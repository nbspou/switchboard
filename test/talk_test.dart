import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:async/async.dart';
import 'package:fake_async/fake_async.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:switchboard/src/bytes.dart';
import 'package:switchboard/src/name.dart';
import 'package:switchboard/src/status.dart';
import 'package:switchboard/src/talk/talk_channel.dart';
import 'package:switchboard/src/talk/talk_frame.dart';
import 'package:switchboard/src/talk/talk_message.dart';
import 'package:test/test.dart';

const Duration ms30 = Duration(milliseconds: 30);

Uint8List bytes(List<int> values) => Uint8List.fromList(values);

Matcher isStatus(StatusCode code) =>
    isA<SwitchboardException>().having((e) => e.code, 'code', code);

Matcher throwsStatus(StatusCode code) => throwsA(isStatus(code));

/// Two talk channels joined through a tap that records every frame.
class Pair {
  Pair({
    TalkOptions a = const TalkOptions(),
    TalkOptions b = const TalkOptions(),
  }) {
    final ca = StreamChannelController<Uint8List>();
    final cb = StreamChannelController<Uint8List>();
    ca.foreign.stream.listen((frame) {
      aToBRaw.add(frame);
      cb.foreign.sink.add(frame);
    }, onDone: () => cb.foreign.sink.close());
    cb.foreign.stream.listen((frame) {
      bToARaw.add(frame);
      ca.foreign.sink.add(frame);
    }, onDone: () => ca.foreign.sink.close());
    this.a = TalkChannel(ca.local, options: a);
    this.b = TalkChannel(cb.local, options: b);
  }

  late final TalkChannel a;
  late final TalkChannel b;
  final List<Uint8List> aToBRaw = [];
  final List<Uint8List> bToARaw = [];

  List<TalkFrame> get aToB => aToBRaw.map(TalkFrame.decode).toList();
  List<TalkFrame> get bToA => bToARaw.map(TalkFrame.decode).toList();

  Future<void> close() => Future.wait([a.close(), b.close()]);
}

/// A talk channel whose peer is driven by hand at the frame level.
class RawPeer {
  RawPeer({TalkOptions options = const TalkOptions(), bool mux = false}) {
    final c = StreamChannelController<Uint8List>();
    raw = c.foreign;
    this.mux = mux ? FakeMuxChannel(c.local) : null;
    talk = TalkChannel(this.mux ?? c.local, options: options);
    raw.stream.listen(
      (frame) => received.add(TalkFrame.decode(frame)),
      onDone: () => ended = true,
    );
  }

  late final StreamChannel<Uint8List> raw;
  late final TalkChannel talk;
  late final FakeMuxChannel? mux;
  final List<TalkFrame> received = [];
  bool ended = false;

  void send(TalkFrame frame) => raw.sink.add(frame.encode());
  void sendHex(String hex) => raw.sink.add(hexBytes(hex));
}

/// Stands in for the mux channel: closable with a status, has an end
/// status.
class FakeMuxChannel extends StreamChannelMixin<Uint8List>
    implements StatusClosable {
  FakeMuxChannel(this._inner);

  final StreamChannel<Uint8List> _inner;
  final List<Status> closedWith = [];
  final Completer<Status> _done = Completer<Status>();

  @override
  Stream<Uint8List> get stream => _inner.stream;

  @override
  StreamSink<Uint8List> get sink => _inner.sink;

  @override
  Future<void> close([Status status = Status.ok]) async {
    closedWith.add(status);
    if (!_done.isCompleted) {
      _done.complete(status);
    }
    _inner.sink.close().ignore();
  }

  @override
  Future<Status> get done => _done.future;

  /// The peer closed the channel with [status]; the stream ends.
  void endFromPeer(StreamChannel<Uint8List> foreign, Status status) {
    _done.complete(status);
    foreign.sink.close().ignore();
  }
}

/// Synchronously observable outcome of a future, for fake_async tests.
class Outcome<T> {
  Outcome(Future<T> future) {
    future.then(
      (v) {
        value = v;
        isDone = true;
      },
      onError: (Object e) {
        error = e;
        isDone = true;
      },
    );
  }

  T? value;
  Object? error;
  bool isDone = false;
}

/// Replies to every request on [channel] with [respond].
void serve(TalkChannel channel, void Function(TalkMessage message) respond) {
  channel.messages.listen(respond, onError: (Object _) {});
}

void main() {
  group('messages and requests', () {
    test('plain messages both ways', () async {
      final p = Pair();
      final atA = StreamQueue(p.a.messages);
      final atB = StreamQueue(p.b.messages);
      p.a.send('HELLO', bytes([1, 2]));
      p.b.send('WORLD', bytes([3]));
      final onB = await atB.next;
      expect(onB.procedureName, 'HELLO');
      expect(onB.procedure, Name('HELLO'));
      expect(onB.payload, [1, 2]);
      expect(onB.kind, TalkKind.message);
      expect(onB.expectsReply, isFalse);
      expect(onB.requestId, 0);
      expect(onB.responseId, 0);
      expect(onB.canReply, isFalse);
      final onA = await atA.next;
      expect(onA.procedureName, 'WORLD');
      expect(onA.payload, [3]);
      expect(hexString(p.aToBRaw.single), '01 48 45 4C 4C 4F 00 00 00 01 02');
      await p.close();
      expect(await atA.hasNext, isFalse);
      expect(await atB.hasNext, isFalse);
    });

    test('request and reply both ways', () async {
      final p = Pair();
      serve(p.b, (m) => m.reply(bytes(m.payload.reversed.toList())));
      serve(p.a, (m) => m.reply(bytes([m.payload.length])));
      final r1 = await p.a.request('ECHO', bytes([1, 2, 3]));
      expect(r1.payload, [3, 2, 1]);
      expect(r1.expectsReply, isFalse);
      expect(r1.responseId, p.aToB.single.requestId);
      final r2 = await p.b.request('LEN', bytes([9, 9]));
      expect(r2.payload, [2]);
      expect(p.a.outgoingRequestCount, 0);
      expect(p.b.incomingRequestCount, 0);
      await p.close();
    });

    test('reply with and without procedure', () async {
      final p = Pair();
      serve(p.b, (m) {
        if (m.procedureName == 'NAMED') {
          m.reply(bytes([1]), procedure: 'RESULT');
        } else {
          m.reply(bytes([2]));
        }
      });
      final named = await p.a.request('NAMED', Uint8List(0));
      expect(named.procedureName, 'RESULT');
      expect(p.bToA.last.procedure, Name('RESULT'));
      final plain = await p.a.request('PLAIN', Uint8List(0));
      expect(plain.procedure, Name.empty);
      expect(plain.procedureName, '');
      expect(p.bToA.last.procedure, isNull);
      expect(hexString(p.bToARaw.last), '04 02 00 00 02');
      await p.close();
    });

    test('chained replies, several hops deep', () async {
      final p = Pair();
      serve(p.b, (m1) async {
        expect(m1.procedureName, 'Q1');
        final r2 = await m1.replyRequest(bytes([2]), procedure: 'Q2');
        expect(r2.procedureName, 'Q3');
        expect(r2.expectsReply, isTrue);
        final r4 = await r2.replyRequest(bytes([4]));
        expect(r4.payload, [5]);
        expect(r4.expectsReply, isTrue);
        r4.reply(bytes([6]));
      });
      final r1 = await p.a.request('Q1', bytes([1]));
      expect(r1.payload, [2]);
      expect(r1.procedureName, 'Q2');
      expect(r1.expectsReply, isTrue);
      final r3 = await r1.replyRequest(bytes([3]), procedure: 'Q3');
      expect(r3.payload, [4]);
      expect(r3.procedure, Name.empty);
      final r5 = await r3.replyRequest(bytes([5]));
      expect(r5.payload, [6]);
      expect(r5.expectsReply, isFalse);
      // Every hop is a response to the previous request.
      final aToB = p.aToB;
      final bToA = p.bToA;
      expect(bToA[0].responseId, aToB[0].requestId);
      expect(aToB[1].responseId, bToA[0].requestId);
      expect(bToA[1].responseId, aToB[1].requestId);
      expect(aToB[2].responseId, bToA[1].requestId);
      expect(bToA[2].responseId, aToB[2].requestId);
      expect(bToA[2].hasRequest, isFalse);
      for (final c in [p.a, p.b]) {
        expect(c.outgoingRequestCount, 0);
        expect(c.incomingRequestCount, 0);
      }
      await p.close();
    });

    test('reply on a message that expects no reply throws', () async {
      final p = Pair();
      final atB = StreamQueue(p.b.messages);
      p.a.send('NOTE', Uint8List(0));
      final m = await atB.next;
      final failed = throwsStatus(StatusCode.failedPrecondition);
      expect(() => m.reply(Uint8List(0)), failed);
      expect(() => m.replyAbort(Status.of(StatusCode.internal)), failed);
      expect(() => m.extend(), failed);
      expect(() => m.replyRequest(Uint8List(0)), failed);
      expect(() => m.replyItem(Uint8List(0)), failed);
      expect(p.bToARaw, isEmpty);
      await p.close();
    });

    test('double final reply throws failedPrecondition', () async {
      final p = Pair();
      final errors = <Object>[];
      serve(p.b, (m) {
        m.reply(bytes([1]));
        for (final again in <void Function()>[
          () => m.reply(bytes([2])),
          () => m.replyAbort(Status.of(StatusCode.internal)),
          () => m.extend(),
          () => m.replyRequest(Uint8List(0)),
        ]) {
          try {
            again();
          } catch (e) {
            errors.add(e);
          }
        }
      });
      final r = await p.a.request('ONCE', Uint8List(0));
      expect(r.payload, [1]);
      expect(errors, hasLength(4));
      expect(errors, everyElement(isStatus(StatusCode.failedPrecondition)));
      expect(p.bToA, hasLength(1));
      await p.close();
    });

    test('replyItem on a non-stream request throws', () async {
      final p = Pair();
      final atB = StreamQueue(p.b.messages);
      final f = p.a.request('ONE', Uint8List(0));
      final m = await atB.next;
      expect(m.expectsStream, isFalse);
      final failed = throwsStatus(StatusCode.failedPrecondition);
      expect(() => m.replyItem(Uint8List(0)), failed);
      expect(() => m.replyItemRequest(Uint8List(0)), failed);
      expect(m.canReply, isTrue);
      m.reply(bytes([7]));
      expect((await f).payload, [7]);
      await p.close();
    });

    test('interleaving: 200 requests in flight, replied in reverse', () async {
      final p = Pair();
      final held = <TalkMessage>[];
      final all = Completer<void>();
      serve(p.b, (m) {
        held.add(m);
        if (held.length == 200) {
          all.complete();
        }
      });
      final futures = [
        for (var i = 0; i < 200; i++)
          p.a.request('N', bytes([i & 0xFF, i >> 8])),
      ];
      await all.future;
      expect(p.a.outgoingRequestCount, 200);
      expect(p.b.incomingRequestCount, 200);
      for (final m in held.reversed) {
        m.reply(bytes([...m.payload, 0xEE]));
      }
      final results = await Future.wait(futures);
      for (var i = 0; i < 200; i++) {
        expect(results[i].payload, [i & 0xFF, i >> 8, 0xEE]);
      }
      expect(p.a.outgoingRequestCount, 0);
      expect(p.b.incomingRequestCount, 0);
      await p.close();
    });

    test('large payloads pass through unchanged', () async {
      final p = Pair();
      final random = Random(42);
      final big = Uint8List(1 << 20);
      for (var i = 0; i < big.length; i++) {
        big[i] = random.nextInt(256);
      }
      serve(p.b, (m) => m.reply(m.payload));
      final r = await p.a.request('BIG', big);
      expect(r.payload.length, big.length);
      expect(r.payload, orderedEquals(big));
      await p.close();
    });
  });

  group('streams', () {
    test('items then a final response with trailing payload', () async {
      final p = Pair();
      serve(p.b, (m) {
        expect(m.expectsStream, isTrue);
        m.replyItem(bytes([1]), procedure: 'ITEM');
        m.replyItem(bytes([2]));
        m.replyItem(bytes([3]));
        m.reply(bytes([0xFF]), procedure: 'END');
      });
      final s = p.a.streamRequest('LIST', bytes([0]));
      final items = await s.items.toList();
      expect(items.map((m) => m.payload.single), [1, 2, 3]);
      expect(items.first.kind, TalkKind.streamItem);
      expect(items.first.procedureName, 'ITEM');
      expect(items.every((m) => m.responseId == s.requestId), isTrue);
      final last = await s.done;
      expect(last.kind, TalkKind.message);
      expect(last.payload, [0xFF]);
      expect(last.procedureName, 'END');
      expect(p.aToB.single.stream, isTrue);
      expect(p.a.outgoingRequestCount, 0);
      await p.close();
    });

    test('items that are requests are answered by the requester', () async {
      final p = Pair();
      serve(p.b, (m) async {
        final answers = await Future.wait([
          m.replyItemRequest(bytes([1]), procedure: 'MORE'),
          m.replyItemRequest(bytes([2])),
        ]);
        m.reply(bytes([answers[0].payload.single + answers[1].payload.single]));
      });
      final s = p.a.streamRequest('ASK', Uint8List(0));
      s.items.listen((item) {
        expect(item.expectsReply, isTrue);
        expect(item.kind, TalkKind.streamItem);
        item.reply(bytes([item.payload.single * 10]));
      });
      final last = await s.done;
      expect(last.payload, [30]);
      final items = p.bToA.where((f) => f.kind == TalkKind.streamItem);
      expect(items.every((f) => f.hasRequest && f.hasResponse), isTrue);
      expect(p.a.incomingRequestCount, 0);
      expect(p.b.outgoingRequestCount, 0);
      await p.close();
    });

    test('a final response that is itself a stream request', () async {
      final p = Pair();
      serve(p.b, (m) async {
        final back = m.replyStreamRequest(bytes([1]), procedure: 'BACK');
        final items = await back.items.toList();
        final end = await back.done;
        expect(items.map((i) => i.payload.single), [7, 8]);
        expect(end.payload, [9]);
      });
      final r = await p.a.request('START', Uint8List(0));
      expect(r.expectsReply, isTrue);
      expect(r.expectsStream, isTrue);
      r.replyItem(bytes([7]));
      r.replyItem(bytes([8]));
      r.reply(bytes([9]));
      await pumpEventQueue();
      expect(p.b.outgoingRequestCount, 0);
      await p.close();
    });

    test('abort response fails items and done', () async {
      final p = Pair();
      serve(p.b, (m) {
        m.replyItem(bytes([1]));
        m.replyAbort(const Status(300, 'gone'));
      });
      final s = p.a.streamRequest('LIST', Uint8List(0));
      final got = <int>[];
      Object? itemsError;
      final ended = Completer<void>();
      s.items.listen(
        (m) => got.add(m.payload.single),
        onError: (Object e) => itemsError = e,
        onDone: ended.complete,
      );
      await expectLater(
        s.done,
        throwsA(
          isA<SwitchboardException>().having(
            (e) => e.status,
            'status',
            const Status(300, 'gone'),
          ),
        ),
      );
      await ended.future;
      expect(got, [1]);
      expect(itemsError, isA<SwitchboardException>());
      await p.close();
    });
  });

  group('aborts', () {
    test('abort response carries the exact status and reason', () async {
      final p = Pair();
      serve(p.b, (m) {
        switch (m.procedureName) {
          case 'MISSING':
            m.replyAbort(Status.of(StatusCode.notFound, 'nope'));
          case 'APP':
            m.replyAbort(const Status(256, 'custom'));
          case 'APPMAX':
            m.replyAbort(const Status(0xFFFF));
          default:
            m.replyAbort(Status.of(StatusCode.unimplemented));
        }
      });
      Future<Status> statusOf(String procedure) async {
        try {
          await p.a.request(procedure, Uint8List(0));
        } on SwitchboardException catch (e) {
          return e.status;
        }
        fail('request $procedure succeeded');
      }

      expect(await statusOf('MISSING'), Status.of(StatusCode.notFound, 'nope'));
      final app = await statusOf('APP');
      expect(app, const Status(256, 'custom'));
      expect(app.isApplicationCode, isTrue);
      expect(app.known, isNull);
      expect(await statusOf('APPMAX'), const Status(0xFFFF));
      expect((await statusOf('OTHER')).known, StatusCode.unimplemented);
      expect(hexString(p.bToARaw.first), '24 01 00 00 05 00 6E 6F 70 65');
      expect(p.a.isOpen, isTrue);
      await p.close();
    });

    test('channel abort from the peer: messages error and end, '
        'channel closes', () async {
      final p = Pair();
      final errors = <Object>[];
      final ended = Completer<void>();
      p.a.messages.listen((_) {}, onError: errors.add, onDone: ended.complete);
      serve(p.b, (_) {});
      final pending = expectLater(
        p.a.request('WAIT', Uint8List(0)),
        throwsStatus(StatusCode.unauthenticated),
      );
      await pumpEventQueue();
      const status = Status(16, 'bad token');
      p.b.abort(status);
      expect(p.b.isOpen, isFalse);
      await ended.future;
      expect(errors, hasLength(1));
      expect(
        errors.single,
        isA<SwitchboardException>().having((e) => e.status, 'status', status),
      );
      await pending;
      expect(await p.a.done, status);
      expect(await p.b.done, status);
      expect(p.a.isOpen, isFalse);
      expect(hexString(p.bToARaw.last), '20 10 00 62 61 64 20 74 6F 6B 65 6E');
    });

    test('channel abort with an application code', () async {
      final peer = RawPeer(mux: true);
      final errors = <Object>[];
      peer.talk.messages.listen((_) {}, onError: errors.add);
      peer.send(
        TalkFrame(
          kind: TalkKind.abort,
          payload: const Status(999, 'x').encode(),
        ),
      );
      expect(await peer.talk.done, const Status(999, 'x'));
      expect(
        errors.single,
        isA<SwitchboardException>().having(
          (e) => e.status,
          'status',
          const Status(999, 'x'),
        ),
      );
      // Mux CLOSE must not carry application codes.
      expect(peer.mux!.closedWith.single.known, StatusCode.unknown);
    });

    test('handler exceptions are answered with ABORT INTERNAL', () async {
      final p = Pair();
      p.b.messages.listen((m) {
        if (m.procedureName == 'BOOM') {
          throw StateError('secret detail');
        }
        if (m.procedureName == 'LATE') {
          m.reply(bytes([1]));
          throw StateError('after reply');
        }
        m.reply(bytes([2]));
      });
      await expectLater(
        p.a.request('BOOM', Uint8List(0)),
        throwsA(
          isA<SwitchboardException>()
              .having((e) => e.code, 'code', StatusCode.internal)
              .having(
                (e) => e.status.reason,
                'reason',
                isNot(contains('secret')),
              ),
        ),
      );
      expect((await p.a.request('LATE', Uint8List(0))).payload, [1]);
      expect((await p.a.request('FINE', Uint8List(0))).payload, [2]);
      p.a.send('BOOM', Uint8List(0));
      await pumpEventQueue();
      expect(p.b.isOpen, isTrue);
      expect(p.b.incomingRequestCount, 0);
      await p.close();
    });

    test('item listener exceptions abort the item request', () async {
      final p = Pair();
      serve(p.b, (m) async {
        try {
          await m.replyItemRequest(bytes([1]));
          m.reply(bytes([0]));
        } on SwitchboardException catch (e) {
          m.reply(bytes([e.status.code]));
        }
      });
      final s = p.a.streamRequest('S', Uint8List(0));
      s.items.listen((_) => throw StateError('bad item'));
      expect((await s.done).payload, [StatusCode.internal.code]);
      await p.close();
    });

    test(
      'requests are refused when nobody listens to messages any more',
      () async {
        final p = Pair();
        final subscription = p.b.messages.listen((_) {});
        await subscription.cancel();
        await expectLater(
          p.a.request('ANY', Uint8List(0)),
          throwsStatus(StatusCode.unimplemented),
        );
        await p.close();
      },
    );
  });

  group('cancel', () {
    test(
      'requester cancels, responder sees it and replies CANCELLED',
      () async {
        final p = Pair();
        final cancelSeen = Completer<TalkMessage>();
        serve(p.b, (m) {
          m.replyItem(bytes([1]));
          expect(m.isCancelled, isFalse);
          m.onCancel.then((_) {
            expect(m.isCancelled, isTrue);
            cancelSeen.complete(m);
          });
        });
        final s = p.a.streamRequest('WATCH', Uint8List(0));
        final got = <int>[];
        Object? error;
        final ended = Completer<void>();
        s.items.listen(
          (m) {
            got.add(m.payload.single);
            s.cancel();
          },
          onError: (Object e) => error = e,
          onDone: ended.complete,
        );
        await ended.future;
        expect(got, [1]);
        expect(error, isStatus(StatusCode.cancelled));
        await expectLater(s.done, throwsStatus(StatusCode.cancelled));
        // The id stays reserved until the responder's final response.
        expect(p.a.outgoingRequestCount, 1);
        final cancel = p.aToB.last;
        expect(cancel.kind, TalkKind.abort);
        expect(cancel.requestId, s.requestId);
        expect(cancel.hasResponse, isFalse);
        expect(cancel.status.known, StatusCode.cancelled);

        final m = await cancelSeen.future;
        // Anything arriving before the final is ignored by the requester.
        m.replyItem(bytes([2]));
        m.replyAbort(Status.of(StatusCode.cancelled));
        await pumpEventQueue();
        expect(got, [1]);
        expect(p.a.outgoingRequestCount, 0);
        expect(p.b.incomingRequestCount, 0);
        expect(p.a.isOpen, isTrue);
        await p.close();
      },
    );

    test('a cancelled request rejects a chained final', () async {
      final peer = RawPeer();
      final s = peer.talk.streamRequest('S', Uint8List(0));
      s.done.ignore();
      s.cancel(const Status(1, 'stop'));
      s.cancel();
      await pumpEventQueue();
      expect(peer.received.last.status, const Status(1, 'stop'));
      expect(peer.received, hasLength(2));
      peer.send(
        TalkFrame(
          kind: TalkKind.message,
          procedure: Name('MORE'),
          requestId: 9,
          responseId: s.requestId,
        ),
      );
      await pumpEventQueue();
      final reject = peer.received.last;
      expect(reject.kind, TalkKind.abort);
      expect(reject.responseId, 9);
      expect(reject.status.known, StatusCode.cancelled);
      expect(peer.talk.outgoingRequestCount, 0);
      await peer.talk.close();
    });

    test('cancel after the request ended does nothing', () async {
      final p = Pair();
      serve(p.b, (m) => m.reply(Uint8List(0)));
      final s = p.a.streamRequest('S', Uint8List(0));
      await s.done;
      final sent = p.aToBRaw.length;
      s.cancel();
      await pumpEventQueue();
      expect(p.aToBRaw.length, sent);
      await p.close();
    });

    test('a cancel for a request already answered is ignored', () async {
      final peer = RawPeer();
      serve(peer.talk, (m) => m.reply(Uint8List(0)));
      peer.send(
        TalkFrame(kind: TalkKind.message, procedure: Name('A'), requestId: 4),
      );
      await pumpEventQueue();
      peer.sendHex('22 04 00 00 01 00');
      await pumpEventQueue();
      expect(peer.talk.isOpen, isTrue);
      expect(peer.received.single.responseId, 4);
      await peer.talk.close();
    });
  });

  group('timeouts', () {
    test('responder side: ABORT DEADLINE_EXCEEDED, later replies throw', () {
      fakeAsync((async) {
        final p = Pair(b: const TalkOptions(replyTimeout: ms30));
        TalkMessage? held;
        serve(p.b, (m) => held = m);
        final result = Outcome(p.a.request('SLOW', Uint8List(0)));
        async.flushMicrotasks();
        expect(held, isNotNull);
        expect(p.b.incomingRequestCount, 1);
        async.elapse(const Duration(milliseconds: 29));
        expect(result.isDone, isFalse);
        async.elapse(const Duration(milliseconds: 2));
        expect(result.error, isStatus(StatusCode.deadlineExceeded));
        final abort = p.bToA.single;
        expect(abort.kind, TalkKind.abort);
        expect(abort.responseId, p.aToB.single.requestId);
        expect(abort.status.known, StatusCode.deadlineExceeded);
        expect(held!.canReply, isFalse);
        expect(held!.isCancelled, isTrue, reason: 'work should stop');
        expect(
          () => held!.reply(Uint8List(0)),
          throwsStatus(StatusCode.failedPrecondition),
        );
        expect(p.b.incomingRequestCount, 0);
        p.close();
        async.flushMicrotasks();
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('requester side: fails locally and sends a cancel', () {
      fakeAsync((async) {
        final peer = RawPeer(options: const TalkOptions(requestTimeout: ms30));
        final result = Outcome(peer.talk.request('X', Uint8List(0)));
        final s = peer.talk.streamRequest('Y', Uint8List(0));
        final items = Outcome(s.items.toList());
        async.flushMicrotasks();
        expect(peer.received, hasLength(2));
        final id = peer.received.first.requestId;
        async.elapse(const Duration(milliseconds: 31));
        expect(result.error, isStatus(StatusCode.deadlineExceeded));
        expect(items.error, isStatus(StatusCode.deadlineExceeded));
        expect(peer.received, hasLength(4));
        final cancel = peer.received[2];
        expect(cancel.kind, TalkKind.abort);
        expect(cancel.requestId, id);
        expect(cancel.hasResponse, isFalse);
        expect(cancel.status.known, StatusCode.cancelled);
        expect(peer.received[3].requestId, s.requestId);
        // The id is released at once; a late answer is ignored.
        expect(peer.talk.outgoingRequestCount, 0);
        peer.send(TalkFrame(kind: TalkKind.message, responseId: id));
        async.flushMicrotasks();
        expect(peer.talk.isOpen, isTrue);
        expect(async.pendingTimers, isEmpty);
        peer.talk.close();
        async.flushMicrotasks();
      });
    });

    test('extend restarts both timers', () {
      fakeAsync((async) {
        final p = Pair(
          a: const TalkOptions(requestTimeout: ms30),
          b: const TalkOptions(replyTimeout: ms30),
        );
        TalkMessage? held;
        serve(p.b, (m) => held = m);
        final result = Outcome(p.a.request('SLOW', Uint8List(0)));
        async.flushMicrotasks();
        for (var i = 0; i < 5; i++) {
          async.elapse(const Duration(milliseconds: 20));
          held!.extend();
        }
        async.elapse(const Duration(milliseconds: 20));
        expect(result.isDone, isFalse);
        held!.reply(bytes([1]));
        async.flushMicrotasks();
        expect((result.value!).payload, [1]);
        expect(p.bToA.where((f) => f.kind == TalkKind.extend), hasLength(5));
        expect(hexString(p.bToARaw.first), '34 01 00 00');
        p.close();
        async.flushMicrotasks();
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('stream items restart both timers', () {
      fakeAsync((async) {
        final p = Pair(
          a: const TalkOptions(requestTimeout: ms30),
          b: const TalkOptions(replyTimeout: ms30),
        );
        TalkMessage? held;
        serve(p.b, (m) => held = m);
        final s = p.a.streamRequest('TICK', Uint8List(0));
        final items = Outcome(s.items.toList());
        final done = Outcome(s.done);
        async.flushMicrotasks();
        for (var i = 0; i < 5; i++) {
          async.elapse(const Duration(milliseconds: 20));
          held!.replyItem(bytes([i]));
        }
        async.elapse(const Duration(milliseconds: 20));
        held!.reply(Uint8List(0));
        async.flushMicrotasks();
        expect(items.value!.map((m) => m.payload.single), [0, 1, 2, 3, 4]);
        expect(done.value, isNotNull);
        p.close();
        async.flushMicrotasks();
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('per-request timeout override', () {
      fakeAsync((async) {
        final p = Pair(
          a: const TalkOptions(requestTimeout: ms30),
          b: const TalkOptions(replyTimeout: Duration.zero),
        );
        final held = <String, TalkMessage>{};
        serve(p.b, (m) => held[m.procedureName] = m);
        final long = Outcome(
          p.a.request(
            'LONG',
            Uint8List(0),
            timeout: const Duration(milliseconds: 100),
          ),
        );
        final short = Outcome(
          p.a.request(
            'SHORT',
            Uint8List(0),
            timeout: const Duration(milliseconds: 10),
          ),
        );
        final never = Outcome(
          p.a.request('NEVER', Uint8List(0), timeout: Duration.zero),
        );
        async.elapse(const Duration(milliseconds: 11));
        expect(short.error, isStatus(StatusCode.deadlineExceeded));
        async.elapse(const Duration(milliseconds: 69));
        expect(long.isDone, isFalse);
        held['LONG']!.reply(bytes([1]));
        async.flushMicrotasks();
        expect(long.value!.payload, [1]);
        async.elapse(const Duration(hours: 1));
        expect(never.isDone, isFalse);
        p.close();
        async.flushMicrotasks();
        expect(never.error, isStatus(StatusCode.cancelled));
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('a cancelled request id is released on timeout', () {
      fakeAsync((async) {
        final peer = RawPeer(options: const TalkOptions(requestTimeout: ms30));
        final s = peer.talk.streamRequest('S', Uint8List(0));
        s.done.ignore();
        async.flushMicrotasks();
        s.cancel();
        async.flushMicrotasks();
        expect(peer.talk.outgoingRequestCount, 1);
        async.elapse(const Duration(milliseconds: 31));
        expect(peer.talk.outgoingRequestCount, 0);
        // No second cancel.
        expect(peer.received, hasLength(2));
        peer.talk.close();
        async.flushMicrotasks();
      });
    });
  });

  group('limits and ids', () {
    test('maxIncomingRequests exceeded: ABORT RESOURCE_EXHAUSTED', () async {
      final p = Pair(b: const TalkOptions(maxIncomingRequests: 2));
      final held = <TalkMessage>[];
      serve(p.b, held.add);
      final f1 = p.a.request('A', Uint8List(0));
      final f2 = p.a.request('B', Uint8List(0));
      final f3 = p.a.request('C', Uint8List(0));
      await expectLater(f3, throwsStatus(StatusCode.resourceExhausted));
      expect(held.map((m) => m.procedureName), ['A', 'B']);
      held[0].reply(Uint8List(0));
      await f1;
      final f4 = p.a.request('D', Uint8List(0));
      await pumpEventQueue();
      expect(held.map((m) => m.procedureName), ['A', 'B', 'D']);
      held[1].reply(Uint8List(0));
      held[2].reply(Uint8List(0));
      await Future.wait([f2, f4]);
      await p.close();
    });

    test(
      'maxOutgoingRequests exceeded: throws locally, sends nothing',
      () async {
        final p = Pair(a: const TalkOptions(maxOutgoingRequests: 2));
        final held = <TalkMessage>[];
        serve(p.b, held.add);
        final f1 = p.a.request('A', Uint8List(0));
        final s2 = p.a.streamRequest('B', Uint8List(0));
        final exhausted = throwsStatus(StatusCode.resourceExhausted);
        expect(() => p.a.request('C', Uint8List(0)), exhausted);
        expect(() => p.a.streamRequest('C', Uint8List(0)), exhausted);
        await pumpEventQueue();
        expect(p.aToB, hasLength(2));
        // A chained reply is an outgoing request too.
        serve(p.a, (m) {
          expect(() => m.replyRequest(Uint8List(0)), exhausted);
          expect(m.canReply, isTrue, reason: 'nothing was sent');
          m.reply(Uint8List(0));
        });
        await p.b.request('Z', Uint8List(0));
        held[0].reply(Uint8List(0));
        held[1].reply(Uint8List(0));
        await f1;
        await s2.done;
        final f4 = p.a.request('D', Uint8List(0));
        await pumpEventQueue();
        expect(held.last.procedureName, 'D');
        held.last.reply(Uint8List(0));
        await f4;
        await p.close();
      },
    );

    test('request ids wrap and skip ids still outstanding', () async {
      final peer = RawPeer();
      peer.talk.nextRequestId = 0xFFFFFE;
      final a = peer.talk.request('A', Uint8List(0));
      peer.talk.request('B', Uint8List(0)).ignore();
      peer.talk.request('C', Uint8List(0)).ignore();
      peer.talk.nextRequestId = 0xFFFFFE;
      peer.talk.request('D', Uint8List(0)).ignore();
      expect(peer.talk.nextRequestId, 3);
      await pumpEventQueue();
      expect(peer.received.map((f) => f.requestId), [0xFFFFFE, 0xFFFFFF, 1, 2]);
      peer.send(TalkFrame(kind: TalkKind.message, responseId: 0xFFFFFE));
      await a;
      peer.talk.nextRequestId = 0xFFFFFE;
      peer.talk.request('E', Uint8List(0)).ignore();
      await pumpEventQueue();
      expect(peer.received.last.requestId, 0xFFFFFE);
      expect(
        hexString(peer.received.last.encode()),
        '03 45 00 00 00 00 00 00 00 FE FF FF',
      );
      await peer.talk.close();
    });

    test('responses for unknown ids are ignored', () async {
      final peer = RawPeer();
      final messages = <TalkMessage>[];
      serve(peer.talk, messages.add);
      peer.send(TalkFrame(kind: TalkKind.message, responseId: 99));
      peer.send(TalkFrame(kind: TalkKind.streamItem, responseId: 99));
      peer.send(TalkFrame(kind: TalkKind.extend, responseId: 99));
      peer.sendHex('24 63 00 00 05 00');
      await pumpEventQueue();
      expect(peer.received, isEmpty);
      expect(messages, isEmpty);
      expect(peer.talk.isOpen, isTrue);
      await peer.talk.close();
    });

    test(
      'an unknown response id with HAS_REQUEST gets ABORT NOT_FOUND',
      () async {
        final peer = RawPeer();
        peer.send(
          TalkFrame(kind: TalkKind.message, requestId: 5, responseId: 99),
        );
        peer.send(
          TalkFrame(kind: TalkKind.streamItem, requestId: 6, responseId: 98),
        );
        await pumpEventQueue();
        expect(peer.received, hasLength(2));
        expect(peer.received[0].kind, TalkKind.abort);
        expect(peer.received[0].responseId, 5);
        expect(peer.received[0].status.known, StatusCode.notFound);
        expect(peer.received[1].responseId, 6);
        expect(peer.received[1].status.known, StatusCode.notFound);
        expect(peer.talk.isOpen, isTrue);
        await peer.talk.close();
      },
    );

    test(
      'a request id reused while outstanding supersedes the old one',
      () async {
        final peer = RawPeer();
        final held = <TalkMessage>[];
        serve(peer.talk, held.add);
        peer.send(
          TalkFrame(
            kind: TalkKind.message,
            procedure: Name('OLD'),
            requestId: 1,
          ),
        );
        await pumpEventQueue();
        peer.send(
          TalkFrame(
            kind: TalkKind.message,
            procedure: Name('NEW'),
            requestId: 1,
          ),
        );
        await pumpEventQueue();
        expect(held, hasLength(2));
        expect(held[0].isCancelled, isTrue);
        expect(held[0].canReply, isFalse);
        expect(
          () => held[0].reply(Uint8List(0)),
          throwsStatus(StatusCode.failedPrecondition),
        );
        held[1].reply(bytes([1]));
        await pumpEventQueue();
        expect(peer.received.single.responseId, 1);
        expect(peer.received.single.payload, [1]);
        await peer.talk.close();
      },
    );
  });

  group('protocol errors and channel end', () {
    test('STREAM_ITEM for a non-stream request: protocol error', () async {
      final peer = RawPeer(mux: true);
      final one = peer.talk.request('ONE', Uint8List(0));
      final two = peer.talk.request('TWO', Uint8List(0));
      await pumpEventQueue();
      peer.send(
        TalkFrame(
          kind: TalkKind.streamItem,
          responseId: peer.received.first.requestId,
        ),
      );
      await expectLater(one, throwsStatus(StatusCode.protocolError));
      await expectLater(two, throwsStatus(StatusCode.protocolError));
      final done = await peer.talk.done;
      expect(done.known, StatusCode.protocolError);
      expect(peer.talk.isOpen, isFalse);
      expect(peer.mux!.closedWith.single.known, StatusCode.protocolError);
    });

    test('malformed frame: channel closed with protocol error', () async {
      final peer = RawPeer();
      final ended = Completer<void>();
      final errors = <Object>[];
      peer.talk.messages.listen(
        (_) {},
        onError: errors.add,
        onDone: ended.complete,
      );
      final pending = peer.talk.request('X', Uint8List(0));
      final s = peer.talk.streamRequest('Y', Uint8List(0));
      final items = s.items.toList();
      await pumpEventQueue();
      peer.sendHex('41 48 45 4C 4C 4F 00 00 00');
      await expectLater(pending, throwsStatus(StatusCode.protocolError));
      await expectLater(items, throwsStatus(StatusCode.protocolError));
      await ended.future;
      expect(errors, isEmpty);
      expect((await peer.talk.done).known, StatusCode.protocolError);
      await pumpEventQueue();
      expect(peer.ended, isTrue, reason: 'raw channel closed');
      expect(
        () => peer.talk.send('X', Uint8List(0)),
        throwsStatus(StatusCode.failedPrecondition),
      );
      expect(
        () => peer.talk.request('X', Uint8List(0)),
        throwsStatus(StatusCode.failedPrecondition),
      );
    });

    test('frames after a protocol error are not processed', () async {
      final peer = RawPeer();
      final messages = <TalkMessage>[];
      serve(peer.talk, messages.add);
      peer.sendHex('00 01');
      peer.send(TalkFrame(kind: TalkKind.message, procedure: Name('A')));
      await peer.talk.done;
      expect(messages, isEmpty);
    });

    test(
      'underlying channel closing: connectionLost, messages end, done',
      () async {
        final peer = RawPeer();
        final ended = Completer<void>();
        TalkMessage? held;
        peer.talk.messages.listen((m) => held = m, onDone: ended.complete);
        final pending = peer.talk.request('X', Uint8List(0));
        final s = peer.talk.streamRequest('Y', Uint8List(0));
        final items = s.items.toList();
        peer.send(
          TalkFrame(kind: TalkKind.message, procedure: Name('Q'), requestId: 1),
        );
        await pumpEventQueue();
        expect(held!.canReply, isTrue);
        peer.raw.sink.close().ignore();
        await expectLater(pending, throwsStatus(StatusCode.connectionLost));
        await expectLater(items, throwsStatus(StatusCode.connectionLost));
        await expectLater(s.done, throwsStatus(StatusCode.connectionLost));
        await ended.future;
        expect(await peer.talk.done, Status.ok);
        expect(peer.talk.isOpen, isFalse);
        expect(held!.isCancelled, isTrue);
        await held!.onCancel;
        expect(
          () => held!.reply(Uint8List(0)),
          throwsStatus(StatusCode.failedPrecondition),
        );
        await peer.talk.close();
      },
    );

    test('an error on the raw stream fails the channel', () async {
      final peer = RawPeer();
      final pending = expectLater(
        peer.talk.request('X', Uint8List(0)),
        throwsStatus(StatusCode.connectionLost),
      );
      await pumpEventQueue();
      peer.raw.sink.addError(StateError('transport failed'));
      await pending;
      expect((await peer.talk.done).known, StatusCode.connectionLost);
      expect(peer.talk.isOpen, isFalse);
    });

    test('mux channel end status is used for outstanding requests', () async {
      final peer = RawPeer(mux: true);
      final pending = peer.talk.request('X', Uint8List(0));
      await pumpEventQueue();
      peer.mux!.endFromPeer(peer.raw, Status.of(StatusCode.goingAway));
      await expectLater(pending, throwsStatus(StatusCode.goingAway));
      expect((await peer.talk.done).known, StatusCode.goingAway);
      expect(peer.mux!.closedWith, isEmpty, reason: 'mux confirms itself');
    });

    test('close passes the status to a status-closable channel', () async {
      final peer = RawPeer(mux: true);
      final pending = expectLater(
        peer.talk.request('X', Uint8List(0)),
        throwsStatus(StatusCode.unavailable),
      );
      await peer.talk.close(Status.of(StatusCode.unavailable, 'bye'));
      await pending;
      expect(
        peer.mux!.closedWith.single,
        Status.of(StatusCode.unavailable, 'bye'),
      );
      expect(await peer.talk.done, Status.of(StatusCode.unavailable, 'bye'));
    });

    test('local abort sends a channel abort and closes', () async {
      final peer = RawPeer(mux: true);
      peer.talk.abort(const Status(1234, 'app'));
      await peer.talk.done;
      await pumpEventQueue();
      expect(hexString(peer.received.single.encode()), '20 D2 04 61 70 70');
      expect(peer.mux!.closedWith.single.known, StatusCode.unknown);
      expect(await peer.talk.done, const Status(1234, 'app'));
      peer.talk.abort(Status.of(StatusCode.internal));
      expect(peer.received, hasLength(1));
    });

    test('close: both sides end, outstanding work fails, no timers left', () {
      fakeAsync((async) {
        final p = Pair(
          a: const TalkOptions(requestTimeout: ms30),
          b: const TalkOptions(replyTimeout: ms30),
        );
        TalkMessage? held;
        serve(p.b, (m) => held = m);
        final pending = Outcome(p.a.request('X', Uint8List(0)));
        async.flushMicrotasks();
        expect(async.pendingTimers, hasLength(2));
        final closing = Outcome(p.a.close());
        expect(identical(p.a.close(), p.a.close()), isTrue);
        async.flushMicrotasks();
        expect(pending.error, isStatus(StatusCode.cancelled));
        expect(closing.isDone, isTrue);
        expect(held!.isCancelled, isTrue);
        final aDone = Outcome(p.a.done);
        final bDone = Outcome(p.b.done);
        async.flushMicrotasks();
        expect(aDone.value, Status.ok);
        expect(bDone.value, Status.ok);
        expect(p.b.isOpen, isFalse);
        expect(async.pendingTimers, isEmpty);
      });
    });
  });
}
