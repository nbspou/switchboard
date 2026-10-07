// Use case 2 of the wiki page "Switchboard Sharding": Discord frontends
// (`discord`, static, stateless, N = the shard count from configuration).
// Each frontend claims the shards it is configured for; other services
// route a guild to its shard by `(guild_id >> 22) mod N` through the
// table. Run over TCP and WebSocket.

import 'package:switchboard/switchboard.dart';
import 'package:test/test.dart';

import 'cluster.dart';

final discord = Name('discord');

/// A Discord gateway frontend: holds the gateway connections of its shards
/// (nothing to load: the state is Discord's) and posts messages for the
/// guilds on them.
class Frontend extends SlotLifecycle {
  Frontend(this.name);

  final String name;
  final Set<int> shards = {};
  final List<String> posted = [];

  @override
  Future<AssignResult> load(
    int slot, {
    required int epoch,
    required int holder,
    required bool shared,
    SlotRequestContext? context,
  }) async {
    shards.add(slot);
    return AssignResult.notHolding;
  }

  @override
  Future<void> unload(int slot) async => shards.remove(slot);

  @override
  void serve(IncomingChannel channel, int slot) {
    channel.talk().messages.listen((m) {
      final [guild, message] = text(m.payload).split(' ');
      // A guild on another shard does not belong here.
      if ((int.parse(guild) >> 22) % gate.client.slotTable(discord)!.count !=
          slot) {
        m.replyAbort(Status.of(StatusCode.invalidArgument, 'wrong shard'));
        return;
      }
      posted.add('$guild $message');
      m.reply(bytes('$name shard $slot'));
    });
  }
}

/// Starts a frontend configured for [shards] of [count]; like the real
/// one, it refuses to start (leaves) when a shard is taken.
Future<(MeshNode, Frontend)> startFrontend(
  Cluster cluster,
  String name, {
  required int count,
  required List<int> shards,
}) async {
  final mesh = await cluster.member();
  final frontend = Frontend(name);
  await mesh
      .publishSharded(discord, frontend, count: count, mode: SlotMode.static)
      .timeout(limit);
  try {
    for (final shard in shards) {
      await mesh.claimSlot(discord, shard).timeout(limit);
    }
  } catch (_) {
    await mesh.leave();
    rethrow;
  }
  return (mesh, frontend);
}

/// Posts [message] in [guild] from a service that knows nothing of the
/// frontends but the table; returns who posted it. A transient
/// `UNAVAILABLE` (a pooled connection replaced under load, say) is retried
/// a few times, as a real caller would.
Future<String> post(MeshNode service, int guild, String message) async {
  final count = service.client.slotTable(discord)!.count;
  for (var attempt = 1; ; attempt++) {
    try {
      final talk = await service.switchboard.openTalkToSlot(
        discord,
        (guild >> 22) % count,
      );
      try {
        return text(
          (await talk.request('POST', bytes('$guild $message'))).payload,
        );
      } finally {
        await talk.close();
      }
    } on SwitchboardException catch (e) {
      if (e.code != StatusCode.unavailable || attempt >= 5) {
        rethrow;
      }
      await Future<void>.delayed(Duration(milliseconds: 20 * attempt));
    }
  }
}

/// Guild ids (snowflakes) and their shard of 4 and of 8.
const guilds = {
  81384788765712384: (2, 2),
  (1001 << 22) | 4242: (1, 1),
  (1006 << 22) | 99: (2, 6),
  (1003 << 22) | 7: (3, 3),
  (1004 << 22) | 1: (0, 4),
  (1013 << 22) | 31337: (1, 5),
};

void main() {
  for (final scheme in ['tcp', 'ws']) {
    group(scheme, () {
      late Cluster cluster;
      late MeshNode service;

      setUp(() async {
        cluster = Cluster(scheme);
        await cluster.start();
        service = await cluster.member(listen: false);
      });

      test('guilds reach the frontend of their shard', () async {
        for (final MapEntry(key: guild, value: (four, eight))
            in guilds.entries) {
          expect((guild >> 22) % 4, four);
          expect((guild >> 22) % 8, eight);
        }
        final (a, frontA) = await startFrontend(
          cluster,
          'A',
          count: 4,
          shards: [0, 1],
        );
        final (b, frontB) = await startFrontend(
          cluster,
          'B',
          count: 4,
          shards: [2, 3],
        );
        await until(() => service.slotOwners(discord).length == 2);
        expect(service.slotOwners(discord), {
          a.gates[discord]!.instance,
          b.gates[discord]!.instance,
        });
        for (final MapEntry(key: guild, value: (shard, _)) in guilds.entries) {
          expect(
            await post(service, guild, 'hello'),
            '${shard < 2 ? 'A' : 'B'} shard $shard',
          );
        }
        expect(frontA.posted, hasLength(3));
        expect(frontB.posted, hasLength(3));
        expect(frontA.shards, {0, 1});
        expect(frontB.shards, {2, 3});
      });

      test('a second frontend for a taken shard refuses to start', () async {
        final (a, _) = await startFrontend(
          cluster,
          'A',
          count: 4,
          shards: [0, 1, 2, 3],
        );
        await expectLater(
          startFrontend(cluster, 'C', count: 4, shards: [1]),
          throwsA(
            isA<SwitchboardException>().having(
              (e) => e.code,
              'code',
              StatusCode.alreadyExists,
            ),
          ),
        );
        await until(() => service.slotOwners(discord).isNotEmpty);
        expect(service.slotOwners(discord), {a.gates[discord]!.instance});
        expect(await post(service, 81384788765712384, 'still'), 'A shard 2');
      });

      test('a frontend with more shards than its naming channel takes '
          'requests leaves with every one released', () async {
        // 16 requests at a time on the naming channel, 40 shards.
        final mesh = await cluster.member(
          options: const TalkOptions(
            requestTimeout: Duration(seconds: 2),
            replyTimeout: Duration(seconds: 1),
            maxOutgoingRequests: 16,
          ),
        );
        final frontend = Frontend('A');
        await mesh
            .publishSharded(discord, frontend, count: 40, mode: SlotMode.static)
            .timeout(limit);
        final shards = List.generate(40, (i) => i);
        await Future.wait([
          for (final shard in shards) mesh.claimSlot(discord, shard),
        ]).timeout(limit);
        expect(frontend.shards, shards.toSet());
        final report = await mesh.leave().timeout(limit);
        expect(report.released, {discord: shards});
        expect(report.dropped, isEmpty);
        expect(report.handedOver, isEmpty);
        expect(frontend.shards, isEmpty);
        await until(
          () => cluster.naming.slotTable(discord)!.owners.isEmpty,
          'every shard free',
        );
        // Released, not lost: the epoch is kept (stateless: no holder).
        expect(
          cluster.naming.slotTable(discord)!.entries.values,
          List.filled(40, const SlotEntry.free(epoch: 1)),
        );
      });

      test('a frontend whose publish failed publishes again', () async {
        await startFrontend(cluster, 'A', count: 4, shards: [0]);
        final mesh = await cluster.member();
        final frontend = Frontend('B');
        await expectLater(
          mesh.publishSharded(
            discord,
            frontend,
            count: 8,
            mode: SlotMode.static,
          ),
          throwsA(
            isA<SwitchboardException>().having(
              (e) => e.code,
              'code',
              StatusCode.failedPrecondition,
            ),
          ),
        );
        // The same lifecycle, with the right configuration.
        final gate = await mesh
            .publishSharded(discord, frontend, count: 4, mode: SlotMode.static)
            .timeout(limit);
        expect(frontend.gate, same(gate));
        await mesh.claimSlot(discord, 1).timeout(limit);
        expect(await post(service, (1001 << 22) | 4242, 'again'), 'B shard 1');
        final report = await mesh.leave();
        expect(report.released, {
          discord: [1],
        });
        expect(report.handedOver, isEmpty);
      });

      test(
        'a full restart with another shard count redefines the space',
        () async {
          final first = [
            await startFrontend(cluster, 'A', count: 4, shards: [0, 1]),
            await startFrontend(cluster, 'B', count: 4, shards: [2, 3]),
          ];
          expect(await post(service, (1003 << 22) | 7, 'x'), 'B shard 3');
          // A frontend of the new configuration cannot join the old one.
          await expectLater(
            startFrontend(cluster, 'X', count: 8, shards: [0]),
            throwsA(
              isA<SwitchboardException>().having(
                (e) => e.code,
                'code',
                StatusCode.failedPrecondition,
              ),
            ),
          );
          for (final (mesh, _) in first) {
            await mesh.leave();
          }
          await until(() => service.slotOwners(discord).isEmpty);
          // Stateless: every slot is free with no holder, so N may change.
          final (c, frontC) = await startFrontend(
            cluster,
            'C',
            count: 8,
            shards: [0, 1, 2, 3],
          );
          final (_, frontD) = await startFrontend(
            cluster,
            'D',
            count: 8,
            shards: [4, 5, 6, 7],
          );
          await until(
            () =>
                service.client.slotTable(discord)?.count == 8 &&
                service.slotOwners(discord).length == 2,
          );
          expect(cluster.naming.slotTable(discord)!.count, 8);
          for (final MapEntry(key: guild, value: (_, shard))
              in guilds.entries) {
            expect(
              await post(service, guild, 'again'),
              '${shard < 4 ? 'C' : 'D'} shard $shard',
            );
          }
          expect(frontC.shards, {0, 1, 2, 3});
          expect(frontD.shards, {4, 5, 6, 7});
          expect(
            c.gates[discord]!.servedSlots.keys,
            unorderedEquals([0, 1, 2, 3]),
          );
        },
      );
    });
  }
}
