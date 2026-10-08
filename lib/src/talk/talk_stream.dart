/*
Polyverse Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Authors:
  Jan Boon <jan.boon@kaetemi.be>
  Claude Opus 5.5 <noreply@anthropic.com>
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
  /// buffered until listened, and while the subscription is paused. As for
  /// [TalkChannel.messages], over a mux channel the credit of an item goes
  /// back to the peer when the item is handed to the listener, so the
  /// channel's window bounds the buffer: a subscription that is paused, or
  /// never made, stalls the whole channel once the window is used up (the
  /// final response included) until the request ends, by its timeout
  /// say, when what the items hold goes back at once (they stay
  /// deliverable). Listen, or cancel the subscription.
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
  /// the item is answered with `ABORT INTERNAL` and marked cancelled.
  Stream<TalkMessage> get items;

  /// The final response. It may carry a trailing payload and may itself be
  /// a request. Fails with the same exception as [items].
  ///
  /// An error on this future is never reported as unhandled, so it is safe
  /// to consume only [items].
  Future<TalkMessage> get done;

  /// When the requester timeout expires unless an answer arrives, as wall
  /// clock time; null when the request has no timeout or has ended. For
  /// observation (a progress display, a log): the timeout itself runs on a
  /// monotonic clock.
  ///
  /// Until the peer declares a deadline or a renewal, it is the last reply
  /// plus the request's timeout, a gap restarted by every reply. After an
  /// `EXTEND` that declares one, it is the later of the declared deadline
  /// (counted from that `EXTEND`'s arrival) and the last reply plus the
  /// declared renewal, each raised to [TalkOptions.minExtension] and
  /// lowered to [TalkOptions.maxExtension]; a later `EXTEND` replaces the
  /// values it carries, and may shorten the deadline. An empty `EXTEND`
  /// restarts the gap, keeping what was declared.
  DateTime? get deadline;

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
