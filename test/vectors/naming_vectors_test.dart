/*
Polyverse Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Authors:
  Jan Boon <jan.boon@kaetemi.be>
  Claude Opus 5.5 <noreply@anthropic.com>
  Claude Sonnet 5.5 <noreply@anthropic.com>
*/

import 'dart:typed_data';

import 'package:switchboard/src/address/service_address.dart';
import 'package:switchboard/src/bytes.dart';
import 'package:switchboard/src/name.dart';
import 'package:switchboard/src/naming/naming_protocol.dart';
import 'package:switchboard/src/status.dart';
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

  // UNWATCH carries the payload of the WATCH it gives back.
  test('UNWATCH all (empty payload)', () {
    final r = WatchRequest.decode(Uint8List(0));
    expect(r.type, isNull);
    expect(r.encode(), isEmpty);
  });

  test('UNWATCH type npc', () {
    final bytes = hexBytes('6E 70 63 00 00 00 00 00');
    final r = WatchRequest.decode(bytes);
    expect(r.type, Name('npc'));
    expect(r.encode(), bytes);
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

  test('procedure names are as specified', () {
    expect(Procedures.register.bytes, hexBytes('52 45 47 49 53 54 45 52'));
    expect(Procedures.unregister.toString(), 'UNREGSTR');
    expect(Procedures.watch.toString(), 'WATCH');
    expect(Procedures.unwatch.bytes, hexBytes('55 4E 57 41 54 43 48 00'));
    expect(Services.naming.bytes, hexBytes('5F 6E 73 00 00 00 00 00'));
    expect(Procedures.renew.bytes, hexBytes('52 45 4E 45 57 00 00 00'));
    expect(Procedures.connect.bytes, hexBytes('43 4F 4E 4E 45 43 54 00'));
  });

  group('CONNECT', () {
    const endpoint =
        '13 74 63 70 3A 2F 2F 31 30 2E 30 2E 30 2E 37 3A 39 33 30 30';

    test('request: worker-g instance 0x2A, tcp://10.0.0.7:9300, intent '
        '01 02 03 04', () {
      final bytes = hexBytes(
        '77 6F 72 6B 65 72 2D 67 2A 00 00 00 00 00 $endpoint '
        '04 01 02 03 04',
      );
      final r = ConnectRequest.decode(bytes);
      expect(r.type, Name('worker-g'));
      expect(r.instance, 0x2A);
      expect(r.endpoint, Uri.parse('tcp://10.0.0.7:9300'));
      expect(r.intent, [1, 2, 3, 4]);
      expect(r.encode(), bytes);
    });

    test('response: identity worker-a1', () {
      final bytes = hexBytes('09 77 6F 72 6B 65 72 2D 61 31');
      expect(ConnectResponse.decode(bytes).identity, 'worker-a1');
      expect(const ConnectResponse('worker-a1').encode(), bytes);
    });

    test('to the instance: requester consumer-1, the endpoint, the '
        'intent', () {
      final bytes = hexBytes(
        '0A 63 6F 6E 73 75 6D 65 72 2D 31 $endpoint 04 01 02 03 04',
      );
      final r = DialBackRequest.decode(bytes);
      expect(r.requester, 'consumer-1');
      expect(r.endpoint, Uri.parse('tcp://10.0.0.7:9300'));
      expect(r.intent, [1, 2, 3, 4]);
      expect(r.encode(), bytes);
    });

    test('to the instance: no requester identity, no intent', () {
      final bytes = hexBytes('00 $endpoint 00');
      final r = DialBackRequest.decode(bytes);
      expect(r.requester, isEmpty);
      expect(r.intent, isEmpty);
      expect(r.encode(), bytes);
    });

    for (final (name, hex, decode)
        in <(String, String, Object Function(Uint8List))>[
          (
            'request with an intent of 65 bytes',
            '77 6F 72 6B 65 72 2D 67 2A 00 00 00 00 00 $endpoint 41 '
                '${List.filled(65, '00').join(' ')}',
            ConnectRequest.decode,
          ),
          (
            'request without its intent',
            '77 6F 72 6B 65 72 2D 67 2A 00 00 00 00 00 $endpoint',
            ConnectRequest.decode,
          ),
          (
            'request with an endpoint without a scheme',
            '77 6F 72 6B 65 72 2D 67 2A 00 00 00 00 00 01 78 00',
            ConnectRequest.decode,
          ),
          (
            'requester that is not UTF-8',
            '01 FF $endpoint 00',
            DialBackRequest.decode,
          ),
          ('response cut short', '09 77 6F', ConnectResponse.decode),
        ]) {
      test('negative: $name', () {
        expect(() => decode(hexBytes(hex)), throwsA(isA<ProtocolException>()));
      });
    }
  });
}
