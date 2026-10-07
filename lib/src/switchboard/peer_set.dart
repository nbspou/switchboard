/*
Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Author: Jan Boon <jan.boon@kaetemi.be>
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
  /// or connected and running the `onConnect` hook and opening the
  /// per-peer channel ([Peer.connection] is set then).
  connecting,

  /// Connected and set up: [Peer.connection] is live.
  online,

  /// Not connected; the next attempt is due at [Peer.nextAttemptAt].
  offline,

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
  /// GOAWAY, its per-peer channel was refused), or its first connection
  /// attempt failed. Reported once until the peer is online again.
  offline,

  /// The resolver's record of the peer changed ([Peer.record]): other
  /// endpoints, or other metadata.
  updated,

  /// The record left the resolver, or the set was closed. The last event
  /// of the peer.
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
/// wiki page "Switchboard Use Cases", entry 5) and load-balances over the
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
/// [Resolver.resolve] returns once the resolver is [Resolver.ready], then
/// its [Resolver.events]. A record that appears is added and connected;
/// one that leaves is removed: its connection is sent GOAWAY (the channels
/// the application opened on it get the grace period) and the peer ends
/// in [PeerState.removed]. A record that changes is updated; if its
/// endpoints changed, the peer moves to the new ones.
///
/// Connections: the set owns one connection per peer, established with
/// [Switchboard.dial] and never pooled, so that a worker that reboots
/// disturbs nothing else, and a backoff is kept per peer. The node's
/// outgoing policy rules apply to it ([policy], else
/// [Switchboard.endpointPolicy], else [Switchboard.outgoingPolicy]), and
/// [Switchboard.credentialFor] chooses the payload of the channels opened
/// on it. Each attempt dials the record's endpoints in order and keeps the
/// first that answers, within [connectTimeout].
///
/// Once connected, `onConnect` runs, then the per-peer [channel] (if any)
/// is opened, a PING round trip on the connection makes sure the peer did
/// not refuse it on arrival, and `onOpen` runs with it; only then is the
/// peer [PeerState.online]. A hook that throws or fails is logged and the
/// peer still goes online; each step is waited for at most
/// [connectTimeout] (then a warning is logged and the peer goes online all
/// the same). The hooks run again after every reconnect.
///
/// The per-peer channel behaves like a `PersistentChannel` of a
/// `ReconnectingClient`: opened on every connection; when it ends while
/// the connection stays up, opened again after a backoff kept per peer
/// (reset by a channel that lasted longer than [maxBackoff]) and `onOpen`
/// runs again, while the peer stays online with [Peer.channel] null in
/// between. A refusal that will not change on its own
/// (`PERMISSION_DENIED`, `UNAUTHENTICATED`, `UNIMPLEMENTED`, `NOT_FOUND`)
/// is a failed connection instead: the set leaves the connection with
/// GOAWAY and the peer goes offline with that status until the next
/// attempt after the backoff.
///
/// Backoff, as for `ReconnectingClient`: the first attempt is immediate;
/// after `n` consecutive failures the delay is
/// `min(initialBackoff * backoffFactor^n, maxBackoff)` times a random
/// factor in `[1 - jitter, 1 + jitter]`. A connection that ends counts as
/// a failure unless it lasted longer than [maxBackoff]. A GOAWAY
/// `GOING_AWAY` from the peer (a worker shutting down or rebooting) is not
/// waited out: the peer goes offline, its channel on the old connection is
/// closed with `GOING_AWAY`, the old connection is left to the
/// application's channels on it, and a new attempt is made at once (with
/// the backoff only if it fails, or if the connection was itself made
/// after a GOAWAY and did not last [maxBackoff]).
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
  /// endpoints one after the other) and each hook; [Duration.zero] waits
  /// for ever. [policy] is the policy of the set's connections, overriding
  /// the node's [Switchboard.endpointPolicy] and
  /// [Switchboard.outgoingPolicy]. [random] drives the jitter (for tests).
  ///
  /// Throws [ArgumentError] when there is no resolver, when [onOpen] is
  /// given without [channel], and for a backoff schedule
  /// `ReconnectingClient` would refuse.
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
      policy: policy,
      random: random,
    );
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

  /// Bound on each connection attempt and each hook; [Duration.zero] for
  /// none.
  final Duration connectTimeout;

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

  /// The peers by instance id, in the order they were added. A live,
  /// unmodifiable view; empty after [close].
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
    final buffered = <ServiceEvent>[];
    var initial = true;
    _subscription = resolver.events.listen((event) {
      if (event.record.address.type != type || _closed) {
        return;
      }
      if (initial) {
        buffered.add(event);
      } else {
        _apply(event);
      }
    });
    Future<void> load() async {
      Object? error;
      StackTrace? stack;
      try {
        await resolver.ready;
        final records = await resolver.resolve(type);
        if (_closed) {
          return;
        }
        for (final record in records) {
          if (record.address.type == type) {
            _upsert(record);
          }
        }
      } on Object catch (e, st) {
        if (_closed) {
          return;
        }
        _log.warning('peer set $type: cannot read the resolver', e, st);
        error = e;
        stack = st;
      }
      // Events that came meanwhile may predate the records just read;
      // applied in order, they end in the resolver's current state.
      initial = false;
      for (final event in buffered) {
        _apply(event);
      }
      buffered.clear();
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
    final peer = _peers.remove(event.record.address.instance);
    peer?._remove(null);
  }

  void _upsert(ServiceRecord record) {
    final existing = _peers[record.address.instance];
    if (existing == null) {
      final peer = Peer._(this, record);
      _peers[record.address.instance] = peer;
      _log.fine('peer set $type: ${record.address} added');
      _emit(PeerEvent(PeerEventType.added, peer));
      peer._attemptConnect();
    } else if (existing.record != record) {
      existing._update(record);
    }
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
  /// has no usable connection (offline, or its connection received
  /// GOAWAY; it works while the peer is connecting with its hooks
  /// running) or the set is closed, and like [MuxConnection.open] and
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
      ChannelAddress(
        type: type,
        instance: instance,
        payload: application,
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
      // A connection that lands now is sent GOAWAY at once.
      await Future.wait(List.of(_dials));
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
  MuxConnection? _connection;
  MuxChannel? _channel;

  /// The last online or offline event reported (null: neither yet).
  PeerEventType? _reported;
  bool _removed = false;
  Object? _token;
  int _failures = 0;
  bool _livedLong = false;
  bool _restartedOnGoAway = false;
  Timer? _connectTimer;
  Timer? _retryTimer;
  Timer? _lifetimeTimer;
  Timer? _hookTimer;
  Completer<void>? _hookWait;
  int _channelFailures = 0;
  bool _channelLivedLong = false;
  Timer? _channelRetry;
  Timer? _channelLifetime;

  /// The type and instance id.
  ServiceAddress get address => _record.address;

  /// The resolver's current record of the peer.
  ServiceRecord get record => _record;

  /// Where the peer stands.
  PeerState get state => _state;

  /// Why the last connection or connection attempt ended: the status the
  /// connection ended with, the peer's GOAWAY status, the refusal of the
  /// per-peer channel, or the failure of the last attempt (with several
  /// endpoints, of the last one tried). Null until something has ended.
  /// Kept through [PeerState.connecting] and [PeerState.online].
  Status? get lastStatus => _lastStatus;

  /// When [state] began, by the local wall clock.
  DateTime? get since => _since;

  /// When the next connection attempt is due while [PeerState.offline], by
  /// the local wall clock; null in every other state. Driven by a timer:
  /// the attempt may come later.
  DateTime? get nextAttemptAt => _nextAttemptAt;

  /// Connection attempts since the peer was last connected: while
  /// [PeerState.connecting] the attempt in progress (from 1), while online
  /// the attempt that succeeded, while offline the attempts that failed (0
  /// right after a connection ended).
  int get attempt => _attempt;

  /// The endpoint of [connection] while it is set.
  Uri? get endpoint => _endpoint;

  /// The peer's connection: set from the moment it is established
  /// (during [PeerState.connecting], while the hooks run) until it is lost
  /// or left.
  MuxConnection? get connection => _connection;

  /// The per-peer channel while it is open, else null.
  MuxChannel? get channel => _channel;

  /// Whether [state] is [PeerState.online].
  bool get isOnline => _state == PeerState.online;

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
    if (_reported == type) {
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
      _cancelAttempt();
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

  /// The record is gone (null) or the set closes ([status]).
  void _remove(Status? status) {
    if (_removed) {
      return;
    }
    _removed = true;
    _cancelAttempt();
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
    final timeout = _set.connectTimeout;
    if (timeout > Duration.zero) {
      _connectTimer = Timer(timeout, () {
        _connectTimer = null;
        if (identical(_token, token)) {
          _token = null;
          _connectFailed(
            Status.of(
              StatusCode.unavailable,
              'cannot connect: timed out after $timeout',
            ),
          );
        }
      });
    }
    _set._track(_dialFirst(token));
  }

  void _cancelAttempt() {
    _token = null;
    _connectTimer?.cancel();
    _connectTimer = null;
  }

  /// Dials the endpoints of the record in order; the first that answers
  /// is the connection.
  Future<void> _dialFirst(Object token) async {
    Status? failure;
    for (final endpoint in List.of(_record.endpoints)) {
      if (!identical(_token, token)) {
        return;
      }
      final MuxConnection connection;
      try {
        connection = await _set.switchboard.dial(endpoint, policy: _set.policy);
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
      _cancelAttempt();
      _onConnected(connection, endpoint);
      return;
    }
    if (!identical(_token, token)) {
      return;
    }
    _cancelAttempt();
    _connectFailed(
      failure ?? Status.of(StatusCode.unavailable, 'record has no endpoints'),
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

  void _onConnected(MuxConnection connection, Uri endpoint) {
    _connection = connection;
    _endpoint = endpoint;
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
    _log.fine('$this: connected to $endpoint');
    unawaited(_setUp(connection));
  }

  /// Runs the hooks and opens the per-peer channel on [connection], then
  /// reports the peer online, unless the connection is left meanwhile.
  Future<void> _setUp(MuxConnection connection) async {
    final onConnect = _set.onConnect;
    if (onConnect != null) {
      await _bounded('onConnect', () => onConnect(this));
      if (!identical(_connection, connection)) {
        return;
      }
    }
    if (_set.channel != null) {
      final opened = await _openChannel(connection);
      if (!identical(_connection, connection)) {
        return;
      }
      if (opened != null) {
        // A refusal the peer sends on arrival (its policy, no such
        // service, a credential checked at once) comes before the answer to
        // a PING sent after the OPEN: such a peer never shows online.
        await _bounded('PING', connection.ping, quiet: true);
        if (!identical(_connection, connection)) {
          return;
        }
      }
      final onOpen = _set.onOpen;
      if (opened != null && identical(_channel, opened) && onOpen != null) {
        await _bounded('onOpen', () => onOpen(this, opened));
        if (!identical(_connection, connection)) {
          return;
        }
      }
    }
    _log.info('$this: online at $_endpoint');
    _setState(PeerState.online, _lastStatus);
  }

  /// Runs [hook]: logs a throw or a failed future (unless [quiet]), and
  /// waits for it at most [PeerSet.connectTimeout], or until the
  /// connection is left.
  Future<void> _bounded(
    String name,
    FutureOr<Object?> Function() hook, {
    bool quiet = false,
  }) async {
    void failed(Object e, StackTrace st) => quiet
        ? _log.fine('$this: $name failed: $e')
        : _log.warning('$this: $name failed', e, st);
    final FutureOr<Object?> result;
    try {
      result = hook();
    } on Object catch (e, st) {
      failed(e, st);
      return;
    }
    if (result is! Future<Object?>) {
      return;
    }
    final wait = Completer<void>();
    _hookWait = wait;
    final timeout = _set.connectTimeout;
    if (timeout > Duration.zero) {
      _hookTimer = Timer(timeout, () {
        final message = '$this: $name did not complete within $timeout';
        quiet ? _log.fine(message) : _log.warning(message);
        if (!wait.isCompleted) {
          wait.complete();
        }
      });
    }
    result.then<void>((_) {}, onError: failed).whenComplete(() {
      if (!wait.isCompleted) {
        wait.complete();
      }
    }).ignore();
    await wait.future;
    if (identical(_hookWait, wait)) {
      _endHook();
    }
  }

  /// Stops waiting for the hook in progress, if any.
  void _endHook() {
    _hookTimer?.cancel();
    _hookTimer = null;
    final wait = _hookWait;
    _hookWait = null;
    if (wait != null && !wait.isCompleted) {
      wait.complete();
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

  /// [connection] failed the set-up (the per-peer channel was refused for
  /// good): leave it and retry after the backoff.
  void _failConnection(MuxConnection connection, Status status) {
    if (!identical(_connection, connection)) {
      return;
    }
    _log.info('$this: leaving the connection: $status');
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
    _attempt = 0;
    _lifetimeTimer?.cancel();
    _lifetimeTimer = null;
    if (_livedLong) {
      _failures = 0;
      _restartedOnGoAway = false;
    }
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

  /// Opens the per-peer channel on [connection]. Returns it, or null if it
  /// could not be opened (handled: a retry is scheduled, or the connection
  /// left).
  Future<MuxChannel?> _openChannel(MuxConnection connection) async {
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
        return null;
      }
      if (!identical(_connection, connection) || _channel != null) {
        return null;
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
      channel = connection.open(address.encode());
    } on SwitchboardException catch (e) {
      switch (e.code) {
        case StatusCode.failedPrecondition:
          // Going away: opened again on the next connection.
          _log.fine('$this: connection going away, channel not opened');
        case StatusCode.resourceExhausted:
          _log.info('$this: cannot open the channel: ${e.status}');
          _scheduleChannelRetry();
        default:
          _log.warning('$this: cannot open the channel: ${e.status}');
          _failConnection(connection, e.status);
      }
      return null;
    }
    _channel = channel;
    _channelLivedLong = false;
    _channelLifetime = Timer(_set.maxBackoff, () {
      _channelLifetime = null;
      _channelLivedLong = true;
    });
    channel.done.then((status) => _onChannelEnded(channel, status)).ignore();
    _log.fine('$this: opened channel ${channel.id}');
    return channel;
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
    if (_isTerminal(status)) {
      _failConnection(connection, status);
      return;
    }
    _log.fine('$this: channel ${channel.id} ended with $status, re-opening');
    _scheduleChannelRetry();
  }

  void _scheduleChannelRetry() {
    _channelRetry?.cancel();
    final delay = _set._schedule.delay(_channelFailures++);
    _channelRetry = Timer(delay, () {
      _channelRetry = null;
      final connection = _usable;
      if (_removed || _channel != null || connection == null) {
        return;
      }
      unawaited(_reopen(connection));
    });
  }

  Future<void> _reopen(MuxConnection connection) async {
    final channel = await _openChannel(connection);
    final onOpen = _set.onOpen;
    if (channel == null || onOpen == null) {
      return;
    }
    try {
      final result = onOpen(this, channel);
      if (result is Future<void>) {
        await result;
      }
    } on Object catch (e, st) {
      _log.warning('$this: onOpen failed', e, st);
    }
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
  String toString() => 'Peer($address, ${_state.name})';
}
