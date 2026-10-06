import 'dart:typed_data';

import 'package:switchboard/src/address/channel_address.dart';
import 'package:switchboard/src/address/service_address.dart';
import 'package:switchboard/src/name.dart';
import 'package:switchboard/src/status.dart';
import 'package:test/test.dart';

void main() {
  _copyWithClear();

  group('ServiceAddress', () {
    test('toString forms', () {
      expect(ServiceAddress(Name('npc'), 0x1A2B).toString(), 'npc/1a2b');
      expect(ServiceAddress(Name('npc')).toString(), 'npc');
      expect(ServiceAddress(Name('npc')).isAny, isTrue);
      expect(ServiceAddress(Name('npc'), 1).isAny, isFalse);
    });

    test('round trips including maximum instance', () {
      for (final text in ['npc/1a2b', 'npc', 'x/ffffffffffff', 'x/1']) {
        expect(ServiceAddress.parse(text).toString(), text);
      }
      expect(ServiceAddress.parse('x/ffffffffffff').instance, 0xFFFFFFFFFFFF);
      expect(ServiceAddress.parse('npc/0'), ServiceAddress(Name('npc')));
      expect(ServiceAddress.parse('npc/1A'), ServiceAddress(Name('npc'), 26));
    });

    test('equality', () {
      expect(ServiceAddress(Name('a'), 2), ServiceAddress(Name('a'), 2));
      expect(
        ServiceAddress(Name('a'), 2).hashCode,
        ServiceAddress(Name('a'), 2).hashCode,
      );
      expect(ServiceAddress(Name('a'), 2), isNot(ServiceAddress(Name('a'), 3)));
      expect(ServiceAddress(Name('a')), isNot(ServiceAddress(Name('b'))));
    });

    test('invalid parses throw FormatException', () {
      for (final text in [
        '',
        '/1',
        'npc/',
        'npc/xyz',
        'npc/-1',
        'npc/1000000000000',
        'npc/0000000000000',
        'toolongname/1',
        'npc/1/2',
        'npc/ 1',
      ]) {
        expect(
          () => ServiceAddress.parse(text),
          throwsFormatException,
          reason: text,
        );
      }
    });

    test('instance range is validated', () {
      expect(() => ServiceAddress(Name('a'), -1), throwsRangeError);
      expect(
        () => ServiceAddress(Name('a'), 0x1000000000000),
        throwsRangeError,
      );
    });
  });

  group('ChannelAddress', () {
    test('address getter', () {
      expect(ChannelAddress().address, isNull);
      expect(
        ChannelAddress(type: Name('npc'), instance: 3).address,
        ServiceAddress(Name('npc'), 3),
      );
    });

    test('copyWith', () {
      final a = ChannelAddress(type: Name('a'), instance: 1, shard: 2);
      final b = a.copyWith(instance: 9, host: 'h');
      expect(b.type, Name('a'));
      expect(b.instance, 9);
      expect(b.shard, 2);
      expect(b.host, 'h');
      expect(a.host, isNull);
      final c = a.copyWith(payload: Uint8List.fromList([1]));
      expect(c.payload, [1]);
      expect(c.instance, 1);
    });

    test('host length limit', () {
      expect(() => ChannelAddress(host: 'a' * 256), throwsArgumentError);
      expect(() => ChannelAddress(host: 'é' * 128), throwsArgumentError);
      final ok = ChannelAddress(host: 'a' * 255);
      expect(ChannelAddress.decode(ok.encode()).host, 'a' * 255);
    });

    test('range validation', () {
      expect(() => ChannelAddress(instance: -1), throwsRangeError);
      expect(() => ChannelAddress(instance: 0x1000000000000), throwsRangeError);
      expect(() => ChannelAddress(shard: -1), throwsRangeError);
      expect(() => ChannelAddress(shard: 0x100000000), throwsRangeError);
      final max = ChannelAddress(
        type: Name('a'),
        instance: 0xFFFFFFFFFFFF,
        shard: 0xFFFFFFFF,
      );
      final back = ChannelAddress.decode(max.encode());
      expect(back.instance, 0xFFFFFFFFFFFF);
      expect(back.shard, 0xFFFFFFFF);
    });

    test('shard 0 and empty host are preserved', () {
      final back = ChannelAddress.decode(
        ChannelAddress(shard: 0, host: '').encode(),
      );
      expect(back.shard, 0);
      expect(back.host, '');
    });

    test('payload preserved, including 100 KiB', () {
      final payload = Uint8List.fromList(
        List.generate(100 * 1024, (i) => i & 0xFF),
      );
      final a = ChannelAddress(type: Name('api'), payload: payload);
      final back = ChannelAddress.decode(a.encode());
      expect(back.payload, payload);
      expect(back.type, Name('api'));
    });

    test('payload is copied from the input', () {
      final bytes = Uint8List.fromList([0x00, 1, 2]);
      final a = ChannelAddress.decode(bytes);
      bytes[1] = 9;
      expect(a.payload, [1, 2]);
    });

    test('encode omits default instance', () {
      expect(ChannelAddress(type: Name('a'), instance: 0).encode()[0], 0x01);
    });

    for (final flag in [0x10, 0x20, 0x40, 0x80]) {
      test('reserved flag 0x${flag.toRadixString(16)} rejected', () {
        expect(
          () => ChannelAddress.decode(Uint8List.fromList([flag])),
          throwsA(isA<ProtocolException>()),
        );
        expect(
          () => ChannelAddress.decode(Uint8List.fromList([flag | 1, 0, 0])),
          throwsA(isA<ProtocolException>()),
        );
      });
    }

    test('invalid name in header is a ProtocolException', () {
      expect(
        () => ChannelAddress.decode(
          Uint8List.fromList([1, 0x61, 0, 0x62, 0, 0, 0, 0, 0]),
        ),
        throwsA(isA<ProtocolException>()),
      );
    });
  });
}

void _copyWithClear() {
  test('copyWith can clear host and shard', () {
    final a = ChannelAddress(type: Name('api'), shard: 3, host: 'h');
    final b = a.copyWith(clearHost: true, clearShard: true, instance: 9);
    expect(b.host, isNull);
    expect(b.shard, isNull);
    expect(b.instance, 9);
    expect(b.type, Name('api'));
  });
}
