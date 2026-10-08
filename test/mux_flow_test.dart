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
import 'dart:typed_data';

import 'package:switchboard/src/bytes.dart';
import 'package:switchboard/src/mux/mux_channel.dart';
import 'package:switchboard/src/mux/mux_frame.dart';
import 'package:switchboard/src/status.dart';
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
        expect(await raw.nextHex(), '22 02 00');
        expect(mux.unconfirmedCloseCount, 1);
      },
    );

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
}
