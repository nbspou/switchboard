import 'dart:typed_data';

import 'package:switchboard/core.dart';
import 'package:test/test.dart';

/// Talk over mux over the in-memory transport: the integration point between
/// the two layers.
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
}
