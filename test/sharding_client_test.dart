/*
Polyverse Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Authors:
  Jan Boon <jan.boon@kaetemi.be>
  Claude Opus 5.5 <noreply@anthropic.com>
*/

// The instance side of sharding in NamingClient: the slot handler, the
// remembered slot state and its restoration after a naming service
// restart, and the mirrored slot tables.

import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:switchboard/src/address/service_address.dart';
import 'package:switchboard/src/name.dart';
import 'package:switchboard/src/naming/naming_client.dart';
import 'package:switchboard/src/naming/naming_protocol.dart';
import 'package:switchboard/src/naming/naming_resolver.dart';
import 'package:switchboard/src/status.dart';
import 'package:switchboard/src/switchboard/incoming_channel.dart';
import 'package:switchboard/src/switchboard/slot_gate.dart';
import 'package:switchboard/src/switchboard/switchboard.dart';
import 'package:switchboard/src/talk/talk_channel.dart';
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
    final client = NamingClient(connect, reconnectDelay: reconnectDelay);
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

  test(
    'a slow ASSIGN that declares its estimate outlasts the timeouts',
    () async {
      final (a, handler) = await sharded('A', zone, 1);
      await a.defineSlots(zone, count: 4, mode: SlotMode.static, capacity: 0);
      // Longer than the service's handover timeout, the client's reply and
      // request timeouts.
      const slow = Duration(milliseconds: 700);
      expect(slow, greaterThan(serverOptions.replyTimeout * 3));
      handler.assign = (r) {
        handler.contexts['ASSIGN ${r.slot}']!.extend(
          deadline: const Duration(seconds: 2),
        );
        return Future.delayed(slow, () => AssignResult.holding);
      };
      final started = DateTime.now();
      expect(await a.claim(zone, 2), 1);
      expect(DateTime.now().difference(started), greaterThanOrEqualTo(slow));
      expect(h.service.slotTable(zone)![2].owner, 1);
    },
  );

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
    // A's HOLDING after the restart listed slot 1, held by B now.
    await until(() => handlerA.discarded.isNotEmpty);
    expect(handlerA.discarded, ['zone: 1']);
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
      holdingSettle: Harness.productionSettle,
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
      holdingSettle: Harness.productionSettle,
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
    final restarted = Harness(holdingSettle: Harness.productionSettle);
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

  test('with the service\'s settle window: declared storage first, fresh '
      'slots once quiet', () async {
    // The service's default window, as a fresh deployment has it.
    final h = Harness(holdingSettle: Harness.productionSettle);
    addTearDown(h.close);
    final (a, _) = await sharded('A', kv, 1, connect: Connector(h).call);
    final watch = Stopwatch()..start();
    // SLOTS and HOLDING back to back, as MeshNode.publishSharded sends them.
    final defined = a.defineSlots(kv, count: 4);
    final declared = a.declareHolding(kv, [2]);
    await defined;
    expect(await declared, isEmpty);
    await until(() => log.isNotEmpty);
    expect(log, ['A ASSIGN 2 e1 h1']);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(log, hasLength(1), reason: 'fresh slots wait for the window');
    await Future<void>.delayed(const Duration(milliseconds: 800));
    await until(() => log.length == 4);
    expect(watch.elapsed, greaterThanOrEqualTo(Harness.productionSettle));
    expect(log.skip(1), everyElement(endsWith('e1 h0')));
    expect(a.servedSlots(kv).keys.toSet(), {0, 1, 2, 3});
  });

  test('discards of a HOLDING sent again after a reconnect reach the '
      'handler', () async {
    final connect = Connector(h);
    final (a, handlerA) = await sharded('A', zone, 1, connect: connect.call);
    await a.defineSlots(zone, count: 4, mode: SlotMode.static, capacity: 0);
    expect(await a.declareHolding(zone, [2, 3]), isEmpty);
    expect(handlerA.discarded, isEmpty);
    // A goes away; meanwhile B takes slot 2 (fetching it from A) and is
    // its holder from then on.
    connect.down = true;
    await connect.servers.last.close();
    await until(() => !h.service.table.containsKey(ServiceAddress(zone, 1)));
    final b = Instance(h, zone, 2, log);
    await b.start(space: staticSpace(zone, 4), capacity: 0);
    await b.claim(2);
    expect(log, ['2 ASSIGN 2 e1 h1']);
    expect(h.service.slotTable(zone)![2].holder, 2);
    connect.down = false;
    await until(() => handlerA.discarded.isNotEmpty);
    expect(handlerA.discarded, ['zone: 2']);
    expect(h.service.slotTable(zone)![3], const SlotEntry.free(holder: 1));
  });

  test('close while a slot is locked resumes it', () async {
    final (a, handlerA) = await sharded('A', zone, 1);
    final (b, handlerB) = await sharded('B', zone, 2);
    for (final client in [a, b]) {
      await client.defineSlots(
        zone,
        count: 4,
        mode: SlotMode.static,
        capacity: 0,
      );
    }
    await a.claim(zone, 1);
    // B never confirms: the slot stays locked at A.
    handlerB.assign = (_) => Completer<AssignResult>().future;
    final router = newClient(Connector(h).call);
    await router.start();
    unawaited(router.migrate(zone, 1, to: 2).drain<void>().catchError((_) {}));
    await until(() => log.contains('B ASSIGN 1 e2 h1'));
    expect(handlerA.revoked, isEmpty);
    await a.close();
    await until(() => log.contains('A RESUME 1 e1'));
    expect(log, [
      'A ASSIGN 1 e1 h0',
      'A DRAIN 1 e2 to2',
      'B ASSIGN 1 e2 h1',
      'A RESUME 1 e1',
    ]);
  });

  test('a handler running longer than slotHandlerMaxDuration is answered '
      'DEADLINE_EXCEEDED', () {
    fakeAsync((async) {
      final h = Harness(handoverTimeout: const Duration(seconds: 5));
      final log = <String>[];
      NamingClient client(String name, int id, RecordingHandler handler) {
        final c = NamingClient(
          Connector(h).call,
          reconnectDelay: reconnectDelay,
          slotHandlerMaxDuration: const Duration(seconds: 1),
        )..slotHandler = handler;
        unawaited(c.start());
        unawaited(c.register(zone, [], instance: id));
        async.elapse(ms10);
        unawaited(
          c.defineSlots(zone, count: 4, mode: SlotMode.static, capacity: 0),
        );
        async.elapse(ms10);
        return c;
      }

      final handlerA = RecordingHandler('A', log);
      final handlerB = RecordingHandler('B', log);
      final a = client('A', 1, handlerA);
      final b = client('B', 2, handlerB);
      // An ASSIGN that never completes in time.
      final loading = Completer<AssignResult>();
      handlerA.assign = (_) => loading.future;
      Object? claimed;
      a
          .claim(zone, 1)
          .then<void>((e) => claimed = e, onError: (Object e) => claimed = e);
      async.elapse(const Duration(milliseconds: 990));
      expect(claimed, isNull);
      async.elapse(ms50);
      expect(claimed, isStatus(StatusCode.unavailable));
      expect(
        (claimed! as SwitchboardException).status.reason,
        contains('deadlineExceeded'),
      );
      // Its late outcome is not served.
      loading.complete(AssignResult.holding);
      async.elapse(ms10);
      expect(handlerA.revoked, ['zone/1']);
      expect(a.servedSlots(zone), isEmpty);
      // A DRAIN that never completes: the migration is rolled back.
      handlerA.assign = (_) async => AssignResult.holding;
      unawaited(a.claim(zone, 2));
      async.elapse(ms10);
      handlerA.drain = (_) => Completer<void>().future;
      log.clear();
      Object? migrated;
      // Listened to rather than drained: under fake time the cancel that
      // drain makes on an error completes outside the fake zone.
      b
          .migrate(zone, 2, to: 2)
          .listen(
            null,
            onError: (Object e) => migrated = e,
            onDone: () => migrated ??= 'done',
          );
      async.elapse(const Duration(milliseconds: 1100));
      expect(log, ['A DRAIN 2 e2 to2', 'A RESUME 2 e1']);
      expect(migrated, isStatus(StatusCode.unavailable));
      expect(h.service.slotTable(zone)![2].owner, 1);
      unawaited(a.close());
      unawaited(b.close());
      unawaited(h.close());
      async.flushMicrotasks();
      async.elapse(ms50 * 2);
      expect(async.pendingTimers, isEmpty);
    });
  });

  test('rejects a negative slotHandlerMaxDuration', () {
    expect(
      () => NamingClient(
        () async => throw StateError('unused'),
        slotHandlerMaxDuration: const Duration(seconds: -1),
      ),
      throwsArgumentError,
    );
  });

  test('close leaves no timers while a handler runs', () {
    fakeAsync((async) {
      final h = Harness();
      final log = <String>[];
      final client = NamingClient(
        Connector(h).call,
        reconnectDelay: reconnectDelay,
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

  test('a definition sent before the registration is sent again with it, '
      'with the capacity', () async {
    final client = newClient(Connector(h).call);
    client.slotHandler = RecordingHandler('A', log);
    await client.start();
    await client.synced.timeout(timeout);
    // Not registering kv yet: defines the space only.
    await client.defineSlots(kv, count: 2).timeout(timeout);
    expect(h.service.slotTable(kv)!.count, 2);
    expect(log, isEmpty);
    await client.register(kv, [], instance: 1).timeout(timeout);
    await until(() => client.servedSlots(kv).length == 2);
    expect(log, ['A ASSIGN 0 e1 h0', 'A ASSIGN 1 e1 h0']);
  });

  test('declareHolding of a type this client does not register is sent at '
      'once and refused', () async {
    final router = newClient(Connector(h).call);
    await router.start();
    await router.synced.timeout(timeout);
    await expectLater(
      router.declareHolding(room, [1]).timeout(timeout),
      throwsStatus(StatusCode.notFound),
    );
    await router.defineSlots(room, count: 4, mode: SlotMode.static);
    await expectLater(
      router.declareHolding(room, [1]).timeout(timeout),
      throwsStatus(StatusCode.failedPrecondition),
    );
    // Made while disconnected: sent after the connect.
    final later = newClient(Connector(h).call);
    final declared = later.declareHolding(room, [2]);
    await later.start();
    await expectLater(
      declared.timeout(timeout),
      throwsStatus(StatusCode.failedPrecondition),
    );
    expect(h.service.slotTable(room)!.entries, isEmpty);
  });

  group('the channel\'s request limit', () {
    void closeWithoutTimers(FakeAsync async, NamingClient client) {
      unawaited(client.close());
      async.flushMicrotasks();
      async.elapse(ms50 * 2);
      expect(async.pendingTimers, isEmpty);
    }

    test('a router\'s SLOTS refused for it is sent once it allows', () {
      fakeAsync((async) {
        // The WATCH holds the only request the channel takes.
        final naming = ScriptedNaming(maxOutgoingRequests: 1);
        final client = NamingClient(
          naming.connect,
          reconnectDelay: reconnectDelay,
        );
        unawaited(client.start());
        async.elapse(ms10);
        expect(naming.log, ['WATCH']);
        var defined = false;
        client
            .defineSlots(room, count: 4, mode: SlotMode.static, capacity: 0)
            .then((_) => defined = true);
        async.elapse(ms50);
        expect(naming.log, ['WATCH']);
        expect(defined, isFalse);
        naming.watch.complete();
        async.elapse(ms50);
        // Sent by itself, once, on the same channel.
        expect(naming.log, ['WATCH', 'SLOTS room']);
        expect(defined, isTrue);
        expect(client.isSynced, isTrue);
        expect(naming.connects, 1);
        closeWithoutTimers(async, client);
      });
    });

    test('the slot state is restored in order, what was refused sent '
        'later and only once', () {
      fakeAsync((async) {
        final naming = ScriptedNaming(maxOutgoingRequests: 2);
        final client = NamingClient(
          naming.connect,
          reconnectDelay: reconnectDelay,
        );
        client.slotHandler = RecordingHandler('A', log);
        unawaited(client.start());
        async.elapse(ms10);
        // Served before the registration, as after a naming service
        // restart.
        for (final slot in [0, 1, 2]) {
          naming.server
              .request('ASSIGN', AssignRequest(zone, slot, epoch: 4).encode())
              .ignore();
        }
        async.elapse(ms10);
        expect(client.servedSlots(zone), {0: 4, 1: 4, 2: 4});
        // With the WATCH in flight, one request at a time goes out.
        unawaited(client.register(zone, [], instance: 1));
        var defined = false;
        client
            .defineSlots(zone, count: 4, mode: SlotMode.static, capacity: 0)
            .then((_) => defined = true);
        List<int>? discard;
        client.declareHolding(zone, [3]).then((d) => discard = d);
        async.elapse(const Duration(milliseconds: 200));
        expect(naming.log, [
          'WATCH',
          'REGISTER zone/1',
          'SLOTS zone',
          'HOLDING zone 0,1,2,3',
          'CLAIM zone/0 e4',
          'CLAIM zone/1 e4',
          'CLAIM zone/2 e4',
        ]);
        expect(defined, isTrue);
        expect(discard, isEmpty);
        expect(client.servedSlots(zone), {0: 4, 1: 4, 2: 4});
        expect(log.where((l) => l.contains('REVOKE')), isEmpty);
        naming.watch.complete();
        async.elapse(ms10);
        expect(client.isSynced, isTrue);
        expect(naming.connects, 1);
        closeWithoutTimers(async, client);
      });
    });

    test('a WATCH refused for it waits instead of dropping the channel', () {
      fakeAsync((async) {
        final h = Harness();
        final connector = Connector(
          h,
          options: const TalkOptions(maxOutgoingRequests: 1),
        );
        final client = NamingClient(
          connector.call,
          reconnectDelay: reconnectDelay,
        );
        // Restored before the WATCH, which then finds the limit reached.
        var defined = false;
        client
            .defineSlots(room, count: 4, mode: SlotMode.static, capacity: 0)
            .then((_) => defined = true);
        unawaited(client.start());
        async.elapse(ms50);
        expect(defined, isTrue);
        expect(client.isSynced, isTrue);
        expect(client.slotTable(room)?.count, 4);
        expect(connector.calls, 1);
        closeWithoutTimers(async, client);
        unawaited(h.close());
        async.flushMicrotasks();
      });
    });

    test('claims, releases and locates beyond it wait for their turn', () {
      fakeAsync((async) {
        final h = Harness();
        final client = NamingClient(
          Connector(h, options: const TalkOptions(maxOutgoingRequests: 4)).call,
          reconnectDelay: reconnectDelay,
        );
        client.slotHandler = RecordingHandler('A', log);
        unawaited(client.start());
        unawaited(client.register(zone, [], instance: 1));
        async.elapse(ms10);
        unawaited(
          client.defineSlots(
            zone,
            count: 16,
            mode: SlotMode.static,
            capacity: 0,
          ),
        );
        async.elapse(ms10);
        List<int>? epochs;
        Future.wait([
          for (var slot = 0; slot < 16; slot++) client.claim(zone, slot),
        ]).then((e) => epochs = e);
        async.elapse(ms50);
        expect(epochs, List.filled(16, 1));
        expect(client.servedSlots(zone), hasLength(16));
        List<LocateResponse>? located;
        Future.wait([
          for (var slot = 0; slot < 16; slot++) client.locate(zone, slot),
        ]).then((l) => located = l);
        async.elapse(ms50);
        expect(
          located,
          List.filled(16, const LocateResponse(SlotState.owned, 1, 1)),
        );
        var released = false;
        Future.wait([
          for (var slot = 0; slot < 16; slot++)
            client.release(zone, slot, keepStorage: true),
        ]).then((_) => released = true);
        async.elapse(ms50);
        expect(released, isTrue);
        expect(h.service.slotTable(zone)!.owners, isEmpty);
        closeWithoutTimers(async, client);
        unawaited(h.close());
        async.flushMicrotasks();
      });
    });

    test('calls waiting for it fail with UNAVAILABLE when the channel is '
        'lost', () {
      fakeAsync((async) {
        final naming = ScriptedNaming(maxOutgoingRequests: 2)
          ..answerClaims = false;
        final client = NamingClient(
          naming.connect,
          reconnectDelay: const Duration(seconds: 10),
        );
        unawaited(client.start());
        async.elapse(ms10);
        // One in flight beside the WATCH, two waiting.
        final outcomes = <int, Object>{};
        for (final slot in [0, 1, 2]) {
          client
              .claim(zone, slot)
              .then<void>(
                (epoch) => outcomes[slot] = epoch,
                onError: (Object e) {
                  outcomes[slot] = e;
                },
              );
        }
        async.elapse(ms50);
        expect(naming.log, ['WATCH', 'CLAIM zone/0 e0']);
        expect(outcomes, isEmpty);
        unawaited(naming.server.close());
        async.elapse(ms10);
        // The one in flight with the channel's end, the others with
        // UNAVAILABLE, never sent.
        expect(outcomes, hasLength(3));
        expect(outcomes[0], isA<SwitchboardException>());
        expect(outcomes[1], isStatus(StatusCode.unavailable));
        expect(outcomes[2], isStatus(StatusCode.unavailable));
        expect(naming.log, hasLength(2));
        closeWithoutTimers(async, client);
      });
    });
  });

  group('declared deadlines, no heartbeat', () {
    const handover = Duration(seconds: 60);

    /// A client registered as `zone/[id]` over a connector that records
    /// the EXTENDs it sends to the naming service in [extends_]; its slot
    /// handler is [handler], or what [handlerFor] makes for it.
    NamingClient start(
      FakeAsync async,
      Harness h,
      int id,
      SlotHandler? handler,
      List<TalkFrame> extends_, {
      SlotHandler Function(NamingClient client)? handlerFor,
      Duration slotHandlerMaxDuration = const Duration(minutes: 10),
    }) {
      final connector = LossyConnector(h)
        ..dropToService = (frame) {
          if (frame.kind == TalkKind.extend) {
            extends_.add(frame);
          }
          return false;
        };
      final c = NamingClient(
        connector.call,
        reconnectDelay: reconnectDelay,
        slotHandlerMaxDuration: slotHandlerMaxDuration,
      );
      c.slotHandler = handler ?? handlerFor!(c);
      unawaited(c.start());
      unawaited(c.register(zone, [], instance: id));
      async.elapse(ms10);
      unawaited(
        c.defineSlots(zone, count: 4, mode: SlotMode.static, capacity: 0),
      );
      async.elapse(ms10);
      return c;
    }

    void finish(FakeAsync async, Harness h, List<NamingClient> clients) {
      for (final c in clients) {
        unawaited(c.close());
      }
      unawaited(h.close());
      async.flushMicrotasks();
      async.elapse(ms50 * 2);
      expect(async.pendingTimers, isEmpty);
    }

    test('a load that declares 5 min outlasts a 60 s handover timeout with '
        'one EXTEND', () {
      fakeAsync((async) {
        final h = Harness(handoverTimeout: handover);
        final loading = Completer<AssignResult>();
        SlotRequestContext? seen;
        final lifecycle = _Loader((slot, context) {
          seen = context;
          context!.extend(deadline: const Duration(minutes: 5));
          return loading.future;
        });
        final node = Switchboard();
        final extends_ = <TalkFrame>[];
        late final SlotGate gate;
        final c = start(
          async,
          h,
          1,
          null,
          extends_,
          handlerFor: (client) => gate = SlotGate(
            node,
            client,
            zone,
            lifecycle: lifecycle,
            instance: 1,
          ),
        );
        int? epoch;
        Object? error;
        c
            .claim(zone, 2)
            .then(
              (e) => epoch = e,
              onError: (Object e) {
                error = e;
              },
            );
        async.elapse(ms10);
        expect(seen, isNotNull);
        expect((seen!.type, seen!.slot, seen!.epoch), (zone, 2, 1));
        async.elapse(const Duration(minutes: 4));
        expect(error, isNull);
        expect(epoch, isNull);
        expect(seen!.isCancelled, isFalse);
        expect(gate.stateOf(2), SlotGateState.loading);
        loading.complete(AssignResult.holding);
        async.elapse(ms10);
        expect(epoch, 1);
        expect(gate.serves(2), isTrue);
        // Exactly one EXTEND, the estimate plus the client's buffer.
        expect(extends_.map((f) => f.extension), [
          (
            deadline: const Duration(minutes: 5) + clientOptions.extendBuffer,
            renew: null,
          ),
        ]);
        unawaited(gate.close());
        unawaited(node.close());
        finish(async, h, [c]);
      });
    });

    test('a load that declares nothing and runs past the handover timeout '
        'is cancelled, and sends nothing', () {
      fakeAsync((async) {
        final h = Harness(handoverTimeout: handover);
        final log = <String>[];
        final handler = RecordingHandler('A', log);
        final loading = Completer<AssignResult>();
        handler.assign = (_) => loading.future;
        final extends_ = <TalkFrame>[];
        final c = start(async, h, 1, handler, extends_);
        Object? error;
        c
            .claim(zone, 2)
            .then(
              (_) {},
              onError: (Object e) {
                error = e;
              },
            );
        async.elapse(ms10);
        final context = handler.contexts['ASSIGN 2']!;
        var cancelled = false;
        context.onCancel.then((_) => cancelled = true);
        async.elapse(handover - ms50);
        expect(error, isNull);
        expect(cancelled, isFalse);
        async.elapse(ms50 * 2);
        expect(cancelled, isTrue);
        expect(context.isCancelled, isTrue);
        expect(error, isStatus(StatusCode.unavailable));
        // Extending what can no longer be answered does nothing.
        context.extend(deadline: const Duration(minutes: 1));
        async.elapse(ms10);
        expect(extends_, isEmpty);
        loading.complete(AssignResult.holding);
        async.elapse(ms10);
        expect(handler.revoked, ['zone/2']);
        finish(async, h, [c]);
      });
    });

    test('the handler deadline is the instance\'s own: it gives up first, '
        'and the estimate is lowered to slotHandlerMaxDuration', () {
      fakeAsync((async) {
        final h = Harness(handoverTimeout: handover);
        final log = <String>[];
        final handler = RecordingHandler('A', log);
        handler.assign = (r) {
          handler.contexts['ASSIGN ${r.slot}']!.extend(
            deadline: const Duration(hours: 1),
          );
          return Completer<AssignResult>().future;
        };
        final extends_ = <TalkFrame>[];
        final c = start(
          async,
          h,
          1,
          handler,
          extends_,
          slotHandlerMaxDuration: const Duration(minutes: 2),
        );
        Object? error;
        c
            .claim(zone, 1)
            .then(
              (_) {},
              onError: (Object e) {
                error = e;
              },
            );
        async.elapse(ms10);
        expect(
          extends_.single.extension.deadline,
          const Duration(minutes: 2) + clientOptions.extendBuffer,
        );
        async.elapse(const Duration(minutes: 2) - ms50);
        expect(error, isNull);
        async.elapse(ms50 * 2);
        expect(error, isStatus(StatusCode.unavailable));
        expect(
          (error! as SwitchboardException).status.reason,
          contains('deadlineExceeded'),
        );
        finish(async, h, [c]);
      });
    });

    test('MIGRATE passes the deadline the old owner declares on DRAIN on to '
        'the requester', () {
      fakeAsync((async) {
        final h = Harness(handoverTimeout: handover);
        final log = <String>[];
        final handlerA = RecordingHandler('A', log);
        final handlerB = RecordingHandler('B', log);
        final draining = Completer<void>();
        handlerA.drain = (r) {
          handlerA.contexts['DRAIN ${r.slot}']!.extend(
            deadline: const Duration(minutes: 3),
          );
          return draining.future;
        };
        final extendsA = <TalkFrame>[];
        final a = start(async, h, 1, handlerA, extendsA);
        final b = start(async, h, 2, handlerB, []);
        unawaited(a.claim(zone, 2));
        async.elapse(ms10);
        // The operator, on a raw channel.
        final (operator, _) = h.link();
        final declared = <(Duration?, Duration?)>[];
        final phases = <String>[];
        final migrate = operator.streamRequest(
          'MIGRATE',
          MigrateRequest(zone, 2, to: 2).encode(),
          onExtend: (deadline, renew) => declared.add((deadline, renew)),
        );
        migrate.items.listen(
          (m) => phases.add(PhaseItem.decode(m.payload).phase.name),
        );
        Object? outcome;
        migrate.done.then(
          (_) => outcome = 'done',
          onError: (Object e) {
            outcome = e;
          },
        );
        async.elapse(ms10);
        final buffer = serverOptions.extendBuffer;
        expect(phases, ['draining']);
        expect(declared, [
          // The DRAIN was sent: the service's handover timeout.
          (handover + buffer, null),
          // The old owner's estimate, with its buffer and the service's.
          (
            const Duration(minutes: 3) + clientOptions.extendBuffer + buffer,
            null,
          ),
        ]);
        // Far past the operator's own request timeout, and the handover
        // timeout.
        async.elapse(const Duration(minutes: 2));
        expect(outcome, isNull);
        draining.complete();
        async.elapse(ms10);
        expect(outcome, 'done');
        expect(phases, ['draining', 'assigning', 'forwarding', 'done']);
        // Each later step declared the handover timeout.
        expect(declared.skip(2), [
          (handover + buffer, null),
          (handover + buffer, null),
        ]);
        expect(extendsA, hasLength(1));
        expect(h.service.slotTable(zone)![2].owner, 2);
        unawaited(operator.close());
        finish(async, h, [a, b]);
      });
    });
  });
}

/// A lifecycle whose load is [onLoad]; channels are refused.
class _Loader extends SlotLifecycle {
  _Loader(this.onLoad);

  final Future<AssignResult> Function(int slot, SlotRequestContext? context)
  onLoad;

  @override
  Future<AssignResult> load(
    int slot, {
    required int epoch,
    required int holder,
    required bool shared,
    SlotRequestContext? context,
  }) => onLoad(slot, context);

  @override
  void serve(IncomingChannel channel, int slot) =>
      unawaited(channel.reject(Status.of(StatusCode.unavailable)));
}
