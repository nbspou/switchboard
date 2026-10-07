/*
Polyverse Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Authors:
  Jan Boon <jan.boon@kaetemi.be>
  Claude Opus 5.5 <noreply@anthropic.com>
*/

import 'dart:async';
import 'dart:collection';
import 'dart:math' show Random;
import 'dart:typed_data';

import 'package:logging/logging.dart';

import '../address/channel_address.dart';
import '../address/service_address.dart';
import '../client/backoff.dart';
import '../mux/mux_channel.dart';
import '../mux/mux_connection.dart';
import '../name.dart';
import '../naming/naming_protocol.dart';
import '../status.dart';
import '../talk/talk_channel.dart';
import 'channel_policy.dart';
import 'resolver.dart';
import 'switchboard.dart';

final Logger _log = Logger('Switchboard.Client');

/// Where a [Peer] of a [PeerSet] stands.
enum PeerState {
  /// Just known, no connection attempt made yet.
  added,

  /// A connection attempt is in progress: dialling the record's endpoints,
  /// or connected and running the `onConnect` hook and setting up the
  /// per-peer channel ([Peer.connection] is set then); or, on a live
  /// connection, re-opening the per-peer channel.
  connecting,

  /// Connected and set up: [Peer.connection] is live, its hooks succeeded
  /// and the per-peer channel (if any) is open.
  online,

  /// Not usable: not connected, or connected with the per-peer channel
  /// closed. The next attempt (a connection, or the channel on the live
  /// connection) is due at [Peer.nextAttemptAt].
  offline,

  /// The record left the resolver less than the set's removal hold-down
  /// ago: the connection is kept, in case the record comes back (a naming
  /// service or registrar restart). Not counted [PeerSet.online].
  held,

  /// Gone from the resolver, or the set was closed. Final.
  removed,
}

/// What a [PeerEvent] reports.
enum PeerEventType {
  /// A record of the type appeared in the resolver: a new [Peer].
  added,

  /// The peer became [PeerState.online].
  online,

  /// The peer stopped being online (its connection was lost, the peer sent
  /// GOAWAY, its per-peer channel ended or was refused, a hook failed), or
  /// its first connection attempt failed. Reported once until the peer is
  /// online again.
  offline,

  /// The resolver's record of the peer changed ([Peer.record]): other
  /// endpoints, or other metadata.
  updated,

  /// The record left the resolver: the peer is [PeerState.held] for the
  /// set's removal hold-down, then removed, unless its record comes back
  /// first (then `online` or `offline` follows, as the peer stands).
  held,

  /// The record left the resolver (after the hold-down), or the set was
  /// closed. The last event of the peer.
  removed,
}

/// A change of a [PeerSet], on [PeerSet.events].
class PeerEvent {
  /// Creates an event.
  const PeerEvent(this.type, this.peer, {this.status});

  /// What happened.
  final PeerEventType type;

  /// The peer it happened to: a live view, which may have changed again by
  /// the time the event is delivered.
  final Peer peer;

  /// For [PeerEventType.offline], why the peer went offline (as
  /// [Peer.lastStatus] was then); for [PeerEventType.removed],
  /// [StatusCode.cancelled] when the set was closed. Null otherwise.
  final Status? status;

  @override
  String toString() =>
      'PeerEvent(${type.name} ${peer.address}'
      '${status != null ? ', $status' : ''})';
}

/// The answer a [Switchboard] gives about the reachable instances of one
/// type, kept connected: one connection per instance the resolver knows,
/// re-established with backoff after every loss.
///
/// For a consumer that keeps a connection to every worker of a fleet (the
/// wiki page "Polyverse Switchboard Use Cases", entry 5) and load-balances over the
/// ones that are online with its own policy.
///
/// ```dart
/// final fleet = PeerSet.watch(
///   node,
///   Name('gpu'),
///   channel: ChannelAddress(type: Name('gpu')),
///   onOpen: (peer, channel) async {
///     // The capability exchange, again after every reconnect.
///     final talk = TalkChannel(channel);
///     capabilities[peer.address.instance] = await talk.request(
///       'CAPS',
///       Uint8List(0),
///     );
///   },
/// );
/// fleet.events.listen((event) => log.info('$event'));
/// await fleet.ready;
/// final worker = pick(fleet.online);
/// final talk = await fleet.openTalk(worker.address.instance);
/// ```
///
/// Membership is the resolver's records of the type: the records
/// [Resolver.resolve] returns once the resolver is [Resolver.ready], with
/// the events that arrived while it answered folded in, then its
/// [Resolver.events]. A record that appears is added and connected. A
/// record that changes is updated; if its endpoints changed, the peer
/// moves to the new ones. A record that leaves is held for
/// [removalHoldDown] ([PeerState.held]): the peer's connection stays up,
/// and if a record with the same address comes back in time at the
/// endpoint the peer is connected to (or the peer is not connected), the
/// peer is adopted again as it stands, connection and channel included.
/// Otherwise the peer is removed: its connection is sent GOAWAY (the
/// channels the application opened on it get the grace period) and the
/// peer ends in [PeerState.removed]. The hold-down exists because a
/// naming service or a registrar that restarts makes every record of the
/// fleet disappear for a moment; without it every job in flight would be
/// cut after the GOAWAY grace period.
///
/// Connections: the set owns one connection per peer, established with
/// [Switchboard.dial] and never pooled, so that a worker that reboots
/// disturbs nothing else, and a backoff is kept per peer. The node's
/// outgoing policy rules apply to it ([policy], else
/// [Switchboard.endpointPolicy], else [Switchboard.outgoingPolicy]), and
/// [Switchboard.credentialFor] chooses the payload of the channels opened
/// on it. Each attempt dials the record's endpoints in order and keeps the
/// first that answers, within [connectTimeout]: each endpoint gets the
/// time left divided by the endpoints left, so that one that does not
/// answer at all leaves time for the next.
///
/// A record without endpoints is reached through the naming service's
/// `CONNECT` instead ([Switchboard.broker]; the resolver must be a
/// `BrokeringResolver`, as a `NamingResolver` is): the peer dials this node
/// and the connection that arrives, accepted on the node's listener and
/// under that listener's policy (not [policy]), is the peer's, with no
/// [Peer.endpoint]. After every loss the set brokers again, with the same
/// backoff, hooks and online rules.
///
/// On a node that cannot broker ([Switchboard.canBroker] false: it listens
/// nowhere) but has a [Switchboard.relay], a record without endpoints is
/// reached through a relay instead (wiki page "Polyverse Switchboard Identity and
/// Credentials", section "Relay", "Staying connected"): each attempt
/// dials the relays [Switchboard.resolveRelays] gives, in that order and
/// within [connectTimeout] as for a record's endpoints, naming each
/// relay's identity from its record when it identifies, and keeps the
/// first that answers as the peer's own connection ([Peer.viaRelay],
/// [Peer.endpoint] the relay's endpoint). The per-peer [channel] and the
/// channels of [openChannel] are opened on it as relay channels carrying
/// the peer's open payload. A connection to a relay that is lost, or that
/// the relay sends GOAWAY on, is replaced as any other, through whichever
/// relay resolves next; a per-peer channel that ends while the peer is
/// online is opened again on the same relay connection after the backoff,
/// and when that fails (the relay cannot reach the peer) the connection
/// is left and the next attempt goes through the relays again. The PING
/// round trip of the set-up is answered by the relay, before the peer has
/// seen the channel: for a relayed peer, only an [onOpen] that exchanges
/// something with the peer confirms that the channel reached it, so give
/// relayed peers a per-peer channel and an [onOpen] that does. A node that
/// can neither broker nor relay fails each attempt as brokering does.
///
/// A peer is online only once it is usable: once connected, `onConnect`
/// runs, then the per-peer [channel] (if any) is opened, a PING round trip
/// on the connection makes sure the peer did not refuse it on arrival, and
/// `onOpen` runs with it; only then is the peer [PeerState.online]. A hook
/// that throws, fails or does not complete within [connectTimeout], and a
/// per-peer channel the peer refuses or closes before the peer is online
/// (with any status), fail the attempt: the set leaves the connection with
/// GOAWAY and the peer is offline (with [StatusCode.internal] for a hook,
/// the channel's close status for the channel) until the next attempt
/// after the backoff. The hooks run again after every reconnect.
///
/// The per-peer channel behaves like a `PersistentChannel` of a
/// `ReconnectingClient`: when it ends while the connection stays up, the
/// peer goes offline with its close status and the channel is set up again
/// on that connection after a backoff kept per peer (reset by a channel
/// that lasted longer than [maxBackoff]), with the same PING round trip
/// and `onOpen`, bounded the same way; a re-open that fails is tried again
/// after the backoff, and the peer is online again once one succeeds. A
/// status that will not change on its own (`PERMISSION_DENIED`,
/// `UNAUTHENTICATED`, `UNIMPLEMENTED`, `NOT_FOUND`) fails the connection
/// instead: GOAWAY, offline with that status until the next connection
/// attempt after the backoff.
///
/// Backoff, as for `ReconnectingClient`: the first attempt is immediate;
/// after `n` consecutive failures the delay is
/// `min(initialBackoff * backoffFactor^n, maxBackoff)` times a random
/// factor in `[1 - jitter, 1 + jitter]`. A connection that ends counts as
/// a failure unless the peer went online on it and it lasted longer than
/// [maxBackoff]. A GOAWAY `GOING_AWAY` from the peer (a worker shutting
/// down or rebooting) is not waited out: the peer goes offline, its
/// channel on the old connection is closed with `GOING_AWAY`, the old
/// connection is left to the application's channels on it, and a new
/// attempt is made at once (with the backoff only if it fails, or if the
/// connection was itself made after a GOAWAY and did not last
/// [maxBackoff]).
///
/// Close the set before the [Switchboard]: once the node is closed every
/// attempt fails and the set keeps retrying.
class PeerSet {
  PeerSet._(
    this.switchboard,
    this.type,
    this.resolver, {
    required this.onConnect,
    required this.channel,
    required this.onOpen,
    required this.initialBackoff,
    required this.maxBackoff,
    required this.backoffFactor,
    required this.jitter,
    required this.connectTimeout,
    required this.removalHoldDown,
    required this.policy,
    required Random? random,
  }) : _schedule = Backoff(
         initial: initialBackoff,
         max: maxBackoff,
         factor: backoffFactor,
         jitter: jitter,
         random: random,
       );

  /// Watches the instances of [type] in [resolver] (default: the
  /// [Switchboard.resolver] of [switchboard]) and keeps a connection to
  /// each, through [switchboard]. Starts at once; [ready] completes once
  /// the initial records are added.
  ///
  /// [onConnect] runs after every (re)connect of a peer, before the peer
  /// is reported online; [Peer.connection] is set then, and
  /// [openChannel] and [openTalk] work for the peer, for a handshake.
  ///
  /// [channel] is the address of a channel opened to every peer on every
  /// (re)connect, after [onConnect]: its instance, when 0, is set to the
  /// peer's instance id, and an empty application payload is replaced by
  /// the node's payload for the peer ([Switchboard.payloadFor], so
  /// [Switchboard.credentialFor] with the peer's record). [onOpen] runs
  /// with each such channel; [Peer.channel] holds it while it is open.
  ///
  /// [initialBackoff], [maxBackoff], [backoffFactor] and [jitter] are the
  /// backoff schedule of each peer, as for `ReconnectingClient`.
  /// [connectTimeout] bounds each connection attempt (dialling the
  /// endpoints one after the other) and each step of the set-up (each
  /// hook, the PING round trip); [Duration.zero] waits for ever.
  /// [removalHoldDown] is how long a peer whose record left the resolver
  /// is kept ([PeerState.held]) before it is removed; [Duration.zero]
  /// removes it at once. [policy] is the policy of the set's connections,
  /// overriding the node's [Switchboard.endpointPolicy] and
  /// [Switchboard.outgoingPolicy]. [random] drives the jitter (for tests).
  ///
  /// Logs a warning when no policy applies to the set's connections (no
  /// [policy], and the node has neither an outgoing nor an endpoint
  /// policy: every peer may open channels to the node's services), and
  /// when the node's [Switchboard.defaultPayload] is not empty and it has
  /// no [Switchboard.credentialFor] (every peer receives the node's
  /// credential), and when the node identifies with a bearer
  /// [Switchboard.credential] on every connection it initiates (every peer
  /// receives that credential in `IDENT`).
  ///
  /// Throws [ArgumentError] when there is no resolver, when [onOpen] is
  /// given without [channel], for a negative [removalHoldDown], and for a
  /// backoff schedule `ReconnectingClient` would refuse.
  factory PeerSet.watch(
    Switchboard switchboard,
    Name type, {
    Resolver? resolver,
    FutureOr<void> Function(Peer peer)? onConnect,
    ChannelAddress? channel,
    FutureOr<void> Function(Peer peer, MuxChannel channel)? onOpen,
    Duration initialBackoff = const Duration(milliseconds: 500),
    Duration maxBackoff = const Duration(seconds: 30),
    double backoffFactor = 2,
    double jitter = 0.2,
    Duration connectTimeout = const Duration(seconds: 10),
    Duration removalHoldDown = const Duration(seconds: 15),
    ChannelPolicy? policy,
    Random? random,
  }) {
    final r = resolver ?? switchboard.resolver;
    if (r == null) {
      throw ArgumentError.value(
        resolver,
        'resolver',
        'no resolver given and the switchboard has none',
      );
    }
    if (onOpen != null && channel == null) {
      throw ArgumentError.value(onOpen, 'onOpen', 'needs a channel');
    }
    if (removalHoldDown < Duration.zero) {
      throw ArgumentError.value(
        removalHoldDown,
        'removalHoldDown',
        'must not be negative',
      );
    }
    final set = PeerSet._(
      switchboard,
      type,
      r,
      onConnect: onConnect,
      channel: channel,
      onOpen: onOpen,
      initialBackoff: initialBackoff,
      maxBackoff: maxBackoff,
      backoffFactor: backoffFactor,
      jitter: jitter,
      connectTimeout: connectTimeout,
      removalHoldDown: removalHoldDown,
      policy: policy,
      random: random,
    );
    if (policy == null &&
        switchboard.outgoingPolicy == null &&
        switchboard.endpointPolicy == null) {
      _log.warning(
        'peer set $type: no policy applies to its connections, so every '
        'peer may open channels to the services of this node; give the set '
        'a policy, or the node an outgoingPolicy or endpointPolicy',
      );
    }
    if (switchboard.credentialFor == null &&
        switchboard.defaultPayload.isNotEmpty) {
      _log.warning(
        'peer set $type: the node has a defaultPayload and no '
        'credentialFor, so every peer receives the node\'s credential',
      );
    }
    final identity = switchboard.credential;
    if (identity != null &&
        identity.isBearer &&
        switchboard.identifyFor == null &&
        switchboard.identifyOutgoing) {
      _log.warning(
        'peer set $type: the node identifies with a bearer credential on '
        'every connection it initiates, so every peer receives it; restrict '
        'identification with identifyFor',
      );
    }
    set._start();
    return set;
  }

  /// The node the connections are made through.
  final Switchboard switchboard;

  /// The service type watched; also the type of [openChannel].
  final Name type;

  /// The resolver whose records of [type] are the members.
  final Resolver resolver;

  /// Runs after every (re)connect of a peer, before it is online.
  final FutureOr<void> Function(Peer peer)? onConnect;

  /// The per-peer channel's address, or null for none.
  final ChannelAddress? channel;

  /// Runs with every per-peer channel opened.
  final FutureOr<void> Function(Peer peer, MuxChannel channel)? onOpen;

  /// Delay before the first retry after a failure.
  final Duration initialBackoff;

  /// Upper bound of the backoff before jitter, and the lifetime beyond
  /// which a connection (or per-peer channel) resets the backoff.
  final Duration maxBackoff;

  /// Growth of the backoff per consecutive failure.
  final double backoffFactor;

  /// Random spread of each delay, as a fraction of it.
  final double jitter;

  /// Bound on each connection attempt and each step of the set-up;
  /// [Duration.zero] for none.
  final Duration connectTimeout;

  /// How long a peer whose record left the resolver is held before it is
  /// removed; [Duration.zero] for not at all.
  final Duration removalHoldDown;

  /// The policy of the set's connections, or null for the node's.
  final ChannelPolicy? policy;

  final Backoff _schedule;
  final Map<int, Peer> _peers = {};
  final StreamController<PeerEvent> _events =
      StreamController<PeerEvent>.broadcast();
  final Completer<void> _ready = _newReady();
  StreamSubscription<ServiceEvent>? _subscription;

  /// Connection attempts in progress, GOAWAYs sent, connections left after
  /// the peer's GOAWAY: what [close] waits for.
  final Set<Future<void>> _dials = {};
  final Set<Future<void>> _retiring = {};
  final Set<MuxConnection> _draining = {};
  bool _closed = false;
  Future<void>? _closeFuture;

  static Completer<void> _newReady() {
    final completer = Completer<void>();
    // Fails on close or a resolver failure; nobody has to be waiting.
    completer.future.ignore();
    return completer;
  }

  /// The peers by instance id, in the order they were added, held ones
  /// included. A live, unmodifiable view; empty after [close].
  Map<int, Peer> get peers => UnmodifiableMapView(_peers);

  /// The peers that are [PeerState.online].
  Iterable<Peer> get online => _peers.values.where((peer) => peer.isOnline);

  /// Additions, state changes and removals of peers, in order. Broadcast;
  /// ends after [close], which reports every peer removed first.
  Stream<PeerEvent> get events => _events.stream;

  /// Completes once the records the resolver had when it became ready are
  /// added (their connection attempts started). Fails with the resolver's
  /// error if it cannot be read (the set still follows its events), and
  /// with [StatusCode.cancelled] if the set is closed first.
  Future<void> get ready => _ready.future;

  /// Whether [close] was called.
  bool get isClosed => _closed;

  void _start() {
    // Until the initial records are read: the events of the type. Those
    // that came before resolve() was called are in its answer and are
    // dropped; those that come while it answers are folded into it.
    final buffered = <ServiceEvent>[];
    var initial = true;
    _subscription = resolver.events.listen(
      (event) {
        if (event.record.address.type != type || _closed) {
          return;
        }
        if (initial) {
          buffered.add(event);
        } else {
          _apply(event);
        }
      },
      onError: (Object e, StackTrace st) {
        // A broadcast or single-subscription stream alike goes on after
        // an error event; so does the set.
        _log.warning('peer set $type: resolver event error', e, st);
      },
    );
    Future<void> load() async {
      Object? error;
      StackTrace? stack;
      var records = const <ServiceRecord>[];
      try {
        await resolver.ready;
        if (_closed) {
          return;
        }
        buffered.clear();
        records = await resolver.resolve(type);
        if (_closed) {
          return;
        }
      } on Object catch (e, st) {
        if (_closed) {
          return;
        }
        _log.warning('peer set $type: cannot read the resolver', e, st);
        error = e;
        stack = st;
      }
      // The answer may or may not include the events that came meanwhile;
      // UP replaces a record and DOWN removes it, so applying all of them
      // to the answer, in order, gives the resolver's current table. Each
      // record of it is added once; one that came and went never is.
      final table = <int, ServiceRecord>{
        for (final record in records)
          if (record.address.type == type) record.address.instance: record,
      };
      for (final event in buffered) {
        final instance = event.record.address.instance;
        if (event.up) {
          table[instance] = event.record;
        } else {
          table.remove(instance);
        }
      }
      buffered.clear();
      initial = false;
      table.values.forEach(_upsert);
      if (!_ready.isCompleted) {
        if (error == null) {
          _ready.complete();
        } else {
          _ready.completeError(error, stack);
        }
      }
    }

    unawaited(load());
  }

  void _apply(ServiceEvent event) {
    if (_closed) {
      return;
    }
    if (event.up) {
      _upsert(event.record);
      return;
    }
    final instance = event.record.address.instance;
    final peer = _peers[instance];
    if (peer == null || peer._isHeld) {
      return;
    }
    if (removalHoldDown > Duration.zero) {
      peer._hold();
    } else {
      _peers.remove(instance);
      peer._remove(null);
    }
  }

  void _upsert(ServiceRecord record) {
    final instance = record.address.instance;
    final existing = _peers[instance];
    if (existing != null && existing._isHeld) {
      if (existing._readopt(record)) {
        return;
      }
      // Elsewhere now: the held peer goes, a new one comes.
      _peers.remove(instance);
      existing._remove(null);
    } else if (existing != null) {
      if (existing.record != record) {
        existing._update(record);
      }
      return;
    }
    final peer = Peer._(this, record);
    _peers[instance] = peer;
    _log.fine('peer set $type: ${record.address} added');
    _emit(PeerEvent(PeerEventType.added, peer));
    peer._attemptConnect();
  }

  /// The hold-down of [peer] ran out: it goes.
  void _expire(Peer peer) {
    final instance = peer.address.instance;
    if (identical(_peers[instance], peer)) {
      _peers.remove(instance);
    }
    peer._remove(null);
  }

  void _emit(PeerEvent event) {
    if (!_events.isClosed) {
      _events.add(event);
    }
  }

  // Connections -----------------------------------------------------------

  /// Runs [attempt], a connection attempt that never fails, as work
  /// [close] waits for.
  void _track(Future<void> attempt) {
    _dials.add(attempt);
    attempt.whenComplete(() => _dials.remove(attempt)).ignore();
  }

  /// Sends GOAWAY on [connection], which this set owns; [close] waits for
  /// it to close.
  void _retire(MuxConnection connection) {
    _draining.remove(connection);
    Future<void> gone;
    try {
      gone = connection.goAway();
    } on Object catch (e, st) {
      _log.warning('GOAWAY failed', e, st);
      gone = connection.close();
    }
    _retiring.add(gone);
    gone.whenComplete(() => _retiring.remove(gone)).ignore();
  }

  /// Keeps [connection], left after the peer's GOAWAY, until it closes on
  /// its own; [close] sends it GOAWAY.
  void _drain(MuxConnection connection) {
    _draining.add(connection);
    connection.done.whenComplete(() => _draining.remove(connection)).ignore();
  }

  // Opening channels ------------------------------------------------------

  /// Opens a channel to `(type, instance)` on the connection of the peer
  /// [instance], with [payload] as the application payload (default: the
  /// node's payload for the peer, [Switchboard.payloadFor] with its
  /// record).
  ///
  /// The channel belongs to the caller and ends with that connection; it
  /// is not moved when the peer reconnects. A rejection by the peer
  /// arrives as its close status ([MuxChannel.done]).
  ///
  /// Throws [SwitchboardException] with [StatusCode.notFound] if the set
  /// has no such peer, with [StatusCode.failedPrecondition] if the peer
  /// has no usable connection (not connected, or its connection received
  /// GOAWAY; it works while the peer is connecting with its hooks running,
  /// while its per-peer channel is being re-opened, and while it is held)
  /// or the set is closed, and like [MuxConnection.open] and
  /// [Switchboard.credentialFor].
  Future<MuxChannel> openChannel(int instance, {Uint8List? payload}) async {
    if (_closed) {
      throw SwitchboardException.of(
        StatusCode.failedPrecondition,
        'peer set closed',
      );
    }
    final peer = _peers[instance];
    if (peer == null) {
      throw SwitchboardException.of(
        StatusCode.notFound,
        'no peer ${ServiceAddress(type, instance)}',
      );
    }
    var connection = peer._usable;
    if (connection == null) {
      throw SwitchboardException.of(
        StatusCode.failedPrecondition,
        '${peer.address} is ${peer.state.name}',
      );
    }
    final application =
        payload ??
        await switchboard.payloadFor(connection, record: peer.record);
    connection = peer._usable;
    if (connection == null) {
      throw SwitchboardException.of(
        StatusCode.failedPrecondition,
        '${peer.address} is ${peer.state.name}',
      );
    }
    return connection.open(
      Peer._wrap(
        ChannelAddress(type: type, instance: instance, payload: application),
        peer._relayType,
      ).encode(),
    );
  }

  /// [openChannel] wrapped in a [TalkChannel] with [options] (default: the
  /// node's [Switchboard.talkOptions]). Throws like [openChannel].
  Future<TalkChannel> openTalk(
    int instance, {
    Uint8List? payload,
    TalkOptions? options,
  }) async => TalkChannel(
    await openChannel(instance, payload: payload),
    options: options ?? switchboard.talkOptions,
  );

  // Shutdown ----------------------------------------------------------------

  /// Stops watching, removes every peer (each reported
  /// [PeerEventType.removed] with [StatusCode.cancelled], its per-peer
  /// channel closed and its connection sent GOAWAY), fails [ready] if it
  /// has not completed, and ends [events].
  ///
  /// Completes once every connection of the set has closed (the channels
  /// the application opened get the GOAWAY grace period) and the dials in
  /// progress have settled; no timer of the set is left then. Does not
  /// close the resolver or the node. Calling it again returns the same
  /// future. Never throws.
  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    _closed = true;
    final unsubscribed = _subscription?.cancel();
    final cancelled = Status.of(StatusCode.cancelled, 'peer set closed');
    for (final peer in List.of(_peers.values)) {
      peer._remove(cancelled);
    }
    _peers.clear();
    for (final connection in List.of(_draining)) {
      _retire(connection);
    }
    if (!_ready.isCompleted) {
      _ready.completeError(SwitchboardException(cancelled));
    }
    try {
      await unsubscribed;
      // A connection that lands now is sent GOAWAY at once. A dial given
      // up on is tracked when it is given up on, so look again.
      while (_dials.isNotEmpty) {
        await Future.wait(List.of(_dials));
      }
      await Future.wait(List.of(_retiring));
    } on Object catch (e, st) {
      _log.warning('error while closing the peer set', e, st);
    }
    // Not awaited: a broadcast stream without listeners completes it at
    // once anyway.
    _events.close().ignore();
    _log.fine('peer set $type closed');
  }

  @override
  String toString() => 'PeerSet($type, ${_peers.length} peers)';
}

/// Close statuses of the per-peer channel that a new attempt on the same
/// connection would get again.
bool _isTerminal(Status status) => switch (status.known) {
  StatusCode.permissionDenied ||
  StatusCode.unauthenticated ||
  StatusCode.unimplemented ||
  StatusCode.notFound => true,
  _ => false,
};

/// One instance of a [PeerSet]: its record, its connection and its state.
///
/// A live view, updated by the set; read it, do not keep copies of its
/// fields.
class Peer {
  Peer._(this._set, this._record) : _since = DateTime.now();

  final PeerSet _set;
  ServiceRecord _record;
  PeerState _state = PeerState.added;
  Status? _lastStatus;
  DateTime? _since;
  DateTime? _nextAttemptAt;
  int _attempt = 0;
  Uri? _endpoint;

  /// The type of the relay channels while [_connection] is a connection
  /// to a relay.
  Name? _relayType;
  MuxConnection? _connection;
  MuxChannel? _channel;

  /// Whether the per-peer channel [_channel] was set up (its PING round
  /// trip and `onOpen` done); false while it is being set up.
  bool _channelUp = false;

  /// The last event of the online, offline and held kind reported (null:
  /// none yet).
  PeerEventType? _reported;
  bool _removed = false;

  /// The connection attempt in progress (dialling), else null.
  Object? _token;
  int _failures = 0;

  /// Whether the peer went online on the current connection (set-up done
  /// once): only then does the connection count as a success.
  bool _established = false;
  bool _livedLong = false;
  bool _restartedOnGoAway = false;
  Timer? _retryTimer;
  Timer? _lifetimeTimer;
  Timer? _hookTimer;
  Completer<Status?>? _hookWait;
  int _channelFailures = 0;
  bool _channelLivedLong = false;
  Timer? _channelRetry;
  Timer? _channelLifetime;
  Timer? _holdTimer;
  DateTime? _heldSince;

  /// The type and instance id.
  ServiceAddress get address => _record.address;

  /// The resolver's current record of the peer (while held, the last one).
  ServiceRecord get record => _record;

  /// Where the peer stands.
  PeerState get state => _holdTimer != null ? PeerState.held : _state;

  /// Why the last connection, connection attempt or per-peer channel
  /// ended: the status the connection ended with, the peer's GOAWAY
  /// status, the close status of the per-peer channel, a hook's failure
  /// ([StatusCode.internal]), or the failure of the last attempt (with
  /// several endpoints, of the last one tried). Null until something has
  /// ended. Kept through [PeerState.connecting] and [PeerState.online].
  Status? get lastStatus => _lastStatus;

  /// When [state] began, by the local wall clock.
  DateTime? get since => _heldSince ?? _since;

  /// When the next attempt (a connection, or the per-peer channel on the
  /// live connection) is due while [PeerState.offline], by the local wall
  /// clock; null in every other state. Driven by a timer: the attempt may
  /// come later.
  DateTime? get nextAttemptAt =>
      _holdTimer != null || _state != PeerState.offline ? null : _nextAttemptAt;

  /// Connection attempts since the peer was last online: while
  /// [PeerState.connecting] the attempt in progress (from 1), while online
  /// the attempt that succeeded, while offline the attempts that failed (0
  /// right after a connection it was online on ended, and while the
  /// per-peer channel is re-opened on such a connection).
  int get attempt => _attempt;

  /// The endpoint of [connection] while it is set: the record's endpoint
  /// that answered, or the relay's endpoint for a peer reached through a
  /// relay ([viaRelay]); null for a brokered connection (the peer
  /// registered without endpoints and dialled this node).
  Uri? get endpoint => _endpoint;

  /// Whether [connection] is a connection to a relay, which forwards the
  /// peer's channels (see [PeerSet], about records without endpoints);
  /// false while not connected.
  bool get viaRelay => _relayType != null;

  /// The peer's connection: set from the moment it is established
  /// (during [PeerState.connecting], while the hooks run) until it is lost
  /// or left.
  MuxConnection? get connection => _connection;

  /// The per-peer channel while it is open, else null.
  MuxChannel? get channel => _channel;

  /// Whether [state] is [PeerState.online].
  bool get isOnline => state == PeerState.online;

  bool get _isHeld => _holdTimer != null;

  /// The connection, if channels may be opened on it.
  MuxConnection? get _usable {
    final connection = _connection;
    return connection != null && connection.isOpen && !connection.peerGoingAway
        ? connection
        : null;
  }

  // State -------------------------------------------------------------------

  void _setState(PeerState state, Status? lastStatus, {Duration? retryDelay}) {
    final now = DateTime.now();
    _state = state;
    _lastStatus = lastStatus;
    _since = now;
    _nextAttemptAt = retryDelay == null ? null : now.add(retryDelay);
    switch (state) {
      case PeerState.online:
        _report(PeerEventType.online, null);
      case PeerState.offline:
        _report(PeerEventType.offline, lastStatus);
      case PeerState.connecting when _reported == PeerEventType.online:
        _report(PeerEventType.offline, lastStatus);
      default:
    }
  }

  void _report(PeerEventType type, Status? status) {
    if (_reported == type || _holdTimer != null) {
      // While held, what happens to the connection is reported when the
      // peer is adopted again.
      return;
    }
    _reported = type;
    _set._emit(PeerEvent(type, this, status: status));
  }

  void _update(ServiceRecord record) {
    final previous = _record;
    _record = record;
    _log.fine('$this: record updated: $record');
    _set._emit(PeerEvent(PeerEventType.updated, this));
    if (_sameEndpoints(previous.endpoints, record.endpoints)) {
      return;
    }
    // Other endpoints: the failures so far say nothing about them.
    _failures = 0;
    final connection = _connection;
    if (connection != null) {
      if (!record.endpoints.contains(_endpoint)) {
        _log.info('$this: endpoint ${_endpoint ?? ''} withdrawn, moving');
        final status = Status.of(StatusCode.goingAway, 'endpoints changed');
        _leave(connection, channelStatus: status);
        _set._retire(connection);
        _attemptConnect(status);
      }
    } else if (_token != null) {
      // Dialling the old endpoints: start over with the new ones.
      _token = null;
      _attemptConnect();
    } else if (_retryTimer != null) {
      _retryTimer!.cancel();
      _attemptConnect();
    }
  }

  static bool _sameEndpoints(List<Uri> a, List<Uri> b) {
    if (a.length != b.length) {
      return false;
    }
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) {
        return false;
      }
    }
    return true;
  }

  /// The record left the resolver: held for the set's hold-down, its
  /// connection kept.
  void _hold() {
    final holdDown = _set.removalHoldDown;
    _log.fine('$this: record gone, held for $holdDown');
    _heldSince = DateTime.now();
    _reported = PeerEventType.held;
    _set._emit(PeerEvent(PeerEventType.held, this));
    _holdTimer = Timer(holdDown, () {
      _holdTimer = null;
      _heldSince = null;
      _log.fine('$this: not back within $holdDown');
      _set._expire(this);
    });
  }

  /// A record of the held peer came back: adopted again if it can still
  /// reach the peer where it is connected (or it is not connected). Returns
  /// false, leaving the peer held, when the record is elsewhere.
  bool _readopt(ServiceRecord record) {
    final endpoint = _endpoint;
    final elsewhere = _relayType != null
        ? record.endpoints.isNotEmpty
        : endpoint != null && !record.endpoints.contains(endpoint);
    if (elsewhere) {
      return false;
    }
    _holdTimer?.cancel();
    _holdTimer = null;
    _heldSince = null;
    _since = DateTime.now();
    _log.fine('$this: record back, adopted again');
    switch (_state) {
      case PeerState.online:
        _report(PeerEventType.online, null);
      case PeerState.offline:
        _report(PeerEventType.offline, _lastStatus);
      default:
      // Connecting: the outcome is reported.
    }
    if (record != _record) {
      _update(record);
    }
    return true;
  }

  /// The record is gone (null) or the set closes ([status]).
  void _remove(Status? status) {
    if (_removed) {
      return;
    }
    _removed = true;
    _holdTimer?.cancel();
    _holdTimer = null;
    _heldSince = null;
    _token = null;
    _retryTimer?.cancel();
    _retryTimer = null;
    final connection = _connection;
    if (connection != null) {
      _leave(
        connection,
        channelStatus: Status.of(StatusCode.goingAway, 'peer removed'),
      );
      _set._retire(connection);
    }
    _log.fine('$this: removed');
    final now = DateTime.now();
    _state = PeerState.removed;
    _since = now;
    _nextAttemptAt = null;
    _set._emit(PeerEvent(PeerEventType.removed, this, status: status));
  }

  // Connecting --------------------------------------------------------------

  /// Starts an attempt; [lastStatus] replaces [lastStatus].
  void _attemptConnect([Status? lastStatus]) {
    _retryTimer = null;
    if (_removed) {
      return;
    }
    _attempt++;
    final token = Object();
    _token = token;
    _setState(PeerState.connecting, lastStatus ?? _lastStatus);
    _set._track(_dialFirst(token));
  }

  /// Dials the endpoints of the record in order; the first that answers
  /// is the connection. With [PeerSet.connectTimeout], each endpoint gets
  /// the time left divided by the endpoints left. A record without
  /// endpoints is brokered instead, or reached through a relay by a node
  /// that cannot broker and has one.
  Future<void> _dialFirst(Object token) async {
    if (_record.endpoints.isEmpty) {
      final switchboard = _set.switchboard;
      if (switchboard.relay != null && !switchboard.canBroker) {
        await _relayConnection(token);
      } else {
        await _brokerConnection(token);
      }
      return;
    }
    await _dialEach(token, [
      for (final endpoint in _record.endpoints) (endpoint, _record),
    ], relayed: false);
  }

  /// Dials the relays of the node in the order it gives them
  /// ([Switchboard.resolveRelays]), as [_dialFirst] dials a record's
  /// endpoints.
  Future<void> _relayConnection(Object token) async {
    final List<ServiceRecord> relays;
    try {
      relays = await _set.switchboard.resolveRelays(resolver: _set.resolver);
    } on Object catch (e) {
      if (!identical(_token, token)) {
        return;
      }
      _token = null;
      _connectFailed(
        e is SwitchboardException
            ? e.status
            : Status.of(StatusCode.unavailable, 'no relay: $e'),
      );
      return;
    }
    await _dialEach(token, [
      for (final relay in relays)
        for (final endpoint in relay.endpoints) (endpoint, relay),
    ], relayed: true);
  }

  /// Dials [targets], endpoints with the record each is dialled for, in
  /// order; the first that answers is the connection, to a relay when
  /// [relayed]. With [PeerSet.connectTimeout], each endpoint gets the time
  /// left divided by the endpoints left.
  Future<void> _dialEach(
    Object token,
    List<(Uri, ServiceRecord)> targets, {
    required bool relayed,
  }) async {
    final budget = _set.connectTimeout;
    final clock = Stopwatch()..start();
    Status? failure;
    for (var i = 0; i < targets.length; i++) {
      if (!identical(_token, token)) {
        return;
      }
      final (endpoint, record) = targets[i];
      Duration? bound;
      if (budget > Duration.zero) {
        final left = budget - clock.elapsed;
        if (left <= Duration.zero) {
          failure = Status.of(
            StatusCode.unavailable,
            'cannot connect: timed out after $budget',
          );
          break;
        }
        bound = left ~/ (targets.length - i);
      }
      final MuxConnection connection;
      try {
        connection = await _dial(endpoint, bound, record);
      } on Object catch (e) {
        failure = e is SwitchboardException
            ? e.status
            : Status.of(StatusCode.unavailable, 'cannot connect: $e');
        _log.fine('$this: $endpoint: $failure');
        continue;
      }
      if (!identical(_token, token)) {
        _log.fine('$this: closing a connection that arrived too late');
        _set._retire(connection);
        return;
      }
      _token = null;
      _onConnected(
        connection,
        endpoint,
        relayType: relayed ? record.address.type : null,
      );
      return;
    }
    if (!identical(_token, token)) {
      return;
    }
    _token = null;
    _connectFailed(
      failure ??
          Status.of(
            StatusCode.unavailable,
            relayed ? 'no relay endpoints' : 'record has no endpoints',
          ),
    );
  }

  /// Has the peer, registered without endpoints, dial this node through
  /// the naming service ([Switchboard.broker]), within
  /// [PeerSet.connectTimeout]; a connection that lands after that is sent
  /// GOAWAY at once.
  Future<void> _brokerConnection(Object token) async {
    final brokering = _set.switchboard.broker(
      _record.address,
      resolver: _set.resolver,
    );
    final budget = _set.connectTimeout;
    final MuxConnection connection;
    try {
      connection = await (budget > Duration.zero
          ? brokering.timeout(
              budget,
              onTimeout: () {
                _set._track(
                  brokering.then<void>(_set._retire, onError: (Object _) {}),
                );
                throw SwitchboardException.of(
                  StatusCode.unavailable,
                  'not brokered within $budget',
                );
              },
            )
          : brokering);
    } on Object catch (e) {
      if (!identical(_token, token)) {
        return;
      }
      _token = null;
      _connectFailed(
        e is SwitchboardException
            ? e.status
            : Status.of(StatusCode.unavailable, 'cannot broker: $e'),
      );
      return;
    }
    if (!identical(_token, token)) {
      _log.fine('$this: closing a connection that arrived too late');
      _set._retire(connection);
      return;
    }
    _token = null;
    _onConnected(connection, null);
  }

  /// Dials [endpoint] for [record] (the peer's, or a relay's), giving up
  /// after [bound] if given; a connection that lands after that is sent
  /// GOAWAY at once ([PeerSet.close] waits for it).
  Future<MuxConnection> _dial(
    Uri endpoint,
    Duration? bound,
    ServiceRecord record,
  ) {
    final dialing = _set.switchboard.dial(
      endpoint,
      policy: _set.policy,
      record: record,
    );
    if (bound == null) {
      return dialing;
    }
    return dialing.timeout(
      bound,
      onTimeout: () {
        _set._track(dialing.then<void>(_set._retire, onError: (Object _) {}));
        throw SwitchboardException.of(
          StatusCode.unavailable,
          'cannot connect to $endpoint: timed out after $bound',
        );
      },
    );
  }

  void _connectFailed(Status status) {
    if (_attempt == 1) {
      _log.info('$this: connection attempt failed: $status');
    } else {
      _log.fine('$this: connection attempt $_attempt failed: $status');
    }
    _retryLater(status);
  }

  /// Offline with [status]; the next attempt after the backoff.
  void _retryLater(Status status) {
    final delay = _set._schedule.delay(_failures++);
    _log.fine('$this: next connection attempt in $delay');
    _retryTimer = Timer(delay, _attemptConnect);
    _setState(PeerState.offline, status, retryDelay: delay);
  }

  void _onConnected(
    MuxConnection connection,
    Uri? endpoint, {
    Name? relayType,
  }) {
    _connection = connection;
    _endpoint = endpoint;
    _relayType = relayType;
    _established = false;
    _livedLong = false;
    _lifetimeTimer = Timer(_set.maxBackoff, () {
      _lifetimeTimer = null;
      _livedLong = true;
    });
    connection.done
        .then((status) => _onConnectionDone(connection, status))
        .ignore();
    connection.peerGoAwayStatus
        .then((status) => _onPeerGoAway(connection, status))
        .ignore();
    _log.fine(
      '$this: ${endpoint == null
          ? 'brokered'
          : relayType == null
          ? 'connected to $endpoint'
          : 'connected to the relay at $endpoint'}',
    );
    unawaited(_setUp(connection));
  }

  /// Runs `onConnect` and sets up the per-peer channel on [connection],
  /// then reports the peer online; a step that fails fails the attempt.
  /// Stops when the connection is left meanwhile.
  Future<void> _setUp(MuxConnection connection) async {
    final onConnect = _set.onConnect;
    if (onConnect != null) {
      final failure = await _bounded('onConnect', () => onConnect(this));
      if (!identical(_connection, connection)) {
        return;
      }
      if (failure != null) {
        _failConnection(connection, failure);
        return;
      }
    }
    if (_set.channel != null && !await _openPerPeerChannel(connection)) {
      return;
    }
    _established = true;
    _log.info(
      '$this: online at ${_endpoint == null
          ? 'a brokered connection'
          : _relayType == null
          ? '$_endpoint'
          : 'the relay at $_endpoint'}',
    );
    _setState(PeerState.online, _lastStatus);
  }

  /// Runs one step of the set-up, [hook], for at most
  /// [PeerSet.connectTimeout] or until the connection or the per-peer
  /// channel is left ([_endHook]). Returns null when it completed (or was
  /// left: the caller checks), else a status with [code] saying it failed
  /// or timed out (logged, as a warning unless [quiet]).
  Future<Status?> _bounded(
    String name,
    FutureOr<Object?> Function() hook, {
    StatusCode code = StatusCode.internal,
    bool quiet = false,
  }) async {
    Status failed(Object e, StackTrace st) {
      if (quiet || _failures > 0 || _channelFailures > 0) {
        // Once per series of failures is enough.
        _log.fine('$this: $name failed: $e');
      } else {
        _log.warning('$this: $name failed', e, st);
      }
      return Status.of(code, '$name failed');
    }

    final FutureOr<Object?> result;
    try {
      result = hook();
    } on Object catch (e, st) {
      return failed(e, st);
    }
    if (result is! Future<Object?>) {
      return null;
    }
    final wait = Completer<Status?>();
    _hookWait = wait;
    final timeout = _set.connectTimeout;
    if (timeout > Duration.zero) {
      _hookTimer = Timer(timeout, () {
        _hookTimer = null;
        final message = '$this: $name did not complete within $timeout';
        quiet ? _log.fine(message) : _log.warning(message);
        if (!wait.isCompleted) {
          wait.complete(Status.of(code, '$name timed out'));
        }
      });
    }
    result
        .then<void>(
          (_) {
            if (!wait.isCompleted) {
              wait.complete(null);
            }
          },
          onError: (Object e, StackTrace st) {
            if (wait.isCompleted) {
              // Left, or timed out, already.
              _log.fine('$this: $name failed late: $e');
              return;
            }
            wait.complete(failed(e, st));
          },
        )
        .ignore();
    final outcome = await wait.future;
    if (identical(_hookWait, wait)) {
      _endHook();
    }
    return outcome;
  }

  /// Stops waiting for the step in progress, if any.
  void _endHook() {
    _hookTimer?.cancel();
    _hookTimer = null;
    final wait = _hookWait;
    _hookWait = null;
    if (wait != null && !wait.isCompleted) {
      wait.complete(null);
    }
  }

  void _onConnectionDone(MuxConnection connection, Status status) {
    if (!identical(_connection, connection)) {
      // Left after a GOAWAY, a refusal or a removal.
      return;
    }
    _leave(connection);
    _log.info('$this: disconnected: $status');
    _retryLater(status);
  }

  /// The peer sent GOAWAY on [connection]: unless it is an error, leave
  /// the connection to the application's channels on it and connect again
  /// at once.
  void _onPeerGoAway(MuxConnection connection, Status status) {
    if (!identical(_connection, connection)) {
      return;
    }
    if (status.known != StatusCode.goingAway) {
      // The peer is ending the connection: a loss once it has ended.
      _log.fine('$this: peer sent GOAWAY $status');
      return;
    }
    _leave(
      connection,
      channelStatus: Status.of(StatusCode.goingAway, 'peer going away'),
    );
    _set._drain(connection);
    if (_restartedOnGoAway) {
      _log.info('$this: going away again: $status');
      _retryLater(status);
      return;
    }
    _restartedOnGoAway = true;
    _log.info('$this: going away: $status, reconnecting');
    _attemptConnect(status);
  }

  /// [connection] failed: its set-up failed, or the per-peer channel was
  /// refused for good. Leave it with GOAWAY and retry after the backoff.
  void _failConnection(MuxConnection connection, Status status) {
    if (!identical(_connection, connection)) {
      return;
    }
    if (_failures == 0) {
      _log.info('$this: leaving the connection: $status');
    } else {
      _log.fine('$this: leaving the connection: $status');
    }
    _leave(connection, channelStatus: status);
    _set._retire(connection);
    _retryLater(status);
  }

  /// [connection], the current one, stops being current. The per-peer
  /// channel on it is closed with [channelStatus] if given (it ends with
  /// the connection anyway).
  void _leave(MuxConnection connection, {Status? channelStatus}) {
    assert(identical(_connection, connection));
    _connection = null;
    _endpoint = null;
    _relayType = null;
    _lifetimeTimer?.cancel();
    _lifetimeTimer = null;
    if (_established) {
      // The attempts count again from the next one.
      _attempt = 0;
      if (_livedLong) {
        _failures = 0;
        _restartedOnGoAway = false;
      }
    }
    _established = false;
    _endHook();
    _channelRetry?.cancel();
    _channelRetry = null;
    final channel = _channel;
    if (channel != null) {
      _channelEnded();
      if (channelStatus != null) {
        _closeQuietly(channel, channelStatus);
      }
    }
  }

  // The per-peer channel ----------------------------------------------------

  /// Opens the per-peer channel on [connection], makes sure with a PING
  /// round trip that the peer did not refuse it on arrival, and runs
  /// `onOpen` with it. Returns true when all of that succeeded; otherwise
  /// the failure is handled ([_channelFailed]), or the connection or the
  /// channel was left meanwhile, and returns false.
  Future<bool> _openPerPeerChannel(MuxConnection connection) async {
    _channelUp = false;
    final template = _set.channel!;
    var payload = template.payload;
    if (payload.isEmpty) {
      try {
        payload = await _set.switchboard.payloadFor(
          connection,
          record: _record,
        );
      } on Object catch (e, st) {
        _log.warning('$this: no payload for the channel', e, st);
        _failConnection(
          connection,
          Status.of(StatusCode.internal, 'credential failed'),
        );
        return false;
      }
      if (!identical(_connection, connection) || _channel != null) {
        return false;
      }
    }
    final address = template.copyWith(
      instance: template.instance == 0
          ? _record.address.instance
          : template.instance,
      payload: payload,
    );
    final MuxChannel channel;
    try {
      channel = connection.open(_wrap(address, _relayType).encode());
    } on SwitchboardException catch (e) {
      _log.info('$this: cannot open the channel: ${e.status}');
      _channelFailed(connection, e.status);
      return false;
    }
    _channel = channel;
    _channelLivedLong = false;
    _channelLifetime = Timer(_set.maxBackoff, () {
      _channelLifetime = null;
      _channelLivedLong = true;
    });
    channel.done.then((status) => _onChannelEnded(channel, status)).ignore();
    _log.fine('$this: opened channel ${channel.id}');
    // A refusal the peer sends on arrival (its policy, no such service, a
    // credential checked at once, a handler that throws) comes before the
    // answer to a PING sent after the OPEN, and is handled by
    // _onChannelEnded before this goes on.
    final noPong = await _bounded(
      'PING',
      connection.ping,
      code: StatusCode.unavailable,
      quiet: true,
    );
    if (!identical(_connection, connection) || !identical(_channel, channel)) {
      return false;
    }
    if (noPong != null) {
      _channelFailed(connection, noPong);
      return false;
    }
    final onOpen = _set.onOpen;
    if (onOpen != null) {
      final failure = await _bounded('onOpen', () => onOpen(this, channel));
      if (!identical(_connection, connection) ||
          !identical(_channel, channel)) {
        return false;
      }
      if (failure != null) {
        _channelFailed(connection, failure);
        return false;
      }
    }
    _channelUp = true;
    return true;
  }

  /// [header], a channel's to the peer: as is, or inside the payload of a
  /// relay channel of [relayType].
  static ChannelAddress _wrap(ChannelAddress header, Name? relayType) =>
      relayType == null
      ? header
      : ChannelAddress(type: relayType, payload: header.encode());

  /// The per-peer channel on [connection], the current connection, could
  /// not be set up, or ended, with [status]. Before the peer went online
  /// on [connection], for a status that would repeat, and for a channel
  /// through a relay that could not be set up again, the connection
  /// fails; otherwise the peer is offline and the channel is set up again
  /// after its backoff.
  void _channelFailed(MuxConnection connection, Status status) {
    if (!_established ||
        _isTerminal(status) ||
        (_relayType != null && !_channelUp)) {
      _failConnection(connection, status);
      return;
    }
    final channel = _channel;
    if (channel != null) {
      _channelEnded();
      _closeQuietly(channel, status);
    }
    // A re-open waiting for its PING or onOpen gives up.
    _endHook();
    _scheduleChannelRetry(status);
  }

  /// The per-peer channel ended or was dropped: its lifetime counts.
  void _channelEnded() {
    _channel = null;
    _channelLifetime?.cancel();
    _channelLifetime = null;
    if (_channelLivedLong) {
      _channelFailures = 0;
    }
  }

  void _onChannelEnded(MuxChannel channel, Status status) {
    if (!identical(_channel, channel)) {
      return;
    }
    _channelEnded();
    final connection = channel.connection;
    if (!identical(_connection, connection) ||
        !connection.isOpen ||
        connection.peerGoingAway) {
      // The connection is ending or going away: the set reconnects.
      _log.fine('$this: channel ${channel.id} ended with $status');
      return;
    }
    _log.fine('$this: channel ${channel.id} ended with $status');
    _channelFailed(connection, status);
  }

  /// Offline with [status] on the live connection; the per-peer channel
  /// is set up again after its backoff.
  void _scheduleChannelRetry(Status status) {
    _channelRetry?.cancel();
    final delay = _set._schedule.delay(_channelFailures++);
    _log.fine('$this: channel set up again in $delay');
    _channelRetry = Timer(delay, () {
      _channelRetry = null;
      final connection = _usable;
      if (_removed || _channel != null || connection == null) {
        return;
      }
      unawaited(_reopen(connection));
    });
    _setState(PeerState.offline, status, retryDelay: delay);
  }

  /// Sets the per-peer channel up again on [connection], on which the peer
  /// was online, as on a new connection.
  Future<void> _reopen(MuxConnection connection) async {
    _setState(PeerState.connecting, _lastStatus);
    if (!await _openPerPeerChannel(connection)) {
      return;
    }
    _log.fine('$this: channel set up again, online');
    _setState(PeerState.online, _lastStatus);
  }

  static void _closeQuietly(MuxChannel channel, Status status) {
    try {
      channel
          .close(status)
          .then<void>(
            (_) {},
            onError: (Object e) => _log.fine('closing a channel failed: $e'),
          )
          .ignore();
    } on Object catch (e) {
      _log.fine('closing a channel failed: $e');
    }
  }

  @override
  String toString() => 'Peer($address, ${state.name})';
}
