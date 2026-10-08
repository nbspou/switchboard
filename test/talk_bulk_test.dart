/*
Polyverse Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Authors:
  Jan Boon <jan.boon@kaetemi.be>
  Claude Opus 5.5 <noreply@anthropic.com>
  GPT-6 Astra <noreply@openai.com>
*/

// Talk bulk payloads (wiki page "Polyverse Switchboard Talk", section
// "Bulk payloads") over raw mux connections: bulk channels are routed with
// TalkChannel.adoptBulk, as the Switchboard dispatcher does.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:async/async.dart';
import 'package:fake_async/fake_async.dart';
import 'package:switchboard/core.dart';
import 'package:switchboard/src/transport/stream_transport.dart';
import 'package:test/test.dart';

import 'mux_harness.dart';

/// Bytes 0, 1, 2, ... modulo 251, so that misplaced chunks show.
Uint8List pattern(int length, [int offset = 0]) {
  final out = Uint8List(length);
  for (var i = 0; i < length; i++) {
    out[i] = (offset + i) % 251;
  }
  return out;
}

/// [total] bytes of [pattern] in pieces of [piece], generated as they are
/// read; [produced] counts what was generated.
Stream<List<int>> generated(
  int total, {
  int piece = 10000,
  void Function(int bytes)? produced,
}) async* {
  var offset = 0;
  while (offset < total) {
    final n = total - offset < piece ? total - offset : piece;
    produced?.call(n);
    yield pattern(n, offset);
    offset += n;
  }
}

/// A client and a server over one mux connection, each routing the bulk
/// channels its peer opens; the server's channels are Talk channels.
class Peers {
  Peers._(this.client, this.server, this.serverOptions);

  final MuxConnection client;
  final MuxConnection server;
  final TalkOptions? serverOptions;
  final StreamController<TalkChannel> _accepted = StreamController();
  late final StreamQueue<TalkChannel> accepted = StreamQueue(_accepted.stream);
  final List<StreamSubscription<MuxChannel>> _subscriptions = [];

  static Future<Peers> connect({
    bool tcp = false,
    MuxOptions options = quiet,
    TalkOptions? serverOptions,
  }) async {
    final MuxConnection client;
    final MuxConnection server;
    if (tcp) {
      final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final accepted = listener.first;
      client = MuxConnection(
        await StreamTransport.connectTcp('127.0.0.1', listener.port),
        isInitiator: true,
        options: options,
      );
      server = MuxConnection(
        StreamTransport.fromSocket(await accepted),
        isInitiator: false,
        options: options,
      );
      await listener.close();
    } else {
      (client, server) = muxPair(initiator: options, acceptor: options);
    }
    final peers = Peers._(client, server, serverOptions);
    peers._subscriptions
      ..add(
        client.incoming.listen((channel) {
          if (_isBulk(channel)) {
            TalkChannel.adoptBulk(channel);
          } else {
            unawaited(channel.close(Status.of(StatusCode.notFound)));
          }
        }),
      )
      ..add(
        server.incoming.listen((channel) {
          if (_isBulk(channel)) {
            TalkChannel.adoptBulk(channel);
          } else {
            peers._accepted.add(TalkChannel(channel, options: serverOptions));
          }
        }),
      );
    addTearDown(peers.close);
    return peers;
  }

  static bool _isBulk(MuxChannel channel) =>
      TalkBulkOpen.isBulk(ChannelAddress.decode(channel.openPayload));

  /// A Talk channel from the client, and its server end.
  Future<(TalkChannel, TalkChannel)> open({TalkOptions? options}) async {
    final talk = TalkChannel(client.open(Uint8List(0)), options: options);
    return (talk, await accepted.next);
  }

  Future<void> close() async {
    for (final s in _subscriptions) {
      await s.cancel();
    }
    await accepted.cancel(immediate: true);
    await _accepted.close();
    await client.close();
    await server.close();
  }
}

/// Polls [condition] until it holds, at most 2 s.
Future<void> until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition not met');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// Collects a stream of byte chunks into one list.
Future<Uint8List> collect(Stream<List<int>> stream) async {
  final builder = BytesBuilder(copy: false);
  await for (final chunk in stream) {
    builder.add(chunk);
  }
  return builder.takeBytes();
}

void main() {
  test('failed reassembly releases its partial memory budget', () async {
    final peers = await Peers.connect(
      serverOptions: const TalkOptions(maxInlinePayload: 1000),
    );
    final (talk, server) = await peers.open(
      options: const TalkOptions(bulkChunkSize: 100),
    );
    server.messages.listen((message) => message.reply(Uint8List(0)));
    await expectLater(
      talk.request('PUT', Uint8List(0), bulk: Stream.value(pattern(1100))),
      throwsStatus(StatusCode.resourceExhausted),
    );
    await talk.request('PUT', Uint8List(0), bulk: Stream.value(pattern(1000)));
  });

  test(
    'completed streams keep unread items within the reassembly budget',
    () async {
      final peers = await Peers.connect(
        serverOptions: const TalkOptions(bulkThreshold: 100),
      );
      final (talk, server) = await peers.open(
        options: const TalkOptions(maxInlinePayload: 1000),
      );
      server.messages.listen((message) {
        message.replyItem(pattern(1000));
        message.reply(Uint8List(0));
      });
      final first = talk.streamRequest('LIST', Uint8List(0));
      await first.done;
      final second = talk.streamRequest('LIST', Uint8List(0));
      second.items.listen((_) => fail('over-budget item delivered'));
      await expectLater(
        second.done,
        throwsStatus(StatusCode.resourceExhausted),
      );
      expect((await first.items.toList()).single.payload, pattern(1000));
      final third = talk.streamRequest('LIST', Uint8List(0));
      expect((await third.items.toList()).single.payload, pattern(1000));
      await third.done;
    },
  );

  test('unread reassemblies share a channel memory budget', () async {
    final peers = await Peers.connect(
      serverOptions: const TalkOptions(maxInlinePayload: 1000),
    );
    final (talk, server) = await peers.open(
      options: const TalkOptions(bulkThreshold: 100),
    );
    final subscription = server.messages.listen((message) {
      expect(message.payload, pattern(1000));
      message.reply(Uint8List(0));
    })..pause();
    final first = talk.request('PUT', pattern(1000));
    await pumpEventQueue();
    final second = talk.request('PUT', pattern(1000));
    await expectLater(
      second.timeout(const Duration(seconds: 1)),
      throwsStatus(StatusCode.resourceExhausted),
    );
    subscription.resume();
    await first;
    // Delivery releases the budget; subsequent large requests still work.
    await talk.request('PUT', pattern(1000));
    await subscription.cancel();
  });

  test('cancelling a stream request closes a delivered item bulk channel '
      'without relying on the peer', () async {
    final peers = await Peers.connect();
    final (talk, server) = await peers.open(
      options: TalkOptions(streamBulk: (_) => true),
    );
    late MuxChannel bulk;
    server.messages.listen((message) {
      final raw = server.raw as MuxChannel;
      // A peer that keeps sending the item after the request was cancelled.
      bulk = raw.openAfter(TalkBulkOpen(raw.id, 1).encode());
      raw.sink.add(
        TalkFrame(
          kind: TalkKind.streamItem,
          responseId: message.requestId,
          bulk: true,
          payload: TalkBulkReference(1).encode(),
        ).encode(),
      );
    });
    final request = talk.streamRequest('LIST', Uint8List(0));
    final items = StreamQueue(request.items);
    expect((await items.next).isBulk, isTrue);
    request.cancel();
    expect(
      (await bulk.done.timeout(const Duration(seconds: 1))).known,
      StatusCode.cancelled,
    );
    await items.cancel();
  });

  test('cancelling messages releases an ordered answer behind a bulk '
      'message being reassembled', () async {
    final peers = await Peers.connect();
    final (talk, server) = await peers.open();
    final source = StreamController<List<int>>();
    server.messages.listen((message) {
      server.send('NOTE', Uint8List(0), bulk: source.stream);
      message.reply(Uint8List.fromList([7]));
    });
    final subscription = talk.messages.listen((_) => fail('not delivered'));
    final response = talk.request('GET', Uint8List(0), ordered: true);
    await pumpEventQueue();
    await subscription.cancel();
    expect((await response.timeout(const Duration(seconds: 1))).payload, [7]);
    await pumpEventQueue();
    expect(source.hasListener, isFalse);
    expect((talk.raw as MuxChannel).heldBytes, 0);
    await source.close();
  });

  for (final cancelBefore in [false, true]) {
    test('cancelling messages ${cancelBefore ? 'before' : 'during'} bulk '
        'reassembly refuses the unread request', () async {
      final peers = await Peers.connect();
      final (talk, server) = await peers.open();
      final subscription = server.messages.listen((_) => fail('not delivered'));
      if (cancelBefore) {
        await subscription.cancel();
      }
      final source = StreamController<List<int>>();
      final response = talk.request('PUT', Uint8List(0), bulk: source.stream);
      await pumpEventQueue();
      if (!cancelBefore) {
        await subscription.cancel();
      }
      await expectLater(
        response.timeout(const Duration(seconds: 1)),
        throwsStatus(StatusCode.unimplemented),
      );
      await pumpEventQueue();
      expect(source.hasListener, isFalse);
      expect((server.raw as MuxChannel).heldBytes, 0);
      await source.close();
    });
  }

  test('references without bulk OPENs have a bounded dispatch wait', () {
    fakeAsync((async) {
      final (client, server) = muxPair();
      final talks = <TalkChannel>[];
      server.incoming.listen((raw) => talks.add(TalkChannel(raw)));
      final raw = client.open(Uint8List(0));
      async.elapse(Duration.zero);
      final baseline = async.nonPeriodicTimerCount;
      for (var number = 1; number <= 100; number++) {
        raw.sink.add(
          TalkFrame(
            kind: TalkKind.message,
            responseId: 1, // Unknown: consumed by Talk immediately.
            bulk: true,
            payload: TalkBulkReference(number).encode(),
          ).encode(),
        );
      }
      async.elapse(Duration.zero);
      expect(
        async.nonPeriodicTimerCount - baseline,
        lessThanOrEqualTo(TalkOptions.defaultMaxUnclaimedBulk),
      );
      Status? end;
      talks.single.done.then((status) => end = status);
      async.elapse(Duration.zero);
      expect(end?.known, StatusCode.protocolError);
      expect(async.pendingTimers, isEmpty);
      client.close();
      server.close();
      async.elapse(quiet.keepAliveTimeout);
    });
  });

  for (final tcp in [false, true]) {
    group(tcp ? 'over TCP' : 'over memory', () {
      test('a request with a bulk payload of known length', () async {
        final peers = await Peers.connect(tcp: tcp);
        final (talk, server) = await peers.open();
        server.messages.listen((m) {
          expect(m.isBulk, isTrue);
          expect(m.bulkLength, 300000);
          m.reply(Uint8List.fromList([m.payload.length ~/ 10000]));
          expect(m.payload, pattern(300000));
        });
        final answer = await talk.request(
          'PUT',
          Uint8List(0),
          bulk: generated(300000),
          bulkLength: 300000,
        );
        expect(answer.payload, [30]);
        expect(answer.isBulk, isFalse);
      });

      test('a request with a bulk payload of unknown length', () async {
        final peers = await Peers.connect(tcp: tcp);
        final (talk, server) = await peers.open();
        server.messages.listen((m) {
          expect(m.bulkLength, isNull);
          m.reply(m.payload.sublist(0, 3));
          expect(m.payload, pattern(123457));
        });
        final answer = await talk.request(
          'PUT',
          Uint8List(0),
          bulk: generated(123457, piece: 777),
        );
        expect(answer.payload, [0, 1, 2]);
      });

      test('a response, stream items and a plain message with bulk '
          'payloads', () async {
        final peers = await Peers.connect(tcp: tcp);
        final (talk, server) = await peers.open(
          options: TalkOptions(
            streamBulk: (m) => m.kind == TalkKind.streamItem,
          ),
        );
        final plain = Completer<TalkMessage>();
        server.messages.listen((m) async {
          switch (m.procedureName) {
            case 'GET':
              await m.replyBulk(generated(200000), length: 200000);
            case 'LIST':
              for (var i = 0; i < 3; i++) {
                unawaited(m.replyItemBulk(generated(70000 + i)));
              }
              m.reply(Uint8List.fromList([9]));
            case 'NOTE':
              plain.complete(m);
          }
        });
        final got = await talk.request('GET', Uint8List(0));
        expect(got.isBulk, isTrue);
        expect(got.bulkLength, 200000);
        expect(got.payload, pattern(200000));
        final stream = talk.streamRequest('LIST', Uint8List(0));
        final lengths = <int>[];
        await for (final item in stream.items) {
          expect(item.isBulk, isTrue);
          // Streamed: payload is not there before it is read.
          expect(() => item.payload, throwsStateError);
          final bytes = await collect(item.bulk);
          expect(bytes, pattern(bytes.length));
          lengths.add(bytes.length);
        }
        expect(lengths, [70000, 70001, 70002]);
        expect((await stream.done).payload, [9]);
        talk.send('NOTE', Uint8List(0), bulk: Stream.value(pattern(50000)));
        final note = await plain.future;
        expect(note.isBulk, isTrue);
        expect(note.payload, pattern(50000));
      });

      test('a payload too large for a frame goes bulk on its own', () async {
        final peers = await Peers.connect(tcp: tcp);
        final (talk, server) = await peers.open();
        final seen = <bool>[];
        server.messages.listen((m) {
          seen.add(m.isBulk);
          m.reply(Uint8List.fromList(m.payload.reversed.toList()));
        });
        final small = Uint8List.fromList([1, 2, 3]);
        final big = pattern(100000);
        final limit = (talk.raw as MuxChannel).maxSubframeLength;
        // Just inline: the frame header (1 + 8 + 3 bytes) and the payload.
        final edge = pattern(limit - 12);
        final answers = [
          for (final payload in [small, big, edge, pattern(limit - 11)])
            await talk.request('ECHO', payload),
        ];
        expect(seen, [false, true, false, true]);
        expect(answers[0].payload, [3, 2, 1]);
        expect(answers[1].isBulk, isTrue);
        expect(answers[1].payload, big.reversed.toList());
        expect(answers[2].isBulk, isFalse);
        // The answer's header is 8 bytes shorter (no procedure, a response
        // id instead of a request id): inline.
        expect(answers[3].isBulk, isFalse);
        expect(answers[3].payload, hasLength(limit - 11));
      });
    });
  }

  test('a message keeps its place while its payload is reassembled', () async {
    final peers = await Peers.connect();
    final (talk, server) = await peers.open();
    final seen = <String>[];
    final all = Completer<void>();
    server.messages.listen((m) {
      seen.add('${m.procedureName} ${m.payload.length}');
      if (seen.length == 4) {
        all.complete();
      }
    });
    talk
      ..send('A', Uint8List(1))
      ..send('B', Uint8List(0), bulk: generated(500000, piece: 1000))
      ..send('C', Uint8List(2))
      ..send('D', pattern(100000));
    await all.future;
    expect(seen, ['A 1', 'B 500000', 'C 2', 'D 100000']);
  });

  test('an ordered answer with a bulk payload keeps its place among the '
      'messages', () async {
    final peers = await Peers.connect();
    final (talk, server) = await peers.open();
    server.messages.listen((m) {
      server.send('EVENT', Uint8List.fromList([1]));
      m.reply(pattern(200000));
      server.send('EVENT', Uint8List.fromList([2]));
    });
    final log = <String>[];
    talk.messages.listen((m) => log.add('event ${m.payload.single}'));
    final answer = await talk.request('SUB', Uint8List(0), ordered: true);
    log.add('answer ${answer.payload.length}');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(log, ['event 1', 'answer 200000', 'event 2']);
  });

  group('timeouts', () {
    const short = TalkOptions(
      requestTimeout: Duration(milliseconds: 200),
      replyTimeout: Duration(milliseconds: 150),
    );

    /// [count] pieces of [size] bytes, one every [every].
    Stream<List<int>> slow(int count, int size, Duration every) async* {
      for (var i = 0; i < count; i++) {
        await Future<void>.delayed(every);
        yield pattern(size, i * size);
      }
    }

    test('an upload longer than both timeouts succeeds while it progresses '
        '(reassembled)', () async {
      final peers = await Peers.connect(serverOptions: short);
      final (talk, server) = await peers.open(options: short);
      server.messages.listen((m) => m.reply(Uint8List.fromList([1])));
      // 12 pieces, 50 ms apart: 600 ms, three times the requester timeout.
      final answer = await talk.request(
        'PUT',
        Uint8List(0),
        bulk: slow(12, 70000, const Duration(milliseconds: 50)),
      );
      expect(answer.payload, [1]);
    });

    test('a streamed upload read for longer than both timeouts, declared '
        'with EXTEND', () async {
      final peers = await Peers.connect(
        serverOptions: TalkOptions(
          requestTimeout: short.requestTimeout,
          replyTimeout: short.replyTimeout,
          streamBulk: (_) => true,
        ),
      );
      final (talk, server) = await peers.open(options: short);
      server.messages.listen((m) async {
        // A long read is declared, as any long work on a request is.
        m.extend(deadline: const Duration(seconds: 5));
        var n = 0;
        await for (final chunk in m.bulk) {
          n += chunk.length;
          await Future<void>.delayed(const Duration(milliseconds: 30));
        }
        m.reply(Uint8List.fromList([n ~/ 100000]));
      });
      final answer = await talk.request(
        'PUT',
        Uint8List(0),
        bulk: generated(1000000, piece: 65536),
        bulkLength: 1000000,
      );
      expect(answer.payload, [10]);
    });

    test('a stalled upload times out and is cancelled', () async {
      final peers = await Peers.connect(serverOptions: short);
      final (talk, server) = await peers.open(options: short);
      final served = <TalkMessage>[];
      server.messages.listen(served.add);
      final source = StreamController<List<int>>();
      source.add(pattern(100000));
      await expectLater(
        talk.request('PUT', Uint8List(0), bulk: source.stream),
        throwsA(
          isA<SwitchboardException>().having(
            (e) => e.code,
            'code',
            StatusCode.deadlineExceeded,
          ),
        ),
      );
      await pumpEventQueue();
      expect(source.hasListener, isFalse);
      expect(served, isEmpty);
      await source.close();
    });
  });

  test('messages sent before the peer\'s LIMITS are sized against the '
      'window it announces', () async {
    // The server grants 256 bytes: frames of at most 112 bytes. The client
    // talks at once, before that LIMITS arrived.
    final (a, b) = MemoryTransport.pair();
    final client = MuxConnection(a, isInitiator: true, options: quiet);
    final server = MuxConnection(
      b,
      isInitiator: false,
      options: quiet.copyWith(initialWindow: 256),
    );
    addTearDown(client.close);
    addTearDown(server.close);
    final received = <String>[];
    final all = Completer<void>();
    server.incoming.listen((channel) {
      if (TalkBulkOpen.isBulk(ChannelAddress.decode(channel.openPayload))) {
        TalkChannel.adoptBulk(channel);
        return;
      }
      TalkChannel(channel).messages.listen((m) {
        received.add('${m.procedureName} ${m.payload.length} ${m.isBulk}');
        if (received.length == 3) {
          all.complete();
        }
      });
    });
    client.incoming.listen(TalkChannel.adoptBulk);
    final raw = client.open(Uint8List(0));
    expect(raw.maxSubframeLength, 32752);
    TalkChannel(raw)
      ..send('SMALL', pattern(50))
      ..send('BIG', pattern(200))
      ..send('AFTER', pattern(10));
    await all.future.timeout(const Duration(seconds: 2));
    expect(raw.maxSubframeLength, 112);
    expect(received, ['SMALL 50 false', 'BIG 200 true', 'AFTER 10 false']);
  });

  test(
    'a large answer to a request completes while its requester drains',
    () async {
      final peers = await Peers.connect();
      final (talk, server) = await peers.open();
      final answering = Completer<TalkMessage>();
      server.messages.listen(answering.complete);
      final big = talk.request('GET', Uint8List(0));
      final request = await answering.future;
      // The client sends GOAWAY: no new channels toward it, but the bulk
      // channel of an answer on a channel it opened is not a new one.
      final drained = peers.client.goAway();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(peers.server.peerGoingAway, isTrue);
      request.reply(pattern(150000));
      final answer = await big;
      expect(answer.isBulk, isTrue);
      expect(answer.payload, pattern(150000));
      await talk.close();
      await drained;
    },
  );

  test('a lower bulkThreshold sends bulk earlier', () async {
    final peers = await Peers.connect();
    final (talk, server) = await peers.open(
      options: const TalkOptions(bulkThreshold: 100),
    );
    final seen = <bool>[];
    server.messages.listen((m) {
      seen.add(m.isBulk);
      m.reply(Uint8List(0));
    });
    await talk.request('X', Uint8List(80));
    await talk.request('X', Uint8List(200));
    expect(seen, [false, true]);
  });

  test('4 MB streamed to a slow reader is never held whole', () async {
    final peers = await Peers.connect(
      serverOptions: TalkOptions(streamBulk: (_) => true),
    );
    final (talk, server) = await peers.open();
    const total = 4 * 1024 * 1024;
    var produced = 0;
    var consumed = 0;
    var maxAhead = 0;
    final done = Completer<void>();
    server.messages.listen((m) async {
      expect(m.bulkLength, total);
      await for (final chunk in m.bulk) {
        expect(chunk, pattern(chunk.length, consumed));
        consumed += chunk.length;
        final ahead = produced - consumed;
        if (ahead > maxAhead) {
          maxAhead = ahead;
        }
        if (consumed % (256 * 1024) < chunk.length) {
          // Slow: a pause every 256 KiB.
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      }
      m.reply(Uint8List(0));
      done.complete();
    });
    await talk.request(
      'PUT',
      Uint8List(0),
      bulk: generated(total, piece: 32768, produced: (n) => produced += n),
      bulkLength: total,
    );
    await done.future;
    expect(consumed, total);
    // The sender ran ahead of the reader by at most the window it was
    // granted (1 MiB) and a few chunks.
    expect(maxAhead, lessThan(1024 * 1024 + 4 * 65536));
  });

  test('a slow bulk reader stalls only its bulk channel', () async {
    final peers = await Peers.connect(
      serverOptions: TalkOptions(streamBulk: (_) => true),
    );
    final (talk, server) = await peers.open();
    final (other, otherServer) = await peers.open();
    otherServer.messages.listen((m) => m.reply(m.payload));
    StreamSubscription<Uint8List>? reading;
    var received = 0;
    server.messages.listen((m) {
      if (m.procedureName == 'PUT') {
        reading = m.bulk.listen((chunk) => received += chunk.length)..pause();
      } else {
        m.reply(Uint8List.fromList([1]));
      }
    });
    var produced = 0;
    final upload = talk.request(
      'PUT',
      Uint8List(0),
      bulk: generated(2 * 1024 * 1024, produced: (n) => produced += n),
      bulkLength: 2 * 1024 * 1024,
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(received, 0);
    // Stalled at the window: the source is paused.
    expect(produced, lessThan(1024 * 1024 + 4 * 65536));
    // The same channel, and another one, keep flowing.
    expect((await talk.request('PING', Uint8List(0))).payload, [1]);
    expect((await other.request('ECHO', Uint8List.fromList([7]))).payload, [7]);
    reading!.resume();
    upload.ignore();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(received, greaterThan(1024 * 1024));
    await reading!.cancel();
  });

  group('cancellation', () {
    test('the receiver cancelling the stream stops the sender', () async {
      final peers = await Peers.connect(
        serverOptions: TalkOptions(streamBulk: (_) => true),
      );
      final (talk, server) = await peers.open();
      final sourceCancelled = Completer<void>();
      final source = StreamController<List<int>>(
        onCancel: sourceCancelled.complete,
      );
      Timer.periodic(const Duration(milliseconds: 1), (timer) {
        if (source.isClosed || sourceCancelled.isCompleted) {
          timer.cancel();
        } else if (!source.isPaused) {
          source.add(pattern(1000));
        }
      });
      server.messages.listen((m) async {
        final first = await m.bulk.first;
        expect(first, isNotEmpty);
        m.reply(Uint8List.fromList([1]));
      });
      final answer = await talk.request(
        'PUT',
        Uint8List(0),
        bulk: source.stream,
      );
      expect(answer.payload, [1]);
      await sourceCancelled.future;
      await source.close();
    });

    test('a reply payload the receiver stops fails replyBulk', () async {
      final peers = await Peers.connect();
      final (talk, server) = await peers.open(
        options: TalkOptions(streamBulk: (_) => true),
      );
      final sent = Completer<Object?>();
      server.messages.listen((m) {
        m
            .replyBulk(generated(4 * 1024 * 1024))
            .then((_) => sent.complete(null), onError: sent.complete);
      });
      final answer = await talk.request('GET', Uint8List(0));
      late final StreamSubscription<Uint8List> reading;
      reading = answer.bulk.listen((_) => reading.pause());
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await reading.cancel();
      final error = await sent.future;
      expect(
        error,
        isA<SwitchboardException>().having(
          (e) => e.code,
          'code',
          StatusCode.cancelled,
        ),
      );
    });

    test('the sender cancelling the request stops the payload', () async {
      final peers = await Peers.connect(
        serverOptions: TalkOptions(streamBulk: (_) => true),
      );
      final (talk, server) = await peers.open();
      final failed = Completer<Object>();
      final request = Completer<TalkMessage>();
      server.messages.listen((m) {
        request.complete(m);
        m.bulk.listen((_) {}, onError: failed.complete);
      });
      final source = StreamController<List<int>>();
      source.add(pattern(1000));
      final pending = talk.startRequest(
        'PUT',
        Uint8List(0),
        bulk: source.stream,
      );
      final m = await request.future;
      pending.cancel();
      expect(
        await failed.future,
        isA<SwitchboardException>().having(
          (e) => e.code,
          'code',
          StatusCode.cancelled,
        ),
      );
      await m.onCancel;
      expect(source.hasListener, isFalse);
      await source.close();
    });

    test('a source error fails the payload with its status', () async {
      final peers = await Peers.connect(
        serverOptions: TalkOptions(streamBulk: (_) => true),
      );
      final (talk, server) = await peers.open();
      final failed = Completer<Object>();
      server.messages.listen((m) {
        m.bulk.listen((_) {}, onError: failed.complete);
      });
      talk.send(
        'PUT',
        Uint8List(0),
        bulk: () async* {
          yield pattern(10);
          throw SwitchboardException.of(StatusCode.dataLoss, 'disk');
        }(),
      );
      expect(
        await failed.future,
        isA<SwitchboardException>()
            .having((e) => e.code, 'code', StatusCode.dataLoss)
            .having((e) => e.status.reason, 'reason', 'disk'),
      );
    });
  });

  group('failed payloads', () {
    test('a source producing another length than declared', () async {
      final peers = await Peers.connect();
      final (talk, server) = await peers.open();
      server.messages.listen((_) => fail('not delivered'));
      await expectLater(
        talk.request(
          'PUT',
          Uint8List(0),
          bulk: Stream.value(pattern(50)),
          bulkLength: 100,
        ),
        throwsA(
          isA<TalkAbortException>().having(
            (e) => e.code,
            'code',
            StatusCode.invalidArgument,
          ),
        ),
      );
    });

    test('a bulk channel carrying another length than its reference is a '
        'PROTOCOL_ERROR for the payload only', () async {
      final peers = await Peers.connect(
        serverOptions: TalkOptions(streamBulk: (_) => true),
      );
      final raw = peers.client.open(Uint8List(0));
      final server = await peers.accepted.next;
      final failed = Completer<Object>();
      final requests = <TalkMessage>[];
      server.messages.listen((m) {
        requests.add(m);
        if (m.isBulk) {
          m.bulk.listen((_) {}, onError: failed.complete);
        }
      });
      final bulk = raw.openAfter(TalkBulkOpen(raw.id, 1).encode());
      await raw.send(
        TalkFrame(
          kind: TalkKind.message,
          procedure: Name('PUT'),
          requestId: 1,
          bulk: true,
          payload: TalkBulkReference(1, length: 100).encode(),
        ).encode(),
      );
      await bulk.send(Uint8List(50));
      await bulk.close();
      expect(
        await failed.future,
        isA<SwitchboardException>().having(
          (e) => e.code,
          'code',
          StatusCode.protocolError,
        ),
      );
      // The message stands, the channel too.
      expect(requests.single.canReply, isTrue);
      requests.single.reply(Uint8List(0));
      expect(raw.canSend, isTrue);
    });

    test('a payload over maxInlinePayload fails toward both sides', () async {
      final peers = await Peers.connect(
        serverOptions: const TalkOptions(maxInlinePayload: 1000),
      );
      final (talk, server) = await peers.open();
      final seen = <TalkMessage>[];
      server.messages.listen((m) {
        seen.add(m);
        m.reply(Uint8List.fromList([m.payload.length ~/ 100]));
      });
      await expectLater(
        talk.request(
          'PUT',
          Uint8List(0),
          bulk: Stream.value(pattern(5000)),
          bulkLength: 5000,
        ),
        throwsA(
          isA<TalkAbortException>().having(
            (e) => e.code,
            'code',
            StatusCode.resourceExhausted,
          ),
        ),
      );
      // Unknown length: the cap is found while reading.
      await expectLater(
        talk.request('PUT', Uint8List(0), bulk: generated(5000, piece: 100)),
        throwsA(
          isA<TalkAbortException>().having(
            (e) => e.code,
            'code',
            StatusCode.resourceExhausted,
          ),
        ),
      );
      expect(seen, isEmpty);
      // Within the cap.
      final ok = await talk.request(
        'PUT',
        Uint8List(0),
        bulk: Stream.value(pattern(1000)),
      );
      expect(ok.payload, [10]);
      expect(seen, hasLength(1));
    });

    test('payloadBytes reassembles a streamed payload within a cap', () async {
      final peers = await Peers.connect(
        serverOptions: TalkOptions(streamBulk: (_) => true),
      );
      final (talk, server) = await peers.open();
      server.messages.listen((m) async {
        try {
          final bytes = await m.payloadBytes(maxLength: 60000);
          expect(m.payload, bytes);
          m.reply(Uint8List.fromList([bytes.length ~/ 1000]));
        } on SwitchboardException catch (e) {
          m.replyAbort(e.status);
        }
      });
      final ok = await talk.request('PUT', pattern(50000));
      expect(ok.payload, [50]);
      await expectLater(
        talk.request('PUT', pattern(70000)),
        throwsA(
          isA<TalkAbortException>().having(
            (e) => e.code,
            'code',
            StatusCode.resourceExhausted,
          ),
        ),
      );
    });
  });

  group('bulk channel rules', () {
    test('more unclaimed bulk channels than allowed are refused', () async {
      final peers = await Peers.connect();
      final raw = peers.client.open(Uint8List(0));
      final server = await peers.accepted.next;
      server.messages.listen((_) {});
      final bulks = [
        for (var n = 1; n <= 17; n++)
          raw.openAfter(TalkBulkOpen(raw.id, n).encode()),
      ];
      final last = await bulks.last.done;
      expect(last.known, StatusCode.resourceExhausted);
      await pumpEventQueue();
      expect(bulks.first.state, MuxChannelState.open);
      // The parent closing cancels the rest.
      await raw.close();
      expect((await bulks.first.done).known, StatusCode.cancelled);
    });

    test('a bulk channel no message references in time is closed', () async {
      final peers = await Peers.connect(
        serverOptions: const TalkOptions(
          bulkOpenTimeout: Duration(milliseconds: 50),
        ),
      );
      final raw = peers.client.open(Uint8List(0));
      final server = await peers.accepted.next;
      server.messages.listen((_) {});
      final bulk = raw.openAfter(TalkBulkOpen(raw.id, 1).encode());
      await bulk.send(Uint8List(1000));
      expect((await bulk.done).known, StatusCode.cancelled);
      // A late reference to it is a protocol error.
      await raw.send(
        TalkFrame(
          kind: TalkKind.message,
          procedure: Name('PUT'),
          bulk: true,
          payload: TalkBulkReference(1).encode(),
        ).encode(),
      );
      expect((await raw.done).known, StatusCode.protocolError);
    });

    test(
      'bulk payloads nobody reads yet do not pause the connection',
      () async {
        // A small receive mark: 20 unread payloads, a window each, are well
        // beyond it.
        final peers = await Peers.connect(
          options: quiet.copyWith(receiveHighWaterMarkBytes: 1024 * 1024),
          serverOptions: TalkOptions(streamBulk: (_) => true),
        );
        final (talk, server) = await peers.open();
        final (other, otherServer) = await peers.open();
        otherServer.messages.listen((m) => m.reply(m.payload));
        final unread = <TalkMessage>[];
        server.messages.listen(unread.add);
        for (var i = 0; i < 20; i++) {
          talk.send('PUT', pattern(200000));
        }
        await until(() => unread.length == 20);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(peers.server.isReceivePaused, isFalse);
        expect(peers.server.bufferedBytes, lessThan(64 * 1024));
        final echo = await other
            .request('ECHO', Uint8List.fromList([5]))
            .timeout(const Duration(seconds: 2));
        expect(echo.payload, [5]);
        // Read one of them whole: what waited is there.
        expect(await collect(unread.first.bulk), pattern(200000));
      },
    );

    test('a reference to a bulk number never opened is a channel protocol '
        'error', () async {
      final peers = await Peers.connect(
        serverOptions: const TalkOptions(
          bulkOpenTimeout: Duration(milliseconds: 50),
        ),
      );
      final raw = peers.client.open(Uint8List(0));
      final server = await peers.accepted.next;
      server.messages.listen((_) {});
      await raw.send(
        TalkFrame(
          kind: TalkKind.message,
          procedure: Name('PUT'),
          bulk: true,
          payload: TalkBulkReference(5).encode(),
        ).encode(),
      );
      expect((await raw.done).known, StatusCode.protocolError);
      expect((await server.done).known, StatusCode.protocolError);
    });

    test(
      'a bulk number referenced twice is a channel protocol error',
      () async {
        final peers = await Peers.connect(
          serverOptions: TalkOptions(streamBulk: (_) => true),
        );
        final raw = peers.client.open(Uint8List(0));
        final server = await peers.accepted.next;
        final seen = <TalkMessage>[];
        server.messages.listen(seen.add, onError: (_) {});
        final bulk = raw.openAfter(TalkBulkOpen(raw.id, 1).encode());
        final frame = TalkFrame(
          kind: TalkKind.message,
          procedure: Name('PUT'),
          bulk: true,
          payload: TalkBulkReference(1).encode(),
        ).encode();
        await raw.send(frame);
        await raw.send(frame);
        expect((await raw.done).known, StatusCode.protocolError);
        expect(seen, hasLength(1));
        expect((await bulk.done).known, StatusCode.cancelled);
      },
    );

    test(
      'a bulk channel for no open parent is refused FAILED_PRECONDITION',
      () async {
        final peers = await Peers.connect();
        final stray = peers.client.open(TalkBulkOpen(1000, 1).encode());
        expect((await stray.done).known, StatusCode.failedPrecondition);
      },
    );

    test('a parent closing cancels its bulk channels in transfer', () async {
      final peers = await Peers.connect(
        serverOptions: TalkOptions(streamBulk: (_) => true),
      );
      final (talk, server) = await peers.open();
      final failed = Completer<Object>();
      final sent = Completer<Object?>();
      server.messages.listen((m) {
        m.bulk.listen((_) {}, onError: failed.complete).pause();
        unawaited(server.close(Status.of(StatusCode.aborted, 'gone')));
      });
      final source = StreamController<List<int>>(
        onCancel: () => sent.complete(null),
      );
      Timer.periodic(const Duration(milliseconds: 1), (timer) {
        if (sent.isCompleted) {
          timer.cancel();
        } else if (!source.isPaused) {
          source.add(pattern(1000));
        }
      });
      talk.send('PUT', Uint8List(0), bulk: source.stream);
      await sent.future;
      expect((await talk.done).known, StatusCode.aborted);
      await source.close();
    });

    test('a graceful close waits for the payloads being sent', () async {
      final peers = await Peers.connect();
      final (talk, server) = await peers.open();
      final got = Completer<TalkMessage>();
      server.messages.listen(got.complete);
      talk.send('PUT', pattern(300000));
      await talk.close();
      final m = await got.future;
      expect(m.payload, pattern(300000));
    });
  });
}
