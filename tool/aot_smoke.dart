/*
Polyverse Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Authors:
  Jan Boon <jan.boon@kaetemi.be>
  Claude Fable 5.1 <noreply@anthropic.com>
*/

// A native (AOT) smoke check: the JIT test suite cannot catch optimiser
// bugs of `dart compile exe`. Compile and run it with tool/aot_smoke.sh.
//
// It runs a naming service and a mesh node in one process over `mem://`,
// the node registering a service and watching every type (the shape that
// crashed Dart 3.13.5 AOT binaries in the naming service's WATCH handler),
// then opens a channel through the mirrored table. It prints `ok` and
// exits 0, or fails.
import 'dart:convert';
import 'dart:io';

import 'package:switchboard/switchboard.dart';

Future<void> main() async {
  final greet = Name('greet');
  final namingNode = Switchboard();
  final naming = NamingService(assignmentHold: Duration.zero);
  namingNode.registerService(Services.naming, naming.handler, instance: 1);
  final namingUri = await namingNode.listenMemory();
  naming.registerLocal(Services.naming, [namingUri], instance: 1);

  final backend = Switchboard();
  await backend.listenMemory();
  final backendMesh = MeshNode.join(backend, namingUri);
  final id = await backendMesh.publish(greet, (incoming) {
    incoming.talk().messages.listen((message) {
      if (message.expectsReply) {
        message.reply(utf8.encode('hello ${utf8.decode(message.payload)}'));
      }
    });
  });
  await backendMesh.synced;

  final client = Switchboard();
  final clientMesh = MeshNode.join(client, namingUri);
  await clientMesh.synced.timeout(const Duration(seconds: 10));
  final seen = clientMesh.client.table.keys.map((a) => '$a').toList()..sort();
  final talk = await client.openTalk(ServiceAddress(greet));
  final reply = await talk.request('HELLO', utf8.encode('aot'));
  final text = utf8.decode(reply.payload);
  await talk.close();

  await clientMesh.leave();
  await client.close();
  await backendMesh.leave();
  await backend.close();
  await naming.close();
  await namingNode.close();

  final expected = ['_ns/1', 'greet/$id']..sort();
  if ('$seen' != '$expected' || text != 'hello aot') {
    stderr.writeln('aot smoke failed: table $seen, reply "$text"');
    exit(1);
  }
  print('ok');
}
