import 'dart:typed_data';

class TalkMessage {
  final String procedureId;
  final int requestId;
  final int responseId;
  final Uint8List data;
  const TalkMessage(this.procedureId, this.requestId, this.responseId, this.data);
}
