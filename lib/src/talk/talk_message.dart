/*
Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Author: Jan Boon <jan.boon@kaetemi.be>
*/

import 'dart:typed_data';

import '../name.dart';
import '../status.dart';
import 'talk_channel.dart';
import 'talk_frame.dart';
import 'talk_stream.dart';

/// A message received on a [TalkChannel]: a plain message, a request, a
/// final response, or a stream item.
///
/// Plain messages and requests arrive on [TalkChannel.messages]. Responses
/// arrive through the requester's `Future` or [TalkStream]. Any of them may
/// itself be a request ([expectsReply]), in which case the reply API below
/// answers it; this is how message chains continue.
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

  /// The procedure as a string.
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
  /// by the responder timeout), or the channel is closed.
  void reply(Uint8List payload, {String? procedure});

  /// Sends the final response as a request of our own (a chained response)
  /// and returns the peer's answer to it.
  ///
  /// The returned future fails with [SwitchboardException] carrying the
  /// peer's abort status, [StatusCode.deadlineExceeded] if no response
  /// arrives within [timeout] (default [TalkOptions.requestTimeout]), or the
  /// channel's failure status. [Duration.zero] disables the timeout.
  ///
  /// Throws synchronously like [reply], and with
  /// [StatusCode.resourceExhausted] if [TalkOptions.maxOutgoingRequests]
  /// is reached (nothing is sent and this message stays unanswered).
  Future<TalkMessage> replyRequest(
    Uint8List payload, {
    String? procedure,
    Duration? timeout,
  });

  /// Sends the final response as a stream request of our own.
  ///
  /// Throws synchronously like [replyRequest].
  TalkStream replyStreamRequest(
    Uint8List payload, {
    String? procedure,
    Duration? timeout,
  });

  /// Sends one stream item. Restarts the responder timeout.
  ///
  /// Throws [SwitchboardException] with [StatusCode.failedPrecondition]
  /// like [reply], and also if the request is not a stream request
  /// ([expectsStream] is false).
  void replyItem(Uint8List payload, {String? procedure});

  /// Sends one stream item that is itself a request, and returns the peer's
  /// answer to it. Restarts the responder timeout.
  ///
  /// Throws synchronously like [replyItem] and [replyRequest].
  Future<TalkMessage> replyItemRequest(
    Uint8List payload, {
    String? procedure,
    Duration? timeout,
  });

  /// Sends the final response as an abort carrying [status]. Application
  /// codes (256 and above) are allowed.
  ///
  /// For an unknown procedure the convention is
  /// `replyAbort(Status.of(StatusCode.unimplemented))`.
  ///
  /// Throws like [reply].
  void replyAbort(Status status);

  /// Tells the requester that work continues: sends `EXTEND`, which
  /// restarts the requester's timeout, and restarts the local responder
  /// timeout.
  ///
  /// Throws like [reply].
  void extend();
}
