import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:wstalk/src/message.dart';
import 'package:wstalk/src/raw_channel.dart';

abstract class Channel {
  RawChannel _raw;
  Channel(RawChannel raw) {
    _raw = raw;
    _listen();
  }

  Future<void> get done => _raw.done;

  Future<void> close() {
    _raw.close();
  }

  /// A message was received from the remote host.
  void onMessage(Message message);

  void _onMessage(Message message) {
    onMessage(message);
  }

  void _onFrame(Uint8List frame) {
    try
    {
      // Parse general header of the message
      int offset = frame.offsetInBytes;
      ByteBuffer buffer = frame.buffer;
      int flags = frame[0];
      bool hasProcedureId = (flags & 0x01) != 0;
      bool hasRequestId = (flags & 0x02) != 0;
      bool hasResponseId = (flags & 0x04) != 0;
      int o = 1;
      Uint8List procedureIdRaw = Uint8List(8);
      int requestId = 0;
      int responseId = 0;
      if (hasProcedureId) {
        procedureIdRaw = buffer.asUint8List(offset + o, 8);
        o += 8;
      }
      if (hasRequestId) {
        requestId = (frame[o++]) | (frame[o++] << 8) | (frame[o++] << 16);
      }
      if (hasResponseId) {
        responseId = (frame[o++]) | (frame[o++] << 8) | (frame[o++] << 16);
      }
      Uint8List subFrame = buffer.asUint8List(offset + o);
      String procedureId = utf8.decode(procedureIdRaw.takeWhile((c) => c != 0));
      // This message expects a stream response (if not set, can only send timeout extend stream response)
      // bool expectStreamResponse = (flags & 0x08) != 0; // not necessary
      // This message is a stream response (a non-stream-response signals end-of-stream)
      bool isStreamResponse = (flags & 0x30) == 0x10;
      // Timeout extend message (must be a stream response) (an extend message with a request id extends the timeout)
      bool isTimeoutExtend = (flags & 0x30) == 0x30;
      // Abort message (must be non-stream response) (an abort message with a request id is a request cancellation)
      bool isAbort = (flags & 0x30) == 0x20;
      _onMessage(new Message()); // TODO -------------
    } catch (error, stack) {
      // TODO: Error while handling channel frame, channel closed.
      close();
    }
  }

  void _listen() {
    _raw.listen(_onFrame);
  }

  void sendMessage() {

  }

  void sendStreamRequest() {

  }

  void sendRequest() {

  }

  void replyMessageStream() {

  }

  void replyRequestStream() {
    
  }

  void replyStreamRequestStream() {

  }

  void replyMessage() {

  }

  void replyRequest() {
    
  }

  void replyStreamRequest() {

  }
}
