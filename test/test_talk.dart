/*

Checklist
=========

- Can open and close a messaging channel
- Can send basic messages over the messaging channel both ways
- Can send basic messages requiring response over the messaging channel both ways
- Can respond with an abort message
- Can send a chain of three messages over the messaging channel both ways
- Can send a message requiring a stream response over the messaging channel both ways
- Exception occurs locally on both sides when a response times out
- Exception occurs locally on both sides when a the stream response times out
- First exception to occur is sent accross as an exception message
- Time extension messages extend the time for exception

*/

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import "package:test/test.dart";
import 'package:wstalk/wstalk.dart';

@Timeout(const Duration(seconds: 45))
HttpServer server;
MuxConnection serverMux;
MuxConnection clientMux;
TalkChannel serverChannel;
TalkChannel clientChannel;
Completer<void> awaitServer;

runServer() async {
  awaitServer = new Completer<void>();
  server = await HttpServer.bind('127.0.0.1', 9090);
  print("bound");
  () async {
    await for (HttpRequest request in server) {
      WebSocket ws;
      if (request.uri.path == '/ws') {
        print("connection");
        ws = await WebSocketTransformer.upgrade(request);
        if (ws == null) {
          awaitServer.completeError(new Exception("Not a WebSocket"));
          throw new Exception("Not a WebSocket");
        }
        serverMux = new MuxConnection(ws,
            onChannel: (MuxChannel channel, Uint8List payload) {
          print("server channel");
          serverChannel = new TalkChannel(channel);
          awaitServer.complete();
        });
      } else {
        awaitServer.completeError(new Exception("Bad Connection"));
        print("bad connection");
        // ...
      }
    }
    print("done");
  }();
}

runClient() async {
  WebSocket ws =
      await WebSocket.connect("ws://localhost:9090/ws", protocols: ['wstalk2']);
  print("connected");
  clientMux =
      new MuxConnection(ws, onChannel: (MuxChannel channel, Uint8List payload) {
    //print("client channel");
    //clientChannel = new TalkChannel(channel);
  });
  print("client channel");
  clientChannel = new TalkChannel(clientMux.openChannel(new Uint8List(0)));
}

void main() {
  setUp(() async {
    await runServer();
    await runClient();
    await awaitServer.future;
  });

  tearDown(() async {
    await serverMux.close();
    await clientMux.close();
    await server.close();
  });

  Random random = new Random();

  test("Can open and close a messaging channel", () async {
    expect(server, isNot(null));
    expect(serverMux, isNot(null));
    expect(clientMux, isNot(null));
    expect(serverMux.isOpen, equals(true));
    expect(clientMux.isOpen, equals(true));
    await serverMux.close();
    await clientMux.close();
    expect(serverMux.isOpen, equals(false));
    expect(clientMux.isOpen, equals(false));
    await for (TalkMessage message in serverChannel) {}
    await for (TalkMessage message in clientChannel) {}
  });

  test("Can send basic messages over the messaging channel both ways",
      () async {
    Uint8List sentPayload = Uint8List.fromList([
      random.nextInt(256),
      random.nextInt(256),
      random.nextInt(256),
      random.nextInt(256),
      random.nextInt(256),
      random.nextInt(256),
    ]);
    expect(serverChannel,
        emitsInOrder([new TalkMessage("HELLO", 0, 0, sentPayload), emitsDone]));
    expect(clientChannel,
        emitsInOrder([new TalkMessage("WORLD", 0, 0, sentPayload), emitsDone]));
    clientChannel.sendMessage("HELLO", sentPayload);
    serverChannel.sendMessage("WORLD", sentPayload);
    await serverChannel.close();
  });

  test("Reply to bad message should except", () async {
    expect(() async {
      serverChannel.replyMessage(
          new TalkMessage("ABC", 5, 0, new Uint8List(0)), "XYZ", new Uint8List(0));
    }(), throwsA(isInstanceOf<TalkException>()));
    expect(serverChannel, emitsInOrder([emitsDone]));
    expect(clientChannel, emitsInOrder([emitsDone]));
    await clientChannel.close();
  });

  test(
      "Can send basic messages requiring response over the messaging channel both ways",
      () async {
    Uint8List sentPayload = Uint8List.fromList([
      random.nextInt(256),
      random.nextInt(256),
      random.nextInt(256),
      random.nextInt(256),
      random.nextInt(256),
      random.nextInt(256),
    ]);
    Completer<void> c = new Completer<void>();
    serverChannel.listen((TalkMessage message) {
      serverChannel.replyMessage(message, "WORLD", message.data);
      c.complete();
    }, onError: (error, stack) {
      fail("$error\n$stack");
    });
    expect(clientChannel,
        emitsInOrder([new TalkMessage("WORLD", 0, 1, sentPayload), emitsDone]));
    clientChannel.sendRequest("HELLO", sentPayload);
    await c.future;
    await clientChannel.close();
  });
}

/* end of file */
