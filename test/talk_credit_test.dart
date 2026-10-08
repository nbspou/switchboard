/*
Polyverse Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Authors:
  Jan Boon <jan.boon@kaetemi.be>
  Claude Opus 5.5 <noreply@anthropic.com>
*/

import 'dart:async';
import 'dart:typed_data';

import 'package:async/async.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:switchboard/core.dart';
import 'package:test/test.dart';

import 'mux_harness.dart';

/// Talk returns the credit of a frame when the application has taken what
/// it carried (wiki "Mux", "Flow control"; "Talk", the delivery point).
void main() {
  /// Lets the mux and Talk deliver what is in flight.
  Future<void> settle() async {
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// A client and a server Talk channel over one mux connection; the
  /// server's raw mux channel is returned for inspection.
  late MuxConnection client;
  late MuxConnection server;
  late StreamQueue<MuxChannel> accepted;

  Future<(TalkChannel, TalkChannel, MuxChannel, MuxChannel)> talkPair(
    MuxConnection client,
    MuxConnection server,
  ) async {
    final raw = client.open(Uint8List(0));
    final talk = TalkChannel(raw);
    final serverRaw = await accepted.next;
    return (talk, TalkChannel(serverRaw), raw, serverRaw);
  }

  setUp(() {
    (client, server) = muxPair();
    accepted = StreamQueue(server.incoming);
  });

  tearDown(() async {
    await accepted.cancel(immediate: true);
    await client.close();
    await server.close();
  });

  test('a Talk channel puts its mux channel in manual credit', () async {
    final (talk, serverTalk, raw, serverRaw) = await talkPair(client, server);
    expect(raw.manualCredit, isTrue);
    expect(serverRaw.manualCredit, isTrue);
    await talk.close();
    await serverTalk.done;
  });

  test('a paused messages stream stalls its channel at the window, and '
      'only it; resuming drains', () async {
    final (talk, serverTalk, raw, serverRaw) = await talkPair(client, server);
    final other = await talkPair(client, server);
    final received = <TalkMessage>[];
    final subscription = serverTalk.messages.listen(received.add)..pause();
    other.$2.messages.listen((m) => m.reply(m.payload));
    const count = 200;
    final payload = Uint8List(1000);
    for (var i = 0; i < count; i++) {
      unawaited(talk.send('MSG', payload));
    }
    await settle();
    // The window is spent and nothing more arrives: what the server holds
    // is bounded by it.
    expect(received, isEmpty);
    expect(raw.sendWindow, lessThan(1100));
    expect(
      serverRaw.heldBytes + serverRaw.bufferedBytes,
      lessThanOrEqualTo(MuxOptions.defaultInitialWindow),
    );
    expect(serverRaw.heldBytes, greaterThan(60000));
    // Another channel of the connection flows meanwhile.
    final echo = await other.$1.request('ECHO', Uint8List.fromList([7]));
    expect(echo.payload, [7]);
    subscription.resume();
    await settle();
    expect(received, hasLength(count));
    expect(serverRaw.heldBytes, 0);
    await subscription.cancel();
    await talk.close();
  });

  test('a paused messages stream holds responses to its own channel\'s '
      'requests behind the window too', () async {
    final (talk, serverTalk, raw, _) = await talkPair(client, server);
    // The server answers requests; the client never listens to messages,
    // and the server sends it plain messages until the window is spent.
    serverTalk.messages.listen((m) => m.reply(Uint8List(0)));
    for (var i = 0; i < 100; i++) {
      unawaited(serverTalk.send('EVENT', Uint8List(1000)));
    }
    await settle();
    final answer = talk.request('REQ', Uint8List(0));
    var answered = false;
    unawaited(answer.then((_) => answered = true));
    await settle();
    expect(answered, isFalse);
    final events = <TalkMessage>[];
    final subscription = talk.messages.listen(events.add);
    await answer;
    await settle();
    expect(events, hasLength(100));
    expect(raw.heldBytes, 0);
    await subscription.cancel();
    await talk.close();
  });

  test('frames Talk consumes itself return their credit at once', () async {
    final (talk, serverTalk, raw, _) = await talkPair(client, server);
    serverTalk.messages.listen((m) {
      switch (m.procedureName) {
        case 'BIG':
          m.reply(Uint8List(20000));
        case 'EXT':
          m
            ..extend()
            ..extend()
            ..reply(Uint8List(0));
        case 'FAIL':
          m.replyAbort(Status.of(StatusCode.notFound, 'x' * 1000));
      }
    });
    // Nobody listens to the client's messages: responses, EXTENDs and
    // aborts never wait for a listener.
    for (var i = 0; i < 20; i++) {
      expect(
        (await talk.request('BIG', Uint8List(0))).payload,
        hasLength(20000),
      );
      await talk.request('EXT', Uint8List(0));
      await expectLater(
        talk.request('FAIL', Uint8List(0)),
        throwsA(isA<TalkAbortException>()),
      );
    }
    await settle();
    expect(raw.heldBytes, 0);
    await talk.close();
  });

  test(
    'a response for an unknown or cancelled request returns its credit',
    () async {
      final (talk, serverTalk, raw, _) = await talkPair(client, server);
      final requests = <TalkMessage>[];
      serverTalk.messages.listen(requests.add);
      final pending = talk.startRequest('SLOW', Uint8List(0));
      await settle();
      pending.cancel();
      await settle();
      // The server's late reply is dropped by the client's Talk, and the
      // server answered the cancel already; a stray response to an id never
      // used is dropped too.
      expect(requests.single.isCancelled, isTrue);
      serverTalk.raw.sink.add(
        TalkFrame(
          kind: TalkKind.message,
          responseId: 77,
          payload: Uint8List(5000),
        ).encode(),
      );
      await settle();
      expect(raw.heldBytes, 0);
      await talk.close();
    },
  );

  test('cancelling the messages subscription returns what it held', () async {
    final (talk, serverTalk, _, serverRaw) = await talkPair(client, server);
    final subscription = serverTalk.messages.listen((_) {})..pause();
    for (var i = 0; i < 30; i++) {
      unawaited(talk.send('MSG', Uint8List(1000)));
    }
    await settle();
    expect(serverRaw.heldBytes, greaterThan(30000));
    await subscription.cancel();
    expect(serverRaw.heldBytes, 0);
    // Later messages are dropped, their credit returned at once.
    for (var i = 0; i < 100; i++) {
      unawaited(talk.send('MSG', Uint8List(1000)));
    }
    await settle();
    expect(serverRaw.heldBytes, 0);
    await talk.close();
  });

  test('stream items are flow controlled by the items subscription', () async {
    final (talk, serverTalk, raw, _) = await talkPair(client, server);
    serverTalk.messages.listen((m) {
      for (var i = 0; i < 100; i++) {
        m.replyItem(Uint8List(1000));
      }
      m.reply(Uint8List(0));
    });
    final stream = talk.streamRequest('LIST', Uint8List(0));
    final items = <TalkMessage>[];
    final subscription = stream.items.listen(items.add)..pause();
    await settle();
    expect(items, isEmpty);
    expect(raw.heldBytes, greaterThan(60000));
    expect(raw.heldBytes, lessThanOrEqualTo(MuxOptions.defaultInitialWindow));
    subscription.resume();
    await stream.done;
    await settle();
    expect(items, hasLength(100));
    expect(raw.heldBytes, 0);
    await subscription.cancel();
    await talk.close();
  });

  test('items nobody listens to stall the channel until their request '
      'ends, not longer', () async {
    final raw = client.open(Uint8List(0));
    final talk = TalkChannel(
      raw,
      options: const TalkOptions(requestTimeout: Duration(milliseconds: 200)),
    );
    final serverTalk = TalkChannel(await accepted.next);
    serverTalk.messages.listen((m) {
      if (m.procedureName == 'LIST') {
        for (var i = 0; i < 100; i++) {
          m.replyItem(Uint8List(1000));
        }
        m.reply(Uint8List(0));
      } else {
        m.reply(Uint8List.fromList([1]));
      }
    });
    // Only `done` is awaited: the items fill the window, the final cannot
    // follow, and the request times out.
    final stream = talk.streamRequest('LIST', Uint8List(0));
    await expectLater(
      stream.done,
      throwsA(
        isA<SwitchboardException>().having(
          (e) => e.code,
          'code',
          StatusCode.deadlineExceeded,
        ),
      ),
    );
    // Its end returned the items' credit: the channel flows again.
    expect(raw.heldBytes, 0);
    final answer = await talk
        .request('PING', Uint8List(0))
        .timeout(const Duration(seconds: 2));
    expect(answer.payload, [1]);
    await talk.close();
  });

  test('cancelling a stream\'s items returns what they held', () async {
    final (talk, serverTalk, raw, _) = await talkPair(client, server);
    serverTalk.messages.listen((m) {
      for (var i = 0; i < 20; i++) {
        m.replyItem(Uint8List(1000));
      }
    });
    final stream = talk.streamRequest('LIST', Uint8List(0));
    final subscription = stream.items.listen((_) {}, onError: (_) {})..pause();
    await settle();
    expect(raw.heldBytes, greaterThan(20000));
    await subscription.cancel();
    expect(raw.heldBytes, 0);
    await talk.close();
  });

  test('an ordered answer returns its credit when it is delivered', () async {
    final (talk, serverTalk, raw, _) = await talkPair(client, server);
    serverTalk.messages.listen((m) {
      serverTalk.send('EVENT', Uint8List(100));
      m.reply(Uint8List(3000));
    });
    final events = <TalkMessage>[];
    final subscription = talk.messages.listen(events.add)..pause();
    final answer = talk.request('SUB', Uint8List(0), ordered: true);
    var answered = false;
    unawaited(answer.then((_) => answered = true));
    await settle();
    expect(answered, isFalse);
    expect(raw.heldBytes, greaterThan(3000));
    subscription.resume();
    await answer;
    await settle();
    expect(events, hasLength(1));
    expect(raw.heldBytes, 0);
    await subscription.cancel();
    await talk.close();
  });

  test('over a raw stream channel nothing is flow controlled', () async {
    final a = StreamController<Uint8List>();
    final b = StreamController<Uint8List>();
    final left = TalkChannel(StreamChannel(a.stream, b.sink));
    final right = TalkChannel(StreamChannel(b.stream, a.sink));
    right.messages.listen((m) => m.reply(m.payload));
    final answer = await left.request('ECHO', Uint8List.fromList([1, 2]));
    expect(answer.payload, [1, 2]);
    await left.close();
    await right.close();
    await a.close();
    await b.close();
  });

  group('awaitable sends', () {
    /// The flow-control cost of a plain message [procedure] carrying
    /// [length] bytes.
    int costOf(String procedure, int length) => MuxCredit.costOf(
      TalkFrame(
        kind: TalkKind.message,
        procedure: Name(procedure),
        payload: Uint8List(length),
      ).encode().length,
    );

    /// The flow-control cost of a stream item carrying [length] bytes.
    int itemCost(int length) => MuxCredit.costOf(
      TalkFrame(
        kind: TalkKind.streamItem,
        responseId: 1,
        payload: Uint8List(length),
      ).encode().length,
    );

    test('send completes once the window took the message, waits beyond '
        'it, and fails when the channel can no longer send', () async {
      final (talk, serverTalk, raw, _) = await talkPair(client, server);
      final subscription = serverTalk.messages.listen((_) {})..pause();
      // The window takes it now: completed at once.
      await talk.send('MSG', Uint8List(1000));
      final pending = [
        for (var i = 0; i < 100; i++) talk.send('MSG', Uint8List(1000)),
      ];
      var done = 0;
      for (final sent in pending) {
        unawaited(sent.then((_) => done++));
      }
      await settle();
      final window = MuxOptions.defaultInitialWindow ~/ costOf('MSG', 1000);
      expect(done, window - 1);
      // The listener takes messages: credit comes back, the rest goes.
      subscription.resume();
      await Future.wait(pending);
      subscription.pause();
      final stuck = [
        for (var i = 0; i < 100; i++) talk.send('MSG', Uint8List(1000)),
      ];
      await settle();
      // The peer closes the channel: what still waits for credit fails.
      await serverTalk.close();
      await expectLater(
        stuck.last,
        throwsStatus(StatusCode.failedPrecondition),
      );
      expect(raw.canSend, isFalse);
      await subscription.cancel();
    });

    test('a failure nobody waits for is not reported as unhandled', () async {
      final errors = <Object>[];
      await runZonedGuarded(() async {
        final (talk, serverTalk, _, _) = await talkPair(client, server);
        serverTalk.messages.listen((m) {
          // Nobody waits for these either.
          unawaited(m.reply(Uint8List(0)));
        }).pause();
        for (var i = 0; i < 100; i++) {
          unawaited(talk.send('MSG', Uint8List(1000)));
        }
        await settle();
        await serverTalk.close();
        await settle();
      }, (error, _) => errors.add(error));
      expect(errors, isEmpty);
    });

    test('a publisher awaiting each send holds at most one message beyond '
        'the window of a stalled subscriber', () async {
      final (talk, serverTalk, raw, serverRaw) = await talkPair(client, server);
      final received = <TalkMessage>[];
      final subscription = serverTalk.messages.listen(received.add)..pause();
      const count = 300;
      var sent = 0;
      final publisher = () async {
        for (var i = 0; i < count; i++) {
          await talk.send('EVENT', Uint8List(1000));
          sent++;
        }
      }();
      await settle();
      final window = MuxOptions.defaultInitialWindow ~/ costOf('EVENT', 1000);
      // What the window took went out; the publisher waits on the next one
      // instead of queueing the rest.
      expect(sent, window);
      await settle();
      expect(sent, window);
      expect(raw.sendWindow, lessThan(costOf('EVENT', 1000)));
      expect(client.heldOutputBytes, 0);
      expect(
        serverRaw.heldBytes,
        lessThanOrEqualTo(MuxOptions.defaultInitialWindow),
      );
      subscription.resume();
      await publisher;
      await settle();
      expect(received, hasLength(count));
      await subscription.cancel();
      await talk.close();
    });

    test('a responder awaiting each replyItem is paced by a stalled items '
        'subscription', () async {
      final (talk, serverTalk, raw, _) = await talkPair(client, server);
      const count = 300;
      var sent = 0;
      final responded = Completer<void>();
      serverTalk.messages.listen((m) async {
        for (var i = 0; i < count; i++) {
          await m.replyItem(Uint8List(1000));
          sent++;
        }
        await m.reply(Uint8List(0));
        responded.complete();
      });
      final stream = talk.streamRequest('LIST', Uint8List(0));
      final items = <TalkMessage>[];
      final itemsDone = Completer<void>();
      final subscription = stream.items.listen(
        items.add,
        onDone: itemsDone.complete,
      )..pause();
      await settle();
      final window = MuxOptions.defaultInitialWindow ~/ itemCost(1000);
      // The request took its share of the window too.
      expect(sent, lessThanOrEqualTo(window));
      expect(sent, greaterThan(window - 3));
      expect(raw.heldBytes, lessThanOrEqualTo(MuxOptions.defaultInitialWindow));
      subscription.resume();
      await stream.done;
      await responded.future;
      await itemsDone.future;
      expect(items, hasLength(count));
      await subscription.cancel();
      await talk.close();
    });

    test('replyStream pauses its source while an item waits for the '
        'window', () async {
      final (talk, serverTalk, _, _) = await talkPair(client, server);
      const count = 300;
      var produced = 0;
      Stream<Uint8List> source() async* {
        for (var i = 0; i < count; i++) {
          produced++;
          yield Uint8List(1000);
        }
      }

      serverTalk.messages.listen((m) => unawaited(m.replyStream(source())));
      final stream = talk.streamRequest('LIST', Uint8List(0));
      final items = <TalkMessage>[];
      final itemsDone = Completer<void>();
      final subscription = stream.items.listen(
        items.add,
        onDone: itemsDone.complete,
      )..pause();
      await settle();
      final window = MuxOptions.defaultInitialWindow ~/ itemCost(1000);
      expect(produced, lessThanOrEqualTo(window + 3));
      subscription.resume();
      await stream.done;
      await itemsDone.future;
      expect(items, hasLength(count));
      expect(produced, count);
      await subscription.cancel();
      await talk.close();
    });
  });
}
