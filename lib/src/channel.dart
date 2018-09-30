import 'dart:async';
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

  void _onFrame(Uint8List frame) {
    try
    {
      int offset = frame.offsetInBytes;
      ByteBuffer buffer = frame.buffer;
      int flags = frame[0];
      bool hasProcedureId = (flags & 0x01) != 0;
      bool hasRequestId = (flags & 0x02) != 0;
      bool hasResponseId = (flags & 0x03) != 0;
      int o = 1;
      Uint8List procedureId = Uint8List(8);
      int requestId = 0;
      int responseId = 0;
      if (hasProcedureId) {
        procedureId = buffer.asUint8List(offset + o, 8);
        o += 8;
      }
      if (hasRequestId) {
        requestId = (frame[o++]) | (frame[o++] << 8) | (frame[o++] << 16);
      }
      if (hasResponseId) {
        responseId = (frame[o++]) | (frame[o++] << 8) | (frame[o++] << 16);
      }
      Uint8List subFrame = buffer.asUint8List(offset + o);
    } catch (error, stack) {
      // TODO: Error while handling channel frame, channel closed.
      close();
    }
  }

  void _listen() {
    _raw.listen(_onFrame);
  }
}
