/*
Polyverse Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Authors:
  Jan Boon <jan.boon@kaetemi.be>
  Claude Opus 5.5 <noreply@anthropic.com>
*/

// Flow control (wiki page "Polyverse Switchboard Mux", section "Flow
// control"): the send window, CREDIT, the receive window and the ways
// credit is returned.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:async/async.dart';
import 'package:switchboard/src/bytes.dart';
import 'package:switchboard/src/mux/mux_channel.dart';
import 'package:switchboard/src/mux/mux_connection.dart';
import 'package:switchboard/src/mux/mux_frame.dart';
import 'package:switchboard/src/status.dart';
import 'package:switchboard/src/transport/stream_transport.dart';
import 'package:test/test.dart';

import 'mux_harness.dart';

/// A LIMITS frame announcing [window], no frame or channel limit.
String limitsHex(int window) => hexString(
  MuxControlMessage.limits(
    MuxLimits(maxFrameSize: 0, maxChannels: 0, initialWindow: window),
  ).toFrame().encode(),
);

/// A CREDIT frame for [id] of [bytes].
String creditHex(int id, int bytes) => hexString(
  MuxControlMessage.credit(MuxCredit(id, bytes)).toFrame().encode(),
);

/// A DATA frame on [id] with [length] payload bytes, as hex.
String dataHex(int id, int length) =>
    hexString(MuxFrame.data(id, Uint8List(length)).encode());

/// Sends PING and waits for its PONG: frames sent before it were handled.
Future<void> settle(RawPeer raw) async {
  raw.send('02 00 00 01 5E');
  await raw.nextControl(MuxControlType.pong);
}

void main() {
  group('send window', () {
    test(
      'a sender waits for credit, which admits subframes in order',
      () async {
        final (mux, raw) = rawPair();
        addTearDown(mux.close);
        raw.send(limitsHex(100));
        await settle(raw);
        final channel = mux.open(empty);
        expect(await raw.nextHex(), '12 02 00');
        expect(channel.sendWindow, 100);
        expect(channel.maxSubframeLength, 34);
        // Each costs its length plus 16: 50, the most a frame may cost.
        final sent = <int>[];
        for (var i = 0; i < 4; i++) {
          unawaited(
            channel.send(Uint8List(34)..[0] = i).then((_) => sent.add(i)),
          );
        }
        await pumpEventQueue();
        expect(sent, [0, 1]);
        expect(channel.sendWindow, 0);
        for (var i = 0; i < 2; i++) {
          final frame = await raw.next();
          expect(frame.command, MuxCommand.data);
          expect(frame.payload[0], i);
        }
        // Not enough for the next: nothing moves.
        raw.send(creditHex(2, 49));
        await settle(raw);
        expect(sent, [0, 1]);
        expect(channel.sendWindow, 49);
        raw.send(creditHex(2, 51));
        for (var i = 2; i < 4; i++) {
          expect((await raw.next()).payload[0], i);
        }
        await pumpEventQueue();
        expect(sent, [0, 1, 2, 3]);
        expect(channel.sendWindow, 0);
      },
    );

    test(
      'a subframe costing more than half the initial window is refused',
      () async {
        final (mux, raw) = rawPair();
        addTearDown(mux.close);
        final early = mux.open(empty);
        raw.send(limitsHex(1000));
        await settle(raw);
        final late = mux.open(empty);
        // Opened before the LIMITS arrived: 64 KiB.
        expect(early.sendWindow, 65536);
        expect(early.maxSubframeLength, 32752);
        expect(late.sendWindow, 1000);
        expect(late.maxSubframeLength, 484);
        expect(
          () => late.send(Uint8List(485)),
          throwsStatus(StatusCode.frameTooLarge),
        );
        expect(
          () => early.send(Uint8List(32753)),
          throwsStatus(StatusCode.frameTooLarge),
        );
        await late.send(Uint8List(484));
        await early.send(Uint8List(32752));
        expect(late.sendWindow, 500);
        expect(early.sendWindow, 32768);
      },
    );

    test('CREDIT beyond 2^32 - 1 is a protocol error', () async {
      final (mux, raw) = rawPair();
      raw.send(limitsHex(MuxLimits.maxWindow - 10));
      await settle(raw);
      final channel = mux.open(empty);
      raw.send(creditHex(channel.id, 10));
      await settle(raw);
      expect(channel.sendWindow, MuxLimits.maxWindow);
      raw.send(creditHex(channel.id, 1));
      final goAway = await raw.nextControl(MuxControlType.goAway);
      expect(goAway.goAwayStatus.known, StatusCode.protocolError);
      expect((await mux.done).known, StatusCode.protocolError);
    });

    test(
      'CREDIT after our CLOSE or for an unknown channel is ignored',
      () async {
        final (mux, raw) = rawPair();
        addTearDown(mux.close);
        final channel = mux.open(empty);
        await raw.next();
        unawaited(channel.close());
        expect(await raw.nextHex(), '22 02 00');
        raw.send(creditHex(2, 0xFFFFFFFF));
        raw.send(creditHex(4, 100));
        await settle(raw);
        expect(channel.sendWindow, 65536);
        expect(mux.isOpen, isTrue);
      },
    );

    test('close waits behind subframes waiting for credit', () async {
      final (mux, raw) = rawPair();
      addTearDown(mux.close);
      raw.send(limitsHex(64));
      await settle(raw);
      final channel = mux.open(empty);
      await raw.next();
      // Each costs 32: two fit the window, the third waits.
      final sends = [for (var i = 0; i < 3; i++) channel.send(Uint8List(16))];
      final closed = channel.close(Status.of(StatusCode.cancelled));
      expect(channel.canSend, isFalse);
      expect(channel.state, MuxChannelState.halfClosedLocal);
      await sends[1];
      for (var i = 0; i < 2; i++) {
        expect((await raw.next()).payload, hasLength(16));
      }
      raw.send(creditHex(2, 32));
      await sends[2];
      expect((await raw.next()).payload, hasLength(16));
      final close = await raw.next();
      expect(close.command, MuxCommand.close);
      expect(Status.decode(close.payload).known, StatusCode.cancelled);
      raw.send('22 02 00');
      await closed;
      expect(await channel.done, hasCode(StatusCode.cancelled));
    });

    test('the peer\'s CLOSE drops waiting subframes and sends ours', () async {
      final (mux, raw) = rawPair();
      addTearDown(mux.close);
      raw.send(limitsHex(64));
      await settle(raw);
      final channel = mux.open(empty);
      await raw.next();
      await channel.send(Uint8List(16));
      await channel.send(Uint8List(16));
      await raw.next();
      await raw.next();
      final waiting = channel.send(Uint8List(16));
      final closed = channel.close(Status.of(StatusCode.cancelled));
      raw.send('22 02 00');
      await expectLater(waiting, throwsStatus(StatusCode.failedPrecondition));
      final close = await raw.next();
      expect(close.command, MuxCommand.close);
      expect(Status.decode(close.payload).known, StatusCode.cancelled);
      await closed;
      expect(channel.state, MuxChannelState.closed);
    });

    test(
      'an unconfirmed close sends the CLOSE waiting behind subframes',
      () async {
        final (mux, raw) = rawPair(
          options: rawOptions.copyWith(
            closeConfirmTimeout: const Duration(milliseconds: 30),
          ),
        );
        addTearDown(mux.close);
        raw.send(limitsHex(64));
        await settle(raw);
        final channel = mux.open(empty);
        await raw.next();
        await channel.send(Uint8List(16));
        await channel.send(Uint8List(16));
        await raw.next();
        await raw.next();
        final waiting = channel.send(Uint8List(16));
        await channel.close();
        await expectLater(waiting, throwsStatus(StatusCode.failedPrecondition));
        // Not OK: what was sent did not all go out.
        final close = await raw.next();
        expect(close.command, MuxCommand.close);
        final status = Status.decode(close.payload);
        expect(status.known, StatusCode.deadlineExceeded);
        expect(status.reason, contains('16 bytes not sent'));
        expect(await channel.done, hasCode(StatusCode.deadlineExceeded));
        expect(mux.unconfirmedCloseCount, 1);
      },
    );

    test('a bulk payload needs a window that takes a byte', () async {
      final (mux, raw) = rawPair();
      addTearDown(mux.close);
      raw.send(limitsHex(16));
      await settle(raw);
      final channel = mux.open(empty)..priority = MuxPriority.bulk;
      expect(
        () => channel.send(Uint8List(10)),
        throwsStatus(StatusCode.frameTooLarge),
      );
      // An empty subframe is not split, and fits.
      await channel.send(empty);
    });

    test('sink.addStream fails on a subframe the channel refuses', () async {
      final (mux, raw) = rawPair();
      addTearDown(mux.close);
      raw.send(limitsHex(1000));
      await settle(raw);
      final channel = mux.open(empty);
      await expectLater(
        channel.sink.addStream(
          Stream.fromIterable([Uint8List(10), Uint8List(1000)]),
        ),
        throwsStatus(StatusCode.frameTooLarge),
      );
    });

    test('a lost connection fails waiting subframes', () async {
      final (mux, raw) = rawPair();
      raw.send(limitsHex(64));
      await settle(raw);
      final channel = mux.open(empty);
      await channel.send(Uint8List(16));
      await channel.send(Uint8List(16));
      final waiting = channel.send(Uint8List(16));
      await raw.transport.sink.close();
      await expectLater(waiting, throwsStatus(StatusCode.failedPrecondition));
      expect(await mux.done, hasCode(StatusCode.connectionLost));
    });

    test('a failure no one awaits is not reported', () async {
      final (mux, raw) = rawPair();
      raw.send(limitsHex(64));
      await settle(raw);
      final channel = mux.open(empty);
      for (var i = 0; i < 3; i++) {
        unawaited(channel.send(Uint8List(16)));
      }
      channel.sink.add(Uint8List(16));
      await mux.close();
      await pumpEventQueue();
    });

    test('sink.addStream waits for each subframe', () async {
      final (mux, raw) = rawPair();
      addTearDown(mux.close);
      raw.send(limitsHex(64));
      await settle(raw);
      final channel = mux.open(empty);
      await raw.next();
      final source = StreamController<Uint8List>();
      final added = channel.sink.addStream(source.stream);
      for (var i = 0; i < 4; i++) {
        source.add(Uint8List(16)..[0] = i);
      }
      unawaited(source.close());
      await pumpEventQueue();
      // Two frames sent, one waiting for credit, the last still in the
      // source, which is paused.
      expect(channel.sendWindow, 0);
      expect(source.isPaused, isTrue);
      for (var i = 0; i < 2; i++) {
        expect((await raw.next()).payload[0], i);
      }
      raw.send(creditHex(2, 64));
      await added;
      for (var i = 2; i < 4; i++) {
        expect((await raw.next()).payload[0], i);
      }
    });
  });

  group('receive window', () {
    /// A channel the mux opened over [raw], after the mux's LIMITS of
    /// [window].
    Future<(MuxConnection, RawPeer, MuxChannel)> opened(
      int window, {
      bool manual = false,
    }) async {
      final (mux, raw) = rawPair(
        options: rawOptions.copyWith(
          announceLimits: true,
          initialWindow: window,
        ),
      );
      addTearDown(mux.close);
      await raw.nextControl(MuxControlType.limits);
      final channel = mux.open(empty)..manualCredit = manual;
      expect(await raw.nextHex(), '12 02 00');
      return (mux, raw, channel);
    }

    String data(int length) => dataHex(2, length);

    test('automatic credit: returned once half the window is taken; a '
        'paused subscription takes nothing', () async {
      final (mux, raw, channel) = await opened(1000);
      final taken = <int>[];
      final sub = channel.stream.listen((d) => taken.add(d.length))..pause();
      // 6 subframes of cost 100: nothing taken while paused.
      for (var i = 0; i < 6; i++) {
        raw.send(data(84));
      }
      await settle(raw);
      expect(channel.receiveWindow, 400);
      expect(channel.bufferedBytes, 600);
      expect(mux.bufferedBytes, 600);
      sub.resume();
      final credit = await raw.nextControl(MuxControlType.credit);
      expect(MuxCredit.decode(credit.payload), const MuxCredit(2, 600));
      expect(taken, hasLength(6));
      expect(channel.receiveWindow, 1000);
      expect(mux.bufferedBytes, 0);
      // Under half: kept until more is taken.
      raw.send(data(84));
      raw.send(data(84));
      await settle(raw);
      expect(channel.receiveWindow, 800);
      for (var i = 0; i < 3; i++) {
        raw.send(data(84));
      }
      expect(
        MuxCredit.decode(
          (await raw.nextControl(MuxControlType.credit)).payload,
        ),
        const MuxCredit(2, 500),
      );
      await sub.cancel();
    });

    test('manual credit: returned as the layer reports consumption', () async {
      final (mux, raw, channel) = await opened(1000, manual: true);
      final taken = <Uint8List>[];
      channel.stream.listen(taken.add);
      for (var i = 0; i < 6; i++) {
        raw.send(data(84));
      }
      await settle(raw);
      // Taken, not consumed: held, not counted by the connection.
      expect(taken, hasLength(6));
      expect(channel.bufferedBytes, 0);
      expect(channel.heldBytes, 600);
      expect(mux.bufferedBytes, 0);
      expect(channel.receiveWindow, 400);
      channel.consumed(84);
      channel.consumed(168, subframes: 2);
      await settle(raw);
      expect(channel.receiveWindow, 400);
      expect(channel.heldBytes, 300);
      // Half the window: returned.
      channel.consumed(taken[3].length);
      channel.consumed(taken[4].length);
      expect(
        MuxCredit.decode(
          (await raw.nextControl(MuxControlType.credit)).payload,
        ),
        const MuxCredit(2, 500),
      );
      expect(channel.receiveWindow, 900);
      // More than delivered and not consumed: a bug of the layer.
      expect(() => channel.consumed(200), throwsStateError);
      expect(() => channel.consumed(-1), throwsArgumentError);
      // Back to automatic: what is held counts as consumed (100 bytes),
      // and delivery is consumption again.
      channel.manualCredit = false;
      expect(channel.heldBytes, 0);
      raw.send(data(384));
      expect(
        MuxCredit.decode(
          (await raw.nextControl(MuxControlType.credit)).payload,
        ),
        const MuxCredit(2, 500),
      );
      expect(channel.receiveWindow, 1000);
      expect(() => channel.consumed(0), throwsStateError);
    });

    test(
      'grant raises the window at once, with the credit not returned yet',
      () async {
        final (mux, raw, channel) = await opened(1000);
        final sub = channel.stream.listen((_) {});
        raw.send(data(84));
        await settle(raw);
        expect(channel.receiveWindow, 900);
        sub.pause();
        // With the 100 bytes consumed and not returned yet.
        channel.grant(10000);
        expect(
          MuxCredit.decode(
            (await raw.nextControl(MuxControlType.credit)).payload,
          ),
          const MuxCredit(2, 10100),
        );
        expect(channel.receiveWindow, 11000);
        // The peer may use all of it.
        for (var i = 0; i < 10; i++) {
          raw.send(data(984));
        }
        await settle(raw);
        expect(channel.receiveWindow, 1000);
        // Credit now comes in batches of half the raised window, 5500.
        sub.resume();
        expect(
          MuxCredit.decode(
            (await raw.nextControl(MuxControlType.credit)).payload,
          ),
          const MuxCredit(2, 10000),
        );
        expect(channel.receiveWindow, 11000);
        expect(() => channel.grant(0), throwsArgumentError);
        // What is buffered or held comes back as credit too: the window
        // could go over 2^32 - 1.
        sub.pause();
        raw.send(data(584));
        await settle(raw);
        expect(channel.bufferedBytes, 600);
        expect(channel.receiveWindow, 10400);
        expect(
          () => channel.grant(MuxLimits.maxWindow - 11000 + 1),
          throwsArgumentError,
        );
        channel.grant(MuxLimits.maxWindow - 11000);
        await sub.cancel();
        expect(() => channel.grant(MuxLimits.maxWindow), throwsArgumentError);
        expect(mux.isOpen, isTrue);
      },
    );

    test('no credit once our CLOSE is out or the peer\'s came', () async {
      final (_, raw, channel) = await opened(1000);
      final sub = channel.stream.listen((_) {})..pause();
      raw.send(data(484));
      await settle(raw);
      unawaited(channel.close());
      expect(await raw.nextHex(), '22 02 00');
      sub.resume();
      channel.grant(100);
      // In flight before the peer saw the CLOSE: still within the window.
      raw.send(data(484));
      raw.send('22 02 00');
      await channel.done;
      await settle(raw);
      expect(channel.receiveWindow, 0);
      await sub.cancel();
    });

    test('a frame beyond the window is a protocol error, logged with its '
        'channel', () async {
      final (mux, raw, channel) = await opened(100);
      raw.send(data(84));
      raw.send(data(0));
      final goAway = await raw.nextControl(MuxControlType.goAway);
      expect(goAway.goAwayStatus.known, StatusCode.protocolError);
      expect(
        goAway.goAwayStatus.reason,
        'DATA costing 16 bytes on channel 2, beyond the window of 0 granted',
      );
      expect((await mux.done).known, StatusCode.protocolError);
      expect(await channel.done, hasCode(StatusCode.connectionLost));
    });
  });

  group('between two connections', () {
    Future<void> exchange(MuxConnection a, MuxConnection b) async {
      await a.ping();
      await b.ping();
      final atB = StreamQueue(b.incoming);
      final ca = a.open(empty);
      final cb = await atB.next;
      final sizes = [for (var i = 0; i < 200; i++) (i * 997) % 30000];
      Future<void> sendAll(MuxChannel channel) async {
        for (final size in sizes) {
          await channel.send(Uint8List(size)..fillRange(0, size, size & 0xFF));
        }
      }

      Future<void> receiveAll(MuxChannel channel) async {
        final received = await channel.stream.take(sizes.length).toList();
        expect(received.map((d) => d.length), sizes);
        for (final d in received) {
          expect(d.every((b) => b == d.length & 0xFF), isTrue);
        }
      }

      await Future.wait([
        sendAll(ca),
        sendAll(cb),
        receiveAll(ca),
        receiveAll(cb),
      ]);
      await a.ping();
      await b.ping();
      // Nothing in flight: each side's view of each window agrees.
      expect(ca.sendWindow, cb.receiveWindow);
      expect(cb.sendWindow, ca.receiveWindow);
      expect(ca.sendWindow, greaterThan(32768));
      expect(cb.sendWindow, greaterThan(32768));
      await ca.close();
      await atB.cancel();
    }

    test('window accounting both ways over memory', () async {
      final (a, b) = muxPair();
      await exchange(a, b);
      await a.close();
    });

    test('window accounting both ways over TCP', () async {
      final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final accepted = listener.first;
      final a = MuxConnection(
        await StreamTransport.connectTcp('127.0.0.1', listener.port),
        isInitiator: true,
        options: quiet,
      );
      final b = MuxConnection(
        StreamTransport.fromSocket(await accepted),
        isInitiator: false,
        options: quiet,
      );
      await listener.close();
      await exchange(a, b);
      await a.close();
      await b.done;
    });

    test('a slow consumer stalls its own channel, another one flows', () async {
      final (a, b) = muxPair();
      await a.ping();
      final atB = StreamQueue(b.incoming);
      final slow = a.open(empty);
      final fast = a.open(empty);
      final slowAtB = await atB.next;
      final fastAtB = await atB.next;
      final paused = slowAtB.stream.listen((_) {})..pause();
      final fastReceived = fastAtB.stream.fold<int>(0, (n, d) => n + d.length);
      var slowSent = 0;
      final slowDone = () async {
        for (var i = 0; i < 100; i++) {
          await slow.send(Uint8List(16000));
          slowSent++;
        }
      }();
      for (var i = 0; i < 100; i++) {
        await fast.send(Uint8List(16000));
      }
      await a.ping();
      // The paused channel holds its window, 4 subframes of 16016; the
      // fifth waits for credit.
      expect(slowSent, 4);
      expect(slowAtB.bufferedBytes, 4 * 16016);
      expect(b.bufferedBytes, 4 * 16016);
      await fast.close();
      expect(await fastReceived, 100 * 16000);
      paused.resume();
      await slowDone;
      await slow.close();
      await a.close();
      await paused.cancel();
      await atB.cancel();
    });

    test(
      'the connection backstop pauses reading for all channels together',
      () async {
        final (a, b) = muxPair(
          acceptor: quiet.copyWith(receiveHighWaterMarkBytes: 100000),
        );
        await a.ping();
        final atB = StreamQueue(b.incoming);
        final channels = [for (var i = 0; i < 4; i++) a.open(empty)];
        final subs = <StreamSubscription<Uint8List>>[];
        for (var i = 0; i < 4; i++) {
          final channel = await atB.next;
          // The first held by a layer with manual credit, which does not
          // count; three not read at all.
          channel.manualCredit = i == 0;
          subs.add(channel.stream.listen((_) {}));
          if (i > 0) {
            subs.last.pause();
          }
        }
        for (final channel in channels) {
          for (var i = 0; i < 4; i++) {
            unawaited(channel.send(Uint8List(16000)));
          }
        }
        await pumpEventQueue();
        final layer = b.channels.firstWhere((c) => c.manualCredit);
        expect(layer.heldBytes, 4 * 16016);
        // Each channel not read holds up to its window, 64064 bytes, and
        // the second pushes the total over the mark.
        expect(b.bufferedBytes, greaterThan(100000));
        expect(b.isReceivePaused, isTrue);
        // A ping is not answered while reading is paused.
        var answered = false;
        unawaited(a.ping().then((_) => answered = true));
        await pumpEventQueue();
        expect(answered, isFalse);
        // Two of them are read: reading resumes below half the mark, and
        // the third holds its window.
        subs[1].resume();
        subs[2].resume();
        await pumpEventQueue();
        expect(b.isReceivePaused, isFalse);
        expect(answered, isTrue);
        expect(b.bufferedBytes, 4 * 16016);
        for (final sub in subs) {
          await sub.cancel();
        }
        await a.close();
        await atB.cancel();
      },
    );
  });
}
