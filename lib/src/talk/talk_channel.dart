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
import 'dart:collection';
import 'dart:typed_data';

import 'package:async/async.dart' show DelegatingStreamSubscription;
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:stream_channel/stream_channel.dart';

import '../address/channel_address.dart';
import '../monotonic.dart';
import '../mux/mux_channel.dart';
import '../name.dart';
import '../status.dart';
import '../status_closable.dart';
import 'talk_bulk.dart';
import 'talk_frame.dart';
import 'talk_message.dart';
import 'talk_request.dart';
import 'talk_stream.dart';

export '../status_closable.dart';

part 'talk_bulk_transfer.dart';
part 'talk_forward.dart';

final Logger _log = Logger('Switchboard.Talk');

/// JavaScript timers overflow above a signed 32-bit millisecond delay.
/// Longer expiries are rearmed from the monotonic deadline in chunks.
const Duration _maxTimerDelay = Duration(milliseconds: 0x7FFFFFFF);

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
    this.bulkThreshold,
    this.bulkChunkSize = defaultBulkChunkSize,
    this.maxInlinePayload = defaultMaxInlinePayload,
    this.bulkWindow = defaultBulkWindow,
    this.maxUnclaimedBulk = defaultMaxUnclaimedBulk,
    this.bulkOpenTimeout = const Duration(seconds: 10),
    this.streamBulk,
  });

  /// Default [bulkChunkSize]: 64 KiB.
  static const int defaultBulkChunkSize = 64 * 1024;

  /// Default [maxInlinePayload]: 16 MiB.
  static const int defaultMaxInlinePayload = 16 * 1024 * 1024;

  /// Default [bulkWindow]: 1 MiB.
  static const int defaultBulkWindow = 1024 * 1024;

  /// Default [maxUnclaimedBulk]: 16, the reference of the wiki.
  static const int defaultMaxUnclaimedBulk = 16;

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

  /// Sending: the largest message, in encoded bytes (header included),
  /// sent inline; a larger one goes as a bulk payload (see
  /// [TalkMessage.isBulk]). Null, the default, is the channel's own limit
  /// ([MuxChannel.maxSubframeLength]: half the peer's initial window, less
  /// the frame overhead), so that a payload goes bulk only when it must; a
  /// lower value sends bulk earlier. Only over a mux channel; over any
  /// other `StreamChannel` every message goes inline.
  final int? bulkThreshold;

  /// Sending: a bulk payload read from a stream is coalesced into chunks of
  /// this many bytes, each sent once the one before was taken by the bulk
  /// channel's window (the stream is paused meanwhile). Default 64 KiB.
  final int bulkChunkSize;

  /// Receiving: the largest bulk payload reassembled in memory, for a
  /// message delivered with its payload ([TalkMessage.payload]) and by
  /// [TalkMessage.payloadBytes] without a `maxLength`. A larger one fails
  /// with `RESOURCE_EXHAUSTED`, toward the sender (its bulk channel is
  /// closed with it, a request is answered with it) and the receiver.
  /// Default 16 MiB.
  /// Also caps the total reassembled bytes still held by this channel for
  /// delivery to the application. Exceeding that budget fails the payload
  /// with `RESOURCE_EXHAUSTED`; delivery or discard releases its budget.
  final int maxInlinePayload;

  /// Receiving: the window granted to a bulk channel being read whose
  /// length is declared, at most: the window is raised to the declared
  /// length up to this, so that a transfer is not paced by the initial
  /// window. What a slow reader makes this side hold for one payload is
  /// bounded by it. Default 1 MiB.
  final int bulkWindow;

  /// Receiving: bulk channels the peer may open for this channel before
  /// the messages that reference them arrive; beyond, a bulk OPEN is closed
  /// `RESOURCE_EXHAUSTED`. Also bounds references waiting for their bulk
  /// OPEN to be dispatched; beyond, a channel protocol error. Default 16,
  /// the wiki's reference.
  final int maxUnclaimedBulk;

  /// Receiving: how long a message waits for the bulk channel it
  /// references to be dispatched (its OPEN precedes it on the wire, but
  /// dispatch may lag). Expiry is a channel protocol error. Default 10 s.
  final Duration bulkOpenTimeout;

  /// Receiving: which bulk messages are delivered as soon as they arrive,
  /// with the payload still arriving as a stream ([TalkMessage.bulk]),
  /// rather than once the payload is reassembled in memory (up to
  /// [maxInlinePayload]), when [TalkMessage.payload] reads it like an
  /// inline one. Called with each bulk message before it is delivered;
  /// only its header and [TalkMessage.bulkLength] can be read then. Null,
  /// the default, reassembles every bulk payload, so that an application
  /// that reads only `payload` never notices bulk payloads. Replies
  /// relayed by `forwardMessage` always stream.
  final bool Function(TalkMessage message)? streamBulk;
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
/// cancellation. See the wiki page "Polyverse Switchboard Talk". [forwardMessage]
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
/// Flow control: over a mux channel, Talk returns the credit of a frame
/// when the application has taken what it carried: a plain message or a
/// request when [messages] hands it to its listener, a stream item when
/// [TalkStream.items] does, the answer to an `ordered` request when it is
/// delivered in its place. Frames the channel consumes itself (a final
/// response completing a future, aborts, `EXTEND`, cancels, frames for ids
/// it does not know or gave up on, requests it refuses, messages nobody
/// will read) return their credit at once. Replies relayed by
/// [forwardMessage] currently return parent-frame credit at once too; see
/// its buffering limitation. A stream that is
/// paused or not listened to therefore stalls its channel once the window
/// is used up (see [messages]), and only that channel.
///
/// Bulk payloads (wiki page "Polyverse Switchboard Talk", "Bulk
/// payloads"), over a mux channel: a message whose frame would exceed what
/// the channel can send in one frame ([MuxChannel.maxSubframeLength], or
/// [TalkOptions.bulkThreshold]) has its payload sent on a bulk channel of
/// its own, opened in order with this channel's frames, transparently;
/// `bulk:` on [send], [startRequest] and [streamRequest], and
/// [TalkMessage.replyBulk] and [TalkMessage.replyItemBulk], send a byte
/// stream that never sits in memory. A received bulk payload is
/// reassembled before its message is delivered, up to
/// [TalkOptions.maxInlinePayload], so that [TalkMessage.payload] reads it
/// like an inline one; messages [TalkOptions.streamBulk] selects are
/// delivered at once instead, the payload read as it arrives
/// ([TalkMessage.bulk]). Either way a message keeps its place in the
/// order: the ones behind it wait while it is reassembled. The peer's bulk
/// channels reach this channel through [adoptBulk] (a `Switchboard` routes
/// them itself). A channel abort or a close with a failure status cancels
/// the bulk payloads in transfer both ways; a [close] with `OK` waits for
/// the ones this side is sending, at most the connection's close
/// confirmation timeout.
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
///   logged and the request is answered with `ABORT INTERNAL` and marked
///   cancelled ([TalkMessage.onCancel]), so that work started on it stops,
///   a [forwardMessage] of it included. Exceptions in asynchronous code
///   (for example the body of an `await for`) cannot be seen by the
///   channel; such a request is answered by the responder timeout.
/// * Error events on [messages] and [TalkStream.items] whose listener has
///   no `onError` handler are logged, never reported as unhandled. Futures
///   returned by the request API never report unhandled errors either.
class TalkChannel {
  /// Wraps [channel]. Starts listening to its stream immediately, and
  /// never pauses it: what waits for the application is held here (see
  /// [messages]). A null [options] means the defaults.
  ///
  /// Over a [MuxChannel] (or a slot channel carrying one) the channel is
  /// put in [MuxChannel.manualCredit] before it is listened to, and the
  /// credit of every frame goes back to the peer when the application has
  /// taken what the frame carried, so that the channel's window bounds
  /// what is held here (see [messages]). Over any other `StreamChannel`
  /// nothing is flow controlled.
  TalkChannel(StreamChannel<Uint8List> channel, {TalkOptions? options})
    : raw = channel,
      options = options ?? const TalkOptions() {
    final r = raw;
    if (r is MuxChannel) {
      r.manualCredit = true;
      _consume = r.consumed;
    } else if (r is MuxChannelCarrier) {
      (r as MuxChannelCarrier).manualCredit = true;
      _consume = (r as MuxChannelCarrier).consumed;
    }
    // Before listening: a bulk channel the peer opened for this one may be
    // waiting for its Talk layer.
    _routeBulk();
    _subscription = raw.stream.listen(
      _onData,
      onError: _onError,
      onDone: _onDone,
    );
  }

  /// Routes a bulk channel the peer opened to the Talk layer of its parent
  /// channel (wiki page "Polyverse Switchboard Talk", "Bulk payloads"), for
  /// applications that read a [MuxConnection]'s incoming channels
  /// themselves: call it for each channel whose open payload is of the
  /// reserved type `_bulk` ([TalkBulkOpen.isBulk]), before any listener
  /// policy. A `Switchboard` does this for every connection.
  ///
  /// The parent must be open on the channel's connection: otherwise the
  /// bulk channel is closed `FAILED_PRECONDITION`, as it is when the parent
  /// is read by something other than a [TalkChannel] (or a pipe of
  /// `pipeChannels`). A parent whose Talk layer is not created yet holds
  /// the bulk channel for it, at most [BulkRoutes.maxHeld], beyond which,
  /// as beyond [TalkOptions.maxUnclaimedBulk], it is closed
  /// `RESOURCE_EXHAUSTED`. A malformed open payload closes it
  /// `PROTOCOL_ERROR`. Throws [ArgumentError] if [channel] is not a bulk
  /// channel.
  static void adoptBulk(MuxChannel channel) {
    final ChannelAddress address;
    try {
      address = ChannelAddress.decode(channel.openPayload);
    } on ProtocolException catch (e) {
      unawaited(channel.close(e.status));
      return;
    }
    if (!TalkBulkOpen.isBulk(address)) {
      throw ArgumentError.value(channel, 'channel', 'not a _bulk channel');
    }
    routeBulk(channel, address);
  }

  /// [adoptBulk] for a channel whose open payload is decoded already.
  @internal
  static void routeBulk(MuxChannel channel, ChannelAddress address) {
    final TalkBulkOpen open;
    try {
      open = TalkBulkOpen.decode(address);
    } on ProtocolException catch (e) {
      unawaited(channel.close(e.status));
      return;
    }
    BulkRoutes.route(channel, open);
  }

  /// The underlying channel.
  final StreamChannel<Uint8List> raw;

  /// The policy of this channel.
  final TalkOptions options;

  late final StreamSubscription<Uint8List> _subscription;

  late final StreamController<TalkMessage> _messages =
      StreamController<TalkMessage>(onCancel: _onMessagesCancelled);

  /// Reports frames consumed to a flow-controlled raw channel; null when
  /// the raw channel is not one.
  void Function(int bytes, {int subframes})? _consume;

  // Bulk payloads. The mux channel the bulk channels of the peer are
  // routed for; bulk numbers this side used; transfers in both directions.
  MuxChannel? _registeredMux;
  int _bulkOutCount = 0;
  final Set<_BulkOut> _bulkOuts = {};
  final Map<int, _BulkIn> _bulkUnclaimed = {};
  final Map<int, _Awaited> _bulkAwaited = {};
  final Set<_BulkIn> _bulkIns = {};
  int _bulkInHighest = 0;

  /// Reassembly in progress and completed payloads not delivered yet.
  int _assemblyBytes = 0;

  /// The order of [messages], kept while bulk payloads arrive.
  final _Lane _messagesLane = _Lane();

  /// The credit of the frames waiting in [_messages].
  final _Held _messagesHeld = _Held();

  /// Requests added to [_messages] and not yet handed to its listener.
  final Queue<_Message> _undeliveredRequests = Queue<_Message>();

  /// Markers carrying the outcome of an `ordered` request, added to
  /// [_messages] and not yet handed to its listener.
  final Queue<_Message> _orderedOutcomes = Queue<_Message>();

  /// Incoming plain messages and requests, in arrival order. Responses
  /// never appear here. Single subscription; buffered until listened, and
  /// while the subscription is paused.
  ///
  /// Flow control: over a mux channel, the credit of a message goes back
  /// to the peer when the message is handed to the listener, not when it
  /// arrives. So what this buffer holds is bounded by the channel's
  /// window ([MuxChannel.receiveWindow], 64 KiB by default): a
  /// subscription that is paused, or not there yet, stalls the peer on
  /// this channel once the window is used up, and only this channel;
  /// everything the peer sends on it then waits, responses to our own
  /// requests included. Listen for as long as the peer may send messages,
  /// or cancel the subscription. Frames the channel consumes itself
  /// (responses completing a request, aborts, `EXTEND`, cancels, frames
  /// for requests given up on, messages dropped or refused) return their
  /// credit at once. [TalkStream.items] is flow controlled the same way.
  /// Over a raw `StreamChannel` that is not a mux channel nothing bounds
  /// this buffer; only the peer's unanswered requests are bounded, by
  /// number ([TalkOptions.maxIncomingRequests]).
  ///
  /// A channel abort from the peer is delivered as an error event (a
  /// [TalkAbortException] carrying its status) and then the stream ends;
  /// without an `onError` handler the error is only logged. The stream also
  /// ends, without an error, when the channel closes for any other reason;
  /// [done] has the status.
  ///
  /// If the subscription is cancelled, buffered requests that were never
  /// delivered and every later request are answered with
  /// `ABORT UNIMPLEMENTED`, including requests whose bulk payloads are
  /// still being reassembled; their transfers are cancelled too.
  late final Stream<TalkMessage> messages = _GuardedStream(
    _messages.stream,
    _undeliveredRequests,
    _messagesHeld,
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

  /// The mux channel under [raw], if it is one or carries one: bulk
  /// payloads need it.
  MuxChannel? get _mux {
    final r = raw;
    if (r is MuxChannel) {
      return r;
    }
    if (r is MuxChannelCarrier) {
      return (r as MuxChannelCarrier).channel;
    }
    return null;
  }

  /// Takes the bulk channels the peer opens for the current mux channel
  /// (a slot channel may have replaced it before anything was sent).
  void _routeBulk() {
    final mux = _mux;
    if (mux == null || identical(mux, _registeredMux)) {
      return;
    }
    _registeredMux = mux;
    BulkRoutes.register(mux, _adoptBulk);
  }

  /// Sends a plain message (fire and forget).
  ///
  /// [name], when given, is the procedure instead of [procedure], which is
  /// then ignored: generated code passes the exact wire name (a [Name]
  /// need not be valid UTF-8, so a string cannot always stand for it).
  ///
  /// A message too large for the channel's frames (or for
  /// [TalkOptions.bulkThreshold]) is sent as a bulk payload, transparently.
  /// With [bulk], the payload is that byte stream, sent as a bulk payload
  /// whose length is [bulkLength] (null: not known in advance) and
  /// [payload] must be empty; see [startRequest].
  ///
  /// Throws [SwitchboardException] with [StatusCode.failedPrecondition] if
  /// the channel is closed, and [ArgumentError] if [procedure] is not a
  /// valid name.
  void send(
    String procedure,
    Uint8List payload, {
    Name? name,
    Stream<List<int>>? bulk,
    int? bulkLength,
  }) => _send(
    name ?? Name(procedure),
    payload,
    bulk: _bulkSource(payload, bulk, bulkLength),
  );

  void _send(Name procedure, Uint8List payload, {_BulkSource? bulk}) {
    _sendFrame(
      TalkFrame(kind: TalkKind.message, procedure: procedure, payload: payload),
      bulk: bulk,
    );
  }

  /// The source of an explicit bulk payload, checking the arguments.
  static _BulkSource? _bulkSource(
    Uint8List payload,
    Stream<List<int>>? bulk,
    int? length,
  ) {
    if (bulk == null) {
      if (length != null) {
        throw ArgumentError.value(length, 'bulkLength', 'without bulk');
      }
      return null;
    }
    if (payload.isNotEmpty) {
      throw ArgumentError.value(
        payload.length,
        'payload',
        'must be empty with a bulk payload',
      );
    }
    if (length != null) {
      RangeError.checkValueInInterval(
        length,
        0,
        TalkBulkReference.maxLength,
        'bulkLength',
      );
    }
    return _BulkSource.stream(bulk, length);
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
    Stream<List<int>>? bulk,
    int? bulkLength,
  }) => startRequest(
    procedure,
    payload,
    timeout: timeout,
    name: name,
    ordered: ordered,
    bulk: bulk,
    bulkLength: bulkLength,
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
  /// the channel) are reported at once. An answer that arrived before
  /// them has ended the request: it is still delivered in its place, also
  /// after the channel ended ([messages] goes on delivering what it
  /// holds), and while the subscription stays paused it waits.
  ///
  /// Bulk payloads (wiki page "Polyverse Switchboard Talk", "Bulk
  /// payloads"): a request too large for the channel's frames (or for
  /// [TalkOptions.bulkThreshold]) goes as a bulk payload transparently.
  /// With [bulk], [payload] must be empty and the payload is that byte
  /// stream: a bulk channel is opened for it (in order with this channel's
  /// frames), the request goes with a reference to it, and the stream is
  /// read in chunks of [TalkOptions.bulkChunkSize], each once the bulk
  /// channel's window took the one before, so the stream is paused while
  /// the receiver does not read. [bulkLength] is its length, null when
  /// not known; a stream producing another number of bytes fails the
  /// payload with `INVALID_ARGUMENT`. A stream error fails the payload
  /// with the error's status (`INTERNAL` unless it is a
  /// [SwitchboardException]). Cancelling the request, or its failing
  /// locally (timeout, the channel closing), stops the transfer with
  /// `CANCELLED`; the receiver can stop it too, by closing the bulk
  /// channel. Needs a mux channel: over any other `StreamChannel` a bulk
  /// payload throws [StatusCode.unimplemented]. The requester timeout
  /// restarts each time a chunk of the payload goes out (as it does for a
  /// stream item), and as the bulk payloads of stream items arrive; it
  /// stops when the final response arrives, and the transfer of a bulk
  /// payload in that response is not timed (the connection's keep-alive
  /// bounds a peer gone silent; [TalkRequest.cancel] stops it).
  ///
  /// Throws synchronously, sending nothing, with
  /// [StatusCode.resourceExhausted] if [TalkOptions.maxOutgoingRequests] is
  /// reached, with [StatusCode.failedPrecondition] if the channel is
  /// closed, and [ArgumentError] if [procedure] is not a valid name, or
  /// [payload] is not empty with [bulk].
  TalkRequest startRequest(
    String procedure,
    Uint8List payload, {
    Duration? timeout,
    void Function(Duration? deadline, Duration? renew)? onExtend,
    Name? name,
    bool ordered = false,
    Stream<List<int>>? bulk,
    int? bulkLength,
  }) {
    final wire = name ?? Name(procedure);
    final source = _bulkSource(payload, bulk, bulkLength);
    return _TalkRequest(
      _startRequest(
        stream: false,
        timeout: timeout,
        onExtend: onExtend,
        ordered: ordered,
        bulk: source,
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
    Stream<List<int>>? bulk,
    int? bulkLength,
  }) {
    final wire = name ?? Name(procedure);
    final source = _bulkSource(payload, bulk, bulkLength);
    return _TalkStream(
      _startRequest(
        stream: true,
        timeout: timeout,
        onExtend: onExtend,
        bulk: source,
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
    // What waited for the peer's LIMITS goes before the end, sized against
    // the limit assumed meanwhile; the mux holds it until the LIMITS.
    if (!_rawEnded) {
      _flushDeferred();
    }
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
      keepOutgoingBulk: status.isOk,
    );
    if (status.isOk && _bulkOuts.isNotEmpty) {
      await _awaitBulkOuts();
    }
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

  /// Waits for the bulk payloads still being sent to finish, as a mux
  /// CLOSE waits behind the subframes before it: at most the connection's
  /// close confirmation timeout, then they are cut with
  /// `DEADLINE_EXCEEDED`.
  Future<void> _awaitBulkOuts() async {
    final outs = List.of(_bulkOuts);
    var timeout = const Duration(seconds: 30);
    final mux = _mux;
    if (mux != null &&
        mux.connection.options.closeConfirmTimeout > Duration.zero) {
      timeout = mux.connection.options.closeConfirmTimeout;
    }
    try {
      await Future.wait<void>([
        for (final out in outs)
          out.done.then<void>((_) {}, onError: (Object _) {}),
      ]).timeout(timeout);
    } on TimeoutException {
      for (final out in outs) {
        out.cancel(
          Status.of(
            StatusCode.deadlineExceeded,
            'bulk payload not sent within $timeout of the channel closing',
          ),
        );
      }
    }
  }

  // ---------------------------------------------------------------------
  // Sending

  /// Sends [frame]: inline, or with its payload on a bulk channel when
  /// [bulk] is given or the frame is too large inline (a `MESSAGE` or
  /// `STREAM_ITEM` over the channel's limit, see
  /// [TalkOptions.bulkThreshold]); [onBulk] gets the bulk transfer, if
  /// any.
  ///
  /// While the mux channel waits for the peer's LIMITS (see
  /// `MuxOptions.awaitPeerLimits`), the frame waits here, in order with
  /// every frame after it, and is sized once the limit the peer announces
  /// is known: one sized against the 64 KiB assumed meanwhile could turn
  /// out too large for the window announced, and be lost. Its failures are
  /// then reported to [onFailure] (logged without one) instead of thrown.
  void _sendFrame(
    TalkFrame frame, {
    _BulkSource? bulk,
    void Function(_BulkOut out)? onBulk,
    void Function(_BulkOut? out)? onSent,
    void Function(SwitchboardException error)? onFailure,
  }) {
    if (_closing) {
      throw SwitchboardException.of(
        StatusCode.failedPrecondition,
        'channel closed',
      );
    }
    if (_mustDefer()) {
      _deferred.add(() {
        try {
          final out = _sendNow(frame, bulk);
          if (out != null) {
            onBulk?.call(out);
          }
          onSent?.call(out);
        } on Object catch (e) {
          final error = e is SwitchboardException
              ? e
              : SwitchboardException.of(StatusCode.internal, '$e');
          if (onFailure != null) {
            onFailure(error);
          } else {
            _log.warning('$frame not sent: ${error.status}');
          }
        }
      });
      return;
    }
    final out = _sendNow(frame, bulk);
    if (out != null) {
      onBulk?.call(out);
    }
    onSent?.call(out);
  }

  /// Whether a frame sent now waits in [_deferred]: frames wait there
  /// already, or the mux channel waits for the peer's LIMITS.
  bool _mustDefer() {
    if (_deferred.isNotEmpty) {
      return true;
    }
    final mux = _mux;
    if (mux == null || !mux.awaitingLimits) {
      return false;
    }
    final waiting = mux;
    waiting.limitsKnown.then((_) {
      if (identical(_mux, waiting)) {
        _flushDeferred();
      }
    });
    return true;
  }

  /// Sends the frames that waited for the peer's LIMITS, in order.
  void _flushDeferred() {
    while (_deferred.isNotEmpty) {
      _deferred.removeFirst()();
    }
  }

  /// [_sendFrame] without the wait for LIMITS; throws its failures.
  _BulkOut? _sendNow(TalkFrame frame, _BulkSource? bulk) {
    if (bulk == null) {
      final bytes = frame.encode();
      if (!_needsBulk(frame, bytes.length)) {
        _sendRaw(bytes);
        return null;
      }
      bulk = _BulkSource.bytes(frame.payload);
    }
    final mux = _mux;
    if (mux == null) {
      throw SwitchboardException.of(
        StatusCode.unimplemented,
        'bulk payloads need a mux channel',
      );
    }
    final out = _openBulk(mux, bulk.length);
    try {
      _sendRaw(
        frame
            .withBulk(TalkBulkReference(out.number, length: bulk.length))
            .encode(),
      );
    } catch (_) {
      unawaited(
        out.channel.close(
          Status.of(StatusCode.cancelled, 'bulk message not sent'),
        ),
      );
      rethrow;
    }
    out.start(bulk);
    return out;
  }

  /// [_sendFrame] for frames that never carry a bulk payload.
  void _sendChecked(TalkFrame frame) => _sendFrame(frame);

  /// Frames waiting for the peer's LIMITS (see [_sendFrame]).
  final Queue<void Function()> _deferred = Queue<void Function()>();

  void _sendRaw(Uint8List bytes) {
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

  /// Whether [frame], [length] bytes encoded, goes as a bulk payload.
  bool _needsBulk(TalkFrame frame, int length) {
    if (frame.kind != TalkKind.message && frame.kind != TalkKind.streamItem) {
      return false;
    }
    final mux = _mux;
    if (mux == null) {
      return false;
    }
    var limit = mux.maxSubframeLength;
    final threshold = options.bulkThreshold;
    if (threshold != null && threshold < limit) {
      limit = threshold;
    }
    return length > limit;
  }

  /// Opens the next bulk channel for [mux], in order with its frames.
  _BulkOut _openBulk(MuxChannel mux, int? length) {
    if (_bulkOutCount >= TalkBulkReference.maxNumber) {
      throw SwitchboardException.of(
        StatusCode.resourceExhausted,
        'bulk numbers of channel ${mux.id} used up',
      );
    }
    final number = _bulkOutCount + 1;
    final channel = mux.openAfter(TalkBulkOpen(mux.id, number).encode());
    _bulkOutCount = number;
    channel.priority = MuxPriority.bulk;
    BulkRoutes.markBulk(channel);
    return _BulkOut(this, channel, number, length);
  }

  /// Sends a frame on the channel's own behalf; failures are logged only.
  void _trySend(TalkFrame frame) {
    if (_closing) {
      return;
    }
    void send() {
      try {
        raw.sink.add(frame.encode());
      } catch (e, st) {
        _log.fine('failed to send $frame', e, st);
      }
    }

    if (_mustDefer()) {
      _deferred.add(send);
    } else {
      send();
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
    _BulkSource? bulk,
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
      _sendFrame(
        frame,
        bulk: bulk,
        onBulk: (out) {
          out.track(pending.bulkOuts);
          // The request's payload going out is progress: the requester
          // timeout restarts with each chunk the receiver takes.
          out.onProgress = () {
            if (!pending.ended && !pending.finalReceived) {
              pending.replied();
            }
          };
        },
        // Only when the frame waited for the peer's LIMITS.
        onFailure: (error) {
          if (identical(_outgoing[id], pending)) {
            _outgoing.remove(id);
          }
          pending.fail(error);
        },
      );
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
    if (pending.finalReceived) {
      // The answer arrived and waits for its bulk payload: the peer is
      // done with the request, the payload's channel is closed.
      _outgoing.remove(pending.id);
      pending.fail(SwitchboardException(status));
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
    if (message.frame.bulk) {
      // Started once the request is delivered: its application cannot
      // answer before (see [_attachBulk]).
      message._timerDeferred = true;
    } else {
      message._startTimer();
    }
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
      _creditMessage(message);
      message._bulk?.abandon();
      message._abortQuietly(
        Status.of(StatusCode.unimplemented, 'no message listener'),
      );
      return;
    }
    if (message.expectsReply) {
      _undeliveredRequests.add(message);
    }
    _messagesHeld.hold(message);
    _messages.add(message);
  }

  void _onMessagesCancelled() {
    _messagesCancelled = true;
    // What the controller still holds is dropped.
    _drainHeld(_messagesHeld);
    final undelivered = _undeliveredRequests.toList();
    _undeliveredRequests.clear();
    for (final message in undelivered) {
      message._abortQuietly(
        Status.of(StatusCode.unimplemented, 'no message listener'),
      );
    }
    _messagesLane.dropIncoming(
      Status.of(StatusCode.unimplemented, 'no message listener'),
    );
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
      _creditMessage(marker);
      outcome();
      return;
    }
    marker._outcome = outcome;
    _orderedOutcomes.add(marker);
    // The answer goes to the request, not to the listener: its payload is
    // not the listener's to drop.
    _messagesHeld.hold(marker, trackBulk: false);
    _messages.add(marker);
  }

  // ---------------------------------------------------------------------
  // Receiving

  void _onData(Uint8List data) {
    final wire = data.length;
    if (_closing) {
      _credit(wire);
      return;
    }
    _routeBulk();
    final TalkFrame frame;
    try {
      frame = TalkFrame.decode(data);
    } on ProtocolException catch (e) {
      _credit(wire);
      _protocolError(e.status.reason);
      return;
    }
    switch (frame.kind) {
      case TalkKind.message:
        _onMessage(frame, wire);
      case TalkKind.streamItem:
        _onStreamItem(frame, wire);
      case TalkKind.abort:
        _credit(wire);
        _onAbort(frame);
      case TalkKind.extend:
        _credit(wire);
        _onExtend(frame);
    }
  }

  // ---------------------------------------------------------------------
  // Flow control

  /// Reports [frames] frames of [bytes] bytes together consumed to the raw
  /// channel, so that their credit goes back to the peer. Does nothing over
  /// a raw channel that is not flow controlled.
  void _credit(int bytes, {int frames = 1}) {
    final consume = _consume;
    if (consume == null || frames == 0) {
      return;
    }
    try {
      consume(bytes, subframes: frames);
    } on StateError catch (e) {
      // Accounting mismatch: logged, never fatal to the channel.
      _log.warning('credit accounting: $e');
    }
  }

  /// Returns the credit of [message], once: it was handed to the
  /// application, or consumed by the channel.
  void _creditMessage(_Message message, [_Held? held]) {
    message._releaseAssembly();
    held?.assembled.remove(message);
    if (held != null && message._heldBulk) {
      message._heldBulk = false;
      held.bulk.remove(message);
    }
    final bytes = message._creditBytes;
    if (bytes == 0) {
      return;
    }
    message._creditBytes = 0;
    if (held != null) {
      if (held.drained) {
        // Returned already with everything the controller held.
        return;
      }
      held.bytes -= bytes;
      held.frames--;
    }
    _credit(bytes);
  }

  /// Returns the credit of everything [held] still holds: the controller
  /// it counts for will deliver nothing more.
  void _drainHeld(_Held held) {
    _returnHeld(held);
    for (final message in held.assembled) {
      message._releaseAssembly();
    }
    held.assembled.clear();
    // Bulk payloads of the dropped messages will not be read.
    final bulk = List.of(held.bulk);
    held.bulk.clear();
    for (final message in bulk) {
      message._heldBulk = false;
      message._bulk?.abandon();
    }
  }

  /// Returns the credit of everything [held] still holds, which stays
  /// deliverable: nothing more will be added to its controller (the stream
  /// request ended), so it is bounded without the window.
  void _returnHeld(_Held held) {
    if (held.drained) {
      return;
    }
    held.drained = true;
    final bytes = held.bytes;
    final frames = held.frames;
    held
      ..bytes = 0
      ..frames = 0;
    _credit(bytes, frames: frames);
  }

  // ---------------------------------------------------------------------
  // Bulk payloads, receiving

  /// Takes [bulk], a bulk channel the peer opened for this channel with
  /// bulk [number] ([BulkRoutes]).
  void _adoptBulk(MuxChannel bulk, int number) {
    // Consumed as the reader takes its bytes; nothing listens to it yet.
    bulk
      ..manualCredit = true
      ..priority = MuxPriority.bulk;
    BulkRoutes.markBulk(bulk);
    final b = _BulkIn(this, bulk, number);
    if (_closing) {
      b.close(Status.of(StatusCode.cancelled, 'channel closed'));
      b.abandon();
      return;
    }
    if (number <= _bulkInHighest) {
      b.close(Status.of(StatusCode.protocolError, 'bulk number reused'));
      b.abandon();
      _protocolError('bulk number $number reused');
      return;
    }
    _bulkInHighest = number;
    final awaited = _bulkAwaited.remove(number);
    if (awaited != null) {
      awaited.timer.cancel();
      final message = awaited.message;
      if (message == null) {
        b.abandon();
      } else {
        _attachBulk(message, b);
      }
      return;
    }
    if (_bulkUnclaimed.length >= options.maxUnclaimedBulk) {
      _log.warning(
        'peer opened more than ${options.maxUnclaimedBulk} bulk channels '
        'ahead of their messages; refusing bulk channel $number',
      );
      b.close(
        Status.of(
          StatusCode.resourceExhausted,
          'too many bulk channels before their messages',
        ),
      );
      b.abandon();
      return;
    }
    _bulkUnclaimed[number] = b;
    // A bulk channel no message references in time is not waited for.
    b.unclaimedTimer = Timer(options.bulkOpenTimeout, () {
      b.unclaimedTimer = null;
      if (identical(_bulkUnclaimed[number], b)) {
        _bulkUnclaimed.remove(number);
        _log.fine('bulk channel $number not referenced in time');
        b
          ..close(Status.of(StatusCode.cancelled, 'not referenced in time'))
          ..abandon();
      }
    });
  }

  /// Claims the bulk channel [message] references, if it is a bulk
  /// message: attaches it, or waits for it to be adopted (its OPEN came
  /// first, but dispatch may lag). False, after a channel protocol error,
  /// for a reference to a bulk number not open or already referenced.
  bool _claimBulk(_Message message, {required bool forSink}) {
    final frame = message.frame;
    if (!frame.bulk) {
      return true;
    }
    final reference = frame.bulkReference;
    message
      .._bulkRef = reference
      .._forSink = forSink;
    if (_mux == null) {
      message._bulkFailure = Status.of(
        StatusCode.unimplemented,
        'bulk payloads need a mux channel',
      );
      return true;
    }
    final number = reference.number;
    final b = _bulkUnclaimed.remove(number);
    if (b != null) {
      _attachBulk(message, b);
      return true;
    }
    if (number <= _bulkInHighest || _bulkAwaited.containsKey(number)) {
      _protocolError(
        'BULK reference to bulk channel $number, not open or referenced '
        'already',
      );
      return false;
    }
    return _awaitBulk(number, message);
  }

  /// The bulk payload of [frame], a message dropped on arrival, is not
  /// wanted: its bulk channel is closed `CANCELLED`, now or when it
  /// arrives.
  void _discardBulk(TalkFrame frame) {
    if (!frame.bulk || _mux == null) {
      return;
    }
    final number = frame.bulkReference.number;
    final b = _bulkUnclaimed.remove(number);
    if (b != null) {
      b.abandon();
      return;
    }
    if (number <= _bulkInHighest || _bulkAwaited.containsKey(number)) {
      _protocolError(
        'BULK reference to bulk channel $number, not open or referenced '
        'already',
      );
      return;
    }
    _awaitBulk(number, null);
  }

  /// Dispatch may lag, but ignored responses must not buy unbounded
  /// timers with the credit returned on arrival.
  bool _awaitBulk(int number, _Message? message) {
    if (_bulkAwaited.length >= options.maxUnclaimedBulk) {
      _protocolError('too many BULK references waiting for their channels');
      return false;
    }
    _bulkAwaited[number] = _Awaited(
      message,
      Timer(options.bulkOpenTimeout, () => _bulkNeverOpened(number)),
    );
    return true;
  }

  void _bulkNeverOpened(int number) {
    if (_bulkAwaited.remove(number) != null) {
      _protocolError(
        'bulk channel $number not opened within ${options.bulkOpenTimeout}',
      );
    }
  }

  /// [b] carries the payload of [message]: delivered as a stream, or
  /// reassembled first (see [TalkOptions.streamBulk]).
  void _attachBulk(_Message message, _BulkIn b) {
    b.unclaimedTimer?.cancel();
    b.unclaimedTimer = null;
    message._bulk = b;
    b
      ..length = message._bulkRef!.length
      ..onProgress = message._onBulkProgress;
    // Until its bytes were all read, or it was abandoned.
    if (b._endStatus == null) {
      _bulkIns.add(b);
    }
    final pending = _outgoing[message.responseId];
    if (pending != null) {
      pending.bulkIns.add(b);
      unawaited(b.channel.done.then((_) => pending.bulkIns.remove(b)));
    }
    var stream = message._forSink;
    final predicate = options.streamBulk;
    if (!stream && predicate != null) {
      try {
        stream = predicate(message);
      } catch (e, st) {
        _log.warning('streamBulk failed; reassembling the payload', e, st);
      }
    }
    if (stream) {
      message._streamBulk = true;
      message._startDeferredTimer();
    } else {
      b
          .collect(options.maxInlinePayload, reserve: message._reserveAssembly)
          .then(
            (bytes) {
              message._assembled = bytes;
              message._startDeferredTimer();
              message._lane?.advance();
            },
            onError: (Object error) {
              message._releaseAssembly();
              message._bulkFailure = error is SwitchboardException
                  ? error.status
                  : Status.of(StatusCode.internal, '$error');
              message._lane?.advance();
            },
          );
    }
    message._lane?.advance();
  }

  /// Ends the bulk payloads in transfer in both directions: the channel
  /// ends. Outgoing ones are cancelled unless [keepOutgoing] (a graceful
  /// close lets them finish).
  void _endBulk({required bool keepOutgoing}) {
    final cancelled = Status.of(StatusCode.cancelled, 'channel closed');
    for (final awaited in _bulkAwaited.values) {
      awaited.timer.cancel();
    }
    _bulkAwaited.clear();
    final unclaimed = List.of(_bulkUnclaimed.values);
    _bulkUnclaimed.clear();
    for (final b in unclaimed) {
      b.abandon();
    }
    final ins = List.of(_bulkIns);
    _bulkIns.clear();
    for (final b in ins) {
      b.close(cancelled);
      b.abandon();
    }
    if (!keepOutgoing) {
      for (final out in List.of(_bulkOuts)) {
        out.cancel(cancelled);
      }
    }
  }

  // ---------------------------------------------------------------------
  // Messages

  void _onMessage(TalkFrame frame, int wire) {
    if (!frame.hasResponse) {
      if (_messagesCancelled) {
        _credit(wire);
        _discardBulk(frame);
        if (frame.hasRequest) {
          _incoming.remove(frame.requestId)?._abandon();
          _rejectRequest(
            frame.requestId,
            Status.of(StatusCode.unimplemented, 'no message listener'),
          );
        }
        return;
      }
      final message = _Message(this, frame).._creditBytes = wire;
      if (frame.hasRequest && !_register(message)) {
        _creditMessage(message);
        _discardBulk(frame);
        return;
      }
      if (!_claimBulk(message, forSink: false)) {
        return;
      }
      _messagesLane.add(message, () => _deliverIncoming(message));
      return;
    }
    final pending = _outgoing[frame.responseId];
    if (pending == null || pending.finalReceived) {
      _credit(wire);
      _discardBulk(frame);
      _unknownResponse(frame);
      return;
    }
    pending.stopTimer();
    if (pending.abandoned) {
      _outgoing.remove(pending.id);
      _credit(wire);
      _discardBulk(frame);
      if (frame.hasRequest) {
        _rejectRequest(
          frame.requestId,
          Status.of(StatusCode.cancelled, 'request ${pending.id} cancelled'),
        );
      }
      return;
    }
    pending.finalReceived = true;
    final message = _Message(this, frame).._creditBytes = wire;
    pending.finalMessage = message;
    if (frame.hasRequest) {
      _register(message);
    }
    if (!_claimBulk(message, forSink: pending.sink != null)) {
      return;
    }
    if (pending.ordered) {
      // Credit when the answer is delivered, in its place.
      _messagesLane.add(
        message,
        () => _answer(pending, message, ordered: true),
      );
    } else {
      pending.lane.add(message, () => _answer(pending, message));
    }
  }

  /// Delivers a plain message or request to [messages], once its bulk
  /// payload (if any) is ready; one whose payload failed is not delivered,
  /// and a request is answered with the payload's status.
  void _deliverIncoming(_Message message) {
    final failure = message._bulkFailure;
    if (failure != null) {
      _log.fine('bulk payload of ${message.frame} failed: $failure');
      _creditMessage(message);
      message._abortQuietly(failure);
      return;
    }
    _deliverMessage(message);
  }

  /// Delivers [message], the final response to [pending], in its turn.
  void _answer(_Outgoing pending, _Message message, {bool ordered = false}) {
    if (!identical(_outgoing[pending.id], pending)) {
      // Failed meanwhile: cancelled, or the channel ended.
      message._drop();
      return;
    }
    _outgoing.remove(pending.id);
    final failure = message._bulkFailure;
    if (failure != null) {
      _log.fine('bulk payload of ${message.frame} failed: $failure');
      _creditMessage(message);
      message._abortQuietly(failure);
      final error = SwitchboardException(failure);
      if (ordered) {
        _deliverOrdered(
          _Message(this, message.frame),
          () => pending.fail(error),
        );
      } else {
        pending.fail(error);
      }
      return;
    }
    if (ordered) {
      _deliverOrdered(message, () => pending.complete(message));
    } else {
      _creditMessage(message);
      pending.complete(message);
    }
  }

  void _onStreamItem(TalkFrame frame, int wire) {
    final pending = _outgoing[frame.responseId];
    if (pending == null || pending.finalReceived) {
      _credit(wire);
      _discardBulk(frame);
      _unknownResponse(frame);
      return;
    }
    if (pending.abandoned) {
      _credit(wire);
      _discardBulk(frame);
      if (frame.hasRequest) {
        _rejectRequest(
          frame.requestId,
          Status.of(StatusCode.cancelled, 'request ${pending.id} cancelled'),
        );
      }
      return;
    }
    if (!pending.isStream) {
      _credit(wire);
      _protocolError('STREAM_ITEM for non-stream request ${pending.id}');
      return;
    }
    pending.replied();
    final message = _Message(this, frame).._creditBytes = wire;
    if (frame.hasRequest) {
      _register(message);
    }
    // The payload of an item arriving is progress of the request, as the
    // item was.
    message._onBulkProgress = () {
      if (!pending.ended && !pending.finalReceived) {
        pending.replied();
      }
    };
    if (!_claimBulk(message, forSink: pending.sink != null)) {
      return;
    }
    pending.lane.add(message, () => _deliverItem(pending, message));
  }

  /// Delivers [message], an item of [pending], in its turn.
  void _deliverItem(_Outgoing pending, _Message message) {
    final failure = message._bulkFailure;
    if (failure != null) {
      _log.fine('bulk payload of ${message.frame} failed: $failure');
      _creditMessage(message);
      message._abortQuietly(failure);
      _cancelOutgoing(pending, failure);
      return;
    }
    pending.addItem(message);
  }

  void _onAbort(TalkFrame frame) {
    if (frame.hasResponse) {
      final pending = _outgoing[frame.responseId];
      if (pending == null || pending.finalReceived) {
        _log.fine('abort for unknown request ${frame.responseId} ignored');
        return;
      }
      pending.stopTimer();
      if (pending.abandoned) {
        _outgoing.remove(pending.id);
        return;
      }
      pending.finalReceived = true;
      final error = TalkAbortException(_abortStatus(frame));
      void fail() {
        if (identical(_outgoing[pending.id], pending)) {
          _outgoing.remove(pending.id);
          pending.fail(error);
        }
      }

      if (pending.ordered) {
        _messagesLane.add(null, () {
          if (identical(_outgoing[pending.id], pending)) {
            _outgoing.remove(pending.id);
            _deliverOrdered(_Message(this, frame), () => pending.fail(error));
          }
        });
      } else {
        pending.lane.add(null, fail);
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
    if (pending == null || pending.abandoned || pending.finalReceived) {
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
    _deferred.clear();
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
  void _terminate(
    SwitchboardException error, {
    bool reportOnMessages = false,
    bool keepOutgoingBulk = false,
  }) {
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
    // Answers in [_orderedOutcomes] arrived before the end: they keep their
    // place in [_messages], which still delivers what it holds once closed.
    final incoming = _incoming.values.toList();
    _incoming.clear();
    for (final message in incoming) {
      message._abandon();
    }
    // What arrived whole keeps its place; what waits for a bulk payload
    // in transfer is dropped with it.
    _messagesLane.flush();
    _undeliveredRequests.clear();
    _endBulk(keepOutgoing: keepOutgoingBulk);
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

  /// The credit of the items waiting in [items].
  final _Held itemsHeld = _Held();

  /// The order of what answers the request, kept while bulk payloads
  /// arrive.
  final _Lane lane = _Lane();

  /// Bulk payloads of the request itself, being sent.
  final Set<_BulkOut> bulkOuts = {};

  /// Reply payloads still in transfer, even after their streamed messages
  /// were delivered. Local cancellation must not rely on the peer to stop.
  final Set<_BulkIn> bulkIns = {};

  /// The final response or abort arrived; it may wait in [lane] (or, for
  /// an ordered request, in the lane of `messages`) for a bulk payload, and
  /// the request stays in the channel's table until it is delivered.
  bool finalReceived = false;

  /// The final response, once it arrived.
  _Message? finalMessage;
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
    expiry
      ..gap = duration
      ..start(monotonicNow());
    _arm();
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
    if (left > _maxTimerDelay) {
      timer = Timer(_maxTimerDelay, () {
        timer = null;
        _arm();
      });
    } else {
      timer = Timer(left, () => channel._onRequestTimeout(this));
    }
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
      // Forwarding queues synchronously; see forwardMessage's buffering
      // limitation for parent-frame credit.
      channel._creditMessage(message);
      _guard(() => sink.item(message), 'forwarding an item');
      return;
    }
    if (items!.isClosed) {
      message._drop();
      return;
    }
    if (message.expectsReply) {
      undeliveredItems.add(message);
    }
    itemsHeld.hold(message);
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
    // No more items will come: what waits for a listener that never comes
    // must not stall the channel.
    channel._returnHeld(itemsHeld);
    completer.complete(message);
  }

  void fail(SwitchboardException error) {
    stopTimer();
    if (_failed) {
      return;
    }
    _failed = true;
    lane.drop();
    for (final bulk in List.of(bulkIns)) {
      bulk
        ..close(Status.of(StatusCode.cancelled, 'request ended'))
        ..abandon();
    }
    bulkIns.clear();
    // An ordered answer can still be waiting for dispatch in the messages
    // lane. Drop its reference now, so it cannot hold later messages up.
    finalMessage?._drop();
    if (error is! TalkAbortException || error.isChannelAbort) {
      // A local failure: the payload of the request is not wanted any
      // more. After the peer's abort response, its receiver decides.
      for (final out in bulkOuts) {
        out.cancel(
          error.status.isOk ? Status.of(StatusCode.cancelled) : error.status,
        );
      }
    }
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
    channel._returnHeld(itemsHeld);
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
      // In order with the items relayed before it.
      final payload = frame.payload;
      lane.add(
        null,
        () => _guard(() => sink.extended(payload), 'forwarding EXTEND'),
      );
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
    channel._drainHeld(itemsHeld);
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
    : items = _GuardedStream(
        _pending.items!.stream,
        _pending.undeliveredItems,
        _pending.itemsHeld,
      );

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

  /// The credit of the frame that carried this message, until it is
  /// returned ([TalkChannel._creditMessage]); 0 after, and for messages
  /// of a channel that is not flow controlled.
  int _creditBytes = 0;

  // Bulk payload: the reference, the bulk channel once claimed, and how
  // it is delivered.
  TalkBulkReference? _bulkRef;
  bool _forSink = false;
  _BulkIn? _bulk;
  bool _streamBulk = false;
  Uint8List? _assembled;
  Status? _bulkFailure;

  /// Bytes charged to the channel until this message is delivered.
  int _assemblyBytes = 0;
  bool _dropped = false;

  bool _reserveAssembly(int bytes) {
    if (_dropped ||
        channel._assemblyBytes + bytes > channel.options.maxInlinePayload) {
      return false;
    }
    _assemblyBytes += bytes;
    channel._assemblyBytes += bytes;
    return true;
  }

  void _releaseAssembly() {
    channel._assemblyBytes -= _assemblyBytes;
    _assemblyBytes = 0;
  }

  /// Held in a controller with its bulk payload unread ([_Held.bulk]).
  bool _heldBulk = false;

  /// The lane this message waits in, while its payload is not ready.
  _Lane? _lane;

  /// Bulk payloads of the replies to this request, being sent.
  final Set<_BulkOut> _bulkOuts = {};

  /// Called as the bulk payload of this message is read: restarts the
  /// timeouts that its transfer counts as progress for.
  void Function()? _onBulkProgress;

  /// The responder timeout waits for the request to be delivered (a bulk
  /// payload being reassembled or not dispatched yet).
  bool _timerDeferred = false;

  /// Starts the responder timeout deferred by [TalkChannel._register].
  void _startDeferredTimer() {
    if (!_timerDeferred) {
      return;
    }
    _timerDeferred = false;
    if (!_finished && expectsReply) {
      _startTimer();
    }
  }

  /// Whether the message can be delivered: inline, or its bulk payload is
  /// reassembled, failed, or delivered as a stream.
  bool get _ready =>
      _bulkRef == null ||
      _bulkFailure != null ||
      _assembled != null ||
      (_bulk != null && _streamBulk);

  /// The message will not be delivered: its credit goes back, its bulk
  /// payload is not wanted, a request is answered `CANCELLED`.
  void _drop() {
    if (_dropped) {
      return;
    }
    _dropped = true;
    _bulkFailure ??= Status.of(StatusCode.cancelled, 'message dropped');
    channel._creditMessage(this);
    final b = _bulk;
    if (b != null) {
      b.close(Status.of(StatusCode.cancelled, 'message dropped'));
      b.abandon();
    } else if (_bulkRef != null) {
      final number = _bulkRef!.number;
      final awaited = channel._bulkAwaited[number];
      if (awaited != null && identical(awaited.message, this)) {
        channel._bulkAwaited[number] = _Awaited(null, awaited.timer);
      }
    }
    _abortQuietly(Status.of(StatusCode.cancelled, 'message dropped'));
    _lane?.advance();
  }

  @override
  bool get isBulk => frame.bulk;

  @override
  int? get bulkLength => _bulkRef?.length;

  @override
  Uint8List get payload {
    if (!frame.bulk) {
      return frame.payload;
    }
    final assembled = _assembled;
    if (assembled != null) {
      return assembled;
    }
    final failure = _bulkFailure;
    if (failure != null) {
      throw SwitchboardException(failure);
    }
    throw StateError(
      'the bulk payload of this message arrives as a stream: read bulk, '
      'or await payloadBytes()',
    );
  }

  @override
  Stream<Uint8List> get bulk {
    final failure = _bulkFailure;
    if (failure != null) {
      return Stream<Uint8List>.error(SwitchboardException(failure));
    }
    final b = _bulk;
    if (!frame.bulk || _assembled != null || b == null) {
      final bytes = frame.bulk ? _assembled : frame.payload;
      if (bytes == null) {
        throw StateError('the bulk payload of this message is not here yet');
      }
      return bytes.isEmpty
          ? const Stream<Uint8List>.empty()
          : Stream<Uint8List>.value(bytes);
    }
    return b.stream();
  }

  @override
  Future<Uint8List> payloadBytes({int? maxLength}) {
    final max = maxLength ?? channel.options.maxInlinePayload;
    final failure = _bulkFailure;
    if (failure != null) {
      return Future<Uint8List>.error(SwitchboardException(failure));
    }
    final b = _bulk;
    if (!frame.bulk || _assembled != null || b == null) {
      final bytes = frame.bulk ? _assembled : frame.payload;
      if (bytes == null) {
        return Future<Uint8List>.error(
          StateError('the bulk payload of this message is not here yet'),
        );
      }
      if (bytes.length > max) {
        return Future<Uint8List>.error(
          SwitchboardException.of(
            StatusCode.resourceExhausted,
            'payload of ${bytes.length} bytes, more than $max',
          ),
        );
      }
      return Future<Uint8List>.value(bytes);
    }
    if (b._read) {
      return Future<Uint8List>.error(
        StateError('the bulk payload is read already'),
      );
    }
    return b.collect(max).then((bytes) => _assembled = bytes);
  }

  /// What forwarding this message sends: the payload, or the bulk channel
  /// to pipe. Throws [StateError] when the bulk payload was read already,
  /// and [SwitchboardException] when it failed.
  (Uint8List, _BulkSource?) _forwardPayload() {
    if (!frame.bulk) {
      return (frame.payload, null);
    }
    final assembled = _assembled;
    if (assembled != null) {
      return (assembled, null);
    }
    final failure = _bulkFailure;
    if (failure != null) {
      throw SwitchboardException(failure);
    }
    final b = _bulk;
    if (b == null || b._read) {
      throw StateError('the bulk payload is read already');
    }
    return (Uint8List(0), _BulkSource.pipe(b));
  }

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

  @override
  Future<void> replyBulk(
    Stream<List<int>> bytes, {
    int? length,
    String? procedure,
    Name? name,
  }) {
    final source = TalkChannel._bulkSource(Uint8List(0), bytes, length)!;
    final sent = _Sent();
    _reply(
      Uint8List(0),
      _name(procedure, name),
      bulk: source,
      onBulk: sent.started,
      onFailure: sent.failed,
    );
    return sent.done;
  }

  void _reply(
    Uint8List payload,
    Name? procedure, {
    _BulkSource? bulk,
    void Function(_BulkOut out)? onBulk,
    void Function(SwitchboardException error)? onFailure,
  }) {
    _check();
    _sendReply(
      () => channel._sendFrame(
        TalkFrame(
          kind: TalkKind.message,
          procedure: procedure,
          responseId: requestId,
          payload: payload,
        ),
        bulk: bulk,
        onBulk: (out) {
          out.track(_bulkOuts);
          onBulk?.call(out);
        },
        onFailure: onFailure,
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
    _BulkSource? bulk,
  }) {
    _check();
    return _sendReply(
      () => channel._startRequest(
        stream: stream,
        timeout: timeout,
        onExtend: onExtend,
        sink: sink,
        bulk: bulk,
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

  @override
  Future<void> replyItemBulk(
    Stream<List<int>> bytes, {
    int? length,
    String? procedure,
    Name? name,
  }) {
    final source = TalkChannel._bulkSource(Uint8List(0), bytes, length)!;
    final sent = _Sent();
    _replyItem(
      Uint8List(0),
      _name(procedure, name),
      bulk: source,
      onBulk: sent.started,
      onFailure: sent.failed,
    );
    return sent.done;
  }

  void _replyItem(
    Uint8List payload,
    Name? procedure, {
    _BulkSource? bulk,
    void Function(_BulkOut out)? onBulk,
    void Function(SwitchboardException error)? onFailure,
  }) {
    _check(item: true);
    _sendReply(
      () => channel._sendFrame(
        TalkFrame(
          kind: TalkKind.streamItem,
          procedure: procedure,
          responseId: requestId,
          payload: payload,
        ),
        bulk: bulk,
        onBulk: (out) {
          out.track(_bulkOuts);
          // An item's payload going out is progress, as the item was.
          out.onProgress = _replied;
          onBulk?.call(out);
        },
        onFailure: onFailure,
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
    _BulkSource? bulk,
  }) {
    _check(item: true);
    final pending = _sendReply(
      () => channel._startRequest(
        stream: stream,
        timeout: timeout,
        onExtend: onExtend,
        sink: sink,
        bulk: bulk,
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
    if (left > _maxTimerDelay) {
      _timer = Timer(_maxTimerDelay, () {
        _timer = null;
        _arm();
      });
    } else {
      _timer = Timer(left, _onTimeout);
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
  /// Never while the final reply is being sent: that is the one final.
  /// Guards this send too, since a synchronous peer may cancel during it.
  void _abortQuietly(Status status) {
    if (_finished || _finalizing || !expectsReply) {
      return;
    }
    _sendReply(() => channel._rejectRequest(requestId, status), isFinal: true);
  }

  /// The listener this request was delivered to threw before answering it:
  /// answers `ABORT INTERNAL` on its behalf and, as on the responder
  /// timeout, marks the request cancelled, so that work started on it (a
  /// [forwardMessage] of it included) stops.
  void _handlerFailed() {
    if (_finished || _finalizing || !expectsReply) {
      return;
    }
    _abortQuietly(Status.of(StatusCode.internal, 'message handler failed'));
    _markCancelled();
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
    // Answered: a payload the application did not read is not needed.
    _bulk?.abandon();
  }

  void _markCancelled([Status? status]) {
    if (_cancelled) {
      return;
    }
    _cancelled = true;
    _cancelStatus = status;
    // The request's own payload and the payloads of the replies to it
    // stop.
    final cancelled = Status.of(StatusCode.cancelled, 'request cancelled');
    _bulk?.close(cancelled);
    _bulk?.abandon();
    if (!_ready) {
      _drop();
    }
    for (final out in _bulkOuts) {
      out.cancel(cancelled);
    }
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
  _GuardedStream(this._source, this._undelivered, this._held);

  final Stream<TalkMessage> _source;
  final Queue<_Message> _undelivered;
  final _Held _held;

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
        _held,
      )
      ..onData(onData)
      ..onError(onError);
  }
}

class _GuardedSubscription extends DelegatingStreamSubscription<TalkMessage> {
  _GuardedSubscription(super.sourceSubscription, this._undelivered, this._held);

  final Queue<_Message> _undelivered;

  /// The credit of the frames the source holds: what reaches the listener
  /// goes back to the peer (the delivery point of flow control).
  final _Held _held;

  @override
  void onData(void Function(TalkMessage data)? handleData) {
    super.onData((message) {
      if (message is _Message) {
        message.channel._creditMessage(message, _held);
      }
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
          message._handlerFailed();
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

/// The credit of the frames a stream controller holds for its listener:
/// their wire bytes, returned one by one as they are delivered, all at once
/// when the subscription is cancelled ([drained]).
class _Held {
  int bytes = 0;
  int frames = 0;

  /// The messages held whose bulk payload is a stream nobody read yet.
  final List<_Message> bulk = [];

  /// Reassembled payloads whose memory budget lasts until delivery, even
  /// after a stream request ends and returns its parent-frame credit.
  final Set<_Message> assembled = {};

  /// Counts the credit of [message], added to the controller, and, with
  /// [trackBulk], its streamed bulk payload.
  void hold(_Message message, {bool trackBulk = true}) {
    if (message._assemblyBytes > 0) {
      assembled.add(message);
    }
    if (message._creditBytes != 0) {
      bytes += message._creditBytes;
      frames++;
    }
    if (trackBulk && message._bulk != null && message._streamBulk) {
      message._heldBulk = true;
      bulk.add(message);
    }
  }

  /// The controller delivers nothing more; its credit went back.
  bool drained = false;
}

/// How a bulk reply ended, for [TalkMessage.replyBulk]: the transfer's own
/// end once it started, or the failure of a frame that waited for the
/// peer's LIMITS.
class _Sent {
  final Completer<void> _done = Completer<void>()..future.ignore();

  Future<void> get done => _done.future;

  void started(_BulkOut out) {
    if (!_done.isCompleted) {
      _done.complete(out.done);
    }
  }

  void failed(SwitchboardException error) {
    if (!_done.isCompleted) {
      _done.completeError(error);
    }
  }
}
