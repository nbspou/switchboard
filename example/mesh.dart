// A small mesh: a naming node, a backend publishing a service, a client.
import 'dart:convert';
import 'dart:io';

import 'package:switchboard/switchboard.dart';

Future<void> main() async {
  final greet = Name('greet');
  final loopback = InternetAddress.loopbackIPv4;

  // The naming node hosts the naming service as `_ns/1`. The hold delays
  // assignments after a restart so that surviving services get their ids
  // back; this mesh is new, so it is turned off.
  final namingNode = Switchboard();
  final naming = NamingService(assignmentHold: Duration.zero);
  namingNode.registerService(Services.naming, naming.handler, instance: 1);
  final namingUri = await namingNode.listenTcp(loopback, 0);
  naming.registerLocal(
    Services.naming,
    namingNode.listeningEndpoints,
    instance: 1,
  );
  print('naming: listening on $namingUri');

  // The backend listens first: publish() registers its listening endpoints.
  final backend = Switchboard();
  await backend.listenTcp(loopback, 0);
  final backendMesh = MeshNode.join(backend, namingUri);
  final id = await backendMesh.publish(greet, (incoming) {
    final self = incoming.address.address;
    incoming.talk().messages.listen((message) {
      if (message.expectsReply) {
        final name = utf8.decode(message.payload);
        message.reply(utf8.encode('hello $name, this is $self'));
      }
    });
  });
  print('backend: published ${ServiceAddress(greet, id)}');

  // The client joins the mesh and resolves through the mirrored table.
  final client = Switchboard();
  final clientMesh = MeshNode.join(client, namingUri);
  await clientMesh.synced;
  print('client: table ${clientMesh.client.table.keys.join(', ')}');
  final talk = await client.openTalk(ServiceAddress(greet));
  final reply = await talk.request('HELLO', utf8.encode('client'));
  print('client: ${utf8.decode(reply.payload)}');
  await talk.close();

  // Leave the mesh before closing a node; the naming node goes last.
  await clientMesh.leave();
  await client.close();
  await backendMesh.leave();
  await backend.close();
  await naming.close();
  await namingNode.close();
}
