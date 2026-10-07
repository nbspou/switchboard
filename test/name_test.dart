/*
Polyverse Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Authors:
  Jan Boon <jan.boon@kaetemi.be>
  Claude Fable 5.1 <noreply@anthropic.com>
*/

import 'package:switchboard/core.dart';
import 'package:test/test.dart';

void main() {
  group('Name', () {
    test('vectors', () {
      expect(hexString(Name('').bytes), '00 00 00 00 00 00 00 00');
      expect(hexString(Name('api').bytes), '61 70 69 00 00 00 00 00');
      expect(hexString(Name('REGISTER').bytes), '52 45 47 49 53 54 45 52');
      expect(hexString(Name('_ns').bytes), '5F 6E 73 00 00 00 00 00');
      expect(hexString(Name('é').bytes), 'C3 A9 00 00 00 00 00 00');
    });

    test('round trips', () {
      for (final s in ['', 'a', 'api', 'REGISTER', 'é', '_ns']) {
        expect(Name.fromBytes(Name(s).bytes).toString(), s);
        expect(Name.fromBytes(Name(s).bytes), Name(s));
        expect(Name.fromBytes(Name(s).bytes).hashCode, Name(s).hashCode);
      }
    });

    test('rejects too long and embedded zero', () {
      expect(() => Name('123456789'), throwsArgumentError);
      expect(() => Name('ééééé'), throwsArgumentError);
      expect(() => Name('a\u0000b'), throwsArgumentError);
    });

    test('rejects bad wire bytes', () {
      expect(
        () => Name.fromBytes(hexBytes('61 00 62 00 00 00 00 00')),
        throwsFormatException,
      );
      expect(() => Name.fromBytes(hexBytes('61 00 00')), throwsFormatException);
    });

    test('properties', () {
      expect(Name('').isEmpty, isTrue);
      expect(Name.empty, Name(''));
      expect(Name('_ns').isReserved, isTrue);
      expect(Name('ns').isReserved, isFalse);
      expect(Name('REGISTER').length, 8);
      expect(Name('é').length, 2);
    });
  });
}
