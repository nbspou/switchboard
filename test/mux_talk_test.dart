/*
Polyverse Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Authors:
  Jan Boon <jan.boon@kaetemi.be>
  Claude Fable 5.1 <noreply@anthropic.com>
  Claude Opus 5.5 <noreply@anthropic.com>
*/

import 'dart:typed_data';

import 'package:switchboard/core.dart';
import 'package:test/test.dart';

/// Talk over mux over the in-memory transport: the integration point between
/// the two layers.
Uint8List bytes(List<int> values) => Uint8List.fromList(values);

void main() {
  test('talk request over a mux channel, close status propagates', () async {
    final (a, b) = MemoryTransport.pair();
    final client = MuxConnection(a, isInitiator: true);
    final server = MuxConnection(b, isInitiator: false);
    final serverChannels = server.incoming.listen((channel) {
      final talk = TalkChannel(channel);
      talk.messages.listen((message) {
        message.reply(
          Uint8List.fromList([...message.payload, 1]),
          procedure: 'PONG',
        );
      });
    });
    final channel = client.open(Uint8List.fromList([7]));
    final talk = TalkChannel(channel);
    final reply = await talk.request('PING', Uint8List.fromList([2]));
    expect(reply.procedureName, 'PONG');
    expect(reply.payload, [2, 1]);
    await talk.close(Status.of(StatusCode.goingAway, 'bye'));
    expect((await talk.done).known, StatusCode.goingAway);
    expect((await channel.done).known, StatusCode.goingAway);
    await serverChannels.cancel();
    await client.close();
    await server.close();
  });

  test('talk abort maps application code before mux close', () async {
    final (a, b) = MemoryTransport.pair();
    final client = MuxConnection(a, isInitiator: true);
    final server = MuxConnection(b, isInitiator: false);
    final serverTalkDone = server.incoming.first.then(
      (c) => TalkChannel(c).done,
    );
    final talk = TalkChannel(client.open(Uint8List(0)));
    talk.abort(const Status(300, 'app'));
    final status = await serverTalkDone;
    expect(status.code, 300);
    await client.close();
    await server.close();
  });

  test('a talk protocol error closes only that channel', () async {
    final (a, b) = MemoryTransport.pair();
    final client = MuxConnection(a, isInitiator: true);
    final server = MuxConnection(b, isInitiator: false);
    final serverTalks = <TalkChannel>[];
    final serverChannels = server.incoming.listen((channel) {
      final talk = TalkChannel(channel);
      serverTalks.add(talk);
      talk.messages.listen((m) => m.reply(bytes([1])), onError: (_) {});
    });
    final bad = client.open(Uint8List(0));
    final good = TalkChannel(client.open(Uint8List(0)));
    final sibling = TalkChannel(client.open(Uint8List(0)));
    // Reserved flag bit 0x40: a channel protocol error.
    bad.send(hexBytes('41 48 45 4C 4C 4F 00 00 00'));
    expect((await bad.done).known, StatusCode.protocolError);
    expect((await serverTalks.first.done).known, StatusCode.protocolError);
    expect((await good.request('X', Uint8List(0))).payload, [1]);
    expect((await sibling.request('Y', Uint8List(0))).payload, [1]);
    expect(client.isOpen, isTrue);
    expect(server.isOpen, isTrue);
    await serverChannels.cancel();
    await client.close();
    await server.close();
  });

  test('CONNECTION_LOST goes on the wire as UNAVAILABLE', () async {
    final (a, b) = MemoryTransport.pair();
    final client = MuxConnection(a, isInitiator: true);
    final server = MuxConnection(b, isInitiator: false);
    final serverDone = server.incoming.first.then((c) => c.done);
    final talk = TalkChannel(client.open(Uint8List(0)));
    await talk.close(Status.of(StatusCode.connectionLost, 'upstream gone'));
    expect((await talk.done).known, StatusCode.connectionLost);
    final remote = await serverDone;
    expect(remote.known, StatusCode.unavailable);
    expect(remote.reason, contains('upstream gone'));
    await client.close();
    await server.close();
  });
}
