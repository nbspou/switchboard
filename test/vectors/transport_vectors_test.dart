// Test vectors from the wiki page "Switchboard Test Vectors", section
// "Transport, stream binding", plus the stream binding rules stated on the
// "Switchboard Transport" page. Platform independent: runs on the VM and,
// compiled to JavaScript, with `dart test -p node test/vectors/`.

import 'dart:typed_data';

import 'package:switchboard/src/bytes.dart';
import 'package:switchboard/src/mux/mux_frame.dart';
import 'package:switchboard/src/status.dart';
import 'package:switchboard/src/transport/stream_framing.dart';
import 'package:test/test.dart';

/// Decodes [bytes] (preamble included) and returns the frames.
List<Uint8List> decodeStream(Uint8List bytes, {int? maxFrameSize}) {
  final decoder = StreamFrameDecoder(
    maxFrameSize: maxFrameSize ?? StreamFraming.defaultMaxFrameSize,
  );
  final frames = <Uint8List>[];
  decoder.add(bytes, frames.add);
  return frames;
}

Matcher throwsStatus(StatusCode code) =>
    throwsA(isA<SwitchboardException>().having((e) => e.code, 'code', code));

void main() {
  const preamble = '53 57 42 44 01 00 00 00';

  group('transport, stream binding', () {
    test('preamble, version 1', () {
      expect(hexString(StreamFraming.encodePreamble()), preamble);
      final decoder = StreamFrameDecoder();
      decoder.add(hexBytes(preamble), (_) => fail('no frame expected'));
      expect(decoder.preambleReceived, isTrue);
      expect(decoder.bufferedBytes, 0);
    });

    test('frame carrying body 02 02 00 AA', () {
      expect(
        hexString(StreamFraming.encodeFrame(hexBytes('02 02 00 AA'))),
        '04 00 00 00 02 02 00 AA',
      );
      final frames = decodeStream(
        hexBytes('$preamble 04 00 00 00 02 02 00 AA'),
      );
      expect(frames.map(hexString), ['02 02 00 AA']);
    });

    test('embedded profile round trip framing', () {
      // From the embedded profile page: transport length 12, mux OPEN ch 2.
      final open = hexBytes('12 02 00 01 64 65 76 00 00 00 00 00');
      expect(
        hexString(StreamFraming.encodeFrame(open)),
        '0C 00 00 00 12 02 00 01 64 65 76 00 00 00 00 00',
      );
      expect(MuxFrame.decode(open).command, MuxCommand.open);
    });

    test('preamble flags are ignored', () {
      final frames = decodeStream(
        hexBytes('53 57 42 44 01 00 FF FF 01 00 00 00 02'),
      );
      expect(frames.map(hexString), ['02']);
    });

    test('wrong magic is a protocol error', () {
      expect(
        () => decodeStream(hexBytes('53 57 42 45 01 00 00 00')),
        throwsA(isA<ProtocolException>()),
      );
    });

    test('unsupported version is UNSUPPORTED, not a protocol error', () {
      expect(
        () => decodeStream(hexBytes('53 57 42 44 02 00 00 00')),
        throwsA(
          isA<SwitchboardException>()
              .having((e) => e.code, 'code', StatusCode.unsupported)
              .having((e) => e is ProtocolException, 'is protocol', false),
        ),
      );
    });

    test('length 0 is a protocol error', () {
      expect(
        () => decodeStream(hexBytes('$preamble 00 00 00 00')),
        throwsA(isA<ProtocolException>()),
      );
      expect(
        () => StreamFraming.encodeFrame(Uint8List(0)),
        throwsArgumentError,
      );
    });

    test('length over the limit is FRAME_TOO_LARGE without the body', () {
      // Only the length is present; the body is never needed.
      expect(
        () => decodeStream(hexBytes('$preamble 05 00 00 00'), maxFrameSize: 4),
        throwsStatus(StatusCode.frameTooLarge),
      );
      expect(
        decodeStream(
          hexBytes('$preamble 04 00 00 00 02 02 00 AA'),
          maxFrameSize: 4,
        ),
        hasLength(1),
      );
    });

    test('lengths with the top bit set are not negative', () {
      // 0x80000000: bitwise operations are 32-bit signed on JavaScript.
      expect(
        () => decodeStream(hexBytes('$preamble 00 00 00 80')),
        throwsStatus(StatusCode.frameTooLarge),
      );
      expect(
        () => decodeStream(hexBytes('$preamble FF FF FF FF')),
        throwsStatus(StatusCode.frameTooLarge),
      );
    });

    test('frames before an error are delivered first', () {
      final decoder = StreamFrameDecoder();
      final frames = <Uint8List>[];
      expect(
        () => decoder.add(
          hexBytes('$preamble 01 00 00 00 02 00 00 00 00'),
          frames.add,
        ),
        throwsA(isA<ProtocolException>()),
      );
      expect(frames.map(hexString), ['02']);
    });
  });
}
