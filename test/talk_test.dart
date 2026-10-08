/*
Polyverse Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Authors:
  Jan Boon <jan.boon@kaetemi.be>
  Claude Fable 5.1 <noreply@anthropic.com>
  Claude Opus 5.5 <noreply@anthropic.com>
*/

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:async/async.dart';
import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:switchboard/src/bytes.dart';
import 'package:switchboard/src/name.dart';
import 'package:switchboard/src/status.dart';
import 'package:switchboard/src/talk/talk_channel.dart';
import 'package:switchboard/src/talk/talk_frame.dart';
import 'package:switchboard/src/talk/talk_message.dart';
import 'package:switchboard/src/talk/talk_stream.dart';
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

  /// Completes [done] alone, as the mux does once the close completes.
  void completeDone(Status status) => _done.complete(status);
}

/// A sink that refuses frames over [limit] bytes, like a mux channel whose
/// peer announced a frame size limit.
class _LimitedSink implements StreamSink<Uint8List> {
  _LimitedSink(this._inner, this.limit);

  final StreamSink<Uint8List> _inner;
  final int limit;

  @override
  void add(Uint8List event) {
    if (event.length > limit) {
      throw SwitchboardException.of(StatusCode.frameTooLarge);
    }
    _inner.add(event);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _inner.addError(error, stackTrace);

  @override
  Future<void> addStream(Stream<Uint8List> stream) => _inner.addStream(stream);

  @override
  Future<void> close() => _inner.close();

  @override
  Future<void> get done => _inner.done;
}

/// A sink that hands each frame to [intercept], when set, instead of
/// passing it on: the interceptor passes it on with `pass`, and may do more
/// before or after, or throw instead.
class _InterceptingSink implements StreamSink<Uint8List> {
  _InterceptingSink(this._inner);

  final StreamSink<Uint8List> _inner;

  void Function(TalkFrame frame, void Function() pass)? intercept;

  @override
  void add(Uint8List event) {
    final intercept = this.intercept;
    if (intercept == null) {
      _inner.add(event);
    } else {
      intercept(TalkFrame.decode(event), () => _inner.add(event));
    }
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _inner.addError(error, stackTrace);

  @override
  Future<void> addStream(Stream<Uint8List> stream) => _inner.addStream(stream);

  @override
  Future<void> close() => _inner.close();

  @override
  Future<void> get done => _inner.done;
}

/// A responder over a synchronous link, holding request 1 of a peer driven
/// by hand. [cancelDuring] has the peer cancel the request while the
/// responder is still sending a reply: over a synchronous transport the
/// responder handles the cancel at once, inside its own send.
class SyncResponder {
  SyncResponder({bool stream = false}) {
    final c = StreamChannelController<Uint8List>(sync: true);
    _peer = c.foreign;
    _sink = _InterceptingSink(c.local.sink);
    talk = TalkChannel(StreamChannel<Uint8List>(c.local.stream, _sink));
    _peer.stream.listen((data) => sent.add(TalkFrame.decode(data)));
    talk.messages.listen(_held.add);
    send(
      TalkFrame(
        kind: TalkKind.message,
        procedure: Name('Q'),
        requestId: 1,
        stream: stream,
      ),
    );
  }

  late final StreamChannel<Uint8List> _peer;
  // The talk channel closes it.
  // ignore: close_sinks
  late final _InterceptingSink _sink;
  late final TalkChannel talk;
  final List<TalkMessage> _held = [];

  /// Every frame the responder sent, in wire order.
  final List<TalkFrame> sent = [];

  /// The peer's request 1, once delivered.
  TalkMessage get request => _held.single;

  void send(TalkFrame frame) => _peer.sink.add(frame.encode());

  /// The peer cancels request 1 while the responder sends the first frame
  /// [when] accepts: once the frame is on the wire, or, if [refuse], in
  /// place of it, the send then failing with [StatusCode.frameTooLarge].
  void cancelDuring(
    bool Function(TalkFrame frame) when, {
    bool refuse = false,
  }) {
    _sink.intercept = (frame, pass) {
      if (!when(frame)) {
        pass();
        return;
      }
      _sink.intercept = null;
      if (!refuse) {
        pass();
      }
      send(
        TalkFrame(
          kind: TalkKind.abort,
          requestId: 1,
          payload: Status.of(StatusCode.cancelled).encode(),
        ),
      );
      if (refuse) {
        throw SwitchboardException.of(StatusCode.frameTooLarge);
      }
    };
  }

  /// The final responses sent for request 1.
  List<TalkFrame> get finals => [
    for (final frame in sent)
      if (frame.responseId == 1 &&
          (frame.kind == TalkKind.message || frame.kind == TalkKind.abort))
        frame,
  ];
}

/// Runs [body] and returns the errors it left unhandled.
Future<List<Object>> uncaughtErrors(Future<void> Function() body) {
  final errors = <Object>[];
  final finished = Completer<List<Object>>();
  runZonedGuarded(() {
    body().whenComplete(() async {
      await pumpEventQueue();
      finished.complete(errors);
    });
  }, (error, stackTrace) => errors.add(error));
  return finished.future;
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

    test('a request whose handler threw is marked cancelled', () async {
      final p = Pair();
      final seen = <String, TalkMessage>{};
      p.b.messages.listen((m) {
        seen[m.procedureName] = m;
        if (m.procedureName == 'LATE') {
          m.reply(bytes([1]));
        }
        throw StateError('handler bug');
      });
      await expectLater(
        p.a.request('BOOM', Uint8List(0)),
        throwsStatus(StatusCode.internal),
      );
      expect((await p.a.request('LATE', Uint8List(0))).payload, [1]);
      final boom = seen['BOOM']!;
      final onCancel = Outcome(boom.onCancel);
      await pumpEventQueue();
      expect(boom.isCancelled, isTrue, reason: 'work should stop');
      expect(onCancel.isDone, isTrue);
      expect(boom.canReply, isFalse);
      expect(seen['LATE']!.isCancelled, isFalse, reason: 'it was answered');
      expect(p.bToA.where((f) => f.kind == TalkKind.abort), hasLength(1));
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
    test('requester cancels: the channel answers CANCELLED at once and '
        'the responder sees onCancel', () async {
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
      expect(error, isNot(isA<TalkAbortException>()), reason: 'local');
      await expectLater(s.done, throwsStatus(StatusCode.cancelled));
      final cancel = p.aToB.last;
      expect(cancel.kind, TalkKind.abort);
      expect(cancel.requestId, s.requestId);
      expect(cancel.hasResponse, isFalse);
      expect(cancel.status.known, StatusCode.cancelled);

      final m = await cancelSeen.future;
      // The channel already sent the final; the request is finished.
      expect(m.canReply, isFalse);
      final failed = throwsStatus(StatusCode.failedPrecondition);
      expect(() => m.replyItem(bytes([2])), failed);
      expect(() => m.replyAbort(Status.of(StatusCode.cancelled)), failed);
      expect(() => m.extend(), failed);
      await pumpEventQueue();
      final aborts = p.bToA.where((f) => f.kind == TalkKind.abort).toList();
      expect(aborts, hasLength(1));
      expect(aborts.single.responseId, s.requestId);
      expect(aborts.single.status.known, StatusCode.cancelled);
      expect(got, [1]);
      expect(p.a.outgoingRequestCount, 0);
      expect(p.b.incomingRequestCount, 0);
      expect(p.a.isOpen, isTrue);
      await p.close();
    });

    test('a peer cancel with no responder timeout still finishes the '
        'request', () async {
      final peer = RawPeer(
        options: const TalkOptions(replyTimeout: Duration.zero),
      );
      TalkMessage? held;
      serve(peer.talk, (m) => held = m);
      peer.send(
        TalkFrame(kind: TalkKind.message, procedure: Name('A'), requestId: 1),
      );
      await pumpEventQueue();
      expect(peer.talk.incomingRequestCount, 1);
      peer.sendHex('22 01 00 00 01 00');
      await pumpEventQueue();
      expect(peer.received.single.kind, TalkKind.abort);
      expect(peer.received.single.responseId, 1);
      expect(peer.received.single.status.known, StatusCode.cancelled);
      expect(peer.talk.incomingRequestCount, 0);
      expect(held!.isCancelled, isTrue);
      expect(held!.canReply, isFalse);
      expect(
        () => held!.reply(Uint8List(0)),
        throwsStatus(StatusCode.failedPrecondition),
      );
      await peer.talk.close();
    });

    test('a cancelled request rejects a chained final', () async {
      final peer = RawPeer();
      final s = peer.talk.streamRequest('S', Uint8List(0));
      s.done.ignore();
      s.cancel(const Status(1, 'stop'));
      s.cancel();
      await pumpEventQueue();
      expect(peer.received.last.status, const Status(1, 'stop'));
      expect(peer.received, hasLength(2));
      // The id stays reserved until the final arrives.
      expect(peer.talk.outgoingRequestCount, 1);
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
    /// The longest delay a JavaScript timer takes, a signed 32-bit number
    /// of milliseconds (about 24.8 days); a longer one fires at once.
    const maxTimerDelay = Duration(milliseconds: 0x7FFFFFFF);

    void expectTimersInRange(FakeAsync async) => expect(
      async.pendingTimers.map((t) => t.duration),
      everyElement(lessThanOrEqualTo(maxTimerDelay)),
      reason: 'longer timers fire at once on JavaScript',
    );

    test('long requester timeouts are armed in steps a JavaScript timer '
        'takes, and expire on time', () {
      fakeAsync((async) {
        final peer = RawPeer(
          options: const TalkOptions(
            requestTimeout: Duration(days: 30),
            maxExtension: Duration.zero,
          ),
        );
        final gap = Outcome(peer.talk.request('Q', Uint8List(0)));
        final declared = Outcome(peer.talk.request('Q', Uint8List(0)));
        async.flushMicrotasks();
        peer.send(
          TalkFrame(
            kind: TalkKind.extend,
            responseId: 2,
            payload: TalkFrame.extendPayload(
              deadline: const Duration(days: 40),
            ),
          ),
        );
        async.flushMicrotasks();
        expectTimersInRange(async);
        async.elapse(const Duration(days: 29));
        expectTimersInRange(async);
        expect(gap.isDone, isFalse);
        async.elapse(const Duration(days: 1));
        expect(gap.error, isStatus(StatusCode.deadlineExceeded));
        async.elapse(const Duration(days: 9));
        expectTimersInRange(async);
        expect(declared.isDone, isFalse);
        async.elapse(const Duration(days: 1));
        expect(declared.error, isStatus(StatusCode.deadlineExceeded));
        expect(peer.talk.outgoingRequestCount, 0);
        expect(async.pendingTimers, isEmpty);
        peer.talk.close();
        async.flushMicrotasks();
      });
    });

    test('long cancelled-id timeouts rearm until their deadline', () {
      fakeAsync((async) {
        final peer = RawPeer(
          options: const TalkOptions(requestTimeout: Duration(days: 30)),
        );
        peer.talk.startRequest('Q', Uint8List(0)).cancel();
        expectTimersInRange(async);
        async.elapse(const Duration(days: 29));
        expectTimersInRange(async);
        expect(peer.talk.outgoingRequestCount, 1);
        async.elapse(const Duration(days: 1));
        expect(peer.talk.outgoingRequestCount, 0);
        expect(async.pendingTimers, isEmpty);
        peer.talk.close();
        async.flushMicrotasks();
      });
    });

    test('long responder deadlines are armed in steps a JavaScript timer '
        'takes, and expire on time', () {
      fakeAsync((async) {
        final peer = RawPeer();
        TalkMessage? held;
        peer.talk.messages.listen((m) => held = m);
        peer.send(
          TalkFrame(kind: TalkKind.message, procedure: Name('Q'), requestId: 1),
        );
        async.flushMicrotasks();
        held!.extend(deadline: const Duration(days: 30));
        expectTimersInRange(async);
        async.elapse(const Duration(days: 29));
        expectTimersInRange(async);
        expect(held!.canReply, isTrue);
        async.elapse(const Duration(days: 1));
        expect(held!.canReply, isFalse);
        expect(peer.received.last.kind, TalkKind.abort);
        expect(peer.received.last.status.known, StatusCode.deadlineExceeded);
        expect(async.pendingTimers, isEmpty);
        peer.talk.close();
        async.flushMicrotasks();
      });
    });

    test(
      'long requester timeouts do not overflow the platform timer',
      () async {
        final peer = RawPeer(
          options: const TalkOptions(requestTimeout: Duration(days: 30)),
        );
        addTearDown(peer.talk.close);
        final request = peer.talk.startRequest('Q', Uint8List(0));
        final result = Outcome(request.response);
        await Future<void>.delayed(ms30);
        expect(result.isDone, isFalse);
        request.cancel();
        await Future<void>.delayed(ms30);
        expect(
          peer.talk.outgoingRequestCount,
          1,
          reason: 'the cancelled id keeps its long release timeout',
        );
        await peer.talk.close();
      },
    );

    test(
      'long declared deadlines do not overflow the platform timer',
      () async {
        final p = Pair(a: const TalkOptions(maxExtension: Duration.zero));
        addTearDown(p.close);
        final held = <TalkMessage>[];
        serve(p.b, (m) {
          held.add(m);
          m.extend(deadline: const Duration(days: 30));
        });
        final response = Outcome(p.a.request('Q', Uint8List(0)));
        await pumpEventQueue();
        await Future<void>.delayed(ms30);
        expect(held, hasLength(1));
        expect(held.single.canReply, isTrue);
        expect(response.isDone, isFalse);
        await p.close();
      },
    );

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

  group('abort statuses', () {
    test('an empty abort response payload means UNKNOWN', () async {
      final peer = RawPeer();
      final pending = peer.talk.request('X', Uint8List(0));
      await pumpEventQueue();
      peer.sendHex('24 01 00 00');
      await expectLater(
        pending,
        throwsA(
          isA<TalkAbortException>()
              .having((e) => e.code, 'code', StatusCode.unknown)
              .having((e) => e.isChannelAbort, 'isChannelAbort', isFalse),
        ),
      );
      await peer.talk.close();
    });

    test('an abort response carrying OK reads as UNKNOWN', () async {
      final peer = RawPeer();
      final pending = peer.talk.request('X', Uint8List(0));
      await pumpEventQueue();
      peer.sendHex('24 01 00 00 00 00 6F 6B');
      await expectLater(
        pending,
        throwsA(
          isA<TalkAbortException>().having(
            (e) => e.status,
            'status',
            const Status(2, 'ok'),
          ),
        ),
      );
      await peer.talk.close();
    });

    test('an empty channel abort closes the channel with UNKNOWN', () async {
      final peer = RawPeer(mux: true);
      final errors = <Object>[];
      peer.talk.messages.listen((_) {}, onError: errors.add);
      final pending = peer.talk.request('X', Uint8List(0));
      await pumpEventQueue();
      peer.sendHex('20');
      expect((await peer.talk.done).known, StatusCode.unknown);
      await expectLater(
        pending,
        throwsA(
          isA<TalkAbortException>()
              .having((e) => e.code, 'code', StatusCode.unknown)
              .having((e) => e.isChannelAbort, 'isChannelAbort', isTrue),
        ),
      );
      expect(errors.single, isA<TalkAbortException>());
      expect(peer.mux!.closedWith.single.known, StatusCode.unknown);
    });

    test('replyAbort and abort refuse OK', () async {
      final p = Pair();
      serve(p.b, (m) {
        expect(() => m.replyAbort(Status.ok), throwsArgumentError);
        expect(
          () => m.replyAbort(const Status(0, 'fine')),
          throwsArgumentError,
        );
        expect(m.canReply, isTrue);
        m.reply(bytes([1]));
      });
      expect((await p.a.request('X', Uint8List(0))).payload, [1]);
      expect(() => p.a.abort(Status.ok), throwsArgumentError);
      expect(p.a.isOpen, isTrue);
      expect(p.aToB, hasLength(1));
      await p.close();
      expect(() => p.a.abort(Status.ok), throwsArgumentError);
    });

    test('CONNECTION_LOST never goes on the wire', () async {
      final lost = Status.of(StatusCode.connectionLost, 'upstream gone');
      final peer = RawPeer(mux: true);
      final held = <TalkMessage>[];
      serve(peer.talk, held.add);
      peer.send(
        TalkFrame(kind: TalkKind.message, procedure: Name('A'), requestId: 1),
      );
      final s = peer.talk.streamRequest('S', Uint8List(0));
      await pumpEventQueue();
      held.single.replyAbort(lost);
      s.cancel(lost);
      await pumpEventQueue();
      final replyAbort = peer.received.firstWhere((f) => f.hasResponse);
      expect(replyAbort.status.known, StatusCode.unavailable);
      expect(replyAbort.status.reason, contains('upstream gone'));
      final cancel = peer.received.lastWhere((f) => f.kind == TalkKind.abort);
      expect(cancel.requestId, s.requestId);
      expect(cancel.status.known, StatusCode.unavailable);
      // Locally the cancel status is reported as given.
      await expectLater(s.done, throwsStatus(StatusCode.connectionLost));

      peer.talk.abort(lost);
      await peer.talk.done;
      await pumpEventQueue();
      expect(peer.received.last.hasRequest, isFalse);
      expect(peer.received.last.hasResponse, isFalse);
      expect(peer.received.last.status.known, StatusCode.unavailable);
      expect(peer.mux!.closedWith.single.known, StatusCode.unavailable);
      expect(await peer.talk.done, lost);
    });

    test('close with CONNECTION_LOST, or a peer channel abort carrying it, '
        'closes the mux channel with UNAVAILABLE', () async {
      final closing = RawPeer(mux: true);
      await closing.talk.close(Status.of(StatusCode.connectionLost));
      expect(closing.mux!.closedWith.single.known, StatusCode.unavailable);

      final aborted = RawPeer(mux: true);
      aborted.talk.messages.listen((_) {});
      aborted.send(
        TalkFrame(
          kind: TalkKind.abort,
          payload: Status.of(StatusCode.connectionLost).encode(),
        ),
      );
      expect((await aborted.talk.done).known, StatusCode.connectionLost);
      expect(aborted.mux!.closedWith.single.known, StatusCode.unavailable);
    });
  });

  group('unhandled errors', () {
    test('a messages listener without onError survives a channel '
        'abort', () async {
      final errors = await uncaughtErrors(() async {
        final p = Pair();
        var ended = false;
        p.a.messages.listen((_) {}, onDone: () => ended = true);
        p.b.abort(Status.of(StatusCode.unauthenticated, 'bad token'));
        expect((await p.a.done).known, StatusCode.unauthenticated);
        await pumpEventQueue();
        expect(ended, isTrue);
      });
      expect(errors, isEmpty);
    });

    test('onError(null) on the subscription logs instead', () async {
      final errors = await uncaughtErrors(() async {
        final peer = RawPeer();
        final seen = <Object>[];
        final subscription = peer.talk.messages.listen(
          (_) {},
          onError: seen.add,
        );
        subscription.onError(null);
        peer.sendHex('20 10 00');
        await peer.talk.done;
        await pumpEventQueue();
        expect(seen, isEmpty);
        await subscription.cancel();
      });
      expect(errors, isEmpty);
    });

    test('items listeners without onError survive aborts, cancels and '
        'timeouts', () async {
      final errors = await uncaughtErrors(() async {
        final peer = RawPeer();
        final aborted = peer.talk.streamRequest('A', Uint8List(0));
        aborted.items.listen((_) {});
        final cancelled = peer.talk.streamRequest('C', Uint8List(0));
        cancelled.items.listen((_) {});
        // Only this request should expire while the event queue is pumped.
        final expired = peer.talk.streamRequest(
          'T',
          Uint8List(0),
          timeout: const Duration(milliseconds: 5),
        );
        expired.items.listen((_) {});
        await pumpEventQueue();
        peer.send(
          TalkFrame(
            kind: TalkKind.abort,
            responseId: aborted.requestId,
            payload: Status.of(StatusCode.notFound).encode(),
          ),
        );
        cancelled.cancel();
        await expectLater(
          expired.done,
          throwsStatus(StatusCode.deadlineExceeded),
        );
        await expectLater(aborted.done, throwsA(isA<TalkAbortException>()));
        await peer.talk.close();
        await pumpEventQueue();
      });
      expect(errors, isEmpty);
    });

    test('an abort response to an unlistened items stream', () async {
      final errors = await uncaughtErrors(() async {
        final peer = RawPeer();
        final s = peer.talk.streamRequest('S', Uint8List(0));
        await pumpEventQueue();
        peer.send(
          TalkFrame(
            kind: TalkKind.abort,
            responseId: s.requestId,
            payload: const Status(300, 'app').encode(),
          ),
        );
        await pumpEventQueue();
        await peer.talk.close();
        await pumpEventQueue();
        // The error is still there for a late listener.
        await expectLater(s.items.toList(), throwsA(isA<TalkAbortException>()));
      });
      expect(errors, isEmpty);
    });

    test('dropped request futures fail quietly on close', () async {
      final errors = await uncaughtErrors(() async {
        final p = Pair();
        final held = <TalkMessage>[];
        serve(p.b, (m) {
          held.add(m);
          if (m.procedureName == 'CHAIN') {
            unawaited(m.replyRequest(Uint8List(0)));
          } else if (m.procedureName == 'ITEMS') {
            unawaited(m.replyItemRequest(Uint8List(0)));
          }
        });
        unawaited(p.a.request('PLAIN', Uint8List(0)));
        unawaited(p.a.startRequest('HANDLE', Uint8List(0)).response);
        unawaited(p.a.request('CHAIN', Uint8List(0)));
        final s = p.a.streamRequest('ITEMS', Uint8List(0));
        s.items.listen((_) {}, onError: (Object _) {});
        await pumpEventQueue();
        expect(held, hasLength(4));
        expect(p.b.outgoingRequestCount, 2);
        await p.close();
        await pumpEventQueue();
      });
      expect(errors, isEmpty);
    });
  });

  group('request handles and EXTEND', () {
    test(
      'startRequest returns a handle with the id and the response',
      () async {
        final p = Pair();
        final held = <TalkMessage>[];
        serve(p.b, held.add);
        final r = p.a.startRequest('A', bytes([1]));
        final c = p.a.startRequest('B', bytes([2]));
        await pumpEventQueue();
        expect(r.requestId, p.aToB.first.requestId);
        expect(c.requestId, p.aToB.last.requestId);
        held.first.reply(bytes([3]));
        expect((await r.response).payload, [3]);
        c.cancel();
        await expectLater(
          c.response,
          throwsA(
            isA<SwitchboardException>()
                .having((e) => e.code, 'code', StatusCode.cancelled)
                .having((e) => e is TalkAbortException, 'remote', isFalse),
          ),
        );
        await pumpEventQueue();
        expect(held.last.isCancelled, isTrue);
        expect(p.a.outgoingRequestCount, 0);
        await p.close();
      },
    );

    test('onExtend is called for every EXTEND, on every kind of '
        'request', () async {
      final p = Pair();
      final counts = <String, int>{};
      void Function(Duration?, Duration?) counter(String key) =>
          (_, _) => counts[key] = (counts[key] ?? 0) + 1;
      serve(p.b, (m) async {
        m.extend();
        m.extend();
        if (m.procedureName == 'CHAIN') {
          final r = m.startReplyRequest(
            Uint8List(0),
            onExtend: counter('chained'),
          );
          await r.response;
        } else if (m.procedureName == 'CHAINS') {
          final s = m.replyStreamRequest(
            Uint8List(0),
            onExtend: counter('chainedStream'),
          );
          await s.done;
        } else if (m.procedureName == 'ITEMS') {
          final r = m.startReplyItemRequest(
            Uint8List(0),
            onExtend: counter('item'),
          );
          final s = m.replyItemStreamRequest(
            Uint8List(0),
            onExtend: counter('itemStream'),
          );
          await r.response;
          await s.done;
          m.reply(Uint8List(0));
        } else {
          m.reply(Uint8List(0));
        }
      });
      final plain = p.a.startRequest(
        'PLAIN',
        Uint8List(0),
        onExtend: counter('request'),
      );
      await plain.response;
      final stream = p.a.streamRequest(
        'STREAM',
        Uint8List(0),
        onExtend: counter('stream'),
      );
      await stream.done;
      for (final procedure in ['CHAIN', 'CHAINS']) {
        final r = await p.a.request(procedure, Uint8List(0));
        r.extend();
        r.reply(Uint8List(0));
      }
      final items = p.a.streamRequest('ITEMS', Uint8List(0));
      items.items.listen((item) {
        item.extend();
        item.reply(Uint8List(0));
      });
      await items.done;
      await pumpEventQueue();
      expect(counts, {
        'request': 2,
        'stream': 2,
        'chained': 1,
        'chainedStream': 1,
        'item': 1,
        'itemStream': 1,
      });
      await p.close();
    });

    test('an onExtend callback that throws is logged only', () async {
      final peer = RawPeer();
      final r = peer.talk.startRequest(
        'X',
        Uint8List(0),
        onExtend: (_, _) => throw StateError('callback bug'),
      );
      await pumpEventQueue();
      peer.send(TalkFrame(kind: TalkKind.extend, responseId: r.requestId));
      peer.send(TalkFrame(kind: TalkKind.message, responseId: r.requestId));
      await r.response;
      expect(peer.talk.isOpen, isTrue);
      await peer.talk.close();
    });

    test('EXTEND restarts the timer of a stream request', () {
      fakeAsync((async) {
        final peer = RawPeer(options: const TalkOptions(requestTimeout: ms30));
        var extends_ = 0;
        final s = peer.talk.streamRequest(
          'S',
          Uint8List(0),
          onExtend: (_, _) => extends_++,
        );
        final done = Outcome(s.done);
        async.flushMicrotasks();
        for (var i = 0; i < 5; i++) {
          async.elapse(const Duration(milliseconds: 20));
          peer.send(TalkFrame(kind: TalkKind.extend, responseId: s.requestId));
          async.flushMicrotasks();
        }
        async.elapse(const Duration(milliseconds: 20));
        expect(done.isDone, isFalse);
        expect(extends_, 5);
        peer.send(TalkFrame(kind: TalkKind.message, responseId: s.requestId));
        async.flushMicrotasks();
        expect(done.value, isNotNull);
        peer.talk.close();
        async.flushMicrotasks();
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('EXTEND after a cancel is ignored', () {
      fakeAsync((async) {
        final peer = RawPeer(options: const TalkOptions(requestTimeout: ms30));
        var extends_ = 0;
        final s = peer.talk.streamRequest(
          'S',
          Uint8List(0),
          onExtend: (_, _) => extends_++,
        );
        s.done.ignore();
        async.flushMicrotasks();
        s.cancel();
        async.elapse(const Duration(milliseconds: 20));
        peer.send(TalkFrame(kind: TalkKind.extend, responseId: s.requestId));
        async.flushMicrotasks();
        expect(extends_, 0);
        expect(peer.talk.outgoingRequestCount, 1);
        // The release timer was not restarted by the EXTEND.
        async.elapse(const Duration(milliseconds: 11));
        expect(peer.talk.outgoingRequestCount, 0);
        peer.talk.close();
        async.flushMicrotasks();
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('a cancelled request without a timeout is released after the '
        'channel default', () {
      fakeAsync((async) {
        final peer = RawPeer(options: const TalkOptions(requestTimeout: ms30));
        final s = peer.talk.streamRequest(
          'S',
          Uint8List(0),
          timeout: Duration.zero,
        );
        s.done.ignore();
        async.elapse(const Duration(hours: 1));
        expect(peer.talk.outgoingRequestCount, 1);
        s.cancel();
        async.elapse(const Duration(milliseconds: 31));
        expect(peer.talk.outgoingRequestCount, 0);
        peer.talk.close();
        async.flushMicrotasks();
      });
    });

    test('an item that is itself a stream request', () async {
      final p = Pair();
      serve(p.b, (m) async {
        final sub = m.replyItemStreamRequest(bytes([1]), procedure: 'SUB');
        final got = await sub.items.map((i) => i.payload.single).toList();
        final end = await sub.done;
        m.reply(bytes([...got, end.payload.single]));
      });
      final s = p.a.streamRequest('S', Uint8List(0));
      s.items.listen((item) {
        expect(item.kind, TalkKind.streamItem);
        expect(item.expectsReply, isTrue);
        expect(item.expectsStream, isTrue);
        expect(item.procedureName, 'SUB');
        item.replyItem(bytes([7]));
        item.replyItem(bytes([8]));
        item.reply(bytes([9]));
      });
      expect((await s.done).payload, [7, 8, 9]);
      final item = p.bToA.first;
      expect(item.kind, TalkKind.streamItem);
      expect(item.flags, 0x1F);
      expect(item.responseId, s.requestId);
      expect(p.a.incomingRequestCount, 0);
      expect(p.b.outgoingRequestCount, 0);
      await p.close();
    });

    test('remote aborts are TalkAbortException, local failures are '
        'not', () async {
      final peer = RawPeer();
      final remote = peer.talk.request('R', Uint8List(0));
      final expired = peer.talk.request(
        'T',
        Uint8List(0),
        timeout: const Duration(milliseconds: 1),
      );
      final cancelled = peer.talk.startRequest('C', Uint8List(0));
      cancelled.cancel();
      await pumpEventQueue();
      peer.send(
        TalkFrame(
          kind: TalkKind.abort,
          responseId: peer.received.first.requestId,
          payload: Status.of(StatusCode.deadlineExceeded).encode(),
        ),
      );
      Matcher local(StatusCode code) => throwsA(
        isA<SwitchboardException>()
            .having((e) => e.code, 'code', code)
            .having((e) => e is TalkAbortException, 'remote', isFalse),
      );
      await expectLater(
        remote,
        throwsA(
          isA<TalkAbortException>().having(
            (e) => e.code,
            'code',
            StatusCode.deadlineExceeded,
          ),
        ),
      );
      await expectLater(expired, local(StatusCode.deadlineExceeded));
      await expectLater(cancelled.response, local(StatusCode.cancelled));
      final lost = peer.talk.request('L', Uint8List(0));
      final broken = RawPeer();
      final protocol = broken.talk.request('P', Uint8List(0));
      await pumpEventQueue();
      peer.raw.sink.close().ignore();
      broken.sendHex('41');
      await expectLater(lost, local(StatusCode.connectionLost));
      await expectLater(protocol, local(StatusCode.protocolError));
    });
  });

  group('declared deadlines', () {
    const sec = Duration(seconds: 1);
    const ms1 = Duration(milliseconds: 1);

    TalkFrame declare(int id, {Duration? deadline, Duration? renew}) =>
        TalkFrame(
          kind: TalkKind.extend,
          responseId: id,
          payload: TalkFrame.extendPayload(deadline: deadline, renew: renew),
        );

    TalkFrame item(int id) =>
        TalkFrame(kind: TalkKind.streamItem, responseId: id);

    /// A stream request from a raw peer's channel (default options unless
    /// given), its outcome, and the time it was sent.
    (RawPeer, TalkStream, Outcome<TalkMessage>, DateTime) start(
      FakeAsync async, {
      TalkOptions options = const TalkOptions(),
    }) {
      final peer = RawPeer(options: options);
      final s = peer.talk.streamRequest('S', Uint8List(0));
      final done = Outcome(s.done);
      async.flushMicrotasks();
      return (peer, s, done, clock.now());
    }

    void finish(FakeAsync async, RawPeer peer) {
      peer.talk.close();
      async.flushMicrotasks();
      expect(async.pendingTimers, isEmpty);
    }

    /// Expects [done] to fail with the requester's own DEADLINE_EXCEEDED
    /// exactly [left] from now.
    void expectTimeoutIn(
      FakeAsync async,
      Outcome<TalkMessage> done,
      Duration left,
    ) {
      async.elapse(left - ms1);
      expect(done.isDone, isFalse);
      async.elapse(ms1);
      expect(
        done.error,
        isA<SwitchboardException>()
            .having((e) => e.code, 'code', StatusCode.deadlineExceeded)
            .having((e) => e is TalkAbortException, 'remote', isFalse),
      );
    }

    test('without EXTEND the default gap applies, restarted by items', () {
      fakeAsync((async) {
        final (peer, s, done, t0) = start(async);
        expect(s.deadline, t0.add(sec * 15));
        async.elapse(sec * 10);
        peer.send(item(s.requestId));
        async.flushMicrotasks();
        expect(s.deadline, t0.add(sec * 25));
        expectTimeoutIn(async, done, sec * 15);
        expect(s.deadline, isNull);
        finish(async, peer);
      });
    });

    test('a deadline replaces the default gap; items do not move it', () {
      fakeAsync((async) {
        final (peer, s, done, t0) = start(async);
        peer.send(declare(s.requestId, deadline: sec * 60));
        async.flushMicrotasks();
        expect(s.deadline, t0.add(sec * 60));
        async.elapse(sec * 50);
        peer.send(item(s.requestId));
        async.flushMicrotasks();
        expect(s.deadline, t0.add(sec * 60), reason: 'no renewal declared');
        expectTimeoutIn(async, done, sec * 10);
        // The requester cancels what it gave up on.
        expect(peer.received.last.kind, TalkKind.abort);
        expect(peer.received.last.requestId, s.requestId);
        finish(async, peer);
      });
    });

    test('a renewal alone counts from the last reply', () {
      fakeAsync((async) {
        final (peer, s, done, t0) = start(async);
        peer.send(declare(s.requestId, renew: sec * 30));
        async.flushMicrotasks();
        expect(s.deadline, t0.add(sec * 30));
        async.elapse(sec * 20);
        peer.send(item(s.requestId));
        async.flushMicrotasks();
        expect(s.deadline, t0.add(sec * 50));
        expectTimeoutIn(async, done, sec * 30);
        finish(async, peer);
      });
    });

    test('with both, the later one applies: a reply never brings the '
        'deadline closer', () {
      fakeAsync((async) {
        final (peer, s, done, t0) = start(async);
        peer.send(declare(s.requestId, deadline: sec * 60, renew: sec * 20));
        async.flushMicrotasks();
        expect(s.deadline, t0.add(sec * 60));
        async.elapse(sec * 10);
        peer.send(item(s.requestId));
        async.flushMicrotasks();
        expect(s.deadline, t0.add(sec * 60), reason: 'not t0 + 30 s');
        async.elapse(sec * 45);
        peer.send(item(s.requestId));
        async.flushMicrotasks();
        expect(s.deadline, t0.add(sec * 75));
        expectTimeoutIn(async, done, sec * 20);
        finish(async, peer);
      });
    });

    test('a later EXTEND replaces what it carries, and may shorten it; a '
        '0 field is unchanged', () {
      fakeAsync((async) {
        final (peer, s, done, t0) = start(async);
        peer.send(
          declare(
            s.requestId,
            deadline: const Duration(minutes: 10),
            renew: const Duration(minutes: 1),
          ),
        );
        async.flushMicrotasks();
        expect(s.deadline, t0.add(const Duration(minutes: 10)));
        async.elapse(sec * 10);
        // Deadline shortened to t0 + 30 s; the renewal of 1 min stands,
        // counted from this EXTEND.
        peer.send(declare(s.requestId, deadline: sec * 20));
        async.flushMicrotasks();
        expect(s.deadline, t0.add(sec * 70));
        async.elapse(sec * 10);
        // Renewal shortened; the deadline (t0 + 30 s) stands.
        peer.send(declare(s.requestId, renew: sec * 5));
        async.flushMicrotasks();
        expect(s.deadline, t0.add(sec * 30));
        expectTimeoutIn(async, done, sec * 10);
        finish(async, peer);
      });
    });

    test('values below minExtension are raised to it', () {
      fakeAsync((async) {
        final (peer, s, done, t0) = start(async);
        peer.send(
          declare(
            s.requestId,
            deadline: const Duration(milliseconds: 100),
            renew: ms1,
          ),
        );
        async.flushMicrotasks();
        expect(s.deadline, t0.add(sec));
        expectTimeoutIn(async, done, sec);
        finish(async, peer);
      });
      fakeAsync((async) {
        final (peer, s, done, _) = start(
          async,
          options: const TalkOptions(minExtension: Duration.zero),
        );
        peer.send(
          declare(s.requestId, deadline: const Duration(milliseconds: 100)),
        );
        async.flushMicrotasks();
        expectTimeoutIn(async, done, const Duration(milliseconds: 100));
        finish(async, peer);
      });
    });

    test('values above maxExtension are lowered to it', () {
      fakeAsync((async) {
        final (peer, s, done, t0) = start(async);
        peer.send(declare(s.requestId, deadline: const Duration(hours: 2)));
        async.flushMicrotasks();
        expect(s.deadline, t0.add(const Duration(hours: 1)));
        expectTimeoutIn(async, done, const Duration(hours: 1));
        finish(async, peer);
      });
      fakeAsync((async) {
        final (peer, s, done, t0) = start(
          async,
          options: const TalkOptions(maxExtension: Duration(minutes: 10)),
        );
        peer.send(declare(s.requestId, renew: const Duration(hours: 1)));
        async.flushMicrotasks();
        expect(s.deadline, t0.add(const Duration(minutes: 10)));
        finish(async, peer);
      });
      fakeAsync((async) {
        final (peer, s, done, t0) = start(
          async,
          options: const TalkOptions(maxExtension: Duration.zero),
        );
        peer.send(declare(s.requestId, deadline: const Duration(days: 3)));
        async.flushMicrotasks();
        expect(s.deadline, t0.add(const Duration(days: 3)));
        finish(async, peer);
      });
    });

    test('an empty EXTEND restarts the default gap, keeping what was '
        'declared; zero fields count as a reply', () {
      fakeAsync((async) {
        final (peer, s, done, t0) = start(async);
        // Default regime: an empty EXTEND and two zero fields restart the
        // gap alike.
        async.elapse(sec * 10);
        peer.send(TalkFrame(kind: TalkKind.extend, responseId: s.requestId));
        async.flushMicrotasks();
        expect(s.deadline, t0.add(sec * 25));
        async.elapse(sec * 10);
        peer.send(
          TalkFrame(
            kind: TalkKind.extend,
            responseId: s.requestId,
            payload: Uint8List(8),
          ),
        );
        async.flushMicrotasks();
        expect(s.deadline, t0.add(sec * 35));
        // Declared: deadline t0 + 80 s.
        peer.send(declare(s.requestId, deadline: sec * 60));
        async.flushMicrotasks();
        async.elapse(sec * 55);
        // t0 + 75 s: the gap ends after the deadline.
        peer.send(TalkFrame(kind: TalkKind.extend, responseId: s.requestId));
        async.flushMicrotasks();
        expect(s.deadline, t0.add(sec * 90));
        async.elapse(sec * 10);
        // t0 + 85 s: a declaration replaces the gap; the deadline stands.
        peer.send(declare(s.requestId, renew: sec * 2));
        async.flushMicrotasks();
        expect(s.deadline, t0.add(sec * 87));
        expectTimeoutIn(async, done, sec * 2);
        finish(async, peer);
      });
    });

    test('an EXTEND payload that is neither empty nor 8 bytes is a channel '
        'protocol error', () async {
      final peer = RawPeer(mux: true);
      final pending = peer.talk.request('X', Uint8List(0));
      await pumpEventQueue();
      peer.sendHex('34 01 00 00 A0 BB 0D 00');
      await expectLater(pending, throwsStatus(StatusCode.protocolError));
      expect((await peer.talk.done).known, StatusCode.protocolError);
      expect(peer.mux!.closedWith.single.known, StatusCode.protocolError);
    });

    test('onExtend receives the values as received', () {
      fakeAsync((async) {
        final peer = RawPeer();
        final seen = <(Duration?, Duration?)>[];
        final r = peer.talk.startRequest(
          'X',
          Uint8List(0),
          onExtend: (deadline, renew) => seen.add((deadline, renew)),
        );
        async.flushMicrotasks();
        final id = r.requestId;
        peer.send(declare(id, deadline: const Duration(milliseconds: 100)));
        peer.send(declare(id, renew: const Duration(hours: 2)));
        peer.send(declare(id, deadline: sec * 90, renew: sec * 30));
        peer.send(TalkFrame(kind: TalkKind.extend, responseId: id));
        async.flushMicrotasks();
        expect(seen, [
          (const Duration(milliseconds: 100), null),
          (null, const Duration(hours: 2)),
          (sec * 90, sec * 30),
          (null, null),
        ]);
        finish(async, peer);
      });
    });

    test('the deadline of a request without a timeout is null', () {
      fakeAsync((async) {
        final peer = RawPeer();
        final r = peer.talk.startRequest(
          'X',
          Uint8List(0),
          timeout: Duration.zero,
        );
        final result = Outcome(r.response);
        async.flushMicrotasks();
        expect(r.deadline, isNull);
        peer.send(declare(r.requestId, deadline: sec * 10));
        async.elapse(const Duration(hours: 2));
        expect(r.deadline, isNull);
        expect(result.isDone, isFalse);
        peer.send(TalkFrame(kind: TalkKind.message, responseId: r.requestId));
        async.flushMicrotasks();
        expect(result.value, isNotNull);
        finish(async, peer);
      });
    });

    test('extend puts the buffer on the wire, not on the responder '
        'timeout, so the responder gives up first', () {
      fakeAsync((async) {
        final p = Pair();
        final held = <TalkMessage>[];
        serve(p.b, held.add);
        final r = p.a.startRequest('SLOW', Uint8List(0));
        final result = Outcome(r.response);
        async.flushMicrotasks();
        final t0 = clock.now();
        held.single.extend(deadline: sec * 60);
        async.flushMicrotasks();
        final wire = p.bToA.single;
        expect(wire.extension, (deadline: sec * 65, renew: null));
        expect(
          hexString(p.bToARaw.single),
          '34 01 00 00 E8 FD 00 00 00 00 00 00',
        );
        expect(r.deadline, t0.add(sec * 65));
        async.elapse(sec * 60 - ms1);
        expect(result.isDone, isFalse);
        async.elapse(ms1);
        expect(
          result.error,
          isA<TalkAbortException>().having(
            (e) => e.code,
            'code',
            StatusCode.deadlineExceeded,
          ),
        );
        expect(held.single.isCancelled, isTrue);
        p.close();
        async.flushMicrotasks();
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('the buffer comes from extendBuffer or the call, on each value', () {
      fakeAsync((async) {
        final p = Pair(
          b: const TalkOptions(extendBuffer: Duration(seconds: 10)),
        );
        final held = <TalkMessage>[];
        serve(p.b, held.add);
        p.a.request('A', Uint8List(0)).ignore();
        async.flushMicrotasks();
        final m = held.single;
        m.extend(deadline: sec * 60, renew: sec * 20);
        m.extend(renew: sec * 20, buffer: Duration.zero);
        m.extend(deadline: Duration.zero, buffer: Duration.zero);
        m.extend();
        async.flushMicrotasks();
        expect(p.bToA.map((f) => f.extension), [
          (deadline: sec * 70, renew: sec * 30),
          (deadline: null, renew: sec * 20),
          (deadline: ms1, renew: null),
          (deadline: null, renew: null),
        ]);
        expect(p.bToA.last.payload, isEmpty);
        p.close();
        async.flushMicrotasks();
      });
    });

    test('a value beyond the EXTEND field is lowered on both sides, the '
        'buffer kept', () {
      fakeAsync((async) {
        const day = Duration(days: 1);
        const max = Duration(milliseconds: TalkFrame.maxExtendMillis);
        final p = Pair(
          a: const TalkOptions(
            requestTimeout: Duration(days: 100),
            maxExtension: Duration.zero,
          ),
          b: const TalkOptions(
            replyTimeout: Duration(days: 100),
            extendBuffer: Duration(days: 20),
          ),
        );
        final held = <String, TalkMessage>{};
        serve(p.b, (m) => held[m.procedureName] = m);
        final deadline = Outcome(p.a.request('DEADLINE', Uint8List(0)));
        final renew = Outcome(p.a.request('RENEW', Uint8List(0)));
        async.flushMicrotasks();
        held['DEADLINE']!.extend(deadline: day * 60);
        held['RENEW']!.extend(renew: day * 60);
        async.flushMicrotasks();
        expect(p.bToA.map((f) => f.extension), [
          (deadline: max, renew: null),
          (deadline: null, renew: max),
        ]);
        // The responder still gives up the buffer before the requester.
        async.elapse(max - day * 20 - ms1);
        expect(held.values.map((m) => m.canReply), everyElement(isTrue));
        async.elapse(ms1);
        expect(held.values.map((m) => m.canReply), everyElement(isFalse));
        async.flushMicrotasks();
        for (final outcome in [deadline, renew]) {
          expect(
            outcome.error,
            isA<TalkAbortException>().having(
              (e) => e.code,
              'code',
              StatusCode.deadlineExceeded,
            ),
          );
        }
        p.close();
        async.flushMicrotasks();
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('the responder timeout follows its own declaration: items renew, '
        'the default gap is gone', () {
      fakeAsync((async) {
        final p = Pair();
        final held = <TalkMessage>[];
        serve(p.b, held.add);
        final s = p.a.streamRequest('S', Uint8List(0));
        final done = Outcome(s.done);
        s.items.listen(null);
        async.flushMicrotasks();
        final m = held.single;
        m.extend(deadline: sec * 30, renew: sec * 20);
        async.elapse(sec * 25);
        m.replyItem(bytes([1]));
        // Responder: max(30, 25 + 20) = 45 s; the requester waits until
        // max(35, 25 + 25) = 50 s.
        async.elapse(sec * 20 - ms1);
        expect(done.isDone, isFalse);
        expect(m.canReply, isTrue);
        async.elapse(ms1);
        expect(m.canReply, isFalse);
        async.flushMicrotasks();
        expect(done.error, isA<TalkAbortException>());
        p.close();
        async.flushMicrotasks();
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('on the responder, an empty extend restarts the gap and '
        'setReplyTimeout goes back to the default regime', () {
      fakeAsync((async) {
        final p = Pair(a: const TalkOptions(requestTimeout: Duration.zero));
        final held = <String, TalkMessage>{};
        serve(p.b, (m) => held[m.procedureName] = m);
        p.a.request('GAP', Uint8List(0)).ignore();
        p.a.request('RESET', Uint8List(0)).ignore();
        p.a.request('NONE', Uint8List(0)).ignore();
        async.flushMicrotasks();
        final gap = held['GAP']!;
        final reset = held['RESET']!;
        final none = held['NONE']!;
        none.setReplyTimeout(Duration.zero);
        for (final m in [gap, reset, none]) {
          m.extend(deadline: sec * 30);
        }
        async.elapse(sec * 25);
        gap.extend();
        reset.setReplyTimeout(sec * 2);
        // GAP: max(30, 25 + 10) = 35 s; RESET: 27 s; NONE: never.
        async.elapse(sec * 2 - ms1);
        expect(reset.canReply, isTrue);
        async.elapse(ms1);
        expect(reset.canReply, isFalse);
        async.elapse(sec * 8 - ms1);
        expect(gap.canReply, isTrue);
        async.elapse(ms1);
        expect(gap.canReply, isFalse);
        async.elapse(const Duration(hours: 1));
        expect(none.canReply, isTrue);
        none.reply(Uint8List(0));
        p.close();
        async.flushMicrotasks();
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('extend refuses negative values and sends nothing', () async {
      final p = Pair();
      final held = <TalkMessage>[];
      serve(p.b, held.add);
      p.a.request('A', Uint8List(0)).ignore();
      await pumpEventQueue();
      final m = held.single;
      expect(() => m.extend(deadline: -sec), throwsArgumentError);
      expect(() => m.extend(renew: -sec), throwsArgumentError);
      expect(() => m.extend(buffer: -sec), throwsArgumentError);
      await pumpEventQueue();
      expect(p.bToA, isEmpty);
      await p.close();
    });
  });

  group('responder timeout override', () {
    test('setReplyTimeout applies at once and to later restarts', () {
      fakeAsync((async) {
        final p = Pair(
          a: const TalkOptions(requestTimeout: Duration.zero),
          b: const TalkOptions(replyTimeout: ms30),
        );
        final held = <String, TalkMessage>{};
        serve(p.b, (m) {
          held[m.procedureName] = m;
          switch (m.procedureName) {
            case 'LONGER':
              m.setReplyTimeout(const Duration(milliseconds: 100));
            case 'NONE':
              m.setReplyTimeout(Duration.zero);
            case 'BACK':
              m.setReplyTimeout(Duration.zero);
          }
        });
        final longer = Outcome(p.a.request('LONGER', Uint8List(0)));
        final none = Outcome(p.a.request('NONE', Uint8List(0)));
        final back = Outcome(p.a.request('BACK', Uint8List(0)));
        final normal = Outcome(p.a.request('NORMAL', Uint8List(0)));
        async.elapse(const Duration(milliseconds: 20));
        held['BACK']!.setReplyTimeout(null);
        async.elapse(const Duration(milliseconds: 11));
        expect(normal.error, isStatus(StatusCode.deadlineExceeded));
        expect(longer.isDone, isFalse);
        expect(back.isDone, isFalse, reason: 'restarted at 20 ms');
        async.elapse(const Duration(milliseconds: 20));
        expect(back.error, isStatus(StatusCode.deadlineExceeded));
        held['LONGER']!.extend();
        async.elapse(const Duration(milliseconds: 99));
        expect(longer.isDone, isFalse, reason: 'extend restarts 100 ms');
        async.elapse(const Duration(milliseconds: 2));
        expect(longer.error, isStatus(StatusCode.deadlineExceeded));
        async.elapse(const Duration(hours: 1));
        expect(none.isDone, isFalse);
        held['NONE']!.reply(bytes([1]));
        async.flushMicrotasks();
        expect(none.value!.payload, [1]);
        held['NONE']!.setReplyTimeout(ms30);
        p.close();
        async.flushMicrotasks();
        expect(async.pendingTimers, isEmpty);
      });
    });
  });

  group('synchronous transport', () {
    test('a response sent while the request is being sent is not '
        'lost', () async {
      final c = StreamChannelController<Uint8List>(sync: true);
      final talk = TalkChannel(c.local);
      c.foreign.stream.listen((data) {
        final frame = TalkFrame.decode(data);
        if (frame.hasRequest && frame.kind == TalkKind.message) {
          c.foreign.sink.add(
            TalkFrame(
              kind: TalkKind.message,
              responseId: frame.requestId,
              payload: bytes([42]),
            ).encode(),
          );
        }
      });
      final r = await talk.request('X', Uint8List(0), timeout: Duration.zero);
      expect(r.payload, [42]);
      expect(talk.outgoingRequestCount, 0);
      await talk.close();
    });

    test('a synchronous rejection reaches the request', () async {
      final c = StreamChannelController<Uint8List>(sync: true);
      final a = TalkChannel(c.local);
      final b = TalkChannel(
        c.foreign,
        options: const TalkOptions(maxIncomingRequests: 1),
      );
      final held = <TalkMessage>[];
      b.messages.listen(held.add);
      final first = a.request('A', Uint8List(0), timeout: Duration.zero);
      final second = a.request('B', Uint8List(0), timeout: Duration.zero);
      await expectLater(second, throwsStatus(StatusCode.resourceExhausted));
      await pumpEventQueue();
      held.single.reply(Uint8List(0));
      await first;
      expect(a.outgoingRequestCount, 0);
      await a.close();
      await b.close();
    });

    test('a failed send leaves no request behind', () async {
      final c = StreamChannelController<Uint8List>();
      final talk = TalkChannel(
        StreamChannel<Uint8List>(
          c.local.stream,
          _LimitedSink(c.local.sink, 64),
        ),
      );
      final held = <TalkMessage>[];
      serve(talk, held.add);
      expect(
        () => talk.request('BIG', Uint8List(100)),
        throwsStatus(StatusCode.frameTooLarge),
      );
      expect(talk.outgoingRequestCount, 0);
      // A chained reply that cannot be sent leaves the message answerable.
      c.foreign.sink.add(
        TalkFrame(
          kind: TalkKind.message,
          procedure: Name('Q'),
          requestId: 1,
        ).encode(),
      );
      await pumpEventQueue();
      expect(
        () => held.single.replyRequest(Uint8List(100)),
        throwsStatus(StatusCode.frameTooLarge),
      );
      expect(talk.outgoingRequestCount, 0);
      expect(held.single.canReply, isTrue);
      held.single.reply(Uint8List(0));
      await talk.close();
    });

    // A cancel handled inside the send of a reply is handled once the send
    // returns: after a final reply it is ignored (the request is answered),
    // after anything else it is answered ABORT CANCELLED as usual. Either
    // way the request gets exactly one final response.

    bool isFinal(TalkFrame f) =>
        f.responseId == 1 &&
        (f.kind == TalkKind.message || f.kind == TalkKind.abort);

    /// Ends the test: no timer may be left, before or after the close.
    void finish(FakeAsync async, SyncResponder r) {
      expect(async.pendingTimers, isEmpty);
      r.talk.close();
      async.flushMicrotasks();
      expect(async.pendingTimers, isEmpty);
    }

    TalkFrame cancelled(int id) => TalkFrame(
      kind: TalkKind.abort,
      responseId: id,
      payload: Status.of(StatusCode.cancelled).encode(),
    );

    test('a cancel during the final reply gets no second final', () {
      fakeAsync((async) {
        final r = SyncResponder();
        async.flushMicrotasks();
        r.cancelDuring(isFinal);
        r.request.reply(bytes([1]));
        async.flushMicrotasks();
        expect(r.finals, [
          TalkFrame(kind: TalkKind.message, responseId: 1, payload: bytes([1])),
        ]);
        expect(r.request.canReply, isFalse);
        expect(r.request.isCancelled, isFalse, reason: 'answered first');
        expect(r.talk.incomingRequestCount, 0);
        finish(async, r);
      });
    });

    test('a cancel during replyAbort keeps the application status', () {
      fakeAsync((async) {
        final r = SyncResponder();
        async.flushMicrotasks();
        r.cancelDuring(isFinal);
        r.request.replyAbort(const Status(300, 'mine'));
        async.flushMicrotasks();
        expect(r.finals, hasLength(1));
        expect(r.finals.single.kind, TalkKind.abort);
        expect(r.finals.single.status, const Status(300, 'mine'));
        expect(r.talk.incomingRequestCount, 0);
        finish(async, r);
      });
    });

    test('a cancel during an automatic timeout abort gets no second final', () {
      fakeAsync((async) {
        final r = SyncResponder();
        async.flushMicrotasks();
        r.cancelDuring(isFinal);
        async.elapse(const Duration(seconds: 10));
        async.flushMicrotasks();
        expect(r.finals, hasLength(1));
        expect(r.finals.single.status.known, StatusCode.deadlineExceeded);
        expect(r.request.canReply, isFalse);
        expect(r.request.isCancelled, isTrue);
        expect(r.talk.incomingRequestCount, 0);
        finish(async, r);
      });
    });

    test('a cancel during a chained reply leaves the chained request as '
        'the final', () {
      fakeAsync((async) {
        final r = SyncResponder();
        async.flushMicrotasks();
        r.cancelDuring(isFinal);
        final chained = r.request.startReplyRequest(
          bytes([2]),
          timeout: Duration.zero,
        );
        final answer = Outcome(chained.response);
        async.flushMicrotasks();
        expect(r.finals, hasLength(1));
        expect(r.finals.single.requestId, chained.requestId);
        expect(r.talk.incomingRequestCount, 0);
        expect(r.talk.outgoingRequestCount, 1);
        // The peer answers the chained final of what it cancelled.
        r.send(cancelled(chained.requestId));
        async.flushMicrotasks();
        expect(answer.error, isA<TalkAbortException>());
        expect(r.talk.outgoingRequestCount, 0);
        finish(async, r);
      });
    });

    test('a cancel during a final that fails to send is answered', () {
      fakeAsync((async) {
        final r = SyncResponder();
        async.flushMicrotasks();
        r.cancelDuring(isFinal, refuse: true);
        expect(
          () => r.request.reply(bytes([1])),
          throwsStatus(StatusCode.frameTooLarge),
        );
        async.flushMicrotasks();
        expect(r.finals, hasLength(1));
        expect(r.finals.single.status.known, StatusCode.cancelled);
        expect(r.request.isCancelled, isTrue);
        expect(r.request.canReply, isFalse);
        expect(r.talk.incomingRequestCount, 0);
        finish(async, r);
      });
    });

    test('a cancel during a stream item is answered after it', () {
      fakeAsync((async) {
        final r = SyncResponder(stream: true);
        async.flushMicrotasks();
        r.cancelDuring((f) => f.kind == TalkKind.streamItem);
        r.request.replyItem(bytes([1]));
        async.flushMicrotasks();
        expect(r.sent.map((f) => f.kind), [
          TalkKind.streamItem,
          TalkKind.abort,
        ]);
        expect(r.finals.single.status.known, StatusCode.cancelled);
        expect(r.request.isCancelled, isTrue);
        expect(r.talk.incomingRequestCount, 0);
        finish(async, r);
      });
    });

    test('a cancel during an item request is answered after it', () {
      fakeAsync((async) {
        final r = SyncResponder(stream: true);
        async.flushMicrotasks();
        r.cancelDuring((f) => f.kind == TalkKind.streamItem);
        final item = r.request.startReplyItemRequest(
          bytes([1]),
          timeout: Duration.zero,
        );
        final answer = Outcome(item.response);
        async.flushMicrotasks();
        expect(r.sent.map((f) => (f.kind, f.requestId)), [
          (TalkKind.streamItem, item.requestId),
          (TalkKind.abort, 0),
        ]);
        expect(r.finals.single.status.known, StatusCode.cancelled);
        expect(r.talk.incomingRequestCount, 0);
        r.send(cancelled(item.requestId));
        async.flushMicrotasks();
        expect(answer.error, isA<TalkAbortException>());
        finish(async, r);
      });
    });

    test('a cancel during EXTEND is answered after it', () {
      fakeAsync((async) {
        final r = SyncResponder();
        async.flushMicrotasks();
        r.cancelDuring((f) => f.kind == TalkKind.extend);
        r.request.extend(deadline: const Duration(minutes: 1));
        async.flushMicrotasks();
        expect(r.sent.map((f) => f.kind), [TalkKind.extend, TalkKind.abort]);
        expect(r.finals.single.status.known, StatusCode.cancelled);
        expect(r.talk.incomingRequestCount, 0);
        finish(async, r);
      });
    });
  });

  group('ordered answers', () {
    /// A channel whose peer is driven by hand over a synchronous link: a
    /// burst of frames is decoded in one go, as the mux delivers them.
    (TalkChannel, StreamSink<Uint8List>) syncLink() {
      final c = StreamChannelController<Uint8List>(sync: true);
      c.foreign.stream.listen((_) {});
      return (TalkChannel(c.local), c.foreign.sink);
    }

    Uint8List plain(String procedure) =>
        TalkFrame(kind: TalkKind.message, procedure: Name(procedure)).encode();

    Uint8List answer(int id) =>
        TalkFrame(kind: TalkKind.message, responseId: id).encode();

    test('the answer comes after the messages sent before it, and code '
        'waiting on it runs before the messages sent after it', () async {
      final (talk, peer) = syncLink();
      final seen = <String>[];
      talk.messages.listen((m) => seen.add(m.procedureName));
      Future<void> awaiting() async {
        await talk.request('Q', Uint8List(0), ordered: true);
        seen.add('awaited');
      }

      final ordered = awaiting();
      final unordered = talk
          .request('P', Uint8List(0))
          .then((_) => seen.add('unordered'));
      for (final frame in [
        plain('M1'),
        plain('M2'),
        plain('M3'),
        answer(1),
        plain('M4'),
        plain('M5'),
        answer(2),
      ]) {
        peer.add(frame);
      }
      await Future.wait([ordered, unordered]);
      await pumpEventQueue();
      expect(seen.where((s) => s != 'unordered'), [
        'M1',
        'M2',
        'M3',
        'awaited',
        'M4',
        'M5',
      ]);
      // Without the option the answer overtakes messages sent before it.
      expect(seen.indexOf('unordered'), lessThan(seen.indexOf('M5')));
      expect(talk.outgoingRequestCount, 0);
      await talk.close();
    });

    test('an abort answer is ordered too', () async {
      final (talk, peer) = syncLink();
      final seen = <String>[];
      talk.messages.listen((m) => seen.add(m.procedureName));
      final failed = talk
          .request('Q', Uint8List(0), ordered: true)
          .then<void>(
            (_) => fail('no abort'),
            onError: (Object e) =>
                seen.add('aborted ${(e as SwitchboardException).code}'),
          );
      peer
        ..add(plain('M1'))
        ..add(plain('M2'))
        ..add(
          TalkFrame(
            kind: TalkKind.abort,
            responseId: 1,
            payload: Status.of(StatusCode.notFound).encode(),
          ).encode(),
        )
        ..add(plain('M3'));
      await failed;
      await pumpEventQueue();
      expect(seen, ['M1', 'M2', 'aborted ${StatusCode.notFound}', 'M3']);
      await talk.close();
    });

    test('without a listener the answer is delivered at once', () async {
      final (talk, peer) = syncLink();
      final response = talk.request('Q', Uint8List(0), ordered: true);
      peer
        ..add(plain('M1'))
        ..add(answer(1));
      await response;
      // The message stays buffered for a later listener.
      expect(
        (await talk.messages.first.timeout(ms30 * 10)).procedureName,
        'M1',
      );
      await talk.close();
    });

    test('a paused listener holds the answer; resuming or cancelling '
        'delivers it', () async {
      final (talk, peer) = syncLink();
      final seen = <String>[];
      final sub = talk.messages.listen((m) => seen.add(m.procedureName));
      sub.pause();
      var done = false;
      final response = talk
          .request('Q', Uint8List(0), ordered: true)
          .then((_) => done = true);
      peer
        ..add(plain('M1'))
        ..add(answer(1));
      await pumpEventQueue();
      expect(done, isFalse);
      // Local failures do not wait.
      final late = talk.request(
        'T',
        Uint8List(0),
        timeout: ms30,
        ordered: true,
      );
      await expectLater(late, throwsStatus(StatusCode.deadlineExceeded));
      sub.resume();
      await response;
      expect(seen, ['M1']);

      // A cancelled subscription releases the answers it held.
      sub.pause();
      done = false;
      final second = talk
          .request('Q', Uint8List(0), ordered: true)
          .then((_) => done = true);
      peer
        ..add(plain('M2'))
        ..add(answer(3));
      await pumpEventQueue();
      expect(done, isFalse);
      await sub.cancel();
      await second;
      expect(seen, ['M1']);
      // Answers arriving afterwards are delivered at once.
      final third = talk.request('Q', Uint8List(0), ordered: true);
      peer.add(answer(4));
      await third;
      await talk.close();
    });

    for (final end in [
      'a channel abort',
      'a protocol error',
      'close',
      'the peer closing',
    ]) {
      test('an answer that arrived before $end keeps its place', () async {
        final (talk, peer) = syncLink();
        final seen = <String>[];
        talk.messages.listen(
          (m) => seen.add(m.procedureName),
          onError: (Object e) => seen.add('error'),
        );
        final response = talk
            .request('Q', Uint8List(0), ordered: true)
            .then((_) => seen.add('answer'));
        peer
          ..add(plain('M1'))
          ..add(plain('M2'))
          ..add(answer(1));
        switch (end) {
          case 'a channel abort':
            peer.add(
              TalkFrame(
                kind: TalkKind.abort,
                payload: Status.of(StatusCode.unavailable).encode(),
              ).encode(),
            );
          case 'a protocol error':
            peer.add(bytes([0xC0]));
          case 'close':
            unawaited(talk.close());
          default:
            unawaited(peer.close());
        }
        await response;
        await talk.done;
        await pumpEventQueue();
        expect(seen, [
          'M1',
          'M2',
          'answer',
          if (end == 'a channel abort') 'error',
        ]);
      });
    }

    for (final abort in [false, true]) {
      test('a paused listener holds an ${abort ? 'abort' : 'answer'} that '
          'arrived before the channel ended; resuming or cancelling '
          'delivers it', () {
        fakeAsync((async) {
          for (final resume in [true, false]) {
            final (talk, peer) = syncLink();
            final seen = <String>[];
            final sub = talk.messages.listen((m) => seen.add(m.procedureName))
              ..pause();
            final response = Outcome(
              talk
                  .request('Q', Uint8List(0), ordered: true)
                  .whenComplete(() => seen.add('answer')),
            );
            peer
              ..add(plain('M1'))
              ..add(
                abort
                    ? TalkFrame(
                        kind: TalkKind.abort,
                        responseId: 1,
                        payload: Status.of(StatusCode.notFound).encode(),
                      ).encode()
                    : answer(1),
              );
            async.flushMicrotasks();
            expect(talk.outgoingRequestCount, 0);
            final closed = Outcome(
              talk.close(Status.of(StatusCode.unavailable)),
            );
            async.flushMicrotasks();
            expect(closed.isDone, isTrue);
            expect(response.isDone, isFalse);
            if (resume) {
              sub.resume();
              async.flushMicrotasks();
              expect(seen, ['M1', 'answer']);
            } else {
              sub.cancel();
              async.flushMicrotasks();
              expect(seen, ['answer']);
            }
            expect(response.isDone, isTrue);
            if (abort) {
              expect(response.error, isA<TalkAbortException>());
              expect(response.error, isStatus(StatusCode.notFound));
            } else {
              expect(response.error, isNull);
              expect(response.value!.responseId, 1);
            }
            sub.cancel();
            async.flushMicrotasks();
            expect(async.pendingTimers, isEmpty);
          }
        });
      });
    }
  });

  group('subscriptions', () {
    test('leaving await for early cancels the stream request', () async {
      final p = Pair();
      final cancelled = Completer<void>();
      serve(p.b, (m) {
        m.replyItem(bytes([1]));
        m.replyItem(bytes([2]));
        m.replyItem(bytes([3]));
        m.onCancel.then(cancelled.complete);
      });
      final s = p.a.streamRequest('WATCH', Uint8List(0));
      await for (final item in s.items) {
        if (item.payload.single == 2) {
          break;
        }
      }
      await cancelled.future;
      await pumpEventQueue();
      final cancel = p.aToB.last;
      expect(cancel.kind, TalkKind.abort);
      expect(cancel.requestId, s.requestId);
      expect(cancel.status.known, StatusCode.cancelled);
      expect(p.bToA.last.kind, TalkKind.abort);
      expect(p.bToA.last.responseId, s.requestId);
      await expectLater(s.done, throwsStatus(StatusCode.cancelled));
      expect(p.a.outgoingRequestCount, 0);
      expect(p.b.incomingRequestCount, 0);
      await p.close();
    });

    test('messages.first: buffered requests never delivered get '
        'UNIMPLEMENTED', () async {
      final peer = RawPeer(
        options: const TalkOptions(replyTimeout: Duration.zero),
      );
      for (final (id, name) in [(1, 'A'), (2, 'B'), (3, 'C')]) {
        peer.send(
          TalkFrame(
            kind: TalkKind.message,
            procedure: Name(name),
            requestId: id,
          ),
        );
      }
      peer.send(TalkFrame(kind: TalkKind.message, procedure: Name('NOTE')));
      await pumpEventQueue();
      final first = await peer.talk.messages.first;
      expect(first.procedureName, 'A');
      first.reply(Uint8List(0));
      await pumpEventQueue();
      final answers = {
        for (final f in peer.received)
          f.responseId: f.kind == TalkKind.abort ? f.status.known : null,
      };
      expect(answers, {
        1: null,
        2: StatusCode.unimplemented,
        3: StatusCode.unimplemented,
      });
      expect(peer.talk.incomingRequestCount, 0);
      await peer.talk.close();
    });

    test('items.first: buffered item requests never delivered get '
        'CANCELLED', () async {
      final peer = RawPeer(
        options: const TalkOptions(replyTimeout: Duration.zero),
      );
      final s = peer.talk.streamRequest('S', Uint8List(0));
      await pumpEventQueue();
      for (final id in [5, 6]) {
        peer.send(
          TalkFrame(
            kind: TalkKind.streamItem,
            requestId: id,
            responseId: s.requestId,
          ),
        );
      }
      await pumpEventQueue();
      final first = await s.items.first;
      expect(first.requestId, 5);
      await pumpEventQueue();
      final refused = peer.received.firstWhere((f) => f.responseId == 6);
      expect(refused.status.known, StatusCode.cancelled);
      final cancel = peer.received.firstWhere((f) => f.hasRequest);
      expect(cancel.requestId, s.requestId);
      expect(first.canReply, isTrue, reason: 'delivered items stay usable');
      first.reply(Uint8List(0));
      expect(peer.talk.incomingRequestCount, 0);
      peer.send(
        TalkFrame(
          kind: TalkKind.abort,
          responseId: s.requestId,
          payload: Status.of(StatusCode.cancelled).encode(),
        ),
      );
      await pumpEventQueue();
      expect(peer.talk.outgoingRequestCount, 0);
      await peer.talk.close();
    });

    test('items subscription cancelled, then an item request gets '
        'ABORT CANCELLED', () async {
      final peer = RawPeer();
      final s = peer.talk.streamRequest('S', Uint8List(0));
      final subscription = s.items.listen((_) {});
      await subscription.cancel();
      await pumpEventQueue();
      expect(peer.received.last.kind, TalkKind.abort);
      expect(peer.received.last.requestId, s.requestId);
      peer.send(
        TalkFrame(
          kind: TalkKind.streamItem,
          requestId: 7,
          responseId: s.requestId,
        ),
      );
      await pumpEventQueue();
      expect(peer.received.last.responseId, 7);
      expect(peer.received.last.status.known, StatusCode.cancelled);
      expect(peer.talk.incomingRequestCount, 0);
      await peer.talk.close();
    });

    test('a STREAM_ITEM with HAS_REQUEST to a cancelled stream gets '
        'ABORT CANCELLED', () async {
      final peer = RawPeer();
      final s = peer.talk.streamRequest('S', Uint8List(0));
      final items = <TalkMessage>[];
      s.items.listen(items.add, onError: (Object _) {});
      s.cancel();
      await pumpEventQueue();
      peer.send(TalkFrame(kind: TalkKind.streamItem, responseId: s.requestId));
      peer.send(
        TalkFrame(
          kind: TalkKind.streamItem,
          requestId: 8,
          responseId: s.requestId,
          stream: true,
        ),
      );
      await pumpEventQueue();
      expect(items, isEmpty);
      expect(peer.received, hasLength(3));
      expect(peer.received.last.responseId, 8);
      expect(peer.received.last.status.known, StatusCode.cancelled);
      expect(peer.talk.isOpen, isTrue);
      await peer.talk.close();
    });
  });

  group('chained and item requests', () {
    test('the responder timeout applies to chained and item requests', () {
      fakeAsync((async) {
        final p = Pair(a: const TalkOptions(replyTimeout: ms30));
        final results = <String, Outcome<TalkMessage>>{};
        serve(p.b, (m) {
          if (m.procedureName == 'CHAIN') {
            results['chain'] = Outcome(m.replyRequest(Uint8List(0)));
          } else {
            results['item'] = Outcome(m.replyItemRequest(Uint8List(0)));
          }
        });
        final chained = Outcome(p.a.request('CHAIN', Uint8List(0)));
        final s = p.a.streamRequest('ITEMS', Uint8List(0));
        final items = <TalkMessage>[];
        s.items.listen(items.add);
        async.elapse(const Duration(milliseconds: 29));
        expect(chained.value!.expectsReply, isTrue);
        expect(items.single.expectsReply, isTrue);
        expect(results['chain']!.isDone, isFalse);
        async.elapse(const Duration(milliseconds: 2));
        for (final key in ['chain', 'item']) {
          expect(
            results[key]!.error,
            isA<TalkAbortException>().having(
              (e) => e.code,
              'code',
              StatusCode.deadlineExceeded,
            ),
          );
        }
        expect(chained.value!.isCancelled, isTrue);
        expect(items.single.canReply, isFalse);
        expect(p.a.incomingRequestCount, 0);
        p.close();
        async.flushMicrotasks();
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('maxIncomingRequests applies to chained and item requests', () async {
      final p = Pair(a: const TalkOptions(maxIncomingRequests: 1));
      final itemResults = <Future<TalkMessage>>[];
      serve(p.b, (m) {
        if (m.procedureName == 'CHAIN') {
          itemResults.add(m.replyRequest(Uint8List(0)));
        } else {
          itemResults.add(m.replyItemRequest(bytes([1])));
          itemResults.add(m.replyItemRequest(bytes([2])));
        }
      });
      final s = p.a.streamRequest('ITEMS', Uint8List(0));
      final items = <TalkMessage>[];
      s.items.listen(items.add);
      await pumpEventQueue();
      expect(items, hasLength(2));
      expect(items[0].canReply, isTrue);
      expect(items[1].expectsReply, isTrue);
      expect(items[1].canReply, isFalse, reason: 'refused by the limit');
      await expectLater(
        itemResults[1],
        throwsStatus(StatusCode.resourceExhausted),
      );
      // A chained final is refused the same way, but still completes the
      // request.
      final chained = await p.a.request('CHAIN', Uint8List(0));
      expect(chained.expectsReply, isTrue);
      expect(chained.canReply, isFalse);
      await expectLater(
        itemResults[2],
        throwsStatus(StatusCode.resourceExhausted),
      );
      items[0].reply(Uint8List(0));
      expect((await itemResults[0]).expectsReply, isFalse);
      await p.close();
    });
  });

  group('channel end races and protocol errors', () {
    test('close after the raw stream ended uses the end status', () async {
      final peer = RawPeer(mux: true);
      final pending = peer.talk.request('X', Uint8List(0));
      await pumpEventQueue();
      peer.raw.sink.close().ignore();
      await pumpEventQueue();
      final closing = peer.talk.close(Status.of(StatusCode.internal));
      peer.mux!.completeDone(Status.of(StatusCode.goingAway));
      await expectLater(pending, throwsStatus(StatusCode.goingAway));
      await closing;
      expect((await peer.talk.done).known, StatusCode.goingAway);
      expect(peer.mux!.closedWith, isEmpty, reason: 'nothing to close');
    });

    test('a one-byte abort payload closes the channel with '
        'PROTOCOL_ERROR', () async {
      final peer = RawPeer(mux: true);
      final pending = peer.talk.request('X', Uint8List(0));
      await pumpEventQueue();
      peer.sendHex('24 01 00 00 05');
      await expectLater(pending, throwsStatus(StatusCode.protocolError));
      expect((await peer.talk.done).known, StatusCode.protocolError);
      expect(peer.mux!.closedWith.single.known, StatusCode.protocolError);
    });

    test('a request without procedure closes the channel with '
        'PROTOCOL_ERROR', () async {
      final peer = RawPeer(mux: true);
      final messages = <TalkMessage>[];
      serve(peer.talk, messages.add);
      peer.sendHex('02 01 00 00');
      expect((await peer.talk.done).known, StatusCode.protocolError);
      expect(messages, isEmpty);
      expect(peer.mux!.closedWith.single.known, StatusCode.protocolError);
    });
  });

  group('generated stub conveniences', () {
    // Not valid UTF-8: a string cannot stand for these names.
    final odd = Name.fromBytes([0xFF, 0x41, 0, 0, 0, 0, 0, 0]);
    final other = Name.fromBytes([0x80, 0, 0, 0, 0, 0, 0, 0]);
    const ignored = 'not used: longer than eight bytes';

    test('a Name takes precedence over the procedure string', () async {
      final p = Pair();
      final seen = <Name>[];
      serve(p.b, (m) async {
        seen.add(m.procedure);
        if (!m.expectsReply) {
          return;
        }
        if (m.expectsStream) {
          m.replyItem(bytes([1]), procedure: ignored, name: other);
          final answer = await m.replyItemRequest(
            bytes([2]),
            procedure: ignored,
            name: other,
          );
          m.reply(answer.payload, procedure: ignored, name: odd);
        } else {
          final back = await m.replyRequest(
            bytes([3]),
            procedure: ignored,
            name: other,
          );
          expect(back.payload, [4]);
        }
      });
      p.a.send(ignored, bytes([0]), name: odd);
      final chained = await p.a.request(ignored, bytes([0]), name: odd);
      expect(chained.procedure, other);
      chained.reply(bytes([4]));
      final stream = p.a.streamRequest(ignored, bytes([0]), name: odd);
      final items = StreamQueue(stream.items);
      final item = await items.next;
      expect(item.procedure, other);
      final asking = await items.next;
      expect(asking.procedure, other);
      asking.reply(bytes([5]));
      final end = await stream.done;
      expect(end.procedure, odd);
      expect(end.payload, [5]);
      await pumpEventQueue();
      expect(seen, [odd, odd, odd]);
      expect(
        p.aToB.where((f) => f.responseId == 0).map((f) => f.procedure),
        everyElement(odd),
      );
      // Without a name the string still applies, and is still checked.
      expect(() => p.a.send(ignored, bytes([0])), throwsArgumentError);
      await p.close();
    });

    test(
      'startRequest and the start/stream reply variants take a name too',
      () async {
        final p = Pair();
        serve(p.b, (m) {
          if (m.expectsStream) {
            m
              ..startReplyItemRequest(bytes([1]), name: other).response.ignore()
              ..replyItemStreamRequest(bytes([2]), name: other).done.ignore()
              ..replyStreamRequest(bytes([3]), name: odd).done.ignore();
          } else {
            m.startReplyRequest(bytes([4]), name: odd).response.ignore();
          }
        });
        final single = await p.a
            .startRequest(ignored, bytes([0]), name: odd)
            .response;
        expect(single.procedure, odd);
        final stream = p.a.streamRequest('S', bytes([0]));
        final items = StreamQueue(stream.items);
        expect((await items.next).procedure, other);
        expect((await items.next).procedure, other);
        expect((await stream.done).procedure, odd);
        await items.cancel();
        await p.close();
      },
    );

    test('replyStream: every item, then the trailer', () async {
      final p = Pair();
      final finished = Completer<void>();
      serve(p.b, (m) {
        if (m.procedureName == 'NONE') {
          // Without a trailer the final reply is empty.
          m.replyStream(const Stream.empty()).ignore();
          return;
        }
        finished.complete(
          m.replyStream(
            Stream.fromIterable([
              bytes([1]),
              bytes([2]),
              bytes([3]),
            ]),
            trailer: bytes([9]),
            name: odd,
          ),
        );
      });
      final stream = p.a.streamRequest('LIST', Uint8List(0));
      final items = await stream.items.toList();
      expect(items.map((m) => m.payload.single), [1, 2, 3]);
      expect(items.map((m) => m.procedure), everyElement(odd));
      final end = await stream.done;
      expect(end.payload, [9]);
      expect(end.procedure, odd);
      await finished.future;
      final empty = p.a.streamRequest('NONE', Uint8List(0));
      expect(await empty.items.toList(), isEmpty);
      expect((await empty.done).payload, isEmpty);
      await p.close();
    });

    test('replyStream: a failing source aborts the request', () async {
      for (final (error, code) in [
        (StateError('boom'), StatusCode.internal),
        (SwitchboardException.of(StatusCode.notFound), StatusCode.notFound),
        (
          TalkAbortException(Status.of(StatusCode.dataLoss)),
          StatusCode.dataLoss,
        ),
        (SwitchboardException(Status.ok), StatusCode.internal),
      ]) {
        final p = Pair();
        serve(p.b, (m) {
          unawaited(
            m.replyStream(() async* {
              yield bytes([1]);
              throw error;
            }()),
          );
        });
        final stream = p.a.streamRequest('X', Uint8List(0));
        final items = StreamQueue(stream.items);
        expect((await items.next).payload, [1]);
        await expectLater(items.next, throwsStatus(code), reason: '$error');
        await expectLater(stream.done, throwsStatus(code));
        await p.close();
      }
      final p = Pair();
      serve(p.b, (m) {
        unawaited(
          m.replyStream(
            Stream.error(SwitchboardException(const Status(300, 'app'))),
          ),
        );
      });
      await expectLater(
        p.a.streamRequest('X', Uint8List(0)).done,
        throwsA(
          isA<TalkAbortException>().having(
            (e) => e.status,
            'status',
            const Status(300, 'app'),
          ),
        ),
      );
      await p.close();
    });

    test('replyStream: a cancel stops consuming the source', () async {
      final p = Pair();
      var cancelled = false;
      final source = StreamController<Uint8List>(
        onCancel: () => cancelled = true,
      );
      final finished = Completer<void>();
      serve(p.b, (m) => finished.complete(m.replyStream(source.stream)));
      final stream = p.a.streamRequest('X', Uint8List(0));
      final items = StreamQueue(stream.items);
      source.add(bytes([1]));
      expect((await items.next).payload, [1]);
      stream.cancel();
      await finished.future.timeout(const Duration(seconds: 5));
      expect(cancelled, isTrue);
      source.add(bytes([2]));
      await pumpEventQueue();
      final sent = p.bToA.where((f) => f.kind == TalkKind.streamItem);
      expect(sent, hasLength(1));
      expect(p.bToA.last.kind, TalkKind.abort);
      expect(p.bToA.last.status.known, StatusCode.cancelled);
      await source.close();
      await p.close();
    });

    for (final sourceFails in [false, true]) {
      test(
        'replyStream: cleanup errors after ${sourceFails ? 'a source error' : 'a peer cancel'} '
        'are handled',
        () async {
          final errors = await uncaughtErrors(() async {
            final p = Pair();
            var cancellations = 0;
            final source = StreamController<Uint8List>(
              onCancel: () {
                cancellations++;
                return Future<void>.error(StateError('cleanup failed'));
              },
            );
            late Outcome<void> finished;
            serve(p.b, (m) => finished = Outcome(m.replyStream(source.stream)));
            final stream = p.a.streamRequest('X', Uint8List(0));
            final answer = Outcome(stream.done);
            stream.items.listen((_) {});
            await pumpEventQueue();
            if (sourceFails) {
              source.addError(StateError('source failed'));
            } else {
              stream.cancel();
            }
            await pumpEventQueue();
            expect(finished.isDone, isTrue);
            expect(finished.error, isNull);
            expect(cancellations, 1);
            expect(
              answer.error,
              isStatus(
                sourceFails ? StatusCode.internal : StatusCode.cancelled,
              ),
            );
            expect(p.bToA.where((f) => f.kind == TalkKind.abort), hasLength(1));
            await source.close();
            await p.close();
          });
          expect(errors, isEmpty);
        },
      );
    }

    test(
      'replyStream: the channel closing stops consuming the source',
      () async {
        final p = Pair();
        var cancelled = false;
        final source = StreamController<Uint8List>(
          onCancel: () => cancelled = true,
        );
        final finished = Completer<void>();
        serve(p.b, (m) => finished.complete(m.replyStream(source.stream)));
        final stream = p.a.streamRequest('X', Uint8List(0));
        source.add(bytes([1]));
        expect((await stream.items.first).payload, [1]);
        await p.b.close();
        await finished.future.timeout(const Duration(seconds: 5));
        expect(cancelled, isTrue);
        await source.close();
        await p.close();
      },
    );

    test(
      'replyStream throws at once when no stream answer can start',
      () async {
        final p = Pair();
        final source = StreamController<Uint8List>();
        final arrived = StreamQueue(p.b.messages);
        p.a.send('PLAIN', Uint8List(0));
        final plain = await arrived.next;
        expect(
          () => plain.replyStream(source.stream),
          throwsStatus(StatusCode.failedPrecondition),
        );
        final answer = p.a.request('ONE', Uint8List(0));
        final single = await arrived.next;
        expect(
          () => single.replyStream(source.stream),
          throwsStatus(StatusCode.failedPrecondition),
        );
        single.reply(Uint8List(0));
        await answer;
        final stream = p.a.streamRequest('MANY', Uint8List(0));
        final many = await arrived.next;
        many.reply(Uint8List(0));
        await stream.done;
        expect(
          () => many.replyStream(source.stream),
          throwsStatus(StatusCode.failedPrecondition),
        );
        expect(source.hasListener, isFalse);
        // Never listened to: its close never completes.
        unawaited(source.close());
        await arrived.cancel();
        await p.close();
      },
    );
  });
}
