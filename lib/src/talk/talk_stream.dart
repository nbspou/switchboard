/*
Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Author: Jan Boon <jan.boon@kaetemi.be>
*/

import '../status.dart';
import 'talk_channel.dart';
import 'talk_message.dart';

/// Handle for an outgoing stream request, returned by
/// [TalkChannel.streamRequest] and [TalkMessage.replyStreamRequest].
///
/// Instances are created by [TalkChannel] only.
abstract class TalkStream {
  /// Our request id on the wire, 1 to 0xFFFFFF.
  int get requestId;

  /// The `STREAM_ITEM` responses, in order. Single subscription; items are
  /// buffered until listened.
  ///
  /// Ends normally when the final response arrives. Emits a
  /// [SwitchboardException] and ends when the peer aborts the request, the
  /// requester timeout expires ([StatusCode.deadlineExceeded]), the request
  /// is cancelled, or the channel fails.
  ///
  /// An item that is itself a request ([TalkMessage.expectsReply]) is
  /// answered through its reply API. If the listener throws synchronously
  /// while handling such an item before replying, the error is logged and
  /// the item is answered with `ABORT INTERNAL`. If the subscription is
  /// cancelled, later items that expect a reply are answered with
  /// `ABORT CANCELLED`.
  Stream<TalkMessage> get items;

  /// The final response. It may carry a trailing payload and may itself be
  /// a request. Fails with the same [SwitchboardException] as [items].
  ///
  /// An error on this future is never reported as unhandled, so it is safe
  /// to consume only [items].
  Future<TalkMessage> get done;

  /// Cancels the request: sends a cancel carrying [status] (default
  /// [StatusCode.cancelled]) and fails [items] and [done] with it.
  ///
  /// The request id stays reserved until the peer's final response arrives
  /// or the requester timeout expires; anything arriving for it meanwhile
  /// is ignored. Does nothing if the request already ended.
  void cancel([Status? status]);
}
