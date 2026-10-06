import 'dart:typed_data';

import 'package:switchboard/core.dart';
import 'package:test/test.dart';

void main() {
  group('Status', () {
    test('encodes code and reason', () {
      expect(
        hexString(Status.of(StatusCode.notFound, 'x').encode()),
        '05 00 78',
      );
      expect(hexString(Status.ok.encode()), '00 00');
      expect(hexString(const Status(0x1234).encode()), '34 12');
    });

    test('decodes', () {
      expect(
        Status.decode(hexBytes('05 00 78')),
        Status.of(StatusCode.notFound, 'x'),
      );
      expect(Status.decode(Uint8List(0)), Status.ok);
      expect(Status.decode(hexBytes('21 00')).known, StatusCode.goingAway);
      expect(Status.decode(hexBytes('00 01')).known, isNull);
      expect(Status.decode(hexBytes('00 01')).isApplicationCode, isTrue);
      expect(() => Status.decode(hexBytes('05')), throwsFormatException);
    });

    test('rejects codes outside u16', () {
      expect(() => const Status(0x10000).encode(), throwsArgumentError);
    });

    test('gRPC numbering', () {
      expect(StatusCode.unauthenticated.code, 16);
      expect(StatusCode.protocolError.code, 32);
      expect(StatusCode.fromCode(14), StatusCode.unavailable);
      expect(StatusCode.fromCode(17), isNull);
    });
  });
}
