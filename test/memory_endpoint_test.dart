/*
Polyverse Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Authors:
  Jan Boon <jan.boon@kaetemi.be>
  Claude Opus 5.5 <noreply@anthropic.com>
*/

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:switchboard/src/switchboard/memory_endpoints.dart';
import 'package:switchboard/switchboard.dart';
import 'package:test/test.dart';

/// Short grace so that closing a node with open channels is quick, and no
/// keep-alive timers.
const fast = MuxOptions(
  goAwayGrace: Duration(milliseconds: 100),
  keepAliveInterval: null,
);

Uint8List bytes(String text) => Uint8List.fromList(utf8.encode(text));

Matcher hasCode(StatusCode code) =>
    isA<Status>().having((s) => s.known, 'code', code);

Matcher throwsCode(StatusCode code) =>
    throwsA(isA<SwitchboardException>().having((e) => e.code, 'code', code));

final echo = Name('echo');

/// A node closed after the test.
Switchboard node({Resolver? resolver}) {
  final s = Switchboard(resolver: resolver, muxOptions: fast);
  addTearDown(s.close);
  return s;
}

/// Answers every request with `<instance>:<payload>`.
void serveEcho(IncomingChannel incoming) {
  incoming.talk().messages.listen(
    (m) => m.reply(
      bytes('${incoming.address.instance}:${utf8.decode(m.payload)}'),
    ),
  );
}

/// One request on a fresh Talk channel to [address] at [endpoint].
Future<String> ask(
  Switchboard from,
  Uri endpoint,
  ChannelAddress address,
  String payload,
) async {
  final talk = await from.openTalkAt(endpoint, address);
  try {
    return utf8.decode((await talk.request('ECHO', bytes(payload))).payload);
  } finally {
    await talk.close();
  }
}

void main() {
  // Every node of this file is closed by its test's tear-down, which
  // releases its ids.
  tearDownAll(() {
    expect(MemoryEndpoints.ids, isEmpty, reason: 'a memory listener leaked');
  });

  group('listenMemory', () {
    test('returns mem:// URIs, listed until close', () async {
      final server = Switchboard(muxOptions: fast);
      final generated = await server.listenMemory();
      final another = await server.listenMemory();
      final named = await server.listenMemory(name: 'Naming.Service_1');
      expect(generated.scheme, 'mem');
      expect(generated.host, isNotEmpty);
      expect(generated.hasPort, isFalse);
      expect(generated.path, isEmpty);
      expect(another.host, isNot(generated.host));
      // Names are compared, and carried, in lower case.
      expect(named.toString(), 'mem://naming.service_1');
      // Stable through the text form, as a naming service record needs.
      expect(Uri.parse(generated.toString()), generated);
      expect(server.listeningEndpoints, [generated, another, named]);
      expect(
        MemoryEndpoints.ids,
        unorderedEquals([generated.host, another.host, named.host]),
      );
      await server.close();
      expect(server.listeningEndpoints, isEmpty);
      expect(MemoryEndpoints.ids, isEmpty);
      await expectLater(
        server.listenMemory(),
        throwsCode(StatusCode.failedPrecondition),
      );
    });

    test('a name is taken until its node closes; invalid names', () async {
      final first = node();
      await first.listenMemory(name: 'shared');
      final second = node();
      await expectLater(
        second.listenMemory(name: 'SHARED'),
        throwsCode(StatusCode.alreadyExists),
      );
      for (final bad in ['', 'a b', 'a/b', 'a:1', 'a#b', 'é']) {
        await expectLater(
          second.listenMemory(name: bad),
          throwsArgumentError,
          reason: bad,
        );
      }
      expect(second.listeningEndpoints, isEmpty);
      await first.close();
      expect(
        await second.listenMemory(name: 'shared'),
        Uri.parse('mem://shared'),
      );
    });

    test('generated ids are unique', () async {
      final server = node();
      final ids = {for (var i = 0; i < 100; i++) (await server.listenMemory())};
      expect(ids, hasLength(100));
      expect(server.listeningEndpoints, hasLength(100));
    });
  });

  group('connecting', () {
    late Switchboard server;
    late Uri uri;
    late List<MuxConnection> accepted;
    late Switchboard client;

    setUp(() async {
      server = node();
      server.registerService(echo, serveEcho, instance: 3);
      uri = await server.listenMemory();
      accepted = [];
      final sub = server.connections.listen(accepted.add);
      addTearDown(sub.cancel);
      client = node();
    });

    test('talk request and reply through dispatch', () async {
      expect(
        await ask(client, uri, ChannelAddress(type: echo, instance: 3), 'hi'),
        '3:hi',
      );
      // Any instance goes to the registered one.
      expect(await ask(client, uri, ChannelAddress(type: echo), 'x'), '0:x');
      expect(accepted, hasLength(1));
      expect(accepted.single.isInitiator, isFalse);
      // Unclaimed types are not found, as over any listener.
      final missing = await client.openChannelAt(
        uri,
        ChannelAddress(type: Name('missing')),
      );
      expect(await missing.done, hasCode(StatusCode.notFound));
    });

    test('a request loop does not starve timers', () async {
      // Frames go through the event queue, as from a socket: with
      // microtask delivery this loop would run to its cap before the timer.
      var fired = false;
      Timer(const Duration(milliseconds: 20), () => fired = true);
      final talk = await client.openTalkAt(uri, ChannelAddress(type: echo));
      var requests = 0;
      while (!fired && requests < 20000) {
        await talk.request('ECHO', bytes('${requests++}'));
      }
      await talk.close();
      expect(fired, isTrue);
      expect(requests, inExclusiveRange(0, 20000));
    });

    test('the accepting side sees the initiator by its mem endpoint', () async {
      final remotes = <String?>[];
      server.registerService(Name('who'), (incoming) {
        remotes.add(incoming.remote);
        unawaited(incoming.channel.close());
      });
      final who = ChannelAddress(type: Name('who'));
      await (await client.openChannelAt(uri, who)).done;
      final named = node();
      await named.listenMemory(name: 'client-a');
      await (await named.openChannelAt(uri, who)).done;
      expect(remotes, ['memory peer', 'mem://client-a']);
    });

    test('the listener policy applies', () async {
      final guarded = await server.listenMemory(
        policy: ChannelPolicies.allowTypes({echo}),
      );
      final secret = Name('secret');
      server.registerService(secret, (incoming) {
        unawaited(incoming.channel.close());
      });
      final refused = await client.openChannelAt(
        guarded,
        ChannelAddress(type: secret),
      );
      final status = await refused.done;
      expect(status, hasCode(StatusCode.permissionDenied));
      expect(status.reason, 'permission denied');
      expect(
        await ask(client, guarded, ChannelAddress(type: echo), 'ok'),
        '0:ok',
      );
      // The listener without a policy reaches everything.
      final open = await client.openChannelAt(
        uri,
        ChannelAddress(type: secret),
      );
      expect(await open.done, Status.ok);
    });

    test('connections are pooled per id', () async {
      final both = await Future.wait([
        client.connect(uri),
        client.connect(uri),
      ]);
      expect(both[0], same(both[1]));
      expect(both[0].isInitiator, isTrue);
      // Case, fragment, port, path and query do not matter.
      for (final spelling in [
        Uri.parse('MEM://${uri.host.toUpperCase()}#echo/3'),
        uri.replace(port: 9, path: '/x', query: 'y'),
      ]) {
        expect(await client.connect(spelling), same(both[0]));
      }
      final a = await client.openChannelAt(uri, ChannelAddress(type: echo));
      final b = await client.openChannelAt(uri, ChannelAddress(type: echo));
      expect(a.connection, same(b.connection));
      expect(accepted, hasLength(1));
      // A closed connection is replaced.
      await accepted.single.close();
      expect(await both[0].done, hasCode(StatusCode.connectionLost));
      final again = await client.connect(uri);
      expect(again, isNot(same(both[0])));
      expect(await ask(client, uri, ChannelAddress(type: echo), 'z'), '0:z');
      expect(accepted, hasLength(2));
    });

    test('an unknown id is UNAVAILABLE, a missing one INVALID_ARGUMENT, and '
        'neither is cached', () async {
      final unknown = Uri.parse('mem://nobody-here');
      await expectLater(
        client.connect(unknown),
        throwsCode(StatusCode.unavailable),
      );
      await expectLater(
        client.openChannelAt(unknown, ChannelAddress(type: echo)),
        throwsCode(StatusCode.unavailable),
      );
      await expectLater(
        client.connect(Uri.parse('mem:')),
        throwsCode(StatusCode.invalidArgument),
      );
      // Someone starts listening there: the next attempt succeeds.
      final revived = node();
      revived.registerService(echo, serveEcho);
      await revived.listenMemory(name: 'nobody-here');
      expect(
        await ask(client, unknown, ChannelAddress(type: echo), 'l'),
        '0:l',
      );
    });

    test('close: GOAWAY on accepted connections, the id released at '
        'once', () async {
      final held = Completer<IncomingChannel>();
      server.registerService(Name('hold'), held.complete);
      final channel = await client.openChannelAt(
        uri,
        ChannelAddress(type: Name('hold')),
      );
      final atServer = await held.future;
      final connection = channel.connection;
      final closing = server.close();
      expect(MemoryEndpoints.lookup(uri.host), isNull);
      expect(server.listeningEndpoints, isEmpty);
      while (!connection.peerGoingAway) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      // The pooled connection is going away and nobody listens any more.
      await expectLater(
        client.connect(uri),
        throwsCode(StatusCode.unavailable),
      );
      // The held channel still works on the old connection.
      atServer.channel.send(bytes('still here'));
      expect(await channel.stream.first, bytes('still here'));
      await channel.close();
      await closing;
      expect(await connection.done, hasCode(StatusCode.goingAway));
      expect(await channel.done, Status.ok);
    });

    test('a client closing right after connecting sends GOAWAY', () async {
      final seen = <StatusCode?>[];
      for (var i = 0; i < 20; i++) {
        final arrived = server.connections.first;
        final quick = Switchboard(muxOptions: fast);
        await quick.connect(uri);
        await quick.close();
        seen.add((await (await arrived).done).known);
      }
      expect(seen, everyElement(StatusCode.goingAway));
    });

    test('isOwnEndpoint matches the id', () async {
      expect(server.isOwnEndpoint(uri), isTrue);
      expect(
        server.isOwnEndpoint(Uri.parse('MEM://${uri.host.toUpperCase()}:5/x')),
        isTrue,
      );
      expect(server.isOwnEndpoint(Uri.parse('mem://${uri.host}x')), isFalse);
      expect(server.isOwnEndpoint(Uri.parse('tcp://${uri.host}:1')), isFalse);
      expect(client.isOwnEndpoint(uri), isFalse);
    });
  });

  group('proxy over mem', () {
    test('forwards to a backend; a record pointing back at the proxy is '
        'refused at once', () async {
      final backend = node();
      backend.registerService(echo, serveEcho, instance: 7);
      final backendUri = await backend.listenMemory();
      final table = StaticResolver([
        ServiceRecord(ServiceAddress(echo, 7), endpoints: [backendUri]),
      ]);
      addTearDown(table.close);
      final proxy = node(resolver: table);
      var hops = 0;
      final handler = proxyHandler(proxy);
      proxy.catchAll = (incoming) {
        hops++;
        return handler(incoming);
      };
      final proxyUri = await proxy.listenMemory();
      table.add(ServiceRecord(ServiceAddress(echo, 9), endpoints: [proxyUri]));
      expect(proxy.isOwnEndpoint(proxyUri), isTrue);
      expect(proxy.isOwnEndpoint(backendUri), isFalse);
      final client = node(resolver: EndpointResolver(proxyUri));
      final talk = await client.openTalk(ServiceAddress(echo, 7));
      final reply = await talk.request('ECHO', bytes('via proxy'));
      expect(utf8.decode(reply.payload), '7:via proxy');
      await talk.close();
      hops = 0;
      final looping = await client.openChannel(ServiceAddress(echo, 9));
      final status = await looping.done;
      expect(status, hasCode(StatusCode.unavailable));
      expect(status.reason, 'unavailable');
      expect(hops, 1);
    });
  });
}
