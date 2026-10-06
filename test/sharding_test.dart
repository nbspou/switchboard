// The naming service side of sharding: slot spaces, ownership, the
// hand-over orchestration and the allocator, driven by scripted instances
// over in-memory links.

import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:switchboard/src/name.dart';
import 'package:switchboard/src/naming/naming_protocol.dart';
import 'package:switchboard/src/naming/naming_service.dart';
import 'package:switchboard/src/naming/slot_table.dart';
import 'package:switchboard/src/status.dart';
import 'package:test/test.dart';

import 'naming_harness.dart';
import 'sharding_harness.dart';

SlotSpace staticSpace(Name type, int count) =>
    SlotSpace(type, count: count, mode: SlotMode.static);

/// Number of slots routed to each instance.
Map<int, int> counts(SlotTable table) {
  final out = <int, int>{};
  for (final entry in table.entries.values) {
    if (entry.owner != 0) {
      out.update(entry.owner, (n) => n + 1, ifAbsent: () => 1);
    }
  }
  return out;
}

bool allOwned(SlotTable? table) =>
    table != null &&
    Iterable<int>.generate(table.count)
        .every((s) => table[s].state == SlotState.owned);

void main() {
  late Harness h;
  late List<String> log;

  setUp(() {
    h = Harness();
    log = [];
  });
  tearDown(() => h.close());

  Instance instance(Name type, int id, {Harness? harness}) =>
      Instance(harness ?? h, type, id, log);

  group('SLOTS', () {
    test('defines, confirms, refuses a different definition', () async {
      final a = instance(kv, 1);
      final b = instance(kv, 2);
      await a.start();
      await b.start();
      final watch = ItemWatch(h.link().$1);
      expect(await watch.take(3), ['UP kv/1', 'UP kv/2', 'SYNCED']);
      await a.slots(SlotSpace(kv, count: 8), capacity: 0);
      expect(await watch.next, 'SLOTSPC kv 8 managed');
      await b.slots(SlotSpace(kv, count: 8), capacity: 0);
      // An explicit claim: the space is no longer blank.
      expect(await a.claim(0), 1);
      expect(await watch.next, 'SLOT kv/0 owned 1 holder 1 epoch 1');
      for (final other in [
        SlotSpace(kv, count: 16),
        SlotSpace(kv, count: 8, lazy: true),
        SlotSpace(kv, count: 8, shared: true),
        staticSpace(kv, 8),
      ]) {
        await expectLater(
          b.slots(other, capacity: 0),
          throwsStatus(StatusCode.failedPrecondition),
          reason: '$other',
        );
      }
      expect(h.service.slotTable(kv)!.space, SlotSpace(kv, count: 8));
      expect(h.service.slotTables.keys, [kv]);
      // A router or operator tool without a registration may confirm it.
      final (router, _) = h.link();
      await router.request(
        'SLOTS',
        SlotsRequest(SlotSpace(kv, count: 8), capacity: 5).encode(),
      );
    });

    test('redefines a space once every slot is free with holder 0', () async {
      final discord = Name('discord');
      final a = instance(discord, 1);
      await a.start(space: staticSpace(discord, 4), capacity: 0);
      final (router, _) = h.link();
      final watch = ItemWatch(router, payload: WatchRequest(discord).encode());
      expect(await watch.take(3), [
        'UP discord/1',
        'SLOTSPC discord 4 static',
        'SYNCED',
      ]);
      expect(await a.claim(1), 1);
      expect(await watch.next, 'SLOT discord/1 owned 1 holder 1 epoch 1');
      await expectLater(
        a.slots(staticSpace(discord, 8), capacity: 0),
        throwsStatus(StatusCode.failedPrecondition),
      );
      await a.release(1, keepStorage: true);
      expect(await watch.next, 'SLOT discord/1 free holder 1 epoch 1');
      // A holder still counts.
      await expectLater(
        a.slots(staticSpace(discord, 8), capacity: 0),
        throwsStatus(StatusCode.failedPrecondition),
      );
      expect(await a.claim(1), 2);
      await a.release(1);
      expect(await watch.take(2), [
        'SLOT discord/1 owned 1 holder 1 epoch 2',
        'SLOT discord/1 free holder 0 epoch 2',
      ]);
      await a.slots(staticSpace(discord, 8), capacity: 0);
      expect(await watch.next, 'SLOTSPC discord 8 static');
      final table = h.service.slotTable(discord)!;
      expect(table.count, 8);
      expect(table.entries, isEmpty);
    });

    test('refuses invalid requests', () async {
      final (c, _) = h.link();
      Future<void> slots(Uint8List payload) => c.request('SLOTS', payload);
      await expectLater(
        slots(SlotsRequest(SlotSpace(kv, count: 0), capacity: 1).encode()),
        throwsStatus(StatusCode.invalidArgument),
      );
      await expectLater(
        slots(
          SlotsRequest(SlotSpace(Name(''), count: 1), capacity: 1).encode(),
        ),
        throwsStatus(StatusCode.invalidArgument),
      );
      await expectLater(
        slots(SlotsRequest(SlotSpace(kv, count: 65537), capacity: 1).encode()),
        throwsStatus(StatusCode.outOfRange),
      );
      await expectLater(
        slots(Uint8List(5)),
        throwsStatus(StatusCode.invalidArgument),
      );
      // Mode 2.
      await expectLater(
        slots(Uint8List.fromList([...kv.bytes, 1, 0, 0, 0, 2, 0, 0, 0, 0, 0])),
        throwsStatus(StatusCode.invalidArgument),
      );
      for (final procedure in ['HOLDING', 'CLAIM', 'RELEASE', 'LOCATE']) {
        await expectLater(
          c.request(procedure, Uint8List(3)),
          throwsStatus(StatusCode.invalidArgument),
          reason: procedure,
        );
      }
      await expectLater(
        c.streamRequest('MIGRATE', Uint8List(3)).done,
        throwsStatus(StatusCode.invalidArgument),
      );
      expect(h.service.slotTables, isEmpty);
    });

    test(
      'a channel with several instances of the type cannot shard it',
      () async {
        final (c, _) = h.link();
        await register(c, 'kv', instance: 1);
        await register(c, 'kv', instance: 2);
        await expectLater(
          c.request(
            'SLOTS',
            SlotsRequest(SlotSpace(kv, count: 4), capacity: 1).encode(),
          ),
          throwsStatus(StatusCode.failedPrecondition),
        );
      },
    );
  });

  group('CLAIM and RELEASE', () {
    final discord = Name('discord');

    test('static claims, conflicts, release and holders', () async {
      final a = instance(discord, 1);
      final b = instance(discord, 2);
      await a.start(space: staticSpace(discord, 4), capacity: 0);
      await b.start(space: staticSpace(discord, 4), capacity: 0);
      final table = h.service.slotTable(discord)!;
      expect(await a.claim(1), 1);
      expect(log, ['1 ASSIGN 1 e1 h0']);
      expect(table[1], const SlotEntry.owned(1, holder: 1, epoch: 1));
      // Claiming an owned slot again is a no-op.
      expect(await a.claim(1), 1);
      expect(log, hasLength(1));
      await expectLater(b.claim(1), throwsStatus(StatusCode.alreadyExists));
      await expectLater(
        b.release(1),
        throwsStatus(StatusCode.permissionDenied),
      );
      await expectLater(
        b.release(2),
        throwsStatus(StatusCode.permissionDenied),
      );
      await expectLater(b.claim(4), throwsStatus(StatusCode.notFound));
      final (raw, _) = h.link();
      await expectLater(
        raw.request('CLAIM', ClaimRequest(Name('nope'), 0).encode()),
        throwsStatus(StatusCode.notFound),
      );
      // Not registered as the type on this channel.
      await expectLater(
        raw.request('CLAIM', ClaimRequest(discord, 0).encode()),
        throwsStatus(StatusCode.failedPrecondition),
      );
      // Release keeping the storage: the next owner fetches from the holder.
      await a.release(1, keepStorage: true);
      expect(table[1], const SlotEntry.free(holder: 1, epoch: 1));
      expect(await b.claim(1), 2);
      expect(log.last, '2 ASSIGN 1 e2 h1');
      expect(table[1], const SlotEntry.owned(2, holder: 2, epoch: 2));
      // A claimant that holds the storage of a slot nobody else holds.
      expect(await a.claim(2, holding: true), 1);
      expect(log.last, '1 ASSIGN 2 e1 h1');
      // "Not holding" keeps the previous holder.
      await a.release(2, keepStorage: true);
      b.onAssign = (_) async => const AssignResponse(notHolding: true);
      expect(await b.claim(2), 2);
      expect(table[2], const SlotEntry.owned(2, holder: 1, epoch: 2));
      // A refused ASSIGN: the claim fails, the slot stays free.
      b.onAssign = (_) async =>
          throw SwitchboardException.of(StatusCode.unavailable, 'not ready');
      await expectLater(b.claim(3), throwsStatus(StatusCode.unavailable));
      expect(table[3], SlotEntry.unassigned);
      expect(log.last, '2 ASSIGN 3 e1 h0');
    });

    test('an instance going down frees its slots, holder kept', () async {
      final a = instance(discord, 1);
      final b = instance(discord, 2);
      await a.start(space: staticSpace(discord, 4), capacity: 0);
      await b.start(space: staticSpace(discord, 4), capacity: 0);
      await a.claim(0);
      b.onAssign = (_) async => const AssignResponse(notHolding: true);
      await b.claim(1);
      await a.close();
      await until(() => h.service.slotTable(discord)![0].isFree);
      final table = h.service.slotTable(discord)!;
      expect(table[0], const SlotEntry.free(holder: 1, epoch: 1));
      // Static: nothing is reassigned.
      await pump();
      expect(table[1], const SlotEntry.owned(2, epoch: 1));
      expect(log, ['1 ASSIGN 0 e1 h0', '2 ASSIGN 1 e1 h0']);
      // A standby claims it and fetches the state from the holder.
      expect(await b.claim(0), 2);
      expect(log.last, '2 ASSIGN 0 e2 h1');
    });
  });

  group('LOCATE', () {
    test('lazy: assigns on first use, by spare capacity', () async {
      final a = instance(userq, 1);
      final b = instance(userq, 2);
      final space = SlotSpace(userq, count: 64, lazy: true);
      await a.start(space: space, capacity: 1);
      await b.start(space: space, capacity: 3);
      await pump();
      expect(h.service.slotTable(userq)!.entries, isEmpty);
      final (router, _) = h.link();
      final r = Instance(h, userq, 0, log)..channel = router;
      final located = [for (var s = 0; s < 8; s++) await r.locate(s)];
      expect(located.map((l) => l.state), everyElement(SlotState.owned));
      expect(located.map((l) => l.epoch), everyElement(1));
      expect(located.map((l) => l.owner), [2, 1, 2, 2, 2, 1, 2, 2]);
      expect(counts(h.service.slotTable(userq)!), {2: 6, 1: 2});
      // Located again: the same answer, no new assignment.
      expect(await r.locate(0), const LocateResponse(SlotState.owned, 2, 1));
      expect(log, hasLength(8));
      await expectLater(r.locate(64), throwsStatus(StatusCode.notFound));
    });

    test('prefers the holder over spare capacity', () async {
      final a = instance(userq, 1);
      final b = instance(userq, 2);
      final space = SlotSpace(userq, count: 64, lazy: true);
      await a.start(space: space, capacity: 1);
      await b.start(space: space, capacity: 10);
      // a holds the storage of slot 20: it gets it back at once.
      expect(await a.holding([20]), isEmpty);
      final (router, _) = h.link();
      final r = Instance(h, userq, 0, log)..channel = router;
      expect(await r.locate(20), const LocateResponse(SlotState.owned, 1, 1));
      expect(await r.locate(21), const LocateResponse(SlotState.owned, 2, 1));
      expect(log, ['1 ASSIGN 20 e1 h1', '2 ASSIGN 21 e1 h0']);
    });

    test('static: a free slot is answered as free', () async {
      final a = instance(zone, 1);
      await a.start(space: staticSpace(zone, 4), capacity: 1);
      expect(await a.locate(2), const LocateResponse(SlotState.free, 0, 0));
      await a.claim(2);
      expect(await a.locate(2), const LocateResponse(SlotState.owned, 1, 1));
      expect(log, ['1 ASSIGN 2 e1 h0']);
    });

    test('capacity 0 takes no slots from LOCATE or the allocator', () async {
      final a = instance(userq, 1);
      await a.start(
        space: SlotSpace(userq, count: 16, lazy: true),
        capacity: 0,
      );
      expect(await a.locate(5), const LocateResponse(SlotState.free, 0, 0));
      final b = instance(userq, 2);
      await b.start(space: SlotSpace(userq, count: 16, lazy: true));
      expect(await a.locate(5), const LocateResponse(SlotState.owned, 2, 1));
      // Eager: everything goes to the instance with capacity.
      final c = instance(kv, 3);
      final d = instance(kv, 4);
      await c.start(space: SlotSpace(kv, count: 4), capacity: 0);
      await d.start(space: SlotSpace(kv, count: 4), capacity: 1);
      await until(() => allOwned(h.service.slotTable(kv)));
      expect(counts(h.service.slotTable(kv)!), {4: 4});
    });

    test('an ASSIGN refused fails LOCATE with UNAVAILABLE', () async {
      final a = instance(userq, 1);
      await a.start(space: SlotSpace(userq, count: 16, lazy: true));
      a.onAssign = (_) async =>
          throw SwitchboardException.of(StatusCode.unavailable, 'loading');
      await expectLater(a.locate(3), throwsStatus(StatusCode.unavailable));
      expect(h.service.slotTable(userq)![3], SlotEntry.unassigned);
    });
  });

  group('allocator', () {
    test('eager: fills every slot in proportion to capacity', () async {
      final h = Harness(assignmentHold: ms50);
      addTearDown(h.close);
      final a = instance(kv, 1, harness: h);
      final b = instance(kv, 2, harness: h);
      await a.start(space: SlotSpace(kv, count: 12), capacity: 1);
      await b.start(space: SlotSpace(kv, count: 12), capacity: 2);
      expect(h.service.isHoldingAssignments, isTrue);
      expect(h.service.slotTable(kv)!.entries, isEmpty);
      await until(() => allOwned(h.service.slotTable(kv)));
      expect(counts(h.service.slotTable(kv)!), {1: 4, 2: 8});
      expect(log.where((l) => !l.endsWith('e1 h0')), isEmpty);
    });

    test('eager: 1024 slots over two equal instances', () async {
      final h = Harness(assignmentHold: ms50);
      addTearDown(h.close);
      final space = SlotSpace(kv, count: 1024);
      await instance(kv, 1, harness: h).start(space: space);
      await instance(kv, 2, harness: h).start(space: space);
      await until(() => allOwned(h.service.slotTable(kv)));
      expect(counts(h.service.slotTable(kv)!), {1: 512, 2: 512});
    });

    test('a third instance receives slots one migration at a time', () async {
      final h = Harness(assignmentHold: ms50);
      addTearDown(h.close);
      final space = SlotSpace(kv, count: 12);
      await instance(kv, 1, harness: h).start(space: space);
      await instance(kv, 2, harness: h).start(space: space);
      await until(() => allOwned(h.service.slotTable(kv)));
      expect(counts(h.service.slotTable(kv)!), {1: 6, 2: 6});
      log.clear();
      final migrating = <int>{};
      var maxConcurrent = 0;
      final sub = h.service.slotEvents.listen((item) {
        if (item.entry.state == SlotState.migrating) {
          migrating.add(item.slot);
        } else {
          migrating.remove(item.slot);
        }
        if (migrating.length > maxConcurrent) {
          maxConcurrent = migrating.length;
        }
      });
      addTearDown(sub.cancel);
      await instance(kv, 3, harness: h).start(space: space);
      await until(
        () =>
            counts(h.service.slotTable(kv)!).values.every((n) => n == 4) &&
            migrating.isEmpty &&
            log.length == 12,
      );
      await pump();
      expect(maxConcurrent, 1);
      // Strictly sequential: DRAIN, ASSIGN, FORWARD, then the next one,
      // alternately from the most over-share instance.
      expect(log, [
        '1 DRAIN 0 e2 to3',
        '3 ASSIGN 0 e2 h1',
        '1 FORWARD 0 e2 to3',
        '2 DRAIN 1 e2 to3',
        '3 ASSIGN 1 e2 h2',
        '2 FORWARD 1 e2 to3',
        '1 DRAIN 2 e2 to3',
        '3 ASSIGN 2 e2 h1',
        '1 FORWARD 2 e2 to3',
        '2 DRAIN 3 e2 to3',
        '3 ASSIGN 3 e2 h2',
        '2 FORWARD 3 e2 to3',
      ]);
    });

    test('holder-only: a down instance\'s slots wait for the grace', () {
      fakeAsync((async) {
        final h = Harness(assignmentHold: ms50);
        final log = <String>[];
        final a = Instance(h, kv, 1, log);
        final b = Instance(h, kv, 2, log);
        final space = SlotSpace(kv, count: 4);
        unawaited(a.start(space: space));
        unawaited(b.start(space: space));
        async.elapse(ms50 * 2);
        final table = h.service.slotTable(kv)!;
        expect(counts(table), {1: 2, 2: 2});
        expect(table.slotsOf(1), [0, 2]);
        log.clear();
        unawaited(a.close());
        async.elapse(ms10);
        expect(table[0], const SlotEntry.free(holder: 1, epoch: 1));
        expect(table[2], const SlotEntry.free(holder: 1, epoch: 1));
        async.elapse(const Duration(minutes: 4, seconds: 59));
        expect(log, isEmpty);
        expect(table[0].isFree, isTrue);
        async.elapse(const Duration(seconds: 2));
        // Reassigned with the holder cleared: the state starts fresh.
        expect(log, ['2 ASSIGN 0 e2 h0', '2 ASSIGN 2 e2 h0']);
        expect(table[0], const SlotEntry.owned(2, holder: 2, epoch: 2));
        expect(counts(table), {2: 4});
        unawaited(h.close());
        async.flushMicrotasks();
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('holder-only: the holder returning within the grace reclaims', () {
      fakeAsync((async) {
        final h = Harness(assignmentHold: ms50);
        final log = <String>[];
        final space = SlotSpace(kv, count: 4);
        unawaited(Instance(h, kv, 1, log).start(space: space));
        final b = Instance(h, kv, 2, log);
        unawaited(b.start(space: space));
        async.elapse(ms50 * 2);
        unawaited(b.close());
        async.elapse(const Duration(minutes: 1));
        log.clear();
        // Same id after a reboot.
        final again = Instance(h, kv, 2, log);
        unawaited(again.start(space: space));
        async.elapse(ms10);
        expect(log, ['2 ASSIGN 1 e2 h2', '2 ASSIGN 3 e2 h2']);
        expect(counts(h.service.slotTable(kv)!), {1: 2, 2: 2});
        async.elapse(const Duration(minutes: 10));
        expect(log, hasLength(2));
        unawaited(h.close());
        async.flushMicrotasks();
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('shared recovery: reassigned at once, from the holder', () async {
      final h = Harness(assignmentHold: ms50);
      addTearDown(h.close);
      final space = SlotSpace(room, count: 4, shared: true);
      final a = instance(room, 1, harness: h);
      await a.start(space: space);
      await instance(room, 2, harness: h).start(space: space);
      await until(() => allOwned(h.service.slotTable(room)));
      log.clear();
      await a.close();
      await until(() => counts(h.service.slotTable(room)!)[2] == 4);
      expect(log, ['2 ASSIGN 0 e2 h1 shared', '2 ASSIGN 2 e2 h1 shared']);
    });
  });

  group('HOLDING', () {
    test('records holders, reclaims, lists what to discard', () async {
      final a = instance(kv, 1);
      final b = instance(kv, 2);
      await a.start();
      await b.start();
      // Defined by an operator: no candidate yet, nothing assigned.
      final (op, _) = h.link();
      await op.request(
        'SLOTS',
        SlotsRequest(SlotSpace(kv, count: 4), capacity: 0).encode(),
      );
      expect(await a.holding([0, 1, 0]), isEmpty);
      expect(await b.holding([1, 2, 7]), [1, 7]);
      final table = h.service.slotTable(kv)!;
      expect(table[1], const SlotEntry.free(holder: 1));
      expect(table[2], const SlotEntry.free(holder: 2));
      expect(log, isEmpty);
      // a becomes a candidate: its slots come back first. b holds slot 2
      // but has not said whether it takes slots: the slot waits for it.
      await a.slots(SlotSpace(kv, count: 4));
      await until(() => table[3].state == SlotState.owned);
      await until(() => table[1].state == SlotState.owned);
      await pump();
      expect(table[2], const SlotEntry.free(holder: 2));
      // b takes no slots: the state is fetched from it.
      await b.slots(SlotSpace(kv, count: 4), capacity: 0);
      await until(() => allOwned(table));
      expect(log, [
        '1 ASSIGN 0 e1 h1',
        '1 ASSIGN 1 e1 h1',
        '1 ASSIGN 3 e1 h0',
        '1 ASSIGN 2 e1 h2',
      ]);
      await expectLater(
        op.request('HOLDING', HoldingRequest(kv, [0]).encode()),
        throwsStatus(StatusCode.failedPrecondition),
      );
      await expectLater(
        a.channel.request('HOLDING', HoldingRequest(zone, [0]).encode()),
        throwsStatus(StatusCode.notFound),
      );
    });
  });

  group('WATCH and LOOKUP', () {
    test('snapshot: SLOTSPC before its slots, empty slots left out', () async {
      final a = instance(kv, 1);
      await a.start(space: staticSpace(kv, 4), capacity: 0);
      await a.claim(1);
      await a.claim(2);
      await a.release(2, keepStorage: true);
      await a.claim(3);
      await a.release(3);
      final (router, _) = h.link();
      final watch = ItemWatch(router);
      expect(await watch.take(5), [
        'UP kv/1',
        'SLOTSPC kv 4 static',
        'SLOT kv/1 owned 1 holder 1 epoch 1',
        'SLOT kv/2 free holder 1 epoch 1',
        'SYNCED',
      ]);
      await a.claim(0);
      expect(await watch.next, 'SLOT kv/0 owned 1 holder 1 epoch 1');
      await a.release(0);
      expect(await watch.next, 'SLOT kv/0 free holder 0 epoch 1');
      // Other types see none of it.
      final other = ItemWatch(router, payload: WatchRequest(zone).encode());
      expect(await other.next, 'SYNCED');
      final lookup = ItemWatch(router, procedure: 'LOOKUP', payload: kv.bytes);
      expect(await lookup.take(4), [
        'UP kv/1',
        'SLOTSPC kv 4 static',
        'SLOT kv/1 owned 1 holder 1 epoch 1',
        'SLOT kv/2 free holder 1 epoch 1',
      ]);
      await lookup.stream.done;
    });
  });

  group('MIGRATE', () {
    late Instance a;
    late Instance b;
    late Instance router;

    setUp(() async {
      a = instance(zone, 1);
      b = instance(zone, 2);
      await a.start(space: staticSpace(zone, 4), capacity: 0);
      await b.start(space: staticSpace(zone, 4), capacity: 0);
      await a.claim(1);
      await a.claim(2);
      router = Instance(h, zone, 0, log)..channel = h.link().$1;
      log.clear();
    });

    test('hand-over: DRAIN, ASSIGN, table, FORWARD', () async {
      // The old owner's own watch shows when it learns of the table.
      final ready = Completer<void>();
      a.channel.streamRequest('WATCH', Uint8List(0)).items.listen((m) {
        if (m.procedureName == 'SYNCED') {
          ready.complete();
        } else if (ready.isCompleted && m.procedureName == 'SLOT') {
          log.add('1 sees ${describeItem(m)}');
        }
      });
      await ready.future;
      final m = Migration(router.channel, zone, 1, to: 2);
      expect(await m.done, Status.ok);
      expect(m.phases, ['draining', 'assigning', 'forwarding', 'done']);
      expect(log, [
        '1 sees SLOT zone/1 migrating 1->2 holder 1 epoch 1',
        '1 DRAIN 1 e2 to2',
        '2 ASSIGN 1 e2 h1',
        '1 sees SLOT zone/1 owned 2 holder 2 epoch 2',
        '1 FORWARD 1 e2 to2',
      ]);
      expect(
        h.service.slotTable(zone)![1],
        const SlotEntry.owned(2, holder: 2, epoch: 2),
      );
    });

    test('one migration per space at a time; others queue', () async {
      final gate = Completer<void>();
      a.onDrain = (r) => r.slot == 1 ? gate.future : Future.value();
      final first = Migration(router.channel, zone, 1, to: 2);
      await until(() => log.contains('1 DRAIN 1 e2 to2'));
      final second = Migration(router.channel, zone, 2, to: 2);
      final again = Migration(router.channel, zone, 1, to: 2);
      final queuedAgain = Migration(router.channel, zone, 2, to: 2);
      expect(
        (await again.done).known,
        StatusCode.failedPrecondition,
        reason: 'already migrating',
      );
      expect((await queuedAgain.done).known, StatusCode.failedPrecondition);
      // Longer than every timeout: kept alive meanwhile.
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(second.phases, isEmpty);
      expect(log, ['1 DRAIN 1 e2 to2']);
      gate.complete();
      expect(await first.done, Status.ok);
      expect(await second.done, Status.ok);
      expect(log, [
        '1 DRAIN 1 e2 to2',
        '2 ASSIGN 1 e2 h1',
        '1 FORWARD 1 e2 to2',
        '1 DRAIN 2 e2 to2',
        '2 ASSIGN 2 e2 h1',
        '1 FORWARD 2 e2 to2',
      ]);
    });

    test('ASSIGN refused: RESUME, epoch unchanged', () async {
      b.onAssign = (_) async =>
          throw SwitchboardException.of(StatusCode.unavailable, 'not ready');
      final m = Migration(router.channel, zone, 1, to: 2);
      expect((await m.done).known, StatusCode.unavailable);
      expect(m.phases, ['draining', 'assigning', 'rolledBack']);
      await until(() => log.length == 3);
      expect(log, ['1 DRAIN 1 e2 to2', '2 ASSIGN 1 e2 h1', '1 RESUME 1 e1']);
      expect(
        h.service.slotTable(zone)![1],
        const SlotEntry.owned(1, holder: 1, epoch: 1),
      );
    });

    test('DRAIN refused: RESUME, nothing assigned', () async {
      a.onDrain = (_) async =>
          throw SwitchboardException.of(StatusCode.aborted, 'busy');
      final m = Migration(router.channel, zone, 1, to: 2);
      expect((await m.done).known, StatusCode.unavailable);
      expect(m.phases, ['draining', 'rolledBack']);
      await until(() => log.length == 2);
      expect(log, ['1 DRAIN 1 e2 to2', '1 RESUME 1 e1']);
      expect(
        h.service.slotTable(zone)![1],
        const SlotEntry.owned(1, holder: 1, epoch: 1),
      );
    });

    test('the old owner going down mid-migration frees the slot', () async {
      a.onDrain = (_) => Completer<void>().future;
      final m = Migration(router.channel, zone, 1, to: 2);
      await until(() => log.isNotEmpty);
      await a.close();
      expect((await m.done).known, StatusCode.unavailable);
      expect(m.phases, ['draining', 'rolledBack']);
      final table = h.service.slotTable(zone)!;
      expect(table[1], const SlotEntry.free(holder: 1, epoch: 1));
      expect(table[2], const SlotEntry.free(holder: 1, epoch: 1));
      expect(log, ['1 DRAIN 1 e2 to2']);
    });

    test('the new owner going down mid-ASSIGN: RESUME to the old', () async {
      b.onAssign = (_) => Completer<AssignResponse>().future;
      final m = Migration(router.channel, zone, 1, to: 2);
      await until(() => log.length == 2);
      await b.close();
      expect((await m.done).known, StatusCode.unavailable);
      await until(() => log.length == 3);
      expect(log, ['1 DRAIN 1 e2 to2', '2 ASSIGN 1 e2 h1', '1 RESUME 1 e1']);
      expect(
        h.service.slotTable(zone)![1],
        const SlotEntry.owned(1, holder: 1, epoch: 1),
      );
    });

    test('refusals', () async {
      Future<StatusCode?> migrate(Name type, int slot, int to) async =>
          (await Migration(router.channel, type, slot, to: to).done).known;
      expect(await migrate(Name('nope'), 1, 2), StatusCode.notFound);
      expect(await migrate(zone, 4, 2), StatusCode.notFound);
      expect(await migrate(zone, 1, 1), StatusCode.failedPrecondition);
      expect(await migrate(zone, 1, 99), StatusCode.failedPrecondition);
      expect(await migrate(zone, 3, 2), StatusCode.failedPrecondition);
      // Nobody with capacity to choose.
      expect(await migrate(zone, 1, 0), StatusCode.failedPrecondition);
      await expectLater(
        router.channel.request(
          'MIGRATE',
          MigrateRequest(zone, 1, to: 2).encode(),
        ),
        throwsStatus(StatusCode.invalidArgument),
      );
      // The allocator chooses among the instances with capacity.
      await b.slots(staticSpace(zone, 4), capacity: 1);
      expect(await migrate(zone, 1, 0), StatusCode.ok);
      expect(h.service.slotTable(zone)![1].owner, 2);
    });
  });

  group('restart recovery', () {
    test('claims made during the hold: higher epoch, then earlier', () async {
      final h = Harness(assignmentHold: const Duration(milliseconds: 100));
      addTearDown(h.close);
      final a = instance(zone, 1, harness: h);
      final b = instance(zone, 2, harness: h);
      final c = instance(zone, 3, harness: h);
      for (final i in [a, b, c]) {
        await i.start(space: staticSpace(zone, 8), capacity: 0);
      }
      final ha = a.holding([3, 4]);
      final ca = a.claim(3, holding: true, epoch: 5);
      final cb = b.claim(3, holding: true, epoch: 7);
      final cc = c.claim(3, epoch: 7);
      final cc5 = c.claim(5, epoch: 2);
      await Future<void>.delayed(ms50);
      expect(h.service.isHoldingAssignments, isTrue);
      expect(log, isEmpty);
      expect(await cb, 8);
      await expectLater(ca, throwsStatus(StatusCode.alreadyExists));
      await expectLater(cc, throwsStatus(StatusCode.alreadyExists));
      expect(await cc5, 3);
      // HOLDING is answered after the claims.
      expect(await ha, [3]);
      final table = h.service.slotTable(zone)!;
      expect(table[3], const SlotEntry.owned(2, holder: 2, epoch: 8));
      expect(table[4], const SlotEntry.free(holder: 1));
      expect(log, unorderedEquals(['2 ASSIGN 3 e8 h2', '3 ASSIGN 5 e3 h0']));
    });

    test('LOCATE of a free managed slot waits for the hold', () async {
      final h = Harness(assignmentHold: const Duration(milliseconds: 100));
      addTearDown(h.close);
      final a = instance(userq, 1, harness: h);
      await a.start(space: SlotSpace(userq, count: 8, lazy: true));
      final started = DateTime.now();
      expect(await a.locate(1), const LocateResponse(SlotState.owned, 1, 1));
      expect(
        DateTime.now().difference(started),
        greaterThan(const Duration(milliseconds: 50)),
      );
    });
  });

  group('ASSIGN backoff', () {
    SwitchboardException notReady() =>
        SwitchboardException.of(StatusCode.unavailable, 'not ready');

    /// Refuses the first [refusals] ASSIGNs, recording when each arrived
    /// (ms of fake time) in [at].
    Future<AssignResponse> Function(AssignRequest) refusing(
      FakeAsync async,
      List<int> at, {
      int refusals = 1 << 30,
    }) {
      var left = refusals;
      return (_) async {
        at.add(async.elapsed.inMilliseconds);
        if (left > 0) {
          left--;
          throw notReady();
        }
        return const AssignResponse();
      };
    }

    void closeWithoutTimers(FakeAsync async, Harness h) {
      unawaited(h.close());
      async.flushMicrotasks();
      // The scripted instances' own EXTEND timers notice on their next tick.
      async.elapse(ms50 * 2);
      expect(async.pendingTimers, isEmpty);
    }

    test('a refusing candidate is retried at the backoff intervals', () {
      fakeAsync((async) {
        final h = Harness();
        final log = <String>[];
        final at = <int>[];
        final a = Instance(h, kv, 1, log)
          ..onAssign = refusing(async, at, refusals: 3);
        unawaited(a.start(space: SlotSpace(kv, count: 1)));
        async.elapse(const Duration(seconds: 30));
        // 200 ms, then doubling: not a burst of retries.
        expect(at, [0, 200, 600, 1400]);
        expect(log, List.filled(4, '1 ASSIGN 0 e1 h0'));
        expect(
          h.service.slotTable(kv)![0],
          const SlotEntry.owned(1, holder: 1, epoch: 1),
        );
        closeWithoutTimers(async, h);
      });
    });

    test('the backoff grows to its maximum and resets on success', () {
      fakeAsync((async) {
        final h = Harness(
          assignBackoff: ms50,
          assignBackoffMax: const Duration(milliseconds: 120),
        );
        final log = <String>[];
        final at = <int>[];
        final a = Instance(h, kv, 1, log)
          ..onAssign = refusing(async, at, refusals: 4);
        unawaited(a.start(space: SlotSpace(kv, count: 1)));
        async.elapse(const Duration(seconds: 1));
        expect(at, [0, 50, 150, 270, 390]);
        // Freed again and refused again: from 50 ms again.
        at.clear();
        a.onAssign = refusing(async, at, refusals: 1);
        unawaited(a.release(0));
        async.elapse(const Duration(seconds: 1));
        expect(at, [1000, 1050]);
        expect(h.service.slotTable(kv)![0].owner, 1);
        closeWithoutTimers(async, h);
      });
    });

    test('another candidate takes the slot meanwhile', () {
      fakeAsync((async) {
        final h = Harness(assignmentHold: ms50);
        final log = <String>[];
        final at = <int>[];
        final a = Instance(h, kv, 1, log)..onAssign = refusing(async, at);
        final b = Instance(h, kv, 2, log);
        final space = SlotSpace(kv, count: 1);
        unawaited(a.start(space: space));
        unawaited(b.start(space: space));
        async.elapse(const Duration(seconds: 30));
        // a first (equal share, lower id); once it refuses, b at once.
        expect(log, ['1 ASSIGN 0 e1 h0', '2 ASSIGN 0 e1 h0']);
        expect(
          h.service.slotTable(kv)![0],
          const SlotEntry.owned(2, holder: 2, epoch: 1),
        );
        closeWithoutTimers(async, h);
      });
    });

    test('LOCATE waits for the backoffs, then fails with UNAVAILABLE', () {
      fakeAsync((async) {
        final h = Harness();
        final log = <String>[];
        final space = SlotSpace(userq, count: 16, lazy: true);
        final at = <String>[];
        for (final id in [1, 2]) {
          final i = Instance(h, userq, id, log)
            ..onAssign = (_) async {
              at.add('$id@${async.elapsed.inMilliseconds}');
              throw notReady();
            };
          unawaited(i.start(space: space));
        }
        async.elapse(ms10);
        final router = Instance(h, userq, 0, log)..channel = h.link().$1;
        final start = async.elapsed.inMilliseconds;
        Status? status;
        int? failedAt;
        router
            .locate(3)
            .then<void>(
              (_) => status = Status.ok,
              onError: (Object e) {
                status = (e as SwitchboardException).status;
                failedAt = async.elapsed.inMilliseconds - start;
              },
            );
        async.elapse(const Duration(seconds: 30));
        expect(status?.known, StatusCode.unavailable);
        expect(status?.reason, contains('not ready'));
        // Both tried, both again when their backoff ended, then the
        // handover timeout (300 ms) is over: no more ASSIGNs.
        expect(at, [
          '1@$start',
          '2@$start',
          '1@${start + 200}',
          '2@${start + 200}',
        ]);
        expect(failedAt, 300);
        expect(h.service.slotTable(userq)![3], SlotEntry.unassigned);
        closeWithoutTimers(async, h);
      });
    });

    test('a refused rebalancing migration waits for the backoff', () {
      fakeAsync((async) {
        final h = Harness(assignmentHold: ms50);
        final log = <String>[];
        final space = SlotSpace(kv, count: 4);
        unawaited(Instance(h, kv, 1, log).start(space: space));
        unawaited(Instance(h, kv, 2, log).start(space: space));
        async.elapse(ms50 * 2);
        final table = h.service.slotTable(kv)!;
        expect(counts(table), {1: 2, 2: 2});
        log.clear();
        final at = <int>[];
        final c = Instance(h, kv, 3, log)
          ..onAssign = refusing(async, at, refusals: 3);
        final joined = async.elapsed.inMilliseconds;
        unawaited(c.start(space: space));
        async.elapse(const Duration(seconds: 30));
        expect(at.map((t) => t - joined), [0, 200, 600, 1400]);
        expect(log, [
          for (var i = 0; i < 3; i++) ...[
            '1 DRAIN 0 e2 to3',
            '3 ASSIGN 0 e2 h1',
            '1 RESUME 0 e1',
          ],
          '1 DRAIN 0 e2 to3',
          '3 ASSIGN 0 e2 h1',
          '1 FORWARD 0 e2 to3',
        ]);
        expect(counts(table), {1: 1, 2: 2, 3: 1});
        closeWithoutTimers(async, h);
      });
    });

    test('close leaves no timers: backoffs, LOCATE, settle window', () {
      fakeAsync((async) {
        final h = Harness(
          handoverTimeout: const Duration(seconds: 10),
          holdingSettle: const Duration(seconds: 1),
        );
        final log = <String>[];
        final a = Instance(h, kv, 1, log)
          ..onAssign = (_) async => throw notReady();
        unawaited(a.start(space: SlotSpace(kv, count: 2)));
        final u = Instance(h, userq, 2, log)
          ..onAssign = (_) async => throw notReady();
        unawaited(u.start(space: SlotSpace(userq, count: 4, lazy: true)));
        // Through the settle window: both kv slots in their backoff.
        async.elapse(const Duration(milliseconds: 1100));
        expect(log, hasLength(2));
        Status? status;
        u
            .locate(1)
            .then(
              (_) => status = Status.ok,
              onError: (Object e) =>
                  status = (e as SwitchboardException).status,
            );
        async.elapse(ms10);
        // A new settle window.
        unawaited(a.slots(SlotSpace(kv, count: 2)));
        async.elapse(ms10);
        expect(status, isNull);
        closeWithoutTimers(async, h);
        expect(status?.known, StatusCode.goingAway);
      });
    });

    test('rejects invalid options', () {
      expect(
        () => NamingService(assignBackoff: Duration.zero),
        throwsArgumentError,
      );
      expect(
        () => NamingService(
          assignBackoff: const Duration(seconds: 2),
          assignBackoffMax: const Duration(seconds: 1),
        ),
        throwsArgumentError,
      );
      expect(
        () => NamingService(holdingSettle: const Duration(seconds: -1)),
        throwsArgumentError,
      );
      final service = NamingService(assignmentHold: Duration.zero);
      expect(service.assignBackoff, const Duration(milliseconds: 200));
      expect(service.assignBackoffMax, const Duration(seconds: 10));
      expect(service.holdingSettle, const Duration(seconds: 1));
      unawaited(service.close());
    });
  });

  group('settle window after SLOTS', () {
    test('a holder whose HOLDING comes late after the hold gets its slot', () {
      fakeAsync((async) {
        // A restarted naming service; its hold is over before anyone is
        // back.
        final h = Harness(
          assignmentHold: ms50,
          holdingSettle: const Duration(seconds: 1),
        );
        final log = <String>[];
        final space = SlotSpace(kv, count: 4);
        async.elapse(ms50 * 2);
        expect(h.service.isHoldingAssignments, isFalse);
        // b, which holds nothing, is back first with capacity.
        unawaited(Instance(h, kv, 2, log).start(space: space));
        async.elapse(ms10);
        // a holds the storage of slot 2; its HOLDING comes 300 ms after
        // its SLOTS.
        final a = Instance(h, kv, 1, log);
        unawaited(a.start(space: space));
        async.elapse(const Duration(milliseconds: 300));
        expect(log, isEmpty);
        final discard = a.holding([2]);
        async.elapse(ms10);
        expect(log, ['1 ASSIGN 2 e1 h1']);
        List<int>? discarded;
        discard.then((d) => discarded = d);
        async.flushMicrotasks();
        expect(discarded, isEmpty);
        // The rest once the window is over: 1 s after it opened (the most
        // it is extended to here, 5 x 50 ms being shorter).
        async.elapse(const Duration(milliseconds: 600));
        expect(log, hasLength(1));
        async.elapse(const Duration(milliseconds: 200));
        final table = h.service.slotTable(kv)!;
        expect(allOwned(table), isTrue);
        expect(table[2], const SlotEntry.owned(1, holder: 1, epoch: 1));
        expect(log.skip(1), everyElement(endsWith('e1 h0')));
        expect(counts(table), {1: 2, 2: 2});
        unawaited(h.close());
        async.flushMicrotasks();
        async.elapse(ms50 * 2);
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('arrivals extend the window until it goes quiet, up to a bound', () {
      fakeAsync((async) {
        // Quiet for 200 ms, at most 5 x 50 ms = 250 ms.
        final h = Harness(
          assignmentHold: ms50,
          holdingSettle: const Duration(milliseconds: 200),
        );
        final log = <String>[];
        async.elapse(ms50 * 2);
        final a = Instance(h, kv, 1, log);
        unawaited(a.start(space: SlotSpace(kv, count: 4)));
        async.elapse(const Duration(milliseconds: 150));
        expect(log, isEmpty);
        // A CLAIM is served at once and extends the window past 300 ms.
        int? epoch;
        a.claim(3).then((e) => epoch = e);
        async.elapse(ms10);
        expect(epoch, 1);
        expect(log, ['1 ASSIGN 3 e1 h0']);
        async.elapse(const Duration(milliseconds: 80));
        expect(log, hasLength(1));
        // 250 ms after it opened it is over all the same.
        async.elapse(const Duration(milliseconds: 20));
        expect(log, hasLength(4));
        expect(allOwned(h.service.slotTable(kv)), isTrue);
        unawaited(h.close());
        async.flushMicrotasks();
        async.elapse(ms50 * 2);
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('LOCATE assigns at once within the window', () {
      fakeAsync((async) {
        final h = Harness(holdingSettle: const Duration(seconds: 1));
        final log = <String>[];
        final space = SlotSpace(kv, count: 4);
        final a = Instance(h, kv, 1, log);
        unawaited(a.start(space: space, capacity: 1));
        unawaited(Instance(h, kv, 2, log).start(space: space, capacity: 3));
        async.elapse(ms10);
        unawaited(a.holding([1]));
        async.elapse(ms10);
        // A slot with a known holder goes back to it within the window.
        expect(log, ['1 ASSIGN 1 e1 h1']);
        final router = Instance(h, kv, 0, log)..channel = h.link().$1;
        LocateResponse? located;
        router.locate(0).then((r) => located = r);
        async.elapse(ms10);
        expect(located, const LocateResponse(SlotState.owned, 2, 1));
        expect(log, ['1 ASSIGN 1 e1 h1', '2 ASSIGN 0 e1 h0']);
        unawaited(h.close());
        async.flushMicrotasks();
        async.elapse(ms50 * 2);
        expect(async.pendingTimers, isEmpty);
      });
    });
  });

  test('close leaves no timers: grace, migration, held requests', () {
    fakeAsync((async) {
      final h = Harness(assignmentHold: ms50);
      final log = <String>[];
      final a = Instance(h, kv, 1, log);
      final b = Instance(h, kv, 2, log);
      final c = Instance(h, zone, 3, log);
      final space = SlotSpace(kv, count: 4);
      unawaited(a.start(space: space));
      unawaited(b.start(space: space));
      async.elapse(ms50 * 2);
      // A grace timer.
      unawaited(a.close());
      async.elapse(ms10);
      // A migration stuck in DRAIN.
      unawaited(c.start(space: staticSpace(zone, 2), capacity: 0));
      async.elapse(ms10);
      unawaited(c.claim(0));
      async.elapse(ms10);
      final d = Instance(h, zone, 4, log);
      unawaited(d.start(space: staticSpace(zone, 2), capacity: 0));
      async.elapse(ms10);
      c.onDrain = (_) => Completer<void>().future;
      final m = Migration(h.link().$1, zone, 0, to: 4);
      async.elapse(ms10);
      expect(log.last, '3 DRAIN 0 e2 to4');
      unawaited(h.close());
      // The scripted instances' own EXTEND timers notice on their next tick.
      async.elapse(ms50 * 2);
      Status? status;
      m.done.then((s) => status = s);
      async.flushMicrotasks();
      expect(status?.known, isNot(StatusCode.ok));
      expect(async.pendingTimers, isEmpty);
    });
  });
}
