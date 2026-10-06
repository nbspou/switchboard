// A frontend endpoint proxying `chat` channels from clients to a backend.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:switchboard/switchboard.dart';

Future<void> main() async {
  final chat = Name('chat');
  final loopback = InternetAddress.loopbackIPv4;

  // A backend runs `chat/7` behind the endpoint. It sees the client's own
  // credential in the application payload.
  final backend = Switchboard();
  backend.registerService(chat, (incoming) {
    final address = incoming.address;
    final credential = utf8.decode(address.payload);
    incoming.talk().messages.listen((message) {
      if (message.expectsReply) {
        message.reply(utf8.encode('${address.address} got "$credential"'));
      }
    });
  }, instance: 7);
  final backendUri = await backend.listenTcp(loopback, 0);

  // The endpoint resolves backends itself (a static table here, a MeshNode
  // in a mesh) and proxies every channel that no local service claims.
  final table = StaticResolver([
    ServiceRecord(ServiceAddress(chat, 7), endpoints: [backendUri]),
  ]);
  final endpoint = Switchboard(resolver: table);
  endpoint.catchAll = proxyHandler(
    endpoint,
    // Checked for every channel: `chat` only, with a credential.
    allow: (address) => address.type == chat && address.payload.isNotEmpty,
    // `authorize:` could also verify it asynchronously and rewrite the address.
  );
  // Internet facing, so the listener has a policy. It refuses every type
  // but `chat`, including the reserved ones such as `_ns`.
  final endpointUri = await endpoint.listenWebSocket(
    loopback,
    0,
    path: '/sb',
    policy: ChannelPolicies.allowTypes({chat}),
  );
  print('endpoint: listening on $endpointUri');

  // A client only knows the endpoint. Its default payload is its session.
  final client = Switchboard(
    resolver: EndpointResolver(endpointUri),
    defaultPayload: utf8.encode('session-42'),
  );
  final talk = await client.openTalk(ServiceAddress(chat));
  final reply = await talk.request('WHO', Uint8List(0));
  print('client: ${utf8.decode(reply.payload)}');
  await talk.close();

  // Refused channels end with PERMISSION_DENIED and a generic reason.
  for (final type in [Services.naming, Name('admin')]) {
    final refused = await client.openChannel(ServiceAddress(type));
    print('client: $type -> ${await refused.done}');
  }
  final anonymous = await client.openChannel(
    ServiceAddress(chat),
    payload: Uint8List(0),
  );
  print('client: chat without a session -> ${await anonymous.done}');

  await client.close();
  await endpoint.close();
  await backend.close();
  await table.close();
}
