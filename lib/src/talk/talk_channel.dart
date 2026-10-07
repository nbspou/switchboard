/*
Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Author: Jan Boon <jan.boon@kaetemi.be>
*/

import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:async/async.dart' show DelegatingStreamSubscription;
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:stream_channel/stream_channel.dart';

import '../monotonic.dart';
import '../name.dart';
import '../status.dart';
import '../status_closable.dart';
import 'talk_frame.dart';
import 'talk_message.dart';
import 'talk_request.dart';
import 'talk_stream.dart';

export '../status_closable.dart';

part 'talk_forward.dart';

final Logger _log = Logger('Switchboard.Talk');

/// Per-channel Talk policy.
class TalkOptions {
  /// Creates options; the defaults are the reference defaults of the wiki.
  const TalkOptions({
    this.requestTimeout = const Duration(seconds: 15),
    this.replyTimeout = const Duration(seconds: 10),
    this.maxIncomingRequests = 1024,
    this.maxOutgoingRequests = 1024,
    this.minExtension = const Duration(seconds: 1),
    this.maxExtension = const Duration(hours: 1),
    this.extendBuffer = const Duration(seconds: 5),
  });

  /// Requester side: the default timeout of a request, a gap restarted by
  /// every stream item and `EXTEND`, until the peer declares a deadline or
  /// a renewal with `EXTEND` (see [TalkRequest.deadline]). Overridable per
  /// request. [Duration.zero] disables the timeout, declared deadlines
  /// included.
  final Duration requestTimeout;

  /// Responder side: how long the application has to call a reply method,
  /// restarted by [TalkMessage.replyItem] and an empty
  /// [TalkMessage.extend], until the application declares a deadline or a
  /// renewal with [TalkMessage.extend]. On expiry the channel sends
  /// `ABORT DEADLINE_EXCEEDED` on the application's behalf. Overridable per
  /// request with [TalkMessage.setReplyTimeout]. [Duration.zero] disables
  /// the timeout, declared deadlines included.
  final Duration replyTimeout;

  /// Outstanding incoming requests beyond which a new request is answered
  /// with `ABORT RESOURCE_EXHAUSTED` immediately. 0 means unlimited.
  final int maxIncomingRequests;

  /// Outstanding outgoing requests beyond which the request API throws
  /// [StatusCode.resourceExhausted] without sending anything. 0 means
  /// unlimited (the `u24` id space still applies).
  final int maxOutgoingRequests;

  /// Requester side: the shortest deadline or renewal the peer's `EXTEND`
  /// can declare; a shorter value is raised to it, so that a declaration
  /// cannot make a request fail sooner than an answer can travel.
  /// Default 1 s. [Duration.zero]: no floor.
  final Duration minExtension;

  /// Requester side: the longest deadline or renewal the peer's `EXTEND`
  /// can declare; a longer value is lowered to it. Default 1 hour.
  /// [Duration.zero]: no clamp.
  final Duration maxExtension;

  /// Responder side: added to the deadline and the renewal that
  /// [TalkMessage.extend] puts on the wire, but not to the responder's own
  /// timeout, so that the responder gives up (and says so with
  /// `ABORT DEADLINE_EXCEEDED`) before the requester does, its answer
  /// having had the buffer to arrive. Raise it on nodes whose requests
  /// cross proxy or relay hops. Default 5 s.
  final Duration extendBuffer;
}

/// A failure caused by the peer sending `ABORT`: an abort response to one
/// of our requests, or a channel abort. [status] is the peer's status (an
/// abort carrying OK or nothing reads as [StatusCode.unknown]).
///
/// Every other failure reported by [TalkChannel] is a plain
/// [SwitchboardException]: our own requester timeout, our own cancel, loss
/// or closing of the channel, a protocol error, a local limit. The
/// distinction matters to intermediaries, which pass on only what the peer
/// said (see [forwardMessage]).
class TalkAbortException extends SwitchboardException {
  /// Creates the exception for an abort carrying [status].
  TalkAbortException(super.status, {this.isChannelAbort = false});

  /// True when the peer aborted the whole channel rather than answering
  /// one request with an abort.
  final bool isChannelAbort;

  @override
  String toString() =>
      'TalkAbortException: ${isChannelAbort ? 'channel abort, ' : ''}'
      '$status';
}

/// Talk message chains over one channel: plain messages, requests,
/// responses, stream responses, aborts, timeout extension and
/// cancellation. See the wiki page "Switchboard Talk". [forwardMessage]
/// forwards message chains between channels.
///
/// Works over a mux channel or any `StreamChannel<Uint8List>` whose events
/// are whole Talk messages.
///
/// Delivery order: [messages] delivers incoming plain messages and
/// requests in wire order, and [TalkStream.items] the items of a stream
/// request, but the answers to our requests complete futures of their own,
/// so an answer can be seen before messages that arrived ahead of it. A
/// request started with `ordered: true` has its answer delivered in wire
/// order with [messages] instead (see [startRequest]).
///
/// Failure handling:
///
/// * A malformed frame or a violation of the kind rules from the peer
///   closes the channel with [StatusCode.protocolError]; outstanding
///   requests fail with it.
/// * A channel abort from the peer closes the channel with the peer's
///   status; [messages] emits it as a [TalkAbortException], then ends, and
///   outstanding requests fail with the same exception.
/// * When the raw stream ends, outstanding requests fail with the raw
///   channel's end status ([StatusClosable.done]) if it is not OK, else
///   with [StatusCode.connectionLost].
/// * [StatusCode.connectionLost] is local only: wherever it would be sent
///   (an abort, a cancel, the close of a [StatusClosable] raw channel) it
///   goes on the wire as [StatusCode.unavailable].
/// * Exceptions thrown by application listeners never affect the channel.
///   If a listener of [messages] or [TalkStream.items] throws synchronously
///   while handling a request it has not yet answered, the exception is
///   logged and the request is answered with `ABORT INTERNAL`. Exceptions
///   in asynchronous code (for example the body of an `await for`) cannot
///   be seen by the channel; such a request is answered by the responder
///   timeout.
/// * Error events on [messages] and [TalkStream.items] whose listener has
///   no `onError` handler are logged, never reported as unhandled. Futures
///   returned by the request API never report unhandled errors either.
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
      StreamController<TalkMessage>(onCancel: _onMessagesCancelled);

  /// Requests added to [_messages] and not yet handed to its listener.
  final Queue<_Message> _undeliveredRequests = Queue<_Message>();

  /// Markers carrying the outcome of an `ordered` request, added to
  /// [_messages] and not yet handed to its listener.
  final Queue<_Message> _orderedOutcomes = Queue<_Message>();

  /// Incoming plain messages and requests, in arrival order. Responses
  /// never appear here. Single subscription; buffered until listened.
  ///
  /// A channel abort from the peer is delivered as an error event (a
  /// [TalkAbortException] carrying its status) and then the stream ends;
  /// without an `onError` handler the error is only logged. The stream also
  /// ends, without an error, when the channel closes for any other reason;
  /// [done] has the status.
  ///
  /// If the subscription is cancelled, buffered requests that were never
  /// delivered and every later request are answered with
  /// `ABORT UNIMPLEMENTED`.
  late final Stream<TalkMessage> messages = _GuardedStream(
    _messages.stream,
    _undeliveredRequests,
  );

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
  Future<void>? _peerEndedFuture;
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
  /// [name], when given, is the procedure instead of [procedure], which is
  /// then ignored: generated code passes the exact wire name (a [Name]
  /// need not be valid UTF-8, so a string cannot always stand for it).
  ///
  /// Throws [SwitchboardException] with [StatusCode.failedPrecondition] if
  /// the channel is closed, and [ArgumentError] if [procedure] is not a
  /// valid name.
  void send(String procedure, Uint8List payload, {Name? name}) =>
      _send(name ?? Name(procedure), payload);

  void _send(Name procedure, Uint8List payload) {
    _sendChecked(
      TalkFrame(kind: TalkKind.message, procedure: procedure, payload: payload),
    );
  }

  /// Sends a request and returns the final response. Shorthand for
  /// [startRequest] followed by [TalkRequest.response].
  ///
  /// The future fails like [TalkRequest.response]: with a
  /// [TalkAbortException] carrying the peer's abort status, or with a plain
  /// [SwitchboardException] carrying [StatusCode.deadlineExceeded] if
  /// nothing arrives within [timeout] (a cancel is then sent to the peer)
  /// or the channel's failure status. It never reports an unhandled error,
  /// so it may be dropped.
  ///
  /// Throws synchronously like [startRequest]. [name] and [ordered] as for
  /// [startRequest].
  Future<TalkMessage> request(
    String procedure,
    Uint8List payload, {
    Duration? timeout,
    Name? name,
    bool ordered = false,
  }) => startRequest(
    procedure,
    payload,
    timeout: timeout,
    name: name,
    ordered: ordered,
  ).response;

  /// Sends a request and returns its handle, through which the response
  /// arrives and the request can be cancelled.
  ///
  /// [timeout] is the requester timeout, a gap restarted by every `EXTEND`
  /// until the peer declares a deadline or a renewal (see
  /// [TalkRequest.deadline]); it defaults to [TalkOptions.requestTimeout]
  /// and [Duration.zero] disables it. [onExtend] is called synchronously
  /// each time the peer sends `EXTEND` for the request, with the deadline
  /// and the renewal as received (null for a field that is 0, both null for
  /// an empty `EXTEND`), before [TalkOptions.minExtension] and
  /// [TalkOptions.maxExtension] apply; exceptions it throws are logged.
  ///
  /// [name], when given, is the procedure instead of [procedure], as for
  /// [send].
  ///
  /// With [ordered], the peer's answer (its final response or its abort)
  /// is delivered in wire order with [messages]: [TalkRequest.response]
  /// completes only once every plain message and request that arrived
  /// before the answer has been handed to the listener of [messages], and
  /// code waiting on [TalkRequest.response] runs before the messages that
  /// arrived after it. Use it when the peer sends one-way messages that
  /// the answer marks a point in, such as the snapshot that precedes the
  /// reply to a subscription. If nobody listens to [messages] yet, or its
  /// subscription was cancelled, the answer is delivered at once. While
  /// the subscription is paused the answer waits, so the body of an
  /// `await for` loop over [messages] must not wait for an ordered
  /// request. Local failures (timeout, [TalkRequest.cancel], the end of
  /// the channel) are reported at once.
  ///
  /// Throws synchronously, sending nothing, with
  /// [StatusCode.resourceExhausted] if [TalkOptions.maxOutgoingRequests] is
  /// reached, with [StatusCode.failedPrecondition] if the channel is
  /// closed, and [ArgumentError] if [procedure] is not a valid name.
  TalkRequest startRequest(
    String procedure,
    Uint8List payload, {
    Duration? timeout,
    void Function(Duration? deadline, Duration? renew)? onExtend,
    Name? name,
    bool ordered = false,
  }) {
    final wire = name ?? Name(procedure);
    return _TalkRequest(
      _startRequest(
        stream: false,
        timeout: timeout,
        onExtend: onExtend,
        ordered: ordered,
        build: (id) => TalkFrame(
          kind: TalkKind.message,
          procedure: wire,
          requestId: id,
          payload: payload,
        ),
      ),
    );
  }

  /// Sends a stream request. Items and the final response arrive through
  /// the returned [TalkStream]. Takes and throws like [startRequest]; the
  /// requester timeout is also restarted by every item (and, once the peer
  /// declared a renewal, renewed by every item).
  TalkStream streamRequest(
    String procedure,
    Uint8List payload, {
    Duration? timeout,
    void Function(Duration? deadline, Duration? renew)? onExtend,
    Name? name,
  }) {
    final wire = name ?? Name(procedure);
    return _TalkStream(
      _startRequest(
        stream: true,
        timeout: timeout,
        onExtend: onExtend,
        build: (id) => TalkFrame(
          kind: TalkKind.message,
          procedure: wire,
          requestId: id,
          stream: true,
          payload: payload,
        ),
      ),
    );
  }

  /// Sends a channel abort carrying [status], then closes the channel with
  /// it. Application codes are allowed in the abort; on a [StatusClosable]
  /// channel they are reported as [StatusCode.unknown] in the close, since
  /// mux CLOSE must not carry them. [StatusCode.connectionLost] goes on the
  /// wire as [StatusCode.unavailable]. Does nothing if already closing.
  ///
  /// Throws [ArgumentError] if [status] is OK: an abort cannot report
  /// success; use [close] instead.
  void abort(Status status) {
    _checkAbortStatus(status);
    if (_closing) {
      return;
    }
    final payload = _wireAbortStatus(status).encode();
    _trySend(TalkFrame(kind: TalkKind.abort, payload: payload));
    unawaited(close(status));
  }

  /// Closes the channel. Outstanding outgoing requests fail with [status],
  /// or with [StatusCode.cancelled] if [status] is OK; outstanding incoming
  /// requests become unanswerable and are marked cancelled. A
  /// [StatusClosable] raw channel is closed with [status], any other raw
  /// channel by closing its sink.
  ///
  /// If the raw channel had already ended, nothing is sent and the raw
  /// channel's end status applies instead of [status].
  ///
  /// Completes when [done] completes. Calling it again returns the same
  /// future.
  Future<void> close([Status status = Status.ok]) =>
      _closeFuture ??= _close(status);

  Future<void> _close(Status status) async {
    final peerEnded = _peerEndedFuture;
    if (peerEnded != null) {
      // The raw stream ended first; its end status is what outstanding
      // requests fail with, once known.
      await peerEnded;
      return _finish();
    }
    if (!status.isOk) {
      _endStatus ??= status;
    }
    _terminate(
      SwitchboardException(
        status.isOk
            ? Status.of(StatusCode.cancelled, 'channel closed')
            : status,
      ),
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
  /// local state.
  void _rejectRequest(int requestId, Status status) {
    _trySend(
      TalkFrame(
        kind: TalkKind.abort,
        responseId: requestId,
        payload: _wireAbortStatus(status).encode(),
      ),
    );
  }

  _Outgoing _startRequest({
    required bool stream,
    required Duration? timeout,
    required TalkFrame Function(int id) build,
    void Function(Duration? deadline, Duration? renew)? onExtend,
    _ResponseSink? sink,
    bool ordered = false,
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
    final frame = build(id);
    final pending = _Outgoing(
      this,
      id,
      timeout ?? options.requestTimeout,
      stream: stream,
      onExtend: onExtend,
      sink: sink,
      ordered: ordered,
    );
    // Registered before sending: over a synchronous transport the response
    // can arrive while the request is still being sent.
    _outgoing[id] = pending;
    _nextRequestId = id >= TalkFrame.maxId ? 1 : id + 1;
    pending.startTimer();
    try {
      _sendChecked(frame);
    } catch (_) {
      if (identical(_outgoing[id], pending)) {
        _outgoing.remove(id);
      }
      pending.stopTimer();
      rethrow;
    }
    return pending;
  }

  // ---------------------------------------------------------------------
  // Requester side

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
    final reason = pending.expiry.declared
        ? 'no response by the deadline the peer declared'
        : 'no response within ${pending.timeout}';
    _log.fine('request ${pending.id} timed out: $reason');
    pending.fail(SwitchboardException.of(StatusCode.deadlineExceeded, reason));
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
    pending.abandoned = true;
    _trySend(
      TalkFrame(
        kind: TalkKind.abort,
        requestId: pending.id,
        payload: _wireAbortStatus(status).encode(),
      ),
    );
    pending.fail(SwitchboardException(status));
    if (!identical(_outgoing[pending.id], pending)) {
      // Over a synchronous transport the final can arrive during the send.
      return;
    }
    // Keep the id until the peer's final response arrives, or on timeout.
    // A request without a timeout of its own falls back to the channel
    // default here, so a peer that never answers the cancel cannot hold the
    // id for ever.
    pending.armRelease(
      pending.timeout > Duration.zero
          ? pending.timeout
          : options.requestTimeout,
    );
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
    message._startTimer();
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
    if (message.expectsReply) {
      _undeliveredRequests.add(message);
    }
    _messages.add(message);
  }

  void _onMessagesCancelled() {
    _messagesCancelled = true;
    final undelivered = _undeliveredRequests.toList();
    _undeliveredRequests.clear();
    for (final message in undelivered) {
      message._abortQuietly(
        Status.of(StatusCode.unimplemented, 'no message listener'),
      );
    }
    // Nothing is delivered any more: the waiting answers go at once.
    final outcomes = _orderedOutcomes.toList();
    _orderedOutcomes.clear();
    for (final marker in outcomes) {
      marker._runOutcome();
    }
  }

  /// Delivers the answer to an `ordered` request: [outcome] runs once
  /// [marker] reaches the listener of [messages], after the messages that
  /// arrived before it; the listener never sees [marker]. At once when
  /// nobody listens, or nobody will.
  void _deliverOrdered(_Message marker, void Function() outcome) {
    if (_messagesCancelled || !_messages.hasListener || _messages.isClosed) {
      outcome();
      return;
    }
    marker._outcome = outcome;
    _orderedOutcomes.add(marker);
    _messages.add(marker);
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
    if (pending.ordered) {
      _deliverOrdered(message, () => pending.complete(message));
    } else {
      pending.complete(message);
    }
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
    pending.replied();
    final message = _Message(this, frame);
    if (frame.hasRequest) {
      _register(message);
    }
    pending.addItem(message);
  }

  void _onAbort(TalkFrame frame) {
    if (frame.hasResponse) {
      final pending = _outgoing.remove(frame.responseId);
      if (pending == null) {
        _log.fine('abort for unknown request ${frame.responseId} ignored');
        return;
      }
      pending.stopTimer();
      if (pending.abandoned) {
        return;
      }
      final error = TalkAbortException(_abortStatus(frame));
      if (pending.ordered) {
        _deliverOrdered(_Message(this, frame), () => pending.fail(error));
      } else {
        pending.fail(error);
      }
    } else if (frame.hasRequest) {
      final message = _incoming[frame.requestId];
      if (message == null) {
        _log.fine('cancel for unknown request ${frame.requestId} ignored');
        return;
      }
      message._cancelledByPeer(frame.status);
    } else {
      final status = _abortStatus(frame);
      _log.info('peer aborted the channel: $status');
      _endStatus ??= status;
      final error = TalkAbortException(status, isChannelAbort: true);
      _terminate(error, reportOnMessages: true);
      unawaited(close(status));
    }
  }

  void _onExtend(TalkFrame frame) {
    final pending = _outgoing[frame.responseId];
    if (pending == null || pending.abandoned) {
      return;
    }
    pending.extended(frame);
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
    _peerEndedFuture = _peerEnded();
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
    _terminate(SwitchboardException(status));
    await _finish();
  }

  // ---------------------------------------------------------------------
  // Shutdown

  /// Stops all timers, fails outstanding outgoing requests with [error],
  /// abandons outstanding incoming requests, and ends [messages], after
  /// emitting [error] on it if [reportOnMessages]. Idempotent.
  void _terminate(SwitchboardException error, {bool reportOnMessages = false}) {
    _closing = true;
    if (_terminated) {
      return;
    }
    _terminated = true;
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
    _undeliveredRequests.clear();
    for (final message in incoming) {
      message._abandon();
    }
    if (reportOnMessages) {
      _messages.addError(error);
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

  /// The status of a received abort; an abort cannot report success, so OK
  /// reads as UNKNOWN.
  static Status _abortStatus(TalkFrame frame) {
    final status = frame.status;
    return status.isOk
        ? Status(StatusCode.unknown.code, status.reason)
        : status;
  }

  static void _checkAbortStatus(Status status) {
    if (status.isOk) {
      throw ArgumentError.value(
        status,
        'status',
        'an abort cannot report success',
      );
    }
  }

  /// CONNECTION_LOST is local only; on the wire it is UNAVAILABLE.
  static Status _wireAbortStatus(Status status) {
    if (status.code != StatusCode.connectionLost.code) {
      return status;
    }
    final reason = status.reason.isEmpty ? '' : ': ${status.reason}';
    return Status.of(StatusCode.unavailable, 'connection lost$reason');
  }

  /// Mux CLOSE must not carry application codes, nor CONNECTION_LOST.
  static Status _wireStatus(Status status) {
    if (!status.isApplicationCode) {
      return _wireAbortStatus(status);
    }
    final reason = status.reason.isEmpty ? '' : ': ${status.reason}';
    return Status.of(
      StatusCode.unknown,
      'application status ${status.code}$reason',
    );
  }
}

/// Receives the responses to an outgoing request synchronously, in wire
/// order, instead of through a [TalkStream] or future. Used by forwarding.
abstract interface class _ResponseSink {
  /// A stream item arrived.
  void item(_Message item);

  /// The final response arrived.
  void complete(_Message message);

  /// The request failed, for any reason.
  void fail(SwitchboardException error);

  /// The peer sent `EXTEND` carrying [payload].
  void extended(Uint8List payload);
}

/// The timeout of one request, on either side: a gap restarted by every
/// reply (the default regime) until a deadline or a renewal is declared,
/// then the later of the declared deadline and the last reply plus the
/// renewal. Instants are [monotonicNow] values.
class _Expiry {
  _Expiry(this.gap);

  /// The default gap; [Duration.zero] for no timeout at all.
  Duration gap;

  /// A deadline or a renewal was declared.
  bool declared = false;

  /// The end of the default gap; in the declared regime, set only by an
  /// empty `EXTEND`.
  Duration? gapEnd;

  /// The declared deadline.
  Duration? deadline;

  /// The declared renewal, counted from [lastReply].
  Duration? renew;

  /// The last reply: stream item or `EXTEND`.
  Duration lastReply = Duration.zero;

  /// Back to the default regime, the gap counted from [now].
  void start(Duration now) {
    declared = false;
    deadline = null;
    renew = null;
    lastReply = now;
    gapEnd = now + gap;
  }

  /// A reply at [now]: restarts the gap, or renews by the declared
  /// renewal.
  void reply(Duration now) {
    lastReply = now;
    if (!declared) {
      gapEnd = now + gap;
    }
  }

  /// An empty `EXTEND` at [now]: restarts the gap, keeping what was
  /// declared.
  void restartGap(Duration now) {
    lastReply = now;
    gapEnd = now + gap;
  }

  /// An `EXTEND` declaring [deadline] from [now] and [renew]; a null value
  /// leaves that one unchanged. Replaces what was declared before, and
  /// the gap.
  void declare(Duration now, Duration? deadline, Duration? renew) {
    if (deadline == null && renew == null) {
      reply(now);
      return;
    }
    lastReply = now;
    declared = true;
    gapEnd = null;
    if (deadline != null) {
      this.deadline = now + deadline;
    }
    if (renew != null) {
      this.renew = renew;
    }
  }

  /// When the request times out; null for never.
  Duration? get end {
    if (gap <= Duration.zero) {
      return null;
    }
    final renew = this.renew;
    return _later(
      _later(gapEnd, deadline),
      renew == null ? null : lastReply + renew,
    );
  }

  static Duration? _later(Duration? a, Duration? b) =>
      a == null ? b : (b == null || a >= b ? a : b);
}

/// One of our outstanding requests.
class _Outgoing {
  _Outgoing(
    this.channel,
    this.id,
    this.timeout, {
    required bool stream,
    this.onExtend,
    this.sink,
    this.ordered = false,
  }) : isStream = stream,
       expiry = _Expiry(timeout),
       items = stream && sink == null ? StreamController<TalkMessage>() : null {
    items?.onCancel = _onItemsCancelled;
    // A dropped request future must never surface as an unhandled error.
    completer.future.ignore();
  }

  final TalkChannel channel;
  final int id;
  final Duration timeout;
  final bool isStream;
  final void Function(Duration? deadline, Duration? renew)? onExtend;
  final _ResponseSink? sink;
  final StreamController<TalkMessage>? items;

  /// The answer is delivered in order with [TalkChannel.messages].
  final bool ordered;

  /// Item requests added to [items] and not yet handed to its listener.
  final Queue<_Message> undeliveredItems = Queue<_Message>();
  final Completer<TalkMessage> completer = Completer<TalkMessage>();
  Timer? timer;

  /// The requester timeout.
  final _Expiry expiry;

  /// Cancelled locally; the id stays reserved until the final arrives.
  bool abandoned = false;
  bool _failed = false;

  /// Answered, failed or cancelled.
  bool get ended => _failed || completer.isCompleted || abandoned;

  /// When the request times out, as wall clock time; null if it never
  /// does, or has ended.
  DateTime? get deadline {
    final end = timer == null || ended ? null : expiry.end;
    return end == null ? null : wallTimeOf(end);
  }

  void stopTimer() {
    timer?.cancel();
    timer = null;
  }

  /// Starts the requester timeout, in the default regime.
  void startTimer() {
    expiry.start(monotonicNow());
    _arm();
  }

  /// A stream item arrived.
  void replied() {
    expiry.reply(monotonicNow());
    _arm();
  }

  /// Keeps the id of a cancelled request for [duration] at most.
  void armRelease(Duration duration) {
    stopTimer();
    _armedEnd = null;
    if (duration > Duration.zero) {
      timer = Timer(duration, () => channel._onRequestTimeout(this));
    }
  }

  /// When [timer] fires, if it was armed by [_arm].
  Duration? _armedEnd;

  void _arm() {
    final end = expiry.end;
    if (end != null && end == _armedEnd && timer != null) {
      return;
    }
    stopTimer();
    _armedEnd = end;
    if (end == null) {
      return;
    }
    var left = end - monotonicNow();
    if (left.isNegative) {
      left = Duration.zero;
    }
    timer = Timer(left, () => channel._onRequestTimeout(this));
  }

  /// [value] within [TalkOptions.minExtension] and
  /// [TalkOptions.maxExtension].
  Duration? _bounded(Duration? value) {
    if (value == null) {
      return null;
    }
    final options = channel.options;
    if (options.minExtension > Duration.zero && value < options.minExtension) {
      value = options.minExtension;
    }
    if (options.maxExtension > Duration.zero && value > options.maxExtension) {
      value = options.maxExtension;
    }
    return value;
  }

  void addItem(_Message message) {
    final sink = this.sink;
    if (sink != null) {
      _guard(() => sink.item(message), 'forwarding an item');
      return;
    }
    if (message.expectsReply) {
      undeliveredItems.add(message);
    }
    items!.add(message);
  }

  void complete(_Message message) {
    stopTimer();
    final sink = this.sink;
    if (sink != null) {
      _guard(() => sink.complete(message), 'forwarding a response');
      return;
    }
    items?.close().ignore();
    completer.complete(message);
  }

  void fail(SwitchboardException error) {
    stopTimer();
    if (_failed) {
      return;
    }
    _failed = true;
    final sink = this.sink;
    if (sink != null) {
      _guard(() => sink.fail(error), 'forwarding a failure');
      return;
    }
    if (!completer.isCompleted) {
      completer.completeError(error);
    }
    final items = this.items;
    if (items != null && !items.isClosed) {
      items.addError(error);
      items.close().ignore();
    }
  }

  /// The peer sent [frame], an `EXTEND`.
  void extended(TalkFrame frame) {
    final (:deadline, :renew) = frame.extension;
    final now = monotonicNow();
    if (frame.payload.isEmpty) {
      expiry.restartGap(now);
    } else {
      expiry.declare(now, _bounded(deadline), _bounded(renew));
    }
    _arm();
    final sink = this.sink;
    if (sink != null) {
      _guard(() => sink.extended(frame.payload), 'forwarding EXTEND');
      return;
    }
    final callback = onExtend;
    if (callback != null) {
      _guard(
        () => callback(deadline, renew),
        'onExtend callback of request $id',
      );
    }
  }

  /// The [items] subscription was cancelled, or ended. Undelivered item
  /// requests are refused, and the request is cancelled if outstanding.
  void _onItemsCancelled() {
    final undelivered = undeliveredItems.toList();
    undeliveredItems.clear();
    for (final message in undelivered) {
      message._abortQuietly(
        Status.of(StatusCode.cancelled, 'stream items not listened'),
      );
    }
    channel._cancelOutgoing(
      this,
      Status.of(StatusCode.cancelled, 'items subscription cancelled'),
    );
  }

  static void _guard(void Function() action, String what) {
    try {
      action();
    } catch (e, st) {
      _log.severe('$what failed', e, st);
    }
  }
}

class _TalkRequest extends TalkRequest {
  _TalkRequest(this._pending);

  final _Outgoing _pending;

  @override
  int get requestId => _pending.id;

  @override
  Future<TalkMessage> get response => _pending.completer.future;

  @override
  DateTime? get deadline => _pending.deadline;

  @override
  void cancel([Status? status]) => _pending.channel._cancelOutgoing(
    _pending,
    status ?? Status.of(StatusCode.cancelled),
  );
}

class _TalkStream extends TalkStream {
  _TalkStream(this._pending)
    : items = _GuardedStream(_pending.items!.stream, _pending.undeliveredItems);

  final _Outgoing _pending;

  @override
  final Stream<TalkMessage> items;

  @override
  int get requestId => _pending.id;

  @override
  Future<TalkMessage> get done => _pending.completer.future;

  @override
  DateTime? get deadline => _pending.deadline;

  @override
  void cancel([Status? status]) => _pending.channel._cancelOutgoing(
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

  /// The responder timeout; created when the request is registered.
  _Expiry? _expiry;

  /// Responder timeout override; null means the channel default.
  Duration? _replyTimeout;

  /// The status of the peer's cancel, if the peer cancelled.
  Status? _cancelStatus;

  /// Called synchronously once when the request is cancelled.
  void Function()? _cancelHook;

  /// Set while this message is the marker of an `ordered` request's answer
  /// in [TalkChannel.messages]: delivers that answer.
  void Function()? _outcome;

  /// Delivers the answer this message is the marker of, once.
  void _runOutcome() {
    final outcome = _outcome;
    _outcome = null;
    outcome?.call();
  }

  /// [forwardMessage] took this request over.
  bool _forwarded = false;

  /// A reply to this request is being sent (see [_sendReply]).
  bool _sending = false;

  /// The reply being sent is the final one: the request counts as answered.
  bool _finalizing = false;

  /// The status of a peer cancel that arrived while a reply was being sent.
  Status? _heldCancel;

  @override
  bool get isCancelled => _cancelled;

  @override
  Future<void> get onCancel => (_cancelCompleter ??= Completer<void>()).future;

  @override
  bool get canReply => !_finished && !_finalizing && channel.isOpen;

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
    if (_finished || _finalizing) {
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

  static Name? _name(String? procedure, Name? name) =>
      name ?? (procedure == null ? null : Name(procedure));

  /// Sends a reply to this request with [send]: the final one if
  /// [isFinal], which finishes the request, else a stream item or an
  /// `EXTEND`. Returns what [send] returns.
  ///
  /// Over a synchronous transport the peer's frames can be handled while
  /// [send] is still sending, a cancel of this request among them. That
  /// cancel is held until [send] returns, then handled as if it had
  /// arrived just after: ignored if the final reply went out (a request has
  /// exactly one final response, and a cancel of an answered request is
  /// ignored), otherwise answered with `ABORT CANCELLED` as usual. Without
  /// such a cancel, a final reply that fails to send leaves the request
  /// answerable.
  T _sendReply<T>(T Function() send, {bool isFinal = false}) {
    // Forwarding can relay a reply while another one is being sent (never
    // within a final reply: [_check] refuses); the outermost send handles
    // a held cancel.
    final outer = _sending;
    _sending = true;
    _finalizing = isFinal;
    try {
      final result = send();
      if (isFinal) {
        _finish();
      }
      return result;
    } finally {
      _sending = outer;
      _finalizing = false;
      final cancel = outer ? null : _heldCancel;
      if (cancel != null) {
        _heldCancel = null;
        if (!_finished) {
          _cancelledByPeer(cancel);
        }
      }
    }
  }

  @override
  void reply(Uint8List payload, {String? procedure, Name? name}) =>
      _reply(payload, _name(procedure, name));

  void _reply(Uint8List payload, Name? procedure) {
    _check();
    _sendReply(
      () => channel._sendChecked(
        TalkFrame(
          kind: TalkKind.message,
          procedure: procedure,
          responseId: requestId,
          payload: payload,
        ),
      ),
      isFinal: true,
    );
  }

  @override
  Future<TalkMessage> replyRequest(
    Uint8List payload, {
    String? procedure,
    Duration? timeout,
    Name? name,
  }) => startReplyRequest(
    payload,
    procedure: procedure,
    timeout: timeout,
    name: name,
  ).response;

  @override
  TalkRequest startReplyRequest(
    Uint8List payload, {
    String? procedure,
    Duration? timeout,
    void Function(Duration? deadline, Duration? renew)? onExtend,
    Name? name,
  }) => _TalkRequest(
    _startReplyRequest(
      payload,
      _name(procedure, name),
      stream: false,
      timeout: timeout,
      onExtend: onExtend,
    ),
  );

  @override
  TalkStream replyStreamRequest(
    Uint8List payload, {
    String? procedure,
    Duration? timeout,
    void Function(Duration? deadline, Duration? renew)? onExtend,
    Name? name,
  }) => _TalkStream(
    _startReplyRequest(
      payload,
      _name(procedure, name),
      stream: true,
      timeout: timeout,
      onExtend: onExtend,
    ),
  );

  _Outgoing _startReplyRequest(
    Uint8List payload,
    Name? procedure, {
    required bool stream,
    required Duration? timeout,
    void Function(Duration? deadline, Duration? renew)? onExtend,
    _ResponseSink? sink,
  }) {
    _check();
    return _sendReply(
      () => channel._startRequest(
        stream: stream,
        timeout: timeout,
        onExtend: onExtend,
        sink: sink,
        build: (id) => TalkFrame(
          kind: TalkKind.message,
          procedure: procedure,
          requestId: id,
          responseId: requestId,
          stream: stream,
          payload: payload,
        ),
      ),
      isFinal: true,
    );
  }

  @override
  void replyItem(Uint8List payload, {String? procedure, Name? name}) =>
      _replyItem(payload, _name(procedure, name));

  void _replyItem(Uint8List payload, Name? procedure) {
    _check(item: true);
    _sendReply(
      () => channel._sendChecked(
        TalkFrame(
          kind: TalkKind.streamItem,
          procedure: procedure,
          responseId: requestId,
          payload: payload,
        ),
      ),
    );
    _replied();
  }

  @override
  Future<TalkMessage> replyItemRequest(
    Uint8List payload, {
    String? procedure,
    Duration? timeout,
    Name? name,
  }) => startReplyItemRequest(
    payload,
    procedure: procedure,
    timeout: timeout,
    name: name,
  ).response;

  @override
  TalkRequest startReplyItemRequest(
    Uint8List payload, {
    String? procedure,
    Duration? timeout,
    void Function(Duration? deadline, Duration? renew)? onExtend,
    Name? name,
  }) => _TalkRequest(
    _startItemRequest(
      payload,
      _name(procedure, name),
      stream: false,
      timeout: timeout,
      onExtend: onExtend,
    ),
  );

  @override
  TalkStream replyItemStreamRequest(
    Uint8List payload, {
    String? procedure,
    Duration? timeout,
    void Function(Duration? deadline, Duration? renew)? onExtend,
    Name? name,
  }) => _TalkStream(
    _startItemRequest(
      payload,
      _name(procedure, name),
      stream: true,
      timeout: timeout,
      onExtend: onExtend,
    ),
  );

  _Outgoing _startItemRequest(
    Uint8List payload,
    Name? procedure, {
    required bool stream,
    required Duration? timeout,
    void Function(Duration? deadline, Duration? renew)? onExtend,
    _ResponseSink? sink,
  }) {
    _check(item: true);
    final pending = _sendReply(
      () => channel._startRequest(
        stream: stream,
        timeout: timeout,
        onExtend: onExtend,
        sink: sink,
        build: (id) => TalkFrame(
          kind: TalkKind.streamItem,
          procedure: procedure,
          requestId: id,
          responseId: requestId,
          stream: stream,
          payload: payload,
        ),
      ),
    );
    _replied();
    return pending;
  }

  @override
  void replyAbort(Status status) {
    TalkChannel._checkAbortStatus(status);
    _replyAbort(status);
  }

  void _replyAbort(Status status) {
    _check();
    _sendReply(
      () => channel._sendChecked(
        TalkFrame(
          kind: TalkKind.abort,
          responseId: requestId,
          payload: TalkChannel._wireAbortStatus(status).encode(),
        ),
      ),
      isFinal: true,
    );
  }

  @override
  void extend({Duration? deadline, Duration? renew, Duration? buffer}) {
    for (final (name, value) in [
      ('deadline', deadline),
      ('renew', renew),
      ('buffer', buffer),
    ]) {
      if (value != null && value.isNegative) {
        throw ArgumentError.value(value, name, 'must not be negative');
      }
    }
    _check();
    final extra = buffer ?? channel.options.extendBuffer;
    // A field holds at most _maxExtend, buffer included. A longer value is
    // lowered so that the local timeout stays the buffer short of what the
    // requester is told: this responder still gives up first.
    final room = extra < _maxExtend ? _maxExtend - extra : Duration.zero;
    Duration? lowered(Duration? value) =>
        value == null || value <= room ? value : room;
    final localDeadline = lowered(deadline);
    final localRenew = lowered(renew);
    final frame = TalkFrame(
      kind: TalkKind.extend,
      responseId: requestId,
      payload: TalkFrame.extendPayload(
        deadline: localDeadline == null ? null : localDeadline + extra,
        renew: localRenew == null ? null : localRenew + extra,
      ),
    );
    _sendReply(() => channel._sendChecked(frame));
    final expiry = _expiry;
    if (expiry == null || _finished) {
      return;
    }
    final now = monotonicNow();
    if (localDeadline == null && localRenew == null) {
      expiry.restartGap(now);
    } else {
      expiry.declare(now, localDeadline, localRenew);
    }
    _arm();
  }

  /// The longest deadline or renewal an `EXTEND` field can carry.
  static const Duration _maxExtend = Duration(
    milliseconds: TalkFrame.maxExtendMillis,
  );

  /// Sends an `EXTEND` with [payload] as received from the far responder,
  /// for forwarding: buffers already on the wire stay as they are.
  void _extendRaw(Uint8List payload) {
    _check();
    final frame = TalkFrame(
      kind: TalkKind.extend,
      responseId: requestId,
      payload: payload,
    );
    _sendReply(() => channel._sendChecked(frame));
    final expiry = _expiry;
    if (expiry == null || _finished) {
      return;
    }
    final (:deadline, :renew) = frame.extension;
    final now = monotonicNow();
    if (payload.isEmpty) {
      expiry.restartGap(now);
    } else {
      expiry.declare(now, deadline, renew);
    }
    _arm();
  }

  @override
  void setReplyTimeout(Duration? timeout) {
    _replyTimeout = timeout;
    if (!_finished && expectsReply) {
      _startTimer();
    }
  }

  /// Starts the responder timeout, in the default regime.
  void _startTimer() {
    final expiry = _expiry ??= _Expiry(Duration.zero);
    expiry
      ..gap = _replyTimeout ?? channel.options.replyTimeout
      ..start(monotonicNow());
    _arm();
  }

  /// A stream item (possibly a request) was sent. Nothing to restart if
  /// the request ended meanwhile.
  void _replied() {
    final expiry = _expiry;
    if (expiry == null || _finished) {
      return;
    }
    expiry.reply(monotonicNow());
    _arm();
  }

  /// When [_timer] fires.
  Duration? _armedEnd;

  void _arm() {
    final end = _expiry?.end;
    if (end != null && end == _armedEnd && _timer != null) {
      return;
    }
    _timer?.cancel();
    _timer = null;
    _armedEnd = end;
    if (end == null) {
      return;
    }
    var left = end - monotonicNow();
    if (left.isNegative) {
      left = Duration.zero;
    }
    _timer = Timer(left, _onTimeout);
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
  /// Never while the final reply is being sent: that is the one final.
  void _abortQuietly(Status status) {
    if (_finished || _finalizing || !expectsReply) {
      return;
    }
    channel._rejectRequest(requestId, status);
    _finish();
  }

  /// The peer cancelled the request: answer it with the final the protocol
  /// requires, then tell the application. Held while a reply is being sent
  /// (see [_sendReply]).
  void _cancelledByPeer(Status status) {
    if (_sending) {
      _heldCancel ??= status;
      return;
    }
    _abortQuietly(Status.of(StatusCode.cancelled, 'cancelled by requester'));
    _markCancelled(status);
  }

  void _finish() {
    _finished = true;
    _timer?.cancel();
    _timer = null;
    channel._release(this);
  }

  void _markCancelled([Status? status]) {
    if (_cancelled) {
      return;
    }
    _cancelled = true;
    _cancelStatus = status;
    (_cancelCompleter ??= Completer<void>()).complete();
    final hook = _cancelHook;
    _cancelHook = null;
    if (hook != null) {
      try {
        hook();
      } catch (e, st) {
        _log.severe('cancel handling of request $requestId failed', e, st);
      }
    }
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
/// with `INTERNAL`; an error event without an `onError` handler is logged
/// instead of being reported as unhandled. Keeps the queue of undelivered
/// requests up to date as events reach the listener.
class _GuardedStream extends Stream<TalkMessage> {
  _GuardedStream(this._source, this._undelivered);

  final Stream<TalkMessage> _source;
  final Queue<_Message> _undelivered;

  @override
  StreamSubscription<TalkMessage> listen(
    void Function(TalkMessage event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return _GuardedSubscription(
        _source.listen(null, onDone: onDone, cancelOnError: cancelOnError),
        _undelivered,
      )
      ..onData(onData)
      ..onError(onError);
  }
}

class _GuardedSubscription extends DelegatingStreamSubscription<TalkMessage> {
  _GuardedSubscription(super.sourceSubscription, this._undelivered);

  final Queue<_Message> _undelivered;

  @override
  void onData(void Function(TalkMessage data)? handleData) {
    super.onData((message) {
      if (message is _Message && message._outcome != null) {
        // The answer to an ordered request, in its place among the
        // messages; never shown to the listener.
        final outcomes = message.channel._orderedOutcomes;
        if (outcomes.isNotEmpty && identical(outcomes.first, message)) {
          outcomes.removeFirst();
        } else {
          outcomes.remove(message);
        }
        message._runOutcome();
        return;
      }
      // Requests are queued, and delivered, in arrival order.
      if (_undelivered.isNotEmpty && identical(_undelivered.first, message)) {
        _undelivered.removeFirst();
      }
      if (handleData == null) {
        return;
      }
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

  @override
  void onError(Function? handleError) {
    super.onError(handleError ?? _logError);
  }

  static void _logError(Object error, StackTrace stackTrace) {
    // A remote abort is a normal event; the status is also on `done`.
    _log.fine('talk stream error without onError handler: $error');
  }
}
