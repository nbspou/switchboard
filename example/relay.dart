// Outbound-only on both ends: a worker and a client that listen nowhere,
// joined through a relay node. Credentials are required everywhere.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:switchboard/switchboard.dart';

Future<void> main() async {
  final work = Name('work');
  final loopback = InternetAddress.loopbackIPv4;

  // The mesh authority issues every node a credential with the rights it
  // needs, bound to the node's own key.
  final authority = await CredentialIssuer.ed25519FromSeed(
    Name('auth1'),
    List.generate(32, (i) => i),
  );
  final verifier = CredentialVerifier();
  await verifier.addIssuer(authority);
  Future<(Credential, HolderKey)> identity(
    String name,
    List<Scope> scopes,
  ) async {
    final key = await HolderKey.generate();
    final credential = await authority.issue(
      kind: CredentialKind.node,
      identity: name,
      scopes: scopes,
      holderKey: key.publicKey,
    );
    return (credential, key);
  }

  // Nodes name the naming service when they identify to it; relays are
  // named from their records.
  late final Uri namingUri;
  String? namesTheNamingService(Uri endpoint, ServiceRecord? record) =>
      endpoint == namingUri ? 'ns' : null;

  // The naming node requires credentials, and IDENTs that name it.
  final (nsCredential, nsKey) = await identity('ns', const []);
  final namingNode = Switchboard(
    muxOptions: const MuxOptions(requireNamedIdent: true),
    credential: nsCredential,
    holderKey: nsKey,
    verifier: verifier,
  );
  final naming = NamingService(
    assignmentHold: Duration.zero,
    verifier: verifier,
    requireCredential: true,
  );
  namingNode.registerService(Services.naming, naming.handler, instance: 1);
  namingUri = await namingNode.listenTcp(
    loopback,
    0,
    policy: ChannelPolicies.scoped(),
  );
  print('naming: listening on $namingUri');

  // The relay listens where both ends can reach it, and publishes `_relay`
  // with its identity. It may broker and open `work`.
  final (relayCredential, relayKey) = await identity('relay-1', [
    Scope.of(Right.register, '_relay'),
    Scope.of(Right.watch, '*'),
    Scope.of(Right.open, 'work'),
    Scope.of(Right.broker, 'work'),
  ]);
  final relayNode = Switchboard(
    muxOptions: const MuxOptions(requireNamedIdent: true),
    credential: relayCredential,
    holderKey: relayKey,
    verifier: verifier,
    expectedIdentityFor: namesTheNamingService,
  );
  final relayUri = await relayNode.listenTcp(
    loopback,
    0,
    policy: ChannelPolicies.scoped(),
  );
  final relayMesh = MeshNode.join(relayNode, namingUri);
  await relayMesh.synced;
  await relayMesh.publishRelay(RelayService(relayNode));
  print('relay: listening on $relayUri');

  // The worker listens nowhere and may only register its type.
  final (workerCredential, workerKey) = await identity('worker-1', [
    Scope.of(Right.register, 'work'),
  ]);
  final worker = Switchboard(
    credential: workerCredential,
    holderKey: workerKey,
    verifier: verifier,
    expectedIdentityFor: namesTheNamingService,
  );
  final workerMesh = MeshNode.join(worker, namingUri, watch: false);
  final id = await workerMesh.publish(work, (incoming) {
    final via = incoming.peerIdentity?.identity;
    incoming.talk().messages.listen((message) {
      if (message.expectsReply) {
        final job = utf8.decode(message.payload);
        message.reply(utf8.encode('$job done, reached through $via'));
      }
    });
  }, endpoints: const []);
  print('worker: published ${ServiceAddress(work, id)} without endpoints');

  // The client listens nowhere either, so it cannot have the worker dial
  // it: with a relay configured, its channel goes through the relay.
  final (clientCredential, clientKey) = await identity('client-1', [
    Scope.of(Right.watch, '*'),
    Scope.of(Right.open, 'work'),
  ]);
  final client = Switchboard(
    credential: clientCredential,
    holderKey: clientKey,
    verifier: verifier,
    expectedIdentityFor: namesTheNamingService,
    relay: RelayConfig(),
  );
  final clientMesh = MeshNode.join(client, namingUri);
  await clientMesh.synced;
  final talk = await client.openTalk(ServiceAddress(work, id));
  final reply = await talk.request(
    'RUN',
    Uint8List.fromList(utf8.encode('job 1')),
  );
  print('client: ${utf8.decode(reply.payload)}');
  await talk.close();

  // Leave the mesh before closing a node; the naming node goes last.
  for (final (mesh, node) in [
    (clientMesh, client),
    (workerMesh, worker),
    (relayMesh, relayNode),
  ]) {
    await mesh.leave();
    await node.close();
  }
  await naming.close();
  await namingNode.close();
}
