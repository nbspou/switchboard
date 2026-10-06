import 'dart:math';
import 'dart:typed_data';

import 'package:switchboard/src/address/service_address.dart';
import 'package:switchboard/src/bytes.dart';
import 'package:switchboard/src/name.dart';
import 'package:switchboard/src/naming/naming_protocol.dart';
import 'package:switchboard/src/status.dart';
import 'package:test/test.dart';

import 'naming_harness.dart';

void main() {
  final npc = Name('npc');
  final uris = [Uri.parse('ws://10.0.0.5:9100/ws'), Uri.parse('tcp://h:9101')];

  group('ServiceRecord', () {
    test('round trip with multiple endpoints', () {
      final r = ServiceRecord(ServiceAddress(npc, 0xABCDEF), endpoints: uris);
      expect(ServiceRecord.decode(r.encode()), r);
    });

    test('zero endpoints', () {
      final r = ServiceRecord(ServiceAddress(npc, 1));
      expect(ServiceRecord.decode(r.encode()), r);
      expect(ServiceRecord.decode(r.encode()).endpoints, isEmpty);
    });

    test('255 endpoints', () {
      final r = ServiceRecord(
        ServiceAddress(npc, 1),
        endpoints: [for (var i = 0; i < 255; i++) Uri.parse('tcp://h$i:1')],
      );
      final back = ServiceRecord.decode(r.encode());
      expect(back.endpoints, hasLength(255));
      expect(back, r);
    });

    test('256 endpoints rejected on encode', () {
      final r = ServiceRecord(
        ServiceAddress(npc, 1),
        endpoints: [for (var i = 0; i < 256; i++) Uri.parse('tcp://h:1')],
      );
      expect(r.encode, throwsArgumentError);
    });

    test('non-ASCII URI', () {
      final r = ServiceRecord(
        ServiceAddress(npc, 1),
        endpoints: [Uri.parse('ws://example.org/é/日本')],
      );
      final back = ServiceRecord.decode(r.encode());
      expect(back, r);
      expect(back.endpoints.single.toString(), r.endpoints.single.toString());
    });

    test('instance 0 rejected on decode and encode', () {
      final bytes = ServiceRecord(ServiceAddress(npc, 1)).encode();
      bytes.fillRange(8, 14, 0);
      expect(
        () => ServiceRecord.decode(bytes),
        throwsA(isA<ProtocolException>()),
      );
      expect(ServiceRecord(ServiceAddress(npc)).encode, throwsArgumentError);
    });

    test('trailing bytes ignored', () {
      final r = ServiceRecord(ServiceAddress(npc, 1), endpoints: uris);
      final bytes = Uint8List.fromList([...r.encode(), 1, 2, 3]);
      expect(ServiceRecord.decode(bytes), r);
    });

    test('truncation at every boundary', () {
      final bytes = ServiceRecord(
        ServiceAddress(npc, 1),
        endpoints: uris,
      ).encode();
      for (var n = 0; n < bytes.length; n++) {
        expect(
          () => ServiceRecord.decode(Uint8List.sublistView(bytes, 0, n)),
          throwsA(isA<ProtocolException>()),
          reason: 'prefix $n',
        );
      }
    });
  });

  group('RegisterRequest', () {
    test('round trip', () {
      final bytes = RegisterRequest(
        npc,
        requestedInstance: 0xFFFFFFFFFFFF,
        endpoints: uris,
      ).encode();
      final r = RegisterRequest.decode(bytes);
      expect(r.type, npc);
      expect(r.requestedInstance, 0xFFFFFFFFFFFF);
      expect(r.endpoints, uris);
    });

    test('zero endpoints and zero instance are valid', () {
      final r = RegisterRequest.decode(RegisterRequest(npc).encode());
      expect(r.requestedInstance, 0);
      expect(r.endpoints, isEmpty);
    });

    test('truncation at every byte boundary throws ProtocolException', () {
      final bytes = RegisterRequest(
        npc,
        requestedInstance: 7,
        endpoints: uris,
      ).encode();
      for (var n = 0; n < bytes.length; n++) {
        expect(
          () => RegisterRequest.decode(Uint8List.sublistView(bytes, 0, n)),
          throwsA(isA<ProtocolException>()),
          reason: 'prefix $n',
        );
      }
      expect(RegisterRequest.decode(bytes).endpoints, uris);
    });

    test('non-ASCII endpoint', () {
      final r = RegisterRequest(
        npc,
        endpoints: [Uri.parse('ws://ü.example/ä')],
      );
      expect(RegisterRequest.decode(r.encode()).endpoints, r.endpoints);
    });
  });

  group('RegisterResponse', () {
    test('round trip and truncation', () {
      final bytes = const RegisterResponse(0x123456789A).encode();
      expect(RegisterResponse.decode(bytes).instance, 0x123456789A);
      for (var n = 0; n < 6; n++) {
        expect(
          () => RegisterResponse.decode(Uint8List.sublistView(bytes, 0, n)),
          throwsA(isA<ProtocolException>()),
        );
      }
    });
  });

  group('UnregisterRequest', () {
    test('round trip and truncation', () {
      final bytes = UnregisterRequest(npc, 42).encode();
      final r = UnregisterRequest.decode(bytes);
      expect(r.type, npc);
      expect(r.instance, 42);
      for (var n = 0; n < bytes.length; n++) {
        expect(
          () => UnregisterRequest.decode(Uint8List.sublistView(bytes, 0, n)),
          throwsA(isA<ProtocolException>()),
        );
      }
    });
  });

  group('WatchRequest', () {
    test('null type is empty payload', () {
      expect(const WatchRequest().encode(), isEmpty);
      expect(WatchRequest.decode(Uint8List(0)).type, isNull);
    });

    test('typed round trip', () {
      expect(WatchRequest.decode(WatchRequest(npc).encode()).type, npc);
    });

    test('short payload is a protocol error', () {
      expect(
        () => WatchRequest.decode(Uint8List(3)),
        throwsA(isA<ProtocolException>()),
      );
    });
  });

  group('ServiceEvent', () {
    test('UP round trip', () {
      final e = ServiceEvent(
        up: true,
        record: ServiceRecord(ServiceAddress(npc, 5), endpoints: uris),
      );
      expect(ServiceEvent.decodeUp(e.encode()), e);
      expect(e.procedure, Procedures.up);
    });

    test('DOWN round trip drops endpoints', () {
      final e = ServiceEvent(
        up: false,
        record: ServiceRecord(ServiceAddress(npc, 5), endpoints: uris),
      );
      final back = ServiceEvent.decodeDown(e.encode());
      expect(back.up, isFalse);
      expect(back.record.address, ServiceAddress(npc, 5));
      expect(back.record.endpoints, isEmpty);
      expect(e.procedure, Procedures.down);
      expect(back.encode(), e.encode());
    });
  });

  group('endpoint validation', () {
    // Parses, but its text form `%3E:x` has no scheme and does not parse.
    const relative = './>:x';
    // Has a scheme, but `tcp://%7B:` parses back without the empty port:
    // a different uri.
    const unstable = r'tcp:/.\\{:';
    const schemeless = '//10.0.0.5:9101/ws';
    // No authority and path `//`; its text form `tcp://` has an empty
    // authority and an empty path. Equal to its reparse one way only.
    const asymmetric = 'tcp:/../..//';

    Uint8List record(String endpoint) {
      final w = ByteWriter()
        ..name(npc)
        ..u48(5)
        ..u8(1)
        ..string8(endpoint);
      return w.toBytes();
    }

    test('checkEndpoint accepts usual endpoints', () {
      for (final uri in [
        ...uris,
        Uri.parse('wss://example.org:443/a/b?x=1#npc/2'),
        Uri.parse('ws://[::1]:9100/'),
        Uri.parse('ws://ü.example/ä'),
        Uri.parse('tcp://${'a' * 249}'),
      ]) {
        ServiceRecord.checkEndpoint(uri);
      }
    });

    test('checkEndpoint refuses what a watcher could not decode', () {
      expect(Uri.parse(unstable).hasScheme, isTrue);
      expect(
        Uri.tryParse(Uri.parse(unstable).toString()),
        isNot(Uri.parse(unstable)),
      );
      final asymmetricUri = Uri.parse(asymmetric);
      final reparsed = Uri.parse(asymmetricUri.toString());
      expect(reparsed == asymmetricUri, isNot(asymmetricUri == reparsed));
      for (final text in [
        relative,
        unstable,
        schemeless,
        asymmetric,
        'tcp://${'a' * 250}',
      ]) {
        expect(
          () => ServiceRecord.checkEndpoint(Uri.parse(text)),
          throwsArgumentError,
          reason: text,
        );
      }
    });

    test('decoders refuse such endpoints', () {
      for (final text in [relative, unstable, schemeless, asymmetric]) {
        final bytes = record(text);
        expect(
          () => ServiceRecord.decode(bytes),
          throwsA(isA<ProtocolException>()),
          reason: text,
        );
        expect(
          () => ServiceEvent.decodeUp(bytes),
          throwsA(isA<ProtocolException>()),
          reason: text,
        );
        // REGISTER has the same layout as a record.
        expect(
          () => RegisterRequest.decode(bytes),
          throwsA(isA<ProtocolException>()),
          reason: text,
        );
      }
      expect(ServiceRecord.decode(record('tcp://h:1')).endpoints, [
        Uri.parse('tcp://h:1'),
      ]);
    });
  });

  group('fuzz', () {
    final decoders = <String, Object Function(Uint8List)>{
      'ServiceRecord': ServiceRecord.decode,
      'RegisterRequest': RegisterRequest.decode,
      'RegisterResponse': RegisterResponse.decode,
      'UnregisterRequest': UnregisterRequest.decode,
      'WatchRequest': WatchRequest.decode,
      'ServiceEvent.up': ServiceEvent.decodeUp,
      'ServiceEvent.down': ServiceEvent.decodeDown,
    };

    var seed = 0;
    for (final MapEntry(key: name, value: decode) in decoders.entries) {
      final random = Random(++seed);
      test(
        '$name: only ProtocolException escapes; decoded values are stable',
        () {
          var decoded = 0;
          for (var i = 0; i < 3000; i++) {
            final input = fuzzInput(random, i);
            final Object value;
            try {
              value = decode(input);
            } on ProtocolException {
              continue;
            } catch (e) {
              fail('$name threw ${e.runtimeType} ($e) for ${hexString(input)}');
            }
            decoded++;
            // Whatever decodes encodes again, and that decodes to the same.
            final again = encodeAny(value);
            final back = decode(again);
            expect(encodeAny(back), again, reason: hexString(input));
            if (value is ServiceRecord) {
              expect(back, value, reason: hexString(input));
            }
          }
          expect(decoded, greaterThan(0));
        },
      );
    }
  });

  test('rejects endpoints that would not re-encode within 255 bytes', () {
    final raw = 'tcp://h/${'a b' * 80}';
    expect(raw.length, lessThanOrEqualTo(255));
    final w = ByteWriter()
      ..name(Name('npc'))
      ..u48(5)
      ..u8(1)
      ..string8(raw);
    expect(
      () => ServiceRecord.decode(w.toBytes()),
      throwsA(isA<ProtocolException>()),
    );
  });
}

Uint8List encodeAny(Object value) => switch (value) {
  ServiceRecord() => value.encode(),
  RegisterRequest() => value.encode(),
  RegisterResponse() => value.encode(),
  UnregisterRequest() => value.encode(),
  WatchRequest() => value.encode(),
  ServiceEvent() => value.encode(),
  _ => throw ArgumentError.value(value),
};
