/*
Switchboard
Microservice Network Architecture
Copyright (C) 2018  NO-BREAK SPACE OÜ
Author: Jan Boon <kaetemi@no-break.space>
*/

import 'dart:typed_data';

import 'package:switchboard/src/talk_channel.dart';

class TalkMessage {
  final TalkChannel channel;
  final String procedureId;
  final int requestId;
  final int responseId;
  final bool expectStreamResponse;
  final Uint8List data;
  const TalkMessage(this.channel, this.procedureId, this.requestId,
      this.responseId, this.expectStreamResponse, this.data);
  bool operator ==(dynamic message) {
    if (!(message is TalkMessage)) {
      return false;
    }
    if (message.channel != channel ||
        message.procedureId != procedureId ||
        message.requestId != requestId ||
        message.responseId != responseId ||
        message.expectStreamResponse != expectStreamResponse) {
      return false;
    }
    bool equalData = message.data == data;
    if (!equalData && message.data != null && data != null) {
      if (message.data.length == data.length) {
        equalData = true;
        for (int i = 0; i < data.length; ++i) {
          if (message.data[i] != data[i]) {
            equalData = false;
            break;
          }
        }
      }
    }
    return equalData;
  }

  int get hashCode {
    return channel.hashCode ^
        procedureId.hashCode ^
        requestId.hashCode ^
        responseId.hashCode ^
        expectStreamResponse.hashCode ^
        data.hashCode;
  }

  @override
  String toString() {
    return "TalkMessage: $procedureId, $requestId, $responseId, $expectStreamResponse, $data";
  }
}

/* end of file */
