/*
Polyverse Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Authors:
  Jan Boon <jan.boon@kaetemi.be>
  Claude Opus 5.5 <noreply@anthropic.com>
  GPT-6 Astra <noreply@anthropic.com>
*/

import 'dart:async';
import 'dart:math' show Random;
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:stream_channel/stream_channel.dart';

import '../address/channel_address.dart';
import '../mux/mux_channel.dart';
import '../mux/mux_connection.dart';
import '../status.dart';
import '../switchboard/incoming_channel.dart';
import '../talk/talk_bulk.dart';
import '../talk/talk_channel.dart';
import 'backoff.dart';

part 'persistent_channel.dart';

final Logger _log = Logger('Switchboard.Client');

/// Establishes a new transport connection to the endpoint, for a
/// [ReconnectingClient]. Called once per connection attempt.
///
/// Typically `() => WebSocketTransport.connect(uri)`. A failed future, or a
/// synchronous throw, counts as a failed attempt, retried after the
/// backoff. A [SwitchboardException] reports its status in
/// [ClientState.lastStatus]; anything else is reported as
/// [StatusCode.unavailable]. The connector may stop or close its client
/// synchronously; an abandoned attempt installs no timeout, and any transport
/// it returns later is discarded.
typedef TransportConnector = Future<StreamChannel<Uint8List>> Function();

/// Phase of a [ReconnectingClient]'s connection.
enum ClientPhase {
  /// No connection: not started, stopped, closed, or waiting for the next
  /// attempt after a failure or a disconnect ([ClientState.nextAttemptAt]).
  disconnected,

  /// A connection attempt is in progress.
  connecting,

  /// Connected: [ReconnectingClient.connection] is the live connection.
  connected,
}

/// A snapshot of a [ReconnectingClient]'s connection, as reported by
/// [ReconnectingClient.state] and [ReconnectingClient.states].
@immutable
class ClientState {
  /// Creates a snapshot.
  const ClientState(
    this.phase, {
    this.attempt = 0,
    this.lastStatus,
    this.since,
    this.nextAttemptAt,
  });

  /// The phase.
  final ClientPhase phase;

  /// Connection attempts since the last connection was established (or
  /// since [ReconnectingClient.start]).
  ///
  /// While [ClientPhase.connecting], the attempt in progress, counting
  /// from 1. While [ClientPhase.connected], the attempt that succeeded.
  /// While [ClientPhase.disconnected], the attempts that failed so far:
  /// 0 right after a connection ended or when stopped.
  final int attempt;

  /// Why the last connection or connection attempt ended: the status the
  /// connection ended with ([MuxConnection.done]), the endpoint's GOAWAY
  /// status when the client left a connection after it
  /// ([MuxConnection.peerGoAwayStatus]), [StatusCode.goingAway] when
  /// [ReconnectingClient.reconnectNow] left it, the failure of the last
  /// attempt, or [StatusCode.cancelled] when stopped or closed. Null until
  /// something has ended. Kept unchanged through
  /// [ClientPhase.connecting] and [ClientPhase.connected].
  final Status? lastStatus;

  /// When this phase began, by the local wall clock.
  final DateTime? since;

  /// When the next connection attempt is due, by the local wall clock:
  /// [since] plus the backoff delay. Set only while
  /// [ClientPhase.disconnected] with an attempt scheduled (after a failed
  /// attempt or a lost connection); null while connecting or connected,
  /// and when stopped or closed.
  ///
  /// The attempt is driven by a timer, not by the clock: it can come later
  /// than this, for example when the application was suspended (call
  /// [ReconnectingClient.reconnectNow] on resume).
  final DateTime? nextAttemptAt;

  /// The time left until [nextAttemptAt], measured against
  /// [DateTime.now] at each call and never negative (zero once it is due),
  /// for a countdown; null when no attempt is scheduled.
  Duration? get retryIn {
    final at = nextAttemptAt;
    if (at == null) {
      return null;
    }
    final left = at.difference(DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }

  /// Whether [phase] is [ClientPhase.connected].
  bool get isConnected => phase == ClientPhase.connected;

  @override
  String toString() =>
      'ClientState(${phase.name}, attempt $attempt'
      '${lastStatus != null ? ', last: $lastStatus' : ''}'
      '${nextAttemptAt != null ? ', next attempt at $nextAttemptAt' : ''})';
}

/// One connection to one endpoint, kept up for a frontend application:
/// reconnects with exponential backoff after every loss, re-opens the
/// application's long-lived channels on every new connection, and
/// delivers the channels the endpoint pushes.
///
/// Platform independent (no `dart:io`): works in Flutter on the web and on
/// mobile with the WebSocket transport.
///
/// ```dart
/// final client = ReconnectingClient(
///   () => WebSocketTransport.connect(Uri.parse('wss://example.com/sb')),
///   defaultPayload: credential,
/// );
/// client.states.listen(showConnectionBanner);
///
/// // One-off request: waits for the connection if needed.
/// final talk = await client.openTalk(
///   ChannelAddress(type: Name('profile')),
/// );
/// final reply = await talk.request('GET', Uint8List(0));
/// await talk.close();
///
/// // Subscription, set up again after every reconnect.
/// final feed = client.openPersistentTalk(
///   ChannelAddress(type: Name('feed')),
///   (talk) async {
///     talk.messages.listen(onFeedMessage);
///     await talk.request('SUB', topic);
///   },
///   onClosed: (status) => log.fine('feed closed: $status'),
/// );
///
/// // Channels the endpoint opens towards the client.
/// client.incoming.listen((channel) => handlePush(channel));
///
/// await client.close();
/// ```
///
/// Connecting: the connector is called (bounded by [connectTimeout]) and a
/// [MuxConnection] is built over the transport as the initiator. Once
/// connected, every persistent channel is opened (all at once, in the
/// order they were created) and pending [openChannel] calls proceed.
///
/// Reconnecting: when the connection ends, for any reason, the state
/// becomes [ClientPhase.disconnected] with the end status, every
/// persistent channel reports its channel's end through its `onClosed`,
/// and a new attempt is made after the backoff.
///
/// GOAWAY: when the endpoint sends GOAWAY with [StatusCode.goingAway] (it
/// is restarting or draining), the client moves to a new connection
/// without waiting for the old one to end. The state becomes
/// [ClientPhase.connecting] with the GOAWAY status as
/// [ClientState.lastStatus]. The persistent channels on the old connection
/// are closed with [StatusCode.goingAway], so that it goes idle and the
/// endpoint can finish promptly, and are opened again on the new one once
/// they have ended; waiting [openChannel] calls go to the new one too. A
/// planned restart is not a failure: the attempt is made at once, and only
/// if it fails does the backoff apply. Channels the application opened on
/// the old connection, and channels the endpoint pushed on it, are left to
/// finish there: the old connection closes once they are done, or when the
/// endpoint's grace period expires. A connection made after a GOAWAY that
/// receives GOAWAY in turn before lasting [maxBackoff] is followed by the
/// backoff instead, so an endpoint that goes away right after accepting is
/// not hammered. A GOAWAY carrying an error is not a restart: the endpoint
/// ends the connection, which is handled as a loss.
///
/// Backoff: the first attempt after [start] is immediate. The delay before
/// attempt `n + 1` after `n` consecutive failures is
/// `min(initialBackoff * backoffFactor^n, maxBackoff)`, then multiplied by
/// a random factor in `[1 - jitter, 1 + jitter]`, so a delay may exceed
/// [maxBackoff] by up to that fraction. A connection that ends counts as a
/// failure unless it lasted longer than [maxBackoff], which resets the
/// sequence: a server that accepts and drops at once is not hammered.
/// While waiting, [ClientState.nextAttemptAt] says when the next attempt is
/// due, and [reconnectNow] makes it at once (on app resume, or when the
/// network comes back).
class ReconnectingClient {
  /// Creates the client and, unless [autoStart] is false, calls [start],
  /// which calls [connect] at once.
  ///
  /// [muxOptions] apply to every connection; [talkOptions] are the defaults
  /// for [openTalk], [openPersistentTalk] and [IncomingChannel.talk].
  /// [defaultPayload] is the application payload (typically the
  /// credential) of every channel opened with an empty
  /// [ChannelAddress.payload]. [random] drives the jitter (for tests).
  ///
  /// Throws [ArgumentError] if [initialBackoff] is negative, [maxBackoff]
  /// is below it, [backoffFactor] is below 1 or not finite, or [jitter] is
  /// outside 0 to 1.
  ReconnectingClient(
    TransportConnector connect, {
    MuxOptions? muxOptions,
    TalkOptions? talkOptions,
    this.initialBackoff = const Duration(milliseconds: 500),
    this.maxBackoff = const Duration(seconds: 30),
    this.backoffFactor = 2,
    this.jitter = 0.2,
    this.connectTimeout = const Duration(seconds: 10),
    Uint8List? defaultPayload,
    bool autoStart = true,
    Random? random,
  }) : _connect = connect,
       muxOptions = muxOptions ?? const MuxOptions(),
       talkOptions = talkOptions ?? const TalkOptions(),
       defaultPayload = defaultPayload ?? Uint8List(0),
       _schedule = Backoff(
         initial: initialBackoff,
         max: maxBackoff,
         factor: backoffFactor,
         jitter: jitter,
         random: random,
       ) {
    if (autoStart) {
      start();
    }
  }

  final TransportConnector _connect;
  final Backoff _schedule;

  /// Mux configuration of every connection.
  final MuxOptions muxOptions;

  /// Default Talk configuration of the channels opened or accepted here.
  final TalkOptions talkOptions;

  /// Delay before the first retry after a failure. Default 500 ms.
  final Duration initialBackoff;

  /// Upper bound of the backoff before jitter, and the lifetime beyond
  /// which a connection (or persistent channel) resets the backoff.
  /// Default 30 s.
  final Duration maxBackoff;

  /// Growth of the backoff per consecutive failure. Default 2.
  final double backoffFactor;

  /// Random spread of each delay, as a fraction of it: 0.2 (the default)
  /// spreads delays over ±20 %.
  final double jitter;

  /// Longest time a connection attempt may take; the attempt then fails
  /// with [StatusCode.unavailable] and a transport that arrives later is
  /// closed. [Duration.zero] waits for ever. Default 10 s.
  final Duration connectTimeout;

  /// Application payload attached to every channel opened with an empty
  /// [ChannelAddress.payload], like `Switchboard.defaultPayload`. May be
  /// replaced at any time (after a credential refresh, say); channels
  /// opened afterwards, including re-opened persistent channels, carry the
  /// new value.
  Uint8List defaultPayload;

  final StreamController<ClientState> _states =
      StreamController<ClientState>.broadcast();
  late final StreamController<IncomingChannel> _incoming =
      StreamController<IncomingChannel>(
        onCancel: () => _incomingCancelled = true,
      );
  ClientState _state = ClientState(
    ClientPhase.disconnected,
    since: DateTime.now(),
  );
  Completer<MuxConnection> _connected = _newConnected();
  MuxConnection? _connection;
  final Set<_PendingOpen> _pendingOpens = {};
  final List<_PersistentCore<Object>> _persistent = [];
  final Set<Future<void>> _retiring = {};

  /// Connections left after the endpoint's GOAWAY that have not closed.
  final Set<MuxConnection> _draining = {};
  bool _running = false;
  bool _closed = false;
  bool _incomingCancelled = false;
  int _attempt = 0;
  int _failures = 0;
  Object? _attemptToken;
  Timer? _connectTimer;
  Timer? _retryTimer;
  Timer? _lifetimeTimer;
  bool _livedLong = false;

  /// The last connection was made at once after a GOAWAY, and no
  /// connection has lasted [maxBackoff] since.
  bool _restartedOnGoAway = false;
  Future<void>? _closeFuture;

  /// Default for the `openTimeout` of [openChannel] and [openTalk].
  static const Duration defaultOpenTimeout = Duration(seconds: 30);

  static Completer<MuxConnection> _newConnected() {
    final completer = Completer<MuxConnection>();
    // Failed by close(); nobody has to be waiting.
    completer.future.ignore();
    return completer;
  }

  // State ---------------------------------------------------------------

  /// Every change of [state], as a broadcast stream. Each listener first
  /// receives the state current when it starts listening. Ends after
  /// [close].
  Stream<ClientState> get states => Stream<ClientState>.multi((controller) {
    controller.add(_state);
    final subscription = _states.stream.listen(
      controller.add,
      onDone: controller.closeSync,
    );
    // Not returning the cancel future: the done event would wait for
    // it, and for a finished stream it belongs to the root zone.
    controller.onCancel = () {
      subscription.cancel().ignore();
    };
  }, isBroadcast: true);

  /// The current state.
  ClientState get state => _state;

  /// When the next connection attempt is due while waiting after a failure
  /// or a disconnect, else null: [ClientState.nextAttemptAt] of [state].
  DateTime? get nextAttemptAt => _state.nextAttemptAt;

  /// The current connection while [ClientPhase.connected], else null.
  ///
  /// One that receives GOAWAY with [StatusCode.goingAway] stops being
  /// current as soon as the client handles it (see the class
  /// documentation); one that receives a GOAWAY carrying an error stays
  /// current until it ends.
  MuxConnection? get connection => _connection;

  /// Completes with the connection once connected: at once while connected,
  /// else with the next connection. A new future replaces it after every
  /// disconnect and every GOAWAY. Fails with [StatusCode.cancelled] when
  /// the client is closed first.
  Future<MuxConnection> get connected => _connected.future;

  /// Whether the client is started: connected, or connecting or waiting to.
  bool get isRunning => _running;

  /// Whether [close] was called.
  bool get isClosed => _closed;

  /// Channels the endpoint opens towards the client, on whichever
  /// connection is current, across reconnects. Single subscription,
  /// buffered until listened to.
  ///
  /// The handler owns each channel, as with `Switchboard` dispatch, and
  /// closes or rejects it. A channel whose OPEN payload is not a valid
  /// [ChannelAddress] is closed with [StatusCode.protocolError] without
  /// being delivered. Once the subscription is cancelled, or after
  /// [close], further channels are closed with [StatusCode.unavailable].
  Stream<IncomingChannel> get incoming => _incoming.stream;

  // Lifecycle -------------------------------------------------------------

  /// Starts connecting, and reconnecting after every loss. Called by the
  /// constructor unless `autoStart` is false. Calls the connector at once,
  /// and resets the backoff. Does nothing if already started or closed.
  void start() {
    if (_closed || _running) {
      return;
    }
    _running = true;
    _failures = 0;
    _restartedOnGoAway = false;
    _attempt = 0;
    _log.fine('starting');
    _attemptConnect();
  }

  /// Stops reconnecting and disconnects: abandons a connection attempt in
  /// progress, closes the persistent channels with
  /// [StatusCode.goingAway] (they are opened again after [start]), and
  /// sends GOAWAY on the connection, and on an earlier one still held open
  /// by the application's channels after the endpoint's GOAWAY; each then
  /// closes once the channels the application opened are done, or after
  /// [MuxOptions.goAwayGrace].
  ///
  /// The state becomes [ClientPhase.disconnected] with
  /// [StatusCode.cancelled]. Pending [openChannel] calls keep waiting.
  /// Does nothing if not started. Never throws.
  void stop() {
    if (_running) {
      _halt('stopped');
    }
  }

  /// Makes the next connection attempt now, for when waiting is pointless:
  /// the application resumed, or the network came back.
  ///
  /// While waiting for the next attempt after a failure or a disconnect,
  /// cancels the wait and attempts at once: the state becomes
  /// [ClientPhase.connecting]. The backoff sequence carries on: if the
  /// attempt fails, the next delay is the one that would have followed the
  /// cancelled attempt ([stop] then [start] resets it).
  ///
  /// While an attempt is in progress, does nothing. While connected, does
  /// nothing unless [force] is true; then the client leaves the connection
  /// as it does after the endpoint's GOAWAY (see the class
  /// documentation), for a connection that may be stale: the state becomes
  /// [ClientPhase.connecting] with [StatusCode.goingAway] as
  /// [ClientState.lastStatus], the persistent channels are closed with
  /// [StatusCode.goingAway] and opened again on the new connection, and
  /// the old connection gets GOAWAY, so it closes once the channels the
  /// application opened on it are done, or after [MuxOptions.goAwayGrace].
  /// If the new attempt fails, the backoff applies.
  ///
  /// Does nothing if not started, or after [close]. Never throws.
  void reconnectNow({bool force = false}) {
    if (_closed || !_running) {
      return;
    }
    final retry = _retryTimer;
    if (retry != null) {
      retry.cancel();
      _log.fine('connecting now');
      _attemptConnect();
      return;
    }
    final connection = _connection;
    if (connection == null || !force) {
      // An attempt is in progress, or connected.
      return;
    }
    _log.info('leaving the connection, reconnecting');
    final status = Status.of(StatusCode.goingAway, 'client reconnecting');
    _leave(connection);
    _retire(connection, status);
    _attemptConnect(status);
  }

  /// Stops (as [stop]), closes every persistent channel for good, fails
  /// pending [openChannel] calls and [connected] with
  /// [StatusCode.cancelled], and ends [states] and [incoming].
  ///
  /// Completes once every connection of this client has closed (after
  /// GOAWAY: when the channels the application opened are done, at most
  /// [MuxOptions.goAwayGrace]); no timer of the client is left then.
  /// Calling it again returns the same future. Never throws.
  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    _closed = true;
    if (_running) {
      _halt('client closed');
    }
    final closed = SwitchboardException.of(
      StatusCode.cancelled,
      'client closed',
    );
    final pending = List.of(_pendingOpens);
    _pendingOpens.clear();
    for (final open in pending) {
      open.fail(closed);
    }
    if (!_connected.isCompleted) {
      _connected.completeError(closed);
    }
    final persistent = [for (final p in List.of(_persistent)) p.close()];
    try {
      await Future.wait(persistent);
      await Future.wait(List.of(_retiring));
    } on Object catch (e, st) {
      _log.warning('error while closing', e, st);
    }
    // Neither close is awaited: an unlistened single subscription stream
    // never delivers its done event.
    _states.close().ignore();
    _incoming.close().ignore();
    _log.fine('closed');
  }

  void _halt(String reason) {
    _running = false;
    _retryTimer?.cancel();
    _retryTimer = null;
    _connectTimer?.cancel();
    _connectTimer = null;
    _attemptToken = null;
    _lifetimeTimer?.cancel();
    _lifetimeTimer = null;
    final connection = _connection;
    _connection = null;
    _attempt = 0;
    if (_connected.isCompleted) {
      _connected = _newConnected();
    }
    _log.fine(reason);
    _setState(
      ClientPhase.disconnected,
      Status.of(StatusCode.cancelled, reason),
    );
    if (connection != null) {
      _retire(connection, Status.of(StatusCode.goingAway, 'client stopping'));
    }
    for (final old in List.of(_draining)) {
      _goAway(old);
    }
    _draining.clear();
  }

  /// Closes the persistent channels on [connection] with [status] and
  /// sends GOAWAY on it.
  void _retire(MuxConnection connection, Status status) {
    for (final p in List.of(_persistent)) {
      p.retire(connection, status);
    }
    _goAway(connection);
  }

  /// Sends GOAWAY on [connection]; [close] waits for it to close.
  void _goAway(MuxConnection connection) {
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

  /// [retryDelay] is the delay of the attempt scheduled, if any.
  void _setState(
    ClientPhase phase,
    Status? lastStatus, {
    int? attempt,
    Duration? retryDelay,
  }) {
    final now = DateTime.now();
    _state = ClientState(
      phase,
      attempt: attempt ?? _attempt,
      lastStatus: lastStatus,
      since: now,
      nextAttemptAt: retryDelay == null ? null : now.add(retryDelay),
    );
    if (!_states.isClosed) {
      _states.add(_state);
    }
  }

  // Connecting ------------------------------------------------------------

  /// Starts an attempt; [lastStatus] replaces [ClientState.lastStatus].
  void _attemptConnect([Status? lastStatus]) {
    _retryTimer = null;
    if (!_running) {
      return;
    }
    _attempt++;
    final token = Object();
    _attemptToken = token;
    _setState(ClientPhase.connecting, lastStatus ?? _state.lastStatus);
    _log.fine('connecting, attempt $_attempt');
    Future<StreamChannel<Uint8List>> attempt;
    try {
      attempt = _connect();
    } on Object catch (e, st) {
      attempt = Future.error(e, st);
    }
    if (identical(_attemptToken, token) && connectTimeout > Duration.zero) {
      _connectTimer = Timer(connectTimeout, () {
        _connectTimer = null;
        if (identical(_attemptToken, token)) {
          _attemptToken = null;
          _connectFailed(
            SwitchboardException.of(
              StatusCode.unavailable,
              'cannot connect: timed out after $connectTimeout',
            ),
          );
        }
      });
    }
    attempt
        .then(
          (transport) {
            if (!identical(_attemptToken, token)) {
              _log.fine('closing a transport that arrived too late');
              _discard(transport);
              return;
            }
            _attemptToken = null;
            _connectTimer?.cancel();
            _connectTimer = null;
            _onTransport(transport);
          },
          onError: (Object e, StackTrace st) {
            if (!identical(_attemptToken, token)) {
              _log.fine('abandoned connection attempt failed: $e');
              return;
            }
            _attemptToken = null;
            _connectTimer?.cancel();
            _connectTimer = null;
            _connectFailed(e);
          },
        )
        .ignore();
  }

  static void _discard(StreamChannel<Uint8List> transport) {
    try {
      transport.sink.close().ignore();
    } on Object catch (e) {
      _log.fine('closing a transport failed: $e');
    }
  }

  void _connectFailed(Object error) {
    final status = error is SwitchboardException
        ? error.status
        : Status.of(StatusCode.unavailable, 'cannot connect: $error');
    if (_attempt == 1) {
      _log.warning('connection attempt failed: $status');
    } else {
      _log.fine('connection attempt $_attempt failed: $status');
    }
    _retryLater(status);
  }

  /// Reports the state [ClientPhase.disconnected] with [status], and the
  /// next attempt after the backoff.
  void _retryLater(Status status) {
    if (!_running) {
      _setState(ClientPhase.disconnected, status);
      return;
    }
    final delay = _backoff(_failures++);
    _log.fine('next connection attempt in $delay');
    _retryTimer = Timer(delay, _attemptConnect);
    _setState(ClientPhase.disconnected, status, retryDelay: delay);
  }

  /// The delay after [failures] consecutive failures, with jitter.
  Duration _backoff(int failures) => _schedule.delay(failures);

  void _onTransport(StreamChannel<Uint8List> transport) {
    final MuxConnection connection;
    try {
      connection = MuxConnection(
        transport,
        isInitiator: true,
        options: muxOptions,
      );
    } on Object catch (e) {
      _discard(transport);
      _connectFailed(e);
      return;
    }
    final attempt = _attempt;
    _attempt = 0;
    _connection = connection;
    _livedLong = false;
    _lifetimeTimer = Timer(maxBackoff, () {
      _lifetimeTimer = null;
      _livedLong = true;
    });
    connection.incoming.listen(_onPeerChannel);
    connection.done
        .then((status) => _onConnectionDone(connection, status))
        .ignore();
    connection.peerGoAwayStatus
        .then((status) => _onPeerGoAway(connection, status))
        .ignore();
    _log.info('connected');
    _setState(ClientPhase.connected, _state.lastStatus, attempt: attempt);
    if (!_connected.isCompleted) {
      _connected.complete(connection);
    }
    // Callbacks may stop or close the client: check before each step.
    for (final p in List.of(_persistent)) {
      if (!identical(_usableConnection, connection)) {
        return;
      }
      p.connectionUp(connection);
    }
    _servePendingOpens(connection);
  }

  void _onConnectionDone(MuxConnection connection, Status status) {
    if (!identical(_connection, connection)) {
      // Retired by stop() or close(), or left after a GOAWAY.
      return;
    }
    _leave(connection);
    _log.info('disconnected: $status');
    _retryLater(status);
  }

  /// [connection], the current one, stops being current.
  void _leave(MuxConnection connection) {
    assert(identical(_connection, connection));
    _connection = null;
    _lifetimeTimer?.cancel();
    _lifetimeTimer = null;
    if (_livedLong) {
      _failures = 0;
      _restartedOnGoAway = false;
    }
    if (_connected.isCompleted) {
      _connected = _newConnected();
    }
  }

  /// The endpoint sent GOAWAY on [connection]: unless it is an error, leave
  /// the connection to the application's channels on it and connect again
  /// at once.
  void _onPeerGoAway(MuxConnection connection, Status status) {
    if (!identical(_connection, connection)) {
      // Retired by stop() or close().
      return;
    }
    if (status.known != StatusCode.goingAway) {
      // The endpoint is ending the connection: a loss once it has ended.
      _log.fine('endpoint sent GOAWAY $status');
      return;
    }
    _leave(connection);
    // Not closed here: the mux closes it once idle after the peer's GOAWAY.
    _draining.add(connection);
    connection.done.whenComplete(() => _draining.remove(connection)).ignore();
    final goingAway = Status.of(StatusCode.goingAway, 'endpoint going away');
    for (final p in List.of(_persistent)) {
      p.retire(connection, goingAway);
    }
    if (_restartedOnGoAway) {
      _log.info('endpoint going away again: $status');
      _retryLater(status);
      return;
    }
    _restartedOnGoAway = true;
    _log.info('endpoint going away: $status, reconnecting');
    _attemptConnect(status);
  }

  /// The current connection if new channels may be opened on it.
  MuxConnection? get _usableConnection {
    final connection = _connection;
    return connection != null && connection.isOpen && !connection.peerGoingAway
        ? connection
        : null;
  }

  void _onPeerChannel(MuxChannel channel) {
    final ChannelAddress address;
    try {
      address = ChannelAddress.decode(channel.openPayload);
    } on ProtocolException catch (e) {
      _log.warning('channel ${channel.id} from the endpoint: ${e.status}');
      unawaited(channel.close(e.status));
      return;
    }
    if (TalkBulkOpen.isBulk(address)) {
      // The payload of a Talk message of one of our channels.
      TalkChannel.routeBulk(channel, address);
      return;
    }
    if (_incomingCancelled || _incoming.isClosed) {
      _log.fine('channel ${channel.id} from the endpoint: nobody listens');
      unawaited(
        channel.close(
          Status.of(StatusCode.unavailable, 'not accepting channels'),
        ),
      );
      return;
    }
    _incoming.add(
      IncomingChannel(channel, address: address, talkOptions: talkOptions),
    );
  }

  // Opening channels --------------------------------------------------------

  Uint8List _encode(ChannelAddress address) =>
      (address.payload.isEmpty && defaultPayload.isNotEmpty
              ? address.copyWith(payload: defaultPayload)
              : address)
          .encode();

  /// Opens a channel to [address] on the current connection, with
  /// [defaultPayload] as the application payload when
  /// [ChannelAddress.payload] is empty.
  ///
  /// While no connection is usable (disconnected, stopped, or the current
  /// connection received GOAWAY), waits for the next connection, at most
  /// [openTimeout]; then fails with [SwitchboardException]
  /// [StatusCode.unavailable]. [Duration.zero] fails at once instead of
  /// waiting.
  ///
  /// The channel belongs to the caller and is not re-opened: it ends with
  /// its connection. A GOAWAY does not move it: it carries on over the old
  /// connection until it ends there or the endpoint's grace period
  /// expires. A rejection by the endpoint arrives as its close status
  /// ([MuxChannel.done]). Fails like [MuxConnection.open] (for
  /// example [StatusCode.resourceExhausted]), with
  /// [StatusCode.cancelled] if the client is closed while waiting, and with
  /// [StatusCode.failedPrecondition] after [close].
  Future<MuxChannel> openChannel(
    ChannelAddress address, {
    Duration openTimeout = defaultOpenTimeout,
  }) {
    if (_closed) {
      return Future.error(_closedException());
    }
    final bytes = _encode(address);
    final connection = _usableConnection;
    if (connection != null) {
      try {
        return Future.value(connection.open(bytes));
      } on SwitchboardException catch (e) {
        if (e.code != StatusCode.failedPrecondition) {
          return Future.error(e);
        }
      }
    }
    if (openTimeout <= Duration.zero) {
      return Future.error(
        SwitchboardException.of(StatusCode.unavailable, 'not connected'),
      );
    }
    final pending = _PendingOpen(bytes);
    _pendingOpens.add(pending);
    pending.timer = Timer(openTimeout, () {
      if (_pendingOpens.remove(pending)) {
        pending.fail(
          SwitchboardException.of(
            StatusCode.unavailable,
            'not connected within $openTimeout',
          ),
        );
      }
    });
    return pending.completer.future;
  }

  void _servePendingOpens(MuxConnection connection) {
    for (final pending in List.of(_pendingOpens)) {
      if (!identical(_usableConnection, connection)) {
        return;
      }
      if (!_pendingOpens.contains(pending)) {
        continue;
      }
      try {
        final channel = connection.open(pending.bytes);
        _pendingOpens.remove(pending);
        pending.complete(channel);
      } on SwitchboardException catch (e) {
        if (e.code == StatusCode.failedPrecondition) {
          // The connection is going away; wait for the next one.
          return;
        }
        _pendingOpens.remove(pending);
        pending.fail(e);
      }
    }
  }

  /// [openChannel] wrapped in a [TalkChannel] with [options] (default:
  /// [talkOptions]). Waits and fails like [openChannel].
  Future<TalkChannel> openTalk(
    ChannelAddress address, {
    TalkOptions? options,
    Duration openTimeout = defaultOpenTimeout,
  }) async => TalkChannel(
    await openChannel(address, openTimeout: openTimeout),
    options: options ?? talkOptions,
  );

  /// A channel to [address] that is opened on every connection, for
  /// subscriptions and other long-lived exchanges. See [PersistentChannel].
  ///
  /// [onOpen] is called with each new channel, starting with the first
  /// connection (never synchronously from this call): read the channel and
  /// send what sets it up there. [onClosed] is called with the end status
  /// of each channel when it ends. Exceptions from either, and a failed
  /// future from [onOpen], are logged and change nothing.
  ///
  /// Throws [SwitchboardException] with [StatusCode.failedPrecondition]
  /// after [close].
  PersistentChannel openPersistent(
    ChannelAddress address,
    FutureOr<void> Function(MuxChannel channel) onOpen, {
    void Function(Status status)? onClosed,
  }) {
    _checkNotClosed();
    final core = _PersistentCore<MuxChannel>(
      this,
      address,
      kind: 'PersistentChannel',
      wrap: (channel) => channel,
      closeValue: (channel, status) => channel.close(status),
      doneOf: (channel) => channel.done,
      onOpen: onOpen,
      onClosed: onClosed,
    );
    _addPersistent(core);
    return PersistentChannel._(core);
  }

  /// [openPersistent] with each channel wrapped in a [TalkChannel] with
  /// [options] (default: [talkOptions]). See [PersistentTalk].
  ///
  /// [onOpen] typically listens to [TalkChannel.messages] and sends the
  /// subscription request again; [onClosed] receives the end status of
  /// each Talk channel ([TalkChannel.done]).
  PersistentTalk openPersistentTalk(
    ChannelAddress address,
    FutureOr<void> Function(TalkChannel channel) onOpen, {
    TalkOptions? options,
    void Function(Status status)? onClosed,
  }) {
    _checkNotClosed();
    final talkOptions = options ?? this.talkOptions;
    final core = _PersistentCore<TalkChannel>(
      this,
      address,
      kind: 'PersistentTalk',
      wrap: (channel) => TalkChannel(channel, options: talkOptions),
      closeValue: (talk, status) => talk.close(status),
      doneOf: (talk) => talk.done,
      onOpen: onOpen,
      onClosed: onClosed,
    );
    _addPersistent(core);
    return PersistentTalk._(core);
  }

  void _addPersistent(_PersistentCore<Object> core) {
    _persistent.add(core);
    // Never call onOpen before the caller has the handle.
    scheduleMicrotask(() {
      final connection = _usableConnection;
      if (connection != null) {
        core.connectionUp(connection);
      }
    });
  }

  void _checkNotClosed() {
    if (_closed) {
      throw _closedException();
    }
  }

  static SwitchboardException _closedException() =>
      SwitchboardException.of(StatusCode.failedPrecondition, 'client closed');

  @override
  String toString() => 'ReconnectingClient(${_state.phase.name})';
}

/// An [ReconnectingClient.openChannel] call waiting for a connection.
class _PendingOpen {
  _PendingOpen(this.bytes);

  final Uint8List bytes;
  final Completer<MuxChannel> completer = Completer<MuxChannel>();
  Timer? timer;

  void complete(MuxChannel channel) {
    timer?.cancel();
    completer.complete(channel);
  }

  void fail(Object error) {
    timer?.cancel();
    completer.completeError(error);
  }
}
