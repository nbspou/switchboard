/*
Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Author: Jan Boon <jan.boon@kaetemi.be>
*/

import 'dart:async';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:stream_channel/stream_channel.dart';

import '../status.dart';
import 'mux_channel.dart';
import 'mux_frame.dart';

final Logger _log = Logger('Switchboard.Mux');

/// Local configuration of a [MuxConnection].
class MuxOptions {
  /// Creates options. Every value has a general purpose default.
  const MuxOptions({
    this.maxFrameSize = defaultMaxFrameSize,
    this.maxChannels = defaultMaxChannels,
    this.shortIdsOnly = false,
    this.keepAliveInterval = const Duration(seconds: 10),
    this.keepAliveTimeout = const Duration(seconds: 10),
    this.goAwayGrace = const Duration(seconds: 10),
    this.announceLimits = true,
  });

  /// Default [maxFrameSize]: 1 MiB.
  static const int defaultMaxFrameSize = 1024 * 1024;

  /// Default [maxChannels].
  static const int defaultMaxChannels = 65536;

  /// Largest incoming mux frame, header included, that we accept; a larger
  /// one ends the connection with GOAWAY `FRAME_TOO_LARGE`. Announced with
  /// LIMITS. 0 means no limit at the mux layer (the transport may still
  /// enforce one).
  final int maxFrameSize;

  /// Largest number of simultaneously open channels (in both directions)
  /// before peer OPENs are rejected with CLOSE `RESOURCE_EXHAUSTED`.
  /// Announced with LIMITS. 0 means unlimited.
  final int maxChannels;

  /// Embedded style: allocate only short ids and refuse long form frames
  /// from the peer with GOAWAY `UNSUPPORTED`.
  final bool shortIdsOnly;

  /// Silence after which a PING is sent. Null disables keep-alive.
  final Duration? keepAliveInterval;

  /// How long to wait for any frame after a keep-alive PING before the
  /// connection is closed with `CONNECTION_LOST`. Also bounds how long
  /// [MuxConnection.close] waits for the transport to close.
  final Duration keepAliveTimeout;

  /// How long [MuxConnection.goAway] waits for open channels to finish.
  final Duration goAwayGrace;

  /// Whether LIMITS is sent when the connection starts.
  final bool announceLimits;

  /// A copy with the given fields replaced. Pass [disableKeepAlive] to set
  /// [keepAliveInterval] to null.
  MuxOptions copyWith({
    int? maxFrameSize,
    int? maxChannels,
    bool? shortIdsOnly,
    Duration? keepAliveInterval,
    bool disableKeepAlive = false,
    Duration? keepAliveTimeout,
    Duration? goAwayGrace,
    bool? announceLimits,
  }) => MuxOptions(
    maxFrameSize: maxFrameSize ?? this.maxFrameSize,
    maxChannels: maxChannels ?? this.maxChannels,
    shortIdsOnly: shortIdsOnly ?? this.shortIdsOnly,
    keepAliveInterval: disableKeepAlive
        ? null
        : keepAliveInterval ?? this.keepAliveInterval,
    keepAliveTimeout: keepAliveTimeout ?? this.keepAliveTimeout,
    goAwayGrace: goAwayGrace ?? this.goAwayGrace,
    announceLimits: announceLimits ?? this.announceLimits,
  );
}

/// The mux layer over one transport connection: any number of channels
/// opened by either side, plus the control channel.
///
/// See the wiki page "Switchboard Mux".
class MuxConnection {
  /// Starts the mux over [transport], a [StreamChannel] carrying one mux
  /// frame per event. [isInitiator] is true on the side that established
  /// the connection; it allocates even channel ids, the acceptor odd ones.
  ///
  /// Sends LIMITS at once if [MuxOptions.announceLimits] is set.
  MuxConnection(
    StreamChannel<Uint8List> transport, {
    required this.isInitiator,
    this.options = const MuxOptions(),
  }) : _transport = transport,
       _firstId = isInitiator ? 2 : 3,
       _maxId = options.shortIdsOnly ? MuxFrame.maxShortId : MuxFrame.maxId {
    _nextId = _firstId;
    _host = _Host(this);
    _incoming = StreamController<MuxChannel>(
      onCancel: () => _incomingCancelled = true,
    );
    _subscription = transport.stream.listen(
      _onFrame,
      onError: _onTransportError,
      onDone: _onTransportDone,
    );
    if (options.announceLimits) {
      _sendFrame(
        MuxControlMessage.limits(
          MuxLimits(
            maxFrameSize: _clampU32(options.maxFrameSize),
            maxChannels: _clampU32(options.maxChannels),
          ),
        ).toFrame(),
      );
    }
    _startKeepAlive();
  }

  /// Whether this side initiated the connection.
  final bool isInitiator;

  /// Local configuration.
  final MuxOptions options;

  final StreamChannel<Uint8List> _transport;
  late final StreamSubscription<Uint8List> _subscription;
  late final _Host _host;
  late final StreamController<MuxChannel> _incoming;
  final Map<int, MuxChannelLink> _links = {};
  final Completer<Status> _done = Completer<Status>();
  final List<_PendingPing> _pings = [];
  final int _firstId;
  final int _maxId;
  late int _nextId;
  int _openCount = 0;
  int _pingCounter = 0;
  bool _incomingCancelled = false;
  bool _closing = false;
  bool _writable = true;
  bool _goAwaySent = false;
  Status? _peerGoAway;
  MuxLimits? _peerLimits;
  Completer<void>? _idle;
  Future<void>? _closeFuture;

  Timer? _keepAliveTimer;
  final Stopwatch _sinceReceive = Stopwatch()..start();
  bool _keepAliveProbing = false;

  /// Channels opened by the peer, single subscription. Buffered until
  /// listened to; ends when the connection ends. Cancelling the
  /// subscription makes the connection reject further peer OPENs with
  /// CLOSE `UNAVAILABLE`.
  Stream<MuxChannel> get incoming => _incoming.stream;

  /// Completes when the connection has ended, never with an error.
  ///
  /// The status is `GOING_AWAY` if the peer sent GOAWAY (the peer's status
  /// is in the reason if it was not `GOING_AWAY`); the status sent with our
  /// GOAWAY if we ended the connection because the peer broke the protocol
  /// (`PROTOCOL_ERROR`, `FRAME_TOO_LARGE` or `UNSUPPORTED`); otherwise
  /// `CONNECTION_LOST`.
  Future<Status> get done => _done.future;

  /// Whether the transport is open and no local close (including
  /// [goAway]) has started.
  bool get isOpen => !_closing && !_goAwaySent;

  /// Whether the peer sent GOAWAY.
  bool get peerGoingAway => _peerGoAway != null;

  /// Limits the peer announced with LIMITS, or null if none arrived.
  MuxLimits? get peerLimits => _peerLimits;

  /// Number of channels not yet mutually closed, in both directions.
  /// Incoming channels rejected by the connection itself are not counted.
  int get openChannelCount => _openCount;

  /// The channels counted by [openChannelCount], as a snapshot.
  Iterable<MuxChannel> get channels => [
    for (final link in _links.values)
      if (link.surfaced) link.channel,
  ];

  /// Opens a channel carrying [openPayload] in its OPEN frame.
  ///
  /// The channel is usable at once. Throws [SwitchboardException] with
  /// [StatusCode.failedPrecondition] if the connection is closing, we sent
  /// GOAWAY, or the peer sent GOAWAY; with [StatusCode.resourceExhausted]
  /// if no channel id is free or the peer's announced channel limit is
  /// reached; with [StatusCode.frameTooLarge] if the OPEN frame would
  /// exceed the peer's announced frame limit.
  MuxChannel open(Uint8List openPayload) {
    if (_closing || _goAwaySent) {
      throw SwitchboardException.of(
        StatusCode.failedPrecondition,
        'connection is closing',
      );
    }
    if (_peerGoAway != null) {
      throw SwitchboardException.of(
        StatusCode.failedPrecondition,
        'peer is going away',
      );
    }
    final peerMaxChannels = _peerLimits?.maxChannels ?? 0;
    if (peerMaxChannels > 0 && _openCount >= peerMaxChannels) {
      throw SwitchboardException.of(
        StatusCode.resourceExhausted,
        'peer accepts at most $peerMaxChannels channels',
      );
    }
    final id = _allocateId();
    final peerMaxFrame = _peerLimits?.maxFrameSize ?? 0;
    final size = MuxFrame.headerSizeFor(id) + openPayload.length;
    if (peerMaxFrame > 0 && size > peerMaxFrame) {
      throw SwitchboardException.of(
        StatusCode.frameTooLarge,
        'OPEN of $size bytes exceeds the peer limit of $peerMaxFrame',
      );
    }
    final payload = Uint8List.fromList(openPayload);
    final link = MuxChannelLink(
      _host,
      this,
      id,
      isLocallyOpened: true,
      openPayload: payload,
      surfaced: true,
    );
    _links[id] = link;
    _openCount++;
    _sendFrame(MuxFrame.open(id, payload));
    return link.channel;
  }

  /// Sends PING and completes with the round trip time when the matching
  /// PONG arrives.
  ///
  /// Without [payload] a unique one is generated. Fails with
  /// [SwitchboardException] if the connection is closed or ends before
  /// the PONG arrives. Throws [ArgumentError] if [payload] is longer than
  /// 125 bytes.
  Future<Duration> ping([Uint8List? payload]) {
    final message = MuxControlMessage.ping(payload ?? _nextPingPayload());
    if (_closing) {
      return Future.error(
        SwitchboardException.of(
          StatusCode.failedPrecondition,
          'connection is closed',
        ),
      );
    }
    final pending = _PendingPing(Uint8List.fromList(message.payload));
    _pings.add(pending);
    _sendFrame(message.toFrame());
    return pending.completer.future;
  }

  /// Graceful shutdown: sends GOAWAY carrying [status] (default
  /// `GOING_AWAY`), stops accepting channels (peer OPENs get CLOSE
  /// `GOING_AWAY`), waits up to [MuxOptions.goAwayGrace] for the open
  /// channels to finish, then [close]s.
  ///
  /// Throws [ArgumentError] synchronously for application status codes.
  Future<void> goAway([Status status = const Status(33)]) {
    checkMuxStatus(status);
    if (_closing) {
      return close();
    }
    if (!_goAwaySent) {
      _goAwaySent = true;
      _log.fine('$this: sending GOAWAY $status');
      _sendFrame(MuxControlMessage.goAway(status).toFrame());
    }
    return _goAwayWait();
  }

  Future<void> _goAwayWait() async {
    if (_openCount > 0 && !_closing) {
      final idle = _idle ??= Completer<void>();
      final grace = Timer(options.goAwayGrace, () {
        if (!idle.isCompleted) {
          _log.fine('$this: GOAWAY grace expired with $_openCount channels');
          idle.complete();
        }
      });
      await idle.future;
      grace.cancel();
    }
    await close();
  }

  /// Closes the transport now. Every channel ends with `CONNECTION_LOST`
  /// (or `GOING_AWAY` if the peer sent GOAWAY) and [done] completes.
  ///
  /// Completes once the transport has closed, waiting at most
  /// [MuxOptions.keepAliveTimeout] for it. Never throws.
  Future<void> close() => _shutdown(_lostStatus(), null);

  @override
  String toString() =>
      'MuxConnection(${isInitiator ? 'initiator' : 'acceptor'}, '
      '$_openCount channels${_closing ? ', closed' : ''})';

  /// Sets the next id the allocator tries. For tests of id wrapping.
  @visibleForTesting
  set nextChannelIdForTesting(int id) => _nextId = id;

  // Allocation ----------------------------------------------------------

  int _allocateId() {
    // Number of ids of our parity in [_firstId, _maxId].
    final candidates = (_maxId - _firstId) ~/ 2 + 1;
    var id = _nextId;
    for (var i = 0; i < candidates; i++) {
      if (id > _maxId) {
        id = _firstId;
      }
      final candidate = id;
      id += 2;
      if (MuxFrame.isReservedId(candidate) || _links.containsKey(candidate)) {
        continue;
      }
      _nextId = id;
      return candidate;
    }
    throw SwitchboardException.of(
      StatusCode.resourceExhausted,
      'no free channel id',
    );
  }

  // Sending -------------------------------------------------------------

  void _sendFrame(MuxFrame frame) {
    if (!_writable) {
      return;
    }
    try {
      _transport.sink.add(frame.encode());
    } on Object catch (e) {
      _log.fine('$this: transport write failed: $e');
      _writable = false;
    }
  }

  Uint8List _nextPingPayload() {
    final n = _pingCounter++;
    return Uint8List.fromList([
      n & 0xFF,
      (n >> 8) & 0xFF,
      (n >> 16) & 0xFF,
      (n >> 24) & 0xFF,
    ]);
  }

  // Receiving -----------------------------------------------------------

  void _onFrame(Uint8List bytes) {
    if (_closing) {
      return;
    }
    _noteReceive();
    try {
      _handleFrame(bytes);
    } on SwitchboardException catch (e) {
      _fail(e.status);
    } on Object catch (e, st) {
      _log.severe('$this: internal error while handling a frame', e, st);
      _fail(Status.of(StatusCode.internal, 'internal error'));
    }
  }

  void _handleFrame(Uint8List bytes) {
    final maxFrame = options.maxFrameSize;
    if (maxFrame > 0 && bytes.length > maxFrame) {
      throw SwitchboardException.of(
        StatusCode.frameTooLarge,
        'frame of ${bytes.length} bytes exceeds limit of $maxFrame',
      );
    }
    final frame = MuxFrame.decode(bytes);
    if (frame.longForm && options.shortIdsOnly) {
      throw SwitchboardException.of(
        StatusCode.unsupported,
        'long channel ids are not supported',
      );
    }
    final id = frame.channelId;
    if (id == MuxFrame.controlChannelId) {
      _handleControl(frame.payload);
      return;
    }
    switch (frame.command) {
      case MuxCommand.open:
        _handleOpen(id, frame.payload);
      case MuxCommand.data:
        final link = _links[id];
        if (link == null || link.closeReceived) {
          throw ProtocolException('DATA on channel $id which is not open');
        }
        link.receiveData(frame.payload);
      case MuxCommand.close:
        final link = _links[id];
        if (link == null || link.closeReceived) {
          throw ProtocolException('CLOSE on channel $id which is not open');
        }
        link.receiveClose(decodeStatusPayload(frame.payload, 'CLOSE'));
    }
  }

  void _handleOpen(int id, Uint8List payload) {
    // The peer allocates odd ids if we are the initiator, even otherwise.
    if (id.isOdd != isInitiator) {
      throw ProtocolException('OPEN on channel $id with the wrong parity');
    }
    if (_links.containsKey(id)) {
      throw ProtocolException('OPEN on channel $id which is in use');
    }
    Status? rejection;
    if (_goAwaySent) {
      rejection = Status.of(StatusCode.goingAway);
    } else if (_incomingCancelled) {
      rejection = Status.of(StatusCode.unavailable, 'not accepting channels');
    } else if (options.maxChannels > 0 && _openCount >= options.maxChannels) {
      rejection = Status.of(
        StatusCode.resourceExhausted,
        'at most ${options.maxChannels} channels',
      );
    }
    final link = MuxChannelLink(
      _host,
      this,
      id,
      isLocallyOpened: false,
      openPayload: Uint8List.fromList(payload),
      surfaced: rejection == null,
    );
    _links[id] = link;
    if (rejection != null) {
      _log.fine('$this: rejecting channel $id: $rejection');
      link.reject(rejection);
      return;
    }
    _openCount++;
    _incoming.add(link.channel);
  }

  void _handleControl(Uint8List payload) {
    final message = MuxControlMessage.decode(payload);
    switch (message.knownType) {
      case MuxControlType.ping:
        _sendFrame(MuxControlMessage.pong(message.payload).toFrame());
      case MuxControlType.pong:
        _completePing(message.payload);
      case MuxControlType.goAway:
        final status = message.goAwayStatus;
        if (_peerGoAway != null) {
          return;
        }
        _log.fine('$this: peer sent GOAWAY $status');
        _peerGoAway = status.known == StatusCode.goingAway
            ? status
            : Status.of(StatusCode.goingAway, status.toString());
        scheduleMicrotask(_checkIdle);
      case MuxControlType.limits:
        _peerLimits = MuxLimits.decode(message.payload);
        _log.fine('$this: peer limits $_peerLimits');
      case null:
        _log.fine('$this: ignoring control type ${message.type}');
    }
  }

  void _completePing(Uint8List payload) {
    for (var i = 0; i < _pings.length; i++) {
      final pending = _pings[i];
      if (_bytesEqual(pending.payload, payload)) {
        _pings.removeAt(i);
        pending.completer.complete(pending.stopwatch.elapsed);
        return;
      }
    }
    // Unsolicited PONGs (including answers to keep-alive PINGs) are
    // ignored.
  }

  void _onTransportError(Object error, StackTrace stackTrace) {
    if (_closing) {
      return;
    }
    if (error is SwitchboardException) {
      switch (error.code) {
        case StatusCode.protocolError ||
            StatusCode.frameTooLarge ||
            StatusCode.unsupported:
          _fail(error.status);
          return;
        default:
          break;
      }
    }
    _log.fine('$this: transport failed: $error');
    unawaited(_shutdown(_lostStatus(), null));
  }

  void _onTransportDone() {
    if (_closing) {
      return;
    }
    _log.fine('$this: transport closed by peer');
    _writable = false;
    unawaited(_shutdown(_lostStatus(), null));
  }

  // Channel bookkeeping --------------------------------------------------

  void _release(MuxChannelLink link) {
    if (!identical(_links[link.id], link)) {
      return;
    }
    _links.remove(link.id);
    if (link.surfaced) {
      _openCount--;
    }
    // Deferred so that the channel finishes sending its confirming CLOSE
    // before an idle connection is closed.
    scheduleMicrotask(_checkIdle);
  }

  void _checkIdle() {
    if (_closing || _openCount > 0) {
      return;
    }
    final idle = _idle;
    _idle = null;
    if (idle != null && !idle.isCompleted) {
      idle.complete();
    }
    if (_peerGoAway != null) {
      _log.fine('$this: idle after peer GOAWAY, closing');
      unawaited(close());
    }
  }

  // Keep-alive ----------------------------------------------------------

  void _startKeepAlive() {
    final interval = options.keepAliveInterval;
    if (interval == null) {
      return;
    }
    _keepAliveTimer = Timer(interval, _onKeepAliveTimer);
  }

  void _noteReceive() {
    _sinceReceive.reset();
    if (_keepAliveProbing) {
      _keepAliveProbing = false;
      _keepAliveTimer?.cancel();
      _startKeepAlive();
    }
  }

  void _onKeepAliveTimer() {
    final interval = options.keepAliveInterval;
    if (_closing || interval == null) {
      return;
    }
    if (_keepAliveProbing) {
      _log.info('$this: no answer to keep-alive PING, closing');
      unawaited(_shutdown(_lostStatus('keep-alive timeout'), null));
      return;
    }
    final silence = _sinceReceive.elapsed;
    if (silence < interval) {
      _keepAliveTimer = Timer(interval - silence, _onKeepAliveTimer);
      return;
    }
    _keepAliveProbing = true;
    _sendFrame(MuxControlMessage.ping(_nextPingPayload()).toFrame());
    _keepAliveTimer = Timer(options.keepAliveTimeout, _onKeepAliveTimer);
  }

  // Shutdown ------------------------------------------------------------

  /// Status for channels (and the connection) when the transport ends
  /// without us killing it.
  Status _lostStatus([String reason = '']) =>
      _peerGoAway ?? Status.of(StatusCode.connectionLost, reason);

  /// Ends the connection because the peer broke the protocol: GOAWAY with
  /// [status], then close.
  void _fail(Status status) {
    if (_closing) {
      return;
    }
    _log.warning('$this: closing with $status');
    _sendFrame(MuxControlMessage.goAway(status).toFrame());
    unawaited(_shutdown(status, _lostStatus()));
  }

  /// Ends the connection with [status]; channels end with [channelStatus]
  /// (default [status]). Idempotent; never throws.
  Future<void> _shutdown(Status status, Status? channelStatus) {
    return _closeFuture ??= _doShutdown(status, channelStatus ?? status);
  }

  Future<void> _doShutdown(Status status, Status channelStatus) async {
    _closing = true;
    _finish(status, channelStatus);
    _writable = false;
    try {
      await Future.wait<void>([
        _subscription.cancel(),
        _transport.sink.close().then<void>((_) {}),
      ]).timeout(options.keepAliveTimeout);
    } on Object catch (e) {
      _log.fine('$this: transport close: $e');
    }
  }

  void _finish(Status status, Status channelStatus) {
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;
    final links = _links.values.toList();
    _links.clear();
    _openCount = 0;
    for (final link in links) {
      try {
        link.connectionLost(channelStatus);
      } on Object catch (e, st) {
        _log.warning('$this: error ending channel ${link.id}', e, st);
      }
    }
    final pings = List.of(_pings);
    _pings.clear();
    for (final pending in pings) {
      pending.completer.completeError(SwitchboardException(status));
    }
    final idle = _idle;
    _idle = null;
    if (idle != null && !idle.isCompleted) {
      idle.complete();
    }
    unawaited(_incoming.close());
    if (!_done.isCompleted) {
      _done.complete(status);
    }
  }
}

class _Host implements MuxChannelHost {
  _Host(this._connection);

  final MuxConnection _connection;

  @override
  void sendFrame(MuxFrame frame) => _connection._sendFrame(frame);

  @override
  void release(MuxChannelLink link) => _connection._release(link);

  @override
  int get peerMaxFrameSize => _connection._peerLimits?.maxFrameSize ?? 0;
}

class _PendingPing {
  _PendingPing(this.payload);

  final Uint8List payload;
  final Completer<Duration> completer = Completer<Duration>();
  final Stopwatch stopwatch = Stopwatch()..start();
}

int _clampU32(int value) => value < 0
    ? 0
    : value > 0xFFFFFFFF
    ? 0xFFFFFFFF
    : value;

bool _bytesEqual(Uint8List a, Uint8List b) {
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
