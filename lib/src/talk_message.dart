import 'dart:typed_data';

class TalkMessage {
  final String procedureId;
  final int requestId;
  final int responseId;
  final Uint8List data;
  const TalkMessage(
      this.procedureId, this.requestId, this.responseId, this.data);
  bool operator ==(dynamic message) {
    if (!(message is TalkMessage)) {
      return false;
    }
    if (message.procedureId != procedureId ||
        message.requestId != requestId ||
        message.responseId != responseId) {
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
    return procedureId.hashCode ^
        requestId.hashCode ^
        responseId.hashCode ^
        data.hashCode;
  }

  @override
  String toString() {
    return "TalkMessage: $procedureId, $requestId, $responseId, $data";
  }
}
