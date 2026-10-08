/*
Polyverse Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Authors:
  Jan Boon <jan.boon@kaetemi.be>
  Claude Opus 5.5 <noreply@anthropic.com>
  GPT-6 Astra <noreply@anthropic.com>
*/

// The `_relay` service (wiki page "Polyverse Switchboard Identity and Credentials",
// section "Relay"; use case 5c) over mem:// nodes: a naming service that
// requires credentials, outbound-only workers registered without
// endpoints, a relay node publishing `_relay` with its identity, and
// consumers that listen nowhere and reach the workers through it. Every
// refusal of RelayService, the identity rules on both hops (the hold for
// identity with and without requireIdentity, an OPEN that overtakes its
// IDENT, an identification while the channel is being opened), one
// brokered connection shared by all consumers, statuses relayed both ways,
// the consumer side (Switchboard.relay, the slot variants, PeerSet), and
// the rule that a node that can broker never relays.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:logging/logging.dart';
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

/// The messages logged on `Switchboard.Relay` (or [logger]) at [level] or
/// above from now on, until the test ends. Below INFO, the root level is
/// lowered for the test.
List<String> logged(Level level, {String logger = 'Switchboard.Relay'}) {
  if (level < Logger.root.level) {
    final previous = Logger.root.level;
    Logger.root.level = level;
    addTearDown(() => Logger.root.level = previous);
  }
  final records = <String>[];
  final logs = Logger.root.onRecord.listen((r) {
    if (r.loggerName == logger && r.level >= level) {
      records.add(r.message);
    }
  });
  addTearDown(logs.cancel);
  return records;
}

/// A node, closed after the test.
Future<Switchboard> newNode({
  Credential? credential,
  bool requireNamedIdent = false,
  bool identifyOutgoing = true,
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
    identifyOutgoing: identifyOutgoing,
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
    Resolver? resolver,
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
      resolver: resolver,
    );
    await m.publishRelay(service).timeout(limit);
    return Relay._(n, m, service, uri);
  }

  final Switchboard node;
  final MeshNode mesh;
  final RelayService service;
  final Uri uri;
}

/// A resolver of fixed [records] that answers only once [release]d.
class GatedResolver implements Resolver {
  GatedResolver(this.records);

  final List<ServiceRecord> records;
  final Completer<void> _gate = Completer<void>();
  final Completer<void> _asked = Completer<void>();

  /// Completes at the first [resolve].
  Future<void> get asked => _asked.future;

  void release() => _gate.complete();

  @override
  Future<List<ServiceRecord>> resolve(Name type) async {
    if (!_asked.isCompleted) {
      _asked.complete();
    }
    await _gate.future;
    return [
      for (final record in records)
        if (record.address.type == type) record,
    ];
  }

  @override
  Stream<ServiceEvent> get events => const Stream.empty();

  @override
  Future<void> get ready => Future.value();

  @override
  Future<void> close() async {}
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

/// Counts subscriptions to the next identity event without depending on
/// the Dart runtime's private future-listener representation.
class _ObservedIdentityConnection extends MuxConnection {
  _ObservedIdentityConnection(super.transport)
    : super(isInitiator: false, options: fast);

  int identityWaits = 0;

  @override
  Future<void> get identityChanged {
    identityWaits++;
    return super.identityChanged;
  }
}

void main() {
  setUpAll(() async {
    authority = await CredentialIssuer.ed25519FromSeed(
      Name('auth1'),
      authoritySeed,
    );
    key = await HolderKey.generate();
  });

  for (final timedOut in [false, true]) {
    test('identity holds release ${timedOut ? 'timed-out' : 'closed'} '
        'channels without accumulating future listeners', () async {
      final host = await newNode(
        requireNamedIdent: true,
        identityTimeout: timedOut ? const Duration(milliseconds: 5) : limit,
      );
      final service = RelayService(host);
      final (local, remote) = MemoryTransport.pair();
      final incoming = _ObservedIdentityConnection(local);
      final peer = MuxConnection(remote, isInitiator: true, options: fast);
      addTearDown(incoming.close);
      addTearDown(peer.close);
      final work = <Future<void>>[];
      incoming.incoming.listen((channel) {
        work.add(
          Future<void>.sync(() => service.handler(IncomingChannel(channel))),
        );
      });
      for (var i = 0; i < 100; i++) {
        final channel = openRelayed(
          peer,
          ChannelAddress(type: workerType).encode(),
        );
        await peer.ping();
        if (timedOut) {
          expect(
            await channel.done.timeout(limit),
            hasCode(StatusCode.unauthenticated),
          );
        } else {
          await channel.close();
        }
      }
      await Future.wait(work).timeout(limit);
      expect(incoming.identityWaits, 1);
      expect(incoming.openChannelCount, 0);
    });
  }

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

    test('an expectedIdentityFor that throws fails that relay: the next is '
        'tried', () async {
      final mesh = await startMesh();
      final relays = [
        await Relay.start(mesh),
        await Relay.start(mesh, identity: 'relay-2'),
      ];
      final worker = await Worker.start(mesh);
      Future<Switchboard> consumerWith(ExpectedIdentity hook) async {
        final c = await newNode(
          credential: await issue('consumer-1', consumerScopes),
          relay: RelayConfig(),
          expectedIdentityFor: hook,
        );
        final joined = MeshNode.join(c, mesh);
        addTearDown(joined.leave);
        await joined.synced.timeout(limit);
        return c;
      }

      // The first relay asked about fails, the other one carries the open.
      final asked = <Uri>[];
      final c = await consumerWith((endpoint, record) {
        if (record?.address.type != relayType) {
          return null;
        }
        asked.add(endpoint);
        if (asked.length == 1) {
          throw StateError('vault sealed');
        }
        return null;
      });
      final answer = await run(c, worker.address, 'x');
      expect(asked, hasLength(2));
      expect(asked.toSet(), hasLength(2));
      final used = relays.singleWhere((r) => r.uri == asked.last);
      expect(
        answer,
        contains('for ${used == relays.first ? 'relay-1' : 'relay-2'}'),
      );
      // Every relay failing: the destination is unavailable, never reached
      // through an IDENT naming nobody.
      final failing = await consumerWith(
        (endpoint, record) => record?.address.type == relayType
            ? throw StateError('vault sealed')
            : null,
      );
      await expectLater(
        failing.openChannel(worker.address),
        throwsA(
          isA<SwitchboardException>()
              .having((e) => e.code, 'code', StatusCode.unavailable)
              .having(
                (e) => e.status.reason,
                'reason',
                allOf(
                  contains('expectedIdentityFor'),
                  isNot(contains('vault sealed')),
                ),
              ),
        ),
      );
      expect(worker.seen, hasLength(1));
    });

    test('RelayConfig: the relay type must be reserved', () async {
      expect(RelayConfig().type, relayType);
      expect(RelayConfig(type: Name('_relay2')).type, Name('_relay2'));
      // Relays refuse to relay to reserved types only: a relay type
      // outside them would let relays chain.
      expect(() => RelayConfig(type: Name('meshrelay')), throwsArgumentError);
      expect(() => RelayConfig(type: Name.empty), throwsArgumentError);
      expect(
        () => RelayConfig(
          type: Name('meshrelay'),
          endpoints: [Uri.parse('mem://relay')],
          identity: 'relay-1',
        ),
        throwsArgumentError,
      );
    });

    test('a relay on a node that accepts unnamed IDENTs is warned '
        'about', () async {
      final warnings = logged(Level.WARNING);
      final lax = await newNode(
        credential: await issue('relay-1', relayScopes),
      );
      RelayService(lax);
      expect(warnings, hasLength(1));
      expect(warnings.single, contains('requireNamedIdent'));
      warnings.clear();
      final strict = await newNode(
        credential: await issue('relay-1', relayScopes),
        requireNamedIdent: true,
      );
      RelayService(strict);
      expect(warnings, isEmpty);
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
    test('an unidentified consumer: UNAUTHENTICATED, after the hold; one '
        'whose OPEN overtakes its IDENT is held, then admitted', () async {
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
    });

    test('a channel that ends while held for identity is dropped without a '
        'refusal and does not count toward the bound', () async {
      final mesh = await startMesh();
      final worker = await Worker.start(mesh);
      final relay = await Relay.start(mesh, maxChannelsPerConnection: 1);
      final logs = logged(Level.FINE);
      final c = await newNode(
        credential: await issue('consumer-1', consumerScopes),
        identifyOutgoing: false,
      );
      final connection = await c.dial(relay.uri);
      ChannelAddress inner(String payload) => ChannelAddress(
        type: workerType,
        instance: worker.id,
        payload: bytes(payload),
      );
      final dropped = openRelayed(connection, inner('dropped').encode());
      await until(() => logs.any((m) => m.contains('held until')), 'held');
      await dropped.close(Status.of(StatusCode.cancelled, 'gone'));
      await until(
        () => logs.any((m) => m.contains('ended while held')),
        'dropped',
      );
      expect(logs.where((m) => m.contains('refused')), isEmpty);
      // The bound of one is free: the next channel, held until the
      // consumer identifies, is relayed, and the one after it refused.
      final next = openRelayed(connection, inner('hold').encode());
      await c.identifyOn(connection, receiver: 'relay-1');
      await until(() => worker.seen.length == 1, 'relayed');
      expect(worker.seen.single.payload, 'hold');
      expect(
        await refusal(connection, inner('hold').encode()),
        hasCode(StatusCode.resourceExhausted),
      );
      expect(next.state, MuxChannelState.open);
    });

    test('without requireIdentity: an unidentified consumer is admitted '
        'unchecked after the hold, an identified one held to its '
        'scopes', () async {
      final mesh = await startMesh();
      final worker = await Worker.start(mesh);
      const hold = Duration(milliseconds: 300);
      final lenient = await Relay.start(
        mesh,
        identity: 'relay-2',
        requireIdentity: false,
        identityTimeout: hold,
      );
      final anonymous = await newNode();
      final open = await anonymous.connect(lenient.uri);
      final watch = Stopwatch()..start();
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
      // Held for the node's identity timeout first, in case an IDENT was
      // on its way.
      expect(watch.elapsed, greaterThanOrEqualTo(hold));
      await channel.close();
      // An identified consumer is held to its scopes all the same.
      final scoped = await newNode(
        credential: await issue('consumer-4', [Scope.of(Right.open, 'x')]),
      );
      final identified = await scoped.dial(lenient.uri, receiver: 'relay-2');
      expect(
        await refusal(
          identified,
          ChannelAddress(type: workerType, instance: worker.id).encode(),
        ),
        hasCode(StatusCode.permissionDenied),
      );
      expect(worker.seen, hasLength(1));
    });

    test('without requireIdentity: an OPEN that overtakes the IDENT is '
        'checked under the identity the IDENT establishes', () async {
      final mesh = await startMesh();
      final worker = await Worker.start(mesh);
      final lenient = await Relay.start(
        mesh,
        identity: 'relay-2',
        requireIdentity: false,
      );
      // A credential without `open` for the type, presented only after
      // the OPEN.
      final sneaky = await newNode(
        credential: await issue('consumer-4', [Scope.of(Right.open, 'x')]),
        identifyOutgoing: false,
      );
      final connection = await sneaky.dial(lenient.uri);
      final channel = openRelayed(
        connection,
        ChannelAddress(
          type: workerType,
          instance: worker.id,
          payload: bytes('sneaky'),
        ).encode(),
      );
      await sneaky.identifyOn(connection, receiver: 'relay-2');
      expect(
        await channel.done.timeout(limit),
        hasCode(StatusCode.permissionDenied),
      );
      expect(worker.seen, isEmpty);
      // The same order with `open` for the type: relayed.
      final honest = await newNode(
        credential: await issue('consumer-1', consumerScopes),
        identifyOutgoing: false,
      );
      final second = await honest.dial(lenient.uri);
      final relayed = TalkChannel(
        openRelayed(
          second,
          ChannelAddress(
            type: workerType,
            instance: worker.id,
            payload: bytes('p'),
          ).encode(),
        ),
      );
      await honest.identifyOn(second, receiver: 'relay-2');
      expect(
        text((await relayed.request('R', bytes('h')).timeout(limit)).payload),
        'h by ${worker.id} for relay-2 with "p"',
      );
      await relayed.close();
    });

    test('a consumer that identifies again while its channel is being opened '
        'is checked under the new identity', () async {
      final mesh = await startMesh();
      // A worker that listens, which the relay finds through a resolver
      // that answers only once the consumer has identified again.
      final lister = await newNode(
        credential: await issue('worker-b2', workerScopes),
      );
      final listerUri = await lister.listenMemory(
        policy: ChannelPolicies.scoped(),
      );
      final listedType = Name('worker-l');
      final opened = <MuxChannel>[];
      lister.registerService(
        listedType,
        (incoming) => opened.add(incoming.channel),
        instance: 1,
      );
      final gate = GatedResolver([
        ServiceRecord(ServiceAddress(listedType, 1), endpoints: [listerUri]),
      ]);
      final relay = await Relay.start(
        mesh,
        allowEndpoints: true,
        resolver: gate,
      );
      final accepted = <MuxConnection>[];
      relay.node.connections.listen(accepted.add);
      final c = await newNode(
        credential: await issue('consumer-1', consumerScopes),
      );
      final connection = await relayConnection(c, relay.uri);
      final channel = openRelayed(
        connection,
        ChannelAddress(type: listedType, instance: 1).encode(),
      );
      // Past the scope check, resolving: the consumer identifies again,
      // with a credential that may not open the type.
      await gate.asked.timeout(limit);
      await connection.identify(
        await issue('consumer-5', [Scope.of(Right.open, 'other-*')]),
        holderKey: key,
        receiver: 'relay-1',
      );
      await until(
        () => accepted.any((x) => x.peerIdentity?.identity == 'consumer-5'),
        'identified again',
      );
      gate.release();
      expect(
        await channel.done.timeout(limit),
        hasCode(StatusCode.permissionDenied),
      );
      // The channel to the instance, opened meanwhile, is closed.
      await until(() => opened.isNotEmpty, 'opened at the worker');
      expect(
        await opened.single.done.timeout(limit),
        hasCode(StatusCode.cancelled),
      );
    });

    test('a consumer expiring while its channel is opened is refused; the '
        'channel to the instance is cancelled, the bound released', () async {
      var now = DateTime.now().toUtc();
      await withClock(Clock(() => now), () async {
        final mesh = await startMesh();
        final worker = await newNode();
        final workerUri = await worker.listenMemory();
        final opened = <MuxChannel>[];
        worker.registerService(workerType, (incoming) {
          opened.add(incoming.channel);
          incoming.channel.send(bytes('private greeting'));
        }, instance: 1);
        final gate = GatedResolver([
          ServiceRecord(ServiceAddress(workerType, 1), endpoints: [workerUri]),
        ]);
        final relay = await Relay.start(
          mesh,
          allowEndpoints: true,
          resolver: gate,
          maxChannelsPerConnection: 1,
        );
        Future<Credential> credential() => authority.issue(
          kind: CredentialKind.node,
          identity: 'consumer-1',
          scopes: consumerScopes,
          holderKey: key.publicKey,
          lifetime: const Duration(minutes: 1),
        );
        final c = await newNode(credential: await credential());
        final connection = await relayConnection(c, relay.uri);
        final inner = ChannelAddress(type: workerType, instance: 1).encode();
        final channel = openRelayed(connection, inner);
        await gate.asked.timeout(limit);
        now = now.add(const Duration(minutes: 2));
        gate.release();
        expect(
          await channel.done.timeout(limit),
          hasCode(StatusCode.unauthenticated),
        );
        expect(await channel.stream.toList(), isEmpty);
        await until(() => opened.isNotEmpty, 'opened at the worker');
        expect(
          await opened.single.done.timeout(limit),
          hasCode(StatusCode.cancelled),
        );
        // Renewed, the consumer has the one channel its bound allows.
        await c.updateCredential(await credential());
        final again = openRelayed(connection, inner);
        expect(
          text(await again.stream.first.timeout(limit)),
          'private greeting',
        );
        await again.close();
      });
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

    test('maxChannelsPerConnection 0: no bound', () async {
      final mesh = await startMesh();
      final relay = await Relay.start(mesh, maxChannelsPerConnection: 0);
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
      final channels = [
        for (var i = 0; i < 5; i++) openRelayed(connection, hold),
      ];
      await until(() => worker.seen.length == 5);
      for (final channel in channels) {
        expect(channel.state, MuxChannelState.open);
      }
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

    test('with allowEndpoints, a record pointing back at the relay\'s own '
        'listener: UNAVAILABLE, never connected to', () async {
      final mesh = await startMesh();
      final relay = await Relay.start(mesh, allowEndpoints: true);
      final warnings = logged(Level.WARNING, logger: 'Switchboard.Router');
      // A record of a worker claiming to listen where the relay does.
      final misdirected = await newNode(
        credential: await issue('worker-c3', workerScopes),
      );
      final misdirectedMesh = MeshNode.join(misdirected, mesh, watch: false);
      addTearDown(misdirectedMesh.leave);
      final selfType = Name('worker-s');
      final id = await misdirectedMesh
          .publish(selfType, (incoming) {}, endpoints: [relay.uri])
          .timeout(limit);
      await until(
        () => relay.mesh.client.table.values.any(
          (r) => r.address.type == selfType,
        ),
      );
      final c = await newNode(
        credential: await issue('consumer-1', consumerScopes),
      );
      final connection = await relayConnection(c, relay.uri);
      final connections = <MuxConnection>[];
      relay.node.connections.listen(connections.add);
      expect(
        await refusal(
          connection,
          ChannelAddress(type: selfType, instance: id).encode(),
        ),
        hasCode(StatusCode.unavailable),
      );
      expect(connections, isEmpty);
      expect(
        warnings.where((m) => m.contains('is this node itself')),
        hasLength(1),
      );
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
