// Identity on Switchboard nodes (wiki page "Switchboard Identity and
// Credentials"): nodes identifying on the connections they initiate,
// verifiers on accepted and initiated connections, ChannelPolicies.scoped
// and requireIdentity, channels held until the peer identifies, and the
// failures of identification, over mem:// and tcp.

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

final npc = Name('npc');
final chat = Name('chat');
final naming = Name('_ns');

final meshKey = Uint8List.fromList(List.generate(32, (i) => i));
final authoritySeed = Uint8List.fromList(List.generate(32, (i) => 3 * i));
final rogueSeed = Uint8List.fromList(List.generate(32, (i) => 5 * i + 1));

late CredentialIssuer authority;
late CredentialIssuer rogue;
late CredentialIssuer hmac;
late HolderKey npcKey;
late HolderKey gateKey;
late HolderKey workerKey;

String text(Uint8List data) => utf8.decode(data);

Matcher throwsCode(StatusCode code) =>
    throwsA(isA<SwitchboardException>().having((e) => e.code, 'code', code));

Matcher hasCode(StatusCode code) =>
    isA<Status>().having((s) => s.known, 'known', code);

Future<void> until(bool Function() condition) async {
  final deadline = DateTime.now().add(limit);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition not met within $limit');
    }
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

Future<Credential> issue(
  String identity,
  HolderKey? key,
  List<Scope> scopes, {
  CredentialIssuer? by,
}) => (by ?? authority).issue(
  kind: CredentialKind.node,
  identity: identity,
  scopes: scopes,
  holderKey: key?.publicKey,
);

/// `npc-7`, which may open `npc` and nothing else.
Future<Credential> npcCredential({CredentialIssuer? by}) =>
    issue('npc-7', npcKey, [Scope.of(Right.open, 'npc')], by: by);

/// A worker: may register its type, open nothing.
Future<Credential> workerCredential() =>
    issue('worker-a1', workerKey, [Scope.of(Right.register, 'worker-*')]);

Future<CredentialVerifier> verifier() async {
  final v = CredentialVerifier();
  await v.addIssuer(authority);
  await v.addIssuer(hmac);
  return v;
}

/// A node closed after the test.
Future<Switchboard> node({
  Credential? credential,
  HolderKey? holderKey,
  bool verify = true,
  bool identifyOutgoing = true,
  bool Function(Uri endpoint)? identifyFor,
  Duration identityTimeout = limit,
  ChannelPolicy? outgoingPolicy,
  Resolver? resolver,
  bool requireNamedIdent = false,
  ExpectedIdentity? expectedIdentityFor,
}) async {
  final s = Switchboard(
    muxOptions: fast.copyWith(requireNamedIdent: requireNamedIdent),
    expectedIdentityFor: expectedIdentityFor,
    credential: credential,
    holderKey: holderKey,
    verifier: verify ? await verifier() : null,
    identifyOutgoing: identifyOutgoing,
    identifyFor: identifyFor,
    identityTimeout: identityTimeout,
    outgoingPolicy: outgoingPolicy,
    resolver: resolver,
  );
  addTearDown(s.close);
  return s;
}

/// A handler answering with the peer's identity and closing.
void answer(IncomingChannel incoming) {
  incoming.channel.send(
    Uint8List.fromList(
      utf8.encode(
        '${incoming.address.type} for '
        '${incoming.peerIdentity?.identity ?? 'nobody'}',
      ),
    ),
  );
  unawaited(incoming.channel.close());
}

/// What an [answer] handler said, or the close status.
Future<String> answerOf(MuxChannel channel) async {
  final frames = await channel.stream.toList().timeout(limit);
  final status = await channel.done.timeout(limit);
  if (frames.isEmpty) {
    return 'closed ${status.known?.name ?? status.code}';
  }
  return text(frames.single);
}

/// A server answering `npc`, `chat` and `_ns`, listening on [scheme] with
/// [policy].
Future<(Switchboard, Uri)> server(
  String scheme, {
  ChannelPolicy? policy,
  Credential? credential,
  HolderKey? holderKey,
  Duration identityTimeout = limit,
  bool requireNamedIdent = false,
}) async {
  final s = await node(
    credential: credential,
    holderKey: holderKey,
    identityTimeout: identityTimeout,
    requireNamedIdent: requireNamedIdent,
  );
  for (final type in [npc, chat, naming]) {
    s.registerService(type, answer);
  }
  final uri = scheme == 'tcp'
      ? await s.listenTcp('127.0.0.1', 0, policy: policy)
      : await s.listenMemory(policy: policy);
  return (s, uri);
}

Future<String> open(Switchboard client, Uri endpoint, Name type) async =>
    answerOf(await client.openChannelAt(endpoint, ChannelAddress(type: type)));

void main() {
  setUpAll(() async {
    authority = await CredentialIssuer.ed25519FromSeed(
      Name('auth1'),
      authoritySeed,
    );
    // Another key pair claiming the authority's key id.
    rogue = await CredentialIssuer.ed25519FromSeed(Name('auth1'), rogueSeed);
    hmac = CredentialIssuer.hmac(Name('mesh1'), meshKey);
    npcKey = await HolderKey.generate();
    gateKey = await HolderKey.generate();
    workerKey = await HolderKey.generate();
  });

  for (final scheme in ['mem', 'tcp']) {
    group('over $scheme', () {
      test('mutual identity', () async {
        final (b, uri) = await server(
          scheme,
          credential: await issue('gate', gateKey, [Scope.of(Right.open, '*')]),
          holderKey: gateKey,
        );
        // The server identifies on the connections whose peers ask.
        final accepted = <MuxConnection>[];
        b.connections.listen((connection) {
          accepted.add(connection);
          connection.identityRequested.then((_) => b.identifyOn(connection));
        });
        final a = await node(
          credential: await npcCredential(),
          holderKey: npcKey,
        );
        final connection = await a.connect(uri);
        // connect() returned after the server confirmed the IDENT.
        expect(accepted.single.peerIdentity?.identity, 'npc-7');
        expect(accepted.single.peerIdentity?.provedPossession, isTrue);
        final gate = await connection.peerIdentified.timeout(limit);
        expect(gate.identity, 'gate');
        expect(connection.peerIdentity, same(gate));
        expect(await open(a, uri, npc), 'npc for npc-7');
      });

      test('a scoped policy admits open-scoped types only', () async {
        final (_, uri) = await server(scheme, policy: ChannelPolicies.scoped());
        final a = await node(
          credential: await npcCredential(),
          holderKey: npcKey,
        );
        expect(await open(a, uri, npc), 'npc for npc-7');
        expect(await open(a, uri, chat), 'closed permissionDenied');
        // The naming service checks the credential itself.
        expect(await open(a, uri, naming), '_ns for npc-7');
      });

      test('a worker, identified, can open nothing', () async {
        final (_, uri) = await server(scheme, policy: ChannelPolicies.scoped());
        final w = await node(
          credential: await workerCredential(),
          holderKey: workerKey,
        );
        expect(await open(w, uri, npc), 'closed permissionDenied');
        expect(await open(w, uri, chat), 'closed permissionDenied');
        expect(await open(w, uri, naming), '_ns for worker-a1');
      });

      test('a bearer credential works', () async {
        final (_, uri) = await server(scheme, policy: ChannelPolicies.scoped());
        final a = await node(
          credential: await hmac.issue(
            kind: CredentialKind.node,
            identity: 'npc-8',
            scopes: [Scope.of(Right.open, 'npc')],
          ),
        );
        expect(await open(a, uri, npc), 'npc for npc-8');
        expect(await open(a, uri, chat), 'closed permissionDenied');
      });

      test('a credential of another authority fails the connect with '
          'UNAUTHENTICATED', () async {
        final (b, uri) = await server(scheme, policy: ChannelPolicies.scoped());
        final ended = <Future<Status>>[];
        b.connections.listen((c) => ended.add(c.done));
        final a = await node(
          credential: await npcCredential(by: rogue),
          holderKey: npcKey,
        );
        await expectLater(
          a.connect(uri),
          throwsCode(StatusCode.unauthenticated),
        );
        await expectLater(
          a.openChannelAt(uri, ChannelAddress(type: npc)),
          throwsCode(StatusCode.unauthenticated),
        );
        expect(ended, hasLength(2));
        for (final done in ended) {
          expect(
            await done.timeout(limit),
            hasCode(StatusCode.unauthenticated),
          );
        }
      });

      test('a forged IDENT gets GOAWAY UNAUTHENTICATED', () async {
        final (_, uri) = await server(scheme);
        final bytes = (await npcCredential()).encode();
        bytes[bytes.length - 1] ^= 0x01;
        final a = await node(
          credential: Credential.decode(bytes),
          holderKey: npcKey,
        );
        final dialled = a.connections.first;
        await expectLater(
          a.connect(uri),
          throwsCode(StatusCode.unauthenticated),
        );
        final connection = await dialled.timeout(limit);
        expect(
          await connection.peerGoAwayStatus.timeout(limit),
          hasCode(StatusCode.unauthenticated),
        );
        expect(
          await connection.done.timeout(limit),
          hasCode(StatusCode.goingAway),
        );
      });
    });
  }

  group('holding', () {
    test('a channel arriving before IDENT is held, then admitted', () async {
      final (_, uri) = await server('mem', policy: ChannelPolicies.scoped());
      final a = await node(
        credential: await npcCredential(),
        holderKey: npcKey,
        identifyOutgoing: false,
      );
      final connection = await a.connect(uri);
      final channel = a.openChannelOn(connection, ChannelAddress(type: npc));
      final answered = answerOf(channel);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(channel.state, MuxChannelState.open);
      await a.identifyOn(connection);
      expect(await answered, 'npc for npc-7');
      // Held channels are evaluated again: a type out of scope is refused
      // once the peer has identified.
      expect(
        await answerOf(a.openChannelOn(connection, ChannelAddress(type: chat))),
        'closed permissionDenied',
      );
    });

    test(
      'a channel held past identityTimeout is refused UNAUTHENTICATED',
      () async {
        final (_, uri) = await server(
          'mem',
          policy: ChannelPolicies.scoped(),
          identityTimeout: const Duration(milliseconds: 100),
        );
        final a = await node();
        final watch = Stopwatch()..start();
        expect(await open(a, uri, npc), 'closed unauthenticated');
        expect(
          watch.elapsed,
          greaterThanOrEqualTo(const Duration(milliseconds: 90)),
        );
      },
    );

    test('without an identityTimeout nothing is held', () async {
      final (_, uri) = await server(
        'mem',
        policy: ChannelPolicies.requireIdentity(),
        identityTimeout: Duration.zero,
      );
      final a = await node();
      expect(await open(a, uri, npc), 'closed unauthenticated');
    });

    test('a held channel the peer closes is dropped', () async {
      final (_, uri) = await server('mem', policy: ChannelPolicies.scoped());
      final a = await node();
      final connection = await a.connect(uri);
      final channel = a.openChannelOn(connection, ChannelAddress(type: npc));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await channel.close().timeout(limit);
      expect(await channel.done, Status.ok);
    });
  });

  group('policies', () {
    test('requireIdentity, combined with denyReserved', () async {
      final (_, uri) = await server(
        'mem',
        policy: ChannelPolicies.all([
          ChannelPolicies.denyReserved,
          ChannelPolicies.requireIdentity(),
        ]),
      );
      final a = await node(
        credential: await npcCredential(),
        holderKey: npcKey,
      );
      expect(await open(a, uri, chat), 'chat for npc-7');
      expect(await open(a, uri, naming), 'closed permissionDenied');
    });

    test(
      'scoped without requireIdentity lets unidentified peers pass',
      () async {
        final (_, uri) = await server(
          'mem',
          policy: ChannelPolicies.scoped(requireIdentity: false),
        );
        final anonymous = await node();
        expect(await open(anonymous, uri, chat), 'chat for nobody');
        final a = await node(
          credential: await npcCredential(),
          holderKey: npcKey,
        );
        expect(await open(a, uri, chat), 'closed permissionDenied');
      },
    );

    test('scoped and requireIdentity are stable functions', () {
      expect(ChannelPolicies.scoped(), ChannelPolicies.scoped());
      expect(
        ChannelPolicies.scoped(requireIdentity: false),
        isNot(ChannelPolicies.scoped()),
      );
      expect(
        ChannelPolicies.requireIdentity(),
        ChannelPolicies.requireIdentity(),
      );
    });

    test('a worker is refused in the other direction too', () async {
      // The consumer dials the worker and identifies; the worker
      // identifies when asked; its channels back are checked by the
      // consumer's outgoing policy.
      final w = await node(
        credential: await workerCredential(),
        holderKey: workerKey,
      );
      final pushed = <Future<String>>[];
      w.connections.listen((connection) {
        connection.identityRequested.then((_) async {
          await w.identifyOn(connection);
          pushed.add(
            answerOf(w.openChannelOn(connection, ChannelAddress(type: npc))),
          );
        });
      });
      final workerUri = await w.listenMemory();
      final consumer = await node(
        credential: await npcCredential(),
        holderKey: npcKey,
        outgoingPolicy: ChannelPolicies.scoped(),
      );
      consumer.registerService(npc, answer);
      final connection = await consumer.connect(workerUri);
      expect(
        (await connection.peerIdentified.timeout(limit)).identity,
        'worker-a1',
      );
      await Future.doWhile(() async {
        await Future<void>.delayed(const Duration(milliseconds: 1));
        return pushed.isEmpty;
      }).timeout(limit);
      expect(await pushed.single, 'closed permissionDenied');
    });
  });

  group('identifying', () {
    test('identifyFor chooses the endpoints the node identifies to', () async {
      final (_, mesh) = await server('mem');
      final (_, outside) = await server('mem');
      final asked = <Uri>[];
      final a = await node(
        credential: await npcCredential(),
        holderKey: npcKey,
        identifyFor: (endpoint) {
          asked.add(endpoint);
          return endpoint == mesh;
        },
      );
      expect(await open(a, mesh, npc), 'npc for npc-7');
      expect(await open(a, outside, npc), 'npc for nobody');
      expect(asked, [mesh, outside]);
    });

    test('identifyOutgoing false, and a hook that throws', () async {
      final (_, uri) = await server('mem');
      final quiet = await node(
        credential: await npcCredential(),
        holderKey: npcKey,
        identifyOutgoing: false,
      );
      expect(await open(quiet, uri, npc), 'npc for nobody');
      final failing = await node(
        credential: await npcCredential(),
        holderKey: npcKey,
        identifyFor: (endpoint) => throw StateError('no'),
      );
      expect(await open(failing, uri, npc), 'npc for nobody');
    });

    test('a peer without a verifier ignores the IDENT', () async {
      final b = await node(verify: false);
      b.registerService(npc, answer);
      final uri = await b.listenMemory();
      final a = await node(
        credential: await npcCredential(),
        holderKey: npcKey,
      );
      expect(await open(a, uri, npc), 'npc for nobody');
    });

    test('a peer that never answers NONCE fails the connect', () async {
      // A peer that reads and ignores every frame, as one that does not
      // know NONCE (the embedded profile) does.
      final listener = await ServerSocket.bind('127.0.0.1', 0);
      addTearDown(listener.close);
      final peers = <StreamTransportChannel>[];
      listener.listen((socket) {
        final transport = StreamTransport.fromSocket(socket);
        peers.add(transport);
        transport.stream.listen((_) {});
      });
      final a = await node(
        credential: await npcCredential(),
        holderKey: npcKey,
        identityTimeout: const Duration(milliseconds: 100),
      );
      await expectLater(
        a.connect(Uri.parse('tcp://127.0.0.1:${listener.port}')),
        throwsCode(StatusCode.unauthenticated),
      );
      for (final peer in peers) {
        await peer.sink.close();
      }
    });

    test('the credential can be replaced; identifyOn presents it', () async {
      final (b, uri) = await server('mem', policy: ChannelPolicies.scoped());
      final accepted = <MuxConnection>[];
      b.connections.listen(accepted.add);
      final a = await node(
        credential: await npcCredential(),
        holderKey: npcKey,
      );
      final connection = await a.connect(uri);
      a.credential = await issue('npc-7', npcKey, [
        Scope.of(Right.open, 'npc'),
        Scope.of(Right.open, 'chat'),
      ]);
      expect(await open(a, uri, chat), 'closed permissionDenied');
      await a.identifyOn(connection);
      expect(accepted.single.peerIdentity!.scopes, hasLength(2));
      expect(await open(a, uri, chat), 'chat for npc-7');
      expect(
        () => a.credential = Credential.decode(
          (accepted.single.peerIdentity!.credential).encode(),
        ),
        returnsNormally,
      );
      final other = await workerCredential();
      expect(() => a.credential = other, throwsArgumentError);
      expect(() => Switchboard(credential: other), throwsArgumentError);
      expect(() => Switchboard().identifyOn(connection), throwsStateError);
    });

    test('expectedIdentityFor names the receiver', () async {
      final (_, uri) = await server(
        'mem',
        credential: await issue('gate', gateKey, const []),
        holderKey: gateKey,
        requireNamedIdent: true,
      );
      final asked = <(Uri, ServiceRecord?)>[];
      Future<Switchboard> client(String? expected) async => node(
        credential: await npcCredential(),
        holderKey: npcKey,
        expectedIdentityFor: (endpoint, record) {
          asked.add((endpoint, record));
          return expected;
        },
      );
      final named = await client('gate');
      expect(await open(named, uri, npc), 'npc for npc-7');
      expect(asked.single, (uri, null));
      // Another receiver, or none at a host that requires one: refused.
      for (final expected in ['other', null]) {
        await expectLater(
          (await client(expected)).connect(uri),
          throwsCode(StatusCode.unauthenticated),
        );
      }
      // An explicit receiver wins over the hook.
      final explicit = await client('other');
      final connection = await explicit.dial(uri, receiver: 'gate');
      expect(connection.isOpen, isTrue);
      final failing = await node(
        credential: await npcCredential(),
        holderKey: npcKey,
        expectedIdentityFor: (endpoint, record) => throw StateError('no'),
      );
      await expectLater(
        failing.connect(uri),
        throwsCode(StatusCode.unauthenticated),
      );
    });

    test('dial with an intent and a receiver; updateCredential presents '
        'the renewed credential where the node identified', () async {
      final (b, bUri) = await server(
        'mem',
        credential: await issue('gate', gateKey, const []),
        holderKey: gateKey,
      );
      final (c, cUri) = await server('mem', policy: ChannelPolicies.scoped());
      final seen = <MuxConnection>[];
      b.connections.listen(seen.add);
      c.connections.listen(seen.add);
      final a = await node(
        credential: await npcCredential(),
        holderKey: npcKey,
        identifyFor: (endpoint) => endpoint == bUri,
      );
      final plain = await node();
      await expectLater(
        plain.dial(bUri, intent: Uint8List(1)),
        throwsCode(StatusCode.failedPrecondition),
      );
      expect(() => a.dial(bUri, intent: Uint8List(65)), throwsArgumentError);
      final toB = await a.dial(
        bUri,
        intent: Uint8List.fromList([7]),
        receiver: 'gate',
      );
      // identifyFor says no for c: not identified there.
      final toC = await a.connect(cUri);
      await until(() => seen.length == 2);
      final atB = seen.firstWhere((s) => s.peerIdentity != null);
      expect(atB.peerIdentity!.intent, [7]);
      expect(atB.peerIdentity!.receiver, 'gate');
      final renewed = await issue('npc-7', npcKey, [
        Scope.of(Right.open, 'npc'),
        Scope.of(Right.open, 'chat'),
      ]);
      await a.updateCredential(renewed);
      expect(a.credential, renewed);
      expect(atB.peerIdentity!.credential, renewed);
      expect(atB.peerIdentity!.intent, [7]);
      expect(atB.peerIdentity!.receiver, 'gate');
      expect(seen.where((s) => s.peerIdentity != null), hasLength(1));
      expect(toB.isOpen && toC.isOpen, isTrue);
      expect(toB.localIdentity, 'npc-7');
    });

    test('PeerSet connections identify', () async {
      final b = await node();
      final seen = Completer<String?>();
      final held = <IncomingChannel>[];
      // Keeps the per-peer channel open: one that closes before the peer
      // is online counts as refused.
      b.registerService(npc, (incoming) {
        held.add(incoming);
        seen.complete(incoming.peerIdentity?.identity);
      }, acceptAnyInstance: true);
      final uri = await b.listenMemory();
      final records = <ServiceRecord?>[];
      final consumer = await node(
        credential: await npcCredential(),
        holderKey: npcKey,
        outgoingPolicy: ChannelPolicies.denyAll,
        resolver: StaticResolver([
          ServiceRecord(ServiceAddress(npc, 5), endpoints: [uri]),
        ]),
        expectedIdentityFor: (endpoint, record) {
          records.add(record);
          return null;
        },
      );
      final set = PeerSet.watch(
        consumer,
        npc,
        channel: ChannelAddress(type: npc),
      );
      addTearDown(set.close);
      expect(await seen.future.timeout(limit), 'npc-7');
      await set.events
          .firstWhere((e) => e.type == PeerEventType.online)
          .timeout(limit);
      // The PeerSet tells the hook which record it dials.
      expect(records.single?.address, ServiceAddress(npc, 5));
    });
  });
}
