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
import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:switchboard/core.dart';
import 'package:test/fake.dart';
import 'package:test/test.dart';

const Duration ms30 = Duration(milliseconds: 30);

Uint8List bytes(List<int> values) => Uint8List.fromList(values);

Matcher isStatus(StatusCode code) =>
    isA<SwitchboardException>().having((e) => e.code, 'code', code);

Matcher throwsStatus(StatusCode code) => throwsA(isStatus(code));

/// An abort that came from the peer, with [code].
Matcher isRemote(StatusCode code) =>
    isA<TalkAbortException>().having((e) => e.code, 'code', code);

/// Replies to every request on [channel] with [respond].
void serve(TalkChannel channel, void Function(TalkMessage message) respond) {
  channel.messages.listen(respond, onError: (Object _) {});
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

/// An intermediary that forwards every message between [front] (toward the
/// client) and [back] (toward the backend), both ways.
class Proxy {
  Proxy(this.front, this.back) {
    _subscriptions = [
      front.messages.listen((m) => forwards.add(forwardMessage(m, back))),
      back.messages.listen((m) => forwards.add(forwardMessage(m, front))),
    ];
  }

  final TalkChannel front;
  final TalkChannel back;
  final List<Future<void>> forwards = [];
  late final List<StreamSubscription<TalkMessage>> _subscriptions;

  Future<void> close() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await Future.wait([front.close(), back.close()]);
  }
}

/// client ↔ proxy ↔ … ↔ proxy ↔ backend over stream channel pairs.
class Chain {
  Chain({
    int proxies = 1,
    bool sync = false,
    TalkOptions client = const TalkOptions(),
    TalkOptions proxy = const TalkOptions(),
    TalkOptions backend = const TalkOptions(),
  }) {
    final first = StreamChannelController<Uint8List>(sync: sync);
    this.client = TalkChannel(first.local, options: client);
    var toward = first.foreign;
    for (var i = 0; i < proxies; i++) {
      final link = StreamChannelController<Uint8List>(sync: sync);
      this.proxies.add(
        Proxy(
          TalkChannel(toward, options: proxy),
          TalkChannel(link.local, options: proxy),
        ),
      );
      toward = link.foreign;
    }
    this.backend = TalkChannel(toward, options: backend);
  }

  late final TalkChannel client;
  late final TalkChannel backend;
  final List<Proxy> proxies = [];

  Proxy get proxy => proxies.first;

  List<TalkChannel> get channels => [
    client,
    for (final p in proxies) ...[p.front, p.back],
    backend,
  ];

  /// Waits for every forwarded exchange to end.
  Future<void> settle() async {
    await pumpEventQueue();
    for (final p in proxies) {
      await Future.wait(p.forwards);
    }
  }

  /// No request is outstanding anywhere.
  void expectIdle() {
    for (final channel in channels) {
      expect(channel.outgoingRequestCount, 0);
      expect(channel.incomingRequestCount, 0);
    }
  }

  Future<void> close() async {
    await client.close();
    for (final p in proxies) {
      await p.close();
    }
    await backend.close();
  }
}

/// A proxy between two hand driven peers, for frame level checks.
class RawProxy {
  RawProxy() {
    final toClient = StreamChannelController<Uint8List>();
    final toBackend = StreamChannelController<Uint8List>();
    proxy = Proxy(TalkChannel(toClient.local), TalkChannel(toBackend.local));
    client = toClient.foreign;
    backend = toBackend.foreign;
    client.stream.listen((data) => atClient.add(TalkFrame.decode(data)));
    backend.stream.listen((data) => atBackend.add(TalkFrame.decode(data)));
  }

  late final Proxy proxy;
  late final StreamChannel<Uint8List> client;
  late final StreamChannel<Uint8List> backend;
  final List<TalkFrame> atClient = [];
  final List<TalkFrame> atBackend = [];

  void fromClient(TalkFrame frame) => client.sink.add(frame.encode());
  void fromBackend(TalkFrame frame) => backend.sink.add(frame.encode());
}

class _ForeignMessage extends Fake implements TalkMessage {}

/// A frontend sink whose frame limit refuses a large streamed reply.
class _LimitedSink extends DelegatingStreamSink<Uint8List> {
  _LimitedSink(super.sink);

  @override
  void add(Uint8List data) {
    if (data.length > 64) {
      throw SwitchboardException.of(StatusCode.frameTooLarge);
    }
    super.add(data);
  }
}

void main() {
  for (final sync in [false, true]) {
    for (final hops in [1, 2]) {
      final label =
          '$hops ${hops == 1 ? 'proxy' : 'proxies'}'
          '${sync ? ', synchronous transport' : ''}';
      group(label, () {
        late Chain chain;
        setUp(() => chain = Chain(proxies: hops, sync: sync));
        tearDown(() => chain.close());

        test('plain messages both ways', () async {
          final atBackend = StreamQueue(chain.backend.messages);
          final atClient = StreamQueue(chain.client.messages);
          chain.client.send('HELLO', bytes([1]));
          chain.backend.send('BACK', bytes([2]));
          final m1 = await atBackend.next;
          expect(m1.procedureName, 'HELLO');
          expect(m1.payload, [1]);
          expect(m1.expectsReply, isFalse);
          final m2 = await atClient.next;
          expect(m2.procedureName, 'BACK');
          expect(m2.payload, [2]);
          await atBackend.cancel();
          await atClient.cancel();
        });

        test('request and reply, with and without procedure', () async {
          serve(chain.backend, (m) {
            if (m.procedureName == 'NAMED') {
              m.reply(bytes(m.payload.reversed.toList()), procedure: 'PONG');
            } else {
              m.reply(bytes([9]));
            }
          });
          final named = await chain.client.request('NAMED', bytes([1, 2]));
          expect(named.procedureName, 'PONG');
          expect(named.payload, [2, 1]);
          final plain = await chain.client.request('PLAIN', Uint8List(0));
          expect(plain.frame.procedure, isNull, reason: 'absent stays absent');
          expect(plain.payload, [9]);
          await chain.settle();
          chain.expectIdle();
        });

        test('requests from the backend reach the client', () async {
          serve(chain.client, (m) => m.reply(bytes([m.payload.single + 1])));
          final r = await chain.backend.request('UP', bytes([41]));
          expect(r.payload, [42]);
          await chain.settle();
          chain.expectIdle();
        });

        test('stream items and a final with trailing payload', () async {
          serve(chain.backend, (m) {
            expect(m.expectsStream, isTrue);
            m.replyItem(bytes([1]), procedure: 'ITEM');
            m.replyItem(bytes([2]));
            m.replyItem(bytes([3]));
            m.reply(bytes([0xFF]), procedure: 'END');
          });
          final s = chain.client.streamRequest('LIST', Uint8List(0));
          final items = await s.items.toList();
          expect(items.map((m) => m.payload.single), [1, 2, 3]);
          expect(items.first.procedureName, 'ITEM');
          expect(items[1].frame.procedure, isNull);
          final last = await s.done;
          expect(last.payload, [0xFF]);
          expect(last.procedureName, 'END');
          await chain.settle();
          chain.expectIdle();
        });

        test('chained replies several hops deep', () async {
          serve(chain.backend, (m1) async {
            expect(m1.procedureName, 'Q1');
            final r2 = await m1.replyRequest(bytes([2]), procedure: 'Q2');
            expect(r2.procedureName, 'Q3');
            expect(r2.expectsReply, isTrue);
            final r4 = await r2.replyRequest(bytes([4]));
            expect(r4.payload, [5]);
            final back = r4.replyStreamRequest(bytes([6]), procedure: 'S');
            final items = await back.items.toList();
            expect(items.map((i) => i.payload.single), [7, 8]);
            final end = await back.done;
            expect(end.payload, [9]);
            expect(end.expectsReply, isFalse);
          });
          final r1 = await chain.client.request('Q1', bytes([1]));
          expect(r1.payload, [2]);
          expect(r1.procedureName, 'Q2');
          expect(r1.expectsReply, isTrue);
          final r3 = await r1.replyRequest(bytes([3]), procedure: 'Q3');
          expect(r3.payload, [4]);
          expect(r3.frame.procedure, isNull);
          final r5 = await r3.replyRequest(bytes([5]));
          expect(r5.payload, [6]);
          expect(r5.procedureName, 'S');
          expect(r5.expectsStream, isTrue);
          r5.replyItem(bytes([7]));
          r5.replyItem(bytes([8]));
          r5.reply(bytes([9]));
          await chain.settle();
          chain.expectIdle();
        });

        test('item requests and item stream requests', () async {
          serve(chain.backend, (m) async {
            final answer = m.replyItemRequest(bytes([1]), procedure: 'MORE');
            final sub = m.replyItemStreamRequest(bytes([2]), procedure: 'SUB');
            final subItems = await sub.items
                .map((i) => i.payload.single)
                .toList();
            final subEnd = await sub.done;
            final a = await answer;
            m.reply(bytes([a.payload.single, ...subItems, subEnd.payload[0]]));
          });
          final s = chain.client.streamRequest('ASK', Uint8List(0));
          s.items.listen((item) {
            expect(item.expectsReply, isTrue);
            if (item.expectsStream) {
              expect(item.procedureName, 'SUB');
              item.replyItem(bytes([7]));
              item.replyItem(bytes([8]));
              item.reply(bytes([9]));
            } else {
              expect(item.procedureName, 'MORE');
              item.reply(bytes([item.payload.single * 10]));
            }
          });
          expect((await s.done).payload, [10, 7, 8, 9]);
          await chain.settle();
          chain.expectIdle();
        });

        test('an abort from the backend passes through', () async {
          serve(chain.backend, (m) {
            if (m.procedureName == 'APP') {
              m.replyAbort(const Status(300, 'app'));
            } else {
              m.replyItem(bytes([1]));
              m.replyAbort(Status.of(StatusCode.notFound, 'gone'));
            }
          });
          await expectLater(
            chain.client.request('APP', Uint8List(0)),
            throwsA(
              isA<TalkAbortException>().having(
                (e) => e.status,
                'status',
                const Status(300, 'app'),
              ),
            ),
          );
          final s = chain.client.streamRequest('S', Uint8List(0));
          final got = <int>[];
          s.items.listen((i) => got.add(i.payload.single), onError: (_) {});
          await expectLater(
            s.done,
            throwsA(
              isA<TalkAbortException>().having(
                (e) => e.status,
                'status',
                Status.of(StatusCode.notFound, 'gone'),
              ),
            ),
          );
          expect(got, [1]);
          await chain.settle();
          chain.expectIdle();
        });

        test('a client cancel reaches the backend', () async {
          final cancels = <String>[];
          final seen = StreamController<String>();
          serve(chain.backend, (m) {
            if (m.expectsStream) {
              m.replyItem(bytes([1]));
            }
            m.onCancel.then((_) {
              cancels.add(m.procedureName);
              seen.add(m.procedureName);
            });
          });
          final events = StreamQueue(seen.stream);
          final s = chain.client.streamRequest('WATCH', Uint8List(0));
          await for (final _ in s.items) {
            break;
          }
          expect(await events.next, 'WATCH');
          final r = chain.client.startRequest('ONE', Uint8List(0));
          await pumpEventQueue();
          r.cancel();
          expect(await events.next, 'ONE');
          await expectLater(r.response, throwsStatus(StatusCode.cancelled));
          await chain.settle();
          chain.expectIdle();
          await events.cancel();
          await seen.close();
        });

        test(
          'losing the client channel cancels the forwarded request',
          () async {
            final cancelled = Completer<void>();
            serve(chain.backend, (m) => m.onCancel.then(cancelled.complete));
            final pending = chain.client.request('X', Uint8List(0));
            await pumpEventQueue();
            expect(chain.backend.incomingRequestCount, 1);
            await chain.client.close();
            await expectLater(pending, throwsStatus(StatusCode.cancelled));
            await cancelled.future;
            await chain.settle();
            chain.expectIdle();
          },
        );

        test('losing the backend channel answers UNAVAILABLE', () async {
          final held = <TalkMessage>[];
          serve(chain.backend, held.add);
          final pending = expectLater(
            chain.client.request('X', Uint8List(0)),
            throwsA(isRemote(StatusCode.unavailable)),
          );
          final s = chain.client.streamRequest('S', Uint8List(0));
          final items = expectLater(
            s.items.toList(),
            throwsA(isRemote(StatusCode.unavailable)),
          );
          await pumpEventQueue();
          expect(held, hasLength(2));
          await chain.backend.close();
          await pending;
          await items;
          // The proxy cannot forward any more.
          await pumpEventQueue();
          await expectLater(
            chain.client.request('Y', Uint8List(0)),
            throwsA(isRemote(StatusCode.unavailable)),
          );
          await chain.settle();
        });

        test('a channel abort from the backend answers UNAVAILABLE', () async {
          serve(chain.backend, (_) {});
          final pending = chain.client.request('X', Uint8List(0));
          await pumpEventQueue();
          chain.backend.abort(Status.of(StatusCode.unauthenticated));
          await expectLater(pending, throwsA(isRemote(StatusCode.unavailable)));
          expect(chain.client.isOpen, isTrue);
          await chain.settle();
        });
      });
    }
  }

  group('timeouts', () {
    test('a deadline the backend declares reaches the client with the '
        "backend's buffer only, through every hop", () {
      fakeAsync((async) {
        final chain = Chain(proxies: 2);
        final held = <TalkMessage>[];
        serve(chain.backend, held.add);
        final seen = <(Duration?, Duration?)>[];
        final r = chain.client.startRequest(
          'SLOW',
          Uint8List(0),
          onExtend: (deadline, renew) => seen.add((deadline, renew)),
        );
        final result = Outcome(r.response);
        async.flushMicrotasks();
        final t0 = clock.now();
        held.single.extend(
          deadline: const Duration(minutes: 1),
          renew: const Duration(seconds: 20),
        );
        async.flushMicrotasks();
        expect(seen, [
          (const Duration(seconds: 65), const Duration(seconds: 25)),
        ]);
        expect(r.deadline, t0.add(const Duration(seconds: 65)));
        // The backend gives up at its own deadline; its abort passes the
        // proxies, which time nothing out themselves.
        async.elapse(const Duration(seconds: 60));
        expect(result.error, isRemote(StatusCode.deadlineExceeded));
        chain.close();
        async.flushMicrotasks();
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('EXTEND from the backend keeps the client waiting', () {
      fakeAsync((async) {
        final chain = Chain(
          proxies: 2,
          client: const TalkOptions(requestTimeout: ms30),
          proxy: const TalkOptions(requestTimeout: ms30, replyTimeout: ms30),
          backend: const TalkOptions(replyTimeout: ms30),
        );
        final held = <TalkMessage>[];
        serve(chain.backend, held.add);
        var extends_ = 0;
        final r = chain.client.startRequest(
          'SLOW',
          Uint8List(0),
          onExtend: (_, _) => extends_++,
        );
        final result = Outcome(r.response);
        final s = chain.client.streamRequest('TICK', Uint8List(0));
        final items = Outcome(s.items.toList());
        async.flushMicrotasks();
        for (var i = 0; i < 5; i++) {
          async.elapse(const Duration(milliseconds: 20));
          held[0].extend();
          held[1].replyItem(bytes([i]));
        }
        async.elapse(const Duration(milliseconds: 20));
        expect(result.isDone, isFalse);
        expect(items.isDone, isFalse);
        expect(extends_, 5);
        held[0].reply(bytes([1]));
        held[1].reply(Uint8List(0));
        async.flushMicrotasks();
        expect(result.value!.payload, [1]);
        expect(items.value!.map((i) => i.payload.single), [0, 1, 2, 3, 4]);
        chain.close();
        async.flushMicrotasks();
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('the proxy imposes no timeout of its own', () {
      fakeAsync((async) {
        final chain = Chain(
          client: const TalkOptions(requestTimeout: Duration(seconds: 1)),
          proxy: const TalkOptions(
            requestTimeout: Duration(milliseconds: 10),
            replyTimeout: Duration(milliseconds: 10),
          ),
          backend: const TalkOptions(replyTimeout: Duration.zero),
        );
        TalkMessage? held;
        serve(chain.backend, (m) => held = m);
        final result = Outcome(chain.client.request('SLOW', Uint8List(0)));
        async.elapse(const Duration(milliseconds: 500));
        expect(result.isDone, isFalse);
        expect(async.pendingTimers, hasLength(1), reason: 'the client only');
        held!.reply(bytes([1]));
        async.flushMicrotasks();
        expect(result.value!.payload, [1]);
        chain.close();
        async.flushMicrotasks();
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('the backend responder timeout reaches the client as '
        'DEADLINE_EXCEEDED', () {
      fakeAsync((async) {
        final chain = Chain(backend: const TalkOptions(replyTimeout: ms30));
        TalkMessage? held;
        serve(chain.backend, (m) => held = m);
        final result = Outcome(chain.client.request('SLOW', Uint8List(0)));
        async.elapse(const Duration(milliseconds: 31));
        expect(result.error, isRemote(StatusCode.deadlineExceeded));
        expect(held!.isCancelled, isTrue);
        chain.expectIdle();
        chain.close();
        async.flushMicrotasks();
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('the client timeout cancels the forwarded request', () {
      fakeAsync((async) {
        final chain = Chain(
          client: const TalkOptions(requestTimeout: ms30),
          backend: const TalkOptions(replyTimeout: Duration.zero),
        );
        TalkMessage? held;
        serve(chain.backend, (m) => held = m);
        final result = Outcome(chain.client.request('SLOW', Uint8List(0)));
        async.elapse(const Duration(milliseconds: 31));
        expect(result.error, isStatus(StatusCode.deadlineExceeded));
        expect(result.error, isNot(isA<TalkAbortException>()));
        expect(held!.isCancelled, isTrue);
        chain.expectIdle();
        chain.close();
        async.flushMicrotasks();
        expect(async.pendingTimers, isEmpty);
      });
    });
  });

  group('frame level', () {
    final odd = Name.fromBytes([0xFF, 0x41, 0, 0, 0, 0, 0, 0]);
    final odd2 = Name.fromBytes([0xC3, 0x28, 0x80, 0, 0, 0, 0, 0]);

    test('an undeliverable synchronous item cancels the forwarded request', () {
      fakeAsync((async) {
        final toClient = StreamChannelController<Uint8List>(sync: true);
        final toBackend = StreamChannelController<Uint8List>(sync: true);
        final proxy = Proxy(
          TalkChannel(
            StreamChannel(
              toClient.local.stream,
              _LimitedSink(toClient.local.sink),
            ),
          ),
          TalkChannel(toBackend.local),
        );
        final atClient = <TalkFrame>[];
        final atBackend = <TalkFrame>[];
        toClient.foreign.stream.listen(
          (d) => atClient.add(TalkFrame.decode(d)),
        );
        toBackend.foreign.stream.listen((data) {
          final frame = TalkFrame.decode(data);
          atBackend.add(frame);
          if (frame.kind == TalkKind.message) {
            // Respond inside the proxy's send, before it has the handle.
            toBackend.foreign.sink.add(
              TalkFrame(
                kind: TalkKind.streamItem,
                responseId: frame.requestId,
                payload: Uint8List(100),
              ).encode(),
            );
          } else if (frame.kind == TalkKind.abort && frame.hasRequest) {
            toBackend.foreign.sink.add(
              TalkFrame(
                kind: TalkKind.abort,
                responseId: frame.requestId,
                payload: Status.of(StatusCode.cancelled).encode(),
              ).encode(),
            );
          }
        });
        toClient.foreign.sink.add(
          TalkFrame(
            kind: TalkKind.message,
            procedure: Name('LIST'),
            requestId: 7,
            stream: true,
          ).encode(),
        );
        async.flushMicrotasks();
        expect(atClient.single.status.known, StatusCode.unavailable);
        expect(atBackend.map((f) => f.kind), [
          TalkKind.message,
          TalkKind.abort,
        ]);
        expect(proxy.front.incomingRequestCount, 0);
        expect(proxy.back.outgoingRequestCount, 0);
        final forwarded = Outcome(proxy.forwards.single);
        async.flushMicrotasks();
        expect(forwarded.isDone, isTrue);
        proxy.close();
        async.flushMicrotasks();
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('a listener that throws after forwarding cancels the forwarded '
        'request', () async {
      final toClient = StreamChannelController<Uint8List>();
      final toBackend = StreamChannelController<Uint8List>();
      final front = TalkChannel(toClient.local);
      final back = TalkChannel(toBackend.local);
      final forwards = <Future<void>>[];
      front.messages.listen((m) {
        forwards.add(forwardMessage(m, back));
        throw StateError('handler bug');
      });
      final atClient = <TalkFrame>[];
      final atBackend = <TalkFrame>[];
      toClient.foreign.stream.listen((d) => atClient.add(TalkFrame.decode(d)));
      toBackend.foreign.stream.listen((data) {
        final frame = TalkFrame.decode(data);
        atBackend.add(frame);
        if (frame.kind == TalkKind.abort && frame.hasRequest) {
          toBackend.foreign.sink.add(
            TalkFrame(
              kind: TalkKind.abort,
              responseId: frame.requestId,
              payload: Status.of(StatusCode.cancelled).encode(),
            ).encode(),
          );
        }
      });
      toClient.foreign.sink.add(
        TalkFrame(
          kind: TalkKind.message,
          procedure: Name('LIST'),
          requestId: 7,
          stream: true,
        ).encode(),
      );
      await pumpEventQueue();
      final forwarded = Outcome(forwards.single);
      await pumpEventQueue();
      expect(forwarded.isDone, isTrue, reason: 'forwarding ended');
      expect(atClient.single.kind, TalkKind.abort);
      expect(atClient.single.responseId, 7);
      expect(atClient.single.status.known, StatusCode.internal);
      expect(atBackend.map((f) => (f.kind, f.requestId)), [
        (TalkKind.message, 1),
        (TalkKind.abort, 1),
      ], reason: 'the backend is told to stop');
      expect(front.incomingRequestCount, 0);
      expect(back.outgoingRequestCount, 0);
      await Future.wait([front.close(), back.close()]);
    });

    test('non-UTF-8 procedure names pass through byte for byte', () async {
      final p = RawProxy();
      p.fromClient(
        TalkFrame(kind: TalkKind.message, procedure: odd, payload: bytes([1])),
      );
      p.fromClient(
        TalkFrame(
          kind: TalkKind.message,
          procedure: odd,
          requestId: 5,
          stream: true,
          payload: bytes([2]),
        ),
      );
      await pumpEventQueue();
      expect(p.atBackend, hasLength(2));
      expect(p.atBackend[0].procedure, odd);
      expect(hexString(p.atBackend[0].procedure!.bytes), startsWith('FF 41'));
      expect(p.atBackend[0].payload, [1]);
      final forwarded = p.atBackend[1];
      expect(forwarded.procedure, odd);
      expect(forwarded.stream, isTrue);
      expect(forwarded.payload, [2]);
      final id = forwarded.requestId;
      p.fromBackend(
        TalkFrame(
          kind: TalkKind.streamItem,
          procedure: odd2,
          responseId: id,
          payload: bytes([3]),
        ),
      );
      p.fromBackend(TalkFrame(kind: TalkKind.extend, responseId: id));
      p.fromBackend(
        TalkFrame(
          kind: TalkKind.message,
          procedure: odd2,
          responseId: id,
          payload: bytes([4]),
        ),
      );
      await pumpEventQueue();
      expect(p.atClient, [
        TalkFrame(
          kind: TalkKind.streamItem,
          procedure: odd2,
          responseId: 5,
          payload: bytes([3]),
        ),
        TalkFrame(kind: TalkKind.extend, responseId: 5),
        TalkFrame(
          kind: TalkKind.message,
          procedure: odd2,
          responseId: 5,
          payload: bytes([4]),
        ),
      ]);
      await p.proxy.close();
    });

    test('EXTEND payloads pass through byte for byte', () async {
      final p = RawProxy();
      p.fromClient(
        TalkFrame(kind: TalkKind.message, procedure: odd, requestId: 5),
      );
      await pumpEventQueue();
      final id = p.atBackend.single.requestId;
      final payloads = [
        hexBytes('A0 BB 0D 00 E0 93 04 00'),
        hexBytes('A0 BB 0D 00 00 00 00 00'),
        hexBytes('00 00 00 00 00 00 00 00'),
        Uint8List(0),
        hexBytes('01 00 00 00 FF FF FF FF'),
      ];
      for (final payload in payloads) {
        p.backend.sink.add(
          TalkFrame(
            kind: TalkKind.extend,
            responseId: id,
            payload: payload,
          ).encode(),
        );
      }
      await pumpEventQueue();
      expect(p.atClient.map((f) => (f.kind, f.responseId)), [
        for (final _ in payloads) (TalkKind.extend, 5),
      ]);
      expect(p.atClient.map((f) => hexString(f.payload)), [
        for (final payload in payloads) hexString(payload),
      ]);
      await p.proxy.close();
    });

    for (final code in [StatusCode.moved, StatusCode.relocated]) {
      test(
        '${code.name} abort fields and reason pass through byte for byte',
        () async {
          final p = RawProxy();
          p.fromClient(
            TalkFrame(
              kind: TalkKind.message,
              procedure: Name('Q'),
              requestId: 7,
            ),
          );
          await pumpEventQueue();
          // The owner bytes and malformed UTF-8 reason must survive status
          // decoding. Rebuilding the status from its reason would corrupt it.
          final payload = bytes([
            code.code,
            0,
            0xFF,
            0xEE,
            0xDD,
            0xCC,
            0xBB,
            0xAA,
            0x78,
            0x56,
            0x34,
            0x12,
            0xFF,
            0x80,
          ]);
          p.fromBackend(
            TalkFrame(
              kind: TalkKind.abort,
              responseId: p.atBackend.single.requestId,
              payload: payload,
            ),
          );
          await Future.wait(p.proxy.forwards);
          await pumpEventQueue();
          final response = p.atClient.single;
          expect(response.kind, TalkKind.abort);
          expect(response.responseId, 7);
          expect(response.payload, payload);
          expect(
            p.atBackend,
            hasLength(1),
            reason: 'neither status is retried',
          );
          expect(p.proxy.front.incomingRequestCount, 0);
          expect(p.proxy.back.outgoingRequestCount, 0);
          await p.proxy.close();
        },
      );
    }

    test('a chained request from the backend gets its own id toward the '
        'client', () async {
      final p = RawProxy();
      p.fromClient(
        TalkFrame(kind: TalkKind.message, procedure: odd, requestId: 9),
      );
      await pumpEventQueue();
      final r = p.atBackend.single.requestId;
      p.fromBackend(
        TalkFrame(
          kind: TalkKind.message,
          procedure: odd2,
          requestId: 0x123456,
          responseId: r,
        ),
      );
      await pumpEventQueue();
      final chained = p.atClient.single;
      expect(chained.responseId, 9);
      expect(chained.procedure, odd2);
      expect(chained.hasRequest, isTrue);
      p.fromClient(
        TalkFrame(
          kind: TalkKind.abort,
          responseId: chained.requestId,
          payload: const Status(999, 'no').encode(),
        ),
      );
      await pumpEventQueue();
      final answer = p.atBackend.last;
      expect(answer.kind, TalkKind.abort);
      expect(answer.responseId, 0x123456);
      expect(answer.status, const Status(999, 'no'));
      await Future.wait(p.proxy.forwards);
      await p.proxy.close();
    });

    test('a client cancel is forwarded with its status', () async {
      final p = RawProxy();
      p.fromClient(
        TalkFrame(kind: TalkKind.message, procedure: odd, requestId: 3),
      );
      await pumpEventQueue();
      final r = p.atBackend.single.requestId;
      p.fromClient(
        TalkFrame(
          kind: TalkKind.abort,
          requestId: 3,
          payload: const Status(1, 'stop').encode(),
        ),
      );
      await pumpEventQueue();
      expect(p.atClient.single.responseId, 3);
      expect(p.atClient.single.status.known, StatusCode.cancelled);
      final cancel = p.atBackend.last;
      expect(cancel.requestId, r);
      expect(cancel.hasResponse, isFalse);
      expect(cancel.status, const Status(1, 'stop'));
      expect(p.proxy.back.outgoingRequestCount, 1, reason: 'until the final');
      p.fromBackend(
        TalkFrame(
          kind: TalkKind.abort,
          responseId: r,
          payload: Status.of(StatusCode.cancelled).encode(),
        ),
      );
      await pumpEventQueue();
      expect(p.proxy.back.outgoingRequestCount, 0);
      expect(p.atClient, hasLength(1), reason: 'nothing more for the client');
      await Future.wait(p.proxy.forwards);
      await p.proxy.close();
    });

    test('a chained request refused by the proxy limit answers the client '
        'UNAVAILABLE', () async {
      final toClient = StreamChannelController<Uint8List>();
      final toBackend = StreamChannelController<Uint8List>();
      final proxy = Proxy(
        TalkChannel(toClient.local),
        TalkChannel(
          toBackend.local,
          options: const TalkOptions(maxIncomingRequests: 1),
        ),
      );
      final atClient = <TalkFrame>[];
      final atBackend = <TalkFrame>[];
      toClient.foreign.stream.listen((d) => atClient.add(TalkFrame.decode(d)));
      toBackend.foreign.stream.listen(
        (d) => atBackend.add(TalkFrame.decode(d)),
      );
      // The backend holds one request toward the client: the limit is used.
      toBackend.foreign.sink.add(
        TalkFrame(
          kind: TalkKind.message,
          procedure: Name('HOLD'),
          requestId: 1,
        ).encode(),
      );
      toClient.foreign.sink.add(
        TalkFrame(
          kind: TalkKind.message,
          procedure: Name('ASK'),
          requestId: 7,
        ).encode(),
      );
      await pumpEventQueue();
      final ask = atBackend.single;
      toBackend.foreign.sink.add(
        TalkFrame(
          kind: TalkKind.message,
          requestId: 2,
          responseId: ask.requestId,
        ).encode(),
      );
      await pumpEventQueue();
      expect(atBackend.last.responseId, 2);
      expect(atBackend.last.status.known, StatusCode.resourceExhausted);
      final answer = atClient.firstWhere((f) => f.responseId == 7);
      expect(answer.kind, TalkKind.abort);
      expect(answer.status.known, StatusCode.unavailable);
      await proxy.close();
    });

    test('a chained request the proxy cannot send toward the client '
        'answers both sides UNAVAILABLE', () async {
      final toClient = StreamChannelController<Uint8List>();
      final toBackend = StreamChannelController<Uint8List>();
      final proxy = Proxy(
        TalkChannel(
          toClient.local,
          options: const TalkOptions(maxOutgoingRequests: 1),
        ),
        TalkChannel(toBackend.local),
      );
      final atClient = <TalkFrame>[];
      final atBackend = <TalkFrame>[];
      toClient.foreign.stream.listen((d) => atClient.add(TalkFrame.decode(d)));
      toBackend.foreign.stream.listen(
        (d) => atBackend.add(TalkFrame.decode(d)),
      );
      // A request of the backend's, forwarded to the client, holds the one
      // outgoing request the proxy may have toward the client.
      toBackend.foreign.sink.add(
        TalkFrame(
          kind: TalkKind.message,
          procedure: Name('HOLD'),
          requestId: 1,
        ).encode(),
      );
      toClient.foreign.sink.add(
        TalkFrame(
          kind: TalkKind.message,
          procedure: Name('ASK'),
          requestId: 7,
        ).encode(),
      );
      await pumpEventQueue();
      expect(proxy.front.outgoingRequestCount, 1);
      final ask = atBackend.single;
      toBackend.foreign.sink.add(
        TalkFrame(
          kind: TalkKind.message,
          requestId: 2,
          responseId: ask.requestId,
        ).encode(),
      );
      await pumpEventQueue();
      // The chained request is refused toward the backend, and the request
      // it was to answer still gets its final.
      expect(atBackend.last.responseId, 2);
      expect(atBackend.last.status.known, StatusCode.unavailable);
      final answer = atClient.singleWhere((f) => f.responseId == 7);
      expect(answer.kind, TalkKind.abort);
      expect(answer.status.known, StatusCode.unavailable);
      expect(proxy.front.incomingRequestCount, 0);
      await proxy.close();
    });
  });

  group('forwardMessage', () {
    test('refuses foreign messages and double forwarding', () async {
      final chain = Chain(proxies: 0);
      expect(
        () => forwardMessage(_ForeignMessage(), chain.client),
        throwsArgumentError,
      );
      final received = Completer<TalkMessage>();
      final other = Chain(proxies: 0);
      serve(other.backend, (m) => m.reply(Uint8List(0)));
      serve(chain.backend, received.complete);
      final pending = chain.client.request('X', Uint8List(0));
      final m = await received.future;
      final forwarded = forwardMessage(m, other.client);
      expect(() => forwardMessage(m, other.client), throwsStateError);
      await forwarded;
      await pending;
      await chain.close();
      await other.close();
    });

    test('completes once nested exchanges have ended', () async {
      final chain = Chain();
      serve(chain.backend, (m) async {
        final r = await m.replyRequest(bytes([1]));
        r.reply(bytes([r.payload.single + 1]));
      });
      final r1 = await chain.client.request('Q', Uint8List(0));
      await pumpEventQueue();
      var done = false;
      unawaited(chain.proxy.forwards.single.then((_) => done = true));
      await pumpEventQueue();
      expect(done, isFalse, reason: 'the chained request is outstanding');
      final r3 = await r1.replyRequest(bytes([5]));
      expect(r3.payload, [6]);
      await pumpEventQueue();
      expect(done, isTrue);
      chain.expectIdle();
      await chain.close();
    });

    test('does nothing for a request that can no longer be answered', () async {
      final chain = Chain(proxies: 0);
      final other = Chain(proxies: 0);
      final received = Completer<TalkMessage>();
      serve(chain.backend, received.complete);
      final pending = chain.client.request('X', Uint8List(0));
      final m = await received.future;
      m.reply(Uint8List(0));
      await forwardMessage(m, other.client);
      await pending;
      expect(other.client.outgoingRequestCount, 0);
      await chain.close();
      await other.close();
    });
  });
}
