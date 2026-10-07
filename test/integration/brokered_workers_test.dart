// Outbound-only trusted workers (wiki page "Switchboard Use Cases", entry
// 5b) over tcp: a naming service that requires credentials, and named
// IDENTs on its listener; a worker that listens nowhere, dials the naming
// service, and holds a credential with `register` only; a consumer with
// `watch`, `open` and `broker` that listens on tcp behind a scoped policy
// and keeps a PeerSet over the workers. The consumer reaches the worker
// through CONNECT: request and reply work, the worker can open nothing on
// the consumer, a lost connection is brokered again, a consumer restart
// (a new listener) is brokered anew, and the worker going away takes the
// peer down and then out of the set.
//
// The relay variant, for a consumer that listens nowhere either, is in
// relayed_workers_test.dart.

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
final consumerType = Name('consumer');

final authoritySeed = Uint8List.fromList(List.generate(32, (i) => 13 * i + 5));

late CredentialIssuer authority;
late HolderKey nsKey;
late HolderKey workerKey;
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

/// The consumer: a node listening on tcp, joined to the mesh, with a
/// PeerSet over the workers.
class Consumer {
  Consumer._(this.node, this.mesh, this.set, this.events);

  static Future<Consumer> start(Uri namingEndpoint) async {
    final node = Switchboard(
      muxOptions: mux,
      talkOptions: talkOptions,
      credential: await issue('consumer-1', consumerKey, [
        Scope.of(Right.watch, '*'),
        Scope.of(Right.open, 'worker-*'),
        Scope.of(Right.broker, 'worker-*'),
      ]),
      holderKey: consumerKey,
      verifier: await verifier(),
      outgoingPolicy: ChannelPolicies.denyAll,
      expectedIdentityFor: (endpoint, record) =>
          endpoint == namingEndpoint ? 'ns' : null,
    );
    addTearDown(node.close);
    // Brokered workers dial this listener; its policy is theirs.
    await node.listenTcp('127.0.0.1', 0, policy: ChannelPolicies.scoped());
    final mesh = MeshNode.join(node, namingEndpoint, talkOptions: talkOptions);
    addTearDown(mesh.leave);
    await mesh.synced.timeout(limit);
    final set = PeerSet.watch(
      node,
      workerType,
      channel: ChannelAddress(type: workerType),
      initialBackoff: const Duration(milliseconds: 50),
      maxBackoff: const Duration(milliseconds: 500),
      removalHoldDown: const Duration(milliseconds: 300),
    );
    addTearDown(set.close);
    final events = <String>[];
    set.events.listen((e) => events.add('${e.type.name} ${e.peer.address}'));
    return Consumer._(node, mesh, set, events);
  }

  final Switchboard node;
  final MeshNode mesh;
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

  Future<void> stop() async {
    await set.close();
    await mesh.leave();
    await node.close();
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
    consumerKey = await HolderKey.generate();
  });

  test('a consumer reaches an outbound-only worker through CONNECT', () async {
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
      issuer: authority,
    );
    addTearDown(service.close);
    host.registerService(naming, service.handler, instance: 1);
    final namingEndpoint = await host.listenTcp(
      '127.0.0.1',
      0,
      policy: ChannelPolicies.scoped(),
    );
    service.registerLocal(naming, [namingEndpoint], instance: 1);

    // The worker: no listener, register only.
    final worker = Switchboard(
      muxOptions: mux,
      talkOptions: talkOptions,
      credential: await issue('worker-a1', workerKey, [
        Scope.of(Right.register, 'worker-*'),
      ]),
      holderKey: workerKey,
      verifier: await verifier(),
      expectedIdentityFor: (endpoint, record) =>
          endpoint == namingEndpoint ? 'ns' : null,
    );
    addTearDown(worker.close);
    final workerMesh = MeshNode.join(
      worker,
      namingEndpoint,
      talkOptions: talkOptions,
      watch: false,
    );
    addTearDown(workerMesh.leave);
    final id = await workerMesh
        .publish(workerType, (incoming) {
          final caller = incoming.peerIdentity?.identity;
          incoming.talk().messages.listen((message) {
            if (message.expectsReply) {
              message.reply(bytes('${text(message.payload)} done for $caller'));
            }
          });
        }, endpoints: const [])
        .timeout(limit);
    expect(worker.listeningEndpoints, isEmpty);
    expect(service.table[ServiceAddress(workerType, id)]?.endpoints, isEmpty);

    // The consumer brokers a connection and talks to the worker.
    var consumer = await Consumer.start(namingEndpoint);
    await until(() => consumer.set.online.isNotEmpty, 'worker online');
    final peer = consumer.set.peers[id]!;
    expect(peer.endpoint, isNull);
    expect(peer.connection!.peerIdentity!.identity, 'worker-a1');
    expect(peer.connection!.peerIdentity!.receiver, 'consumer-1');
    expect(
      await consumer.run(id, 'job 1').timeout(limit),
      'job 1 done for '
      'consumer-1',
    );
    final brokered = workerMesh.brokeredConnections.single;
    expect(brokered.peerIdentity!.identity, 'consumer-1');

    // The worker can open nothing on the consumer.
    final push = worker.openChannelOn(
      brokered,
      ChannelAddress(type: consumerType),
    );
    expect(
      await push.done.timeout(limit),
      hasCode(StatusCode.permissionDenied),
    );
    final pushWorker = worker.openChannelOn(
      brokered,
      ChannelAddress(type: workerType),
    );
    expect(
      await pushWorker.done.timeout(limit),
      hasCode(StatusCode.permissionDenied),
    );

    // A lost connection is brokered again.
    final first = peer.connection!;
    await first.close();
    await until(
      () => peer.isOnline && !identical(peer.connection, first),
      'brokered again',
    );
    expect(
      await consumer.run(id, 'job 2').timeout(limit),
      'job 2 done for '
      'consumer-1',
    );
    await until(
      () => workerMesh.brokeredConnections.length == 1,
      'one brokered connection at the worker',
    );

    // The consumer restarts with a new listener: brokered anew.
    final oldListener = consumer.node.listeningEndpoints.single;
    await consumer.stop();
    await until(
      () => workerMesh.brokeredConnections.isEmpty,
      'the worker left alone',
    );
    consumer = await Consumer.start(namingEndpoint);
    expect(consumer.node.listeningEndpoints.single, isNot(oldListener));
    await until(() => consumer.set.online.isNotEmpty, 'online again');
    expect(
      await consumer.run(id, 'job 3').timeout(limit),
      'job 3 done for '
      'consumer-1',
    );

    // The worker goes away: offline, held, then removed.
    final address = '${ServiceAddress(workerType, id)}';
    await workerMesh.leave();
    await worker.close();
    await until(
      () => consumer.events.contains('removed $address'),
      'worker removed',
    );
    expect(consumer.events.take(2), ['added $address', 'online $address']);
    expect(consumer.events.last, 'removed $address');
    expect(consumer.events, contains('held $address'));
    expect(
      consumer.events.skip(2).take(consumer.events.length - 3),
      everyElement(anyOf(startsWith('offline'), startsWith('held'))),
    );
    expect(consumer.set.peers, isEmpty);
  });
}
