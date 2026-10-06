import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:switchboard/src/address/service_address.dart';
import 'package:switchboard/src/name.dart';
import 'package:switchboard/src/naming/naming_client.dart';
import 'package:switchboard/src/naming/naming_protocol.dart';
import 'package:switchboard/src/naming/naming_resolver.dart';
import 'package:switchboard/src/status.dart';
import 'package:switchboard/src/switchboard/resolver.dart';
import 'package:test/test.dart';

import 'naming_harness.dart';

void main() {
  late Harness h;
  late Connector connector;
  late NamingClient client;
  late NamingResolver resolver;

  setUp(() {
    h = Harness();
    connector = Connector(h);
    client = NamingClient(
      connector.call,
      reconnectDelay: reconnectDelay,
      watchTimeout: clientOptions.requestTimeout,
    );
    resolver = NamingResolver(client, resolveTimeout: ms50);
  });

  tearDown(() async {
    await resolver.close();
    await h.close();
  });

  test('is a Resolver', () {
    expect(resolver, isA<Resolver>());
  });

  test('resolves after sync', () async {
    final raw = h.link().$1;
    final npc = await register(raw, 'npc', endpoints: [uriA]);
    await register(raw, 'api');
    final own = client.register(Name('npc'), [uriB]);
    // Resolution started before the client even connects waits for sync.
    final patient = NamingResolver(client, resolveTimeout: timeout);
    final early = patient.resolve(Name('npc'));
    unawaited(client.start());
    final records = await early;
    expect(records.map((r) => r.address), [
      ServiceAddress(Name('npc'), npc),
      ServiceAddress(Name('npc'), await own),
    ]);
    expect(records.first.endpoints, [uriA]);
    expect(await resolver.resolve(Name('none')), isEmpty);
    await resolver.ready;
  });

  test('UNAVAILABLE if never synced within the resolve timeout', () async {
    connector.down = true;
    unawaited(client.start());
    await expectLater(
      resolver.resolve(Name('npc')),
      throwsStatus(StatusCode.unavailable),
    );
    // Recovers once the service is reachable.
    connector.down = false;
    await resolver.ready.timeout(timeout);
    expect(await resolver.resolve(Name('npc')), isEmpty);
  });

  test('serves the stale table while resyncing after a loss', () async {
    await client.start();
    await client.register(Name('npc'), [uriA]);
    expect(await resolver.resolve(Name('npc')), hasLength(1));
    connector.down = true;
    await connector.servers.last.close();
    await until(() => !client.isSynced);
    // Synced once before: the mirrored table keeps answering, unblocked.
    expect(await resolver.resolve(Name('npc')), hasLength(1));
    connector.down = false;
    await resolver.ready.timeout(timeout);
    expect(await resolver.resolve(Name('npc')), hasLength(1));
  });

  test('events pass through', () async {
    final events = <String>[];
    resolver.events.listen((e) => events.add(describeEvent(e)));
    await client.start();
    await resolver.ready;
    final raw = h.link().$1;
    final id = await register(raw, 'api', endpoints: [uriB]);
    await raw.close();
    await until(() => events.length == 2);
    expect(events, ['UP api/$id $uriB', 'DOWN api/$id']);
  });

  test('close closes the client and fails later resolves', () async {
    await client.start();
    await resolver.ready;
    final eventsDone = resolver.events.toList();
    await resolver.close();
    expect(client.isClosed, isTrue);
    expect(client.isConnected, isFalse);
    expect(await eventsDone, isEmpty);
    await expectLater(
      resolver.resolve(Name('npc')),
      throwsStatus(StatusCode.failedPrecondition),
    );
    await until(() => h.service.channelCount == 0);
  });

  test('close stops reconnecting and leaves no timers', () {
    fakeAsync((async) {
      final h = Harness();
      final connector = Connector(h)..down = true;
      final client = NamingClient(connector.call, reconnectDelay: ms50);
      final resolver = NamingResolver(client, resolveTimeout: ms50);
      unawaited(client.start());
      Object? error;
      resolver.resolve(Name('npc')).catchError((Object e) {
        error = e;
        return <ServiceRecord>[];
      }).ignore();
      async.elapse(const Duration(milliseconds: 500));
      expect(error, isStatus(StatusCode.unavailable));
      final calls = connector.calls;
      expect(calls, greaterThan(5));
      unawaited(resolver.close());
      async.flushMicrotasks();
      expect(async.pendingTimers, isEmpty);
      async.elapse(const Duration(seconds: 1));
      expect(connector.calls, calls);
      unawaited(h.close());
      async.flushMicrotasks();
      expect(async.pendingTimers, isEmpty);
    });
  });
}
