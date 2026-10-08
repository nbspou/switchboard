/*
Polyverse Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Authors:
  Jan Boon <jan.boon@kaetemi.be>
  Claude Opus 5.5 <noreply@anthropic.com>
*/

// Test vectors from the wiki page "Polyverse Switchboard Test Vectors", section
// "Mux frames", plus the decoding rules of the "Switchboard Mux" page.
// Platform independent: runs on the VM and, compiled to JavaScript, with
// `dart test -p node test/vectors/`, which checks the 48-bit channel ids.

import 'dart:async';
import 'dart:typed_data';

import 'package:async/async.dart';
import 'package:switchboard/src/bytes.dart';
import 'package:switchboard/src/mux/mux_connection.dart';
import 'package:switchboard/src/mux/mux_frame.dart';
import 'package:switchboard/src/status.dart';
import 'package:switchboard/src/transport/memory_transport.dart';
import 'package:test/test.dart';

void main() {
  group('mux frames', () {
    void vector(String name, MuxFrame frame, String hex) {
      test(name, () {
        expect(hexString(frame.encode()), hex);
        final decoded = MuxFrame.decode(hexBytes(hex));
        expect(decoded.command, frame.command);
        expect(decoded.channelId, frame.channelId);
        expect(hexString(decoded.payload), hexString(frame.payload));
      });
    }

    vector(
      'DATA, short id 2, payload 01 02 03',
      MuxFrame.data(2, hexBytes('01 02 03')),
      '02 02 00 01 02 03',
    );
    vector(
      'DATA, short id 2, empty payload',
      MuxFrame.data(2, Uint8List(0)),
      '02 02 00',
    );
    vector(
      'DATA, long id 0x010000, empty payload',
      MuxFrame.data(0x010000, Uint8List(0)),
      '00 00 00 01 00 00 00',
    );
    vector(
      'DATA, long id 0x1234567890AB, payload FF',
      MuxFrame.data(0x1234567890AB, hexBytes('FF')),
      '00 AB 90 78 56 34 12 FF',
    );
    vector(
      'OPEN, short id 3, payload AA',
      MuxFrame.open(3, hexBytes('AA')),
      '12 03 00 AA',
    );
    vector(
      'OPEN, short id 2, empty payload',
      MuxFrame.open(2, Uint8List(0)),
      '12 02 00',
    );
    vector(
      'CLOSE, short id 2, status OK, no reason',
      MuxFrame.close(2, Status.ok),
      '22 02 00 00 00',
    );
    vector(
      'CLOSE, short id 2, no payload (means OK)',
      MuxFrame.close(2),
      '22 02 00',
    );
    vector(
      'CLOSE, short id 2, NOT_FOUND, reason "x"',
      MuxFrame.close(2, Status.of(StatusCode.notFound, 'x')),
      '22 02 00 05 00 78',
    );
    vector(
      'Control PING, payload DE AD',
      MuxControlMessage.ping(hexBytes('DE AD')).toFrame(),
      '02 00 00 01 DE AD',
    );
    vector(
      'Control PONG, payload DE AD',
      MuxControlMessage.pong(hexBytes('DE AD')).toFrame(),
      '02 00 00 02 DE AD',
    );
    vector(
      'Control GOAWAY, GOING_AWAY, no reason',
      MuxControlMessage.goAway(Status.of(StatusCode.goingAway)).toFrame(),
      '02 00 00 03 21 00',
    );
    vector(
      'Control LIMITS, 1024 bytes, 4 channels, 64 KiB window',
      MuxControlMessage.limits(
        const MuxLimits(
          maxFrameSize: 1024,
          maxChannels: 4,
          initialWindow: 65536,
        ),
      ).toFrame(),
      '02 00 00 04 00 04 00 00 04 00 00 00 00 00 01 00',
    );
    vector(
      'Control CREDIT, channel 2, 32768 bytes',
      MuxControlMessage.credit(const MuxCredit(2, 32768)).toFrame(),
      '02 00 00 07 02 00 00 00 00 00 00 80 00 00',
    );

    test('CLOSE payloads decode to their status', () {
      Status statusOf(String hex) =>
          Status.decode(MuxFrame.decode(hexBytes(hex)).payload);
      expect(statusOf('22 02 00 00 00'), Status.ok);
      expect(statusOf('22 02 00'), Status.ok);
      expect(
        statusOf('22 02 00 05 00 78'),
        Status.of(StatusCode.notFound, 'x'),
      );
    });

    test('control messages decode', () {
      MuxControlMessage control(String hex) {
        final frame = MuxFrame.decode(hexBytes(hex));
        expect(frame.channelId, 0);
        expect(frame.command, MuxCommand.data);
        return MuxControlMessage.decode(frame.payload);
      }

      final ping = control('02 00 00 01 DE AD');
      expect(ping.knownType, MuxControlType.ping);
      expect(hexString(ping.payload), 'DE AD');
      final pong = control('02 00 00 02 DE AD');
      expect(pong.knownType, MuxControlType.pong);
      expect(hexString(pong.payload), 'DE AD');
      final goAway = control('02 00 00 03 21 00');
      expect(goAway.knownType, MuxControlType.goAway);
      expect(goAway.goAwayStatus, Status.of(StatusCode.goingAway));
      final limits = control('02 00 00 04 00 04 00 00 04 00 00 00 00 00 01 00');
      expect(limits.knownType, MuxControlType.limits);
      expect(
        MuxLimits.decode(limits.payload),
        const MuxLimits(
          maxFrameSize: 1024,
          maxChannels: 4,
          initialWindow: 65536,
        ),
      );
      final credit = control('02 00 00 07 02 00 00 00 00 00 00 80 00 00');
      expect(credit.knownType, MuxControlType.credit);
      expect(MuxCredit.decode(credit.payload), const MuxCredit(2, 32768));
    });

    test('LIMITS ignores trailing fields', () {
      expect(
        MuxLimits.decode(hexBytes('00 04 00 00 04 00 00 00 00 00 01 00 99 99')),
        const MuxLimits(
          maxFrameSize: 1024,
          maxChannels: 4,
          initialWindow: 65536,
        ),
      );
    });

    test('LIMITS and CREDIT carry full u32 and u48 values', () {
      // Bitwise operations are 32-bit when compiled to JavaScript.
      const limits = MuxLimits(
        maxFrameSize: 0xFFFFFFFF,
        maxChannels: 0x80000000,
        initialWindow: 0xFFFFFFFF,
      );
      expect(hexString(limits.encode()), 'FF FF FF FF 00 00 00 80 FF FF FF FF');
      expect(MuxLimits.decode(limits.encode()), limits);
      const credit = MuxCredit(0xFFFFFFFFFFFE, 0xFFFFFFFF);
      expect(hexString(credit.encode()), 'FE FF FF FF FF FF FF FF FF FF');
      expect(MuxCredit.decode(credit.encode()), credit);
      const high = MuxCredit(0x100000002, 0x80000000);
      expect(MuxCredit.decode(high.encode()).channelId, 0x100000002);
      expect(MuxCredit.decode(high.encode()).bytes, 0x80000000);
    });

    test('LIMITS and CREDIT refuse values that do not fit', () {
      for (final limits in const [
        MuxLimits(maxFrameSize: 0, maxChannels: 0, initialWindow: 0),
        MuxLimits(maxFrameSize: 0, maxChannels: 0, initialWindow: 0x100000000),
        MuxLimits(maxFrameSize: -1, maxChannels: 0),
      ]) {
        expect(limits.encode, throwsArgumentError, reason: '$limits');
      }
      for (final credit in const [
        MuxCredit(-1, 0),
        MuxCredit(0x1000000000000, 0),
        MuxCredit(2, -1),
        MuxCredit(2, 0x100000000),
      ]) {
        expect(credit.encode, throwsArgumentError, reason: '$credit');
      }
      expect(MuxCredit.costOf(0), 16);
      expect(MuxCredit.costOf(100), 116);
    });

    test('unknown control types decode', () {
      final message = MuxControlMessage.decode(hexBytes('7F 01'));
      expect(message.type, 0x7F);
      expect(message.knownType, isNull);
    });

    test('short form whenever the id fits', () {
      expect(
        hexString(MuxFrame.data(0xFFFE, Uint8List(0)).encode()),
        '02 FE FF',
      );
      expect(
        hexString(MuxFrame.data(0x10000, Uint8List(0)).encode()),
        '00 00 00 01 00 00 00',
      );
      // A short id sent in the long form is the same id.
      final long = MuxFrame.decode(hexBytes('00 02 00 00 00 00 00 AA'));
      expect(long.channelId, 2);
      expect(long.longForm, isTrue);
      expect(MuxFrame.decode(hexBytes('02 02 00 AA')).longForm, isFalse);
    });

    test('ids above 32 bits do not alias short ids', () {
      // Bitwise operations are 32-bit when compiled to JavaScript; these
      // ids must survive the round trip there too.
      for (final (id, hex) in [
        (0x100000002, '00 02 00 00 00 01 00'),
        (0x1234567890AB, '00 AB 90 78 56 34 12'),
        (0xFFFF00000002, '00 02 00 00 00 FF FF'),
        (0xFFFFFFFFFFFE, '00 FE FF FF FF FF FF'),
        (0x80000000, '00 00 00 00 80 00 00'),
      ]) {
        expect(hexString(MuxFrame.data(id, Uint8List(0)).encode()), hex);
        final decoded = MuxFrame.decode(hexBytes(hex));
        expect(decoded.channelId, id, reason: hex);
        expect(decoded.longForm, isTrue);
      }
      expect(
        MuxFrame.decode(hexBytes('00 02 00 00 00 01 00')).channelId,
        isNot(2),
      );
    });

    test('compatible reserved bits are ignored', () {
      final frame = MuxFrame.decode(hexBytes('42 02 00 01'));
      expect(frame.command, MuxCommand.data);
      expect(frame.channelId, 2);
      expect(hexString(frame.payload), '01');
      expect(MuxFrame.decode(hexBytes('82 02 00')).channelId, 2);
      expect(MuxFrame.decode(hexBytes('D2 03 00')).command, MuxCommand.open);
    });
  });

  // Negative vectors: each MUST be a protocol error.
  const negative = <(String, String)>[
    ('Reserved incompatible flag 0x01', '03 02 00'),
    ('Command 3', '32 02 00'),
    ('Truncated short header', '02 02'),
    ('Truncated long header', '00 01 02 03 04 05'),
    ('OPEN on channel 0', '12 00 00'),
    ('DATA on channel 1', '02 01 00'),
  ];

  // Further decoding rules from the mux page.
  const negativeRules = <(String, String)>[
    ('Reserved incompatible flag 0x04', '06 02 00'),
    ('Reserved incompatible flag 0x08', '0A 02 00'),
    ('CLOSE on channel 0', '22 00 00'),
    ('OPEN on channel 1', '12 01 00'),
    ('DATA on reserved id 0xFFFF', '02 FF FF'),
    ('DATA on reserved id 0xFFFF00000000', '00 00 00 00 00 FF FF'),
    ('DATA on reserved id 0xFFFFFFFFFFFF', '00 FF FF FF FF FF FF'),
    (
      'DATA with payload on reserved 0xFFFF00000000',
      '00 00 00 00 00 FF FF 01 DE AD',
    ),
    ('Empty frame', ''),
  ];

  group('mux negative vectors, decoder', () {
    for (final (name, hex) in [...negative, ...negativeRules]) {
      test(name, () {
        expect(
          () => MuxFrame.decode(hexBytes(hex)),
          throwsA(isA<ProtocolException>()),
        );
      });
    }

    test('control payload over 1024 bytes', () {
      final payload = Uint8List(1 + 1025)..[0] = 0x7F;
      expect(
        () => MuxControlMessage.decode(payload),
        throwsA(isA<ProtocolException>()),
      );
      expect(
        MuxControlMessage.decode(Uint8List(1 + 1024)..[0] = 0x7F).payload,
        hasLength(1024),
      );
    });

    test('control message without type', () {
      expect(
        () => MuxControlMessage.decode(Uint8List(0)),
        throwsA(isA<ProtocolException>()),
      );
    });

    test('truncated LIMITS', () {
      expect(
        () => MuxLimits.decode(hexBytes('00 04 00 00 04 00 00')),
        throwsA(isA<ProtocolException>()),
      );
    });

    // Control payloads that are protocol errors (after the type byte).
    for (final (name, hex, decode)
        in <(String, String, Object Function(Uint8List))>[
          (
            'LIMITS shorter than 12 bytes',
            '00 04 00 00 04 00 00 00',
            MuxLimits.decode,
          ),
          (
            'LIMITS with a zero window',
            '00 04 00 00 04 00 00 00 00 00 00 00',
            MuxLimits.decode,
          ),
          (
            'CREDIT that is not 10 bytes',
            '02 00 00 00 00 00 00 80',
            MuxCredit.decode,
          ),
          (
            'CREDIT of 11 bytes',
            '02 00 00 00 00 00 00 80 00 00 00',
            MuxCredit.decode,
          ),
        ]) {
      test(name, () {
        expect(() => decode(hexBytes(hex)), throwsA(isA<ProtocolException>()));
      });
    }
  });

  group('mux negative vectors, connection', () {
    for (final (name, hex) in negative) {
      test('$name: GOAWAY PROTOCOL_ERROR and close', () async {
        final (local, remote) = MemoryTransport.pair();
        final mux = MuxConnection(
          local,
          isInitiator: true,
          options: const MuxOptions(
            keepAliveInterval: null,
            announceLimits: false,
          ),
        );
        final queue = StreamQueue(remote.stream);
        remote.sink.add(hexBytes(hex));
        final frame = MuxFrame.decode(await queue.next);
        expect(frame.channelId, 0);
        final control = MuxControlMessage.decode(frame.payload);
        expect(control.knownType, MuxControlType.goAway);
        expect(control.goAwayStatus.known, StatusCode.protocolError);
        expect(await queue.hasNext, isFalse);
        expect((await mux.done).known, StatusCode.protocolError);
        expect(mux.isOpen, isFalse);
      });
    }

    for (final (name, hex) in const [
      ('LIMITS shorter than 12 bytes', '02 00 00 04 00 04 00 00 04 00 00 00'),
      (
        'LIMITS with a zero window',
        '02 00 00 04 00 04 00 00 04 00 00 00 00 00 00 00',
      ),
      ('CREDIT that is not 10 bytes', '02 00 00 07 02 00 00 00 00 00 00 80'),
    ]) {
      test('$name: GOAWAY PROTOCOL_ERROR and close', () async {
        final (local, remote) = MemoryTransport.pair();
        final mux = MuxConnection(
          local,
          isInitiator: true,
          options: const MuxOptions(
            keepAliveInterval: null,
            announceLimits: false,
          ),
        );
        final queue = StreamQueue(remote.stream);
        remote.sink.add(hexBytes(hex));
        final frame = MuxFrame.decode(await queue.next);
        final control = MuxControlMessage.decode(frame.payload);
        expect(control.knownType, MuxControlType.goAway);
        expect(control.goAwayStatus.known, StatusCode.protocolError);
        expect(await queue.hasNext, isFalse);
        expect((await mux.done).known, StatusCode.protocolError);
      });
    }

    test('CREDIT for a channel that is not open is ignored', () async {
      final (local, remote) = MemoryTransport.pair();
      final mux = MuxConnection(
        local,
        isInitiator: true,
        options: const MuxOptions(
          keepAliveInterval: null,
          announceLimits: false,
        ),
      );
      final queue = StreamQueue(remote.stream);
      remote.sink
        ..add(hexBytes('02 00 00 07 02 00 00 00 00 00 00 80 00 00'))
        ..add(hexBytes('02 00 00 07 FE FF FF FF FF FF FF FF FF FF'))
        ..add(hexBytes('02 00 00 01 AA'));
      expect(hexString(await queue.next), '02 00 00 02 AA');
      expect(mux.isOpen, isTrue);
      await mux.close();
      await queue.cancel();
    });

    test('a long id above 32 bits addresses its own channel', () async {
      final (local, remote) = MemoryTransport.pair();
      final mux = MuxConnection(
        local,
        isInitiator: true,
        options: const MuxOptions(
          keepAliveInterval: null,
          announceLimits: false,
        ),
      );
      final queue = StreamQueue(remote.stream);
      // OPEN 0x100000003 and OPEN 3, then DATA on each.
      remote.sink
        ..add(hexBytes('10 03 00 00 00 01 00'))
        ..add(hexBytes('12 03 00'))
        ..add(hexBytes('00 03 00 00 00 01 00 AA'))
        ..add(hexBytes('02 03 00 BB'));
      final channels = StreamQueue(mux.incoming);
      final long = await channels.next;
      final short = await channels.next;
      expect(long.id, 0x100000003);
      expect(short.id, 3);
      expect(hexString(await long.stream.first), 'AA');
      expect(hexString(await short.stream.first), 'BB');
      // Our CLOSE uses the long form for the long id.
      unawaited(long.close());
      expect(hexString(await queue.next), '20 03 00 00 00 01 00');
      await mux.close();
      await queue.cancel();
      await channels.cancel();
    });

    test('compatible reserved bits are ignored by a connection', () async {
      final (local, remote) = MemoryTransport.pair();
      final mux = MuxConnection(
        local,
        isInitiator: true,
        options: const MuxOptions(
          keepAliveInterval: null,
          announceLimits: false,
        ),
      );
      final queue = StreamQueue(remote.stream);
      // OPEN 3 with bit 0x40, DATA with 0x80, PING with 0xC0.
      remote.sink
        ..add(hexBytes('52 03 00'))
        ..add(hexBytes('82 03 00 01'))
        ..add(hexBytes('C2 00 00 01 DE AD'));
      final channel = await mux.incoming.first;
      expect(channel.id, 3);
      expect(hexString(await channel.stream.first), '01');
      expect(hexString(await queue.next), '02 00 00 02 DE AD');
      await mux.close();
      await queue.cancel();
    });
  });
}
