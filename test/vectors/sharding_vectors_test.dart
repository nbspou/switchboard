// Byte vectors of the sharding payloads (wiki page "Switchboard Sharding";
// table in doc/sharding-vectors.md), plus round trips and truncation. No
// dart:io: also runs compiled to JavaScript (`dart test -P node`).

import 'dart:typed_data';

import 'package:switchboard/src/address/service_address.dart';
import 'package:switchboard/src/bytes.dart';
import 'package:switchboard/src/name.dart';
import 'package:switchboard/src/naming/naming_protocol.dart';
import 'package:switchboard/src/status.dart';
import 'package:test/test.dart';

/// A vector: bytes, a decoder, and what the decoded value must encode to.
class Vector {
  Vector(this.name, String hex, this.decode, this.encode, this.check)
    : bytes = hexBytes(hex);

  final String name;
  final Uint8List bytes;
  final Object Function(Uint8List) decode;
  final Uint8List Function(Object) encode;
  final void Function(Object) check;
}

final kv = Name('kv');
final userq = Name('userq');
final room = Name('room');
final discord = Name('discord');
final zone = Name('zone');

final List<Vector> vectors = [
  Vector(
    'SLOTS "kv", 1024 slots, managed, holder-only, capacity 1',
    '6B 76 00 00 00 00 00 00 00 04 00 00 00 00 01 00 00 00',
    SlotsRequest.decode,
    (v) => (v as SlotsRequest).encode(),
    (v) {
      final r = v as SlotsRequest;
      expect(r.space, SlotSpace(kv, count: 1024));
      expect(r.capacity, 1);
    },
  ),
  Vector(
    'SLOTS "userq", 65536 slots, managed lazy, capacity 0',
    '75 73 65 72 71 00 00 00 00 00 01 00 00 01 00 00 00 00',
    SlotsRequest.decode,
    (v) => (v as SlotsRequest).encode(),
    (v) {
      final r = v as SlotsRequest;
      expect(r.space, SlotSpace(userq, count: 65536, lazy: true));
      expect(r.capacity, 0);
    },
  ),
  Vector(
    'SLOTSPC "room", 256 slots, managed, shared recovery',
    '72 6F 6F 6D 00 00 00 00 00 01 00 00 00 02',
    SlotSpace.decode,
    (v) => (v as SlotSpace).encode(),
    (v) => expect(v, SlotSpace(room, count: 256, shared: true)),
  ),
  Vector(
    'SLOTSPC "discord", 16 slots, static',
    '64 69 73 63 6F 72 64 00 10 00 00 00 01 00',
    SlotSpace.decode,
    (v) => (v as SlotSpace).encode(),
    (v) => expect(v, SlotSpace(discord, count: 16, mode: SlotMode.static)),
  ),
  Vector(
    'HOLDING "kv", slots 3 and 258',
    '6B 76 00 00 00 00 00 00 02 00 00 00 03 00 00 00 02 01 00 00',
    HoldingRequest.decode,
    (v) => (v as HoldingRequest).encode(),
    (v) {
      final r = v as HoldingRequest;
      expect(r.type, kv);
      expect(r.slots, [3, 258]);
    },
  ),
  Vector(
    'HOLDING response, discard slot 258',
    '01 00 00 00 02 01 00 00',
    HoldingResponse.decode,
    (v) => (v as HoldingResponse).encode(),
    (v) => expect((v as HoldingResponse).discard, [258]),
  ),
  Vector(
    'HOLDING response, nothing to discard',
    '00 00 00 00',
    HoldingResponse.decode,
    (v) => (v as HoldingResponse).encode(),
    (v) => expect((v as HoldingResponse).discard, isEmpty),
  ),
  Vector(
    'CLAIM "discord" slot 5, no storage, epoch 0',
    '64 69 73 63 6F 72 64 00 05 00 00 00 00 00 00 00 00',
    ClaimRequest.decode,
    (v) => (v as ClaimRequest).encode(),
    (v) {
      final r = v as ClaimRequest;
      expect(r.type, discord);
      expect(r.slot, 5);
      expect(r.holding, isFalse);
      expect(r.epoch, 0);
    },
  ),
  Vector(
    'CLAIM "kv" slot 7, holding, last epoch 9',
    '6B 76 00 00 00 00 00 00 07 00 00 00 01 09 00 00 00',
    ClaimRequest.decode,
    (v) => (v as ClaimRequest).encode(),
    (v) {
      final r = v as ClaimRequest;
      expect(r.slot, 7);
      expect(r.holding, isTrue);
      expect(r.epoch, 9);
    },
  ),
  Vector(
    'CLAIM response, epoch 7',
    '07 00 00 00',
    ClaimResponse.decode,
    (v) => (v as ClaimResponse).encode(),
    (v) => expect((v as ClaimResponse).epoch, 7),
  ),
  Vector(
    'RELEASE "kv" slot 7, keep storage',
    '6B 76 00 00 00 00 00 00 07 00 00 00 01',
    ReleaseRequest.decode,
    (v) => (v as ReleaseRequest).encode(),
    (v) {
      final r = v as ReleaseRequest;
      expect(r.type, kv);
      expect(r.slot, 7);
      expect(r.keepStorage, isTrue);
    },
  ),
  Vector(
    'LOCATE "userq" slot 0x1234',
    '75 73 65 72 71 00 00 00 34 12 00 00',
    LocateRequest.decode,
    (v) => (v as LocateRequest).encode(),
    (v) {
      final r = v as LocateRequest;
      expect(r.type, userq);
      expect(r.slot, 0x1234);
    },
  ),
  Vector(
    'LOCATE response, owned by 0x1A2B, epoch 7',
    '01 2B 1A 00 00 00 00 07 00 00 00',
    LocateResponse.decode,
    (v) => (v as LocateResponse).encode(),
    (v) => expect(v, const LocateResponse(SlotState.owned, 0x1A2B, 7)),
  ),
  Vector(
    'LOCATE response, free, epoch 3',
    '00 00 00 00 00 00 00 03 00 00 00',
    LocateResponse.decode,
    (v) => (v as LocateResponse).encode(),
    (v) => expect(v, const LocateResponse(SlotState.free, 0, 3)),
  ),
  Vector(
    'MIGRATE "zone" slot 4 to 0xB',
    '7A 6F 6E 65 00 00 00 00 04 00 00 00 0B 00 00 00 00 00',
    MigrateRequest.decode,
    (v) => (v as MigrateRequest).encode(),
    (v) {
      final r = v as MigrateRequest;
      expect(r.type, zone);
      expect(r.slot, 4);
      expect(r.to, 0xB);
    },
  ),
  Vector(
    'MIGRATE "zone" slot 4, allocator chooses',
    '7A 6F 6E 65 00 00 00 00 04 00 00 00 00 00 00 00 00 00',
    MigrateRequest.decode,
    (v) => (v as MigrateRequest).encode(),
    (v) => expect((v as MigrateRequest).to, 0),
  ),
  Vector(
    'PHASE draining',
    '01',
    PhaseItem.decode,
    (v) => (v as PhaseItem).encode(),
    (v) => expect((v as PhaseItem).phase, MigrationPhase.draining),
  ),
  Vector(
    'PHASE rolled back',
    '05',
    PhaseItem.decode,
    (v) => (v as PhaseItem).encode(),
    (v) => expect((v as PhaseItem).phase, MigrationPhase.rolledBack),
  ),
  Vector(
    'ASSIGN "kv" slot 7, epoch 8, holder 2',
    '6B 76 00 00 00 00 00 00 07 00 00 00 08 00 00 00 02 00 00 00 00 00 00',
    AssignRequest.decode,
    (v) => (v as AssignRequest).encode(),
    (v) {
      final r = v as AssignRequest;
      expect(r.type, kv);
      expect(r.slot, 7);
      expect(r.epoch, 8);
      expect(r.holder, 2);
      expect(r.shared, isFalse);
    },
  ),
  Vector(
    'ASSIGN "room" slot 1, epoch 1, no holder, shared recovery',
    '72 6F 6F 6D 00 00 00 00 01 00 00 00 01 00 00 00 00 00 00 00 00 00 01',
    AssignRequest.decode,
    (v) => (v as AssignRequest).encode(),
    (v) {
      final r = v as AssignRequest;
      expect(r.holder, 0);
      expect(r.shared, isTrue);
    },
  ),
  Vector(
    'ASSIGN response, holding (empty)',
    '',
    AssignResponse.decode,
    (v) => (v as AssignResponse).encode(),
    (v) => expect((v as AssignResponse).notHolding, isFalse),
  ),
  Vector(
    'ASSIGN response, not holding',
    '01',
    AssignResponse.decode,
    (v) => (v as AssignResponse).encode(),
    (v) => expect((v as AssignResponse).notHolding, isTrue),
  ),
  Vector(
    'DRAIN "kv" slot 7, epoch 9, to 3',
    '6B 76 00 00 00 00 00 00 07 00 00 00 09 00 00 00 03 00 00 00 00 00',
    DrainRequest.decode,
    (v) => (v as DrainRequest).encode(),
    (v) {
      final r = v as DrainRequest;
      expect(r.type, kv);
      expect(r.slot, 7);
      expect(r.epoch, 9);
      expect(r.to, 3);
    },
  ),
  Vector(
    'FORWARD "kv" slot 7, epoch 9, to 3',
    '6B 76 00 00 00 00 00 00 07 00 00 00 09 00 00 00 03 00 00 00 00 00',
    ForwardRequest.decode,
    (v) => (v as ForwardRequest).encode(),
    (v) {
      final r = v as ForwardRequest;
      expect(r.slot, 7);
      expect(r.epoch, 9);
      expect(r.to, 3);
    },
  ),
  Vector(
    'RESUME "kv" slot 7, epoch 8',
    '6B 76 00 00 00 00 00 00 07 00 00 00 08 00 00 00',
    ResumeRequest.decode,
    (v) => (v as ResumeRequest).encode(),
    (v) {
      final r = v as ResumeRequest;
      expect(r.type, kv);
      expect(r.slot, 7);
      expect(r.epoch, 8);
    },
  ),
  Vector(
    'SLOT "kv" slot 7, owned by 2, holder 2, epoch 8',
    '6B 76 00 00 00 00 00 00 07 00 00 00 01 02 00 00 00 00 00 00 00 00 00 '
        '00 00 02 00 00 00 00 00 08 00 00 00',
    SlotItem.decode,
    (v) => (v as SlotItem).encode(),
    (v) => expect(
      v,
      SlotItem(kv, 7, const SlotEntry.owned(2, holder: 2, epoch: 8)),
    ),
  ),
  Vector(
    'SLOT "kv" slot 7, migrating from 2 to 3, holder 2, epoch 8',
    '6B 76 00 00 00 00 00 00 07 00 00 00 02 02 00 00 00 00 00 03 00 00 00 '
        '00 00 02 00 00 00 00 00 08 00 00 00',
    SlotItem.decode,
    (v) => (v as SlotItem).encode(),
    (v) => expect(
      v,
      SlotItem(kv, 7, const SlotEntry.migrating(2, 3, holder: 2, epoch: 8)),
    ),
  ),
  Vector(
    'SLOT "kv" slot 7, free, holder 2, epoch 8',
    '6B 76 00 00 00 00 00 00 07 00 00 00 00 00 00 00 00 00 00 00 00 00 00 '
        '00 00 02 00 00 00 00 00 08 00 00 00',
    SlotItem.decode,
    (v) => (v as SlotItem).encode(),
    (v) =>
        expect(v, SlotItem(kv, 7, const SlotEntry.free(holder: 2, epoch: 8))),
  ),
  Vector(
    'SLOT "x" slot 0xFFFFFFFF, owned by 0xFFFFFFFFFFFF, holder '
        '0x123456789ABC, epoch 0xFFFFFFFF',
    '78 00 00 00 00 00 00 00 FF FF FF FF 01 FF FF FF FF FF FF 00 00 00 00 '
        '00 00 BC 9A 78 56 34 12 FF FF FF FF',
    SlotItem.decode,
    (v) => (v as SlotItem).encode(),
    (v) => expect(
      v,
      SlotItem(
        Name('x'),
        0xFFFFFFFF,
        const SlotEntry.owned(
          0xFFFFFFFFFFFF,
          holder: 0x123456789ABC,
          epoch: 0xFFFFFFFF,
        ),
      ),
    ),
  ),
];

/// Negative vectors: each must be a protocol error.
final Map<String, (String, Object Function(Uint8List))> negative = {
  'SLOTSPC with mode 2': (
    '6B 76 00 00 00 00 00 00 00 04 00 00 02 00',
    SlotSpace.decode,
  ),
  'SLOT with state 3': (
    '6B 76 00 00 00 00 00 00 07 00 00 00 03 02 00 00 00 00 00 00 00 00 00 '
        '00 00 02 00 00 00 00 00 08 00 00 00',
    SlotItem.decode,
  ),
  'HOLDING announcing 2 slots, carrying 1': (
    '6B 76 00 00 00 00 00 00 02 00 00 00 03 00 00 00',
    HoldingRequest.decode,
  ),
  'PHASE 0': ('00', PhaseItem.decode),
  'PHASE 6': ('06', PhaseItem.decode),
  'LOCATE response with state 3': (
    '03 00 00 00 00 00 00 00 00 00 00',
    LocateResponse.decode,
  ),
  'CLAIM without epoch': (
    '6B 76 00 00 00 00 00 00 07 00 00 00 01',
    ClaimRequest.decode,
  ),
};

void main() {
  group('vectors', () {
    for (final v in vectors) {
      test(v.name, () {
        final value = v.decode(v.bytes);
        v.check(value);
        expect(hexString(v.encode(value)), hexString(v.bytes));
      });
    }
  });

  group('negative vectors', () {
    for (final MapEntry(key: name, value: (hex, decode)) in negative.entries) {
      test(name, () {
        expect(() => decode(hexBytes(hex)), throwsA(isA<ProtocolException>()));
      });
    }
  });

  group('codecs', () {
    test('every structure: truncation is a protocol error, trailing bytes '
        'are ignored', () {
      for (final v in vectors) {
        if (v.bytes.isEmpty) {
          continue;
        }
        // An ASSIGN response is a flags byte or nothing: any prefix is valid.
        if (v.name.startsWith('ASSIGN response')) {
          continue;
        }
        for (var n = 0; n < v.bytes.length; n++) {
          expect(
            () => v.decode(Uint8List.sublistView(v.bytes, 0, n)),
            throwsA(isA<ProtocolException>()),
            reason: '${v.name}, prefix $n',
          );
        }
        final longer = Uint8List.fromList([...v.bytes, 0xEE, 0x01]);
        expect(
          hexString(v.encode(v.decode(longer))),
          hexString(v.bytes),
          reason: v.name,
        );
      }
    });

    test('unknown flag bits are ignored', () {
      final space = SlotSpace.decode(
        hexBytes('6B 76 00 00 00 00 00 00 00 04 00 00 00 FE'),
      );
      expect(space.lazy, isFalse);
      expect(space.shared, isTrue);
      expect(AssignResponse.decode(hexBytes('FE')).notHolding, isFalse);
      expect(
        ClaimRequest.decode(
          hexBytes('6B 76 00 00 00 00 00 00 07 00 00 00 FE 00 00 00 00'),
        ).holding,
        isFalse,
      );
    });

    test('a slot list longer than the payload is refused before reading', () {
      expect(
        () => HoldingResponse.decode(hexBytes('FF FF FF FF 01 00 00 00')),
        throwsA(isA<ProtocolException>()),
      );
    });

    test('values outside u32 and u48 are refused on encode', () {
      expect(
        () => ClaimRequest(kv, 0x100000000).encode(),
        throwsA(isA<RangeError>()),
      );
      expect(
        () => SlotItem(kv, 1, const SlotEntry.owned(0x1000000000000)).encode(),
        throwsA(isA<RangeError>()),
      );
      expect(
        () => const ClaimResponse(-1).encode(),
        throwsA(isA<RangeError>()),
      );
    });

    test('procedure names', () {
      expect(
        [
          Procedures.slots,
          Procedures.holding,
          Procedures.claim,
          Procedures.release,
          Procedures.locate,
          Procedures.migrate,
          Procedures.phase,
          Procedures.assign,
          Procedures.drain,
          Procedures.forward,
          Procedures.resume,
          Procedures.slotSpace,
          Procedures.slot,
        ].map((n) => '$n'),
        [
          'SLOTS',
          'HOLDING',
          'CLAIM',
          'RELEASE',
          'LOCATE',
          'MIGRATE',
          'PHASE',
          'ASSIGN',
          'DRAIN',
          'FORWARD',
          'RESUME',
          'SLOTSPC',
          'SLOT',
        ],
      );
      expect(Procedures.slotSpace.bytes, hexBytes('53 4C 4F 54 53 50 43 00'));
      expect(StatusCode.moved.code, 37);
      expect(StatusCode.fromCode(37), StatusCode.moved);
    });
  });

  group('MOVED reason', () {
    test('format', () {
      final owner = ServiceAddress(userq, 0x1A2B);
      expect(MovedStatus.format(owner, 7), 'userq/1a2b 7');
      expect(MovedStatus.format(null), '');
      expect(MovedStatus(owner, 7).reason, 'userq/1a2b 7');
      expect(const MovedStatus().reason, '');
      expect(
        MovedStatus(owner, 0xFFFFFFFF).toStatus(),
        Status.of(StatusCode.moved, 'userq/1a2b 4294967295'),
      );
      expect(
        () => MovedStatus.format(ServiceAddress(userq), 1),
        throwsArgumentError,
      );
    });

    test('parse', () {
      expect(
        MovedStatus.parse('userq/1a2b 7'),
        MovedStatus(ServiceAddress(userq, 0x1A2B), 7),
      );
      expect(
        MovedStatus.parse('x/ffffffffffff 4294967295'),
        MovedStatus(ServiceAddress(Name('x'), maxInstance), 0xFFFFFFFF),
      );
      for (final unknown in [
        '',
        'userq/1a2b',
        'userq 7',
        'userq/0 7',
        'userq/1a2b 4294967296',
        'userq/1a2b  7',
        'userq/1a2b -7',
        'userq/1a2b 7 ',
        'userq/zz 7',
        '/1 7',
        'waytoolongname/1 7',
      ]) {
        expect(
          MovedStatus.parse(unknown),
          const MovedStatus(),
          reason: unknown,
        );
      }
      expect(
        MovedStatus.fromStatus(Status.of(StatusCode.moved, 'kv/2 8')),
        MovedStatus(ServiceAddress(kv, 2), 8),
      );
      expect(
        MovedStatus.fromStatus(Status.of(StatusCode.unavailable, 'kv/2 8')),
        const MovedStatus(),
      );
    });
  });
}
