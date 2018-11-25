/*
Switchboard
Microservice Network Architecture
Copyright (C) 2018  NO-BREAK SPACE OÜ
Author: Jan Boon <kaetemi@no-break.space>
*/

/*

Checklist
=========

- Can make basic connection
- Can open and close raw channels with opening payload
- Can send messages over raw channels
- Exception when sending messages over closed channels
- (Not tested) Exception when receiving message over remotely closed channel

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
Completer<MuxChannel> channelCompleter;
Completer<Uint8List> payloadCompleter;

void onChannel(MuxChannel channel, Uint8List payload) {
  channelCompleter.complete(channel);
  payloadCompleter.complete(payload);
}

runServer() async {
  server = await HttpServer.bind('127.0.0.1', 9090);
  print("bound");
  () async {
    await for (HttpRequest request in server) {
      WebSocket ws;
      if (request.uri.path == '/ws') {
        print("connection");
        ws = await WebSocketTransformer.upgrade(request);
        if (ws == null) throw Exception("Not a WebSocket");
        serverMux = new MuxConnection(ws, onChannel: onChannel);
      } else {
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
  clientMux = new MuxConnection(ws, onChannel: onChannel);
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
  });

  tearDown(() async {
    await serverMux.close();
    await clientMux.close();
    await server.close();
  });

  Random random = new Random();

  test("Can make basic connection", () async {
    expect(server, isNot(null));
    expect(serverMux, isNot(null));
    expect(clientMux, isNot(null));
    expect(serverMux.isOpen, equals(true));
    expect(clientMux.isOpen, equals(true));
    await serverMux.close();
    await clientMux.close();
    expect(serverMux.isOpen, equals(false));
    expect(clientMux.isOpen, equals(false));
  });

  test("Can open and close raw channels with opening payload", () async {
    Uint8List sentPayload = Uint8List.fromList([
      random.nextInt(256),
      random.nextInt(256),
      random.nextInt(256),
      random.nextInt(256),
      random.nextInt(256),
      random.nextInt(256),
    ]);
    channelCompleter = new Completer<MuxChannel>();
    payloadCompleter = new Completer<Uint8List>();
    MuxChannel clientMuxChannel = clientMux.openChannel(sentPayload);
    MuxChannel serverMuxChannel = await channelCompleter.future;
    Uint8List receivedPayload = await payloadCompleter.future;
    expect(receivedPayload, equals(sentPayload));
    clientMuxChannel.close();
    await for (dynamic _ in clientMuxChannel) {}
    await for (dynamic _ in serverMuxChannel) {}
    await clientMuxChannel.done;
    await serverMuxChannel.done;
  });

  test("Can open and close multiple raw channels with opening payload",
      () async {
    List<MuxChannel> channels = new List<MuxChannel>();
    for (int i = 0; i < 64; ++i) {
      print(i++);
      Uint8List sentPayload = Uint8List.fromList([
        random.nextInt(256),
        random.nextInt(256),
        random.nextInt(256),
        random.nextInt(256),
        random.nextInt(256),
        random.nextInt(256),
      ]);
      channelCompleter = new Completer<MuxChannel>();
      payloadCompleter = new Completer<Uint8List>();
      MuxChannel clientMuxChannel =
          (((i & 1) == 1) ? clientMux : serverMux).openChannel(sentPayload);
      MuxChannel serverMuxChannel = await channelCompleter.future;
      Uint8List receivedPayload = await payloadCompleter.future;
      expect(receivedPayload, equals(sentPayload));
      channels.add(clientMuxChannel);
      channels.add(serverMuxChannel);
    }
    int i = 0;
    for (MuxChannel channel in channels) {
      print(i++);
      channel.close();
    }
    i = 0;
    for (MuxChannel channel in channels) {
      print(i++);
      await for (dynamic f in channel) {}
      await channel.done;
    }
  });

  test("Channels close when connection closes", () async {
    Uint8List sentPayload = Uint8List.fromList([
      random.nextInt(256),
      random.nextInt(256),
      random.nextInt(256),
      random.nextInt(256),
      random.nextInt(256),
      random.nextInt(256),
    ]);
    channelCompleter = new Completer<MuxChannel>();
    payloadCompleter = new Completer<Uint8List>();
    MuxChannel clientMuxChannel = clientMux.openChannel(sentPayload);
    MuxChannel serverMuxChannel = await channelCompleter.future;
    Uint8List receivedPayload = await payloadCompleter.future;
    expect(receivedPayload, equals(sentPayload));
    await serverMux.close();
    await for (dynamic f in clientMuxChannel) {}
    await for (dynamic f in serverMuxChannel) {}
    await clientMuxChannel.done;
    await serverMuxChannel.done;
    expect(serverMux.isOpen, equals(false));
    expect(clientMux.isOpen, equals(false));
  });

  test("Can send messages over raw channels", () async {
    Uint8List sentPayload = Uint8List.fromList([
      random.nextInt(256),
      random.nextInt(256),
      random.nextInt(256),
      random.nextInt(256),
      random.nextInt(256),
      random.nextInt(256),
    ]);
    channelCompleter = new Completer<MuxChannel>();
    payloadCompleter = new Completer<Uint8List>();
    MuxChannel clientMuxChannel = serverMux.openChannel(sentPayload);
    MuxChannel serverMuxChannel = await channelCompleter.future;
    Uint8List receivedPayload = await payloadCompleter.future;
    expect(receivedPayload, equals(sentPayload));
    Uint8List sentMessageClient = Uint8List.fromList([
      random.nextInt(256),
      random.nextInt(256),
      random.nextInt(256),
      random.nextInt(256),
      random.nextInt(256),
      random.nextInt(256),
    ]);
    clientMuxChannel.add(sentMessageClient);
    Uint8List sentMessageServer = Uint8List.fromList([
      random.nextInt(256),
      random.nextInt(256),
      random.nextInt(256),
      random.nextInt(256),
      random.nextInt(256),
      random.nextInt(256),
    ]);
    serverMuxChannel.add(sentMessageServer);
    clientMuxChannel.close();
    expect(clientMuxChannel, emitsInOrder([sentMessageServer, emitsDone]));
    expect(serverMuxChannel, emitsInOrder([sentMessageClient, emitsDone]));
    await clientMuxChannel.done;
    await serverMuxChannel.done;
  }); //

  test("Exception when sending messages over closed channels", () async {
    Uint8List sentPayload = Uint8List.fromList([
      random.nextInt(256),
      random.nextInt(256),
      random.nextInt(256),
      random.nextInt(256),
      random.nextInt(256),
      random.nextInt(256),
    ]);
    channelCompleter = new Completer<MuxChannel>();
    payloadCompleter = new Completer<Uint8List>();
    MuxChannel clientMuxChannel = serverMux.openChannel(sentPayload);
    MuxChannel serverMuxChannel = await channelCompleter.future;
    Uint8List receivedPayload = await payloadCompleter.future;
    expect(receivedPayload, equals(sentPayload));
    clientMuxChannel.close();
    expect(() async {
      clientMuxChannel.add(sentPayload);
    }(), throwsA(isInstanceOf<MuxException>()));
  });
}

/* end of file */
