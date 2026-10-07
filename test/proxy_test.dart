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
  Future<MuxConnection> connect(Uri endpoint, {ChannelPolicy? policy}) async {
    final connection = await super.connect(endpoint, policy: policy);
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

  group('proxyHandler authorize', () {
    final chat = Name('chat');
    late List<IncomingChannel> atBackend;
    late StaticResolver backends;
    late Switchboard client;

    setUp(() async {
      atBackend = [];
      final backend = Switchboard(muxOptions: fast);
      addTearDown(backend.close);
      backend.registerService(chat, (incoming) {
        atBackend.add(incoming);
        incoming.talk().messages.listen((m) {
          final a = incoming.address;
          m.reply(bytes('${a.instance} ${a.shard} ${utf8.decode(a.payload)}'));
        });
      }, instance: 7);
      final backendUri = await backend.listenTcp('127.0.0.1', 0);
      backends = StaticResolver([
        ServiceRecord(ServiceAddress(chat, 7), endpoints: [backendUri]),
      ]);
      addTearDown(backends.close);
    });

    /// A proxy with [authorize], and [client] connected to it.
    Future<void> start(
      FutureOr<ChannelAddress?> Function(IncomingChannel incoming) authorize, {
      Duration authorizeTimeout = const Duration(seconds: 10),
      int budget = 256,
    }) async {
      final proxy = Switchboard(muxOptions: fast);
      addTearDown(proxy.close);
      proxy.catchAll = proxyHandler(
        proxy,
        authorize: authorize,
        authorizeTimeout: authorizeTimeout,
        resolver: backends,
        maxChannelsPerConnection: budget,
      );
      final uri = await proxy.listenTcp('127.0.0.1', 0);
      client = Switchboard(
        resolver: EndpointResolver(uri),
        muxOptions: fast,
        defaultPayload: bytes('token-5'),
      );
      addTearDown(client.close);
    }

    test('a rewritten shard and payload reach the backend; the client\'s '
        'data waits for the verdict', () async {
      final seen = <ChannelAddress>[];
      await start((incoming) async {
        seen.add(incoming.address);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        final token = utf8.decode(incoming.address.payload);
        final account = int.parse(token.split('-').last);
        return incoming.address.copyWith(
          shard: account,
          payload: bytes('verified $token'),
        );
      });
      final talk = await client.openTalk(ServiceAddress(chat));
      // Sent at once, while the proxy is still authorizing.
      final reply = await talk.request('WHO', Uint8List(0));
      expect(utf8.decode(reply.payload), '7 5 verified token-5');
      expect(seen.single.payload, bytes('token-5'));
      expect(seen.single.shard, isNull);
      expect(atBackend.single.address.shard, 5);
      await talk.close();
    });

    test('null is UNAUTHENTICATED, a throw PERMISSION_DENIED', () async {
      await start((incoming) async {
        switch (utf8.decode(incoming.address.payload)) {
          case 'anonymous':
            return null;
          case 'bad':
            throw const FormatException('bad credential');
          default:
            return incoming.address;
        }
      });
      Future<Status> statusWith(String payload) async {
        final channel = await client.openChannel(
          ServiceAddress(chat),
          payload: bytes(payload),
        );
        return channel.done;
      }

      final anonymous = await statusWith('anonymous');
      expect(anonymous, hasCode(StatusCode.unauthenticated));
      expect(anonymous.reason, 'unauthenticated');
      expect(await statusWith('bad'), hasCode(StatusCode.permissionDenied));
      expect(atBackend, isEmpty);
      // A synchronous answer works too.
      final talk = await client.openTalk(ServiceAddress(chat));
      final reply = await talk.request('WHO', Uint8List(0));
      expect(utf8.decode(reply.payload), '7 null token-5');
      await talk.close();
    });

    test('no answer within authorizeTimeout is UNAUTHENTICATED; pending '
        'authorizations count toward the budget', () async {
      final pending = Completer<ChannelAddress?>();
      await start(
        (_) => pending.future,
        authorizeTimeout: const Duration(milliseconds: 30),
        budget: 1,
      );
      final first = await client.openChannel(ServiceAddress(chat));
      await pumpEventQueue();
      final second = await client.openChannel(ServiceAddress(chat));
      expect(await second.done, hasCode(StatusCode.resourceExhausted));
      expect(await first.done, hasCode(StatusCode.unauthenticated));
      // The late answer is ignored.
      pending.complete(ChannelAddress(type: chat));
      await pumpEventQueue();
      expect(atBackend, isEmpty);
    });

    test(
      'a channel its client closed while being authorized is dropped',
      () async {
        final verdict = Completer<void>();
        final asked = Completer<void>();
        await start((incoming) async {
          asked.complete();
          await verdict.future;
          return incoming.address;
        });
        final channel = await client.openChannel(ServiceAddress(chat));
        await asked.future;
        await channel.close(Status.of(StatusCode.cancelled));
        verdict.complete();
        await pumpEventQueue();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(atBackend, isEmpty);
      },
    );
  });

  group('proxyHandler with slot tables', () {
    final zone = Name('zone');
    late Map<int, String> modes;
    late Map<int, List<ChannelAddress>> opened;
    late Map<int, List<Status>> ended;
    late _Locating table;
    late Switchboard proxy;
    late Switchboard client;

    /// The proxy, with [budget] channels per client connection, the other
    /// options of [proxyHandler] and [options] for its connections, and a
    /// client of it, over TCP or, with [memory], in memory.
    Future<void> startProxy({
      int budget = 256,
      bool revealOwners = false,
      bool allowExplicitInstance = false,
      int maxLocates = 32,
      Duration refill = const Duration(seconds: 1),
      MuxOptions options = fast,
      bool memory = false,
    }) async {
      proxy = Switchboard(
        muxOptions: options,
        slotRefreshTimeout: const Duration(milliseconds: 500),
      );
      addTearDown(proxy.close);
      proxy.catchAll = proxyHandler(
        proxy,
        resolver: table,
        maxChannelsPerConnection: budget,
        revealOwners: revealOwners,
        allowExplicitInstance: allowExplicitInstance,
        maxLocatesPerConnection: maxLocates,
        locateRefillInterval: refill,
      );
      final proxyUri = memory
          ? await proxy.listenMemory()
          : await proxy.listenTcp('127.0.0.1', 0);
      client = Switchboard(
        resolver: EndpointResolver(proxyUri),
        muxOptions: fast,
        defaultPayload: bytes('player'),
      );
      addTearDown(client.close);
    }

    /// A backend `zone/id` that, by its mode: greets (`<id> <shard>`) and
    /// echoes (`<id>:<data>`); rejects with MOVED at once
    /// (`moved:<owner>:<epoch>`, `moved:` naming none); rejects with MOVED
    /// once data arrived (`movedAfter:...`); greets, then rejects with
    /// MOVED (`greetMoved:...`); closes with RELOCATED once data arrived
    /// (`relocatedAfter:...`).
    Future<ServiceRecord> backend(int id) async {
      final node = Switchboard(muxOptions: fast);
      addTearDown(node.close);
      opened[id] = [];
      ended[id] = [];
      modes[id] = 'greet';
      node.registerService(zone, (incoming) {
        opened[id]!.add(incoming.address);
        final channel = incoming.channel;
        unawaited(channel.done.then(ended[id]!.add));
        final [mode, ...rest] = modes[id]!.split(':');
        final fields = rest.length == 2
            ? MovedStatus(owner: int.parse(rest[0]), epoch: int.parse(rest[1]))
            : MovedStatus.unknown;
        final moved = fields.toStatus();
        switch (mode) {
          case 'greet':
            channel.send(bytes('$id ${incoming.address.shard}'));
            channel.stream.listen(
              (d) => channel.send(bytes('$id:${utf8.decode(d)}')),
            );
          case 'moved':
            unawaited(incoming.reject(moved));
          case 'movedAfter':
            channel.stream.first.then((_) => incoming.reject(moved)).ignore();
          case 'greetMoved':
            channel.send(bytes('$id ${incoming.address.shard}'));
            unawaited(incoming.reject(moved));
          case 'relocatedAfter':
            channel.stream.first
                .then((_) => incoming.reject(fields.toStatus(relocated: true)))
                .ignore();
        }
      }, instance: id);
      final uri = await node.listenTcp('127.0.0.1', 0);
      return ServiceRecord(ServiceAddress(zone, id), endpoints: [uri]);
    }

    setUp(() async {
      modes = {};
      opened = {};
      ended = {};
      table = _Locating([await backend(1), await backend(2)]);
      addTearDown(table.close);
      table.defineSlots(SlotSpace(zone, count: 8, mode: SlotMode.managed));
      await startProxy();
    });

    /// A plain channel through the proxy: the client does not retry.
    Future<MuxChannel> open(int slot) =>
        client.openChannel(ServiceAddress(zone), shard: slot);

    test('routes to the owner, the old owner while migrating', () async {
      table
        ..setSlot(zone, 2, const SlotEntry.owned(2, epoch: 1))
        ..setSlot(zone, 3, const SlotEntry.migrating(1, 2, epoch: 4));
      final channel = await open(2);
      expect(await channel.stream.first, bytes('2 2'));
      expect(opened[2]!.single.instance, 2);
      expect(opened[2]!.single.payload, bytes('player'));
      await channel.close();
      final migrating = await open(3);
      expect(await migrating.stream.first, bytes('1 3'));
      await migrating.close();
    });

    test('a free slot: located in a managed space, UNAVAILABLE in a static '
        'one', () async {
      table.answer = (_) => const SlotEntry.owned(2, epoch: 1);
      final located = await open(5);
      expect(await located.stream.first, bytes('2 5'));
      expect(table.located, [5]);
      await located.close();
      table.defineSlots(SlotSpace(zone, count: 8, mode: SlotMode.static));
      final refused = await open(5);
      expect(await refused.done, hasCode(StatusCode.unavailable));
      expect(table.located, [5]);
    });

    test('MOVED before any data: retried once, unseen by the client', () async {
      await startProxy(budget: 1);
      table.setSlot(zone, 4, const SlotEntry.owned(1, epoch: 1));
      modes[1] = 'moved:2:2';
      final channel = await open(4);
      final answers = StreamQueue(channel.stream);
      expect(await answers.next, bytes('2 4'));
      channel.send(bytes('x'));
      expect(await answers.next, bytes('2:x'));
      expect(opened[1], hasLength(1));
      // The open payload is sent again, the instance set to the new owner.
      expect(opened[2]!.single.instance, 2);
      expect(opened[2]!.single.shard, 4);
      expect(opened[2]!.single.payload, bytes('player'));
      // The retried channel is the same channel for the client's budget.
      final second = await open(4);
      expect(await second.done, hasCode(StatusCode.resourceExhausted));
      await channel.close();
      expect(await channel.done, Status.ok);
    });

    test('MOVED naming no owner: the proxy asks', () async {
      table
        ..setSlot(zone, 4, const SlotEntry.owned(1, epoch: 1))
        ..answer = (_) => const SlotEntry.owned(2, epoch: 2);
      modes[1] = 'moved:';
      final channel = await open(4);
      expect(await channel.stream.first, bytes('2 4'));
      expect(table.located, [4]);
    });

    test('MOVED after data is forwarded to the client, owner hidden', () async {
      table.setSlot(zone, 4, const SlotEntry.owned(1, epoch: 1));
      modes[1] = 'movedAfter:2:2';
      final channel = await open(4);
      channel.send(bytes('x'));
      final status = await channel.done;
      expect(status, hasCode(StatusCode.moved));
      expect(MovedStatus.fromStatus(status), MovedStatus.unknown);
      expect(status.encode(), MovedStatus.unknown.encode());
      expect(opened[2], isEmpty);

      modes[1] = 'greetMoved:2:2';
      final greeted = await open(4);
      expect(await greeted.stream.toList(), [bytes('1 4')]);
      expect(await greeted.done, hasCode(StatusCode.moved));
      expect(opened[2], isEmpty);
    });

    test('RELOCATED reaches the client without its owner, never '
        'retried', () async {
      table.setSlot(zone, 4, const SlotEntry.owned(1, epoch: 1));
      modes[1] = 'relocatedAfter:0xFFFFFFFFFF80:0x80000000';
      final channel = await open(4);
      channel.send(bytes('x'));
      final status = await channel.done;
      expect(status, hasCode(StatusCode.relocated));
      expect(status.encode(), MovedStatus.unknown.encode(relocated: true));
      expect(opened[2], isEmpty);
      // Not retried by a client either.
      final slotChannel = await client.openChannelToSlot(zone, 4);
      slotChannel.send(bytes('y'));
      expect(await slotChannel.done, hasCode(StatusCode.relocated));
      expect(slotChannel.retried, isFalse);
      expect(opened[1], hasLength(2));
    });

    test('revealOwners: MOVED and RELOCATED byte for byte', () async {
      await startProxy(revealOwners: true);
      table.setSlot(zone, 4, const SlotEntry.owned(1, epoch: 1));
      modes[1] = 'relocatedAfter:0xFFFFFFFFFF80:0x80000000';
      final channel = await open(4);
      channel.send(bytes('x'));
      expect(
        (await channel.done).encode(),
        MovedStatus(
          owner: 0xFFFFFFFFFF80,
          epoch: 0x80000000,
        ).encode(relocated: true),
      );
      modes[1] = 'movedAfter:2:2';
      final moved = await open(4);
      moved.send(bytes('x'));
      final status = await moved.done;
      expect(MovedStatus.fromStatus(status), MovedStatus(owner: 2, epoch: 2));
    });

    test(
      'an explicit instance is routed by the table unless allowed',
      () async {
        table
          ..setSlot(zone, 4, const SlotEntry.migrating(1, 2, epoch: 4))
          ..setSlot(zone, 5, const SlotEntry.owned(1, epoch: 2));
        // The client names the instance that is taking the slot over.
        final overtaking = await client.openChannel(
          ServiceAddress(zone, 2),
          shard: 4,
        );
        expect(await overtaking.stream.first, bytes('1 4'));
        expect(opened[1]!.single.instance, 1);
        expect(opened[2], isEmpty);
        await overtaking.close();
        // No LOCATE for a slot with an owner.
        expect(table.located, isEmpty);
        await startProxy(allowExplicitInstance: true);
        final explicit = await client.openChannel(
          ServiceAddress(zone, 2),
          shard: 5,
        );
        expect(await explicit.stream.first, bytes('2 5'));
        expect(opened[2]!.single.instance, 2);
        await explicit.close();
      },
    );

    test('a resolver still syncing: the table routes once it answered, '
        'the instance the client named ignored, LOCATEs counted', () async {
      await startProxy(maxLocates: 1, refill: Duration.zero);
      table.answer = (_) => const SlotEntry.owned(2, epoch: 1);
      // Takes the only LOCATE token.
      final located = await open(3);
      expect(await located.stream.first, bytes('2 3'));
      await located.close();
      // The resolver has not synced: no table yet.
      table.removeSlots(zone);
      final gate = table.gate = Completer<void>();
      final named = await client.openChannel(ServiceAddress(zone, 1), shard: 1);
      await table.waiting.future;
      table.waiting = Completer<void>();
      final free = await open(2);
      await table.waiting.future;
      // It syncs: instance 2 owns slot 1, slot 2 is free.
      table
        ..defineSlots(SlotSpace(zone, count: 8, mode: SlotMode.managed))
        ..setSlot(zone, 1, const SlotEntry.owned(2, epoch: 1));
      gate.complete();
      expect(await named.stream.first, bytes('2 1'));
      expect(opened[1], isEmpty);
      expect(
        [for (final address in opened[2]!) (address.instance, address.shard)],
        [(2, 3), (2, 1)],
      );
      expect(await free.done, hasCode(StatusCode.resourceExhausted));
      expect(table.located, [3]);
      await named.close();
    });

    test('what the client sends during a retry is held up to the node\'s '
        'channel buffer limit, then RESOURCE_EXHAUSTED', () async {
      // In memory, so that each subframe reaches the proxy's pipe before
      // the next is sent: the client leg's own receive buffer, with the
      // same limit, never fills up.
      await startProxy(
        options: fast.copyWith(maxChannelBufferBytes: 1000),
        memory: true,
      );
      table.setSlot(zone, 4, const SlotEntry.owned(1, epoch: 1));
      modes[1] = 'moved:';
      final asked = Completer<void>();
      final answer = Completer<SlotEntry?>();
      addTearDown(() {
        if (!answer.isCompleted) {
          answer.complete(null);
        }
      });
      table.answer = (_) {
        asked.complete();
        return answer.future;
      };
      final channel = await open(4);
      await asked.future;
      // Each subframe counts its length plus 32: the fourth goes beyond.
      var sent = 0;
      while (channel.canSend && sent < 10) {
        channel.send(pattern(300, sent++));
        await Future<void>.delayed(Duration.zero);
      }
      final status = await channel.done;
      expect(status, hasCode(StatusCode.resourceExhausted));
      expect(status.reason, 'send buffer of 1000 bytes exceeded');
      expect(sent, lessThan(10));
      // The LOCATE answers after all: the new owner's channel is closed at
      // once.
      answer.complete(const SlotEntry.owned(2, epoch: 2));
      final watch = Stopwatch()..start();
      while (ended[2]!.isEmpty) {
        expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(ended[2]!.single, hasCode(StatusCode.resourceExhausted));
      expect(opened[2]!.single.instance, 2);
    });

    test('LOCATEs per client connection are bounded', () async {
      await startProxy(maxLocates: 2, refill: Duration.zero);
      table.answer = (_) => const SlotEntry.owned(2, epoch: 1);
      for (final slot in [1, 2]) {
        final located = await open(slot);
        expect(await located.stream.first, bytes('2 $slot'));
        await located.close();
      }
      // The table still shows no owner: the next one would ask again.
      final refused = await open(3);
      expect(await refused.done, hasCode(StatusCode.resourceExhausted));
      expect(table.located, [1, 2]);
      // A slot with an owner needs no LOCATE.
      table.setSlot(zone, 3, const SlotEntry.owned(1, epoch: 1));
      final owned = await open(3);
      expect(await owned.stream.first, bytes('1 3'));
      await owned.close();
      // Another client connection has its own budget.
      final other = Switchboard(resolver: client.resolver, muxOptions: fast);
      addTearDown(other.close);
      final fresh = await other.openChannel(ServiceAddress(zone), shard: 6);
      expect(await fresh.stream.first, bytes('2 6'));
      expect(table.located, [1, 2, 6]);
    });

    test('the LOCATE budget refills', () async {
      await startProxy(
        maxLocates: 1,
        refill: const Duration(milliseconds: 100),
      );
      table.answer = (_) => const SlotEntry.owned(2, epoch: 1);
      expect(await (await open(1)).stream.first, bytes('2 1'));
      expect(await (await open(2)).done, hasCode(StatusCode.resourceExhausted));
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(await (await open(2)).stream.first, bytes('2 2'));
      expect(table.located, [1, 2]);
    });

    test('a LOCATE that does not answer: UNAVAILABLE after '
        'slotRefreshTimeout', () async {
      final never = Completer<SlotEntry?>();
      addTearDown(() => never.complete());
      table.answer = (_) => never.future;
      final watch = Stopwatch()..start();
      final channel = await open(1);
      expect(await channel.done, hasCode(StatusCode.unavailable));
      expect(watch.elapsed, greaterThanOrEqualTo(Duration(milliseconds: 450)));
      expect(table.located, [1]);
    });

    test('MOVED with nowhere else to go is forwarded', () async {
      table.setSlot(zone, 4, const SlotEntry.owned(1, epoch: 1));
      modes[1] = 'moved:';
      table.answer = (_) => const SlotEntry.owned(1, epoch: 1);
      final channel = await open(4);
      expect(await channel.done, hasCode(StatusCode.moved));
      // Only once.
      modes
        ..[1] = 'moved:2:2'
        ..[2] = 'moved:1:3';
      final twice = await open(4);
      expect(await twice.done, hasCode(StatusCode.moved));
      expect(opened[2], hasLength(1));
    });

    test('a client reopening after MOVED reaches the owner', () async {
      table.setSlot(zone, 6, const SlotEntry.owned(1, epoch: 1));
      modes[1] = 'movedAfter:2:2';
      final channel = await client.openChannelToSlot(zone, 6);
      channel.send(bytes('x'));
      expect(await channel.done, hasCode(StatusCode.moved));
      expect(channel.retried, isFalse);
      // The client opens again; the proxy's table is still stale, and the
      // proxy's own retry takes it to the owner the rejection names.
      modes[1] = 'moved:2:2';
      table.setSlot(zone, 6, const SlotEntry.owned(1, epoch: 1));
      final again = await client.openChannelToSlot(zone, 6);
      expect(await again.stream.first, bytes('2 6'));
    });
  });

  group('proxyHandler: channels without a shard slot', () {
    // Table-routed: zone and room (allowed by the proxy below), lobby (its
    // allowNoSlot throws). No table: plain.
    final zone = Name('zone');
    final room = Name('room');
    final lobby = Name('lobby');
    final plain = Name('plain');
    late List<ChannelAddress> opened;
    late _Gated table;
    late Switchboard client;

    /// Instance [id] of every type: greets with `<type> <instance> <shard>`
    /// and closes.
    Future<List<ServiceRecord>> backend(int id) async {
      final node = Switchboard(muxOptions: fast);
      addTearDown(node.close);
      final uri = await node.listenTcp('127.0.0.1', 0);
      return [
        for (final type in [zone, room, lobby, plain])
          () {
            node.registerService(type, (incoming) {
              final a = incoming.address;
              opened.add(a);
              incoming.channel.send(
                bytes('${a.type} ${a.instance} ${a.shard}'),
              );
              unawaited(incoming.channel.close());
            }, instance: id);
            return ServiceRecord(ServiceAddress(type, id), endpoints: [uri]);
          }(),
      ];
    }

    /// A proxy with [allowNoSlot] and [authorize], and [client] of it.
    Future<void> startProxy({
      bool Function(Name type)? allowNoSlot,
      FutureOr<ChannelAddress?> Function(IncomingChannel incoming)? authorize,
    }) async {
      final proxy = Switchboard(muxOptions: fast);
      addTearDown(proxy.close);
      proxy.catchAll = proxyHandler(
        proxy,
        resolver: table,
        allowNoSlot: allowNoSlot,
        authorize: authorize,
      );
      final proxyUri = await proxy.listenTcp('127.0.0.1', 0);
      client = Switchboard(
        resolver: EndpointResolver(proxyUri),
        muxOptions: fast,
      );
      addTearDown(client.close);
    }

    setUp(() async {
      opened = [];
      table = _Gated([...await backend(1), ...await backend(2)]);
      addTearDown(table.close);
      for (final type in [zone, room, lobby]) {
        table.defineSlots(SlotSpace(type, count: 8, mode: SlotMode.static));
        table.setSlot(type, 5, const SlotEntry.owned(2, epoch: 1));
      }
    });

    /// The greeting of a new channel to [type] through the proxy, or its
    /// close status.
    Future<String> greeting(Name type, {int instance = 0, int? shard}) async {
      final channel = await client.openChannel(
        ServiceAddress(type, instance),
        shard: shard,
      );
      final frames = await channel.stream.toList();
      if (frames.isNotEmpty) {
        return utf8.decode(frames.first);
      }
      final status = await channel.done;
      return 'closed ${status.known?.name} ${status.reason}';
    }

    test('refused unless allowNoSlot admits the type; an admitted one goes '
        'round robin with the instance filled in', () async {
      await startProxy(
        allowNoSlot: (type) =>
            type == lobby ? throw StateError('broken filter') : type == room,
      );
      const denied = 'closed permissionDenied permission denied';
      expect(await greeting(zone), denied);
      expect(await greeting(zone, instance: 2), denied);
      expect(await greeting(lobby), denied);
      expect(opened, isEmpty);
      expect(
        [for (var i = 0; i < 4; i++) await greeting(room)],
        ['room 1 null', 'room 2 null', 'room 1 null', 'room 2 null'],
      );
      // An instance in the address is honoured, as for a type without a
      // slot table.
      expect(await greeting(room, instance: 2), 'room 2 null');
      // With a slot, every type is routed by its table.
      expect(await greeting(zone, shard: 5), 'zone 2 5');
      expect(await greeting(lobby, shard: 5), 'lobby 2 5');
      expect(await greeting(plain), 'plain 1 null');
    });

    test('the default refuses every table-routed type', () async {
      await startProxy();
      const denied = 'closed permissionDenied permission denied';
      expect(await greeting(zone), denied);
      expect(await greeting(room), denied);
      expect(opened, isEmpty);
      expect(await greeting(room, shard: 5), 'room 2 5');
      // Types without a slot table are not concerned.
      expect(await greeting(plain), 'plain 1 null');
      expect(await greeting(plain), 'plain 2 null');
    });

    test('a slot set by authorize routes the channel by the table', () async {
      await startProxy(
        authorize: (incoming) => incoming.address.type == zone
            ? incoming.address.copyWith(shard: 5)
            : incoming.address,
      );
      // The client sends no slot; the address authorize returns has one.
      expect(await greeting(zone), 'zone 2 5');
      expect(opened.single.shard, 5);
      expect(await greeting(room), 'closed permissionDenied permission denied');
    });

    test('the table is looked at once the resolver answers', () async {
      await startProxy(allowNoSlot: (type) => type == room);
      table.removeSlots(zone);
      final gate = table.gate = Completer<void>();
      final pending = greeting(zone);
      await table.waiting.future;
      // The resolver syncs, with a slot table for zone.
      table.defineSlots(SlotSpace(zone, count: 8, mode: SlotMode.static));
      gate.complete();
      expect(await pending, 'closed permissionDenied permission denied');
      expect(opened, isEmpty);
    });
  });
}

/// A static resolver whose LOCATE answers are scripted, and whose
/// [resolve] waits as [_Gated]'s.
class _Locating extends _Gated {
  _Locating(super.records);

  final List<int> located = [];
  FutureOr<SlotEntry?> Function(int slot) answer = (_) => null;

  @override
  Future<SlotEntry?> locateSlot(Name type, int slot) async {
    located.add(slot);
    return answer(slot);
  }
}

/// A static resolver whose [resolve] waits for [gate], if set: a resolver
/// that has not synced yet. [waiting] completes when a resolve waits.
class _Gated extends StaticResolver {
  _Gated(super.records);

  Completer<void>? gate;
  Completer<void> waiting = Completer<void>();

  @override
  Future<List<ServiceRecord>> resolve(Name type) async {
    final g = gate;
    if (g != null && !g.isCompleted) {
      if (!waiting.isCompleted) {
        waiting.complete();
      }
      await g.future;
    }
    return super.resolve(type);
  }
}
