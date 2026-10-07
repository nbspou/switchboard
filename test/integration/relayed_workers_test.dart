// Outbound-only on both ends (wiki page "Switchboard Use Cases", entry
// 5c) over tcp: a naming service that requires credentials and named
// IDENTs; two relay nodes that listen, require named IDENTs and publish
// `_relay` with their identities; a worker that listens nowhere and holds
// `register worker-*` only; two consumers that listen nowhere either,
// keep a PeerSet over the workers through the relays and run jobs with
// openTalk. Strict credentials for everyone. The consumers come online
// through one relay, which brokers one connection to the worker for both;
// a consumer without the `open` scope is refused by the relay; the relay
// in use stops and the consumers come back through the other one; the
// worker restarts and is brokered again.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:switchboard/switchboard.dart';
import 'package:test/test.dart';

const mux = MuxOptions(
  goAwayGrace: Duration(milliseconds: 200),
  keepAliveInterval: null,
);
const talkOptions = TalkOptions(
  requestTimeout: Duration(seconds: 3),
  replyTimeout: Duration(seconds: 2),
);
const limit = Duration(seconds: 10);

final naming = Services.naming;
final workerType = Name('worker-g');

final authoritySeed = Uint8List.fromList(List.generate(32, (i) => 17 * i + 1));

late CredentialIssuer authority;
late HolderKey nsKey;
late HolderKey workerKey;
late HolderKey relayKey;
late HolderKey consumerKey;

Uint8List bytes(String text) => Uint8List.fromList(utf8.encode(text));

String text(Uint8List data) => utf8.decode(data);

Matcher hasCode(StatusCode code) =>
    isA<Status>().having((s) => s.known, 'known', code);

Future<void> until(bool Function() condition, [String? what]) async {
  final deadline = DateTime.now().add(limit);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('${what ?? 'condition'} not met within $limit');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Future<Credential> issue(
  String identity,
  HolderKey holder,
  List<Scope> scopes,
) => authority.issue(
  kind: CredentialKind.node,
  identity: identity,
  scopes: scopes,
  holderKey: holder.publicKey,
);

Future<CredentialVerifier> verifier() async {
  final v = CredentialVerifier();
  await v.addIssuer(authority);
  return v;
}

/// Names the naming service when identifying to it; the relays are named
/// from their records.
ExpectedIdentity namesTheNamingService(Uri namingEndpoint) =>
    (endpoint, record) => endpoint == namingEndpoint ? 'ns' : null;

/// A relay node on tcp.
class Relay {
  Relay._(this.node, this.mesh, this.uri);

  static Future<Relay> start(Uri namingEndpoint, String identity) async {
    final node = Switchboard(
      muxOptions: mux.copyWith(requireNamedIdent: true),
      talkOptions: talkOptions,
      credential: await issue(identity, relayKey, [
        Scope.of(Right.register, '_relay'),
        Scope.of(Right.watch, '*'),
        Scope.of(Right.open, 'worker-*'),
        Scope.of(Right.broker, 'worker-*'),
      ]),
      holderKey: relayKey,
      verifier: await verifier(),
      expectedIdentityFor: namesTheNamingService(namingEndpoint),
    );
    addTearDown(node.close);
    final uri = await node.listenTcp(
      '127.0.0.1',
      0,
      policy: ChannelPolicies.scoped(),
    );
    final mesh = MeshNode.join(node, namingEndpoint, talkOptions: talkOptions);
    addTearDown(mesh.leave);
    await mesh.synced.timeout(limit);
    await mesh.publishRelay(RelayService(node)).timeout(limit);
    return Relay._(node, mesh, uri);
  }

  final Switchboard node;
  final MeshNode mesh;
  final Uri uri;

  Future<void> stop() async {
    await mesh.leave();
    await node.close();
  }
}

/// The worker: no listener, `register worker-*` only, answering jobs with
/// the identity it sees (the relay's) and its instance.
class Worker {
  Worker._(this.node, this.mesh, this.id);

  static Future<Worker> start(Uri namingEndpoint, {int instance = 0}) async {
    final node = Switchboard(
      muxOptions: mux,
      talkOptions: talkOptions,
      credential: await issue('worker-a1', workerKey, [
        Scope.of(Right.register, 'worker-*'),
      ]),
      holderKey: workerKey,
      verifier: await verifier(),
      expectedIdentityFor: namesTheNamingService(namingEndpoint),
    );
    addTearDown(node.close);
    final mesh = MeshNode.join(
      node,
      namingEndpoint,
      talkOptions: talkOptions,
      watch: false,
    );
    addTearDown(mesh.leave);
    final id = await mesh
        .publish(
          workerType,
          (incoming) {
            final via = incoming.peerIdentity?.identity;
            incoming.talk().messages.listen((message) {
              if (message.expectsReply) {
                message.reply(bytes('${text(message.payload)} done via $via'));
              }
            });
          },
          endpoints: const [],
          instance: instance,
        )
        .timeout(limit);
    expect(node.listeningEndpoints, isEmpty);
    return Worker._(node, mesh, id);
  }

  final Switchboard node;
  final MeshNode mesh;
  final int id;

  Future<void> stop() async {
    await mesh.leave();
    await node.close();
  }
}

/// A consumer: no listener, `open` and `watch`, relays found through the
/// naming service, a PeerSet over the workers.
class Consumer {
  Consumer._(this.node, this.set, this.events);

  static Future<Consumer> start(
    Uri namingEndpoint,
    String identity, {
    List<Scope>? scopes,
  }) async {
    final node = Switchboard(
      muxOptions: mux,
      talkOptions: talkOptions,
      credential: await issue(
        identity,
        consumerKey,
        scopes ??
            [Scope.of(Right.watch, '*'), Scope.of(Right.open, 'worker-*')],
      ),
      holderKey: consumerKey,
      verifier: await verifier(),
      outgoingPolicy: ChannelPolicies.denyAll,
      expectedIdentityFor: namesTheNamingService(namingEndpoint),
      relay: RelayConfig(),
    );
    addTearDown(node.close);
    final mesh = MeshNode.join(node, namingEndpoint, talkOptions: talkOptions);
    addTearDown(mesh.leave);
    await mesh.synced.timeout(limit);
    expect(node.canBroker, isFalse);
    final set = PeerSet.watch(
      node,
      workerType,
      channel: ChannelAddress(type: workerType),
      // A round trip on the per-peer channel: through a relay, only that
      // says the channel reached the worker.
      onOpen: (peer, channel) async {
        await TalkChannel(
          channel,
          options: talkOptions,
        ).request('HELLO', Uint8List(0));
      },
      initialBackoff: const Duration(milliseconds: 50),
      maxBackoff: const Duration(milliseconds: 500),
      removalHoldDown: const Duration(seconds: 5),
    );
    addTearDown(set.close);
    final events = <String>[];
    set.events.listen((e) => events.add('${e.type.name} ${e.peer.address}'));
    return Consumer._(node, set, events);
  }

  final Switchboard node;
  final PeerSet set;
  final List<String> events;

  /// Runs a job on the worker [id] over a fresh channel of the set.
  Future<String> run(int id, String job) async {
    final channel = await set.openTalk(id);
    try {
      return text((await channel.request('RUN', bytes(job))).payload);
    } finally {
      await channel.close();
    }
  }
}

void main() {
  setUpAll(() async {
    authority = await CredentialIssuer.ed25519FromSeed(
      Name('auth1'),
      authoritySeed,
    );
    nsKey = await HolderKey.generate();
    workerKey = await HolderKey.generate();
    relayKey = await HolderKey.generate();
    consumerKey = await HolderKey.generate();
  });

  test('consumers reach an outbound-only worker through relays', () async {
    // The naming service: credentials required, and IDENTs must name it.
    final host = Switchboard(
      muxOptions: mux.copyWith(requireNamedIdent: true),
      talkOptions: talkOptions,
      credential: await issue('ns', nsKey, const []),
      holderKey: nsKey,
      verifier: await verifier(),
    );
    addTearDown(host.close);
    final service = NamingService(
      assignmentHold: Duration.zero,
      verifier: await verifier(),
      requireCredential: true,
    );
    addTearDown(service.close);
    host.registerService(naming, service.handler, instance: 1);
    final namingEndpoint = await host.listenTcp(
      '127.0.0.1',
      0,
      policy: ChannelPolicies.scoped(),
    );
    service.registerLocal(naming, [namingEndpoint], instance: 1);

    final relayA = await Relay.start(namingEndpoint, 'relay-a');
    final relayB = await Relay.start(namingEndpoint, 'relay-b');
    final relays = [
      for (final record in service.table.values)
        if (record.address.type == Services.relay) record,
    ]..sort((a, b) => a.address.instance.compareTo(b.address.instance));
    expect(relays.map((r) => text(r.metadata)), ['relay-a', 'relay-b']);
    expect(relays.first.endpoints, [relayA.uri]);

    var worker = await Worker.start(namingEndpoint);
    final id = worker.id;
    expect(service.table[ServiceAddress(workerType, id)]?.endpoints, isEmpty);

    // Both consumers come online through the first relay, which brokers
    // one connection to the worker for both.
    final one = await Consumer.start(namingEndpoint, 'consumer-1');
    final two = await Consumer.start(namingEndpoint, 'consumer-2');
    await until(
      () => one.set.online.isNotEmpty && two.set.online.isNotEmpty,
      'the worker online for both consumers',
    );
    final peerOne = one.set.peers[id]!;
    final peerTwo = two.set.peers[id]!;
    for (final peer in [peerOne, peerTwo]) {
      expect(peer.viaRelay, isTrue);
      expect(peer.endpoint, relayA.uri);
    }
    expect(await one.run(id, 'job 1').timeout(limit), 'job 1 done via relay-a');
    expect(await two.run(id, 'job 2').timeout(limit), 'job 2 done via relay-a');
    expect(worker.mesh.brokeredConnections, hasLength(1));
    final brokered = worker.mesh.brokeredConnections.single;
    expect(brokered.peerIdentity?.identity, 'relay-a');
    expect(brokered.peerIdentity?.receiver, 'worker-a1');

    // A consumer without `open` for the worker's type is refused by the
    // relay.
    final stranger = Switchboard(
      muxOptions: mux,
      talkOptions: talkOptions,
      credential: await issue('consumer-3', consumerKey, [
        Scope.of(Right.watch, '*'),
      ]),
      holderKey: consumerKey,
      verifier: await verifier(),
      expectedIdentityFor: namesTheNamingService(namingEndpoint),
      relay: RelayConfig(),
    );
    addTearDown(stranger.close);
    final strangerMesh = MeshNode.join(
      stranger,
      namingEndpoint,
      talkOptions: talkOptions,
    );
    addTearDown(strangerMesh.leave);
    await strangerMesh.synced.timeout(limit);
    final refused = await stranger
        .openChannel(ServiceAddress(workerType, id))
        .timeout(limit);
    expect(
      await refused.done.timeout(limit),
      hasCode(StatusCode.permissionDenied),
    );

    // The relay in use stops: both consumers come back through the other.
    await relayA.stop();
    await until(
      () =>
          peerOne.isOnline &&
          peerOne.endpoint == relayB.uri &&
          peerTwo.isOnline &&
          peerTwo.endpoint == relayB.uri,
      'back through relay-b',
    );
    expect(await one.run(id, 'job 3').timeout(limit), 'job 3 done via relay-b');
    expect(await two.run(id, 'job 4').timeout(limit), 'job 4 done via relay-b');
    await until(
      () => worker.mesh.brokeredConnections.length == 1,
      'one brokered connection, to relay-b',
    );
    expect(
      worker.mesh.brokeredConnections.single.peerIdentity?.identity,
      'relay-b',
    );

    // The worker restarts under its id: brokered again, online again.
    await worker.stop();
    await until(
      () => !peerOne.isOnline && !peerTwo.isOnline,
      'the worker offline',
    );
    worker = await Worker.start(namingEndpoint, instance: id);
    expect(worker.id, id);
    await until(
      () => peerOne.isOnline && peerTwo.isOnline,
      'the worker online again',
    );
    expect(identical(one.set.peers[id], peerOne), isTrue);
    expect(await one.run(id, 'job 5').timeout(limit), 'job 5 done via relay-b');
    expect(await two.run(id, 'job 6').timeout(limit), 'job 6 done via relay-b');
    expect(worker.mesh.brokeredConnections, hasLength(1));
    for (final consumer in [one, two]) {
      expect(consumer.events.first, 'added ${ServiceAddress(workerType, id)}');
      expect(consumer.events.where((e) => e.startsWith('removed')), isEmpty);
    }
  });
}
