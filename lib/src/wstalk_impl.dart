import 'dart:async';

import 'wstalk_message.dart';

class RemoteResponseState {
  final int id;
  final Completer<TalkMessage> completer;
  final Timer timer;
  const RemoteResponseState(this.id, this.completer, this.timer);
}
