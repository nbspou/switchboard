/*
Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Author: Jan Boon <jan.boon@kaetemi.be>
*/

import '../status.dart';
import 'talk_channel.dart';
import 'talk_message.dart';
import 'talk_stream.dart';

/// Handle for an outgoing request that expects a single final response,
/// returned by [TalkChannel.startRequest], [TalkMessage.startReplyRequest]
/// and [TalkMessage.startReplyItemRequest]. The stream counterpart is
/// [TalkStream].
///
/// Instances are created by [TalkChannel] only.
abstract class TalkRequest {
  /// Our request id on the wire, 1 to 0xFFFFFF.
  int get requestId;

  /// The final response. It may carry a payload and may itself be a request
  /// ([TalkMessage.expectsReply]).
  ///
  /// Fails with a [TalkAbortException] carrying the peer's status when the
  /// peer aborts the request or the channel, and with a plain
  /// [SwitchboardException] for local failures: [StatusCode.deadlineExceeded]
  /// when the requester timeout expires, the cancel status after [cancel],
  /// or the channel's failure status.
  ///
  /// An error on this future is never reported as unhandled, so a request
  /// whose outcome does not matter can simply be dropped.
  Future<TalkMessage> get response;

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
  /// [StatusCode.cancelled]) and fails [response] with it.
  ///
  /// The request id stays reserved until the peer's final response arrives
  /// or the requester timeout expires (the channel default if the request
  /// has none); anything arriving for it meanwhile is ignored. Does nothing
  /// if the request already ended.
  void cancel([Status? status]);
}
