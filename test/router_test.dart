/*
Switchboard
Microservice Network Architecture
Copyright (C) 2018  NO-BREAK SPACE OÜ
Author: Jan Boon <kaetemi@no-break.space>
*/

// TODO: Test case for proper reconnection if server disconnects

import 'dart:math';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:async/async.dart';
import "package:test/test.dart";
import 'package:switchboard/switchboard.dart';

@Timeout(const Duration(seconds: 5))
Switchboard server;
Switchboard client;

Future<void> runServer() async {
  server = new Switchboard();
  await server.bindWebSocket("localhost", 9091, "/ws");
}

Future<void> runClient() async {
  client = new Switchboard();
  client.setEndPoint("ws://localhost:9091/ws");
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
    await server.close();
    await client.close();
  });

  Random random = new Random();

  test("Can make basic connection and send message", () async {
    Uint8List connectionPayload = Uint8List.fromList([
      random.nextInt(256),
      random.nextInt(256),
      random.nextInt(256),
      random.nextInt(256),
      random.nextInt(256),
      random.nextInt(256),
    ]);
    Uint8List messagePayload = Uint8List.fromList([
      random.nextInt(256),
      random.nextInt(256),
      random.nextInt(256),
      random.nextInt(256),
      random.nextInt(256),
      random.nextInt(256),
    ]);
    expect(server, isNot(null));
    expect(client, isNot(null));
    client.setPayload(connectionPayload);
    StreamQueue<ChannelInfo> serverQueue = new StreamQueue<ChannelInfo>(server);
    StreamQueue<ChannelInfo> clientQueue = new StreamQueue<ChannelInfo>(client);
    client.sendMessage("api", "HELLO", messagePayload);
    ChannelInfo serverChannelInfo = await serverQueue.next;
    expect(serverChannelInfo.host, equals("localhost"));
    expect(serverChannelInfo.service, equals("api"));
    expect(serverChannelInfo.payload, equals(connectionPayload));
    TalkChannel serverChannel = new TalkChannel(serverChannelInfo.channel);
    StreamQueue<TalkMessage> serverMessageQueue =
        new StreamQueue<TalkMessage>(serverChannel);
    TalkMessage message = await serverMessageQueue.next;
    expect(message.procedureId, equals("HELLO"));
    expect(message.data, equals(messagePayload));
    serverMessageQueue.cancel();
    serverQueue.cancel();
    clientQueue.cancel();
  });

  test("Can change endpoint payload", () async {
    Uint8List firstPayload = Uint8List.fromList([
      random.nextInt(256),
      random.nextInt(256),
      random.nextInt(256),
      random.nextInt(256),
      random.nextInt(256),
      random.nextInt(256),
    ]);
    Uint8List secondPayload = Uint8List.fromList([
      random.nextInt(256),
      random.nextInt(256),
      random.nextInt(256),
      random.nextInt(256),
      random.nextInt(256),
      random.nextInt(256),
    ]);
    Uint8List messagePayload = Uint8List.fromList([
      random.nextInt(256),
      random.nextInt(256),
      random.nextInt(256),
      random.nextInt(256),
      random.nextInt(256),
      random.nextInt(256),
    ]);
    client.setPayload(firstPayload);
    StreamQueue<ChannelInfo> serverQueue = new StreamQueue<ChannelInfo>(server);
    StreamQueue<ChannelInfo> clientQueue = new StreamQueue<ChannelInfo>(client);
    client.sendMessage("api", "HELLO", messagePayload);
    client.setPayload(secondPayload);
    client.sendMessage("api", "WORLD", messagePayload);
    {
      ChannelInfo serverChannelInfo = await serverQueue.next;
      expect(serverChannelInfo.host, equals("localhost"));
      expect(serverChannelInfo.service, equals("api"));
      expect(serverChannelInfo.payload, equals(firstPayload));
      TalkChannel serverChannel = new TalkChannel(serverChannelInfo.channel);
      StreamQueue<TalkMessage> serverMessageQueue =
          new StreamQueue<TalkMessage>(serverChannel);
      TalkMessage message = await serverMessageQueue.next;
      expect(message.procedureId, equals("HELLO"));
      expect(message.data, equals(messagePayload));
      serverMessageQueue.cancel();
      print("1");
    }
    {
      ChannelInfo serverChannelInfo = await serverQueue.next;
      expect(serverChannelInfo.host, equals("localhost"));
      expect(serverChannelInfo.service, equals("api"));
      expect(serverChannelInfo.payload, equals(secondPayload));
      TalkChannel serverChannel = new TalkChannel(serverChannelInfo.channel);
      StreamQueue<TalkMessage> serverMessageQueue =
          new StreamQueue<TalkMessage>(serverChannel);
      TalkMessage message = await serverMessageQueue.next;
      expect(message.procedureId, equals("WORLD"));
      expect(message.data, equals(messagePayload));
      serverMessageQueue.cancel();
      print("2");
    }
    serverQueue.cancel();
    clientQueue.cancel();
  });

  test("Can reconnect", () async {
    Uint8List payload = Uint8List.fromList([
      random.nextInt(256),
      random.nextInt(256),
      random.nextInt(256),
      random.nextInt(256),
      random.nextInt(256),
      random.nextInt(256),
    ]);
    StreamQueue<ChannelInfo> serverQueue = new StreamQueue<ChannelInfo>(server);
    StreamQueue<ChannelInfo> clientQueue = new StreamQueue<ChannelInfo>(client);
    client.setPayload(payload);
    client.sendMessage("api", "HELLO", payload);
    {
      ChannelInfo serverChannelInfo = await serverQueue.next;
      expect(serverChannelInfo.host, equals("localhost"));
      expect(serverChannelInfo.service, equals("api"));
      expect(serverChannelInfo.payload, equals(payload));
      TalkChannel serverChannel = new TalkChannel(serverChannelInfo.channel);
      StreamQueue<TalkMessage> serverMessageQueue =
          new StreamQueue<TalkMessage>(serverChannel);
      TalkMessage message = await serverMessageQueue.next;
      expect(message.procedureId, equals("HELLO"));
      expect(message.data, equals(payload));
      serverMessageQueue.cancel();
      print("1");
    }
    serverQueue.cancel();
    await server.close();
    await Future<void>.delayed(new Duration(seconds: 2));
    expect(() async {
      await client.sendMessage("api", "MY", payload);
    }(), throwsA(isInstanceOf<Exception>()));
    print("x");
    await Future<void>.delayed(new Duration(seconds: 2));
    server = Switchboard();
    await server.bindWebSocket("localhost", 9091, "/ws");
    print("y");
    await client.sendMessage("api", "WORLD", payload);
    print("z");
    serverQueue = new StreamQueue<ChannelInfo>(server);
    {
      ChannelInfo serverChannelInfo = await serverQueue.next;
      expect(serverChannelInfo.host, equals("localhost"));
      expect(serverChannelInfo.service, equals("api"));
      expect(serverChannelInfo.payload, equals(payload));
      TalkChannel serverChannel = new TalkChannel(serverChannelInfo.channel);
      StreamQueue<TalkMessage> serverMessageQueue =
          new StreamQueue<TalkMessage>(serverChannel);
      TalkMessage message = await serverMessageQueue.next;
      expect(message.procedureId, equals("WORLD"));
      expect(message.data, equals(payload));
      serverMessageQueue.cancel();
      print("2");
    }
    serverQueue.cancel();
    clientQueue.cancel();
  });
}

/* end of file */
