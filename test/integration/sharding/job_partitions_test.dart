// Use case 6 of the wiki page "Switchboard Sharding": queue partitions
// (`jobs`, static, shared recovery). Workers claim the partitions their
// configuration names; a standby worker configured for every partition
// claims whatever is free. The partition logs and consumer positions are
// in shared storage, so when a worker goes down the standby takes its
// partitions over and continues where it stopped.

import 'dart:async';

import 'package:switchboard/switchboard.dart';
import 'package:test/test.dart';

import 'cluster.dart';

final jobs = Name('jobs');
const partitions = 4;

/// Shared storage: the partition logs and the consumer positions.
class Storage {
  final Map<int, List<String>> logs = {
    for (var p = 0; p < partitions; p++) p: [],
  };
  final Map<int, int> positions = {for (var p = 0; p < partitions; p++) p: 0};

  /// Every job processed: (worker, partition, job).
  final List<(String, int, String)> processed = [];
}

/// A worker: consumes the partitions it owns from the shared position.
class Worker extends SlotLifecycle {
  Worker(this.name, this.storage);

  final String name;
  final Storage storage;
  final Map<int, Timer> consumers = {};

  /// Set when the process dies: it stops doing anything at once.
  bool dead = false;

  @override
  Future<AssignResult> load(
    int slot, {
    required int epoch,
    required int holder,
    required bool shared,
  }) async {
    expect(shared, isTrue);
    consumers[slot] = Timer.periodic(const Duration(milliseconds: 2), (_) {
      if (dead) {
        return;
      }
      // Processing a job and moving the position is one step.
      final log = storage.logs[slot]!;
      while (storage.positions[slot]! < log.length) {
        final job = log[storage.positions[slot]!];
        storage.processed.add((name, slot, job));
        storage.positions[slot] = storage.positions[slot]! + 1;
      }
    });
    return AssignResult.notHolding;
  }

  @override
  Future<void> unload(int slot) async => consumers.remove(slot)?.cancel();

  @override
  void serve(IncomingChannel channel, int slot) {
    channel.talk().messages.listen((m) {
      if (dead) {
        return;
      }
      final job = text(m.payload);
      final log = storage.logs[slot]!;
      // A producer retrying after a lost answer pushes the job again.
      if (!log.contains(job)) {
        log.add(job);
      }
      m.reply(bytes('ok'));
    });
  }
}

Future<(MeshNode, Worker)> startWorker(
  Cluster cluster,
  String name,
  Storage storage, {
  List<int> claim = const [],
  List<int> standby = const [],
}) async {
  final mesh = await cluster.member();
  final worker = Worker(name, storage);
  await mesh
      .publishSharded(
        jobs,
        worker,
        count: partitions,
        mode: SlotMode.static,
        shared: true,
      )
      .timeout(limit);
  for (final partition in claim) {
    await mesh.claimSlot(jobs, partition).timeout(limit);
  }
  if (standby.isNotEmpty) {
    // Claims every configured partition that is (or becomes) free.
    Future<void> take(int partition) async {
      try {
        await mesh.claimSlot(jobs, partition);
      } on SwitchboardException catch (e) {
        if (e.code != StatusCode.alreadyExists &&
            e.code != StatusCode.failedPrecondition) {
          rethrow;
        }
      }
    }

    final events = mesh.client.slotEvents.listen((event) {
      if (event.type == jobs &&
          standby.contains(event.slot) &&
          event.entry.isFree) {
        unawaited(take(event.slot));
      }
    });
    addTearDown(() => events.cancel());
    for (final partition in standby) {
      if (mesh.client.slotOwner(jobs, partition) == null) {
        unawaited(take(partition));
      }
    }
  }
  return (mesh, worker);
}

void main() {
  test('a standby worker takes over the partitions of a worker that went '
      'down, from the shared position', () async {
    final cluster = Cluster('tcp');
    await cluster.start();
    final storage = Storage();
    final (w1, worker1) = await startWorker(
      cluster,
      'W1',
      storage,
      claim: [0, 1],
    );
    await startWorker(cluster, 'W2', storage, claim: [2, 3]);
    final (standbyMesh, _) = await startWorker(
      cluster,
      'S',
      storage,
      standby: [0, 1, 2, 3],
    );
    expect(standbyMesh.gates[jobs]!.servedSlots, isEmpty);

    // A producer pushes jobs to their partitions.
    final producer = await cluster.member(listen: false);
    const total = 300;
    var pushed = 0;
    Future<void> push(String job) async {
      final partition = slotForText(job, partitions);
      while (true) {
        try {
          final talk = await producer.switchboard.openTalkToSlot(
            jobs,
            partition,
          );
          try {
            await talk.request('PUSH', bytes(job));
            return;
          } finally {
            unawaited(talk.close());
          }
        } on Object catch (e) {
          if (!retryable(e)) {
            rethrow;
          }
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      }
    }

    final producing = () async {
      for (var i = 0; i < total; i++) {
        await push('job$i');
        pushed++;
        if (i % 10 == 0) {
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
      }
    }();

    // W1 goes down mid-stream.
    await until(() => pushed >= total ~/ 3);
    worker1.dead = true;
    await cluster.crash(w1);
    await until(
      () => standbyMesh.gates[jobs]!.servedSlots.length == 2,
      'the standby took the partitions over',
    );
    expect(standbyMesh.gates[jobs]!.servedSlots.keys, unorderedEquals([0, 1]));
    await producing.timeout(limit);
    await until(() => storage.processed.length == total, 'every job processed');

    // Each job once, in partition order; W1's partitions continued by S.
    for (var p = 0; p < partitions; p++) {
      final done = [
        for (final (_, partition, job) in storage.processed)
          if (partition == p) job,
      ];
      expect(done, storage.logs[p]);
      expect(storage.positions[p], storage.logs[p]!.length);
      final workers = [
        for (final (worker, partition, _) in storage.processed)
          if (partition == p) worker,
      ];
      if (p < 2) {
        final takeover = workers.indexOf('S');
        expect(takeover, greaterThan(0), reason: 'partition $p');
        expect(workers.take(takeover).toSet(), {'W1'});
        expect(workers.skip(takeover).toSet(), {'S'});
      } else {
        expect(workers.toSet(), {'W2'});
      }
    }
    expect({
      for (final (_, _, job) in storage.processed) job,
    }, hasLength(total));
  });
}
