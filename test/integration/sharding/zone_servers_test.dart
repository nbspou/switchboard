/*
Polyverse Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Authors:
  Jan Boon <jan.boon@kaetemi.be>
  Claude Opus 5.5 <noreply@anthropic.com>
*/

// Use case 4 of the wiki page "Polyverse Switchboard Sharding": AI zone servers
// (`zone`, static with explicit MIGRATE, holder-only). An operator moves a
// zone to a fresh instance during play. The NPC state (a counter advanced
// by a timer) moves over a direct channel during DRAIN. Players attached
// through a frontend proxy keep their channels: a player attached before
// the move has its requests forwarded as message chains, a player that
// attaches while the zone is locked has its channel queued and piped to
// the new server. Run over TCP and WebSocket.

import 'dart:async';

import 'package:switchboard/switchboard.dart';
import 'package:test/test.dart';

import 'cluster.dart';

final zone = Name('zone');

/// One zone's NPC state on its server.
class Zone {
  Zone(this.counter);

  int counter;
  Timer? timer;
  final List<(int, Completer<void>)> waiting = [];
}

/// A zone server. [ticks] (shared by every server) records each counter
/// step as (server, zone, value).
class ZoneServer extends SlotLifecycle {
  ZoneServer(this.name, this.ticks);

  final String name;
  final List<(String, int, int)> ticks;
  final Map<int, Zone> zones = {};

  /// NPC state transferred by the previous server, until ASSIGN.
  final Map<int, int> arriving = {};

  /// When set, DRAIN waits for it (lets the test act while locked).
  Completer<void>? holdDrain;

  void _run(int slot, Zone z) {
    z.timer = Timer.periodic(const Duration(milliseconds: 5), (_) {
      z.counter++;
      ticks.add((name, slot, z.counter));
      for (final (after, waiter) in List.of(z.waiting)) {
        if (z.counter > after) {
          z.waiting.remove((after, waiter));
          waiter.complete();
        }
      }
    });
  }

  @override
  Future<AssignResult> load(
    int slot, {
    required int epoch,
    required int holder,
    required bool shared,
    SlotRequestContext? context,
  }) async {
    final int counter;
    if (holder == 0 || holder == gate.instance) {
      counter = 0;
    } else {
      // Moved here: the state arrived during DRAIN.
      final transferred = arriving.remove(slot);
      if (transferred == null) {
        throw SwitchboardException.of(StatusCode.unavailable, 'no state');
      }
      counter = transferred;
    }
    final z = zones[slot] = Zone(counter);
    _run(slot, z);
    return AssignResult.holding;
  }

  @override
  Future<void> drain(
    int slot, {
    required int epoch,
    required int to,
    SlotRequestContext? context,
  }) async {
    await holdDrain?.future;
    final z = zones[slot]!;
    z.timer?.cancel();
    // The transfer starts: how long it may take is known now.
    context?.extend(deadline: const Duration(seconds: 10));
    final talk = await gate.switchboard.openTalk(ServiceAddress(zone, to));
    try {
      await talk.request('XFER', bytes('$slot ${z.counter}'));
    } finally {
      await talk.close();
    }
  }

  @override
  Future<void> unload(int slot) async => zones.remove(slot)?.timer?.cancel();

  @override
  void serve(IncomingChannel channel, int slot) {
    // Players stay attached; their requests are gated one by one.
    gate.detach(channel);
    channel.talk().messages.listen(
      (m) => gate.serveRequest(m, slot, (m) => _next(m, slot)),
    );
  }

  /// `NEXT after`: the counter value following `after`, once reached.
  Future<void> _next(TalkMessage m, int slot) async {
    final after = int.parse(text(m.payload));
    final z = zones[slot]!;
    if (z.counter <= after) {
      final reached = Completer<void>();
      z.waiting.add((after, reached));
      await reached.future;
    }
    if (m.canReply) {
      unawaited(m.reply(bytes('$name ${after + 1}')));
    }
  }

  /// `XFER zone counter` from the previous server.
  void serveTransfer(IncomingChannel channel) {
    channel.talk().messages.listen((m) {
      final [slot, counter] = text(m.payload).split(' ');
      arriving[int.parse(slot)] = int.parse(counter);
      m.reply(bytes('ok'));
    });
  }
}

/// A player attached to a zone through the frontend: asks for every
/// counter value in turn; reattaches when told the zone moved.
class Player {
  Player(this.node, this.slot);

  final Switchboard node;
  final int slot;
  late TalkChannel talk;

  /// (server, value, channel number) of every answer.
  final List<(String, int, int)> seen = [];
  int channels = 0;
  final List<StatusCode?> reattached = [];
  bool _stop = false;
  late final Future<void> done;

  int get last => seen.isEmpty ? 0 : seen.last.$2;

  Future<void> attach() async {
    talk = await node.openTalkToSlot(zone, slot);
    channels++;
  }

  void start() {
    done = () async {
      while (!_stop) {
        try {
          final answer = await talk.request('NEXT', bytes('$last'));
          final [server, value] = text(answer.payload).split(' ');
          seen.add((server, int.parse(value), channels));
        } on Object catch (e) {
          if (_stop || !retryable(e)) {
            rethrow;
          }
          reattached.add((e as SwitchboardException).code);
          unawaited(talk.close());
          await attach();
        }
      }
      await talk.close();
    }();
  }

  Future<void> stop() {
    _stop = true;
    return done.timeout(limit);
  }
}

void main() {
  for (final scheme in ['tcp', 'ws']) {
    test('$scheme: a hot zone moves to a fresh server during play', () async {
      final cluster = Cluster(scheme);
      await cluster.start();
      final ticks = <(String, int, int)>[];
      Future<(MeshNode, ZoneServer)> startServer(String name, int id) async {
        final mesh = await cluster.member();
        final app = ZoneServer(name, ticks);
        await mesh
            .publishSharded(
              zone,
              app,
              count: 4,
              mode: SlotMode.static,
              instance: id,
              forwardGrace: const Duration(milliseconds: 150),
              noSlotHandler: app.serveTransfer,
            )
            .timeout(limit);
        return (mesh, app);
      }

      final (z1, app1) = await startServer('Z1', 0x31);
      for (var slot = 0; slot < 4; slot++) {
        await z1.claimSlot(zone, slot, holding: true);
      }
      final (z3, app3) = await startServer('Z3', 0x33);

      // The frontend proxies players to the zone's server.
      final frontend = await cluster.member();
      frontend.switchboard.catchAll = proxyHandler(frontend.switchboard);
      final endpoint = frontend.switchboard.listeningEndpoints.single;
      Future<Player> player() async {
        final node = await cluster.node(
          resolver: EndpointResolver(endpoint),
          listen: false,
        );
        return Player(node, 2);
      }

      final early = await player();
      await early.attach();
      early.start();
      await until(() => early.seen.length >= 5);

      // The operator moves zone 2; the old server holds it locked.
      app1.holdDrain = Completer<void>();
      final phases = frontend
          .migrateSlot(zone, 2, to: 0x33)
          .map((p) => p.phase.name)
          .toList();
      await until(() => z1.gates[zone]!.stateOf(2) == SlotGateState.locked);
      // A player attaching now is queued at the old server.
      final joiner = await player();
      await joiner.attach();
      final first = joiner.talk.request('NEXT', bytes('${early.last}'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(app3.zones, isEmpty);
      app1.holdDrain!.complete();
      expect(await phases.timeout(limit), [
        'draining',
        'assigning',
        'forwarding',
        'done',
      ]);
      final [server, value] = text((await first.timeout(limit)).payload)
          .split(' ');
      expect(server, 'Z3');
      joiner
        ..seen.add((server, int.parse(value), 1))
        ..start();

      // The early player's requests are forwarded during the grace period,
      // then it is told MOVED and reattaches straight to Z3.
      await until(() => early.reattached.isNotEmpty);
      await until(() => early.seen.last.$3 == 2 && joiner.seen.length >= 3);
      await early.stop();
      await joiner.stop();
      expect(early.reattached, [StatusCode.moved]);
      final values = [for (final (_, v, _) in early.seen) v];
      expect(values, [for (var v = 1; v <= values.length; v++) v]);
      final servers = [for (final (s, _, _) in early.seen) s];
      final moved = servers.indexOf('Z3');
      expect(moved, greaterThan(0));
      expect(servers.skip(moved).toSet(), {'Z3'});
      // The first channel was kept across the move.
      expect(early.seen.where((s) => s.$1 == 'Z3' && s.$3 == 1), isNotEmpty);
      expect(joiner.channels, 1);
      expect(joiner.reattached, isEmpty);
      expect(joiner.seen.every((s) => s.$1 == 'Z3'), isTrue);
      final joined = [for (final (_, v, _) in joiner.seen) v];
      expect(joined, [
        for (var i = 0; i < joined.length; i++) joined.first + i,
      ]);

      // The NPCs never skipped or repeated a step.
      final steps = [
        for (final (_, slot, value) in ticks)
          if (slot == 2) value,
      ];
      expect(steps, [for (var v = 1; v <= steps.length; v++) v]);
      final lastOnZ1 = ticks.lastWhere((t) => t.$1 == 'Z1' && t.$2 == 2).$3;
      final firstOnZ3 = ticks.firstWhere((t) => t.$1 == 'Z3' && t.$2 == 2).$3;
      expect(firstOnZ3, lastOnZ1 + 1);

      // Z3 holds the zone now; Z1 dropped it after the grace period.
      await until(() => !app1.zones.containsKey(2));
      expect(
        frontend.client.slotOwner(zone, 2),
        const SlotEntry.owned(0x33, holder: 0x33, epoch: 2),
      );
      expect(z1.gates[zone]!.servedSlots.keys, unorderedEquals([0, 1, 3]));
      expect(z3.gates[zone]!.servedSlots, {2: 2});
    });
  }
}
