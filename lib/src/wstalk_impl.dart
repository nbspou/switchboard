
import 'dart:async';

import 'wstalk_message.dart';

class RemoteResponseState {
  final Completer<TalkMessage> completer;
  final Timer timer;
  const RemoteResponseState(this.completer, this.timer);
}
