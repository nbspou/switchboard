/*
Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Author: Jan Boon <jan.boon@kaetemi.be>
*/

import 'dart:async';
import 'dart:typed_data';

import 'package:async/async.dart' show DelegatingStreamSubscription;
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:stream_channel/stream_channel.dart';

import '../name.dart';
import '../status.dart';
import 'talk_frame.dart';
import 'talk_message.dart';
import 'talk_stream.dart';

final Logger _log = Logger('Switchboard.Talk');

/// Implemented by channels that can be closed with a status (the mux
/// channel).
///
/// When the raw channel of a [TalkChannel] implements this, the talk
/// channel closes it with the talk-level status and takes its end status
/// from [done].
abstract interface class StatusClosable {
  /// Closes the channel, reporting [status] to the peer.
  Future<void> close([Status status]);

  /// The channel's end status, once it is closed.
  Future<Status> get done;
}

/// Per-channel Talk policy.
class TalkOptions {
  /// Creates options; the defaults are the reference defaults of the wiki.
  const TalkOptions({
    this.requestTimeout = const Duration(seconds: 15),
    this.replyTimeout = const Duration(seconds: 10),
    this.maxIncomingRequests = 1024,
    this.maxOutgoingRequests = 1024,
  });

  /// Requester side: how long to wait for a response, restarted by every
  /// stream item and `EXTEND`. Overridable per request. [Duration.zero]
  /// disables the timeout.
  final Duration requestTimeout;

  /// Responder side: how long the application has to call a reply method,
  /// restarted by [TalkMessage.replyItem] and [TalkMessage.extend]. On
  /// expiry the channel sends `ABORT DEADLINE_EXCEEDED` on the
  /// application's behalf. [Duration.zero] disables the timeout.
  final Duration replyTimeout;

  /// Outstanding incoming requests beyond which a new request is answered
  /// with `ABORT RESOURCE_EXHAUSTED` immediately. 0 means unlimited.
  final int maxIncomingRequests;

  /// Outstanding outgoing requests beyond which the request API throws
  /// [StatusCode.resourceExhausted] without sending anything. 0 means
  /// unlimited (the `u24` id space still applies).
  final int maxOutgoingRequests;
}

/// Talk message chains over one channel: plain messages, requests,
/// responses, stream responses, aborts, timeout extension and
/// cancellation. See the wiki page "Switchboard Talk".
///
/// Works over a mux channel or any `StreamChannel<Uint8List>` whose events
/// are whole Talk messages.
///
/// Failure handling:
///
/// * A malformed frame or a violation of the kind rules from the peer
///   closes the channel with [StatusCode.protocolError]; outstanding
///   requests fail with it.
/// * A channel abort from the peer closes the channel with the peer's
///   status; [messages] emits it as an error, then ends.
/// * When the raw stream ends, outstanding requests fail with the raw
///   channel's end status ([StatusClosable.done]) if it is not OK, else
///   with [StatusCode.connectionLost].
/// * Exceptions thrown by application listeners never affect the channel.
///   If a listener of [messages] or [TalkStream.items] throws synchronously
///   while handling a request it has not yet answered, the exception is
///   logged and the request is answered with `ABORT INTERNAL`. Exceptions
///   in asynchronous code (for example the body of an `await for`) cannot
///   be seen by the channel; such a request is answered by the responder
///   timeout.
class TalkChannel {
  /// Wraps [channel]. Starts listening to its stream immediately. A null
  /// [options] means the defaults.
  TalkChannel(StreamChannel<Uint8List> channel, {TalkOptions? options})
    : raw = channel,
      options = options ?? const TalkOptions() {
    _subscription = raw.stream.listen(
      _onData,
      onError: _onError,
      onDone: _onDone,
    );
  }

  /// The underlying channel.
  final StreamChannel<Uint8List> raw;

  /// The policy of this channel.
  final TalkOptions options;

  late final StreamSubscription<Uint8List> _subscription;

  late final StreamController<TalkMessage> _messages =
      StreamController<TalkMessage>(onCancel: () => _messagesCancelled = true);

  /// Incoming plain messages and requests, in arrival order. Responses
  /// never appear here. Single subscription; buffered until listened.
  ///
  /// A channel abort from the peer is delivered as an error event (a
  /// [SwitchboardException] carrying its status) and then the stream ends;
  /// listen with an `onError` handler. The stream also ends, without an
  /// error, when the channel closes for any other reason; [done] has the
  /// status.
  ///
  /// If the subscription is cancelled, later requests are answered with
  /// `ABORT UNIMPLEMENTED`.
  late final Stream<TalkMessage> messages = _GuardedStream(_messages.stream);

  final Map<int, _Outgoing> _outgoing = {};
  final Map<int, _Message> _incoming = {};
  int _nextRequestId = 1;

  bool _messagesCancelled = false;
  bool _closing = false;
  bool _terminated = false;
  bool _rawEnded = false;
  bool _rawClosed = false;
  bool _finishing = false;
  Status? _endStatus;
  Future<void>? _closeFuture;
  final Completer<Status> _done = Completer<Status>();

  /// True until the channel starts closing, for any reason.
  bool get isOpen => !_closing;

  /// Completes once the channel is closed, with its end status: the first
  /// non-OK talk-level status sent or received (channel abort, protocol
  /// error, or the status passed to [close] or [abort]); otherwise the raw
  /// channel's [StatusClosable.done] status if it has one; otherwise
  /// [Status.ok].
  Future<Status> get done => _done.future;

  /// Number of our requests that still hold a request id, including
  /// cancelled ones still waiting for the peer's final response.
  int get outgoingRequestCount => _outgoing.length;

  /// Number of the peer's requests waiting for our final reply.
  int get incomingRequestCount => _incoming.length;

  /// The id the next request will try first. Ids still in use are skipped.
  @visibleForTesting
  int get nextRequestId => _nextRequestId;

  @visibleForTesting
  set nextRequestId(int id) {
    if (id < 1 || id > TalkFrame.maxId) {
      throw RangeError.range(id, 1, TalkFrame.maxId, 'id');
    }
    _nextRequestId = id;
  }

  /// Sends a plain message (fire and forget).
  ///
  /// Throws [SwitchboardException] with [StatusCode.failedPrecondition] if
  /// the channel is closed, and [ArgumentError] if [procedure] is not a
  /// valid name.
  void send(String procedure, Uint8List payload) {
    _sendChecked(
      TalkFrame(
        kind: TalkKind.message,
        procedure: Name(procedure),
        payload: payload,
      ),
    );
  }

  /// Sends a request and returns the final response.
  ///
  /// The future fails with [SwitchboardException] carrying the peer's abort
  /// status, [StatusCode.deadlineExceeded] if nothing arrives within
  /// [timeout] (a cancel is then sent to the peer), or the channel's failure
  /// status. [timeout] defaults to [TalkOptions.requestTimeout];
  /// [Duration.zero] disables it.
  ///
  /// Throws synchronously, sending nothing, with
  /// [StatusCode.resourceExhausted] if [TalkOptions.maxOutgoingRequests] is
  /// reached and with [StatusCode.failedPrecondition] if the channel is
  /// closed.
  Future<TalkMessage> request(
    String procedure,
    Uint8List payload, {
    Duration? timeout,
  }) {
    final name = Name(procedure);
    return _startRequest(
      stream: false,
      timeout: timeout,
      build: (id) => TalkFrame(
        kind: TalkKind.message,
        procedure: name,
        requestId: id,
        payload: payload,
      ),
    ).completer.future;
  }

  /// Sends a stream request. Items and the final response arrive through
  /// the returned [TalkStream]. Throws like [request].
  TalkStream streamRequest(
    String procedure,
    Uint8List payload, {
    Duration? timeout,
  }) {
    final name = Name(procedure);
    final pending = _startRequest(
      stream: true,
      timeout: timeout,
      build: (id) => TalkFrame(
        kind: TalkKind.message,
        procedure: name,
        requestId: id,
        stream: true,
        payload: payload,
      ),
    );
    return _TalkStream(this, pending);
  }

  /// Sends a channel abort carrying [status], then closes the channel with
  /// it. Application codes are allowed in the abort; on a [StatusClosable]
  /// channel they are reported as [StatusCode.unknown] in the close, since
  /// mux CLOSE must not carry them. Does nothing if already closing.
  void abort(Status status) {
    if (_closing) {
      return;
    }
    final payload = status.encode();
    _trySend(TalkFrame(kind: TalkKind.abort, payload: payload));
    unawaited(close(status));
  }

  /// Closes the channel. Outstanding outgoing requests fail with [status],
  /// or with [StatusCode.cancelled] if [status] is OK; outstanding incoming
  /// requests become unanswerable and are marked cancelled. A
  /// [StatusClosable] raw channel is closed with [status], any other raw
  /// channel by closing its sink.
  ///
  /// Completes when [done] completes. Calling it again returns the same
  /// future.
  Future<void> close([Status status = Status.ok]) =>
      _closeFuture ??= _close(status);

  Future<void> _close(Status status) async {
    if (!status.isOk) {
      _endStatus ??= status;
    }
    _terminate(
      status.isOk ? Status.of(StatusCode.cancelled, 'channel closed') : status,
    );
    if (!_rawEnded && !_rawClosed) {
      _rawClosed = true;
      final r = raw;
      if (r is StatusClosable) {
        try {
          await (r as StatusClosable).close(_wireStatus(status));
        } catch (e, st) {
          _log.fine('closing raw channel failed', e, st);
        }
      } else {
        r.sink.close().ignore();
      }
    }
    // Not awaited: nothing depends on it, and the future of an already
    // finished subscription may belong to another zone.
    _subscription.cancel().ignore();
    await _finish();
  }

  // ---------------------------------------------------------------------
  // Sending

  void _sendChecked(TalkFrame frame) {
    if (_closing) {
      throw SwitchboardException.of(
        StatusCode.failedPrecondition,
        'channel closed',
      );
    }
    final bytes = frame.encode();
    try {
      raw.sink.add(bytes);
    } on SwitchboardException {
      rethrow;
    } catch (e) {
      throw SwitchboardException.of(
        StatusCode.failedPrecondition,
        'channel closed: $e',
      );
    }
  }

  /// Sends a frame on the channel's own behalf; failures are logged only.
  void _trySend(TalkFrame frame) {
    if (_closing) {
      return;
    }
    try {
      raw.sink.add(frame.encode());
    } catch (e, st) {
      _log.fine('failed to send $frame', e, st);
    }
  }

  /// Answers the peer's request [requestId] with an abort, without any
  /// local state (the request was never accepted).
  void _rejectRequest(int requestId, Status status) {
    _trySend(
      TalkFrame(
        kind: TalkKind.abort,
        responseId: requestId,
        payload: status.encode(),
      ),
    );
  }

  _Outgoing _startRequest({
    required bool stream,
    required Duration? timeout,
    required TalkFrame Function(int id) build,
  }) {
    if (_closing) {
      throw SwitchboardException.of(
        StatusCode.failedPrecondition,
        'channel closed',
      );
    }
    final max = options.maxOutgoingRequests;
    if ((max > 0 && _outgoing.length >= max) ||
        _outgoing.length >= TalkFrame.maxId) {
      throw SwitchboardException.of(
        StatusCode.resourceExhausted,
        'too many outstanding requests (${_outgoing.length})',
      );
    }
    var id = _nextRequestId;
    while (_outgoing.containsKey(id)) {
      id = id >= TalkFrame.maxId ? 1 : id + 1;
    }
    _sendChecked(build(id));
    _nextRequestId = id >= TalkFrame.maxId ? 1 : id + 1;
    final pending = _Outgoing(
      id,
      timeout ?? options.requestTimeout,
      stream: stream,
    );
    _outgoing[id] = pending;
    _armRequestTimer(pending);
    return pending;
  }

  // ---------------------------------------------------------------------
  // Requester side

  void _armRequestTimer(_Outgoing pending) {
    pending.stopTimer();
    if (pending.timeout > Duration.zero) {
      pending.timer = Timer(pending.timeout, () => _onRequestTimeout(pending));
    }
  }

  void _onRequestTimeout(_Outgoing pending) {
    pending.timer = null;
    if (!identical(_outgoing[pending.id], pending)) {
      return;
    }
    _outgoing.remove(pending.id);
    if (pending.abandoned) {
      _log.fine('released cancelled request ${pending.id} on timeout');
      return;
    }
    _log.fine('request ${pending.id} timed out after ${pending.timeout}');
    pending.fail(
      SwitchboardException.of(
        StatusCode.deadlineExceeded,
        'no response within ${pending.timeout}',
      ),
    );
    _trySend(
      TalkFrame(
        kind: TalkKind.abort,
        requestId: pending.id,
        payload: Status.of(StatusCode.cancelled, 'deadline exceeded').encode(),
      ),
    );
  }

  void _cancelOutgoing(_Outgoing pending, Status status) {
    if (!identical(_outgoing[pending.id], pending) || pending.abandoned) {
      return;
    }
    final payload = status.encode();
    pending.abandoned = true;
    _trySend(
      TalkFrame(kind: TalkKind.abort, requestId: pending.id, payload: payload),
    );
    pending.fail(SwitchboardException(status));
    // Keep the id until the peer's final response arrives, or on timeout.
    _armRequestTimer(pending);
  }

  // ---------------------------------------------------------------------
  // Responder side

  /// Starts tracking the peer's request carried by [message]. Returns false
  /// if it was rejected (over [TalkOptions.maxIncomingRequests]), in which
  /// case the abort was sent and [message] is marked as answered.
  bool _register(_Message message) {
    final id = message.requestId;
    final existing = _incoming[id];
    if (existing != null) {
      // The peer may reuse an id after its own timeout released it.
      _log.warning(
        'peer reused request id $id while it was outstanding; '
        'abandoning the earlier request',
      );
      _incoming.remove(id);
      existing._abandon();
    }
    final max = options.maxIncomingRequests;
    if (max > 0 && _incoming.length >= max) {
      _log.warning('incoming request limit $max reached, rejecting $id');
      _rejectRequest(
        id,
        Status.of(
          StatusCode.resourceExhausted,
          'too many outstanding requests',
        ),
      );
      message._finished = true;
      return false;
    }
    _incoming[id] = message;
    message._restartTimer();
    return true;
  }

  void _release(_Message message) {
    if (identical(_incoming[message.requestId], message)) {
      _incoming.remove(message.requestId);
    }
  }

  void _deliverMessage(_Message message) {
    if (_messagesCancelled) {
      _log.fine('no message listener, dropping ${message.frame}');
      message._abortQuietly(
        Status.of(StatusCode.unimplemented, 'no message listener'),
      );
      return;
    }
    _messages.add(message);
  }

  // ---------------------------------------------------------------------
  // Receiving

  void _onData(Uint8List data) {
    if (_closing) {
      return;
    }
    final TalkFrame frame;
    try {
      frame = TalkFrame.decode(data);
    } on ProtocolException catch (e) {
      _protocolError(e.status.reason);
      return;
    }
    switch (frame.kind) {
      case TalkKind.message:
        _onMessage(frame);
      case TalkKind.streamItem:
        _onStreamItem(frame);
      case TalkKind.abort:
        _onAbort(frame);
      case TalkKind.extend:
        _onExtend(frame);
    }
  }

  void _onMessage(TalkFrame frame) {
    if (!frame.hasResponse) {
      final message = _Message(this, frame);
      if (frame.hasRequest && !_register(message)) {
        return;
      }
      _deliverMessage(message);
      return;
    }
    final pending = _outgoing[frame.responseId];
    if (pending == null) {
      _unknownResponse(frame);
      return;
    }
    _outgoing.remove(pending.id);
    pending.stopTimer();
    if (pending.abandoned) {
      if (frame.hasRequest) {
        _rejectRequest(
          frame.requestId,
          Status.of(StatusCode.cancelled, 'request ${pending.id} cancelled'),
        );
      }
      return;
    }
    final message = _Message(this, frame);
    if (frame.hasRequest) {
      _register(message);
    }
    pending.complete(message);
  }

  void _onStreamItem(TalkFrame frame) {
    final pending = _outgoing[frame.responseId];
    if (pending == null) {
      _unknownResponse(frame);
      return;
    }
    if (pending.abandoned) {
      if (frame.hasRequest) {
        _rejectRequest(
          frame.requestId,
          Status.of(StatusCode.cancelled, 'request ${pending.id} cancelled'),
        );
      }
      return;
    }
    if (!pending.isStream) {
      _protocolError('STREAM_ITEM for non-stream request ${pending.id}');
      return;
    }
    _armRequestTimer(pending);
    final message = _Message(this, frame);
    if (frame.hasRequest) {
      _register(message);
    }
    if (pending.itemsCancelled) {
      message._abortQuietly(
        Status.of(StatusCode.cancelled, 'stream items not listened'),
      );
      return;
    }
    pending.items!.add(message);
  }

  void _onAbort(TalkFrame frame) {
    if (frame.hasResponse) {
      final pending = _outgoing.remove(frame.responseId);
      if (pending == null) {
        _log.fine('abort for unknown request ${frame.responseId} ignored');
        return;
      }
      pending.stopTimer();
      if (!pending.abandoned) {
        pending.fail(SwitchboardException(frame.status));
      }
    } else if (frame.hasRequest) {
      final message = _incoming[frame.requestId];
      if (message == null) {
        _log.fine('cancel for unknown request ${frame.requestId} ignored');
        return;
      }
      message._markCancelled();
    } else {
      final status = frame.status;
      _log.info('peer aborted the channel: $status');
      _endStatus ??= status;
      _terminate(status, messagesError: SwitchboardException(status));
      unawaited(close(status));
    }
  }

  void _onExtend(TalkFrame frame) {
    final pending = _outgoing[frame.responseId];
    if (pending == null || pending.abandoned) {
      return;
    }
    _armRequestTimer(pending);
  }

  void _unknownResponse(TalkFrame frame) {
    _log.fine('response for unknown request ${frame.responseId} ignored');
    if (frame.hasRequest) {
      _rejectRequest(
        frame.requestId,
        Status.of(
          StatusCode.notFound,
          'unknown response id ${frame.responseId}',
        ),
      );
    }
  }

  void _protocolError(String reason) {
    _log.warning('talk protocol error: $reason');
    unawaited(close(Status.of(StatusCode.protocolError, reason)));
  }

  void _onError(Object error, StackTrace stackTrace) {
    if (_closing) {
      return;
    }
    _log.warning('raw channel failed', error, stackTrace);
    final status = error is SwitchboardException
        ? error.status
        : Status.of(StatusCode.connectionLost, '$error');
    unawaited(close(status));
  }

  void _onDone() {
    _rawEnded = true;
    if (_closing) {
      return;
    }
    _closing = true;
    unawaited(_peerEnded());
  }

  Future<void> _peerEnded() async {
    var status = Status.of(StatusCode.connectionLost, 'channel closed');
    final r = raw;
    if (r is StatusClosable) {
      try {
        final end = await (r as StatusClosable).done;
        if (!end.isOk) {
          status = end;
        }
      } catch (e, st) {
        _log.fine('raw channel done failed', e, st);
      }
    } else {
      r.sink.close().ignore();
    }
    _terminate(status);
    await _finish();
  }

  // ---------------------------------------------------------------------
  // Shutdown

  /// Stops all timers, fails outstanding outgoing requests with
  /// [failStatus], abandons outstanding incoming requests, and ends
  /// [messages]. Idempotent.
  void _terminate(Status failStatus, {SwitchboardException? messagesError}) {
    _closing = true;
    if (_terminated) {
      return;
    }
    _terminated = true;
    final error = SwitchboardException(failStatus);
    final outgoing = _outgoing.values.toList();
    _outgoing.clear();
    for (final pending in outgoing) {
      if (pending.abandoned) {
        pending.stopTimer();
      } else {
        pending.fail(error);
      }
    }
    final incoming = _incoming.values.toList();
    _incoming.clear();
    for (final message in incoming) {
      message._abandon();
    }
    if (messagesError != null) {
      _messages.addError(messagesError);
    }
    _messages.close().ignore();
  }

  Future<void> _finish() {
    if (!_finishing) {
      _finishing = true;
      unawaited(_completeDone());
    }
    return _done.future;
  }

  Future<void> _completeDone() async {
    var status = _endStatus;
    if (status == null) {
      final r = raw;
      if (r is StatusClosable) {
        try {
          status = await (r as StatusClosable).done;
        } catch (e) {
          status = Status.of(StatusCode.connectionLost, '$e');
        }
      } else {
        status = Status.ok;
      }
    }
    _done.complete(status);
  }

  /// Mux CLOSE must not carry application codes.
  static Status _wireStatus(Status status) {
    if (!status.isApplicationCode) {
      return status;
    }
    final reason = status.reason.isEmpty ? '' : ': ${status.reason}';
    return Status.of(
      StatusCode.unknown,
      'application status ${status.code}$reason',
    );
  }
}

/// One of our outstanding requests.
class _Outgoing {
  _Outgoing(this.id, this.timeout, {required bool stream})
    : items = stream ? StreamController<TalkMessage>() : null {
    if (stream) {
      items!.onCancel = () => itemsCancelled = true;
      // TalkStream.done may legitimately go unobserved.
      completer.future.ignore();
    }
  }

  final int id;
  final Duration timeout;
  final StreamController<TalkMessage>? items;
  final Completer<TalkMessage> completer = Completer<TalkMessage>();
  Timer? timer;

  /// Cancelled locally; the id stays reserved until the final arrives.
  bool abandoned = false;
  bool itemsCancelled = false;

  bool get isStream => items != null;

  void stopTimer() {
    timer?.cancel();
    timer = null;
  }

  void complete(TalkMessage message) {
    stopTimer();
    items?.close().ignore();
    completer.complete(message);
  }

  void fail(SwitchboardException error) {
    stopTimer();
    if (!completer.isCompleted) {
      completer.completeError(error);
    }
    final items = this.items;
    if (items != null && !items.isClosed) {
      items.addError(error);
      items.close().ignore();
    }
  }
}

class _TalkStream extends TalkStream {
  _TalkStream(this._channel, this._pending)
    : items = _GuardedStream(_pending.items!.stream);

  final TalkChannel _channel;
  final _Outgoing _pending;

  @override
  final Stream<TalkMessage> items;

  @override
  int get requestId => _pending.id;

  @override
  Future<TalkMessage> get done => _pending.completer.future;

  @override
  void cancel([Status? status]) => _channel._cancelOutgoing(
    _pending,
    status ?? Status.of(StatusCode.cancelled),
  );
}

class _Message extends TalkMessage {
  _Message(this.channel, this.frame) : _finished = frame.requestId == 0;

  @override
  final TalkChannel channel;

  @override
  final TalkFrame frame;

  /// A final reply was sent, or the request can no longer be answered.
  bool _finished;
  bool _cancelled = false;
  Completer<void>? _cancelCompleter;
  Timer? _timer;

  @override
  bool get isCancelled => _cancelled;

  @override
  Future<void> get onCancel => (_cancelCompleter ??= Completer<void>()).future;

  @override
  bool get canReply => !_finished && channel.isOpen;

  void _check({bool item = false}) {
    if (!expectsReply) {
      throw SwitchboardException.of(
        StatusCode.failedPrecondition,
        'message expects no reply',
      );
    }
    if (!channel.isOpen) {
      throw SwitchboardException.of(
        StatusCode.failedPrecondition,
        'channel closed',
      );
    }
    if (_finished) {
      throw SwitchboardException.of(
        StatusCode.failedPrecondition,
        'request $requestId already answered',
      );
    }
    if (item && !expectsStream) {
      throw SwitchboardException.of(
        StatusCode.failedPrecondition,
        'request $requestId is not a stream request',
      );
    }
  }

  static Name? _name(String? procedure) =>
      procedure == null ? null : Name(procedure);

  @override
  void reply(Uint8List payload, {String? procedure}) {
    _check();
    channel._sendChecked(
      TalkFrame(
        kind: TalkKind.message,
        procedure: _name(procedure),
        responseId: requestId,
        payload: payload,
      ),
    );
    _finish();
  }

  @override
  Future<TalkMessage> replyRequest(
    Uint8List payload, {
    String? procedure,
    Duration? timeout,
  }) {
    _check();
    final name = _name(procedure);
    final pending = channel._startRequest(
      stream: false,
      timeout: timeout,
      build: (id) => TalkFrame(
        kind: TalkKind.message,
        procedure: name,
        requestId: id,
        responseId: requestId,
        payload: payload,
      ),
    );
    _finish();
    return pending.completer.future;
  }

  @override
  TalkStream replyStreamRequest(
    Uint8List payload, {
    String? procedure,
    Duration? timeout,
  }) {
    _check();
    final name = _name(procedure);
    final pending = channel._startRequest(
      stream: true,
      timeout: timeout,
      build: (id) => TalkFrame(
        kind: TalkKind.message,
        procedure: name,
        requestId: id,
        responseId: requestId,
        stream: true,
        payload: payload,
      ),
    );
    _finish();
    return _TalkStream(channel, pending);
  }

  @override
  void replyItem(Uint8List payload, {String? procedure}) {
    _check(item: true);
    channel._sendChecked(
      TalkFrame(
        kind: TalkKind.streamItem,
        procedure: _name(procedure),
        responseId: requestId,
        payload: payload,
      ),
    );
    _restartTimer();
  }

  @override
  Future<TalkMessage> replyItemRequest(
    Uint8List payload, {
    String? procedure,
    Duration? timeout,
  }) {
    _check(item: true);
    final name = _name(procedure);
    final pending = channel._startRequest(
      stream: false,
      timeout: timeout,
      build: (id) => TalkFrame(
        kind: TalkKind.streamItem,
        procedure: name,
        requestId: id,
        responseId: requestId,
        payload: payload,
      ),
    );
    _restartTimer();
    return pending.completer.future;
  }

  @override
  void replyAbort(Status status) {
    _check();
    channel._sendChecked(
      TalkFrame(
        kind: TalkKind.abort,
        responseId: requestId,
        payload: status.encode(),
      ),
    );
    _finish();
  }

  @override
  void extend() {
    _check();
    channel._sendChecked(
      TalkFrame(kind: TalkKind.extend, responseId: requestId),
    );
    _restartTimer();
  }

  void _restartTimer() {
    _timer?.cancel();
    _timer = null;
    final timeout = channel.options.replyTimeout;
    if (timeout > Duration.zero) {
      _timer = Timer(timeout, _onTimeout);
    }
  }

  void _onTimeout() {
    _timer = null;
    if (_finished) {
      return;
    }
    _log.fine('no reply to request $requestId, aborting');
    _abortQuietly(Status.of(StatusCode.deadlineExceeded, 'no reply in time'));
    _markCancelled();
  }

  /// Answers with an abort on the channel's behalf, if still unanswered.
  void _abortQuietly(Status status) {
    if (_finished || !expectsReply) {
      return;
    }
    channel._rejectRequest(requestId, status);
    _finish();
  }

  void _finish() {
    _finished = true;
    _timer?.cancel();
    _timer = null;
    channel._release(this);
  }

  void _markCancelled() {
    if (_cancelled) {
      return;
    }
    _cancelled = true;
    (_cancelCompleter ??= Completer<void>()).complete();
  }

  /// The request can no longer be answered (channel closed or id reused).
  void _abandon() {
    _finished = true;
    _timer?.cancel();
    _timer = null;
    _markCancelled();
  }
}

/// A message stream whose direct listener is guarded: a synchronous
/// exception in `onData` is logged and an unanswered request is aborted
/// with `INTERNAL`.
class _GuardedStream extends Stream<TalkMessage> {
  _GuardedStream(this._source);

  final Stream<TalkMessage> _source;

  @override
  StreamSubscription<TalkMessage> listen(
    void Function(TalkMessage event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return _GuardedSubscription(
      _source.listen(
        null,
        onError: onError,
        onDone: onDone,
        cancelOnError: cancelOnError,
      ),
    )..onData(onData);
  }
}

class _GuardedSubscription extends DelegatingStreamSubscription<TalkMessage> {
  _GuardedSubscription(super.sourceSubscription);

  @override
  void onData(void Function(TalkMessage data)? handleData) {
    if (handleData == null) {
      super.onData(null);
      return;
    }
    super.onData((message) {
      try {
        handleData(message);
      } catch (e, st) {
        _log.severe('message handler threw on ${message.procedureName}', e, st);
        if (message is _Message) {
          message._abortQuietly(
            Status.of(StatusCode.internal, 'message handler failed'),
          );
        }
      }
    });
  }
}
