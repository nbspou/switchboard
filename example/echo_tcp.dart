// Server and client over TCP in one process: a request and a stream request.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:switchboard/switchboard.dart';

Future<void> main(List<String> args) async {
  // `-v` shows the library's own log.
  if (args.contains('-v')) {
    Logger.root.level = Level.FINE;
    Logger.root.onRecord.listen(
      (r) => print('  ${r.loggerName}: ${r.message}'),
    );
  }
  final echo = Name('echo');

  // The server runs instance 1 of `echo` and listens on a free port.
  final server = Switchboard();
  server.registerService(echo, (incoming) {
    incoming.talk().messages.listen((message) {
      if (!message.expectsReply) {
        return; // A plain message; nothing to answer.
      }
      switch (message.procedureName) {
        case 'UPPER':
          final text = utf8.decode(message.payload);
          message.reply(utf8.encode(text.toUpperCase()));
        case 'COUNT':
          for (var i = 1; i <= 3; i++) {
            message.replyItem(utf8.encode('$i'));
          }
          message.reply(utf8.encode('done'));
        default:
          message.replyAbort(Status.of(StatusCode.unimplemented));
      }
    });
  }, instance: 1);
  final uri = await server.listenTcp(
    InternetAddress.loopbackIPv4,
    0,
    policy: ChannelPolicies.allowTypes({echo}),
  );
  print('server: listening on $uri');

  // The client finds `echo` in a static table.
  final resolver = StaticResolver([
    ServiceRecord(ServiceAddress(echo, 1), endpoints: [uri]),
  ]);
  final client = Switchboard(resolver: resolver);
  final talk = await client.openTalk(ServiceAddress(echo));

  final reply = await talk.request('UPPER', utf8.encode('hello'));
  print('client: UPPER hello -> ${utf8.decode(reply.payload)}');

  final stream = talk.streamRequest('COUNT', Uint8List(0));
  await for (final item in stream.items) {
    print('client: COUNT item ${utf8.decode(item.payload)}');
  }
  print('client: COUNT final ${utf8.decode((await stream.done).payload)}');

  // Close the channel, then the nodes. The resolver belongs to the caller.
  await talk.close();
  await client.close();
  await server.close();
  await resolver.close();
}
