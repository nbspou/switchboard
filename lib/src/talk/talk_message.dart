/*
Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Author: Jan Boon <jan.boon@kaetemi.be>
*/

import 'dart:async';
import 'dart:typed_data';

import 'package:logging/logging.dart';

import '../name.dart';
import '../status.dart';
import 'talk_channel.dart';
import 'talk_frame.dart';
import 'talk_request.dart';
import 'talk_stream.dart';

final Logger _log = Logger('Switchboard.Talk');

/// A message received on a [TalkChannel]: a plain message, a request, a
/// final response, or a stream item.
///
/// Plain messages and requests arrive on [TalkChannel.messages]. Responses
/// arrive through the requester's `Future`, [TalkRequest] or [TalkStream].
/// Any of them may itself be a request ([expectsReply]), in which case the
/// reply API below answers it; this is how message chains continue.
///
/// Every reply method that takes a `procedure` string also takes a [Name]
/// `name`, which, when given, is sent instead (the string is then
/// ignored): generated code passes the exact wire name, which need not be
/// valid UTF-8.
///
/// Instances are created by [TalkChannel] only.
abstract class TalkMessage {
  /// The channel the message arrived on.
  TalkChannel get channel;

  /// The decoded wire frame.
  TalkFrame get frame;

  /// [TalkKind.message] or [TalkKind.streamItem].
  TalkKind get kind => frame.kind;

  /// The procedure, or [Name.empty] if the sender omitted it.
  Name get procedure => frame.procedure ?? Name.empty;

  /// The procedure as a string. Bytes that are not valid UTF-8 are replaced,
  /// so use [procedure] to compare or pass names on.
  String get procedureName => procedure.toString();

  /// The payload. It may be a view into the received buffer.
  Uint8List get payload => frame.payload;

  /// The peer's request id, or 0 if the peer expects no reply.
  int get requestId => frame.requestId;

  /// The id of our request this message responds to, or 0 if it is not a
  /// response.
  int get responseId => frame.responseId;

  /// True when the peer expects a reply ([requestId] is not 0).
  bool get expectsReply => requestId != 0;

  /// True when the peer accepts stream items before the final reply.
  bool get expectsStream => frame.stream;

  /// True once the peer cancelled this request, or once the request can no
  /// longer be answered: the responder timeout expired, the channel closed,
  /// or the peer reused its id. Work on the request should stop.
  bool get isCancelled;

  /// Completes when [isCancelled] becomes true. Never completes for a
  /// message that expects no reply, or for a request answered before any
  /// of those events.
  ///
  /// When the peer cancels the request, the channel itself answers it at
  /// once with `ABORT CANCELLED`, as the protocol requires a final for every
  /// request. The request is then finished: [canReply] is false and the
  /// reply methods throw [StatusCode.failedPrecondition], as after the
  /// responder timeout. The application only has to stop working.
  Future<void> get onCancel;

  /// True while a reply method may still be called: the message expects a
  /// reply, no final reply was sent (by the application, by the responder
  /// timeout, or by the channel), and the channel is open.
  bool get canReply;

  /// Sends the final response.
  ///
  /// [procedure] is optional on responses; the requester knows what it
  /// asked. For a stream request this is the end of the stream and may
  /// carry a trailing [payload].
  ///
  /// Throws [SwitchboardException] with [StatusCode.failedPrecondition] if
  /// the message expects no reply, was already finally replied (including
  /// by the responder timeout or because the peer cancelled it), or the
  /// channel is closed.
  void reply(Uint8List payload, {String? procedure, Name? name});

  /// Sends the final response as a request of our own (a chained response)
  /// and returns the peer's answer to it. Shorthand for
  /// [startReplyRequest] followed by [TalkRequest.response].
  ///
  /// The returned future fails like [TalkRequest.response]. It never
  /// reports an unhandled error, so it may be dropped.
  ///
  /// Throws synchronously like [startReplyRequest].
  Future<TalkMessage> replyRequest(
    Uint8List payload, {
    String? procedure,
    Duration? timeout,
    Name? name,
  });

  /// Sends the final response as a request of our own (a chained response)
  /// and returns its handle.
  ///
  /// [timeout] is the requester timeout for the chained request (default
  /// [TalkOptions.requestTimeout], [Duration.zero] disables it). [onExtend]
  /// is called synchronously each time the peer sends `EXTEND` for it.
  ///
  /// Throws synchronously like [reply], and with
  /// [StatusCode.resourceExhausted] if [TalkOptions.maxOutgoingRequests]
  /// is reached (nothing is sent and this message stays unanswered).
  TalkRequest startReplyRequest(
    Uint8List payload, {
    String? procedure,
    Duration? timeout,
    void Function()? onExtend,
    Name? name,
  });

  /// Sends the final response as a stream request of our own.
  ///
  /// Takes and throws like [startReplyRequest].
  TalkStream replyStreamRequest(
    Uint8List payload, {
    String? procedure,
    Duration? timeout,
    void Function()? onExtend,
    Name? name,
  });

  /// Sends one stream item. Restarts the responder timeout.
  ///
  /// Throws [SwitchboardException] with [StatusCode.failedPrecondition]
  /// like [reply], and also if the request is not a stream request
  /// ([expectsStream] is false).
  void replyItem(Uint8List payload, {String? procedure, Name? name});

  /// Sends one stream item that is itself a request, and returns the peer's
  /// answer to it. Shorthand for [startReplyItemRequest] followed by
  /// [TalkRequest.response]; the future never reports an unhandled error.
  ///
  /// Throws synchronously like [startReplyItemRequest].
  Future<TalkMessage> replyItemRequest(
    Uint8List payload, {
    String? procedure,
    Duration? timeout,
    Name? name,
  });

  /// Sends one stream item that is itself a request, and returns its
  /// handle. Restarts the responder timeout.
  ///
  /// Takes [timeout] and [onExtend] like [startReplyRequest]. Throws
  /// synchronously like [replyItem] and [startReplyRequest].
  TalkRequest startReplyItemRequest(
    Uint8List payload, {
    String? procedure,
    Duration? timeout,
    void Function()? onExtend,
    Name? name,
  });

  /// Sends one stream item that is itself a stream request. Restarts the
  /// responder timeout.
  ///
  /// Takes and throws like [startReplyItemRequest].
  TalkStream replyItemStreamRequest(
    Uint8List payload, {
    String? procedure,
    Duration? timeout,
    void Function()? onExtend,
    Name? name,
  });

  /// Answers a stream request with [items]: each one is sent with
  /// [replyItem] as it arrives, then the final reply carries [trailer]
  /// (empty by default). [procedure] or [name] go with every item and the
  /// final reply.
  ///
  /// An error event on [items] ends the answer with [replyAbort]: the
  /// error's status if it is a [SwitchboardException] (a
  /// [TalkAbortException] from a backend passes its status on), otherwise
  /// `INTERNAL` (the error is logged). An item that cannot be sent (for
  /// example over the peer's frame limit) aborts the request the same way
  /// with its status.
  ///
  /// When the request is cancelled ([onCancel]: the peer cancelled it, the
  /// responder timeout expired, or the channel closed) the subscription to
  /// [items] is cancelled and nothing more is sent; when the peer
  /// cancelled, the channel has already answered `ABORT CANCELLED`. Each
  /// item restarts the responder timeout; a source slower than
  /// [TalkOptions.replyTimeout] between items should be paired with
  /// [setReplyTimeout] or [extend].
  ///
  /// The future completes once the answer has ended (or the subscription
  /// was cancelled); it never completes with an error. Throws
  /// synchronously, without listening to [items], like [replyItem] (also
  /// if the request is not a stream request) and with [ArgumentError] if
  /// [procedure] is not a valid name.
  Future<void> replyStream(
    Stream<Uint8List> items, {
    Uint8List? trailer,
    String? procedure,
    Name? name,
  }) {
    final wire = name ?? (procedure == null ? null : Name(procedure));
    _checkStreamReply();
    final done = Completer<void>();
    late final StreamSubscription<Uint8List> subscription;
    void finish() {
      if (!done.isCompleted) {
        done.complete();
      }
    }

    void stop() {
      unawaited(subscription.cancel().whenComplete(finish));
    }

    void abort(Object error, StackTrace stackTrace) {
      var status = error is SwitchboardException
          ? error.status
          : Status.of(StatusCode.internal, 'stream failed');
      if (error is! SwitchboardException) {
        _log.warning(
          'stream reply to request $requestId failed',
          error,
          stackTrace,
        );
      }
      if (status.isOk) {
        status = Status.of(StatusCode.internal, 'stream failed');
      }
      if (canReply) {
        try {
          replyAbort(status);
        } on SwitchboardException catch (e) {
          _log.fine('stream reply abort not sent: ${e.status}');
        }
      }
    }

    subscription = items.listen(
      (item) {
        if (!canReply) {
          stop();
          return;
        }
        try {
          replyItem(item, name: wire);
        } on SwitchboardException catch (e, st) {
          abort(e, st);
          stop();
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        abort(error, stackTrace);
        stop();
      },
      onDone: () {
        if (canReply) {
          try {
            reply(trailer ?? Uint8List(0), name: wire);
          } on SwitchboardException catch (e, st) {
            abort(e, st);
          }
        }
        finish();
      },
      cancelOnError: true,
    );
    onCancel.then((_) => stop()).ignore();
    return done.future;
  }

  /// Throws like [replyItem] when no stream answer can start.
  void _checkStreamReply() {
    if (!expectsReply || !expectsStream || !canReply) {
      throw SwitchboardException.of(
        StatusCode.failedPrecondition,
        !expectsReply
            ? 'message expects no reply'
            : !expectsStream
            ? 'request $requestId is not a stream request'
            : 'request $requestId cannot be answered',
      );
    }
  }

  /// Sends the final response as an abort carrying [status]. Application
  /// codes (256 and above) are allowed. [StatusCode.connectionLost], which
  /// never goes on the wire, is sent as [StatusCode.unavailable].
  ///
  /// For an unknown procedure the convention is
  /// `replyAbort(Status.of(StatusCode.unimplemented))`.
  ///
  /// Throws [ArgumentError] if [status] is OK (an abort cannot report
  /// success), otherwise throws like [reply].
  void replyAbort(Status status);

  /// Tells the requester that work continues: sends `EXTEND`, which
  /// restarts the requester's timeout, and restarts the local responder
  /// timeout.
  ///
  /// Throws like [reply].
  void extend();

  /// Overrides the responder timeout for this request:
  /// [TalkOptions.replyTimeout] when [timeout] is null, none when it is
  /// [Duration.zero].
  ///
  /// Applies immediately: the responder timeout restarts with the new
  /// duration. Later restarts ([replyItem], [extend]) use it too. Does
  /// nothing once the request is finished or for a message that expects no
  /// reply.
  void setReplyTimeout(Duration? timeout);
}
