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

  /// Cancels the request: sends a cancel carrying [status] (default
  /// [StatusCode.cancelled]) and fails [response] with it.
  ///
  /// The request id stays reserved until the peer's final response arrives
  /// or the requester timeout expires (the channel default if the request
  /// has none); anything arriving for it meanwhile is ignored. Does nothing
  /// if the request already ended.
  void cancel([Status? status]);
}
