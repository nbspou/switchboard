// The `_relay` service (wiki page "Switchboard Identity and Credentials",
// section "Relay"; use case 5c) over mem:// nodes: a naming service that
// requires credentials, outbound-only workers registered without
// endpoints, a relay node publishing `_relay` with its identity, and
// consumers that listen nowhere and reach the workers through it. Every
// refusal of RelayService, the identity rules on both hops, one brokered
// connection shared by all consumers, statuses relayed both ways, the
// consumer side (Switchboard.relay, the slot variants, PeerSet), and the
// rule that a node that can broker never relays.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:switchboard/switchboard.dart';
import 'package:test/test.dart';

const fast = MuxOptions(
  goAwayGrace: Duration(milliseconds: 100),
  keepAliveInterval: null,
);
const talk = TalkOptions(
  requestTimeout: Duration(seconds: 2),
  replyTimeout: Duration(seconds: 1),
);
const limit = Duration(seconds: 5);

final naming = Services.naming;
final relayType = Services.relay;
final workerType = Name('worker-g');
final otherType = Name('worker-d');

final authoritySeed = Uint8List.fromList(List.generate(32, (i) => 7 * i + 3));

late CredentialIssuer authority;
late HolderKey key;

final workerScopes = [Scope.of(Right.register, 'worker-*')];
final consumerScopes = [
  Scope.of(Right.watch, '*'),
  Scope.of(Right.open, 'worker-*'),
];
final relayScopes = [
  Scope.of(Right.register, '_relay'),
  Scope.of(Right.watch, '*'),
  Scope.of(Right.open, 'worker-*'),
  Scope.of(Right.broker, 'worker-*'),
];

Future<Credential> issue(String identity, List<Scope> scopes) =>
    authority.issue(
      kind: CredentialKind.node,
      identity: identity,
      scopes: scopes,
      holderKey: key.publicKey,
    );

Future<CredentialVerifier> verifier() async {
  final v = CredentialVerifier();
  await v.addIssuer(authority);
  return v;
}

Uint8List bytes(String text) => Uint8List.fromList(utf8.encode(text));

String text(Uint8List data) => utf8.decode(data);

Matcher throwsCode(StatusCode code) =>
    throwsA(isA<SwitchboardException>().having((e) => e.code, 'code', code));

Matcher hasCode(StatusCode code) =>
    isA<Status>().having((s) => s.known, 'known', code);

Future<void> until(bool Function() condition, [String? what]) async {
  final deadline = DateTime.now().add(limit);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('${what ?? 'condition'} not met within $limit');
    }
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

/// A node, closed after the test.
Future<Switchboard> newNode({
  Credential? credential,
  bool requireNamedIdent = false,
  Duration identityTimeout = limit,
  RelayConfig? relay,
  ExpectedIdentity? expectedIdentityFor,
}) async {
  final s = Switchboard(
    muxOptions: fast.copyWith(requireNamedIdent: requireNamedIdent),
    talkOptions: talk,
    credential: credential,
    holderKey: credential == null ? null : key,
    verifier: await verifier(),
    identityTimeout: identityTimeout,
    relay: relay,
    expectedIdentityFor: expectedIdentityFor,
  );
  addTearDown(s.close);
  return s;
}

/// A naming service that requires credentials.
Future<Uri> startMesh() async {
  final host = await newNode();
  final service = NamingService(
    assignmentHold: Duration.zero,
    holdingSettle: Duration.zero,
    verifier: await verifier(),
    requireCredential: true,
  );
  addTearDown(service.close);
  host.registerService(naming, service.handler, instance: 1);
  return host.listenMemory(policy: ChannelPolicies.allowTypes({naming}));
}

/// What a worker channel did: the identity it saw and the application
/// payload it received.
class Seen {
  Seen(this.identity, this.payload, this.channel);

  final String? identity;
  final String payload;
  final MuxChannel channel;
}

/// An outbound-only worker: registered without endpoints, `register` only.
class Worker {
  Worker._(this.node, this.mesh, this.id, this.type);

  static Future<Worker> start(
    Uri mesh, {
    String identity = 'worker-a1',
    Name? type,
  }) async {
    final n = await newNode(credential: await issue(identity, workerScopes));
    final m = MeshNode.join(n, mesh, watch: false);
    addTearDown(m.leave);
    final t = type ?? workerType;
    late final Worker worker;
    final id = await m
        .publish(t, (incoming) => worker._serve(incoming), endpoints: const [])
        .timeout(limit);
    return worker = Worker._(n, m, id, t);
  }

  final Switchboard node;
  final MeshNode mesh;
  final int id;
  final Name type;
  final List<Seen> seen = [];

  /// Answers every request with what it saw; an application payload
  /// `moved` is refused with a MOVED naming owner 7 at epoch 3, `hold`
  /// keeps the channel open without answering.
  void _serve(IncomingChannel incoming) {
    final payload = text(incoming.address.payload);
    seen.add(Seen(incoming.peerIdentity?.identity, payload, incoming.channel));
    if (payload == 'moved') {
      unawaited(
        incoming.reject(
          MovedStatus(owner: 7, epoch: 3, reason: 'elsewhere').toStatus(),
        ),
      );
      return;
    }
    if (payload == 'hold') {
      return;
    }
    incoming.talk().messages.listen((message) {
      if (message.expectsReply) {
        message.reply(
          bytes(
            '${text(message.payload)} by $id for '
            '${incoming.peerIdentity?.identity} with "$payload"',
          ),
        );
      }
    });
  }

  ServiceAddress get address => ServiceAddress(type, id);
}

/// A relay node: listens on mem:// behind [policy], requires named
/// IDENTs, publishes `_relay` with its identity.
class Relay {
  Relay._(this.node, this.mesh, this.service, this.uri);

  static Future<Relay> start(
    Uri meshUri, {
    String identity = 'relay-1',
    List<Scope>? scopes,
    bool requireIdentity = true,
    bool allowEndpoints = false,
    int maxChannelsPerConnection = 1024,
    ChannelPolicy? policy,
    Duration identityTimeout = limit,
  }) async {
    final n = await newNode(
      credential: await issue(identity, scopes ?? relayScopes),
      requireNamedIdent: true,
      identityTimeout: identityTimeout,
    );
    final uri = await n.listenMemory(policy: policy);
    final m = MeshNode.join(n, meshUri);
    addTearDown(m.leave);
    await m.synced.timeout(limit);
    final service = RelayService(
      n,
      requireIdentity: requireIdentity,
      allowEndpoints: allowEndpoints,
      maxChannelsPerConnection: maxChannelsPerConnection,
    );
    await m.publishRelay(service).timeout(limit);
    return Relay._(n, m, service, uri);
  }

  final Switchboard node;
  final MeshNode mesh;
  final RelayService service;
  final Uri uri;
}

/// A consumer that listens nowhere, joined to the mesh, with [relay].
Future<Switchboard> consumer(
  Uri mesh, {
  String identity = 'consumer-1',
  List<Scope>? scopes,
  RelayConfig? relay,
  bool useRelay = true,
  bool listen = false,
}) async {
  final c = await newNode(
    credential: await issue(identity, scopes ?? consumerScopes),
    relay: useRelay ? relay ?? RelayConfig() : null,
  );
  if (listen) {
    await c.listenMemory(policy: ChannelPolicies.scoped());
  }
  final m = MeshNode.join(c, mesh);
  addTearDown(m.leave);
  await m.synced.timeout(limit);
  return c;
}

/// A request on a fresh channel to [address] from [c]; its answer.
Future<String> run(Switchboard c, ServiceAddress address, String job) async {
  final channel = await c.openTalk(address).timeout(limit);
  try {
    return text((await channel.request('RUN', bytes(job))).payload);
  } finally {
    await channel.close();
  }
}

/// A connection from [c] to the relay at [relay], identified naming it.
Future<MuxConnection> relayConnection(Switchboard c, Uri relay) =>
    c.dial(relay, receiver: 'relay-1');

/// Opens a `_relay` channel with [inner] as its application payload.
MuxChannel openRelayed(MuxConnection connection, Uint8List inner) =>
    connection.open(ChannelAddress(type: relayType, payload: inner).encode());

/// The close status of a `_relay` channel carrying [inner].
Future<Status> refusal(MuxConnection connection, Uint8List inner) =>
    openRelayed(connection, inner).done.timeout(limit);

void main() {
  setUpAll(() async {
    authority = await CredentialIssuer.ed25519FromSeed(
      Name('auth1'),
      authoritySeed,
    );
    key = await HolderKey.generate();
  });

  test('scoped() admits _relay and _ns for every identified peer', () async {
    final mesh = await startMesh();
    // The relay listener's policy lets a consumer with no `open` scope
    // for `_relay` through; the relay checks the inner type.
    final relay = await Relay.start(mesh, policy: ChannelPolicies.scoped());
    final worker = await Worker.start(mesh);
    final c = await consumer(mesh);
    expect(await run(c, worker.address, 'job'), contains('by ${worker.id}'));
    expect(relay.node.listeningEndpoints, isNotEmpty);
    final dummy = await newNode(credential: await issue('x', const []));
    final connection = await dummy.dial(relay.uri, receiver: 'relay-1');
    // No `open` scope at all: the policy admits the channel, the relay
    // refuses the inner type.
    expect(
      await refusal(
        connection,
        ChannelAddress(type: workerType, instance: worker.id).encode(),
      ),
      hasCode(StatusCode.permissionDenied),
    );
    // Anything else is refused by the policy.
    final other = connection.open(ChannelAddress(type: workerType).encode());
    expect(
      await other.done.timeout(limit),
      hasCode(StatusCode.permissionDenied),
    );
  });

  group('relaying', () {
    test('a channel through the relay: request and reply end to end; the '
        'instance sees the relay\'s identity and the consumer\'s payload, '
        'the relay the consumer\'s', () async {
      final mesh = await startMesh();
      final relay = await Relay.start(mesh);
      final worker = await Worker.start(mesh);
      final c = await consumer(mesh);
      expect(c.canBroker, isFalse);
      final mux = await c
          .openChannel(worker.address, payload: bytes('token'))
          .timeout(limit);
      final channel = TalkChannel(mux);
      final reply = await channel.request('RUN', bytes('job')).timeout(limit);
      expect(
        text(reply.payload),
        'job by ${worker.id} for relay-1 with "token"',
      );
      // The channel went through the relay: a `_relay` channel whose
      // payload is the destination's open payload, instance filled in.
      final outer = ChannelAddress.decode(mux.openPayload);
      expect(outer.type, relayType);
      expect(outer.instance, 0);
      final inner = ChannelAddress.decode(outer.payload);
      expect(inner.type, workerType);
      expect(inner.instance, worker.id);
      expect(text(inner.payload), 'token');
      expect(mux.connection.isOpen, isTrue);
      expect(relay.uri, isNotNull);
      // The worker dialled the relay, which identified naming it.
      final brokered = worker.mesh.brokeredConnections.single;
      expect(brokered.peerIdentity?.identity, 'relay-1');
      expect(brokered.peerIdentity?.receiver, 'worker-a1');
      expect(worker.seen.single.identity, 'relay-1');
      await channel.close();
    });

    test('the relay record carries the relay\'s identity; the consumer names '
        'it', () async {
      final mesh = await startMesh();
      final relay = await Relay.start(mesh, identity: 'relay-7');
      final c = await consumer(mesh);
      final relays = await c.resolveRelays();
      expect(relays, hasLength(1));
      expect(relays.single.address.type, relayType);
      expect(text(relays.single.metadata), 'relay-7');
      expect(relays.single.endpoints, [relay.uri]);
      final worker = await Worker.start(mesh);
      // A connection the relay accepted from the consumer: identified,
      // naming relay-7.
      final identities = <PeerIdentity>[];
      relay.node.connections.listen((connection) {
        connection.peerIdentified.then(identities.add).ignore();
      });
      expect(await run(c, worker.address, 'x'), contains('for relay-7'));
      await until(() => identities.isNotEmpty);
      expect(identities.first.identity, 'consumer-1');
      expect(identities.first.receiver, 'relay-7');
    });

    test('explicit relay endpoints with an identity', () async {
      final mesh = await startMesh();
      final relay = await Relay.start(mesh);
      final worker = await Worker.start(mesh);
      final c = await consumer(
        mesh,
        relay: RelayConfig(endpoints: [relay.uri], identity: 'relay-1'),
      );
      expect(await run(c, worker.address, 'x'), contains('for relay-1'));
      final relays = await c.resolveRelays();
      expect(relays.single.address.instance, 0);
      expect(relays.single.endpoints, [relay.uri]);
      // Without the identity the relay's host refuses the IDENT that
      // names nobody.
      final anonymous = await consumer(
        mesh,
        identity: 'consumer-2',
        relay: RelayConfig(endpoints: [relay.uri]),
      );
      await expectLater(
        anonymous.openChannel(worker.address),
        throwsCode(StatusCode.unavailable),
      );
      await expectLater(
        anonymous.connect(relay.uri),
        throwsCode(StatusCode.unauthenticated),
      );
      // expectedIdentityFor wins over the record: a wrong name is
      // refused.
      final wrong = await newNode(
        credential: await issue('consumer-3', consumerScopes),
        relay: RelayConfig(),
        expectedIdentityFor: (endpoint, record) =>
            record?.address.type == relayType ? 'relay-9' : null,
      );
      final joined = MeshNode.join(wrong, mesh);
      addTearDown(joined.leave);
      await joined.synced.timeout(limit);
      await expectLater(
        wrong.openChannel(worker.address),
        throwsCode(StatusCode.unavailable),
      );
      expect(() => RelayConfig(endpoints: const []), throwsArgumentError);
      expect(
        () => RelayConfig(endpoints: [relay.uri], identity: ''),
        throwsArgumentError,
      );
    });

    test('one brokered connection shared by two consumers', () async {
      final mesh = await startMesh();
      await Relay.start(mesh);
      final worker = await Worker.start(mesh);
      final a = await consumer(mesh);
      final b = await consumer(mesh, identity: 'consumer-2');
      final results = await Future.wait([
        run(a, worker.address, 'a1'),
        run(b, worker.address, 'b1'),
        run(a, worker.address, 'a2'),
        run(b, worker.address, 'b2'),
      ]);
      expect(results, [
        for (final job in ['a1', 'b1', 'a2', 'b2'])
          '$job by ${worker.id} for relay-1 with ""',
      ]);
      expect(worker.mesh.brokeredConnections, hasLength(1));
    });

    test('a node that can broker never relays', () async {
      final mesh = await startMesh();
      final relay = await Relay.start(mesh);
      final worker = await Worker.start(mesh);
      final c = await consumer(
        mesh,
        scopes: [...consumerScopes, Scope.of(Right.broker, 'worker-*')],
        listen: true,
      );
      expect(c.canBroker, isTrue);
      final relayed = <MuxConnection>[];
      relay.node.connections.listen(relayed.add);
      final mux = await c.openChannel(worker.address).timeout(limit);
      final channel = TalkChannel(mux);
      expect(
        text((await channel.request('RUN', bytes('x')).timeout(limit)).payload),
        'x by ${worker.id} for consumer-1 with ""',
      );
      expect(ChannelAddress.decode(mux.openPayload).type, workerType);
      // Only the worker's own dial-back for the consumer, no relay.
      expect(relayed, isEmpty);
      expect(
        worker.mesh.brokeredConnections.single.peerIdentity?.identity,
        'consumer-1',
      );
      await channel.close();
    });

    test('without a relay, a node that cannot broker fails as before; a '
        'record with endpoints is dialled directly', () async {
      final mesh = await startMesh();
      await Relay.start(mesh);
      final worker = await Worker.start(mesh);
      final c = await consumer(mesh, useRelay: false);
      await expectLater(
        c.openChannel(worker.address),
        throwsA(
          isA<SwitchboardException>()
              .having((e) => e.code, 'code', StatusCode.unavailable)
              .having(
                (e) => e.status.reason,
                'reason',
                contains('no listener'),
              ),
        ),
      );
      await expectLater(
        c.resolveRelays(),
        throwsCode(StatusCode.failedPrecondition),
      );
      // A worker that listens is reached directly by a consumer with a
      // relay.
      final lister = await newNode(
        credential: await issue('worker-b2', workerScopes),
      );
      final listerUri = await lister.listenMemory(
        policy: ChannelPolicies.scoped(),
      );
      final listerMesh = MeshNode.join(lister, mesh, watch: false);
      addTearDown(listerMesh.leave);
      final listed = await listerMesh.publish(
        otherType,
        (incoming) => incoming.talk().messages.listen(
          (m) =>
              m.reply(bytes('direct for ${incoming.peerIdentity?.identity}')),
        ),
        endpoints: [listerUri],
      );
      final r = await consumer(mesh, identity: 'consumer-2');
      final mux = await r
          .openChannel(ServiceAddress(otherType, listed))
          .timeout(limit);
      final channel = TalkChannel(mux);
      expect(
        text((await channel.request('X', Uint8List(0)).timeout(limit)).payload),
        'direct for consumer-2',
      );
      expect(ChannelAddress.decode(mux.openPayload).type, otherType);
      await channel.close();
    });

    test('a lost connection on either side reaches the other as '
        'UNAVAILABLE; the relay brokers again', () async {
      final mesh = await startMesh();
      await Relay.start(mesh);
      final worker = await Worker.start(mesh);
      final c = await consumer(mesh);
      // The worker side goes: the consumer's channel ends UNAVAILABLE.
      final first = await c
          .openChannel(worker.address, payload: bytes('hold'))
          .timeout(limit);
      await until(() => worker.seen.length == 1);
      await worker.mesh.brokeredConnections.single.close();
      expect(await first.done.timeout(limit), hasCode(StatusCode.unavailable));
      // Brokered again for the next channel.
      expect(await run(c, worker.address, 'again'), contains('again by'));
      await until(() => worker.mesh.brokeredConnections.length == 1);
      // The consumer side goes: the worker's channel ends UNAVAILABLE.
      final second = await c
          .openChannel(worker.address, payload: bytes('hold'))
          .timeout(limit);
      await until(() => worker.seen.length == 3);
      final atWorker = worker.seen.last.channel;
      await second.connection.close();
      expect(
        await atWorker.done.timeout(limit),
        hasCode(StatusCode.unavailable),
      );
    });

    test('MOVED is relayed with its fields byte for byte', () async {
      final mesh = await startMesh();
      await Relay.start(mesh);
      final worker = await Worker.start(mesh);
      final c = await consumer(mesh);
      final channel = await c
          .openChannel(worker.address, payload: bytes('moved'))
          .timeout(limit);
      final status = await channel.done.timeout(limit);
      expect(status, hasCode(StatusCode.moved));
      expect(
        status.encode(),
        MovedStatus(owner: 7, epoch: 3, reason: 'elsewhere').encode(),
      );
    });

    test('openTalkToSlot reaches a slot owner through the relay', () async {
      final mesh = await startMesh();
      await Relay.start(mesh);
      final worker = await Worker.start(mesh);
      final c = await consumer(mesh);
      // A type without a slot table: the slot picks among the instances.
      final slotChannel = await c
          .openChannelToSlot(workerType, 5)
          .timeout(limit);
      final channel = TalkChannel(slotChannel);
      expect(
        text((await channel.request('S', bytes('s')).timeout(limit)).payload),
        's by ${worker.id} for relay-1 with ""',
      );
      final inner = ChannelAddress.decode(
        ChannelAddress.decode(slotChannel.channel.openPayload).payload,
      );
      expect(inner.shard, 5);
      expect(inner.instance, worker.id);
      await channel.close();
    });
  });

  group('refusals', () {
    test('an unidentified consumer: UNAUTHENTICATED, after the hold; '
        'admitted without requireIdentity', () async {
      final mesh = await startMesh();
      final worker = await Worker.start(mesh);
      final relay = await Relay.start(
        mesh,
        identityTimeout: const Duration(milliseconds: 200),
      );
      final anonymous = await newNode();
      final connection = await anonymous.connect(relay.uri);
      final inner = ChannelAddress(
        type: workerType,
        instance: worker.id,
      ).encode();
      expect(
        await refusal(connection, inner),
        hasCode(StatusCode.unauthenticated),
      );
      // A consumer whose OPEN overtakes its IDENT is held, then admitted.
      final overtaken = await anonymous.dial(relay.uri);
      final held = TalkChannel(
        openRelayed(
          overtaken,
          ChannelAddress(
            type: workerType,
            instance: worker.id,
            payload: bytes('p'),
          ).encode(),
        ),
      );
      await overtaken.identify(
        await issue('consumer-1', consumerScopes),
        holderKey: key,
        receiver: 'relay-1',
      );
      expect(
        text((await held.request('R', bytes('h')).timeout(limit)).payload),
        'h by ${worker.id} for relay-1 with "p"',
      );
      await held.close();
      final lenient = await Relay.start(
        mesh,
        identity: 'relay-2',
        requireIdentity: false,
      );
      final open = await anonymous.connect(lenient.uri);
      final channel = TalkChannel(
        openRelayed(
          open,
          ChannelAddress(
            type: workerType,
            instance: worker.id,
            payload: bytes('p'),
          ).encode(),
        ),
      );
      expect(
        text((await channel.request('R', bytes('r')).timeout(limit)).payload),
        'r by ${worker.id} for relay-2 with "p"',
      );
      await channel.close();
    });

    test('a consumer that identifies without naming the relay is refused by '
        'requireNamedIdent', () async {
      final mesh = await startMesh();
      final relay = await Relay.start(mesh);
      final c = await newNode(
        credential: await issue('consumer-1', consumerScopes),
      );
      await expectLater(
        c.connect(relay.uri),
        throwsCode(StatusCode.unauthenticated),
      );
      await expectLater(
        c.dial(relay.uri, receiver: 'someone-else'),
        throwsCode(StatusCode.unauthenticated),
      );
      final named = await c.dial(relay.uri, receiver: 'relay-1');
      expect(named.isOpen, isTrue);
    });

    test('malformed, untyped, host hints, reserved types and chains: '
        'INVALID_ARGUMENT', () async {
      final mesh = await startMesh();
      final relay = await Relay.start(mesh);
      final worker = await Worker.start(mesh);
      final c = await newNode(
        credential: await issue('consumer-1', [Scope.of(Right.open, '*')]),
      );
      final connection = await relayConnection(c, relay.uri);
      final cases = {
        'reserved flag bit': Uint8List.fromList([0x10]),
        'truncated': Uint8List.fromList([0x01, 0x61, 0x70]),
        'no type': Uint8List(0),
        'default service': Uint8List.fromList([0x00, 0x01]),
        'host hint': ChannelAddress(
          type: workerType,
          instance: worker.id,
          host: 'b.example:1',
        ).encode(),
        'the naming service': ChannelAddress(type: naming).encode(),
        'a chained relay': ChannelAddress(
          type: relayType,
          payload: ChannelAddress(
            type: workerType,
            instance: worker.id,
          ).encode(),
        ).encode(),
        'another reserved type': ChannelAddress(type: Name('_echo')).encode(),
      };
      for (final MapEntry(key: what, value: inner) in cases.entries) {
        expect(
          await refusal(connection, inner),
          hasCode(StatusCode.invalidArgument),
          reason: what,
        );
      }
      expect(worker.seen, isEmpty);
    });

    test(
      'a consumer without `open` for the inner type: PERMISSION_DENIED',
      () async {
        final mesh = await startMesh();
        final relay = await Relay.start(mesh);
        final worker = await Worker.start(mesh);
        final c = await consumer(
          mesh,
          scopes: [Scope.of(Right.watch, '*'), Scope.of(Right.open, 'other-*')],
        );
        final channel = await c.openChannel(worker.address).timeout(limit);
        expect(
          await channel.done.timeout(limit),
          hasCode(StatusCode.permissionDenied),
        );
        final raw = await relayConnection(c, relay.uri);
        expect(
          await refusal(
            raw,
            ChannelAddress(type: workerType, instance: worker.id).encode(),
          ),
          hasCode(StatusCode.permissionDenied),
        );
        expect(worker.seen, isEmpty);
      },
    );

    test('the per-connection bound: RESOURCE_EXHAUSTED', () async {
      final mesh = await startMesh();
      final relay = await Relay.start(mesh, maxChannelsPerConnection: 2);
      final worker = await Worker.start(mesh);
      final c = await newNode(
        credential: await issue('consumer-1', consumerScopes),
      );
      final connection = await relayConnection(c, relay.uri);
      final hold = ChannelAddress(
        type: workerType,
        instance: worker.id,
        payload: bytes('hold'),
      ).encode();
      final first = openRelayed(connection, hold);
      final second = openRelayed(connection, hold);
      await until(() => worker.seen.length == 2);
      expect(
        await refusal(connection, hold),
        hasCode(StatusCode.resourceExhausted),
      );
      // Another connection has its own bound.
      final other = await c.dial(relay.uri, receiver: 'relay-1');
      final third = openRelayed(other, hold);
      await until(() => worker.seen.length == 3);
      // One ends: room again.
      await first.close();
      await until(
        () => worker.seen.first.channel.state != MuxChannelState.open,
      );
      final fourth = openRelayed(connection, hold);
      await until(() => worker.seen.length == 4);
      for (final channel in [second, third, fourth]) {
        expect(channel.state, MuxChannelState.open);
      }
      expect(
        () => RelayService(relay.node, maxChannelsPerConnection: -1),
        throwsRangeError,
      );
    });

    test('no record: NOT_FOUND; a record with endpoints: '
        'FAILED_PRECONDITION, relayed with allowEndpoints', () async {
      final mesh = await startMesh();
      final relay = await Relay.start(mesh);
      final worker = await Worker.start(mesh);
      final c = await newNode(
        credential: await issue('consumer-1', consumerScopes),
      );
      final connection = await relayConnection(c, relay.uri);
      expect(
        await refusal(
          connection,
          ChannelAddress(type: workerType, instance: worker.id + 100).encode(),
        ),
        hasCode(StatusCode.notFound),
      );
      expect(
        await refusal(
          connection,
          ChannelAddress(type: Name('worker-z')).encode(),
        ),
        hasCode(StatusCode.notFound),
      );
      // A worker that listens.
      final lister = await newNode(
        credential: await issue('worker-b2', workerScopes),
      );
      final listerUri = await lister.listenMemory(
        policy: ChannelPolicies.scoped(),
      );
      final listerMesh = MeshNode.join(lister, mesh, watch: false);
      addTearDown(listerMesh.leave);
      final listedType = Name('worker-l');
      final listed = await listerMesh.publish(
        listedType,
        (incoming) => incoming.talk().messages.listen(
          (m) =>
              m.reply(bytes('listed for ${incoming.peerIdentity?.identity}')),
        ),
        endpoints: [listerUri],
      );
      final listedAddress = ChannelAddress(type: listedType, instance: listed);
      await until(
        () => relay.mesh.client.table.values.any(
          (r) => r.address.type == listedType,
        ),
      );
      expect(
        await refusal(connection, listedAddress.encode()),
        hasCode(StatusCode.failedPrecondition),
      );
      // Any instance of the type: only records with endpoints, also
      // FAILED_PRECONDITION.
      expect(
        await refusal(connection, ChannelAddress(type: listedType).encode()),
        hasCode(StatusCode.failedPrecondition),
      );
      final open = await Relay.start(
        mesh,
        identity: 'relay-2',
        allowEndpoints: true,
      );
      final openConnection = await c.dial(open.uri, receiver: 'relay-2');
      final channel = TalkChannel(
        openRelayed(openConnection, listedAddress.encode()),
      );
      expect(
        text((await channel.request('L', Uint8List(0)).timeout(limit)).payload),
        'listed for relay-2',
      );
      await channel.close();
    });

    test('a relay without `broker`: UNAVAILABLE', () async {
      final mesh = await startMesh();
      final relay = await Relay.start(
        mesh,
        scopes: [
          Scope.of(Right.register, '_relay'),
          Scope.of(Right.watch, '*'),
          Scope.of(Right.open, 'worker-*'),
        ],
      );
      final worker = await Worker.start(mesh);
      final c = await consumer(mesh);
      final channel = await c.openChannel(worker.address).timeout(limit);
      expect(
        await channel.done.timeout(limit),
        hasCode(StatusCode.unavailable),
      );
      expect(worker.mesh.brokeredConnections, isEmpty);
      expect(relay.uri, isNotNull);
    });

    test('a relay without `open` for the type: the worker\'s brokered '
        'policy refuses, and the refusal is relayed', () async {
      final mesh = await startMesh();
      await Relay.start(
        mesh,
        scopes: [
          Scope.of(Right.register, '_relay'),
          Scope.of(Right.watch, '*'),
          Scope.of(Right.broker, 'worker-*'),
        ],
      );
      final worker = await Worker.start(mesh);
      final c = await consumer(mesh);
      final channel = await c.openChannel(worker.address).timeout(limit);
      expect(
        await channel.done.timeout(limit),
        hasCode(StatusCode.permissionDenied),
      );
      expect(worker.seen, isEmpty);
      expect(worker.mesh.brokeredConnections, hasLength(1));
    });
  });

  group('PeerSet', () {
    test('a peer without endpoints is connected through the relay, and '
        'comes back through the other relay when its relay goes', () async {
      final mesh = await startMesh();
      final first = await Relay.start(mesh, identity: 'relay-1');
      final worker = await Worker.start(mesh);
      final c = await consumer(mesh);
      final set = PeerSet.watch(
        c,
        workerType,
        channel: ChannelAddress(type: workerType),
        onOpen: (peer, channel) async {
          // A round trip confirms the channel reached the worker.
          final talk = TalkChannel(channel);
          await talk.request('HELLO', Uint8List(0));
        },
        policy: ChannelPolicies.denyAll,
        initialBackoff: const Duration(milliseconds: 20),
        maxBackoff: const Duration(milliseconds: 100),
      );
      addTearDown(set.close);
      final events = <String>[];
      set.events.listen((e) => events.add(e.type.name));
      await until(() => set.online.length == 1, 'online');
      final peer = set.peers[worker.id]!;
      expect(peer.viaRelay, isTrue);
      expect(peer.endpoint, first.uri);
      final talkChannel = await set.openTalk(worker.id);
      expect(
        text(
          (await talkChannel.request('J', bytes('j')).timeout(limit)).payload,
        ),
        'j by ${worker.id} for relay-1 with ""',
      );
      await talkChannel.close();
      // A second relay; the first goes away.
      final second = await Relay.start(mesh, identity: 'relay-2');
      await until(
        () =>
            c.resolver is NamingResolver &&
            (c.resolver! as NamingResolver).client.table.values
                    .where((r) => r.address.type == relayType)
                    .length ==
                2,
        'two relays known',
      );
      await first.mesh.leave();
      await first.node.close();
      await until(
        () => peer.isOnline && peer.endpoint == second.uri,
        'online through the second relay',
      );
      expect(events.first, 'added');
      expect(events, containsAllInOrder(['online', 'offline', 'online']));
      final again = await set.openTalk(worker.id);
      expect(
        text((await again.request('J', bytes('k')).timeout(limit)).payload),
        'k by ${worker.id} for relay-2 with ""',
      );
      await again.close();
      // The worker's connection to the relay is lost: the channel ends,
      // and the peer is set up again through the relay.
      await worker.mesh.brokeredConnections.single.close();
      await until(() => !peer.isOnline, 'offline');
      await until(() => peer.isOnline, 'online again');
      expect(peer.viaRelay, isTrue);
    });

    test('a node that can neither broker nor relay reports the brokering '
        'failure', () async {
      final mesh = await startMesh();
      final worker = await Worker.start(mesh);
      final c = await consumer(mesh, useRelay: false);
      final set = PeerSet.watch(
        c,
        workerType,
        channel: ChannelAddress(type: workerType),
        policy: ChannelPolicies.denyAll,
        initialBackoff: const Duration(milliseconds: 20),
        maxBackoff: const Duration(milliseconds: 100),
      );
      addTearDown(set.close);
      await until(
        () => set.peers[worker.id]?.lastStatus != null,
        'attempt failed',
      );
      final peer = set.peers[worker.id]!;
      expect(peer.isOnline, isFalse);
      expect(peer.viaRelay, isFalse);
      expect(peer.lastStatus, hasCode(StatusCode.failedPrecondition));
    });
  });
}
