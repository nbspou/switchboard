import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:async/async.dart';
import 'package:switchboard/switchboard.dart';
import 'package:test/test.dart';

const fast = MuxOptions(
  goAwayGrace: Duration(milliseconds: 100),
  keepAliveInterval: null,
);

Uint8List bytes(String text) => Uint8List.fromList(utf8.encode(text));

Uint8List pattern(int length, [int seed = 0]) =>
    Uint8List.fromList(List.generate(length, (i) => (i * 31 + seed) & 0xFF));

Matcher hasCode(StatusCode code) =>
    isA<Status>().having((s) => s.known, 'code', code);

Matcher throwsCode(StatusCode code) =>
    throwsA(isA<SwitchboardException>().having((e) => e.code, 'code', code));

/// A node whose next [connect] hands out the connection only after
/// [beforeReturn] ran on it, to make a backend's GOAWAY arrive between
/// connect() and the OPEN.
class RacingSwitchboard extends Switchboard {
  RacingSwitchboard() : super(muxOptions: fast);

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

/// Two mux connections over an in-memory transport, closed after the test.
(MuxConnection, MuxConnection) muxPair({MuxOptions acceptor = fast}) {
  final (a, b) = MemoryTransport.pair();
  final initiator = MuxConnection(a, isInitiator: true, options: fast);
  final accepting = MuxConnection(b, isInitiator: false, options: acceptor);
  addTearDown(() async {
    await initiator.close();
    await accepting.close();
  });
  return (initiator, accepting);
}

/// client ⇄ (proxyIn | pipe | proxyOut) ⇄ backend.
class Piped {
  late MuxConnection clientConnection;
  late MuxConnection backendConnection;
  late MuxChannel client;
  late MuxChannel backend;
  late Future<void> pipe;
}

/// Sets up a piped channel. [early] runs on the client channel before the
/// proxy attaches the pipe.
Future<Piped> piped({
  void Function(MuxChannel client)? early,
  MuxOptions backendOptions = fast,
}) async {
  final p = Piped();
  final (clientConnection, proxyIn) = muxPair();
  final (proxyOut, backendConnection) = muxPair(acceptor: backendOptions);
  p.clientConnection = clientConnection;
  p.backendConnection = backendConnection;
  final atProxy = StreamQueue(proxyIn.incoming);
  final atBackend = StreamQueue(backendConnection.incoming);
  p.client = clientConnection.open(bytes('header'));
  early?.call(p.client);
  await pumpEventQueue();
  final inbound = await atProxy.next;
  final outbound = proxyOut.open(inbound.openPayload);
  p.pipe = pipeChannels(inbound, outbound);
  p.backend = await atBackend.next;
  expect(p.backend.openPayload, bytes('header'));
  return p;
}

void main() {
  group('pipeChannels', () {
    test('forwards subframes both ways, in order', () async {
      final p = await piped();
      final toBackend = [for (var i = 0; i < 100; i++) pattern(i, i)];
      final toClient = [for (var i = 0; i < 100; i++) pattern(i + 1, -i)];
      final atBackend = p.backend.stream.take(100).toList();
      final atClient = p.client.stream.take(100).toList();
      for (var i = 0; i < 100; i++) {
        p.client.send(toBackend[i]);
        p.backend.send(toClient[i]);
      }
      expect(await atBackend, toBackend);
      expect(await atClient, toClient);
      await p.client.close();
      await p.pipe;
    });

    test('forwards large subframes', () async {
      final p = await piped();
      final big = pattern(900 * 1024, 7);
      final atBackend = p.backend.stream.first;
      p.client.send(big);
      expect(await atBackend, big);
      final atClient = p.client.stream.first;
      p.backend.send(big);
      expect(await atClient, big);
      await p.backend.close();
      await p.pipe;
    });

    test('client close status reaches the backend', () async {
      final p = await piped();
      final atBackend = p.backend.stream.toList();
      p.client.send(bytes('last'));
      await p.client.close(Status.of(StatusCode.cancelled, 'bye'));
      expect(await atBackend, [bytes('last')]);
      expect(await p.backend.done, Status.of(StatusCode.cancelled, 'bye'));
      expect(await p.client.done, hasCode(StatusCode.cancelled));
      await p.pipe;
    });

    test('backend close status reaches the client', () async {
      final p = await piped();
      final atClient = p.client.stream.toList();
      p.backend.send(bytes('result'));
      await p.backend.close(Status.of(StatusCode.aborted, 'conflict'));
      expect(await atClient, [bytes('result')]);
      expect(await p.client.done, Status.of(StatusCode.aborted, 'conflict'));
      await p.pipe;
    });

    test('an OK close passes as OK', () async {
      final p = await piped();
      await p.client.close();
      expect(await p.backend.done, hasCode(StatusCode.ok));
      await p.pipe;
    });

    test('lost backend connection is UNAVAILABLE at the client', () async {
      final p = await piped();
      await p.backendConnection.close();
      expect(await p.client.done, hasCode(StatusCode.unavailable));
      await p.pipe;
    });

    test('lost client connection is UNAVAILABLE at the backend', () async {
      final p = await piped();
      await p.clientConnection.close();
      expect(await p.backend.done, hasCode(StatusCode.unavailable));
      await p.pipe;
    });

    test('an application code from a broken peer is sent as UNKNOWN', () async {
      final (clientConnection, proxyIn) = muxPair();
      final (proxyTransport, raw) = MemoryTransport.pair();
      final proxyOut = MuxConnection(
        proxyTransport,
        isInitiator: true,
        options: fast,
      );
      addTearDown(proxyOut.close);
      final frames = StreamQueue(raw.stream.map(MuxFrame.decode));
      final client = clientConnection.open(bytes('x'));
      final inbound = await proxyIn.incoming.first;
      final pipe = pipeChannels(inbound, proxyOut.open(inbound.openPayload));
      MuxFrame frame;
      do {
        frame = await frames.next;
      } while (frame.command != MuxCommand.open);
      // Mux CLOSE must not carry application codes; this peer does anyway.
      raw.sink.add(MuxFrame.close(frame.channelId, const Status(300)).encode());
      expect(await client.done, hasCode(StatusCode.unknown));
      await pipe;
      await raw.sink.close();
      await frames.cancel(immediate: true);
    });

    test('frames sent before the pipe is attached are not lost', () async {
      final p = await piped(
        early: (client) {
          client.send(bytes('one'));
          client.send(Uint8List(0));
          client.send(bytes('three'));
          unawaited(client.close(Status.of(StatusCode.cancelled)));
        },
      );
      expect(await p.backend.stream.toList(), [
        bytes('one'),
        Uint8List(0),
        bytes('three'),
      ]);
      expect(await p.backend.done, hasCode(StatusCode.cancelled));
      await p.pipe;
    });

    test('a subframe over the receiving peer limit closes both', () async {
      final p = await piped(backendOptions: fast.copyWith(maxFrameSize: 1000));
      p.client.send(pattern(2000));
      expect(await p.client.done, hasCode(StatusCode.frameTooLarge));
      expect(await p.backend.done, hasCode(StatusCode.frameTooLarge));
      await p.pipe;
    });

    test('a stream already listened to closes both channels', () async {
      final (clientConnection, proxyIn) = muxPair();
      final (proxyOut, backendConnection) = muxPair();
      final client = clientConnection.open(bytes('x'));
      final inbound = await proxyIn.incoming.first;
      final atBackend = backendConnection.incoming.first;
      final outbound = proxyOut.open(inbound.openPayload);
      inbound.stream.listen(null);
      await pipeChannels(inbound, outbound);
      expect(await client.done, hasCode(StatusCode.internal));
      expect(await (await atBackend).done, hasCode(StatusCode.internal));
    });

    test('a far end that cancels its subscription without closing keeps the '
        'pipe waiting for done', () async {
      final p = await piped();
      // Cancelling drops further DATA but does not close the channel.
      await p.backend.stream.listen(null).cancel();
      var finished = false;
      unawaited(p.pipe.then((_) => finished = true));
      p.client.send(bytes('dropped'));
      await p.clientConnection.ping();
      await p.backendConnection.ping();
      await pumpEventQueue();
      expect(finished, isFalse);
      expect(p.client.state, MuxChannelState.open);
      expect(p.backend.state, MuxChannelState.open);
      // The other direction still flows.
      p.backend.send(bytes('still'));
      expect(await p.client.stream.first, bytes('still'));
      await p.backend.close();
      await p.pipe;
      expect(finished, isTrue);
      expect(await p.client.done, hasCode(StatusCode.ok));
    });

    test('talk works through the pipe', () async {
      final p = await piped();
      final backend = TalkChannel(p.backend);
      backend.messages.listen((m) {
        final s = m.replyStreamRequest(m.payload, procedure: 'CHAIN');
        s.items.listen((item) => item.reply(Uint8List(0)));
      });
      final client = TalkChannel(p.client);
      final reply = await client.request('ASK', bytes('q'));
      expect(reply.procedureName, 'CHAIN');
      expect(reply.expectsStream, isTrue);
      reply.replyItem(bytes('item'));
      reply.reply(Uint8List(0));
      await client.close();
      await p.pipe;
      expect(await backend.done, hasCode(StatusCode.ok));
    });
  });

  group('proxyHandler', () {
    final chat = Name('chat');
    late Switchboard backend;
    late Switchboard endpoint;
    late Switchboard client;
    late Uri backendUri;
    late Uri endpointUri;
    late List<IncomingChannel> atBackend;

    Switchboard node({
      Resolver? resolver,
      Uint8List? defaultPayload,
      bool allowHostHint = false,
    }) {
      final s = Switchboard(
        resolver: resolver,
        defaultPayload: defaultPayload,
        muxOptions: fast,
        allowHostHint: allowHostHint,
      );
      addTearDown(s.close);
      return s;
    }

    setUp(() async {
      atBackend = [];
      backend = node(defaultPayload: bytes('backend credential'));
      backendUri = await backend.listenTcp('127.0.0.1', 0);
      backend.registerService(chat, (incoming) {
        atBackend.add(incoming);
        final talk = incoming.talk();
        talk.messages.listen((m) {
          switch (m.procedureName) {
            case 'WHO':
              final a = incoming.address;
              m.reply(
                bytes(
                  '${a.type} ${a.instance} ${a.shard} ${a.host} '
                  '${utf8.decode(a.payload)}',
                ),
              );
            case 'COUNT':
              for (var i = 1; i <= 3; i++) {
                m.replyItem(bytes('$i'));
              }
              m.reply(bytes('done'));
            case 'KILL':
              unawaited(
                incoming.reject(Status.of(StatusCode.aborted, 'killed')),
              );
          }
        });
      }, instance: 7);
      final dead = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final deadUri = Uri.parse('tcp://127.0.0.1:${dead.port}');
      await dead.close();
      final backends = StaticResolver([
        ServiceRecord(ServiceAddress(chat, 7), endpoints: [backendUri]),
        ServiceRecord(ServiceAddress(Name('down'), 1), endpoints: [deadUri]),
      ]);
      addTearDown(backends.close);
      endpoint = node(defaultPayload: bytes('endpoint credential'));
      final allowed = {chat, Name('void'), Name('down')};
      endpoint.catchAll = proxyHandler(
        endpoint,
        allow: (address) => allowed.contains(address.type),
        resolver: backends,
      );
      endpoint.registerService(Name('api'), (incoming) {
        incoming.talk().messages.listen((m) => m.reply(bytes('local')));
      });
      endpointUri = await endpoint.listenWebSocket('127.0.0.1', 0);
      client = node(
        resolver: EndpointResolver(endpointUri),
        defaultPayload: bytes('client token'),
      );
    });

    test('request and reply through the endpoint', () async {
      final talk = await client.openTalk(ServiceAddress(chat));
      // The backend sees the client's own payload and the instance the
      // proxy selected; the shard slot passes through.
      final who = await talk.request('WHO', Uint8List(0));
      expect(utf8.decode(who.payload), 'chat 7 null null client token');
      final sharded = await client.openTalk(ServiceAddress(chat), shard: 9);
      final whoSharded = await sharded.request('WHO', Uint8List(0));
      expect(utf8.decode(whoSharded.payload), 'chat 7 9 null client token');
      // Local services on the endpoint are not proxied.
      final api = await client.openTalk(ServiceAddress(Name('api')));
      expect((await api.request('X', Uint8List(0))).payload, bytes('local'));
      await talk.close();
      await sharded.close();
      await api.close();
    });

    test('stream through the endpoint', () async {
      final talk = await client.openTalk(ServiceAddress(chat, 7));
      final stream = talk.streamRequest('COUNT', Uint8List(0));
      final items = await stream.items
          .map((m) => utf8.decode(m.payload))
          .toList();
      expect(items, ['1', '2', '3']);
      expect((await stream.done).payload, bytes('done'));
      await talk.close();
    });

    test('rejections', () async {
      Future<Status> statusOf(String type, {int instance = 0}) async {
        final channel = await client.openChannel(
          ServiceAddress(Name(type), instance),
        );
        return channel.done;
      }

      expect(await statusOf('admin'), hasCode(StatusCode.permissionDenied));
      expect(await statusOf('void'), hasCode(StatusCode.notFound));
      expect(await statusOf('chat', instance: 8), hasCode(StatusCode.notFound));
      expect(await statusOf('down'), hasCode(StatusCode.unavailable));
      final untyped = await client.openChannelAt(endpointUri, ChannelAddress());
      expect(await untyped.done, hasCode(StatusCode.permissionDenied));
    });

    test('a channel without a type is not found when allowed', () async {
      final open = node();
      open.catchAll = proxyHandler(open);
      final uri = await open.listenTcp('127.0.0.1', 0);
      final channel = await client.openChannelAt(uri, ChannelAddress());
      expect(await channel.done, hasCode(StatusCode.notFound));
      // No resolver and no host hint support: the proxy cannot forward,
      // which the client sees as UNAVAILABLE.
      final typed = await client.openChannelAt(uri, ChannelAddress(type: chat));
      final status = await typed.done;
      expect(status, hasCode(StatusCode.unavailable));
      expect(status.reason, 'unavailable');
    });

    test('backend close status reaches the client', () async {
      final talk = await client.openTalk(ServiceAddress(chat));
      talk.send('KILL', Uint8List(0));
      expect(await talk.done, Status.of(StatusCode.aborted, 'killed'));
    });

    test('client close status reaches the backend', () async {
      final talk = await client.openTalk(ServiceAddress(chat));
      await talk.request('WHO', Uint8List(0));
      await talk.close(Status.of(StatusCode.cancelled, 'leaving'));
      expect(
        await atBackend.single.channel.done,
        Status.of(StatusCode.cancelled, 'leaving'),
      );
    });

    test('backend connection loss is UNAVAILABLE at the client', () async {
      final accepted = backend.connections.first;
      final talk = await client.openTalk(ServiceAddress(chat));
      await talk.request('WHO', Uint8List(0));
      await (await accepted).close();
      expect(await talk.done, hasCode(StatusCode.unavailable));
    });

    test('backend shutdown is GOING_AWAY at the client', () async {
      final talk = await client.openTalk(ServiceAddress(chat));
      await talk.request('WHO', Uint8List(0));
      final pending = expectLater(
        talk.request('NEVER', Uint8List(0)),
        throwsCode(StatusCode.goingAway),
      );
      await backend.close();
      await pending;
      expect(await talk.done, hasCode(StatusCode.goingAway));
    });

    test('host hint relay', () async {
      final relay = node(allowHostHint: true);
      relay.catchAll = proxyHandler(relay);
      final relayUri = await relay.listenTcp('127.0.0.1', 0);
      for (final hint in [
        '127.0.0.1:${backendUri.port}',
        'tcp://127.0.0.1:${backendUri.port}',
      ]) {
        final talk = await client.openTalkAt(
          relayUri,
          ChannelAddress(type: chat, instance: 7, host: hint),
        );
        final who = await talk.request('WHO', Uint8List(0));
        // The relay strips the hint and keeps everything else.
        expect(utf8.decode(who.payload), 'chat 7 null null client token');
        await talk.close();
      }
      final bad = await client.openChannelAt(
        relayUri,
        ChannelAddress(type: chat, host: 'tcp://'),
      );
      expect(await bad.done, hasCode(StatusCode.invalidArgument));
      final deadSocket = await ServerSocket.bind('127.0.0.1', 0);
      final deadPort = deadSocket.port;
      await deadSocket.close();
      final dead = await client.openChannelAt(
        relayUri,
        ChannelAddress(type: chat, host: '127.0.0.1:$deadPort'),
      );
      expect(await dead.done, hasCode(StatusCode.unavailable));
    });

    test('rejections carry no detail about the mesh', () async {
      final down = await client.openChannel(ServiceAddress(Name('down')));
      final downStatus = await down.done;
      expect(downStatus, hasCode(StatusCode.unavailable));
      expect(downStatus.reason, 'unavailable');
      final missing = await client.openChannel(ServiceAddress(chat, 8));
      final missingStatus = await missing.done;
      expect(missingStatus, hasCode(StatusCode.notFound));
      expect(missingStatus.reason, 'not found');
      final denied = await client.openChannel(ServiceAddress(Name('admin')));
      expect((await denied.done).reason, 'permission denied');
      for (final status in [downStatus, missingStatus]) {
        expect(status.reason, isNot(contains('127.0.0.1')));
        expect(status.reason, isNot(contains('${backendUri.port}')));
        expect(status.reason, isNot(contains('tcp')));
      }
    });

    test('the default allow refuses reserved types', () async {
      final ns = Name('_ns');
      backend.registerService(ns, (incoming) {
        incoming.channel.send(bytes('naming'));
        unawaited(incoming.channel.close());
      }, instance: 1);
      final table = StaticResolver([
        ServiceRecord(ServiceAddress(ns, 1), endpoints: [backendUri]),
        ServiceRecord(ServiceAddress(chat, 7), endpoints: [backendUri]),
      ]);
      addTearDown(table.close);
      final open = node();
      open.catchAll = proxyHandler(open, resolver: table);
      final openUri = await open.listenTcp('127.0.0.1', 0);
      final refused = await client.openChannelAt(
        openUri,
        ChannelAddress(type: ns),
      );
      expect(await refused.done, hasCode(StatusCode.permissionDenied));
      final talk = await client.openTalkAt(openUri, ChannelAddress(type: chat));
      expect((await talk.request('WHO', Uint8List(0))).payload, isNotEmpty);
      await talk.close();
      // Proxying a reserved type takes an explicit allow.
      final explicit = node();
      explicit.catchAll = proxyHandler(
        explicit,
        resolver: table,
        allow: (address) => address.type == ns,
      );
      final explicitUri = await explicit.listenTcp('127.0.0.1', 0);
      final allowed = await client.openChannelAt(
        explicitUri,
        ChannelAddress(type: ns),
      );
      expect(await allowed.stream.first, bytes('naming'));
    });

    test('a record pointing back at the proxy is refused at once', () async {
      final table = StaticResolver();
      addTearDown(table.close);
      final loop = node(resolver: table);
      var hops = 0;
      final proxy = proxyHandler(loop, allow: (a) => a.type == chat);
      loop.catchAll = (incoming) {
        hops++;
        return proxy(incoming);
      };
      final tcp = await loop.listenTcp(InternetAddress.loopbackIPv4, 0);
      final ws = await loop.listenWebSocket('127.0.0.1', 0, path: '/mesh');
      table.add(ServiceRecord(ServiceAddress(chat, 9), endpoints: [tcp]));
      // Other spellings of the same listeners.
      table.add(
        ServiceRecord(
          ServiceAddress(chat, 10),
          endpoints: [
            Uri.parse('tcp://localhost:${tcp.port}'),
            Uri.parse('ws://127.0.0.1:${ws.port}/mesh/'),
          ],
        ),
      );
      final looping = node(resolver: EndpointResolver(tcp));
      for (final instance in [9, 10]) {
        hops = 0;
        final watch = Stopwatch()..start();
        final channel = await looping.openChannel(
          ServiceAddress(chat, instance),
        );
        final status = await channel.done;
        expect(status, hasCode(StatusCode.unavailable));
        expect(status.reason, 'unavailable');
        expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
        expect(hops, 1);
      }
      expect(loop.isOwnEndpoint(tcp), isTrue);
      expect(
        loop.isOwnEndpoint(Uri.parse('ws://localhost:${ws.port}/mesh')),
        isTrue,
      );
      expect(loop.isOwnEndpoint(ws.replace(path: '/other')), isFalse);
      expect(loop.isOwnEndpoint(backendUri), isFalse);
    });

    test('a host hint pointing at the relay itself is refused', () async {
      final relay = node(allowHostHint: true);
      var hops = 0;
      final proxy = proxyHandler(relay);
      relay.catchAll = (incoming) {
        hops++;
        return proxy(incoming);
      };
      final relayUri = await relay.listenTcp('0.0.0.0', 0);
      expect(
        relay.isOwnEndpoint(Uri.parse('tcp://127.0.0.1:${relayUri.port}')),
        isTrue,
      );
      for (final hint in [
        '127.0.0.1:${relayUri.port}',
        'tcp://localhost:${relayUri.port}',
      ]) {
        hops = 0;
        final channel = await client.openChannelAt(
          Uri.parse('tcp://127.0.0.1:${relayUri.port}'),
          ChannelAddress(type: chat, host: hint),
        );
        expect(await channel.done, hasCode(StatusCode.unavailable));
        expect(hops, 1);
      }
    });

    test('one client filling its allowance does not starve another', () async {
      // The backend accepts 4 channels on a connection and the proxy keeps
      // one connection to it; each client may hold 3.
      final smallBackend = Switchboard(
        muxOptions: fast.copyWith(maxChannels: 4),
      );
      addTearDown(smallBackend.close);
      final held = <IncomingChannel>[];
      smallBackend.registerService(Name('hold'), held.add, instance: 1);
      final smallUri = await smallBackend.listenTcp('127.0.0.1', 0);
      final table = StaticResolver([
        ServiceRecord(ServiceAddress(Name('hold'), 1), endpoints: [smallUri]),
      ]);
      addTearDown(table.close);
      final proxyNode = Switchboard(
        muxOptions: fast,
        maxConnectionsPerEndpoint: 1,
      );
      addTearDown(proxyNode.close);
      proxyNode.catchAll = proxyHandler(
        proxyNode,
        resolver: table,
        maxChannelsPerConnection: 3,
      );
      final proxyUri = await proxyNode.listenTcp('127.0.0.1', 0);
      // Warm up the proxy's connection so that the backend's LIMITS are
      // known.
      final warm = await client.openChannelAt(
        proxyUri,
        ChannelAddress(type: Name('hold')),
      );
      while (held.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      await held.single.channel.close();
      await warm.done;
      held.clear();

      final greedy = node();
      final greedyChannels = [
        for (var i = 0; i < 5; i++)
          await greedy.openChannelAt(
            proxyUri,
            ChannelAddress(type: Name('hold')),
          ),
      ];
      final refused = await Future.wait([
        for (final channel in greedyChannels.skip(3)) channel.done,
      ]);
      expect(refused, everyElement(hasCode(StatusCode.resourceExhausted)));
      while (held.length < 3) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      // Another client still gets through.
      final polite = node();
      final channel = await polite.openChannelAt(
        proxyUri,
        ChannelAddress(type: Name('hold')),
      );
      while (held.length < 4) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      held.last.channel.send(bytes('served'));
      expect(await channel.stream.first, bytes('served'));
      // A channel of the greedy client that ends frees its allowance, once
      // the proxy has closed both sides of it.
      final toBackend = await proxyNode.connect(smallUri);
      expect(toBackend.openChannelCount, 4);
      await greedyChannels.first.close();
      while (toBackend.openChannelCount > 3) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      await pumpEventQueue();
      final more = await greedy.openChannelAt(
        proxyUri,
        ChannelAddress(type: Name('hold')),
      );
      while (held.length < 5) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      held.last.channel.send(bytes('again'));
      expect(await more.stream.first, bytes('again'));
    });

    test('a backend GOAWAY between connect and OPEN is retried once', () async {
      final accepted = <MuxConnection>[];
      final sub = backend.connections.listen(accepted.add);
      addTearDown(sub.cancel);
      final table = StaticResolver([
        ServiceRecord(ServiceAddress(chat, 7), endpoints: [backendUri]),
      ]);
      addTearDown(table.close);
      final racing = RacingSwitchboard();
      addTearDown(racing.close);
      racing.catchAll = proxyHandler(racing, resolver: table);
      final racingUri = await racing.listenTcp('127.0.0.1', 0);
      // The proxy's pooled connection to the backend.
      final warm = await client.openTalkAt(
        racingUri,
        ChannelAddress(type: chat),
      );
      await warm.request('WHO', Uint8List(0));
      await warm.close();
      final pooled = await racing.connect(backendUri);
      racing.beforeReturn = (connection) async {
        expect(connection, same(pooled));
        unawaited(accepted.single.goAway());
        while (!connection.peerGoingAway) {
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
      };
      final talk = await client.openTalkAt(
        racingUri,
        ChannelAddress(type: chat),
      );
      final who = await talk.request('WHO', Uint8List(0));
      expect(utf8.decode(who.payload), 'chat 7 null null client token');
      expect(accepted, hasLength(2));
      expect(racing.beforeReturn, isNull);
      await talk.close();
    });

    test('without allowHostHint the hint is ignored and stripped', () async {
      final talk = await client.openTalkAt(
        endpointUri,
        ChannelAddress(type: chat, host: 'tcp://10.0.0.1:1'),
      );
      final who = await talk.request('WHO', Uint8List(0));
      expect(utf8.decode(who.payload), 'chat 7 null null client token');
      await talk.close();
    });
  });
}
