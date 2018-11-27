/*
Switchboard
Microservice Network Architecture
Copyright (C) 2018  NO-BREAK SPACE OÜ
Author: Jan Boon <kaetemi@no-break.space>
*/

/*

Checklist
=========

- Can open and close a messaging channel
- Can send basic messages over the messaging channel both ways
- Can send basic messages requiring response over the messaging channel both ways
- Can respond with an abort message
- No infinite loop in failure when sending a message with fake request and response id
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

import 'package:logging/logging.dart';
import "package:test/test.dart";
import 'package:switchboard/switchboard.dart';

@Timeout(const Duration(seconds: 45))
HttpServer server;
MuxConnection serverMux;
MuxConnection clientMux;
TalkChannel serverChannel;
TalkChannel clientChannel;
Completer<void> awaitServer;

runServer() async {
  awaitServer = new Completer<void>();
  server = await HttpServer.bind('127.0.0.1', 9092);
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
      await WebSocket.connect("ws://localhost:9092/ws", protocols: ['wstalk2']);
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
  hierarchicalLoggingEnabled = true;
  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((LogRecord rec) {
    print('${rec.loggerName}: ${rec.level.name}: ${rec.time}: ${rec.message}');
  });
  new Logger('Switchboard').level = Level.ALL;
  new Logger('Switchboard.Mux').level = Level.ALL;
  new Logger('Switchboard.Talk').level = Level.ALL;
  new Logger('Switchboard.Router').level = Level.ALL;
  

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
    expect(
        serverChannel,
        emitsInOrder([
          new TalkMessage(serverChannel, "HELLO", 0, 0, false, sentPayload),
          emitsDone
        ]));
    expect(
        clientChannel,
        emitsInOrder([
          new TalkMessage(clientChannel, "WORLD", 0, 0, false, sentPayload),
          emitsDone
        ]));
    clientChannel.sendMessage("HELLO", sentPayload);
    serverChannel.sendMessage("WORLD", sentPayload);
    await serverChannel.close();
  });

  test("Reply to bad message should except", () async {
    expect(() async {
      serverChannel.replyMessage(
          new TalkMessage(serverChannel, "ABC", 5, 0, false,
              new Uint8List(0)), // non-existent message
          "XYZ",
          new Uint8List(0));
    }(), throwsA(isInstanceOf<TalkException>()));
    expect(serverChannel, emitsInOrder([emitsDone]));
    expect(clientChannel, emitsInOrder([emitsDone]));
    await clientChannel.close();
  });

  test("Sending a bad reply should return an abort", () async {
    serverChannel.outgoingSafety = false;
    serverChannel.replyMessage(
        new TalkMessage(serverChannel, "ABC", 5, 0, false,
            new Uint8List(0)), // non-existent message
        "XYZ",
        new Uint8List(0));
    expect(serverChannel,
        emitsInOrder([emitsError(isInstanceOf<TalkAbort>()), emitsDone]));
    expect(clientChannel, emitsInOrder([emitsDone]));
    await new Future.delayed(new Duration(seconds: 1));
    await serverChannel.close();
  });

  test("Can send basic request messages and receive response", () async {
    Uint8List sentPayload = Uint8List.fromList([
      random.nextInt(256),
      random.nextInt(256),
      random.nextInt(256),
      random.nextInt(256),
      random.nextInt(256),
      random.nextInt(256),
    ]);
    serverChannel.listen((TalkMessage message) {
      serverChannel.replyMessage(message, "WORLD", message.data);
      serverChannel.close();
    }, onError: (error, stackTrace) {
      fail("$error\n$stackTrace");
    });
    expect(
        await clientChannel.sendRequest("HELLO", sentPayload),
        equals(
            new TalkMessage(clientChannel, "WORLD", 0, 1, false, sentPayload)));
  });

  test("Can reply to stream", () async {
    Uint8List sentPayload = Uint8List.fromList([
      random.nextInt(256),
      random.nextInt(256),
      random.nextInt(256),
      random.nextInt(256),
      random.nextInt(256),
      random.nextInt(256),
    ]);
    serverChannel.listen((TalkMessage message) {
      serverChannel.replyMessage(message, "WORLD", message.data);
      serverChannel.replyMessage(message, "WORLD", message.data);
      serverChannel.replyMessage(message, "WORLD", message.data);
      serverChannel.replyMessage(message, "WORLD", message.data);
      serverChannel.replyMessage(message, "WORLD", message.data);
      serverChannel.replyMessage(message, "WORLD", message.data);
      serverChannel.replyEndOfStream(message);
      serverChannel.close();
    }, onError: (error, stackTrace) {
      fail("$error\n$stackTrace");
    });
    expect(
      clientChannel.sendStreamRequest("HELLO", sentPayload),
      emitsInOrder(
        [
          new TalkMessage(clientChannel, "WORLD", 0, 1, false, sentPayload),
          new TalkMessage(clientChannel, "WORLD", 0, 1, false, sentPayload),
          new TalkMessage(clientChannel, "WORLD", 0, 1, false, sentPayload),
          new TalkMessage(clientChannel, "WORLD", 0, 1, false, sentPayload),
          new TalkMessage(clientChannel, "WORLD", 0, 1, false, sentPayload),
          new TalkMessage(clientChannel, "WORLD", 0, 1, false, sentPayload),
          emitsDone
        ],
      ),
    );
  });

  test(
      "Not sending a reply to a message in time should receive abort from remote",
      () async {
    // Test for exception generated by clientChannel
    serverChannel.outgoingSafety = false;
    expect(() async {
      await serverChannel.sendRequest("HALO", new Uint8List(0));
    }(), throwsA(isInstanceOf<TalkAbort>()));
  });

  test("Not receiving a reply to a message in time should abort locally",
      () async {
    // Test for exception generated by serverChannel
    clientChannel.outgoingSafety = false; // Disable remotely sent exception
    expect(() async {
      await serverChannel.sendRequest("HALO", new Uint8List(0));
    }(), throwsA(isInstanceOf<TalkAbort>()));
  });

  test("Can reply to stream slowly", () async {
    Uint8List sentPayload = Uint8List.fromList([
      random.nextInt(256),
      random.nextInt(256),
      random.nextInt(256),
      random.nextInt(256),
      random.nextInt(256),
      random.nextInt(256),
    ]);
    serverChannel.listen((TalkMessage message) async {
      serverChannel.replyMessage(message, "WORLD", message.data);
      await new Future.delayed(new Duration(seconds: 5));
      serverChannel.replyMessage(message, "WORLD", message.data);
      await new Future.delayed(new Duration(seconds: 5));
      serverChannel.replyMessage(message, "WORLD", message.data);
      await new Future.delayed(new Duration(seconds: 5));
      serverChannel.replyMessage(message, "WORLD", message.data);
      serverChannel.replyExtend(message);
      serverChannel.replyExtend(message);
      serverChannel.replyExtend(message);
      await new Future.delayed(new Duration(seconds: 5));
      serverChannel.replyMessage(message, "WORLD", message.data);
      serverChannel.replyMessage(message, "WORLD", message.data);
      serverChannel.replyEndOfStream(message);
      serverChannel.close();
    }, onError: (error, stackTrace) {
      fail("$error\n$stackTrace");
    });
    expect(
      clientChannel.sendStreamRequest("HELLO", sentPayload),
      emitsInOrder(
        [
          new TalkMessage(clientChannel, "WORLD", 0, 1, false, sentPayload),
          new TalkMessage(clientChannel, "WORLD", 0, 1, false, sentPayload),
          new TalkMessage(clientChannel, "WORLD", 0, 1, false, sentPayload),
          new TalkMessage(clientChannel, "WORLD", 0, 1, false, sentPayload),
          new TalkMessage(clientChannel, "WORLD", 0, 1, false, sentPayload),
          new TalkMessage(clientChannel, "WORLD", 0, 1, false, sentPayload),
          emitsDone
        ],
      ),
    );
  });

  test("Can extend message reply", () async {
    Uint8List sentPayload = Uint8List.fromList([
      random.nextInt(256),
      random.nextInt(256),
      random.nextInt(256),
      random.nextInt(256),
      random.nextInt(256),
      random.nextInt(256),
    ]);
    serverChannel.listen((TalkMessage message) async {
      serverChannel.replyExtend(message);
      await new Future.delayed(new Duration(seconds: 5));
      serverChannel.replyExtend(message);
      await new Future.delayed(new Duration(seconds: 5));
      serverChannel.replyExtend(message);
      await new Future.delayed(new Duration(seconds: 5));
      serverChannel.replyExtend(message);
      await new Future.delayed(new Duration(seconds: 5));
      serverChannel.replyMessage(message, "WORLD", message.data);
      serverChannel.close();
    }, onError: (error, stackTrace) {
      fail("$error\n$stackTrace");
    });
    expect(
        await clientChannel.sendRequest("HELLO", sentPayload),
        equals(
            new TalkMessage(clientChannel, "WORLD", 0, 1, false, sentPayload)));
  });
}

/* end of file */
