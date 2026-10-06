/*
Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Author: Jan Boon <jan.boon@kaetemi.be>
*/

import '../status.dart';
import 'talk_channel.dart';
import 'talk_message.dart';
import 'talk_request.dart';

/// Handle for an outgoing stream request, returned by
/// [TalkChannel.streamRequest], [TalkMessage.replyStreamRequest] and
/// [TalkMessage.replyItemStreamRequest]. The single-response counterpart is
/// [TalkRequest].
///
/// Instances are created by [TalkChannel] only.
abstract class TalkStream {
  /// Our request id on the wire, 1 to 0xFFFFFF.
  int get requestId;

  /// The `STREAM_ITEM` responses, in order. Single subscription; items are
  /// buffered until listened.
  ///
  /// Ends normally when the final response arrives. Emits an error and ends
  /// when the request fails: a [TalkAbortException] when the peer aborts
  /// the request or the channel, a plain [SwitchboardException] when the
  /// requester timeout expires ([StatusCode.deadlineExceeded]), the request
  /// is cancelled, or the channel fails. Without an `onError` handler the
  /// error is logged instead of being reported as unhandled; [done] carries
  /// it too.
  ///
  /// Cancelling the subscription while the request is outstanding cancels
  /// the request (as [cancel] does), so leaving an `await for` loop early
  /// stops the peer. Buffered items that expect a reply and were never
  /// delivered are answered with `ABORT CANCELLED`, and so is every item
  /// request arriving afterwards.
  ///
  /// An item that is itself a request ([TalkMessage.expectsReply]) is
  /// answered through its reply API. If the listener throws synchronously
  /// while handling such an item before replying, the error is logged and
  /// the item is answered with `ABORT INTERNAL`.
  Stream<TalkMessage> get items;

  /// The final response. It may carry a trailing payload and may itself be
  /// a request. Fails with the same exception as [items].
  ///
  /// An error on this future is never reported as unhandled, so it is safe
  /// to consume only [items].
  Future<TalkMessage> get done;

  /// Cancels the request: sends a cancel carrying [status] (default
  /// [StatusCode.cancelled]) and fails [items] and [done] with it.
  ///
  /// The request id stays reserved until the peer's final response arrives
  /// or the requester timeout expires (the channel default if the request
  /// has none); anything arriving for it meanwhile is ignored, and item
  /// requests are answered with `ABORT CANCELLED`. Does nothing if the
  /// request already ended.
  void cancel([Status? status]);
}
