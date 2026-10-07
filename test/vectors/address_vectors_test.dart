import 'dart:typed_data';

import 'package:switchboard/src/address/channel_address.dart';
import 'package:switchboard/src/bytes.dart';
import 'package:switchboard/src/name.dart';
import 'package:switchboard/src/naming/naming_protocol.dart';
import 'package:switchboard/src/status.dart';
import 'package:test/test.dart';

void main() {
  void positive(
    String label,
    String hex, {
    Name? type,
    int instance = 0,
    int? shard,
    String? host,
    String payload = '',
  }) {
    test(label, () {
      final bytes = hexBytes(hex);
      final a = ChannelAddress.decode(bytes);
      expect(a.type, type);
      expect(a.instance, instance);
      expect(a.shard, shard);
      expect(a.host, host);
      expect(a.payload, hexBytes(payload));
      expect(a.encode(), bytes);
    });
  }

  group('address header positive vectors', () {
    positive('default service, no payload', '00');
    positive(
      'service api with app payload',
      '01 61 70 69 00 00 00 00 00 01 02',
      type: Name('api'),
      payload: '01 02',
    );
    positive(
      'service npc instance 0x1A2B',
      '03 6E 70 63 00 00 00 00 00 2B 1A 00 00 00 00',
      type: Name('npc'),
      instance: 0x1A2B,
    );
    positive(
      'service chat shard 7',
      '05 63 68 61 74 00 00 00 00 07 00 00 00',
      type: Name('chat'),
      shard: 7,
    );
    positive(
      'service api host hint',
      '09 61 70 69 00 00 00 00 00 09 62 2E 65 78 61 6D 70 6C 65',
      type: Name('api'),
      host: 'b.example',
    );
    positive(
      'everything',
      '0F 61 62 00 00 00 00 00 00 01 00 00 00 00 00 02 00 00 00 01 68 FF',
      type: Name('ab'),
      instance: 1,
      shard: 2,
      host: 'h',
      payload: 'FF',
    );
  });

  group('relay open payloads', () {
    // A `_relay` channel (instance 0, no shard) whose application payload
    // is the complete open payload of the channel to relay.
    void relayed(
      String label,
      String hex,
      String innerHex, {
      required Name type,
      int instance = 0,
      int? shard,
      String payload = '',
    }) {
      test(label, () {
        final bytes = hexBytes(hex);
        final outer = ChannelAddress.decode(bytes);
        expect(outer.type, Services.relay);
        expect(outer.type, Name('_relay'));
        expect(outer.instance, 0);
        expect(outer.shard, isNull);
        expect(outer.host, isNull);
        expect(outer.payload, hexBytes(innerHex));
        final inner = ChannelAddress.decode(outer.payload);
        expect(inner.type, type);
        expect(inner.instance, instance);
        expect(inner.shard, shard);
        expect(inner.payload, hexBytes(payload));
        expect(
          ChannelAddress(
            type: Services.relay,
            payload: inner.encode(),
          ).encode(),
          bytes,
        );
      });
    }

    relayed(
      '"worker-g" instance 0x2A, app payload 01 02',
      '01 5F 72 65 6C 61 79 00 00 '
          '03 77 6F 72 6B 65 72 2D 67 2A 00 00 00 00 00 01 02',
      '03 77 6F 72 6B 65 72 2D 67 2A 00 00 00 00 00 01 02',
      type: Name('worker-g'),
      instance: 0x2A,
      payload: '01 02',
    );
    relayed(
      '"chat" shard 7',
      '01 5F 72 65 6C 61 79 00 00 05 63 68 61 74 00 00 00 00 07 00 00 00',
      '05 63 68 61 74 00 00 00 00 07 00 00 00',
      type: Name('chat'),
      shard: 7,
    );
  });

  test('empty open payload decodes as default', () {
    final a = ChannelAddress.decode(Uint8List(0));
    expect(a.type, isNull);
    expect(a.instance, 0);
    expect(a.shard, isNull);
    expect(a.host, isNull);
    expect(a.payload, isEmpty);
    expect(a.encode(), hexBytes('00'));
  });

  group('address header negative vectors', () {
    for (final entry in {
      'reserved bit 0x10': '10',
      'truncated service name': '01 61 70',
      'host hint longer than payload': '08 05 61',
    }.entries) {
      test(entry.key, () {
        expect(
          () => ChannelAddress.decode(hexBytes(entry.value)),
          throwsA(isA<ProtocolException>()),
        );
      });
    }
  });
}
