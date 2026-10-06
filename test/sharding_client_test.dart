// The instance side of sharding in NamingClient: the slot handler, the
// remembered slot state and its restoration after a naming service
// restart, and the mirrored slot tables.

import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:switchboard/src/name.dart';
import 'package:switchboard/src/naming/naming_client.dart';
import 'package:switchboard/src/naming/naming_protocol.dart';
import 'package:switchboard/src/naming/naming_resolver.dart';
import 'package:switchboard/src/status.dart';
import 'package:switchboard/src/talk/talk_frame.dart';
import 'package:test/test.dart';

import 'naming_harness.dart';
import 'sharding_harness.dart';

SlotSpace staticSpace(Name type, int count) =>
    SlotSpace(type, count: count, mode: SlotMode.static);

void main() {
  late Harness h;
  late List<String> log;
  final clients = <NamingClient>[];

  NamingClient newClient(TalkConnector connect) {
    final client = NamingClient(
      connect,
      reconnectDelay: reconnectDelay,
      watchTimeout: clientOptions.requestTimeout,
      slotExtendInterval: ms50,
    );
    clients.add(client);
    return client;
  }

  /// A started client registered as [type]/[id] with a recording handler.
  Future<(NamingClient, RecordingHandler)> sharded(
    String name,
    Name type,
    int id, {
    TalkConnector? connect,
  }) async {
    final client = newClient(connect ?? Connector(h).call);
    final handler = RecordingHandler(name, log);
    client.slotHandler = handler;
    await client.start();
    await client.register(type, [], instance: id);
    await client.synced.timeout(timeout);
    return (client, handler);
  }

  setUp(() {
    h = Harness();
    log = [];
  });

  tearDown(() async {
    for (final client in clients) {
      await client.close();
    }
    clients.clear();
    await h.close();
  });

  test('claim through ASSIGN; the mirror and the resolver follow', () async {
    final (a, _) = await sharded('A', zone, 1);
    final router = newClient(Connector(h).call);
    final resolver = NamingResolver(router);
    final events = <String>[];
    router.slotEvents.listen((e) => events.add('${e.slot}: ${e.entry}'));
    await router.start();
    await router.synced.timeout(timeout);
    expect(router.slotTables, isEmpty);
    expect(router.slotOwners(zone), isEmpty);
    await a.defineSlots(zone, count: 4, mode: SlotMode.static, capacity: 0);
    expect(await a.claim(zone, 1), 1);
    expect(log, ['A ASSIGN 1 e1 h0']);
    expect(a.servedSlots(zone), {1: 1});
    await until(() => router.slotOwner(zone, 1) != null);
    expect(router.slotTable(zone)!.space, staticSpace(zone, 4));
    expect(
      router.slotOwner(zone, 1),
      const SlotEntry.owned(1, holder: 1, epoch: 1),
    );
    expect(router.slotOwner(zone, 2), isNull);
    expect(router.slotOwner(Name('nope'), 1), isNull);
    expect(router.slotOwners(zone), {1});
    expect(resolver.slotOwner(zone, 1)?.owner, 1);
    expect(resolver.slotOwners(zone), {1});
    expect(resolver.slotTable(zone), same(router.slotTable(zone)));
    // The client's own mirror sees it too.
    expect(a.slotOwners(zone), {1});
    await a.release(zone, 1);
    await until(() => router.slotOwner(zone, 1) == null);
    expect(a.servedSlots(zone), isEmpty);
    expect(router.slotOwners(zone), isEmpty);
    expect(events, ['1: owned 1 holder 1 epoch 1', '1: free holder 0 epoch 1']);
  });

  test('migration seen from the instances, in protocol order', () async {
    final (a, _) = await sharded('A', zone, 1);
    final (b, _) = await sharded('B', zone, 2);
    final router = newClient(Connector(h).call);
    await router.start();
    await router.synced.timeout(timeout);
    await a.defineSlots(zone, count: 4, mode: SlotMode.static, capacity: 0);
    await b.defineSlots(zone, count: 4, mode: SlotMode.static, capacity: 0);
    await a.claim(zone, 1);
    await until(() => router.slotOwners(zone).isNotEmpty);
    log.clear();
    // The old owner learns of the new owner from its own mirror.
    a.slotEvents.listen((e) => log.add('A sees ${e.slot}: ${e.entry}'));
    final owners = <Set<int>>[];
    router.slotEvents.listen((_) => owners.add(router.slotOwners(zone)));
    final phases = await router
        .migrate(zone, 1, to: 2)
        .map((p) => p.phase.name)
        .toList()
        .timeout(timeout);
    expect(phases, ['draining', 'assigning', 'forwarding', 'done']);
    expect(log, [
      'A sees 1: migrating 1->2 holder 1 epoch 1',
      'A DRAIN 1 e2 to2',
      'B ASSIGN 1 e2 h1',
      'A sees 1: owned 2 holder 2 epoch 2',
      'A FORWARD 1 e2 to2',
    ]);
    expect(a.servedSlots(zone), isEmpty);
    expect(b.servedSlots(zone), {1: 2});
    await until(() => owners.length == 2);
    expect(owners, [
      {1},
      {2},
    ]);
    expect(router.slotOwners(zone), {2});
  });

  test('requests are answered from the handler, or refused', () async {
    final connector = Connector(h);
    final client = newClient(connector.call);
    await client.start();
    await client.synced.timeout(timeout);
    final server = connector.servers.last;
    Future<Uint8List> ask(String procedure, Uint8List payload) async =>
        (await server.request(procedure, payload)).payload;
    final assign = AssignRequest(zone, 1, epoch: 3).encode();
    await expectLater(
      ask('ASSIGN', assign),
      throwsStatus(StatusCode.unimplemented),
    );
    final handler = RecordingHandler('A', log);
    client.slotHandler = handler;
    expect(await ask('ASSIGN', assign), isEmpty);
    expect(client.servedSlots(zone), {1: 3});
    handler.assign = (_) async => AssignResult.notHolding;
    expect(await ask('ASSIGN', AssignRequest(zone, 2, epoch: 1).encode()), [1]);
    handler.assign = (_) async =>
        throw SwitchboardException.of(StatusCode.resourceExhausted, 'full');
    await expectLater(
      ask('ASSIGN', AssignRequest(zone, 3, epoch: 1).encode()),
      throwsStatus(StatusCode.resourceExhausted),
    );
    handler.assign = (_) async => throw StateError('broken');
    await expectLater(
      ask('ASSIGN', AssignRequest(zone, 3, epoch: 1).encode()),
      throwsStatus(StatusCode.unavailable),
    );
    expect(client.servedSlots(zone), {1: 3, 2: 1});
    await expectLater(
      ask('DRAIN', Uint8List(2)),
      throwsStatus(StatusCode.invalidArgument),
    );
    expect(
      await ask('DRAIN', DrainRequest(zone, 1, epoch: 4, to: 9).encode()),
      isEmpty,
    );
    expect(
      await ask('RESUME', ResumeRequest(zone, 1, epoch: 3).encode()),
      isEmpty,
    );
    expect(
      await ask('FORWARD', ForwardRequest(zone, 2, epoch: 2, to: 9).encode()),
      isEmpty,
    );
    expect(client.servedSlots(zone), {1: 3});
    await expectLater(
      ask('FROB', Uint8List(0)),
      throwsStatus(StatusCode.unimplemented),
    );
    expect(log, [
      'A ASSIGN 1 e3 h0',
      'A ASSIGN 2 e1 h0',
      'A ASSIGN 3 e1 h0',
      'A ASSIGN 3 e1 h0',
      'A DRAIN 1 e4 to9',
      'A RESUME 1 e3',
      'A FORWARD 2 e2 to9',
    ]);
  });

  test('a slow ASSIGN is kept alive with EXTEND', () async {
    final (a, handler) = await sharded('A', zone, 1);
    await a.defineSlots(zone, count: 4, mode: SlotMode.static, capacity: 0);
    // Longer than the service's handover timeout, the client's reply and
    // request timeouts.
    const slow = Duration(milliseconds: 700);
    expect(slow, greaterThan(serverOptions.replyTimeout * 3));
    handler.assign = (_) => Future.delayed(slow, () => AssignResult.holding);
    final started = DateTime.now();
    expect(await a.claim(zone, 2), 1);
    expect(DateTime.now().difference(started), greaterThanOrEqualTo(slow));
    expect(h.service.slotTable(zone)![2].owner, 1);
  });

  test('managed: capacity 1 by default, served slots tracked', () async {
    final (a, _) = await sharded('A', kv, 1);
    await a.defineSlots(kv, count: 4);
    await until(() => a.servedSlots(kv).length == 4);
    expect(log, [
      'A ASSIGN 0 e1 h0',
      'A ASSIGN 1 e1 h0',
      'A ASSIGN 2 e1 h0',
      'A ASSIGN 3 e1 h0',
    ]);
    // A conflicting definition is refused and forgotten.
    await expectLater(
      a.defineSlots(kv, count: 8),
      throwsStatus(StatusCode.failedPrecondition),
    );
    expect(await a.locate(kv, 2), const LocateResponse(SlotState.owned, 1, 1));
    await expectLater(a.locate(kv, 9), throwsStatus(StatusCode.notFound));
    await expectLater(
      a.claim(Name(''), 1),
      throwsStatus(StatusCode.invalidArgument),
    );
    expect(() => a.defineSlots(kv, count: 0), throwsRangeError);
  });

  test('defineSlots and declareHolding wait for the registration', () async {
    final client = newClient(Connector(h).call);
    final handler = RecordingHandler('A', log);
    client.slotHandler = handler;
    final defined = client.defineSlots(
      zone,
      count: 4,
      mode: SlotMode.static,
      capacity: 0,
    );
    final declared = client.declareHolding(zone, [2, 9]);
    final registered = client.register(zone, [], instance: 1);
    await client.start();
    expect(await registered.timeout(timeout), 1);
    await defined.timeout(timeout);
    expect(await declared.timeout(timeout), [9]);
    expect(h.service.slotTable(zone)![2], const SlotEntry.free(holder: 1));
    // Claimed with the storage it holds.
    expect(await client.claim(zone, 2, holding: true), 1);
    expect(log, ['A ASSIGN 2 e1 h1']);
  });

  test('a router without a registration defines a space', () async {
    final router = newClient(Connector(h).call);
    await router.start();
    await router.defineSlots(Name('discord'), count: 16, mode: SlotMode.static);
    expect(h.service.slotTable(Name('discord'))!.count, 16);
    await expectLater(
      router.claim(Name('discord'), 1),
      throwsStatus(StatusCode.failedPrecondition),
    );
  });

  test('naming service restart: resume, re-send, re-claim by epoch', () async {
    final connectA = SwitchableConnector(h);
    final connectB = SwitchableConnector(h);
    final (a, handlerA) = await sharded('A', zone, 1, connect: connectA.call);
    final (b, _) = await sharded('B', zone, 2, connect: connectB.call);
    final router = newClient(Connector(h).call);
    await router.start();
    for (final client in [a, b]) {
      await client.defineSlots(
        zone,
        count: 4,
        mode: SlotMode.static,
        capacity: 0,
      );
    }
    expect(await a.declareHolding(zone, [3]), isEmpty);
    await a.claim(zone, 1, holding: true);
    // The FORWARD to A never arrives: the naming service dies in between,
    // after B confirmed and the table says B.
    connectA.dropToClient = isRequestFor('FORWARD');
    unawaited(router.migrate(zone, 1, to: 2).drain<void>().catchError((_) {}));
    await until(() => h.service.slotTable(zone)![1].owner == 2);
    expect(log, ['A ASSIGN 1 e1 h1', 'A DRAIN 1 e2 to2', 'B ASSIGN 1 e2 h1']);
    expect(a.servedSlots(zone), {1: 1});
    expect(b.servedSlots(zone), {1: 2});
    log.clear();
    final restarted = Harness(
      assignmentHold: const Duration(milliseconds: 100),
    );
    addTearDown(restarted.close);
    connectA
      ..harness = restarted
      ..dropToClient = (_) => false;
    connectB.harness = restarted;
    await h.close();
    // A unlocks the slot it was draining and serves it again.
    await until(() => log.contains('A RESUME 1 e1'));
    // Both claim it back; B's later epoch wins, A must stop serving it.
    await until(() => handlerA.revoked.isNotEmpty);
    expect(handlerA.revoked, ['zone/1']);
    expect(log, ['A RESUME 1 e1', 'B ASSIGN 1 e3 h2', 'A REVOKE 1']);
    expect(a.servedSlots(zone), isEmpty);
    expect(b.servedSlots(zone), {1: 3});
    final table = restarted.service.slotTable(zone)!;
    expect(table.space, staticSpace(zone, 4));
    expect(table[1], const SlotEntry.owned(2, holder: 2, epoch: 3));
    // A's declared storage was restored after the claims.
    await until(() => table[3].holder == 1);
    expect(table[3], const SlotEntry.free(holder: 1));
  });

  test('re-claims served slots after a restart without conflict', () async {
    final connect = SwitchableConnector(h);
    final (a, _) = await sharded('A', kv, 1, connect: connect.call);
    await a.defineSlots(kv, count: 2);
    await until(() => a.servedSlots(kv).length == 2);
    log.clear();
    final restarted = Harness(
      assignmentHold: ms50,
      holdingSettle: const Duration(seconds: 1),
    );
    addTearDown(restarted.close);
    connect.harness = restarted;
    await h.close();
    await until(() => log.length == 2);
    // Claimed back with the holding flag and the last epoch: epoch 2.
    expect(log, ['A ASSIGN 0 e2 h1', 'A ASSIGN 1 e2 h1']);
    expect(a.servedSlots(kv), {0: 2, 1: 2});
    await until(() => a.isSynced && a.slotOwners(kv).length == 1);
    expect(a.slotOwner(kv, 0), const SlotEntry.owned(1, holder: 1, epoch: 2));
  });

  test('re-claims more served slots than the Talk request limit', () async {
    final connect = SwitchableConnector(h);
    final (a, _) = await sharded('A', kv, 1, connect: connect.call);
    await a.defineSlots(kv, count: 1100);
    await until(() => a.servedSlots(kv).length == 1100);
    log.clear();
    final restarted = Harness(
      assignmentHold: ms50,
      holdingSettle: const Duration(seconds: 1),
    );
    addTearDown(restarted.close);
    connect.harness = restarted;
    await h.close();
    await until(() => log.length == 1100);
    // Every slot comes back to its holder, none starts fresh: the claims
    // within the window keep their epoch (1, now 2); the others reach the
    // service after its hold and come back through HOLDING.
    final assigned = {
      for (final line in log)
        int.parse(line.split(' ')[2]): line.split(' ').skip(3).join(' '),
    };
    expect(assigned.keys.toSet(), {for (var s = 0; s < 1100; s++) s});
    expect(assigned.values.toSet(), {'e2 h1', 'e1 h1'});
    expect(
      assigned.values.where((v) => v == 'e2 h1').length,
      greaterThanOrEqualTo(256),
    );
    await until(() => a.servedSlots(kv).length == 1100);
    expect(restarted.service.slotTable(kv)!.slotsOf(1), hasLength(1100));
  });

  test('served slots come back to their holder after the hold', () async {
    final connect = SwitchableConnector(h);
    final (a, _) = await sharded('A', kv, 1, connect: connect.call);
    await a.defineSlots(kv, count: 8);
    await until(() => a.servedSlots(kv).length == 8);
    log.clear();
    // A restarted naming service whose hold is over (none at all) when the
    // instance is back: SLOTS gives it capacity before its HOLDING is
    // processed, and the settle window keeps the allocator from starting
    // those slots fresh (holder 0) meanwhile.
    final restarted = Harness(holdingSettle: const Duration(seconds: 1));
    addTearDown(restarted.close);
    connect.harness = restarted;
    await h.close();
    await until(() => log.length == 8);
    await pump();
    expect(log, [for (var s = 0; s < 8; s++) 'A ASSIGN $s e1 h1']);
    expect(restarted.service.slotTable(kv)!.slotsOf(1), hasLength(8));
  });

  test('HOLDING goes ahead of SLOTS when the mirror shows the space', () async {
    final sent = <String>[];
    final lossy = LossyConnector(h)
      ..dropToService = (frame) {
        final procedure = frame.procedure?.toString();
        if (frame.kind == TalkKind.message &&
            frame.requestId != 0 &&
            (procedure == 'SLOTS' || procedure == 'HOLDING')) {
          sent.add(procedure!);
        }
        return false;
      };
    final (b, _) = await sharded('B', kv, 2);
    await b.defineSlots(kv, count: 4, capacity: 0);
    final a = newClient(lossy.call);
    a.slotHandler = RecordingHandler('A', log);
    await a.start();
    await a.synced.timeout(timeout);
    await until(() => a.slotTable(kv) != null);
    // Defined and declared before the registration is back: sent
    // together once it is.
    final registered = a.register(kv, [], instance: 1);
    final defined = a.defineSlots(kv, count: 4);
    final discard = a.declareHolding(kv, [2]);
    await registered;
    await defined;
    expect(await discard, isEmpty);
    expect(sent, ['HOLDING', 'SLOTS']);
    await until(() => log.length == 4);
    expect(log, contains('A ASSIGN 2 e1 h1'));
    // Without the space in the mirror: SLOTS first (HOLDING would fail).
    sent.clear();
    final c = newClient(lossy.call);
    c.slotHandler = RecordingHandler('C', log);
    await c.start();
    await c.synced.timeout(timeout);
    final registeredC = c.register(zone, [], instance: 3);
    final definedC = c.defineSlots(zone, count: 4, capacity: 0);
    final discardC = c.declareHolding(zone, [1]);
    await registeredC;
    await definedC;
    expect(await discardC, isEmpty);
    expect(sent, ['SLOTS', 'HOLDING']);
  });

  test('close leaves no timers while a handler runs', () {
    fakeAsync((async) {
      final h = Harness();
      final log = <String>[];
      final client = NamingClient(
        Connector(h).call,
        reconnectDelay: reconnectDelay,
        watchTimeout: clientOptions.requestTimeout,
        slotExtendInterval: ms50,
      );
      final handler = RecordingHandler('A', log)
        ..assign = (_) => Completer<AssignResult>().future;
      client.slotHandler = handler;
      unawaited(client.start());
      unawaited(client.register(zone, [], instance: 1));
      async.elapse(ms10);
      unawaited(
        client.defineSlots(zone, count: 2, mode: SlotMode.static, capacity: 0),
      );
      async.elapse(ms10);
      client.claim(zone, 0).ignore();
      async.elapse(const Duration(seconds: 1));
      expect(log, ['A ASSIGN 0 e1 h0']);
      unawaited(client.close());
      unawaited(h.close());
      async.flushMicrotasks();
      async.elapse(ms50 * 2);
      expect(async.pendingTimers, isEmpty);
    });
  });
}
