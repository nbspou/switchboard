import 'dart:typed_data';

import 'package:switchboard/src/address/service_address.dart';
import 'package:switchboard/src/bytes.dart';
import 'package:switchboard/src/name.dart';
import 'package:switchboard/src/naming/naming_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('REGISTER npc, assign id, one endpoint', () {
    final bytes = hexBytes(
      '6E 70 63 00 00 00 00 00 00 00 00 00 00 00 01 13 74 63 70 3A 2F 2F 31 '
      '30 2E 30 2E 30 2E 35 3A 39 31 30 31 00 00',
    );
    final r = RegisterRequest.decode(bytes);
    expect(r.type, Name('npc'));
    expect(r.requestedInstance, 0);
    expect(r.endpoints, [Uri.parse('tcp://10.0.0.5:9101')]);
    expect(r.metadata, isEmpty);
    expect(r.encode(), bytes);
  });

  test('REGISTER response, instance 5', () {
    final bytes = hexBytes('05 00 00 00 00 00');
    expect(RegisterResponse.decode(bytes).instance, 5);
    expect(const RegisterResponse(5).encode(), bytes);
  });

  test('UNREGSTR npc instance 5', () {
    final bytes = hexBytes('6E 70 63 00 00 00 00 00 05 00 00 00 00 00');
    final r = UnregisterRequest.decode(bytes);
    expect(r.type, Name('npc'));
    expect(r.instance, 5);
    expect(r.encode(), bytes);
  });

  test('WATCH all (empty payload)', () {
    final r = WatchRequest.decode(Uint8List(0));
    expect(r.type, isNull);
    expect(r.encode(), isEmpty);
  });

  test('WATCH type npc', () {
    final bytes = hexBytes('6E 70 63 00 00 00 00 00');
    final r = WatchRequest.decode(bytes);
    expect(r.type, Name('npc'));
    expect(r.encode(), bytes);
  });

  test('WATCH all-zero name is all', () {
    expect(WatchRequest.decode(Uint8List(8)).type, isNull);
  });

  test('UP npc instance 5, no endpoints', () {
    final bytes = hexBytes(
      '6E 70 63 00 00 00 00 00 05 00 00 00 00 00 00 00 00',
    );
    final e = ServiceEvent.decodeUp(bytes);
    expect(e.up, isTrue);
    expect(e.record.address, ServiceAddress(Name('npc'), 5));
    expect(e.record.endpoints, isEmpty);
    expect(e.record.metadata, isEmpty);
    expect(e.encode(), bytes);
  });

  test('UP npc instance 5, no endpoints, metadata 01 02 03', () {
    final bytes = hexBytes(
      '6E 70 63 00 00 00 00 00 05 00 00 00 00 00 00 03 00 01 02 03',
    );
    final e = ServiceEvent.decodeUp(bytes);
    expect(e.up, isTrue);
    expect(e.record.address, ServiceAddress(Name('npc'), 5));
    expect(e.record.endpoints, isEmpty);
    expect(e.record.metadata, [1, 2, 3]);
    expect(e.encode(), bytes);
  });

  test('a record without the metadata field has empty metadata', () {
    final bytes = hexBytes('6E 70 63 00 00 00 00 00 05 00 00 00 00 00 00');
    final e = ServiceEvent.decodeUp(bytes);
    expect(e.record.address, ServiceAddress(Name('npc'), 5));
    expect(e.record.metadata, isEmpty);
    expect(e.encode(), hexBytes('${hexString(bytes)} 00 00'));
  });

  test('DOWN npc instance 5', () {
    final bytes = hexBytes('6E 70 63 00 00 00 00 00 05 00 00 00 00 00');
    final e = ServiceEvent.decodeDown(bytes);
    expect(e.up, isFalse);
    expect(e.record.address, ServiceAddress(Name('npc'), 5));
    expect(e.encode(), bytes);
  });

  test('SYNCED is empty and procedure names are as specified', () {
    expect(Procedures.synced.toString(), 'SYNCED');
    expect(Procedures.register.bytes, hexBytes('52 45 47 49 53 54 45 52'));
    expect(Procedures.unregister.toString(), 'UNREGSTR');
    expect(Services.naming.bytes, hexBytes('5F 6E 73 00 00 00 00 00'));
  });
}
