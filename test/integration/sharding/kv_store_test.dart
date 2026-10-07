/*
Polyverse Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Authors:
  Jan Boon <jan.boon@kaetemi.be>
  Claude Opus 5.5 <noreply@anthropic.com>
*/

// Use case 1 of the wiki page "Polyverse Switchboard Sharding": a key-value store
// (`kv`, eager managed, holder-only). The wiki has N = 1024; 64 slots
// keep the test fast and exercise the same paths (every migration is the
// same hand-over, only more of them).
//
// Each instance keeps its slots in a "disk" that survives a reboot. A new
// owner fetches a slot from its holder over a channel without a shard
// slot (the gate's noSlotHandler). Clients open one channel per operation
// to the slot's owner and write, per key, a sequence number that must come
// back in order: no operation may be lost, applied twice or reordered
// while slots move. A node that leaves the mesh hands its slots over
// before it stops, so nothing it holds is lost.

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:switchboard/src/switchboard/memory_endpoints.dart';
import 'package:switchboard/switchboard.dart';
import 'package:test/test.dart';

import 'cluster.dart';

final kv = Name('kv');
const slots = 64;

/// Counters shared by every instance of the store.
class Stats {
  /// `load` calls by kind: `fresh`, `reclaim` (holder is this instance),
  /// `fetch` (from another holder).
  final Map<String, int> loads = {};

  /// Puts whose sequence number was already applied (a client retry after
  /// a lost answer); answered without applying.
  int replays = 0;

  /// Puts that skipped a sequence number: never expected.
  int gaps = 0;

  void count(String kind) =>
      loads.update(kind, (n) => n + 1, ifAbsent: () => 1);
}

/// One instance of the store. [disk] maps slot -> key -> the sequence
/// numbers applied to the key, in order.
class KvStore extends SlotLifecycle {
  KvStore(this.disk, this.stats);

  final Map<int, Map<String, List<int>>> disk;
  final Stats stats;

  @override
  Future<AssignResult> load(
    int slot, {
    required int epoch,
    required int holder,
    required bool shared,
    SlotRequestContext? context,
  }) async {
    if (holder == gate.instance && disk.containsKey(slot)) {
      stats.count('reclaim');
    } else if (holder == 0 || holder == gate.instance) {
      stats.count('fresh');
      disk[slot] = {};
    } else {
      stats.count('fetch');
      final talk = await gate.switchboard.openTalk(ServiceAddress(kv, holder));
      try {
        final answer = await talk.request('FETCH', bytes('$slot'));
        disk[slot] = {
          for (final MapEntry(:key, :value) in (jsonDecode(
            text(answer.payload),
          ) as Map<String, Object?>).entries)
            key: (value! as List<Object?>).cast<int>(),
        };
      } finally {
        await talk.close();
      }
    }
    return AssignResult.holding;
  }

  /// The slot stays here for the new owner to fetch; a short pause stands
  /// for flushing it, so that the lock is long enough for operations to
  /// queue behind it.
  @override
  Future<void> drain(
    int slot, {
    required int epoch,
    required int to,
    SlotRequestContext? context,
  }) => Future<void>.delayed(const Duration(milliseconds: 3));

  @override
  Future<void> unload(int slot) async {
    // Kept while this instance is still the holder (it released the slot
    // keeping its storage); dropped once the storage moved on.
    final entry = gate.client.slotTable(kv)?[slot];
    if (entry?.holder != gate.instance) {
      disk.remove(slot);
    }
  }

  @override
  void discard(List<int> slots) => slots.forEach(disk.remove);

  @override
  void serve(IncomingChannel channel, int slot) {
    channel.talk().messages.listen((m) {
      final [key, ...rest] = text(m.payload).split(' ');
      if (slotForText(key, slots) != slot) {
        m.replyAbort(Status.of(StatusCode.invalidArgument, 'wrong slot'));
        return;
      }
      final history = disk[slot]!.putIfAbsent(key, () => []);
      final last = history.isEmpty ? 0 : history.last;
      switch (m.procedureName) {
        case 'PUT':
          final seq = int.parse(rest.single);
          if (seq == last + 1) {
            history.add(seq);
          } else if (seq <= last) {
            stats.replays++;
          } else {
            stats.gaps++;
          }
          m.reply(bytes('$seq'));
        case 'GET':
          m.reply(bytes('$last'));
      }
    });
  }

  /// Serves `FETCH slot` to a new owner of a slot this instance holds.
  void serveTransfer(IncomingChannel channel) {
    channel.talk().messages.listen((m) {
      final slot = int.parse(text(m.payload));
      m.reply(bytes(jsonEncode(disk[slot] ?? const {})));
    });
  }
}

/// Starts a store instance with a stable id and the given [disk].
Future<(MeshNode, SlotGate)> startStore(
  Cluster cluster,
  int id,
  Map<int, Map<String, List<int>>> disk,
  Stats stats,
) async {
  final mesh = await cluster.member();
  final store = KvStore(disk, stats);
  final gate = await mesh
      .publishSharded(
        kv,
        store,
        count: slots,
        instance: id,
        holding: disk.keys,
        forwardGrace: const Duration(milliseconds: 200),
        noSlotHandler: store.serveTransfer,
      )
      .timeout(limit);
  return (mesh, gate);
}

/// A client issuing operations on its own keys, one channel per operation.
class Client {
  Client(this.node, this.keys, this.random);

  final Switchboard node;
  final List<String> keys;
  final Random random;
  final Map<String, int> written = {};
  int operations = 0;
  int retries = 0;
  bool _stop = false;
  late final Future<void> done;

  Future<String> call(String procedure, String key, [String? arg]) async {
    final slot = slotForText(key, slots);
    while (true) {
      try {
        final talk = await node.openTalkToSlot(kv, slot);
        try {
          final answer = await talk.request(
            procedure,
            bytes(arg == null ? key : '$key $arg'),
          );
          return text(answer.payload);
        } finally {
          unawaited(talk.close());
        }
      } on Object catch (e) {
        if (!retryable(e)) {
          rethrow;
        }
        retries++;
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }
  }

  void start() {
    done = () async {
      while (!_stop) {
        final key = keys[random.nextInt(keys.length)];
        final seq = (written[key] ?? 0) + 1;
        expect(await call('PUT', key, '$seq'), '$seq');
        written[key] = seq;
        expect(await call('GET', key), '$seq', reason: key);
        operations++;
      }
    }();
  }

  Future<void> stop() {
    _stop = true;
    return done.timeout(limit);
  }
}

void main() {
  // Every node is closed by its cluster's tear-down, which releases its ids.
  tearDownAll(() {
    expect(MemoryEndpoints.ids, isEmpty, reason: 'a memory listener leaked');
  });

  for (final scheme in ['tcp', 'mem']) {
    test('$scheme kv: slots move one at a time while clients write; a reboot '
        'gets its slots back without transfer', () async {
      final cluster = Cluster(scheme);
      await cluster.start();
      final stats = Stats();
      final disks = <int, Map<int, Map<String, List<int>>>>{
        0x11: {},
        0x12: {},
        0x13: {},
      };
      final clientMesh = await cluster.member(listen: false);
      final watch = MigrationWatch(clientMesh.client, kv);
      Map<int, int> shares() {
        final table = clientMesh.client.slotTable(kv);
        final counts = <int, int>{};
        for (final entry in table?.entries.values ?? const <SlotEntry>[]) {
          if (entry.state == SlotState.owned) {
            counts.update(entry.owner, (n) => n + 1, ifAbsent: () => 1);
          }
        }
        return counts;
      }

      // Two instances share the space.
      final (_, second) = await (
        startStore(cluster, 0x11, disks[0x11]!, stats),
        startStore(cluster, 0x12, disks[0x12]!, stats),
      ).wait;
      await until(
        () =>
            watch.idle &&
            shares()[0x11] == slots ~/ 2 &&
            shares()[0x12] == slots ~/ 2,
        'two instances with half the slots each',
      );

      // Clients keep writing and reading.
      final random = Random(7);
      final clients = [
        for (var c = 0; c < 3; c++)
          Client(clientMesh.switchboard, [
            for (var k = 0; k < 24; k++) 'c$c-k$k',
          ], random)..start(),
      ];
      await until(() => clients.every((c) => c.operations >= 5));

      // A third instance joins: slots migrate to it one at a time.
      final movesBefore = watch.moves.length;
      final third = await startStore(cluster, 0x13, disks[0x13]!, stats);
      await until(
        () => watch.idle && (shares()[0x13] ?? 0) >= slots ~/ 3,
        'the third instance has its share',
      );
      final moved = watch.moves.skip(movesBefore).toList();
      expect(moved, hasLength(greaterThanOrEqualTo(slots ~/ 3)));
      expect(moved.every((m) => m.$3 == 0x13), isTrue);
      expect(watch.maxConcurrent, 1, reason: 'one migration at a time');
      expect(third.$2.servedSlots, hasLength(shares()[0x13]));
      final opsAtJoin = [for (final c in clients) c.operations];
      await until(
        () => [
          for (var i = 0; i < clients.length; i++)
            clients[i].operations - opsAtJoin[i],
        ].every((n) => n >= 5),
      );

      // Old copies are dropped once the forwarding grace is over.
      await until(
        () => disks.values.fold(0, (n, d) => n + d.length) == slots,
        'one copy of every slot',
      );

      // While slots moved, no PUT reached an owner twice: MOVED means
      // nothing was processed, and a client only resends after MOVED.
      expect(stats.replays, 0, reason: 'no PUT applied twice');

      // The second instance reboots with its id and its disk.
      final held = disks[0x12]!.keys.toSet();
      expect(held, clientMesh.client.slotTable(kv)!.slotsOf(0x12).toSet());
      final before = Map.of(stats.loads);
      await cluster.crash(second.$1);
      await until(
        () => !clientMesh.client.slotOwners(kv).contains(0x12),
        'the slots of the crashed instance are free',
      );
      // Holder-only: they wait for their holder.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(clientMesh.client.slotOwners(kv), {0x11, 0x13});
      final (rebooted, _) = await startStore(
        cluster,
        0x12,
        disks[0x12]!,
        stats,
      );
      await until(
        () => shares()[0x12] == held.length,
        'the rebooted instance has its slots back',
      );
      expect(clientMesh.client.slotTable(kv)!.slotsOf(0x12).toSet(), held);
      // Served before the naming service published them.
      expect(rebooted.gates[kv]!.servedSlots.keys.toSet(), held);
      expect(stats.loads['reclaim'], (before['reclaim'] ?? 0) + held.length);
      expect(stats.loads['fetch'], before['fetch'], reason: 'no transfer');
      expect(stats.loads['fresh'], before['fresh']);

      // Operations go on; then everything written is there, once, in order.
      final opsAtReboot = [for (final c in clients) c.operations];
      await until(
        () => [
          for (var i = 0; i < clients.length; i++)
            clients[i].operations - opsAtReboot[i],
        ].every((n) => n >= 5),
      );
      for (final client in clients) {
        await client.stop();
      }
      final table = clientMesh.client.slotTable(kv)!;
      for (final client in clients) {
        for (final MapEntry(:key, value: last) in client.written.entries) {
          final slot = slotForText(key, slots);
          final owner = table[slot].owner;
          expect(disks[owner]![slot]![key], [
            for (var s = 1; s <= last; s++) s,
          ]);
        }
      }
      expect(stats.gaps, 0);
      // The crash may cut a PUT whose answer was on its way: the client
      // resends it, and the store answers without applying it again. At
      // most one per client.
      expect(stats.replays, lessThanOrEqualTo(clients.length));
    });

    test('$scheme kv: a node that leaves hands its slots over before it '
        'stops; no key is lost', () async {
      final cluster = Cluster(scheme);
      await cluster.start(holderGrace: const Duration(milliseconds: 300));
      final stats = Stats();
      final d11 = <int, Map<String, List<int>>>{};
      final d12 = <int, Map<String, List<int>>>{};
      final clientMesh = await cluster.member(listen: false);
      final table = clientMesh.client;
      await startStore(cluster, 0x11, d11, stats);
      final (leaving, gate) = await startStore(cluster, 0x12, d12, stats);
      await until(
        () =>
            table.slotTable(kv)?.slotsOf(0x11).length == slots ~/ 2 &&
            table.slotTable(kv)?.slotsOf(0x12).length == slots ~/ 2,
        'two instances with half the slots each',
      );
      // One key in every slot.
      final keys = <int, String>{};
      for (var i = 0; keys.length < slots; i++) {
        keys.putIfAbsent(slotForText('k$i', slots), () => 'k$i');
      }
      final client = Client(clientMesh.switchboard, const [], Random(1));
      for (final key in keys.values) {
        expect(await client.call('PUT', key, '1'), '1');
      }
      final held = gate.servedSlots.keys.toList()..sort();
      expect(held, hasLength(slots ~/ 2));
      final fetches = stats.loads['fetch'] ?? 0;

      final report = await leaving.leave();
      await leaving.switchboard.close();
      expect(report.handedOver, {kv: held});
      expect(report.released, isEmpty);
      expect(report.dropped, isEmpty);
      expect(report.isComplete, isTrue);
      // Taken over, fetched while the leaving node was still up.
      expect(stats.loads['fetch'], fetches + held.length);
      await until(
        () => table.slotTable(kv)?.slotsOf(0x11).length == slots,
        'every slot on the remaining instance',
      );
      for (final MapEntry(key: slot, value: key) in keys.entries) {
        expect(await client.call('GET', key), '1', reason: 'slot $slot');
        expect(d11[slot]![key], [1]);
      }
      expect(stats.replays, 0);
      expect(stats.gaps, 0);
    });
  }
}
