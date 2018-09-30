import 'dart:typed_data';

class Message {
  final String procedureId;
  final int requestId;
  final int responseId;
  final Uint8List data;
  const Message(this.procedureId, this.requestId, this.responseId, this.data);
}
