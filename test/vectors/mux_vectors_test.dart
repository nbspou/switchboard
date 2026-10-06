// Test vectors from the wiki page "Switchboard Test Vectors", sections
// "Transport, stream binding" and "Mux frames", plus the stream binding
// rules stated on the "Switchboard Transport" page.

import 'dart:typed_data';

import 'package:async/async.dart';
import 'package:switchboard/src/bytes.dart';
import 'package:switchboard/src/mux/mux_connection.dart';
import 'package:switchboard/src/mux/mux_frame.dart';
import 'package:switchboard/src/status.dart';
import 'package:switchboard/src/transport/memory_transport.dart';
import 'package:switchboard/src/transport/stream_transport.dart';
import 'package:test/test.dart';

/// Decodes [bytes] (preamble included) and returns the frames.
List<Uint8List> decodeStream(Uint8List bytes, {int? maxFrameSize}) {
  final decoder = StreamFrameDecoder(
    maxFrameSize: maxFrameSize ?? StreamTransport.defaultMaxFrameSize,
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
      expect(hexString(StreamTransport.encodePreamble()), preamble);
      final decoder = StreamFrameDecoder();
      decoder.add(hexBytes(preamble), (_) => fail('no frame expected'));
      expect(decoder.preambleReceived, isTrue);
      expect(decoder.bufferedBytes, 0);
    });

    test('frame carrying body 02 02 00 AA', () {
      expect(
        hexString(StreamTransport.encodeFrame(hexBytes('02 02 00 AA'))),
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
        hexString(StreamTransport.encodeFrame(open)),
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

    test('unsupported version is a protocol error', () {
      expect(
        () => decodeStream(hexBytes('53 57 42 44 02 00 00 00')),
        throwsA(isA<ProtocolException>()),
      );
    });

    test('length 0 is a protocol error', () {
      expect(
        () => decodeStream(hexBytes('$preamble 00 00 00 00')),
        throwsA(isA<ProtocolException>()),
      );
      expect(
        () => StreamTransport.encodeFrame(Uint8List(0)),
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
      'Control LIMITS, 1024 bytes, 4 channels',
      MuxControlMessage.limits(
        const MuxLimits(maxFrameSize: 1024, maxChannels: 4),
      ).toFrame(),
      '02 00 00 04 00 04 00 00 04 00 00 00',
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
      final limits = control('02 00 00 04 00 04 00 00 04 00 00 00');
      expect(limits.knownType, MuxControlType.limits);
      expect(
        MuxLimits.decode(limits.payload),
        const MuxLimits(maxFrameSize: 1024, maxChannels: 4),
      );
    });

    test('LIMITS ignores trailing fields', () {
      expect(
        MuxLimits.decode(hexBytes('00 04 00 00 04 00 00 00 99 99')),
        const MuxLimits(maxFrameSize: 1024, maxChannels: 4),
      );
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
