import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:async/async.dart';
import 'package:stream_channel/stream_channel.dart';
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

/// A node whose next [connect] hands out the connection only after
/// [beforeReturn] ran on it: used to make the peer's GOAWAY arrive between
/// connect() and the OPEN, the race the open methods retry once.
class RacingSwitchboard extends Switchboard {
  RacingSwitchboard({super.resolver}) : super(muxOptions: fast);

  /// Runs once, on the next connection [connect] returns.
  Future<void> Function(MuxConnection connection)? beforeReturn;

  @override
  Future<MuxConnection> connect(Uri endpoint) async {
    final connection = await super.connect(endpoint);
    final hook = beforeReturn;
    beforeReturn = null;
    await hook?.call(connection);
    return connection;
  }
}

/// Makes the server side of [connection] send GOAWAY and waits until the
/// client side has seen it.
Future<void> peerGoesAway(
  MuxConnection connection,
  MuxConnection serverSide,
) async {
  unawaited(serverSide.goAway());
  while (!connection.peerGoingAway) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

/// The status codes of the HTTP responses read from [socket], in order.
StreamQueue<int> httpStatuses(Socket socket) {
  final statuses = StreamController<int>();
  var text = '';
  var seen = 0;
  socket.listen(
    (data) {
      text += latin1.decode(data);
      final matches = RegExp(r'HTTP/1\.1 (\d{3})').allMatches(text).toList();
      for (final match in matches.skip(seen)) {
        statuses.add(int.parse(match[1]!));
      }
      seen = matches.length;
    },
    onError: (Object _) {},
    onDone: statuses.close,
  );
  return StreamQueue(statuses.stream);
}

/// A transport whose sink's close completes only once [release] has: the
/// node's side of a connection that takes a while to close.
StreamChannel<Uint8List> gated(
  StreamChannel<Uint8List> transport,
  Future<void> release,
) => StreamChannel(transport.stream, _GatedSink(transport.sink, release));

class _GatedSink extends DelegatingStreamSink<Uint8List> {
  _GatedSink(super.sink, this.release);

  final Future<void> release;

  @override
  Future<void> close() async {
    await super.close();
    await release;
  }
}

/// Sends a GET for [path] to port [port] and returns the status and body.
Future<(int, String)> httpGet(int port, String path) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(
      Uri.parse('http://127.0.0.1:$port$path'),
    );
    final response = await request.close();
    return (response.statusCode, await utf8.decodeStream(response));
  } finally {
    client.close(force: true);
  }
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

  group('WebSocket binding', () {
    test('the mux frame limit reaches both ends', () async {
      const limit = 4 * 1024 * 1024;
      final options = fast.copyWith(maxFrameSize: limit);
      final server = Switchboard(muxOptions: options);
      addTearDown(server.close);
      server.registerService(Name('echo'), (incoming) {
        incoming.channel.stream.listen(
          incoming.channel.send,
          onDone: () => unawaited(incoming.channel.close()),
        );
      });
      final uri = await server.listenWebSocket('127.0.0.1', 0);
      final accepted = server.connections.first;
      final client = Switchboard(muxOptions: options);
      addTearDown(client.close);
      final connection = await client.connect(uri);
      final serverSide = await accepted;
      await connection.ping();
      await serverSide.ping();
      expect(connection.peerLimits!.maxFrameSize, limit);
      expect(serverSide.peerLimits!.maxFrameSize, limit);
      // A subframe of 3 MiB passes both ways.
      final big = Uint8List.fromList(
        List.generate(3 * 1024 * 1024, (i) => i * 7 & 0xFF),
      );
      final echo = await client.openChannelAt(
        uri,
        ChannelAddress(type: Name('echo')),
      );
      echo.send(big);
      expect(await echo.stream.first, big);
      await echo.close();
    });

    test('no limit at the mux layer keeps the transport default', () async {
      final options = fast.copyWith(maxFrameSize: 0);
      final server = Switchboard(muxOptions: options);
      addTearDown(server.close);
      final uri = await server.listenWebSocket('127.0.0.1', 0);
      final accepted = server.connections.first;
      final client = Switchboard(muxOptions: options);
      addTearDown(client.close);
      final connection = await client.connect(uri);
      final serverSide = await accepted;
      await connection.ping();
      await serverSide.ping();
      expect(
        connection.peerLimits!.maxFrameSize,
        WebSocketServerTransport.defaultMaxFrameSize,
      );
      expect(
        serverSide.peerLimits!.maxFrameSize,
        WebSocketTransport.defaultMaxFrameSize,
      );
    });

    test(
      'the dialer offers the switchboard protocol and no compression',
      () async {
        final http = await HttpServer.bind('127.0.0.1', 0);
        addTearDown(() => http.close(force: true));
        final seen = Completer<HttpHeaders>();
        http.listen((request) {
          seen.complete(request.headers);
          request.response.statusCode = HttpStatus.badRequest;
          unawaited(request.response.close());
        });
        final client = node();
        await expectLater(
          client.connect(Uri.parse('ws://127.0.0.1:${http.port}/')),
          throwsCode(StatusCode.unavailable),
        );
        final headers = await seen.future;
        expect(headers.value('sec-websocket-protocol'), 'switchboard');
        expect(headers.value('sec-websocket-version'), '13');
        expect(headers['sec-websocket-extensions'], isNull);
      },
    );
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

  group('listener policy', () {
    final ns = Name('_ns');
    final secret = Name('secret');
    late Switchboard server;
    late Switchboard client;

    setUp(() {
      server = node();
      server.registerService(ns, tagged('naming'), instance: 1);
      server.registerService(svc, tagged('svc'));
      server.registerService(secret, tagged('secret'));
      server.catchAll = tagged('catch-all');
      client = node();
    });

    Future<Status> statusOf(Uri uri, ChannelAddress address) async =>
        (await client.openChannelAt(uri, address)).done;

    test('a policy is applied before every handler', () async {
      final public = await server.listenTcp(
        '127.0.0.1',
        0,
        policy: ChannelPolicies.allowTypes({svc}),
      );
      final internal = await server.listenTcp('127.0.0.1', 0);
      for (final address in [
        ChannelAddress(type: ns, instance: 1),
        ChannelAddress(type: ns),
        ChannelAddress(type: secret),
        ChannelAddress(type: Name('other')),
        ChannelAddress(),
      ]) {
        final status = await statusOf(public, address);
        expect(
          status,
          hasCode(StatusCode.permissionDenied),
          reason: '$address',
        );
        // Generic: nothing about the node or the address.
        expect(status.reason, 'permission denied');
      }
      expect(
        await tagOf(await client.openChannelAt(public, svcAddress())),
        'svc',
      );
      // The internal listener has no policy: everything is reachable.
      for (final (address, tag) in [
        (ChannelAddress(type: ns, instance: 1), 'naming'),
        (ChannelAddress(type: secret), 'secret'),
        (ChannelAddress(type: Name('other')), 'catch-all'),
        (svcAddress(), 'svc'),
      ]) {
        expect(await tagOf(await client.openChannelAt(internal, address)), tag);
      }
    });

    test('denyReserved on a WebSocket listener', () async {
      final uri = await server.listenWebSocket(
        '127.0.0.1',
        0,
        policy: ChannelPolicies.denyReserved,
      );
      expect(
        await statusOf(uri, ChannelAddress(type: ns, instance: 1)),
        hasCode(StatusCode.permissionDenied),
      );
      expect(await tagOf(await client.openChannelAt(uri, svcAddress())), 'svc');
      expect(
        await tagOf(
          await client.openChannelAt(uri, ChannelAddress(type: Name('x'))),
        ),
        'catch-all',
      );
    });

    test('the policy sees the address and connection; a throwing policy '
        'refuses', () async {
      final seen = <(ChannelAddress, MuxConnection)>[];
      final uri = await server.listenTcp(
        '127.0.0.1',
        0,
        policy: (address, connection) {
          seen.add((address, connection));
          if (address.type == secret) {
            throw StateError('broken policy');
          }
          return true;
        },
      );
      expect(
        await tagOf(
          await client.openChannelAt(uri, svcAddress(payload: bytes('t'))),
        ),
        'svc',
      );
      expect(seen.single.$1.address, ServiceAddress(svc));
      expect(utf8.decode(seen.single.$1.payload), 't');
      expect(seen.single.$2.isInitiator, isFalse);
      expect(
        await statusOf(uri, ChannelAddress(type: secret)),
        hasCode(StatusCode.permissionDenied),
      );
    });

    test('allowTypes with untyped channels', () async {
      server.defaultService = tagged('default');
      final uri = await server.listenTcp(
        '127.0.0.1',
        0,
        policy: ChannelPolicies.allowTypes({svc}, untyped: true),
      );
      expect(
        await tagOf(await client.openChannelAt(uri, ChannelAddress())),
        'default',
      );
      expect(
        await statusOf(uri, ChannelAddress(type: secret)),
        hasCode(StatusCode.permissionDenied),
      );
    });

    test('connections initiated locally are trusted', () async {
      // The client listens with a strict policy, yet the server reaches
      // its reserved service over the connection the client initiated.
      client.registerService(ns, tagged('client naming'));
      await client.listenTcp(
        '127.0.0.1',
        0,
        policy: ChannelPolicies.allowTypes(const {}),
      );
      final serverUri = await server.listenTcp(
        '127.0.0.1',
        0,
        policy: ChannelPolicies.denyReserved,
      );
      final accepted = server.connections.first;
      await client.connect(serverUri);
      final back = server.openChannelOn(
        await accepted,
        ChannelAddress(type: ns),
      );
      expect(await tagOf(back), 'client naming');
    });

    test('unclaimed channels are rejected with a generic reason', () async {
      server.catchAll = null;
      final uri = await server.listenTcp('127.0.0.1', 0);
      final status = await statusOf(uri, ChannelAddress(type: Name('nope')));
      expect(status, hasCode(StatusCode.notFound));
      expect(status.reason, 'not found');
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

    test('more connections when the pooled ones are full', () async {
      final small = Switchboard(muxOptions: fast.copyWith(maxChannels: 2));
      addTearDown(small.close);
      final held = <IncomingChannel>[];
      small.registerService(Name('hold'), held.add);
      final smallUri = await small.listenTcp('127.0.0.1', 0);
      final pooled = Switchboard(
        muxOptions: fast,
        maxConnectionsPerEndpoint: 3,
      );
      addTearDown(pooled.close);
      final channels = <MuxChannel>[];
      for (var i = 0; i < 6; i++) {
        final channel = await pooled.openChannelAt(
          smallUri,
          ChannelAddress(type: Name('hold')),
        );
        // Let LIMITS arrive on a new connection before the next open.
        await channel.connection.ping();
        channels.add(channel);
      }
      final connections = channels.map((c) => c.connection).toSet();
      expect(connections, hasLength(3));
      for (final connection in connections) {
        expect(connection.openChannelCount, 2);
      }
      expect(held, hasLength(6));
      // At the cap and every connection is full.
      await expectLater(
        pooled.openChannelAt(smallUri, ChannelAddress(type: Name('hold'))),
        throwsCode(StatusCode.resourceExhausted),
      );
      // A channel that ends makes room on its connection again.
      await held.first.channel.close();
      await channels.first.done;
      final again = await pooled.openChannelAt(
        smallUri,
        ChannelAddress(type: Name('hold')),
      );
      expect(again.connection, same(channels.first.connection));
    });

    test('a GOAWAY between connect and OPEN is retried once', () async {
      server.registerService(svc, tagged('one'), instance: 1);
      final racing = RacingSwitchboard(
        resolver: StaticResolver([
          ServiceRecord(ServiceAddress(svc, 1), endpoints: [uri]),
        ]),
      );
      addTearDown(racing.close);
      final first = await racing.connect(uri);
      await first.ping();
      racing.beforeReturn = (c) async {
        expect(c, same(first));
        await peerGoesAway(c, accepted.last);
      };
      final viaAt = await racing.openChannelAt(uri, svcAddress(instance: 1));
      expect(viaAt.connection, isNot(same(first)));
      expect(await tagOf(viaAt), 'one');
      // The same through the resolver.
      final second = viaAt.connection;
      await second.ping();
      racing.beforeReturn = (c) async {
        expect(c, same(second));
        await peerGoesAway(c, accepted.last);
      };
      final viaResolver = await racing.openChannel(ServiceAddress(svc, 1));
      expect(viaResolver.connection, isNot(same(second)));
      expect(await tagOf(viaResolver), 'one');
      expect(accepted, hasLength(3));
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

    for (final scheme in ['tcp', 'ws']) {
      test(
        'a client closing right after connecting sends GOAWAY ($scheme)',
        () async {
          final server = node();
          final uri = scheme == 'tcp'
              ? await server.listenTcp('127.0.0.1', 0)
              : await server.listenWebSocket('127.0.0.1', 0);
          final seen = <StatusCode?>[];
          for (var i = 0; i < 50; i++) {
            final accepted = server.connections.first;
            final client = Switchboard(muxOptions: fast);
            await client.connect(uri);
            await client.close();
            seen.add((await (await accepted).done).known);
          }
          expect(seen, everyElement(StatusCode.goingAway));
        },
      );
    }

    test('a dial in progress gets GOAWAY, and close waits for it', () async {
      // An endpoint that answers the upgrade only when told to.
      final http = await HttpServer.bind('127.0.0.1', 0);
      addTearDown(() => http.close(force: true));
      final arrived = Completer<void>();
      final release = Completer<void>();
      final peer = Completer<MuxConnection>();
      http.listen((request) async {
        arrived.complete();
        await release.future;
        peer.complete(
          MuxConnection(
            await WebSocketServerTransport.upgrade(request),
            isInitiator: false,
            options: fast,
          ),
        );
      });
      final client = Switchboard(muxOptions: fast);
      final dial = expectLater(
        client.connect(Uri.parse('ws://127.0.0.1:${http.port}/')),
        throwsCode(StatusCode.failedPrecondition),
      );
      await arrived.future;
      var closed = false;
      final closing = client.close().then((_) => closed = true);
      await pumpEventQueue();
      expect(closed, isFalse);
      release.complete();
      final connection = await peer.future;
      await closing;
      await dial;
      // The peer was told: GOAWAY, not a dropped connection.
      expect(await connection.done, hasCode(StatusCode.goingAway));
    });

    test('a request in progress when closing is answered, then its '
        'connection closes', () async {
      final server = Switchboard(
        muxOptions: fast.copyWith(goAwayGrace: const Duration(seconds: 5)),
      );
      final held = Completer<IncomingChannel>();
      server.registerService(Name('hold'), held.complete);
      final uri = await server.listenWebSocket('127.0.0.1', 0);
      final client = node();
      await client.openChannelAt(uri, ChannelAddress(type: Name('hold')));
      final holding = await held.future;
      // A plain request, then one whose body is not complete yet: the
      // connection is busy with it when the node starts closing.
      final raw = await Socket.connect('127.0.0.1', uri.port);
      addTearDown(raw.destroy);
      final statuses = httpStatuses(raw);
      raw.write(
        'GET / HTTP/1.1\r\nHost: x\r\n\r\n'
        'POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 4\r\n\r\nab',
      );
      expect(await statuses.next, HttpStatus.upgradeRequired);
      // The held channel keeps the node closing until it is released.
      final closing = server.close();
      raw.write(
        'cdGET / HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\n'
        'Connection: Upgrade\r\nSec-WebSocket-Version: 13\r\n'
        'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n',
      );
      // The POST is answered; the pipelined request after it is not
      // served, as the listener has stopped.
      expect(await statuses.next, HttpStatus.upgradeRequired);
      expect(await statuses.hasNext, isFalse);
      await holding.channel.close();
      await closing;
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

  group('accept', () {
    final secret = Name('secret');

    /// A node with `svc` and `secret` services; `svc` reports the remote.
    Switchboard served(List<String?> remotes, {MuxOptions options = fast}) {
      final server = Switchboard(muxOptions: options);
      addTearDown(server.close);
      server.registerService(svc, (incoming) {
        remotes.add(incoming.remote);
        tagged('svc')(incoming);
      });
      server.registerService(secret, tagged('secret'));
      return server;
    }

    /// A raw mux peer on one side of a memory pair; the other side is
    /// returned for the node.
    (MuxConnection, StreamChannel<Uint8List>) rawPeer() {
      final (local, remote) = MemoryTransport.pair();
      final peer = MuxConnection(local, isInitiator: true, options: fast);
      addTearDown(peer.close);
      return (peer, remote);
    }

    test('adopts a transport like a listener: acceptor side, mux options, '
        'policy, dispatch, connections', () async {
      final remotes = <String?>[];
      final server = served(remotes, options: fast.copyWith(maxChannels: 7));
      final announced = server.connections.first;
      final (peer, transport) = rawPeer();
      final connection = await server.accept(
        transport,
        policy: ChannelPolicies.allowTypes({svc}),
      );
      expect(await announced, same(connection));
      expect(connection.isInitiator, isFalse);
      await peer.ping();
      // The node's mux options, announced with LIMITS.
      expect(peer.peerLimits!.maxChannels, 7);
      expect(await tagOf(peer.open(svcAddress().encode())), 'svc');
      final refused = peer.open(ChannelAddress(type: secret).encode());
      final status = await refused.done;
      expect(status, hasCode(StatusCode.permissionDenied));
      expect(status.reason, 'permission denied');
      // Without a policy everything is reachable; the remote is as given.
      final (other, otherTransport) = rawPeer();
      await server.accept(otherTransport, remote: 'app peer 1');
      expect(
        await tagOf(other.open(ChannelAddress(type: secret).encode())),
        'secret',
      );
      expect(await tagOf(other.open(svcAddress().encode())), 'svc');
      expect(remotes, ['external', 'app peer 1']);
      // Symmetric dispatch: the node opens channels back on it.
      peer.incoming.listen((channel) {
        channel.send(bytes('peer'));
        unawaited(channel.close());
      });
      expect(
        await tagOf(server.openChannelOn(connection, ChannelAddress())),
        'peer',
      );
    });

    test('close sends GOAWAY to an accepted connection', () async {
      final server = Switchboard(muxOptions: fast);
      final (peer, transport) = rawPeer();
      final connection = await server.accept(transport);
      await peer.ping();
      await server.close();
      expect(await peer.done, hasCode(StatusCode.goingAway));
      expect(await connection.done, hasCode(StatusCode.goingAway));
    });

    test('accept after close fails and closes the transport', () async {
      final server = Switchboard(muxOptions: fast);
      await server.close();
      final (peer, transport) = rawPeer();
      await expectLater(
        server.accept(transport),
        throwsCode(StatusCode.failedPrecondition),
      );
      // The peer is told, and the transport closed.
      expect(await peer.done, hasCode(StatusCode.goingAway));
    });

    test('close waits for a connection accepted while closing', () async {
      final server = Switchboard(
        muxOptions: fast.copyWith(goAwayGrace: const Duration(seconds: 5)),
      );
      final held = Completer<IncomingChannel>();
      server.registerService(Name('hold'), held.complete);
      final (first, firstTransport) = rawPeer();
      await server.accept(firstTransport);
      first.open(ChannelAddress(type: Name('hold')).encode());
      final holding = await held.future;
      var closed = false;
      final closing = server.close().then((_) => closed = true);
      // The held channel keeps the node closing.
      while (!first.peerGoingAway) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      // A connection accepted now is refused and sent GOAWAY at once, but
      // the node's side takes a while to close.
      final release = Completer<void>();
      final (second, secondTransport) = rawPeer();
      await expectLater(
        server.accept(gated(secondTransport, release.future)),
        throwsCode(StatusCode.failedPrecondition),
      );
      expect(await second.done, hasCode(StatusCode.goingAway));
      await holding.channel.close();
      expect(await first.done, hasCode(StatusCode.goingAway));
      await pumpEventQueue();
      expect(closed, isFalse);
      release.complete();
      await closing;
      expect(closed, isTrue);
    });
  });

  group('an app HttpServer', () {
    test('acceptWebSocket: /ws to the node, other routes to the app, bad '
        'upgrades refused', () async {
      final server = node();
      final remotes = <String?>[];
      server.registerService(svc, (incoming) {
        remotes.add(incoming.remote);
        incoming.talk().messages.listen((m) => m.reply(m.payload));
      });
      server.registerService(Name('_ns'), tagged('naming'));
      final http = await HttpServer.bind('127.0.0.1', 0);
      addTearDown(() => http.close(force: true));
      final accepted = <MuxConnection>[];
      final failures = StreamController<SwitchboardException>();
      http.listen((request) async {
        switch (request.uri.path) {
          case '/ws':
            try {
              accepted.add(
                await server.acceptWebSocket(
                  request,
                  policy: ChannelPolicies.denyReserved,
                ),
              );
            } on SwitchboardException catch (e) {
              failures.add(e);
            }
          case '/oauth':
            request.response.write('signed in');
            await request.response.close();
          default:
            request.response.statusCode = HttpStatus.notFound;
            await request.response.close();
        }
      });
      final refusals = StreamQueue(failures.stream);
      final endpoint = Uri.parse('ws://127.0.0.1:${http.port}/ws');
      final client = node();
      final talk = await client.openTalkAt(endpoint, svcAddress());
      expect((await talk.request('ECHO', bytes('hi'))).payload, bytes('hi'));
      await talk.close();
      expect(accepted.single.isInitiator, isFalse);
      expect(remotes.single, startsWith('127.0.0.1:'));
      // The policy applies.
      final naming = await client.openChannelAt(
        endpoint,
        ChannelAddress(type: Name('_ns')),
      );
      expect(await naming.done, hasCode(StatusCode.permissionDenied));
      // The app's own routes.
      expect(await httpGet(http.port, '/oauth'), (200, 'signed in'));
      expect((await httpGet(http.port, '/nothing')).$1, HttpStatus.notFound);
      // A bad key gets 400, a plain request 426; the call fails.
      final raw = await Socket.connect('127.0.0.1', http.port);
      addTearDown(raw.destroy);
      final statuses = httpStatuses(raw);
      raw.write(
        'GET /ws HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\n'
        'Connection: Upgrade\r\nSec-WebSocket-Version: 13\r\n'
        'Sec-WebSocket-Key: short\r\n\r\n',
      );
      expect(await statuses.next, HttpStatus.badRequest);
      expect((await refusals.next).code, StatusCode.invalidArgument);
      expect((await httpGet(http.port, '/ws')).$1, HttpStatus.upgradeRequired);
      expect((await refusals.next).code, StatusCode.invalidArgument);
      expect(accepted, hasLength(1));
      // Closing the node sends GOAWAY; then upgrades are answered 503.
      final pooled = await client.connect(endpoint);
      await server.close();
      expect(await pooled.done, hasCode(StatusCode.goingAway));
      expect(
        (await httpGet(http.port, '/ws')).$1,
        HttpStatus.serviceUnavailable,
      );
      expect((await refusals.next).code, StatusCode.failedPrecondition);
      await refusals.cancel(immediate: true);
      await failures.close();
    });

    test('listenWebSocket hands other paths to onOtherRequest', () async {
      final server = node();
      server.registerService(svc, tagged('svc'));
      final uri = await server.listenWebSocket(
        '127.0.0.1',
        0,
        path: '/ws',
        onOtherRequest: (request) async {
          final response = request.response;
          switch (request.uri.path) {
            case '/.well-known/thing':
              response.write('{"ok":true}');
              await response.close();
            case '/boom':
              throw StateError('app bug');
            case '/late-boom':
              await Future<void>.delayed(Duration.zero);
              throw StateError('async app bug');
            case '/answered-boom':
              response.statusCode = HttpStatus.accepted;
              await response.close();
              throw StateError('after answering');
            default:
              response.statusCode = HttpStatus.notFound;
              await response.close();
          }
        },
      );
      expect(uri.path, '/ws');
      // The WebSocket path still upgrades.
      final client = node();
      expect(await tagOf(await client.openChannelAt(uri, svcAddress())), 'svc');
      expect(await httpGet(uri.port, '/.well-known/thing'), (
        200,
        '{"ok":true}',
      ));
      expect((await httpGet(uri.port, '/')).$1, HttpStatus.notFound);
      // A failing callback: 500 unless it had answered.
      expect(
        (await httpGet(uri.port, '/boom')).$1,
        HttpStatus.internalServerError,
      );
      expect(
        (await httpGet(uri.port, '/late-boom')).$1,
        HttpStatus.internalServerError,
      );
      expect((await httpGet(uri.port, '/answered-boom')).$1, 202);
      // The WebSocket path keeps its own answers.
      expect((await httpGet(uri.port, '/ws')).$1, HttpStatus.upgradeRequired);
    });
  });
}

ChannelAddress svcAddress({int instance = 0, Uint8List? payload}) =>
    ChannelAddress(type: svc, instance: instance, payload: payload);
