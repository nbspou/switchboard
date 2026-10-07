import 'dart:typed_data';

import 'package:switchboard/src/bytes.dart';
import 'package:switchboard/src/name.dart';
import 'package:switchboard/src/status.dart';
import 'package:switchboard/src/talk/talk_frame.dart';
import 'package:test/test.dart';

/// Positive vectors from the wiki page "Switchboard Test Vectors", section
/// "Talk messages", with the frame each one must decode to.
final List<(String, String, TalkFrame)> positive = [
  (
    'Plain message "HELLO", payload 01',
    '01 48 45 4C 4C 4F 00 00 00 01',
    TalkFrame(
      kind: TalkKind.message,
      procedure: Name('HELLO'),
      payload: hexBytes('01'),
    ),
  ),
  (
    'Request "GET_PROF" id 1, empty payload',
    '03 47 45 54 5F 50 52 4F 46 01 00 00',
    TalkFrame(
      kind: TalkKind.message,
      procedure: Name('GET_PROF'),
      requestId: 1,
    ),
  ),
  (
    'Final response to 1, no procedure, payload FF',
    '04 01 00 00 FF',
    TalkFrame(kind: TalkKind.message, responseId: 1, payload: hexBytes('FF')),
  ),
  (
    'Stream request "LIST" id 2',
    '0B 4C 49 53 54 00 00 00 00 02 00 00',
    TalkFrame(
      kind: TalkKind.message,
      procedure: Name('LIST'),
      requestId: 2,
      stream: true,
    ),
  ),
  (
    'Stream item "ITEM" to 2, payload 07',
    '15 49 54 45 4D 00 00 00 00 02 00 00 07',
    TalkFrame(
      kind: TalkKind.streamItem,
      procedure: Name('ITEM'),
      responseId: 2,
      payload: hexBytes('07'),
    ),
  ),
  (
    'End of stream (final response) to 2, empty',
    '04 02 00 00',
    TalkFrame(kind: TalkKind.message, responseId: 2),
  ),
  (
    'Abort response to 1, NOT_FOUND, "nope"',
    '24 01 00 00 05 00 6E 6F 70 65',
    TalkFrame(
      kind: TalkKind.abort,
      responseId: 1,
      payload: Status.of(StatusCode.notFound, 'nope').encode(),
    ),
  ),
  (
    'Extend response to 1 (restart the default timeout)',
    '34 01 00 00',
    TalkFrame(kind: TalkKind.extend, responseId: 1),
  ),
  (
    'Extend response to 1, deadline 900000 ms, renew 300000 ms',
    '34 01 00 00 A0 BB 0D 00 E0 93 04 00',
    TalkFrame(
      kind: TalkKind.extend,
      responseId: 1,
      payload: TalkFrame.extendPayload(
        deadline: const Duration(minutes: 15),
        renew: const Duration(minutes: 5),
      ),
    ),
  ),
  (
    'Extend response to 1, deadline 900000 ms, renew unchanged',
    '34 01 00 00 A0 BB 0D 00 00 00 00 00',
    TalkFrame(
      kind: TalkKind.extend,
      responseId: 1,
      payload: TalkFrame.extendPayload(deadline: const Duration(minutes: 15)),
    ),
  ),
  (
    'Cancel own request 2',
    '22 02 00 00 01 00',
    TalkFrame(
      kind: TalkKind.abort,
      requestId: 2,
      payload: Status.of(StatusCode.cancelled).encode(),
    ),
  ),
  (
    'Channel abort, UNAUTHENTICATED, no reason',
    '20 10 00',
    TalkFrame(
      kind: TalkKind.abort,
      payload: Status.of(StatusCode.unauthenticated).encode(),
    ),
  ),
  (
    'Chained: response to 1 that is request 7 "MORE"',
    '07 4D 4F 52 45 00 00 00 00 07 00 00 01 00 00',
    TalkFrame(
      kind: TalkKind.message,
      procedure: Name('MORE'),
      requestId: 7,
      responseId: 1,
    ),
  ),
  (
    'Request id 0xFFFFFF "X"',
    '03 58 00 00 00 00 00 00 00 FF FF FF',
    TalkFrame(
      kind: TalkKind.message,
      procedure: Name('X'),
      requestId: 0xFFFFFF,
    ),
  ),
];

/// Negative vectors from the wiki (each MUST be a channel protocol error).
const List<(String, String)> negative = [
  ('Reserved bit 0x40', '41 48 45 4C 4C 4F 00 00 00'),
  ('STREAM without HAS_REQUEST', '09 48 45 4C 4C 4F 00 00 00'),
  ('Request id 0', '03 48 45 4C 4C 4F 00 00 00 00 00 00'),
  ('STREAM_ITEM without HAS_RESPONSE', '11 48 45 4C 4C 4F 00 00 00'),
  ('EXTEND with HAS_REQUEST', '36 01 00 00 02 00 00'),
  ('EXTEND with a 4-byte payload', '34 01 00 00 A0 BB 0D 00'),
  ('ABORT with both ids', '26 01 00 00 02 00 00 01 00'),
  ('Plain message without procedure', '00 01'),
  ('Truncated procedure', '01 48 45'),
];

/// Further violations of the flag rules in talk.md that are not wiki
/// vectors.
const List<(String, String)> negativeExtra = [
  ('Reserved bit 0x80', '81 48 45 4C 4C 4F 00 00 00'),
  ('Empty input', ''),
  ('Response id 0', '04 00 00 00'),
  ('Chained with response id 0', '06 01 00 00 00 00 00'),
  ('EXTEND without HAS_RESPONSE', '30'),
  ('EXTEND with STREAM and no request', '3C 01 00 00'),
  ('EXTEND with a 2-byte payload', '34 01 00 00 AA BB'),
  ('EXTEND with a 9-byte payload', '34 01 00 00 01 00 00 00 01 00 00 00 00'),
  ('STREAM_ITEM with only a request id', '13 48 45 4C 4C 4F 00 00 00 01 00 00'),
  ('Request without procedure', '02 01 00 00'),
  ('ABORT with a one byte payload', '24 01 00 00 05'),
  ('Truncated request id', '03 48 45 4C 4C 4F 00 00 00 01 00'),
  ('Truncated response id', '04 01 00'),
  ('Procedure with a byte after the padding', '01 61 00 62 00 00 00 00 00'),
];

void main() {
  group('Talk vectors, positive', () {
    for (final (name, hex, expected) in positive) {
      test(name, () {
        final bytes = hexBytes(hex);
        final frame = TalkFrame.decode(bytes);
        expect(frame, expected);
        expect(hexString(frame.encode()), hexString(bytes));
        expect(hexString(expected.encode()), hexString(bytes));
      });
    }

    test('abort statuses decode', () {
      expect(
        TalkFrame.decode(hexBytes('24 01 00 00 05 00 6E 6F 70 65')).status,
        Status.of(StatusCode.notFound, 'nope'),
      );
      expect(
        TalkFrame.decode(hexBytes('22 02 00 00 01 00')).status.known,
        StatusCode.cancelled,
      );
      expect(
        TalkFrame.decode(hexBytes('20 10 00')).status.known,
        StatusCode.unauthenticated,
      );
      // An empty abort payload means UNKNOWN (talk.md, ABORT).
      expect(
        TalkFrame.decode(hexBytes('24 01 00 00')).status,
        Status.of(StatusCode.unknown),
      );
      expect(TalkFrame.decode(hexBytes('20')).status.known, StatusCode.unknown);
    });
  });

  group('Talk vectors, negative', () {
    for (final (name, hex) in negative) {
      test(name, () {
        expect(
          () => TalkFrame.decode(hexBytes(hex)),
          throwsA(
            isA<ProtocolException>().having(
              (e) => e.code,
              'code',
              StatusCode.protocolError,
            ),
          ),
        );
      });
    }
  });

  group('Talk decoding rules beyond the wiki vectors', () {
    for (final (name, hex) in negativeExtra) {
      test(name, () {
        expect(
          () => TalkFrame.decode(hexBytes(hex)),
          throwsA(isA<ProtocolException>()),
        );
      });
    }

    test('EXTEND values decode', () {
      expect(
        TalkFrame.decode(hexBytes('34 01 00 00 A0 BB 0D 00 E0 93 04 00'))
            .extension,
        (
          deadline: const Duration(minutes: 15),
          renew: const Duration(minutes: 5),
        ),
      );
      expect(
        TalkFrame.decode(hexBytes('34 01 00 00 00 00 00 00 E0 93 04 00'))
            .extension,
        (deadline: null, renew: const Duration(minutes: 5)),
      );
      // An empty payload and two zero fields both declare nothing; the
      // payload tells a restart of the default timeout from "unchanged".
      expect(TalkFrame.decode(hexBytes('34 01 00 00')).extension, (
        deadline: null,
        renew: null,
      ));
      final zeros = TalkFrame.decode(
        hexBytes('34 01 00 00 00 00 00 00 00 00 00 00'),
      );
      expect(zeros.extension, (deadline: null, renew: null));
      expect(zeros.payload, hasLength(8));
      expect(
        TalkFrame.decode(hexBytes('34 01 00 00 FF FF FF FF 01 00 00 00'))
            .extension,
        (
          deadline: const Duration(milliseconds: 0xFFFFFFFF),
          renew: const Duration(milliseconds: 1),
        ),
      );
      expect(
        () => TalkFrame(kind: TalkKind.message, responseId: 1).extension,
        throwsStateError,
      );
    });

    test('EXTEND values encode in whole milliseconds, rounded up', () {
      String payload({Duration? deadline, Duration? renew}) =>
          hexString(TalkFrame.extendPayload(deadline: deadline, renew: renew));
      expect(payload(), '');
      expect(
        payload(deadline: const Duration(microseconds: 1500)),
        '02 00 00 00 00 00 00 00',
      );
      // Under 1 ms is 1 ms: 0 would mean "unchanged".
      expect(payload(renew: Duration.zero), '00 00 00 00 01 00 00 00');
      expect(
        payload(deadline: const Duration(days: 60)),
        'FF FF FF FF 00 00 00 00',
      );
      expect(
        () => payload(deadline: const Duration(seconds: -1)),
        throwsArgumentError,
      );
    });

    test('a missing procedure reads as the empty name', () {
      final frame = TalkFrame.decode(hexBytes('04 01 00 00'));
      expect(frame.procedure, isNull);
    });

    test('chained stream request and item request decode', () {
      // Final response to 3 that is stream request 4.
      final chained = TalkFrame.decode(hexBytes('0E 04 00 00 03 00 00'));
      expect(chained.stream, isTrue);
      expect(chained.requestId, 4);
      expect(chained.responseId, 3);
      // Stream item to 3 that is request 5.
      final item = TalkFrame.decode(hexBytes('16 05 00 00 03 00 00 AA'));
      expect(item.kind, TalkKind.streamItem);
      expect(item.requestId, 5);
      expect(item.responseId, 3);
      expect(hexString(item.payload), 'AA');
    });

    test('payload is a view, not a copy', () {
      final bytes = hexBytes('04 01 00 00 01 02 03');
      final frame = TalkFrame.decode(bytes);
      expect(hexString(frame.payload), '01 02 03');
      bytes[4] = 0x7F;
      expect(frame.payload[0], 0x7F);
    });
  });

  group('TalkFrame.encode refuses invalid frames', () {
    final cases = <(String, TalkFrame Function())>[
      (
        'plain message without procedure',
        () => TalkFrame(kind: TalkKind.message),
      ),
      (
        'request without procedure',
        () => TalkFrame(kind: TalkKind.message, requestId: 1),
      ),
      (
        'stream without request',
        () => TalkFrame(
          kind: TalkKind.message,
          procedure: Name('A'),
          stream: true,
        ),
      ),
      ('item without response', () => TalkFrame(kind: TalkKind.streamItem)),
      (
        'abort with both ids',
        () => TalkFrame(kind: TalkKind.abort, requestId: 1, responseId: 1),
      ),
      ('extend without response', () => TalkFrame(kind: TalkKind.extend)),
      (
        'extend with request',
        () => TalkFrame(kind: TalkKind.extend, requestId: 1, responseId: 1),
      ),
      (
        'extend with a 1-byte payload',
        () => TalkFrame(
          kind: TalkKind.extend,
          responseId: 1,
          payload: Uint8List(1),
        ),
      ),
      (
        'request id over u24',
        () => TalkFrame(
          kind: TalkKind.message,
          procedure: Name('A'),
          requestId: 0x1000000,
        ),
      ),
      (
        'negative response id',
        () => TalkFrame(kind: TalkKind.message, responseId: -1),
      ),
    ];
    for (final (name, build) in cases) {
      test(name, () {
        expect(() => build().encode(), throwsArgumentError);
      });
    }
  });
}
