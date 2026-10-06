import 'package:switchboard/core.dart';
import 'package:switchboard/src/bytes.dart';
import 'package:test/test.dart';

void main() {
  test('writer and reader round trip little endian', () {
    final w = ByteWriter(4)
      ..u8(0xAB)
      ..u16(0x1234)
      ..u24(0x123456)
      ..u32(0x12345678)
      ..u48(0x1234567890AB)
      ..name(Name('api'))
      ..string8('hi')
      ..bytes([1, 2, 3]);
    final bytes = w.toBytes();
    expect(
      hexString(bytes),
      'AB 34 12 56 34 12 78 56 34 12 AB 90 78 56 34 12 '
      '61 70 69 00 00 00 00 00 02 68 69 01 02 03',
    );
    final r = ByteReader(bytes);
    expect(r.u8(), 0xAB);
    expect(r.u16(), 0x1234);
    expect(r.u24(), 0x123456);
    expect(r.u32(), 0x12345678);
    expect(r.u48(), 0x1234567890AB);
    expect(r.name(), Name('api'));
    expect(r.string8(), 'hi');
    expect(r.rest(), [1, 2, 3]);
    expect(r.isDone, isTrue);
  });

  test('reader throws on truncation', () {
    expect(() => ByteReader(hexBytes('01')).u16(), throwsFormatException);
    expect(
      () => ByteReader(hexBytes('03 61')).string8(),
      throwsFormatException,
    );
    expect(() => ByteReader(hexBytes('')).name(), throwsFormatException);
  });

  test('hex helpers', () {
    expect(hexBytes('0a 0B0c'), [10, 11, 12]);
    expect(() => hexBytes('abc'), throwsFormatException);
  });

  test('u32 and u48 high values survive 32-bit arithmetic', () {
    final w = ByteWriter()
      ..u32(0xFFFFFFFF)
      ..u48(0xFFFFFFFFFFFF)
      ..u48(0x100000002)
      ..u48(0xFFFF00000000);
    expect(
      hexString(w.toBytes()),
      'FF FF FF FF FF FF FF FF FF FF 02 00 00 00 01 00 00 00 00 00 FF FF',
    );
    final r = ByteReader(w.toBytes());
    expect(r.u32(), 0xFFFFFFFF);
    expect(r.u48(), 0xFFFFFFFFFFFF);
    expect(r.u48(), 0x100000002);
    expect(r.u48(), 0xFFFF00000000);
  });
}
