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
      // No resolver and no host hint support.
      final typed = await client.openChannelAt(uri, ChannelAddress(type: chat));
      expect(await typed.done, hasCode(StatusCode.failedPrecondition));
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
