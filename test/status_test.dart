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

    test('keeps the bytes after the code as received', () {
      // Fixed fields before the reason (MOVED) need not be valid UTF-8.
      final wire = hexBytes('25 00 FE DC BA 98 76 54 01 00 00 80 78');
      final status = Status.decode(wire);
      expect(status.known, StatusCode.moved);
      expect(status.encode(), wire);
      expect(Status.decode(status.encode()), status);
      expect(status.hashCode, Status.decode(wire).hashCode);
      // Unequal to a status whose reason decodes the same.
      final other = Status.decode(
        hexBytes('25 00 FF DC BA 98 76 54 01 00 00 80 78'),
      );
      expect(other.reason, status.reason);
      expect(other, isNot(status));
      // Equal to a status built from the same text.
      expect(
        Status.decode(hexBytes('05 00 78')),
        Status.of(StatusCode.notFound, 'x'),
      );
      expect(
        Status.decode(hexBytes('05 00 78')).encode(),
        hexBytes('05 00 78'),
      );
      expect(Status.decode(hexBytes('05 00')), const Status(5));
    });

    test('toString shows binary reasons as hex', () {
      expect(Status.of(StatusCode.notFound, 'x').toString(), 'notFound: x');
      expect(Status.of(StatusCode.notFound).toString(), 'notFound');
      expect(
        Status.decode(hexBytes('25 00 2B 1A 00 00 00 00 07 00 00 00'))
            .toString(),
        'moved: [2b 1a 00 00 00 00 07 00 00 00]',
      );
      expect(Status.decode(hexBytes('00 01 FF')).toString(), 'code 256: [ff]');
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
