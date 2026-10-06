import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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

final svc = Name('svc');

/// A node closed after the test.
Switchboard node({
  Resolver? resolver,
  Uint8List? defaultPayload,
  TalkOptions? talkOptions,
}) {
  final s = Switchboard(
    resolver: resolver,
    defaultPayload: defaultPayload,
    muxOptions: fast,
    talkOptions: talkOptions,
  );
  addTearDown(s.close);
  return s;
}

/// A handler that sends [tag] and closes.
ChannelHandler tagged(String tag) => (incoming) {
  incoming.channel.send(bytes(tag));
  unawaited(incoming.channel.close());
};

/// Reads the tag sent by a [tagged] handler, or the close status.
Future<String> tagOf(MuxChannel channel) async {
  final frames = await channel.stream.toList();
  final status = await channel.done;
  if (frames.isEmpty) {
    return 'closed ${status.known?.name ?? status.code}';
  }
  return utf8.decode(frames.single);
}

/// A port nothing listens on.
Future<int> deadPort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

void main() {
  group('listening', () {
    test('returns bound URIs and lists them until close', () async {
      final server = Switchboard(muxOptions: fast);
      final tcp = await server.listenTcp(InternetAddress.loopbackIPv4, 0);
      final ws = await server.listenWebSocket('127.0.0.1', 0, path: 'mesh/');
      expect(tcp.scheme, 'tcp');
      expect(tcp.host, '127.0.0.1');
      expect(tcp.port, isNot(0));
      expect(ws.toString(), 'ws://127.0.0.1:${ws.port}/mesh');
      expect(server.listeningEndpoints, [tcp, ws]);
      await server.close();
      expect(server.listeningEndpoints, isEmpty);
      await expectLater(
        server.listenTcp('127.0.0.1', 0),
        throwsCode(StatusCode.failedPrecondition),
      );
    });

    test('WebSocket path matching and HTTP answers', () async {
      final server = node();
      final uri = await server.listenWebSocket('127.0.0.1', 0, path: '/mesh');
      server.registerService(svc, tagged('hi'));
      final client = node();
      // With and without the trailing slash.
      for (final path in ['/mesh', '/mesh/']) {
        final endpoint = uri.replace(path: path);
        expect(
          await tagOf(await client.openChannelAt(endpoint, svcAddress())),
          'hi',
        );
      }
      final http = HttpClient();
      addTearDown(() => http.close(force: true));
      Future<int> get(String path) async {
        final request = await http.getUrl(
          Uri.parse('http://127.0.0.1:${uri.port}$path'),
        );
        final response = await request.close();
        await response.drain<void>();
        return response.statusCode;
      }

      expect(await get('/other'), HttpStatus.forbidden);
      expect(await get('/'), HttpStatus.forbidden);
      expect(await get('/mesh/x'), HttpStatus.forbidden);
      expect(await get('/mesh'), HttpStatus.upgradeRequired);
      await expectLater(
        client.connect(uri.replace(path: '/other')),
        throwsCode(StatusCode.unavailable),
      );
    });

    test('selects the switchboard subprotocol', () async {
      final server = node();
      final uri = await server.listenWebSocket('127.0.0.1', 0);
      final accepted = server.connections.first;
      final ws = await WebSocket.connect(
        uri.toString(),
        protocols: ['other', WebSocketTransport.subprotocol],
      );
      expect(ws.protocol, WebSocketTransport.subprotocol);
      final connection = await accepted;
      final drained = ws.drain<void>();
      await ws.close();
      await drained;
      await connection.done;
      // A client offering only other subprotocols is refused.
      await expectLater(
        WebSocket.connect(uri.toString(), protocols: ['other']),
        throwsA(isA<WebSocketException>()),
      );
    });
  });

  group('dispatch', () {
    late Switchboard server;
    late Switchboard client;
    late Uri uri;

    setUp(() async {
      server = node();
      uri = await server.listenTcp('127.0.0.1', 0);
      client = node();
    });

    Future<String> open(ChannelAddress address) async =>
        tagOf(await client.openChannelAt(uri, address));

    test('exact instance', () async {
      server.registerService(svc, tagged('five'), instance: 5);
      server.registerService(svc, tagged('six'), instance: 6);
      expect(await open(svcAddress(instance: 6)), 'six');
      expect(await open(svcAddress(instance: 5)), 'five');
    });

    test('any instance goes to the first registered', () async {
      server.registerService(svc, tagged('six'), instance: 6);
      server.registerService(svc, tagged('five'), instance: 5);
      expect(await open(svcAddress()), 'six');
      // An exact registration for instance 0 wins.
      server.registerService(svc, tagged('any'));
      expect(await open(svcAddress()), 'any');
      // Re-registering keeps the position but replaces the handler.
      server.unregisterService(svc);
      server.registerService(svc, tagged('six again'), instance: 6);
      expect(await open(svcAddress()), 'six again');
    });

    test('unknown instance or type is not found', () async {
      server.registerService(svc, tagged('five'), instance: 5);
      server.registerService(svc, tagged('any'));
      expect(await open(svcAddress(instance: 7)), 'closed notFound');
      expect(
        await open(ChannelAddress(type: Name('other'))),
        'closed notFound',
      );
      server.unregisterService(svc, instance: 5);
      expect(await open(svcAddress(instance: 5)), 'closed notFound');
    });

    test('default service for channels without a type', () async {
      server.registerService(svc, tagged('svc'));
      expect(await open(ChannelAddress()), 'closed notFound');
      server.defaultService = tagged('default');
      expect(await open(ChannelAddress()), 'default');
      // The minimal one-byte header and the empty open payload.
      final connection = await client.connect(uri);
      expect(await tagOf(connection.open(Uint8List(1))), 'default');
      expect(await tagOf(connection.open(Uint8List(0))), 'default');
      expect(await open(svcAddress()), 'svc');
    });

    test('catch-all takes what no service claims', () async {
      server.registerService(svc, tagged('five'), instance: 5);
      server.catchAll = tagged('catch-all');
      expect(await open(svcAddress(instance: 7)), 'catch-all');
      expect(await open(ChannelAddress(type: Name('other'))), 'catch-all');
      expect(await open(ChannelAddress()), 'catch-all');
      expect(await open(svcAddress(instance: 5)), 'five');
      server.defaultService = tagged('default');
      expect(await open(ChannelAddress()), 'default');
      server.catchAll = null;
      expect(await open(svcAddress(instance: 7)), 'closed notFound');
    });

    test('malformed open payload is a channel protocol error', () async {
      server.registerService(svc, tagged('svc'));
      final raw = MuxConnection(
        await StreamTransport.connectTcp('127.0.0.1', uri.port),
        isInitiator: true,
        options: fast,
      );
      addTearDown(raw.close);
      final reserved = raw.open(Uint8List.fromList([0x10]));
      final truncated = raw.open(Uint8List.fromList([0x01, 0x73, 0x76]));
      expect(await reserved.done, hasCode(StatusCode.protocolError));
      expect(await truncated.done, hasCode(StatusCode.protocolError));
      // The connection itself is fine.
      expect(await tagOf(raw.open(svcAddress().encode())), 'svc');
      expect(raw.isOpen, isTrue);
    });

    test('a throwing handler closes the channel with INTERNAL', () async {
      server.registerService(svc, (_) => throw StateError('sync'));
      server.registerService(Name('async'), (incoming) async {
        await Future<void>.delayed(Duration.zero);
        throw StateError('async');
      });
      expect(await open(svcAddress()), 'closed internal');
      expect(
        await open(ChannelAddress(type: Name('async'))),
        'closed internal',
      );
    });

    test('reject closes with the given status', () async {
      server.registerService(svc, (incoming) {
        final token = utf8.decode(incoming.address.payload);
        if (token != 'good') {
          unawaited(
            incoming.reject(Status.of(StatusCode.unauthenticated, 'bad')),
          );
          return;
        }
        incoming.channel.send(bytes('welcome'));
        unawaited(incoming.channel.close());
      });
      server.registerService(Name('app'), (incoming) {
        unawaited(incoming.reject(const Status(300, 'app')));
      });
      expect(
        await open(svcAddress(payload: bytes('bad'))),
        'closed unauthenticated',
      );
      expect(await open(svcAddress(payload: bytes('good'))), 'welcome');
      expect(await open(ChannelAddress(type: Name('app'))), 'closed unknown');
    });

    test('incoming channel exposes the header, payload and remote', () async {
      final seen = Completer<IncomingChannel>();
      server.registerService(svc, (incoming) {
        seen.complete(incoming);
        unawaited(incoming.channel.close());
      }, instance: 0x1a2b);
      final channel = await client.openChannelAt(
        uri,
        ChannelAddress(
          type: svc,
          instance: 0x1a2b,
          shard: 42,
          payload: bytes('token'),
        ),
      );
      final incoming = await seen.future;
      expect(incoming.address.address, ServiceAddress(svc, 0x1a2b));
      expect(incoming.address.shard, 42);
      expect(utf8.decode(incoming.address.payload), 'token');
      expect(incoming.remote, startsWith('127.0.0.1:'));
      expect(incoming.connection.isInitiator, isFalse);
      expect(incoming.channel.isLocallyOpened, isFalse);
      expect(await channel.done, hasCode(StatusCode.ok));
    });

    test('talk() wraps once with the default talk options', () async {
      final quick = node(
        talkOptions: const TalkOptions(
          replyTimeout: Duration(milliseconds: 30),
        ),
      );
      final quickUri = await quick.listenTcp('127.0.0.1', 0);
      quick.registerService(svc, (incoming) {
        final talk = incoming.talk();
        expect(incoming.talk(), same(talk));
        expect(talk.options.replyTimeout, const Duration(milliseconds: 30));
        talk.messages.listen((message) {
          if (message.procedureName == 'ECHO') {
            message.reply(message.payload);
          }
          // Anything else is left unanswered: the responder timeout of
          // the default options answers it.
        });
      });
      final talk = await client.openTalkAt(quickUri, svcAddress());
      expect((await talk.request('ECHO', bytes('x'))).payload, bytes('x'));
      await expectLater(
        talk.request('IGNORE', Uint8List(0)),
        throwsCode(StatusCode.deadlineExceeded),
      );
      await talk.close();
    });
  });

  group('symmetric dispatch', () {
    test('the server opens a channel back to a client service', () async {
      final server = node();
      final uri = await server.listenWebSocket('127.0.0.1', 0);
      final client = node(defaultPayload: bytes('client'));
      final pushed = StreamController<String>();
      client.registerService(Name('push'), (incoming) async {
        final talk = incoming.talk();
        await for (final message in talk.messages) {
          pushed.add(
            '${message.procedureName} ${utf8.decode(message.payload)}',
          );
          message.reply(Uint8List(0));
        }
      });
      final accepted = <MuxConnection>[];
      final sub = server.connections.listen(accepted.add);
      addTearDown(sub.cancel);
      server.registerService(Name('hello'), (incoming) async {
        final back = server.openChannelOn(
          incoming.connection,
          ChannelAddress(type: Name('push')),
        );
        final talk = TalkChannel(back);
        await talk.request('NEWS', incoming.address.payload);
        await talk.close();
        await incoming.reject(Status.ok);
      });
      final hello = await client.openChannelAt(
        uri,
        ChannelAddress(type: Name('hello')),
      );
      expect(await pushed.stream.first, 'NEWS client');
      expect(await hello.done, hasCode(StatusCode.ok));
      // The server also reaches the client service through `connections`.
      expect(accepted, hasLength(1));
      final talk = TalkChannel(
        server.openChannelOn(
          accepted.single,
          ChannelAddress(type: Name('push')),
        ),
      );
      await talk.request('MORE', bytes('again'));
      await talk.close();
      await pushed.close();
    });
  });

  group('connection pool', () {
    late Switchboard server;
    late Switchboard client;
    late Uri uri;
    late List<MuxConnection> accepted;

    setUp(() async {
      server = node();
      server.registerService(svc, tagged('svc'));
      uri = await server.listenTcp('127.0.0.1', 0);
      accepted = [];
      final sub = server.connections.listen(accepted.add);
      addTearDown(sub.cancel);
      client = node();
    });

    test('channels to one endpoint share a connection', () async {
      final a = await client.openChannelAt(uri, svcAddress());
      final b = await client.openChannelAt(
        Uri.parse('TCP://127.0.0.1:${uri.port}#svc'),
        svcAddress(),
      );
      expect(a.connection, same(b.connection));
      expect(a.connection.isInitiator, isTrue);
      expect(await tagOf(a), 'svc');
      expect(await tagOf(b), 'svc');
      expect(accepted, hasLength(1));
    });

    test('WebSocket URIs are pooled per path', () async {
      final ws = await server.listenWebSocket('127.0.0.1', 0);
      final a = await client.connect(ws);
      final b = await client.connect(Uri.parse('ws://127.0.0.1:${ws.port}'));
      final c = await client.connect(ws.replace(path: '/'));
      expect(a, same(b));
      expect(a, same(c));
    });

    test('concurrent connects share one attempt', () async {
      final seen = <MuxConnection>{};
      server.registerService(Name('who'), (incoming) {
        seen.add(incoming.connection);
        unawaited(incoming.channel.close());
      });
      final both = await Future.wait([
        client.connect(uri),
        client.connect(uri),
      ]);
      expect(both[0], same(both[1]));
      expect(await client.connect(uri), same(both[0]));
      for (final connection in both) {
        await connection.open(ChannelAddress(type: Name('who')).encode()).done;
      }
      expect(seen, hasLength(1));
      expect(accepted, hasLength(1));
    });

    test('a closed connection is replaced', () async {
      final first = await client.connect(uri);
      expect(await tagOf(first.open(svcAddress().encode())), 'svc');
      await accepted.single.close();
      expect(await first.done, hasCode(StatusCode.connectionLost));
      final second = await client.connect(uri);
      expect(second, isNot(same(first)));
      expect(await tagOf(second.open(svcAddress().encode())), 'svc');
    });

    test('a connection whose peer sent GOAWAY is not reused', () async {
      final arrived = Completer<IncomingChannel>();
      server.registerService(Name('hold'), (incoming) {
        arrived.complete(incoming);
      });
      final first = await client.connect(uri);
      final held = first.open(ChannelAddress(type: Name('hold')).encode());
      final serverSide = await arrived.future;
      // The server keeps the connection while the held channel lives.
      final goingAway = serverSide.connection.goAway();
      while (!first.peerGoingAway) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      final channel = await client.openChannelAt(uri, svcAddress());
      expect(channel.connection, isNot(same(first)));
      expect(await tagOf(channel), 'svc');
      // The held channel still works on the old connection.
      serverSide.channel.send(bytes('still here'));
      expect(await held.stream.first, bytes('still here'));
      await held.close();
      await goingAway;
      expect(await first.done, hasCode(StatusCode.goingAway));
    });

    test('connection refused is unavailable and not cached', () async {
      final port = await deadPort();
      final endpoint = Uri.parse('tcp://127.0.0.1:$port');
      await expectLater(
        client.connect(endpoint),
        throwsCode(StatusCode.unavailable),
      );
      await expectLater(
        client.openChannelAt(endpoint, svcAddress()),
        throwsCode(StatusCode.unavailable),
      );
      // Something starts listening there: the next attempt succeeds.
      final revived = node();
      revived.registerService(svc, tagged('late'));
      await revived.listenTcp('127.0.0.1', port);
      expect(
        await tagOf(await client.openChannelAt(endpoint, svcAddress())),
        'late',
      );
    });

    test('bad endpoints', () async {
      await expectLater(
        client.connect(Uri.parse('unix:///tmp/nothing')),
        throwsCode(StatusCode.unimplemented),
      );
      await expectLater(
        client.connect(Uri.parse('tcp://127.0.0.1')),
        throwsCode(StatusCode.invalidArgument),
      );
      final port = await deadPort();
      await expectLater(
        client.connect(Uri.parse('ws://127.0.0.1:$port/')),
        throwsCode(StatusCode.unavailable),
      );
    });

    test('connections reports initiated connections', () async {
      final initiated = client.connections.first;
      final connection = await client.connect(uri);
      expect(await initiated, same(connection));
    });
  });

  group('openChannel', () {
    late Switchboard one;
    late Switchboard two;
    late Uri oneUri;
    late Uri twoUri;
    late List<IncomingChannel> seen;

    ChannelHandler recording(String tag) => (incoming) {
      seen.add(incoming);
      tagged(tag)(incoming);
    };

    setUp(() async {
      seen = [];
      one = node();
      two = node();
      one.registerService(svc, recording('one'), instance: 1);
      two.registerService(svc, recording('two'), instance: 2);
      oneUri = await one.listenTcp('127.0.0.1', 0);
      twoUri = await two.listenWebSocket('127.0.0.1', 0);
    });

    StaticResolver both() => StaticResolver([
      // Deliberately out of order: selection sorts by instance.
      ServiceRecord(ServiceAddress(svc, 2), endpoints: [twoUri]),
      ServiceRecord(ServiceAddress(svc, 1), endpoints: [oneUri]),
    ]);

    test('needs a resolver', () async {
      final client = node();
      await expectLater(
        client.openChannel(ServiceAddress(svc)),
        throwsCode(StatusCode.failedPrecondition),
      );
    });

    test('nothing known is not found', () async {
      final client = node(resolver: both());
      await expectLater(
        client.openChannel(ServiceAddress(Name('other'))),
        throwsCode(StatusCode.notFound),
      );
      await expectLater(
        client.openChannel(ServiceAddress(svc, 3)),
        throwsCode(StatusCode.notFound),
      );
    });

    test('filters by instance', () async {
      final client = node(resolver: both());
      for (var i = 0; i < 3; i++) {
        expect(
          await tagOf(await client.openChannel(ServiceAddress(svc, 2))),
          'two',
        );
        expect(
          await tagOf(await client.openChannel(ServiceAddress(svc, 1))),
          'one',
        );
      }
      expect(seen.map((s) => s.address.instance), [2, 1, 2, 1, 2, 1]);
    });

    test('round robin across instances', () async {
      final client = node(resolver: both());
      final tags = [
        for (var i = 0; i < 4; i++)
          await tagOf(await client.openChannel(ServiceAddress(svc))),
      ];
      expect(tags, ['one', 'two', 'one', 'two']);
      // The header names the selected instance, so dispatch is exact.
      expect(seen.map((s) => s.address.instance), [1, 2, 1, 2]);
      expect(seen.map((s) => s.address.shard), everyElement(isNull));
    });

    test('shard selection is deterministic', () async {
      final client = node(resolver: both());
      for (var round = 0; round < 2; round++) {
        for (final (shard, tag) in [
          (0, 'one'),
          (1, 'two'),
          (2, 'one'),
          (5, 'two'),
          (0xFFFFFFFF, 'two'),
        ]) {
          final channel = await client.openChannel(
            ServiceAddress(svc),
            shard: shard,
          );
          expect(await tagOf(channel), tag, reason: 'shard $shard');
        }
      }
      expect(seen.last.address.shard, 0xFFFFFFFF);
      expect(seen.last.address.instance, 2);
    });

    test('fails over to the next endpoint, then the next instance', () async {
      final dead = Uri.parse('tcp://127.0.0.1:${await deadPort()}');
      final client = node(
        resolver: StaticResolver([
          ServiceRecord(ServiceAddress(svc, 1), endpoints: [dead, oneUri]),
          ServiceRecord(ServiceAddress(svc, 2), endpoints: [dead]),
          ServiceRecord(ServiceAddress(svc, 3), endpoints: const []),
        ]),
      );
      expect(
        await tagOf(await client.openChannel(ServiceAddress(svc, 1))),
        'one',
      );
      // Instance 2 is first by shard, unreachable; 3 has no endpoint.
      expect(
        await tagOf(await client.openChannel(ServiceAddress(svc), shard: 1)),
        'one',
      );
      expect(seen.last.address.instance, 1);
      await expectLater(
        client.openChannel(ServiceAddress(svc, 2)),
        throwsCode(StatusCode.unavailable),
      );
      await expectLater(
        client.openChannel(ServiceAddress(svc, 3)),
        throwsCode(StatusCode.unavailable),
      );
    });

    test('default payload applied and overridable', () async {
      final client = node(resolver: both(), defaultPayload: bytes('cred'));
      await tagOf(await client.openChannel(ServiceAddress(svc, 1)));
      await tagOf(
        await client.openChannel(ServiceAddress(svc, 1), payload: bytes('own')),
      );
      await tagOf(await client.openChannelAt(oneUri, svcAddress(instance: 1)));
      await tagOf(
        await client.openChannelAt(
          oneUri,
          svcAddress(instance: 1, payload: bytes('explicit')),
        ),
      );
      final talk = await client.openTalk(ServiceAddress(svc, 1));
      await talk.done;
      expect(seen.map((s) => utf8.decode(s.address.payload)), [
        'cred',
        'own',
        'cred',
        'explicit',
        'cred',
      ]);
    });

    test('an endpoint resolver keeps the requested instance', () async {
      final client = node(resolver: EndpointResolver(oneUri));
      expect(
        await tagOf(await client.openChannel(ServiceAddress(svc, 1))),
        'one',
      );
      expect(await tagOf(await client.openChannel(ServiceAddress(svc))), 'one');
      expect(seen.map((s) => s.address.instance), [1, 0]);
    });

    test('selectAndConnect reports the selected instance', () async {
      final client = node(resolver: both());
      final (record, connection) = await client.selectAndConnect(
        ServiceAddress(svc),
        shard: 3,
      );
      expect(record.address, ServiceAddress(svc, 2));
      expect(connection.isOpen, isTrue);
      expect(await client.connect(twoUri), same(connection));
    });
  });

  group('close', () {
    test('sends GOAWAY, stops listening and refuses new work', () async {
      final server = Switchboard(muxOptions: fast);
      server.registerService(svc, (incoming) => incoming.talk());
      final tcp = await server.listenTcp('127.0.0.1', 0);
      final ws = await server.listenWebSocket('127.0.0.1', 0);
      final client = node();
      final viaTcp = await client.openTalkAt(tcp, svcAddress());
      final viaWs = await client.openChannelAt(ws, svcAddress());
      final pending = expectLater(
        viaTcp.request('WAIT', Uint8List(0)),
        throwsCode(StatusCode.goingAway),
      );
      await pumpEventQueue();
      final watch = Stopwatch()..start();
      await server.close();
      // Bounded by the grace period, not by the open channels.
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
      expect(await viaWs.connection.done, hasCode(StatusCode.goingAway));
      expect(await viaWs.done, hasCode(StatusCode.goingAway));
      await pending;
      await expectLater(
        client.connect(tcp),
        throwsCode(StatusCode.unavailable),
      );
      await expectLater(client.connect(ws), throwsCode(StatusCode.unavailable));
      await expectLater(
        server.connect(tcp),
        throwsCode(StatusCode.failedPrecondition),
      );
      await expectLater(
        server.openChannelAt(tcp, svcAddress()),
        throwsCode(StatusCode.failedPrecondition),
      );
      await server.close();
    });

    test('closing a client closes its pooled connections', () async {
      final server = node();
      final uri = await server.listenTcp('127.0.0.1', 0);
      final accepted = server.connections.first;
      final client = Switchboard(muxOptions: fast);
      final connection = await client.connect(uri);
      final serverSide = await accepted;
      final connectionsDone = client.connections.toList();
      await client.close();
      expect(connection.isOpen, isFalse);
      expect(await serverSide.done, hasCode(StatusCode.goingAway));
      expect(await connectionsDone, isEmpty);
    });
  });
}

ChannelAddress svcAddress({int instance = 0, Uint8List? payload}) =>
    ChannelAddress(type: svc, instance: instance, payload: payload);
