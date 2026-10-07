// Connections a node initiates: their policy (outgoingPolicy, the
// endpointPolicy hook, asked about the endpoint as the pool keys it,
// connect's and dial's policy, in that order of precedence from last to
// first), un-pooled dials, and the application
// payload chosen per destination (credentialFor), which never falls back to
// the node's default payload. The consumer side of the untrusted worker
// fleet (wiki page "Switchboard Use Cases", entry 5).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:switchboard/switchboard.dart';
import 'package:test/test.dart';

const fast = MuxOptions(
  goAwayGrace: Duration(milliseconds: 100),
  keepAliveInterval: null,
);
const limit = Duration(seconds: 5);

final svc = Name('svc');
final back = Name('back');
final meshSecret = bytes('mesh-secret');

Uint8List bytes(String text) => Uint8List.fromList(utf8.encode(text));

String text(Uint8List data) => utf8.decode(data);

Matcher throwsCode(StatusCode code) =>
    throwsA(isA<SwitchboardException>().having((e) => e.code, 'code', code));

/// Whether [needle] occurs anywhere in [haystack].
bool containsBytes(Uint8List haystack, Uint8List needle) {
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    var match = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        match = false;
        break;
      }
    }
    if (match) {
      return true;
    }
  }
  return false;
}

/// A node closed after the test.
Switchboard node({
  Resolver? resolver,
  Uint8List? defaultPayload,
  ChannelPolicy? outgoingPolicy,
  EndpointPolicy? endpointPolicy,
  EndpointCredential? credentialFor,
}) {
  final s = Switchboard(
    resolver: resolver,
    defaultPayload: defaultPayload,
    muxOptions: fast,
    outgoingPolicy: outgoingPolicy,
    endpointPolicy: endpointPolicy,
    credentialFor: credentialFor,
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
  final frames = await channel.stream.toList().timeout(limit);
  final status = await channel.done;
  if (frames.isEmpty) {
    return 'closed ${status.known?.name ?? status.code} ${status.reason}';
  }
  return text(frames.single);
}

/// A node that records the OPEN payloads it receives (raw, as on the
/// wire) and answers every channel with its name.
class Target {
  Target(this.name, [this.id = 1]);

  final String name;
  final int id;
  late final Switchboard sb;
  late final Uri uri;
  final List<Uint8List> raw = [];
  final List<MuxConnection> accepted = [];

  /// The application payloads, as text.
  List<String> get payloads => [
    for (final open in raw) text(ChannelAddress.decode(open).payload),
  ];

  ServiceRecord record({Uint8List? metadata}) => ServiceRecord(
    ServiceAddress(svc, id),
    endpoints: [uri],
    metadata: metadata,
  );

  Future<void> start() async {
    sb = node();
    sb.registerService(svc, (incoming) {
      raw.add(incoming.channel.openPayload);
      tagged(name)(incoming);
    }, acceptAnyInstance: true);
    final sub = sb.connections.listen(accepted.add);
    addTearDown(sub.cancel);
    uri = await sb.listenMemory();
  }

  /// Pushes a channel to [back] on the connection the peer accepted
  /// [index]th, and reads the answer.
  Future<String> push([int index = 0]) =>
      tagOf(sb.openChannelOn(accepted[index], ChannelAddress(type: back)));
}

void main() {
  group('outgoing policy', () {
    late Target server;

    setUp(() async {
      server = Target('server');
      await server.start();
    });

    /// A client with a local service [back], connected to the server with
    /// [policy]; returns what the server's push got.
    Future<String> pushed(Switchboard client, {ChannelPolicy? policy}) async {
      client.registerService(back, tagged('back'));
      await client.connect(server.uri, policy: policy);
      await expectLater(
        Future.doWhile(() async {
          await Future<void>.delayed(const Duration(milliseconds: 1));
          return server.accepted.isEmpty;
        }).timeout(limit),
        completes,
      );
      return server.push();
    }

    const refused = 'closed permissionDenied permission denied';

    test('none: channels the peer pushes are dispatched', () async {
      expect(await pushed(node()), 'back');
    });

    test('outgoingPolicy applies to every initiated connection', () async {
      expect(
        await pushed(node(outgoingPolicy: ChannelPolicies.denyAll)),
        refused,
      );
    });

    test('endpointPolicy chooses by endpoint', () async {
      final seen = <Uri>[];
      final client = node(
        endpointPolicy: (endpoint) {
          seen.add(endpoint);
          return ChannelPolicies.denyAll;
        },
      );
      expect(await pushed(client), refused);
      expect(seen, [server.uri]);
    });

    test('endpointPolicy sees the endpoint as the pool keys it: every '
        'spelling gets the same policy', () async {
      final seen = <Uri>[];
      final client = node(
        outgoingPolicy: ChannelPolicies.denyAll,
        endpointPolicy: (endpoint) {
          seen.add(endpoint);
          return endpoint == server.uri ? ChannelPolicies.allowAll : null;
        },
      );
      client.registerService(back, tagged('back'));
      // A mem endpoint is its id: port, path, query and fragment ignored.
      final spelled = server.uri.replace(
        port: 7,
        path: '/x',
        query: 'q',
        fragment: 'svc/1',
      );
      await client.dial(spelled);
      await client.connect(spelled);
      expect(seen, [server.uri, server.uri]);
      await expectLater(
        Future.doWhile(() async {
          await Future<void>.delayed(const Duration(milliseconds: 1));
          return server.accepted.length < 2;
        }).timeout(limit),
        completes,
      );
      expect(await server.push(0), 'back');
      expect(await server.push(1), 'back');
      // WebSocket: the default port and path filled in, the fragment
      // dropped; both spellings share the pooled connection.
      final ws = node();
      ws.registerService(svc, tagged('ws'));
      final uri = await ws.listenWebSocket(InternetAddress.loopbackIPv4, 0);
      seen.clear();
      final first = await client.connect(
        Uri.parse('ws://127.0.0.1:${uri.port}#svc/1'),
      );
      final second = await client.connect(
        Uri.parse('WS://127.0.0.1:${uri.port}/'),
      );
      expect(second, same(first));
      await client.dial(Uri.parse('ws://127.0.0.1:${uri.port}/#x'));
      expect(seen, [
        Uri.parse('ws://127.0.0.1:${uri.port}/'),
        Uri.parse('ws://127.0.0.1:${uri.port}/'),
      ]);
    });

    test('connect(policy:) applies to that connection', () async {
      expect(await pushed(node(), policy: ChannelPolicies.denyAll), refused);
    });

    test('precedence: endpointPolicy over outgoingPolicy', () async {
      expect(
        await pushed(
          node(
            outgoingPolicy: ChannelPolicies.denyAll,
            endpointPolicy: (_) => ChannelPolicies.allowAll,
          ),
        ),
        'back',
      );
    });

    test(
      'precedence: a null endpointPolicy leaves it to outgoingPolicy',
      () async {
        expect(
          await pushed(
            node(
              outgoingPolicy: ChannelPolicies.denyAll,
              endpointPolicy: (_) => null,
            ),
          ),
          refused,
        );
      },
    );

    test('precedence: an explicit policy over endpointPolicy', () async {
      expect(
        await pushed(
          node(endpointPolicy: (_) => ChannelPolicies.denyAll),
          policy: ChannelPolicies.allowAll,
        ),
        'back',
      );
    });

    test('a throwing endpointPolicy refuses everything', () async {
      expect(
        await pushed(node(endpointPolicy: (_) => throw StateError('broken'))),
        refused,
      );
    });

    test('an outgoing policy that allows some types', () async {
      final client = node(outgoingPolicy: ChannelPolicies.allowTypes({back}));
      expect(await pushed(client), 'back');
      client.registerService(Name('other'), tagged('other'));
      expect(
        await tagOf(
          server.sb.openChannelOn(
            server.accepted.single,
            ChannelAddress(type: Name('other')),
          ),
        ),
        refused,
      );
    });

    test('connections are pooled per explicit policy', () async {
      final client = node();
      final plain = await client.connect(server.uri);
      expect(await client.connect(server.uri), same(plain));
      final strict = await client.connect(
        server.uri,
        policy: ChannelPolicies.denyAll,
      );
      expect(strict, isNot(same(plain)));
      expect(
        await client.connect(server.uri, policy: ChannelPolicies.denyAll),
        same(strict),
      );
      expect(await client.connect(server.uri), same(plain));
    });

    test('dial: not pooled, adopted for dispatch, policy, GOAWAY on '
        'close', () async {
      final client = node(outgoingPolicy: ChannelPolicies.denyAll);
      client.registerService(back, tagged('back'));
      final reported = <MuxConnection>[];
      final sub = client.connections.listen(reported.add);
      addTearDown(sub.cancel);
      final pooled = await client.connect(server.uri);
      final first = await client.dial(server.uri);
      final second = await client.dial(
        server.uri,
        policy: ChannelPolicies.allowAll,
      );
      expect(first, isNot(same(pooled)));
      expect(second, isNot(same(first)));
      expect(await client.connect(server.uri), same(pooled));
      expect(first.isInitiator, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(reported, [pooled, first, second]);
      expect(server.accepted, hasLength(3));
      expect(await server.push(1), refused);
      expect(await server.push(2), 'back');
      // Channels opened on a dialled connection follow the payload rules.
      final channel = client.openChannelOn(first, ChannelAddress(type: svc));
      expect(await tagOf(channel), 'server');
      await client.close();
      expect(await first.done.timeout(limit), isA<Status>());
      expect(await second.done.timeout(limit), isA<Status>());
      await expectLater(
        client.dial(server.uri),
        throwsCode(StatusCode.failedPrecondition),
      );
    });

    test('dial fails like connect', () async {
      final client = node();
      await expectLater(
        client.dial(Uri.parse('mem://nobody-listens-here')),
        throwsCode(StatusCode.unavailable),
      );
      await expectLater(
        client.dial(Uri.parse('foo://x')),
        throwsCode(StatusCode.unimplemented),
      );
    });

    test('ChannelPolicies.denyAll refuses everything', () async {
      final (a, _) = MemoryTransport.pair();
      final connection = MuxConnection(a, isInitiator: true, options: fast);
      addTearDown(connection.close);
      expect(ChannelPolicies.denyAll(ChannelAddress(), connection), isFalse);
      expect(
        ChannelPolicies.denyAll(ChannelAddress(type: svc), connection),
        isFalse,
      );
    });
  });

  group('credentialFor', () {
    late Target a;
    late Target b;
    late Target c;
    late StaticResolver resolver;
    late List<(Uri, ServiceRecord?)> calls;

    setUp(() async {
      a = Target('A', 1);
      b = Target('B', 2);
      c = Target('C', 3);
      await a.start();
      await b.start();
      await c.start();
      resolver = StaticResolver([a.record(), b.record(), c.record()]);
      addTearDown(resolver.close);
      calls = [];
    });

    /// A consumer whose hook knows the keys of A and B, not C.
    Switchboard consumer({bool async = false}) => node(
      resolver: resolver,
      defaultPayload: meshSecret,
      credentialFor: (endpoint, record) {
        calls.add((endpoint, record));
        final key = endpoint == a.uri
            ? bytes('key-a')
            : endpoint == b.uri
            ? bytes('key-b')
            : null;
        return async
            ? Future<Uint8List?>.delayed(Duration.zero, () => key)
            : key;
      },
    );

    void expectNoMeshSecret() {
      for (final peer in [a, b, c]) {
        for (final open in peer.raw) {
          expect(containsBytes(open, meshSecret), isFalse, reason: peer.name);
        }
      }
    }

    for (final async in [false, true]) {
      test('openChannelAt: the key of each endpoint, never the default '
          '(${async ? 'asynchronous' : 'synchronous'} hook)', () async {
        final client = consumer(async: async);
        final address = ChannelAddress(type: svc);
        expect(await tagOf(await client.openChannelAt(a.uri, address)), 'A');
        expect(await tagOf(await client.openChannelAt(b.uri, address)), 'B');
        expect(await tagOf(await client.openChannelAt(c.uri, address)), 'C');
        expect(a.payloads, ['key-a']);
        expect(b.payloads, ['key-b']);
        // Unknown to the hook: empty, not the default.
        expect(c.payloads, ['']);
        expect(calls, [(a.uri, null), (b.uri, null), (c.uri, null)]);
        expectNoMeshSecret();
      });

      test('openChannel and openTalk: the hook sees the selected record '
          '(${async ? 'asynchronous' : 'synchronous'} hook)', () async {
        final client = consumer(async: async);
        expect(
          await tagOf(await client.openChannel(ServiceAddress(svc, 1))),
          'A',
        );
        expect(
          await tagOf(await client.openChannel(ServiceAddress(svc, 2))),
          'B',
        );
        final talk = await client.openTalk(ServiceAddress(svc, 3));
        await talk.done.timeout(limit);
        expect(a.payloads, ['key-a']);
        expect(b.payloads, ['key-b']);
        expect(c.payloads, ['']);
        expect(calls.map((call) => call.$1), [a.uri, b.uri, c.uri]);
        expect(calls.map((call) => call.$2), [
          a.record(),
          b.record(),
          c.record(),
        ]);
        expectNoMeshSecret();
      });
    }

    test('an explicit payload wins and the hook is not asked', () async {
      final client = consumer();
      await tagOf(
        await client.openChannelAt(
          a.uri,
          ChannelAddress(type: svc, payload: bytes('explicit')),
        ),
      );
      await tagOf(
        await client.openChannel(
          ServiceAddress(svc, 2),
          payload: bytes('given'),
        ),
      );
      // An explicit empty payload for openChannel is sent as it is.
      await tagOf(
        await client.openChannel(ServiceAddress(svc, 2), payload: Uint8List(0)),
      );
      expect(a.payloads, ['explicit']);
      expect(b.payloads, ['given', '']);
      expect(calls, isEmpty);
    });

    test('per-worker keys from the record metadata', () async {
      resolver
        ..add(a.record(metadata: bytes('meta-a')))
        ..add(b.record(metadata: bytes('meta-b')));
      final client = node(
        resolver: resolver,
        defaultPayload: meshSecret,
        credentialFor: (endpoint, record) =>
            record != null && record.metadata.isNotEmpty
            ? record.metadata
            : null,
      );
      for (var i = 0; i < 2; i++) {
        await tagOf(await client.openChannel(ServiceAddress(svc, 1)));
        await tagOf(await client.openChannel(ServiceAddress(svc, 2)));
      }
      // Any instance: whichever is selected gets its own key.
      for (var i = 0; i < 3; i++) {
        await tagOf(await client.openChannel(ServiceAddress(svc)));
      }
      // No record (explicit endpoint): nothing.
      await tagOf(await client.openChannelAt(a.uri, ChannelAddress(type: svc)));
      expect(a.payloads, everyElement(isIn(['meta-a', ''])));
      expect(a.payloads.last, '');
      expect(a.payloads.where((p) => p == 'meta-a'), hasLength(3));
      expect(b.payloads, everyElement('meta-b'));
      expect(c.payloads, everyElement(''));
      expect(a.raw.length + b.raw.length + c.raw.length, 8);
      expectNoMeshSecret();
    });

    test('a record for any instance stands for the instance asked for, '
        'metadata included', () async {
      final seen = <ServiceRecord?>[];
      final client = node(
        resolver: StaticResolver([
          ServiceRecord(
            ServiceAddress(svc),
            endpoints: [a.uri],
            metadata: bytes('worker-key'),
          ),
        ]),
        defaultPayload: meshSecret,
        credentialFor: (endpoint, record) {
          seen.add(record);
          return record == null || record.metadata.isEmpty
              ? null
              : record.metadata;
        },
      );
      await tagOf(await client.openChannel(ServiceAddress(svc)));
      await tagOf(await client.openChannel(ServiceAddress(svc, 5)));
      expect(seen.map((r) => r?.address), [
        ServiceAddress(svc),
        ServiceAddress(svc, 5),
      ]);
      expect(seen.map((r) => r?.metadata), everyElement(bytes('worker-key')));
      expect(a.payloads, ['worker-key', 'worker-key']);
      expect(a.raw.map((open) => ChannelAddress.decode(open).instance), [0, 5]);
      expectNoMeshSecret();
    });

    test('openChannelOn: the hook for an initiated connection, empty on an '
        'accepted one, StateError for an asynchronous hook', () async {
      final client = consumer();
      final connection = await client.connect(a.uri);
      expect(
        await tagOf(
          client.openChannelOn(connection, ChannelAddress(type: svc)),
        ),
        'A',
      );
      expect(a.payloads, ['key-a']);
      expect(await client.payloadFor(connection), bytes('key-a'));
      // Accepted: no destination to choose a credential for.
      final server = node(
        defaultPayload: meshSecret,
        credentialFor: (_, _) => bytes('never'),
      );
      final uri = await server.listenMemory();
      final accepted = server.connections.first;
      a.sb.registerService(back, (incoming) {
        a.raw.add(incoming.channel.openPayload);
        tagged('A back')(incoming);
      });
      await a.sb.connect(uri);
      final pushed = server.openChannelOn(
        await accepted.timeout(limit),
        ChannelAddress(type: back),
      );
      expect(await tagOf(pushed), 'A back');
      expect(a.payloads.last, '');
      expect(await server.payloadFor(await accepted), isEmpty);
      // An asynchronous hook cannot serve this synchronous call.
      final asyncClient = consumer(async: true);
      final asyncConnection = await asyncClient.connect(b.uri);
      expect(
        () => asyncClient.openChannelOn(
          asyncConnection,
          ChannelAddress(type: svc),
        ),
        throwsStateError,
      );
      expect(await asyncClient.payloadFor(asyncConnection), bytes('key-b'));
      expectNoMeshSecret();
    });

    test('without the hook, the default payload as before', () async {
      final client = node(resolver: resolver, defaultPayload: meshSecret);
      await tagOf(await client.openChannel(ServiceAddress(svc, 1)));
      await tagOf(await client.openChannelAt(b.uri, ChannelAddress(type: svc)));
      final connection = await client.connect(c.uri);
      await tagOf(client.openChannelOn(connection, ChannelAddress(type: svc)));
      expect(a.payloads, ['mesh-secret']);
      expect(b.payloads, ['mesh-secret']);
      expect(c.payloads, ['mesh-secret']);
      expect(await client.payloadFor(connection), meshSecret);
    });

    test('a hook that throws fails the open', () async {
      final client = node(
        resolver: resolver,
        defaultPayload: meshSecret,
        credentialFor: (_, _) => throw StateError('no vault'),
      );
      await expectLater(
        client.openChannel(ServiceAddress(svc, 1)),
        throwsStateError,
      );
      await expectLater(
        client.openChannelAt(a.uri, ChannelAddress(type: svc)),
        throwsStateError,
      );
      expect(a.raw, isEmpty);
    });

    test('the proxy forwards the client payload, never the hook or the '
        'default', () async {
      final proxy = node(
        defaultPayload: meshSecret,
        credentialFor: (_, _) => bytes('proxy-key'),
      );
      proxy.resolver = StaticResolver([a.record()]);
      proxy.catchAll = proxyHandler(proxy);
      final uri = await proxy.listenMemory();
      final client = node();
      await tagOf(
        await client.openChannelAt(
          uri,
          ChannelAddress(type: svc, payload: bytes('client-token')),
        ),
      );
      await tagOf(await client.openChannelAt(uri, ChannelAddress(type: svc)));
      expect(a.payloads, ['client-token', '']);
      expectNoMeshSecret();
    });
  });

  group('credentialFor and the MOVED retry', () {
    test('each owner gets its own key', () async {
      final owner1 = node();
      final owner2 = node();
      final seen = <String>[];
      owner1.registerService(svc, (incoming) {
        seen.add('1 ${text(incoming.address.payload)}');
        unawaited(incoming.reject(MovedStatus(owner: 2, epoch: 2).toStatus()));
      }, instance: 1);
      owner2.registerService(svc, (incoming) {
        seen.add('2 ${text(incoming.address.payload)}');
        tagged('owner 2')(incoming);
      }, instance: 2);
      final uri1 = await owner1.listenMemory();
      final uri2 = await owner2.listenMemory();
      final resolver = StaticResolver([
        ServiceRecord(ServiceAddress(svc, 1), endpoints: [uri1]),
        ServiceRecord(ServiceAddress(svc, 2), endpoints: [uri2]),
      ]);
      addTearDown(resolver.close);
      resolver
        ..defineSlots(SlotSpace(svc, count: 4))
        ..setSlot(svc, 1, const SlotEntry.owned(1, epoch: 1));
      final client = node(
        resolver: resolver,
        defaultPayload: meshSecret,
        credentialFor: (endpoint, record) =>
            bytes('key-${record?.address.instance}'),
      );
      final channel = await client.openChannelToSlot(svc, 1);
      expect(text(await channel.stream.first.timeout(limit)), 'owner 2');
      expect(channel.retried, isTrue);
      expect(seen, ['1 key-1', '2 key-2']);
      // With a payload, both get it.
      seen.clear();
      resolver.setSlot(svc, 1, const SlotEntry.owned(1, epoch: 3));
      final given = await client.openChannelToSlot(
        svc,
        1,
        payload: bytes('given'),
      );
      expect(text(await given.stream.first.timeout(limit)), 'owner 2');
      expect(seen, ['1 given', '2 given']);
    });
  });
}
