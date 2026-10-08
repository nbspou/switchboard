/*
Polyverse Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Authors:
  Jan Boon <jan.boon@kaetemi.be>
  Claude Opus 5.5 <noreply@anthropic.com>
*/

part of 'talk_channel.dart';

/// Forwards [incoming], a message received on one channel, to [target]:
/// message chain proxying as described on the wiki page "Switchboard
/// Proxying". An intermediary typically calls it for every message of
/// [TalkChannel.messages] it lets through, in both directions.
///
/// A message that expects no reply is sent on [target] as a plain message;
/// if [target] is closed it is dropped. A request is sent on [target] as a
/// new request with the same procedure, payload and `STREAM` flag, and
/// everything that comes back for it is relayed to [incoming], in order:
///
/// * stream items and `EXTEND`s are passed on as they arrive, an `EXTEND`
///   with its payload unchanged (the deadline and renewal the far
///   responder declared, whose buffer covers the hops);
/// * the final response is passed on as the final reply, with its trailing
///   payload;
/// * an item or final response that is itself a request is forwarded the
///   other way, as an item request or chained response to [incoming], and
///   the answer to it is relayed back the same way, so chains of any depth
///   work in both directions;
/// * an abort response from [target]'s peer is passed on with the same
///   status;
/// * every other failure of the forwarded request (the channel to the
///   target lost or closed, a channel abort, a local limit) is answered
///   with `ABORT UNAVAILABLE`: the intermediary's own failures, such as its
///   `CONNECTION_LOST` or `DEADLINE_EXCEEDED`, are never presented as the
///   far peer's answer;
/// * a cancel of [incoming], or the loss of its channel, cancels the
///   forwarded request. A reply that cannot be delivered also cancels it,
///   including a synchronous reply received while forwarding the request.
///
/// Procedure names and payloads pass through byte for byte, including
/// names that are not valid UTF-8; an absent procedure field on a response
/// stays absent (a request forwarded without one gets the empty name).
///
/// The intermediary imposes no timeouts of its own: the responder timeout
/// of every forwarded request is disabled ([TalkMessage.setReplyTimeout])
/// and the requests it sends have no requester timeout, so the timeouts of
/// the two real peers apply end to end, with `EXTEND` forwarded.
///
/// The returned future completes once [incoming] and every request
/// forwarded on its behalf have ended. It never completes with an error.
/// If [incoming] can no longer be answered (it was already answered or
/// cancelled), nothing is forwarded.
///
/// Throws [ArgumentError] if [incoming] was not received by a
/// [TalkChannel], and [StateError] if it is already being forwarded.
Future<void> forwardMessage(TalkMessage incoming, TalkChannel target) {
  if (incoming is! _Message) {
    throw ArgumentError.value(
      incoming,
      'incoming',
      'not received by a TalkChannel',
    );
  }
  final procedure = incoming.frame.procedure ?? Name.empty;
  final payload = incoming.payload;
  if (!incoming.expectsReply) {
    try {
      target._send(procedure, payload);
    } on SwitchboardException catch (e) {
      _log.fine('forwarded ${incoming.frame} dropped: $e');
    }
    return Future<void>.value();
  }
  final stream = incoming.expectsStream;
  return _Relay.start(
    incoming,
    (relay) => target._startRequest(
      stream: stream,
      timeout: Duration.zero,
      sink: relay,
      build: (id) => TalkFrame(
        kind: TalkKind.message,
        procedure: procedure,
        requestId: id,
        stream: stream,
        payload: payload,
      ),
    ),
  );
}

/// Relays what one forwarded request receives back to the request it was
/// forwarded for.
///
/// The two requests may be on any two channels, in either direction: for
/// a request from the client, [incoming] is on the client channel and the
/// forwarded request on the backend channel; for a request the backend
/// makes in a reply (a chained response or an item request) it is the
/// other way round.
class _Relay implements _ResponseSink {
  _Relay._(this.incoming);

  /// The request answered with whatever the forwarded request receives.
  final _Message incoming;

  /// The forwarded request, once sent.
  _Outgoing? _out;

  /// Cancellation requested while the forwarded request was being sent.
  Status? _cancelWhenSent;

  /// The forwarded request ended.
  bool _ended = false;

  /// Requests forwarded on behalf of replies to [incoming], still going.
  int _nested = 0;

  /// Completes when the forwarded request and every nested one ended.
  final Completer<void> _done = Completer<void>();

  /// Forwards [incoming] with [send], which sends the forwarded request
  /// with the relay as its response sink.
  static Future<void> start(
    _Message incoming,
    _Outgoing Function(_Relay relay) send,
  ) {
    if (incoming._forwarded) {
      throw StateError('request ${incoming.requestId} is already forwarded');
    }
    final relay = _Relay._(incoming);
    if (!incoming.canReply) {
      relay._end();
      return relay._done.future;
    }
    incoming._forwarded = true;
    // The far requester's own timeout applies; EXTEND is forwarded.
    incoming.setReplyTimeout(Duration.zero);
    incoming._cancelHook = relay._onIncomingCancelled;
    try {
      relay._out = send(relay);
    } catch (e, st) {
      final Status status;
      if (e is SwitchboardException) {
        status = e.status;
        _log.fine('request ${incoming.requestId} not forwarded: $e');
      } else {
        status = Status.of(StatusCode.internal);
        _log.severe('forwarding request ${incoming.requestId} failed', e, st);
      }
      relay._abortIncoming(_localFailure(status));
      relay._end();
      return relay._done.future;
    }
    final cancel = relay._cancelWhenSent;
    if (cancel != null) {
      relay._cancelOutgoing(cancel);
    }
    return relay._done.future;
  }

  /// UNAVAILABLE, for a failure of the intermediary itself.
  static Status _localFailure(Status cause) => Status.of(
    StatusCode.unavailable,
    'forwarding failed (${cause.known?.name ?? 'code ${cause.code}'})',
  );

  void _end() {
    if (_ended) {
      return;
    }
    _ended = true;
    incoming._cancelHook = null;
    _checkDone();
  }

  void _addNested(Future<void> nested) {
    _nested++;
    nested.then((_) {
      _nested--;
      _checkDone();
    });
  }

  void _checkDone() {
    if (_ended && _nested == 0 && !_done.isCompleted) {
      _done.complete();
    }
  }

  void _onIncomingCancelled() => _cancelOutgoing(
    incoming._cancelStatus ?? Status.of(StatusCode.cancelled),
  );

  void _cancelOutgoing(Status status) {
    final out = _out;
    if (out == null) {
      _cancelWhenSent ??= status;
      return;
    }
    out.channel._cancelOutgoing(out, status);
  }

  void _abortIncoming(Status status) {
    if (!incoming.canReply) {
      return;
    }
    try {
      incoming._replyAbort(status);
    } on SwitchboardException catch (e) {
      _log.fine('abort of request ${incoming.requestId} not sent: $e');
    }
  }

  /// Sends one response to [incoming]. If that fails, [incoming] is
  /// answered with UNAVAILABLE instead and the forwarded request cancelled.
  void _deliver(void Function() send) {
    if (!incoming.canReply) {
      return;
    }
    try {
      send();
    } on SwitchboardException catch (e) {
      _log.fine('response to request ${incoming.requestId} not sent: $e');
      _abortIncoming(_localFailure(e.status));
      _cancelOutgoing(Status.of(StatusCode.cancelled, 'requester unreachable'));
    }
  }

  @override
  void item(_Message item) {
    if (!item.expectsReply) {
      _deliver(() => incoming._replyItem(item.payload, item.frame.procedure));
      return;
    }
    if (!item.canReply) {
      // Refused by the channel (incoming request limit); the sender
      // already has its answer.
      _log.fine('item request ${item.requestId} refused, not forwarded');
      return;
    }
    _addNested(
      start(
        item,
        (relay) => incoming._startItemRequest(
          item.payload,
          item.frame.procedure,
          stream: item.expectsStream,
          timeout: Duration.zero,
          sink: relay,
        ),
      ),
    );
  }

  @override
  void complete(_Message message) {
    if (!message.expectsReply) {
      _deliver(() => incoming._reply(message.payload, message.frame.procedure));
    } else if (!message.canReply) {
      // The chained request was refused by the channel (incoming request
      // limit), so the chain cannot continue.
      _abortIncoming(_localFailure(Status.of(StatusCode.resourceExhausted)));
    } else {
      _addNested(
        start(
          message,
          (relay) => incoming._startReplyRequest(
            message.payload,
            message.frame.procedure,
            stream: message.expectsStream,
            timeout: Duration.zero,
            sink: relay,
          ),
        ),
      );
      // Sent, the chained request is the final of [incoming], which is then
      // finished and this does nothing. Not sent (over the outgoing request
      // limit of [incoming]'s channel, say), [start] answered [message]
      // only, and [incoming] still needs its final.
      _abortIncoming(_localFailure(Status.of(StatusCode.unavailable)));
    }
    _end();
  }

  @override
  void fail(SwitchboardException error) {
    final remote = error is TalkAbortException && !error.isChannelAbort;
    _abortIncoming(remote ? error.status : _localFailure(error.status));
    _end();
  }

  @override
  void extended(Uint8List payload) {
    // Byte for byte: the far responder's buffer covers the hops.
    _deliver(() => incoming._extendRaw(payload));
  }
}
