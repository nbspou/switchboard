import 'dart:typed_data';

import 'package:switchboard/src/address/service_address.dart';
import 'package:switchboard/src/name.dart';
import 'package:switchboard/src/naming/naming_protocol.dart';
import 'package:switchboard/src/status.dart';
import 'package:test/test.dart';

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
}
