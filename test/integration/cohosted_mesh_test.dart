/*
Polyverse Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Authors:
  Jan Boon <jan.boon@kaetemi.be>
  Claude Opus 5.5 <noreply@anthropic.com>
*/

// One node hosting a whole small mesh, over tcp and over ws: the naming
// service, a `_relay` and an application service, joined to the naming
// service it hosts through its own listener. Its own naming channel and its
// own channels to the application service go over an in-process pair, not
// a socket to itself. A worker that listens nowhere registers through it;
// a consumer that listens nowhere reaches the application service directly
// and the worker through the relay, which brokers the worker's connection
// through the naming service on the same node. Strict credentials and
// named IDENTs, as in relayed_workers_test.dart.

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
final app = Name('app');
final workerType = Name('worker-g');

final authoritySeed = Uint8List.fromList(List.generate(32, (i) => 13 * i + 5));

late CredentialIssuer authority;
late HolderKey hubKey;
late HolderKey workerKey;
late HolderKey consumerKey;

Uint8List bytes(String text) => Uint8List.fromList(utf8.encode(text));

String text(Uint8List data) => utf8.decode(data);

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

/// One request on a fresh Talk channel from [from] to [to].
Future<String> call(Switchboard from, ServiceAddress to, String job) async {
  final talk = await from.openTalk(to);
  try {
    return text((await talk.request('RUN', bytes(job))).payload);
  } finally {
    await talk.close();
  }
}

/// A channel the hub received: who opened it, and over what.
typedef Arrival = ({Name type, String? identity, String? remote});

void main() {
  setUpAll(() async {
    authority = await CredentialIssuer.ed25519FromSeed(
      Name('auth1'),
      authoritySeed,
    );
    hubKey = await HolderKey.generate();
    workerKey = await HolderKey.generate();
    consumerKey = await HolderKey.generate();
  });

  for (final scheme in ['tcp', 'ws']) {
    test('one node hosting naming, a relay and a service, joined to '
        'itself in-process ($scheme)', () async {
      // The hub. It names itself when it identifies to its own listener,
      // and requires named IDENTs, as a relay should.
      late final Uri hubUri;
      final hub = Switchboard(
        muxOptions: mux.copyWith(requireNamedIdent: true),
        talkOptions: talkOptions,
        credential: await issue('hub', hubKey, [
          Scope.of(Right.register, '_relay'),
          Scope.of(Right.register, 'app'),
          Scope.of(Right.watch, '*'),
          Scope.of(Right.open, 'app'),
          Scope.of(Right.open, 'worker-*'),
          Scope.of(Right.broker, 'worker-*'),
        ]),
        holderKey: hubKey,
        verifier: await verifier(),
        expectedIdentityFor: (endpoint, record) =>
            endpoint == hubUri ? 'hub' : null,
      );
      addTearDown(hub.close);
      final arrivals = <Arrival>[];
      void arrived(IncomingChannel incoming) => arrivals.add((
        type: incoming.address.type!,
        identity: incoming.peerIdentity?.identity,
        remote: incoming.remote,
      ));

      final service = NamingService(
        assignmentHold: Duration.zero,
        verifier: await verifier(),
        requireCredential: true,
      );
      addTearDown(service.close);
      hub.registerService(naming, (incoming) {
        arrived(incoming);
        return service.handler(incoming);
      }, instance: 1);
      hubUri = scheme == 'tcp'
          ? await hub.listenTcp(
              '127.0.0.1',
              0,
              policy: ChannelPolicies.scoped(),
            )
          : await hub.listenWebSocket(
              '127.0.0.1',
              0,
              policy: ChannelPolicies.scoped(),
            );
      service.registerLocal(naming, [hubUri], instance: 1);
      expect(hub.isOwnEndpoint(hubUri), isTrue);

      // The hub joins the naming service it hosts, through its own
      // listener, and publishes the relay and the application service.
      final hubMesh = MeshNode.join(hub, hubUri, talkOptions: talkOptions);
      addTearDown(hubMesh.leave);
      await hubMesh.synced.timeout(limit);
      await hubMesh.publishRelay(RelayService(hub)).timeout(limit);
      final appId = await hubMesh
          .publish(app, (incoming) {
            arrived(incoming);
            incoming.talk().messages.listen((message) {
              message.reply(
                bytes(
                  '${text(message.payload)} for '
                  '${incoming.peerIdentity?.identity}',
                ),
              );
            });
          })
          .timeout(limit);
      expect(service.table[ServiceAddress(app, appId)]?.endpoints, [hubUri]);

      // A worker that listens nowhere registers through the hub.
      final worker = Switchboard(
        muxOptions: mux,
        talkOptions: talkOptions,
        credential: await issue('worker-a1', workerKey, [
          Scope.of(Right.register, 'worker-*'),
        ]),
        holderKey: workerKey,
        verifier: await verifier(),
        expectedIdentityFor: (endpoint, record) =>
            endpoint == hubUri ? 'hub' : null,
      );
      addTearDown(worker.close);
      final workerMesh = MeshNode.join(
        worker,
        hubUri,
        talkOptions: talkOptions,
        watch: false,
      );
      addTearDown(workerMesh.leave);
      final workerId = await workerMesh
          .publish(workerType, (incoming) {
            final via = incoming.peerIdentity?.identity;
            incoming.talk().messages.listen((message) {
              message.reply(bytes('${text(message.payload)} done via $via'));
            });
          }, endpoints: const [])
          .timeout(limit);
      expect(
        service.table[ServiceAddress(workerType, workerId)]?.endpoints,
        isEmpty,
      );

      // A consumer that listens nowhere either: the service directly, the
      // worker through the hub's relay.
      final consumer = Switchboard(
        muxOptions: mux,
        talkOptions: talkOptions,
        credential: await issue('consumer-1', consumerKey, [
          Scope.of(Right.watch, '*'),
          Scope.of(Right.open, 'app'),
          Scope.of(Right.open, 'worker-*'),
        ]),
        holderKey: consumerKey,
        verifier: await verifier(),
        outgoingPolicy: ChannelPolicies.denyAll,
        expectedIdentityFor: (endpoint, record) =>
            endpoint == hubUri ? 'hub' : null,
        relay: RelayConfig(),
      );
      addTearDown(consumer.close);
      final consumerMesh = MeshNode.join(
        consumer,
        hubUri,
        talkOptions: talkOptions,
      );
      addTearDown(consumerMesh.leave);
      await consumerMesh.synced.timeout(limit);
      expect(consumer.canBroker, isFalse);

      expect(
        await call(consumer, ServiceAddress(app), 'ping').timeout(limit),
        'ping for consumer-1',
      );
      expect(
        await call(
          consumer,
          ServiceAddress(workerType, workerId),
          'job 1',
        ).timeout(limit),
        'job 1 done via hub',
      );
      expect(workerMesh.brokeredConnections, hasLength(1));
      expect(
        workerMesh.brokeredConnections.single.peerIdentity?.identity,
        'hub',
      );
      // The hub reaches its own service too, on the same in-process
      // connection as its naming channel.
      expect(
        await call(hub, ServiceAddress(app), 'self').timeout(limit),
        'self for hub',
      );

      // Every channel the hub opened to itself came over the in-process
      // pair: no socket from the hub to its own listener. The others came
      // over sockets.
      final own = arrivals.where((a) => a.identity == 'hub').toList();
      expect(own.map((a) => a.type), unorderedEquals([naming, app]));
      expect(own.map((a) => a.remote), everyElement('local'));
      final others = arrivals.where((a) => a.identity != 'hub').toList();
      expect(
        others.map((a) => (a.type, a.identity)),
        unorderedEquals([
          (naming, 'worker-a1'),
          (naming, 'consumer-1'),
          (app, 'consumer-1'),
        ]),
      );
      expect(others.map((a) => a.remote), everyElement(isNot('local')));
      expect(
        others.map((a) => a.remote),
        everyElement(startsWith('127.0.0.1:')),
      );
    });
  }
}
