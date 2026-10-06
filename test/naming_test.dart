import 'dart:async';
import 'dart:typed_data';

import 'package:async/async.dart';
import 'package:fake_async/fake_async.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:switchboard/src/address/service_address.dart';
import 'package:switchboard/src/name.dart';
import 'package:switchboard/src/naming/naming_client.dart';
import 'package:switchboard/src/naming/naming_protocol.dart';
import 'package:switchboard/src/status.dart';
import 'package:switchboard/src/talk/talk_channel.dart';
import 'package:switchboard/src/talk/talk_stream.dart';
import 'package:test/test.dart';

import 'naming_harness.dart';

void main() {
  group('NamingService', () {
    late Harness h;

    setUp(() => h = Harness());
    tearDown(() => h.close());

    test('assigns increasing ids across types, starting at 1', () async {
      final (c, _) = h.link();
      expect(await register(c, 'npc'), 1);
      expect(await register(c, 'api'), 2);
      expect(await register(c, 'npc'), 3);
      expect(h.service.table.keys.map((a) => '$a'), [
        'npc/1',
        'api/2',
        'npc/3',
      ]);
    });

    test('honours a requested id and skips it when assigning', () async {
      final (c, _) = h.link();
      expect(await register(c, 'npc', instance: 3), 3);
      expect(await register(c, 'npc'), 1);
      expect(await register(c, 'npc'), 2);
      expect(await register(c, 'npc'), 4);
      expect(await register(c, 'big', instance: maxInstance), maxInstance);
    });

    test('wraps at the u48 limit and skips ids in use', () async {
      final (c, _) = h.link();
      expect(await register(c, 'npc'), 1);
      h.service.nextInstance = maxInstance;
      expect(await register(c, 'npc'), maxInstance);
      expect(await register(c, 'npc'), 2);
    });

    test('a requested id in use is ALREADY_EXISTS', () async {
      final (a, _) = h.link();
      final (b, _) = h.link();
      expect(await register(a, 'npc', instance: 5), 5);
      // Another channel, same type.
      await expectLater(
        register(b, 'npc', instance: 5),
        throwsStatus(StatusCode.alreadyExists),
      );
      // Ids are unique across types, even on the owning channel.
      await expectLater(
        register(a, 'api', instance: 5),
        throwsStatus(StatusCode.alreadyExists),
      );
      expect(h.service.table.length, 1);
    });

    test('re-registering from the owner replaces the endpoints', () async {
      final (a, _) = h.link();
      final events = <String>[];
      final sub = h.service.events.listen((e) => events.add(describeEvent(e)));
      expect(await register(a, 'npc', endpoints: [uriA]), 1);
      expect(await register(a, 'npc', instance: 1, endpoints: [uriB]), 1);
      // Unchanged: no event.
      expect(await register(a, 'npc', instance: 1, endpoints: [uriB]), 1);
      await pump();
      expect(h.service.table.values.single.endpoints, [uriB]);
      expect(events, ['UP npc/1 $uriA', 'UP npc/1 $uriB']);
      await sub.cancel();
    });

    test('rejects invalid requests', () async {
      final (c, _) = h.link();
      await expectLater(
        register(c, ''),
        throwsStatus(StatusCode.invalidArgument),
      );
      await expectLater(
        c.request('REGISTER', bytes([0x6E, 0x70])),
        throwsStatus(StatusCode.invalidArgument),
      );
      await expectLater(
        c.request('UNREGSTR', Uint8List(3)),
        throwsStatus(StatusCode.invalidArgument),
      );
      // A name with a byte after its terminating zero.
      await expectLater(
        c.streamRequest('WATCH', bytes([0x61, 0, 0x62, 0, 0, 0, 0, 0])).done,
        throwsStatus(StatusCode.invalidArgument),
      );
      await expectLater(
        c.request('WATCH', Uint8List(0)),
        throwsStatus(StatusCode.invalidArgument),
      );
      await expectLater(
        c.request('LOOKUP', Name('npc').bytes),
        throwsStatus(StatusCode.invalidArgument),
      );
      await expectLater(
        c.request('FROB', Uint8List(0)),
        throwsStatus(StatusCode.unimplemented),
      );
      // Decodes, but re-encodes longer than 255 bytes: refused, and the
      // table stays encodable.
      final long = 'tcp://h/${'a b' * 80}';
      final raw = Uint8List.fromList([
        ...Name('npc').bytes,
        ...Uint8List(6),
        1,
        long.length,
        ...long.codeUnits,
      ]);
      await expectLater(
        c.request('REGISTER', raw),
        throwsStatus(StatusCode.invalidArgument),
      );
      expect(
        () => h.service.registerLocal(Name('npc'), [Uri.parse(long)]),
        throwsStatus(StatusCode.invalidArgument),
      );
      expect(h.service.table, isEmpty);
      // Plain messages are ignored, the channel stays usable.
      c.send('REGISTER', RegisterRequest(Name('npc')).encode());
      c.send('FROB', Uint8List(0));
      expect(await register(c, 'npc'), 1);
      expect(h.service.table.length, 1);
    });

    test('unregister: NOT_FOUND, PERMISSION_DENIED, then DOWN', () async {
      final (a, _) = h.link();
      final (b, _) = h.link();
      final watcher = Watcher(b);
      expect(await watcher.next, 'SYNCED');
      final id = await register(a, 'npc');
      expect(await watcher.next, 'UP npc/1');
      await expectLater(
        unregister(a, 'npc', 9),
        throwsStatus(StatusCode.notFound),
      );
      // Right id, wrong type.
      await expectLater(
        unregister(a, 'api', id),
        throwsStatus(StatusCode.notFound),
      );
      await expectLater(
        unregister(b, 'npc', id),
        throwsStatus(StatusCode.permissionDenied),
      );
      await unregister(a, 'npc', id);
      expect(await watcher.next, 'DOWN npc/1');
      expect(h.service.table, isEmpty);
      await expectLater(
        unregister(a, 'npc', id),
        throwsStatus(StatusCode.notFound),
      );
    });

    test('watch: snapshot, SYNCED, then live UP and DOWN', () async {
      final (a, _) = h.link();
      final (b, _) = h.link();
      await register(a, 'npc', endpoints: [uriA]);
      await register(a, 'api');
      final watcher = Watcher(b);
      expect(await watcher.take(3), ['UP npc/1 $uriA', 'UP api/2', 'SYNCED']);
      final id = await register(a, 'npc', endpoints: [uriB]);
      expect(await watcher.next, 'UP npc/3 $uriB');
      await register(a, 'npc', instance: id, endpoints: [uriA]);
      expect(await watcher.next, 'UP npc/3 $uriA');
      await unregister(a, 'api', 2);
      expect(await watcher.next, 'DOWN api/2');
      expect(h.service.watchCount, 1);
    });

    test(
      'a watch on the registering channel sees UP before the reply',
      () async {
        final (a, _) = h.link();
        final watcher = Watcher(a);
        expect(await watcher.next, 'SYNCED');
        final seen = <String>[];
        final registered = register(a, 'npc').then((_) => seen.add('reply'));
        seen.add(await watcher.next);
        await registered;
        expect(seen, ['UP npc/1', 'reply']);
      },
    );

    test('watch filtered by type', () async {
      final (a, _) = h.link();
      final (b, _) = h.link();
      await register(a, 'npc');
      await register(a, 'api');
      final watcher = Watcher(b, type: 'api');
      expect(await watcher.take(2), ['UP api/2', 'SYNCED']);
      await register(a, 'npc');
      await register(a, 'api');
      await unregister(a, 'npc', 1);
      await unregister(a, 'api', 2);
      expect(await watcher.take(2), ['UP api/4', 'DOWN api/2']);
      // An all-zero name watches everything.
      final all = Watcher(b, payload: Uint8List(8));
      expect(await all.take(3), ['UP npc/3', 'UP api/4', 'SYNCED']);
    });

    test('LOOKUP streams the records of a type, then ends', () async {
      final (a, _) = h.link();
      await register(a, 'npc', endpoints: [uriA, uriB]);
      await register(a, 'api');
      await register(a, 'npc');
      final lookup = a.streamRequest('LOOKUP', Name('npc').bytes);
      final items = await lookup.items.map(describe).toList();
      expect(items, ['UP npc/1 $uriA,$uriB', 'UP npc/3']);
      expect((await lookup.done).payload, isEmpty);
      final none = a.streamRequest('LOOKUP', Name('none').bytes);
      expect(await none.items.toList(), isEmpty);
      await expectLater(
        a.streamRequest('LOOKUP', Uint8List(0)).done,
        throwsStatus(StatusCode.invalidArgument),
      );
      expect(h.service.watchCount, 0);
    });

    test('cancelling a watch ends it with CANCELLED', () async {
      final (a, server) = h.link();
      final watcher = Watcher(a);
      expect(await watcher.next, 'SYNCED');
      expect(h.service.watchCount, 1);
      watcher.stream.cancel();
      await until(() => h.service.watchCount == 0);
      // The cancelled request id is released by the final CANCELLED.
      await until(() => a.outgoingRequestCount == 0);
      expect(server.incomingRequestCount, 0);
      expect(await register(a, 'npc'), 1);
    });

    test('channel close removes its records; watchers see DOWN', () async {
      final (a, _) = h.link();
      final (b, _) = h.link();
      final (c, _) = h.link();
      await register(a, 'npc');
      await register(b, 'api');
      await register(a, 'npc');
      final watcherA = Watcher(a);
      final watcherC = Watcher(c);
      expect(await watcherC.take(4), [
        'UP npc/1',
        'UP api/2',
        'UP npc/3',
        'SYNCED',
      ]);
      expect(await watcherA.take(4), hasLength(4));
      expect(h.service.watchCount, 2);
      await a.close();
      expect(await watcherC.take(2), ['DOWN npc/1', 'DOWN npc/3']);
      expect(h.service.table.keys.map((a) => '$a'), ['api/2']);
      await until(() => h.service.watchCount == 1);
      expect(h.service.channelCount, 2);
      // The server side closing has the same effect.
      await h.servers[1].close();
      expect(await watcherC.next, 'DOWN api/2');
      expect(h.service.table, isEmpty);
    });

    test('local registrations', () async {
      final (a, _) = h.link();
      final watcher = Watcher(a);
      expect(await watcher.next, 'SYNCED');
      expect(h.service.registerLocal(Services.naming, [uriA], instance: 1), 1);
      expect(await watcher.next, 'UP _ns/1 $uriA');
      expect(await register(a, 'npc'), 2);
      expect(await watcher.next, 'UP npc/2');
      await expectLater(
        register(a, '_ns', instance: 1),
        throwsStatus(StatusCode.alreadyExists),
      );
      await expectLater(
        unregister(a, '_ns', 1),
        throwsStatus(StatusCode.permissionDenied),
      );
      expect(
        () => h.service.unregisterLocal(ServiceAddress(Name('npc'), 2)),
        throwsStatus(StatusCode.permissionDenied),
      );
      expect(
        () => h.service.registerLocal(Name('x'), const [], instance: 2),
        throwsStatus(StatusCode.alreadyExists),
      );
      h.service.unregisterLocal(ServiceAddress(Services.naming, 1));
      expect(await watcher.next, 'DOWN _ns/1');
    });

    test('close aborts watches with GOING_AWAY and closes channels', () async {
      final (a, _) = h.link();
      await register(a, 'npc');
      final watcher = Watcher(a);
      expect(await watcher.take(2), ['UP npc/1', 'SYNCED']);
      final eventsDone = h.service.events.toList();
      await h.service.close();
      await expectLater(
        watcher.stream.done,
        throwsStatus(StatusCode.goingAway),
      );
      await a.done;
      expect(a.isOpen, isFalse);
      expect((await h.servers[0].done).known, StatusCode.goingAway);
      expect(h.service.watchCount, 0);
      expect(h.service.table, isEmpty);
      expect((await eventsDone).map(describeEvent), ['DOWN npc/1']);
      // Channels served after close are closed at once.
      final (b, bServer) = h.link();
      await b.done;
      expect(b.isOpen, isFalse);
      expect((await bServer.done).known, StatusCode.goingAway);
    });
  });

  group('heartbeat', () {
    test('keeps an idle watch alive well past every timeout', () {
      fakeAsync((async) {
        final h = Harness();
        final (a, _) = h.link();
        final items = <String>[];
        Object? error;
        final watch = a.streamRequest('WATCH', Uint8List(0));
        watch.items.listen(
          (m) => items.add(describe(m)),
          onError: (Object e) => error = e,
        );
        // 10 times the watcher's request timeout, 15 times the service's
        // reply timeout.
        async.elapse(clientOptions.requestTimeout * 10);
        expect(error, isNull);
        expect(items, ['SYNCED']);
        expect(h.service.watchCount, 1);
        // Still live.
        final (b, _) = h.link();
        unawaited(register(b, 'npc'));
        async.elapse(ms10);
        expect(items, ['SYNCED', 'UP npc/1']);
        async.elapse(clientOptions.requestTimeout * 10);
        expect(error, isNull);
        watch.cancel();
        async.elapse(ms10);
        expect(h.service.watchCount, 0);
        unawaited(h.close());
        async.flushMicrotasks();
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('a heartbeat slower than the reply timeout loses the watch', () {
      fakeAsync((async) {
        final h = Harness(heartbeat: const Duration(seconds: 1));
        final (a, _) = h.link();
        final watch = a.streamRequest('WATCH', Uint8List(0));
        Object? error;
        watch.items.listen((_) {}, onError: (Object e) => error = e);
        async.elapse(clientOptions.requestTimeout * 2);
        expect(error, isStatus(StatusCode.deadlineExceeded));
        expect(h.service.watchCount, 0);
        unawaited(h.close());
        async.flushMicrotasks();
        expect(async.pendingTimers, isEmpty);
      });
    });
  });

  group('NamingClient', () {
    late Harness h;
    late Connector connector;
    final clients = <NamingClient>[];

    NamingClient newClient(Connector connector) {
      final client = NamingClient(
        connector.call,
        reconnectDelay: reconnectDelay,
        watchTimeout: clientOptions.requestTimeout,
      );
      clients.add(client);
      return client;
    }

    setUp(() {
      h = Harness();
      connector = Connector(h);
    });

    tearDown(() async {
      for (final client in clients) {
        await client.close();
      }
      clients.clear();
      await h.close();
    });

    test('registers, syncs and mirrors the table', () async {
      final raw = h.link().$1;
      await register(raw, 'api', endpoints: [uriB]);
      final client = newClient(connector);
      final events = <String>[];
      client.events.listen((e) => events.add(describeEvent(e)));
      final registered = client.register(Name('npc'), [uriA]);
      expect(client.isConnected, isFalse);
      await client.start();
      expect(client.isConnected, isTrue);
      expect(await registered.timeout(timeout), 2);
      await client.synced.timeout(timeout);
      expect(client.isSynced, isTrue);
      expect(client.table.keys.map((a) => '$a'), ['api/1', 'npc/2']);
      expect(client.table[ServiceAddress(Name('npc'), 2)]!.endpoints, [uriA]);
      await register(raw, 'api');
      await until(() => client.table.length == 3);
      await unregister(raw, 'api', 1);
      await until(() => client.table.length == 2);
      // Snapshot in table order.
      expect(events, [
        'UP api/1 $uriB',
        'UP npc/2 $uriA',
        'UP api/3',
        'DOWN api/1',
      ]);
    });

    test('register after sync is mirrored when it completes', () async {
      final client = newClient(connector);
      await client.start();
      await client.synced.timeout(timeout);
      final id = await client.register(Name('npc'), [uriA]);
      // The UP item precedes the response on the same channel.
      expect(client.table[ServiceAddress(Name('npc'), id)]?.endpoints, [uriA]);
      expect(await client.register(Name('npc'), [], instance: 7), 7);
      await expectLater(
        client.register(Name('api'), [], instance: 7),
        throwsStatus(StatusCode.alreadyExists),
      );
      await expectLater(
        client.register(Name(''), []),
        throwsStatus(StatusCode.invalidArgument),
      );
      expect(h.service.table.length, 2);
    });

    test('unregister', () async {
      final client = newClient(connector);
      await client.start();
      final id = await client.register(Name('npc'), [uriA]);
      await client.synced.timeout(timeout);
      await expectLater(
        client.unregister(Name('npc'), id + 1),
        throwsStatus(StatusCode.notFound),
      );
      await client.unregister(Name('npc'), id);
      expect(h.service.table, isEmpty);
      await until(() => client.table.isEmpty);
      // Not re-registered after a reconnect.
      await connector.servers.last.close();
      await until(() => connector.calls == 2 && client.isSynced);
      expect(h.service.table, isEmpty);
    });

    test('two clients see each other', () async {
      final a = newClient(connector);
      final b = newClient(connector);
      final idA = await a.start().then((_) => a.register(Name('npc'), [uriA]));
      final idB = await b.start().then((_) => b.register(Name('api'), [uriB]));
      await until(() => a.table.length == 2 && b.table.length == 2);
      expect(a.table.keys, unorderedEquals(b.table.keys));
      expect(a.table[ServiceAddress(Name('api'), idB)]!.endpoints, [uriB]);
      expect(b.table[ServiceAddress(Name('npc'), idA)]!.endpoints, [uriA]);
      final downs = <String>[];
      b.events.where((e) => !e.up).listen((e) => downs.add(describeEvent(e)));
      await a.close();
      await until(() => downs.isNotEmpty);
      expect(downs, ['DOWN npc/$idA']);
      expect(b.table.keys.map((a) => '$a'), ['api/$idB']);
    });

    test('reconnects, re-registers the same ids, resyncs with DOWN', () async {
      final client = newClient(connector);
      final other = newClient(Connector(h));
      await client.start();
      final id = await client.register(Name('npc'), [uriA]);
      await other.start();
      final otherId = await other.register(Name('api'), [uriB]);
      await until(() => client.table.length == 2);
      final firstSynced = client.synced;

      final events = <String>[];
      client.events.listen((e) => events.add(describeEvent(e)));
      connector.down = true;
      await connector.servers.last.close();
      await until(() => !client.isConnected);
      expect(client.isSynced, isFalse);
      // The stale table is kept.
      expect(client.table.length, 2);
      expect(identical(client.synced, firstSynced), isFalse);
      // Meanwhile the service lost our record and the other one went away.
      expect(h.service.table.keys.map((a) => '$a'), ['api/$otherId']);
      await other.close();
      expect(h.service.table, isEmpty);
      await until(() => connector.calls >= 3);

      connector.down = false;
      await client.synced.timeout(timeout);
      expect(client.isConnected, isTrue);
      expect(h.service.table.keys.map((a) => '$a'), ['npc/$id']);
      expect(client.table.keys.map((a) => '$a'), ['npc/$id']);
      expect(events, ['DOWN api/$otherId']);
    });

    test('a taken id is replaced by a new one on reconnect', () async {
      final client = newClient(connector);
      await client.start();
      final id = await client.register(Name('npc'), [uriA]);
      await client.synced.timeout(timeout);
      connector.down = true;
      await connector.servers.last.close();
      await until(() => h.service.table.isEmpty);
      final thief = h.link().$1;
      expect(await register(thief, 'api', instance: id), id);
      connector.down = false;
      await until(() => client.isSynced && client.table.length == 2);
      final mine = h.service.table.keys.singleWhere(
        (a) => a.type == Name('npc'),
      );
      expect(mine.instance, isNot(id));
      // The new id is the one remembered from now on.
      await client.unregister(Name('npc'), mine.instance);
      expect(h.service.table.keys.map((a) => '$a'), ['api/$id']);
    });

    test('register while disconnected completes after reconnect', () async {
      final client = newClient(connector);
      connector.down = true;
      unawaited(client.start());
      await until(() => connector.calls >= 2);
      final registered = client.register(Name('npc'), [uriA], instance: 4);
      var done = false;
      unawaited(registered.then((_) => done = true));
      await Future<void>.delayed(reconnectDelay * 3);
      expect(done, isFalse);
      expect(client.isConnected, isFalse);
      connector.down = false;
      expect(await registered.timeout(timeout), 4);
      expect(h.service.table.keys.map((a) => '$a'), ['npc/4']);
      await client.synced.timeout(timeout);
    });

    test('service close: GOING_AWAY, reconnect to a new service', () async {
      final client = newClient(connector);
      await client.start();
      final id = await client.register(Name('npc'), [uriA]);
      await client.synced.timeout(timeout);
      final calls = connector.calls;
      await h.service.close();
      await until(() => !client.isConnected);
      // Keeps trying against the closed service.
      await until(() => connector.calls >= calls + 2);
      expect(client.isSynced, isFalse);
      final old = h;
      h = Harness();
      connector.harness = h;
      await old.close();
      await client.synced.timeout(timeout);
      expect(h.service.table.keys.map((a) => '$a'), ['npc/$id']);
      expect(client.table.keys.map((a) => '$a'), ['npc/$id']);
    });

    test('a watch timeout is a loss of the service', () async {
      // The service never answers: no SYNCED, no heartbeat.
      final silent = <StreamChannelController<Uint8List>>[];
      var calls = 0;
      final client = NamingClient(
        () async {
          calls++;
          final link = StreamChannelController<Uint8List>();
          silent.add(link);
          link.local.stream.listen((_) {});
          return TalkChannel(link.foreign, options: clientOptions);
        },
        reconnectDelay: reconnectDelay,
        watchTimeout: ms50,
      );
      clients.add(client);
      await client.start();
      await until(() => calls >= 3);
      expect(client.isSynced, isFalse);
      await client.close();
      for (final link in silent) {
        await link.local.sink.close();
      }
    });

    test('connect errors are retried', () async {
      final client = newClient(connector);
      connector.down = true;
      var started = false;
      unawaited(client.start().then((_) => started = true));
      await until(() => connector.calls >= 3);
      expect(started, isFalse);
      connector.down = false;
      await client.synced.timeout(timeout);
      expect(started, isTrue);
    });

    test('close fails pending futures and stops', () async {
      final client = newClient(connector);
      connector.down = true;
      final started = client.start();
      final registered = client.register(Name('npc'), []);
      final synced = client.synced;
      await until(() => connector.calls >= 2);
      await client.close();
      await started;
      await expectLater(registered, throwsStatus(StatusCode.cancelled));
      await expectLater(synced, throwsStatus(StatusCode.cancelled));
      final calls = connector.calls;
      await Future<void>.delayed(reconnectDelay * 3);
      expect(connector.calls, calls);
      await expectLater(
        client.register(Name('npc'), []),
        throwsStatus(StatusCode.failedPrecondition),
      );
      expect(await client.events.toList(), isEmpty);
    });

    test('close leaves no timers, connected or reconnecting', () {
      fakeAsync((async) {
        final h = Harness();
        final connector = Connector(h);
        final client = NamingClient(
          connector.call,
          reconnectDelay: reconnectDelay,
          watchTimeout: clientOptions.requestTimeout,
        );
        unawaited(client.start());
        unawaited(client.register(Name('npc'), [uriA]));
        async.elapse(ms10);
        expect(client.isSynced, isTrue);
        async.elapse(const Duration(seconds: 1));
        expect(client.isSynced, isTrue);
        // Lose the service and close during the reconnect delay.
        connector.down = true;
        unawaited(connector.servers.last.close());
        async.elapse(reconnectDelay * 3);
        expect(client.isConnected, isFalse);
        unawaited(client.close());
        async.flushMicrotasks();
        expect(async.pendingTimers, isEmpty);

        // Connected.
        final second = NamingClient(
          Connector(h).call,
          reconnectDelay: reconnectDelay,
          watchTimeout: clientOptions.requestTimeout,
        );
        unawaited(second.start());
        async.elapse(ms10);
        expect(second.isSynced, isTrue);
        expect(h.service.watchCount, 1);
        unawaited(second.close());
        async.flushMicrotasks();
        expect(h.service.watchCount, 0);
        expect(async.pendingTimers, isEmpty);
        unawaited(h.close());
        async.flushMicrotasks();
        expect(async.pendingTimers, isEmpty);
      });
    });
  });
}

/// Unregisters over a raw Talk channel.
Future<void> unregister(TalkChannel channel, String type, int instance) =>
    channel.request(
      'UNREGSTR',
      UnregisterRequest(Name(type), instance).encode(),
    );

/// A raw `WATCH` whose items are read one by one, as strings.
class Watcher {
  Watcher(TalkChannel channel, {String? type, Uint8List? payload})
    : stream = channel.streamRequest(
        'WATCH',
        payload ?? WatchRequest(type == null ? null : Name(type)).encode(),
      ) {
    _queue = StreamQueue(stream.items.map(describe));
  }

  final TalkStream stream;
  late final StreamQueue<String> _queue;

  Future<String> get next => _queue.next.timeout(timeout);

  Future<List<String>> take(int count) => _queue.take(count).timeout(timeout);
}
