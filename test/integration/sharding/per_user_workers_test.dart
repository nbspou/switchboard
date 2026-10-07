/*
Polyverse Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Authors:
  Jan Boon <jan.boon@kaetemi.be>
  Claude Opus 5.5 <noreply@anthropic.com>
*/

// Use case 3 of the wiki page "Polyverse Switchboard Sharding": per-user workers
// (`userq`, lazy managed, holder-only, N = 65536), with the layered
// deployment of the same page: a web frontend and a Discord frontend both
// route user actions by user id and land on the same worker.
//
// A user's slot is assigned when the user first shows up (LOCATE). Each
// user's job queue runs on the owner, one job at a time. When a second
// worker starts, busy users move over one at a time: a job in progress
// completes on the old worker, the next one is answered by the new worker,
// and the user's job count goes on without a gap.

import 'dart:async';

import 'package:switchboard/switchboard.dart';
import 'package:test/test.dart';

import 'cluster.dart';

final userq = Name('userq');
final web = Name('web');
final discord = Name('discord');
const slots = 65536;

int slotOf(String user) => slotForText('user:$user', slots);

/// The queue of one user on its worker.
class UserQueue {
  UserQueue(this.completed);

  /// Jobs completed so far: the state that moves with the user.
  int completed;
  Future<void> tail = Future<void>.value();
}

/// A worker instance. [log] is shared by every worker and frontend.
class Worker extends SlotLifecycle {
  Worker(this.name, this.log);

  final String name;
  final List<String> log;
  final Map<int, UserQueue> users = {};
  static const job = Duration(milliseconds: 25);
  static const slowJob = Duration(milliseconds: 300);

  /// Users whose next job is slow, and how many slow jobs have started.
  final Set<String> slowNext = {};
  int slowStarted = 0;

  @override
  Future<AssignResult> load(
    int slot, {
    required int epoch,
    required int holder,
    required bool shared,
    SlotRequestContext? context,
  }) async {
    var completed = 0;
    if (holder != 0 && holder != gate.instance) {
      final talk = await gate.switchboard.openTalk(
        ServiceAddress(userq, holder),
      );
      try {
        completed = int.parse(
          text((await talk.request('FETCH', bytes('$slot'))).payload),
        );
      } finally {
        await talk.close();
      }
    }
    users[slot] = UserQueue(completed);
    log.add('$name load $slot from $holder');
    return AssignResult.holding;
  }

  @override
  Future<void> unload(int slot) async {
    if (gate.client.slotTable(userq)?[slot].holder != gate.instance) {
      users.remove(slot);
    }
  }

  @override
  void serve(IncomingChannel channel, int slot) {
    channel.talk().messages.listen((m) {
      final [verb, user] = text(m.payload).split(' ');
      if (slotOf(user) != slot) {
        m.replyAbort(Status.of(StatusCode.invalidArgument, 'wrong slot'));
        return;
      }
      final queue = users[slot]!;
      switch (verb) {
        case 'WHO':
          m.reply(bytes(name));
        case 'JOB':
          final done = queue.tail.then((_) async {
            log.add('$name start $user ${queue.completed + 1}');
            final slow = slowNext.remove(user);
            if (slow) {
              slowStarted++;
            }
            await Future<void>.delayed(slow ? slowJob : job);
            queue.completed++;
            log.add('$name end $user ${queue.completed}');
            return queue.completed;
          });
          queue.tail = done;
          done.then((n) => m.reply(bytes('$name $n'))).ignore();
      }
    });
  }

  /// `FETCH slot` from a new owner: the user's job count.
  void serveTransfer(IncomingChannel channel) {
    channel.talk().messages.listen((m) {
      final slot = int.parse(text(m.payload));
      m.reply(bytes('${users[slot]?.completed ?? 0}'));
    });
  }
}

/// Records the naming service's requests to a worker before its gates
/// handle them.
class Recording extends SlotHandler {
  Recording(this.inner, this.name, this.log);

  final SlotHandler inner;
  final String name;
  final List<String> log;

  @override
  Future<AssignResult> onAssign(AssignRequest r, SlotRequestContext c) =>
      inner.onAssign(r, c);

  @override
  Future<void> onDrain(DrainRequest r, SlotRequestContext c) {
    log.add('$name DRAIN ${r.slot}');
    return inner.onDrain(r, c);
  }

  @override
  Future<void> onForward(ForwardRequest r, SlotRequestContext c) =>
      inner.onForward(r, c);

  @override
  Future<void> onResume(ResumeRequest r, SlotRequestContext c) =>
      inner.onResume(r, c);

  @override
  Future<void> onRevoke(Name type, int slot) => inner.onRevoke(type, slot);
}

Future<(MeshNode, Worker)> startWorker(
  Cluster cluster,
  String name,
  int id,
  List<String> log, {
  int capacity = 1,
}) async {
  final mesh = await cluster.member();
  final worker = Worker(name, log);
  await mesh
      .publishSharded(
        userq,
        worker,
        count: slots,
        lazy: true,
        capacity: capacity,
        instance: id,
        forwardGrace: const Duration(milliseconds: 300),
        noSlotHandler: worker.serveTransfer,
      )
      .timeout(limit);
  mesh.client.slotHandler = Recording(mesh.gates, name, log);
  return (mesh, worker);
}

/// Acts for users: routes their actions to their worker, by table on a
/// mesh node, or through the web frontend's proxy on a web client.
class Router {
  Router(this.node);

  final Switchboard node;

  Future<String> call(String verb, String user) async {
    while (true) {
      try {
        final talk = await node.openTalkToSlot(userq, slotOf(user));
        try {
          return text((await talk.request(verb, bytes('$verb $user'))).payload);
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
}

void main() {
  test('users move one at a time, each job in order; every frontend lands '
      'on the same worker', () async {
    final cluster = Cluster('tcp');
    await cluster.start();
    final log = <String>[];

    // The web frontend has no sharding ("connect anywhere"): web clients
    // reach it through its endpoint, and its proxy routes their channels
    // to the user's worker by the table. The Discord frontend is sharded
    // itself, by guild, statically, and routes for its users directly.
    final webMesh = await cluster.member();
    await webMesh.publish(web, (incoming) => incoming.reject(Status.ok));
    webMesh.switchboard.catchAll = proxyHandler(
      webMesh.switchboard,
      allow: (address) => address.type == userq,
    );
    final webClient = Router(
      await cluster.node(
        resolver: EndpointResolver(
          webMesh.switchboard.listeningEndpoints.single,
        ),
        listen: false,
      ),
    );
    final discordMesh = await cluster.member();
    await discordMesh.publishSharded(
      discord,
      _Shard(),
      count: 1,
      mode: SlotMode.static,
    );
    await discordMesh.claimSlot(discord, 0);
    final discordFrontend = Router(discordMesh.switchboard);

    final (_, worker1) = await startWorker(cluster, 'W1', 0x21, log);
    final users = [for (var i = 0; i < 8; i++) 'u$i'];
    expect({for (final u in users) slotOf(u)}, hasLength(users.length));
    final watch = MigrationWatch(webMesh.client, userq);
    final table = webMesh.client;
    expect(table.slotTable(userq)!.entries, isEmpty);

    // Users show up: their slots are assigned on first use.
    // Every user keeps two jobs submitted, so that its queue never runs
    // dry: the next job waits in the queue while one runs.
    final answers = <String, List<String>>{for (final u in users) u: []};
    var stop = false;
    final loops = [
      for (final user in users)
        for (var lane = 0; lane < 2; lane++)
          () async {
            while (!stop) {
              answers[user]!.add(await webClient.call('JOB', user));
            }
          }(),
    ];
    await until(() => answers.values.every((a) => a.length >= 2));
    expect(table.slotTable(userq)!.entries, hasLength(users.length));
    expect(table.slotOwners(userq), {0x21});

    // A second worker: half the users move over, one at a time.
    // It takes slots once every user is in the middle of a (slow) job, so
    // that the hand-overs find jobs running.
    final (w2, _) = await startWorker(cluster, 'W2', 0x22, log, capacity: 0);
    worker1.slowNext.addAll(users);
    await until(() => worker1.slowStarted == users.length);
    await w2.client.defineSlots(userq, count: slots, lazy: true);
    await until(
      () =>
          watch.idle &&
          table.slotTable(userq)!.slotsOf(0x22).length == users.length ~/ 2,
      'four users on the new worker',
    );
    expect(watch.maxConcurrent, 1);
    final moved = {for (final (slot, _, _) in watch.moves) slot};
    expect(moved, hasLength(users.length ~/ 2));
    final counts = {for (final u in users) u: answers[u]!.length};
    await until(() => users.every((u) => answers[u]!.length >= counts[u]! + 2));
    stop = true;
    await Future.wait(loops).timeout(limit);

    var midJob = 0;
    for (final user in users) {
      // Each job answered once, numbered in order without a gap.
      final seen = [
        for (final a in answers[user]!)
          (int.parse(a.split(' ')[1]), a.split(' ')[0]),
      ]..sort((a, b) => a.$1.compareTo(b.$1));
      expect(
        [for (final (n, _) in seen) n],
        [for (var n = 1; n <= seen.length; n++) n],
        reason: user,
      );
      final owners = [for (final (_, owner) in seen) owner];
      if (!moved.contains(slotOf(user))) {
        expect(owners.toSet(), {'W1'}, reason: user);
        continue;
      }
      // Jobs 1..last done by W1, every later one by W2.
      final last = owners.indexOf('W2');
      expect(last, greaterThan(0), reason: user);
      expect(owners.skip(last).toSet(), {'W2'}, reason: user);
      final drain = log.indexOf('W1 DRAIN ${slotOf(user)}');
      expect(drain, isNot(-1), reason: user);
      // The next job starts on W2 only after the last one on W1 ended.
      expect(
        log.indexOf('W2 start $user ${last + 1}'),
        greaterThan(log.indexOf('W1 end $user $last')),
        reason: user,
      );
      // Was a job running when the hand-over began?
      for (var n = 1; n <= last; n++) {
        if (log.indexOf('W1 start $user $n') < drain &&
            drain < log.indexOf('W1 end $user $n')) {
          midJob++;
        }
      }
    }
    // The hand-overs found the users mid-job.
    expect(midJob, greaterThan(0));

    // The layered deployment: both frontends reach the same worker.
    for (final user in users) {
      final owner = table.slotOwner(userq, slotOf(user))!.owner;
      final name = owner == 0x21 ? 'W1' : 'W2';
      expect(await webClient.call('WHO', user), name);
      expect(await discordFrontend.call('WHO', user), name);
    }
  });
}

/// The Discord frontend's own shard; it only routes here.
class _Shard extends SlotLifecycle {
  @override
  Future<AssignResult> load(
    int slot, {
    required int epoch,
    required int holder,
    required bool shared,
    SlotRequestContext? context,
  }) async => AssignResult.notHolding;

  @override
  void serve(IncomingChannel channel, int slot) =>
      unawaited(channel.reject(Status.ok));
}
