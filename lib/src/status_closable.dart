/*
Polyverse Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Authors:
  Jan Boon <jan.boon@kaetemi.be>
  Claude Opus 5.5 <noreply@anthropic.com>
*/

import 'status.dart';

/// Implemented by channels that can be closed with a status (the mux
/// channel).
///
/// When the raw channel of a `TalkChannel` implements this, the talk
/// channel closes it with the talk-level status and takes its end status
/// from [done].
abstract interface class StatusClosable {
  /// Closes the channel, reporting [status] to the peer.
  Future<void> close([Status status]);

  /// The channel's end status, once it is closed.
  Future<Status> get done;
}
