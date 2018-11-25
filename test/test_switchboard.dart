/*
Switchboard
Microservice Network Architecture
Copyright (C) 2018  NO-BREAK SPACE OÜ
Author: Jan Boon <kaetemi@no-break.space>
*/

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:async/async.dart';
import "package:test/test.dart";
import 'package:switchboard/switchboard.dart';

@Timeout(const Duration(seconds: 45))
Switchboard server;
Switchboard client;

runServer() async {
  server = new Switchboard();
  await server.bindWebSocket("localhost", 9090, "/ws");
}

runClient() async {
  client = new Switchboard();
  client.setEndPoint("ws://localhost:9090/ws");
}

void main() {
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
    await client.setPayload(connectionPayload); // FIXME: This needs to succeed without the await as well - locking
    StreamQueue<ChannelInfo> serverQueue = new StreamQueue<ChannelInfo>(server);
    StreamQueue<ChannelInfo> clientQueue = new StreamQueue<ChannelInfo>(client);
    client.sendMessage("api", "HELLO", messagePayload);
    ChannelInfo serverChannelInfo = await serverQueue.next;
    expect(serverChannelInfo.host, equals("localhost"));
    expect(serverChannelInfo.service, equals("api"));
    expect(serverChannelInfo.payload, equals(connectionPayload));
    TalkChannel serverChannel = new TalkChannel(serverChannelInfo.channel);
    StreamQueue<TalkMessage> serverMessageQueue = new StreamQueue<TalkMessage>(serverChannel);
    TalkMessage message = await serverMessageQueue.next;
    expect(message.procedureId, equals("HELLO"));
    expect(message.data, equals(messagePayload));
    serverQueue.cancel();
    clientQueue.cancel();
  });
}

/* end of file */
