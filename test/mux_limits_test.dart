/*
Polyverse Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Authors:
  Jan Boon <jan.boon@kaetemi.be>
  Claude Opus 5.5 <noreply@anthropic.com>
  GPT-6 Astra <noreply@anthropic.com>
*/

// Resource limits of the mux: rejected OPENs, undelivered channels, receive
// buffers and the connection high-water mark, output backpressure over TCP,
// reason truncation, application codes from the peer, the close
// confirmation timeout and the budget of held OPEN payloads.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:async/async.dart';
import 'package:switchboard/src/bytes.dart';
import 'package:switchboard/src/mux/mux_channel.dart';
import 'package:switchboard/src/mux/mux_connection.dart';
import 'package:switchboard/src/mux/mux_frame.dart';
import 'package:switchboard/src/naming/naming_protocol.dart';
import 'package:switchboard/src/status.dart';
import 'package:switchboard/src/transport/stream_transport.dart';
import 'package:test/test.dart';

import 'mux_harness.dart';

/// A DATA frame on [id] with [length] payload bytes, as hex.
String dataHex(int id, int length) =>
    hexString(MuxFrame.data(id, Uint8List(length)).encode());

/// An OPEN frame on [id] with [length] payload bytes, as hex.
String openHex(int id, [int length = 0]) =>
    hexString(MuxFrame.open(id, Uint8List(length)).encode());

Status closeStatus(MuxFrame frame) {
  expect(frame.command, MuxCommand.close);
  return Status.decode(frame.payload);
}

/// Sends PING and waits for its PONG: frames sent before it were handled.
Future<void> settleRaw(RawPeer raw) async {
  raw.send('02 00 00 01 5E');
  await raw.nextControl(MuxControlType.pong);
}

/// An output that accepts one chunk each time [take] is called, like a
/// socket whose peer reads slowly.
class SlowSink implements StreamSink<List<int>> {
  StreamSubscription<List<int>>? _subscription;
  final Completer<void> _done = Completer<void>();
  int accepted = 0;

  /// Accepts one more chunk.
  void take() => _subscription?.resume();

  @override
  Future<void> addStream(Stream<List<int>> stream) {
    final finished = Completer<void>();
    _subscription = stream.listen((chunk) {
      accepted += chunk.length;
      _subscription!.pause();
    }, onDone: finished.complete);
    return finished.future;
  }

  @override
  void add(List<int> event) => throw UnsupportedError('add');

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      throw UnsupportedError('addError');

  @override
  Future<void> close() async {
    await _subscription?.cancel();
    if (!_done.isCompleted) {
      _done.complete();
    }
  }

  @override
  Future<void> get done => _done.future;
}

void main() {
  group('rejected OPENs', () {
    test('keep only the id; re-OPEN before the confirmation is a protocol '
        'error', () async {
      final (mux, raw) = rawPair(options: rawOptions.copyWith(maxChannels: 1));
      raw.send(openHex(3));
      raw.send(openHex(5, 1000));
      final rejection = await raw.next();
      expect(rejection.channelId, 5);
      expect(closeStatus(rejection).known, StatusCode.resourceExhausted);
      expect(mux.unconfirmedCloseCount, 1);
      expect(mux.openChannelCount, 1);
      // DATA racing the rejection is dropped, not a protocol error.
      raw.send('02 05 00 01');
      raw.send('02 00 00 01 AA');
      expect(await raw.nextHex(), '02 00 00 02 AA');
      expect(mux.isOpen, isTrue);
      raw.send(openHex(5));
      final goAway = await raw.nextControl(MuxControlType.goAway);
      expect(goAway.goAwayStatus.known, StatusCode.protocolError);
      expect(await mux.done, hasCode(StatusCode.protocolError));
    });

    test('the confirmation frees the id', () async {
      final (mux, raw) = rawPair(options: rawOptions.copyWith(maxChannels: 1));
      final channels = StreamQueue(mux.incoming);
      raw.send(openHex(3));
      raw.send(openHex(5));
      expect((await raw.next()).channelId, 5);
      raw.send('22 05 00');
      raw.send('02 00 00 01 AA');
      expect(await raw.nextHex(), '02 00 00 02 AA');
      expect(mux.unconfirmedCloseCount, 0);
      // Channel 3 ends, then 5 can be opened again.
      final first = await channels.next;
      raw.send('22 03 00');
      expect(await raw.nextHex(), '22 03 00');
      expect(await first.done, Status.ok);
      raw.send(openHex(5));
      expect((await channels.next).id, 5);
      await mux.close();
      await channels.cancel();
    });

    test('many unconfirmed rejections end the connection with GOAWAY '
        'RESOURCE_EXHAUSTED', () async {
      final (mux, raw) = rawPair(options: rawOptions.copyWith(maxChannels: 1));
      const cap = MuxOptions.defaultMaxPendingRejections;
      raw.send(openHex(3));
      for (var i = 0; i < cap; i++) {
        raw.send(openHex(5 + 2 * i, 1000));
      }
      raw.send('02 00 00 01 AA');
      var closes = 0;
      while (true) {
        final frame = await raw.next();
        if (frame.channelId == 0) {
          expect(hexString(frame.payload), '02 AA');
          break;
        }
        expect(closeStatus(frame).known, StatusCode.resourceExhausted);
        closes++;
      }
      expect(closes, cap);
      expect(mux.unconfirmedCloseCount, cap);
      expect(mux.isOpen, isTrue);
      // One more is beyond the cap.
      raw.send(openHex(5 + 2 * cap, 1000));
      final rest = await raw.rest();
      expect(rest, hasLength(1));
      final goAway = MuxControlMessage.decode(rest.single.payload);
      expect(goAway.knownType, MuxControlType.goAway);
      expect(goAway.goAwayStatus.known, StatusCode.resourceExhausted);
      expect(await mux.done, hasCode(StatusCode.resourceExhausted));
      expect(mux.unconfirmedCloseCount, 0);
    });
  });

  group('undelivered incoming channels', () {
    test(
      'closed channels still count toward the incoming backlog cap',
      () async {
        final (mux, raw) = rawPair(
          options: rawOptions.copyWith(maxChannels: 2),
        );
        addTearDown(mux.close);
        for (var i = 0; i < 2; i++) {
          raw.send(openHex(3));
          raw.send('22 03 00');
          expect(closeStatus(await raw.next()), Status.ok);
        }
        expect(mux.openChannelCount, 0);
        raw.send(openHex(3));
        raw.send('22 03 00');
        expect(
          closeStatus(await raw.next()).known,
          StatusCode.resourceExhausted,
        );
        final incoming = StreamQueue(mux.incoming);
        addTearDown(() => incoming.cancel(immediate: true));
        expect((await incoming.next).state, MuxChannelState.closed);
        expect((await incoming.next).state, MuxChannelState.closed);
        // Delivering the backlog frees capacity, including a reused id.
        raw.send(openHex(3));
        expect((await incoming.next).state, MuxChannelState.open);
      },
    );

    test('closed undelivered OPEN payloads retain their budget', () async {
      final (mux, raw) = rawPair(
        options: rawOptions.copyWith(maxOpenPayloadBytes: 100),
      );
      addTearDown(mux.close);
      raw.send(openHex(3, 100));
      raw.send('02 03 00 AA');
      raw.send('22 03 00');
      expect(closeStatus(await raw.next()), Status.ok);
      expect(mux.openPayloadBytes, 100);
      // The payload and one subframe at its cost, 1 + 16.
      expect(mux.bufferedBytes, 117);
      raw.send(openHex(3, 1));
      raw.send('22 03 00');
      expect(closeStatus(await raw.next()).known, StatusCode.resourceExhausted);
      final incoming = StreamQueue(mux.incoming);
      addTearDown(() => incoming.cancel(immediate: true));
      final channel = await incoming.next;
      expect(channel.openPayload, hasLength(100));
      expect((await channel.stream.toList()).map(hexString), ['AA']);
      expect(mux.openPayloadBytes, 0);
      expect(mux.bufferedBytes, 0);
      raw.send(openHex(3, 100));
      expect((await incoming.next).openPayload, hasLength(100));
    });

    test(
      'cancelling or ending a closed backlog releases accounting once',
      () async {
        for (final closeConnection in [false, true]) {
          final (mux, raw) = rawPair();
          addTearDown(mux.close);
          raw.send(openHex(3, 100));
          raw.send('02 03 00 AA');
          raw.send('22 03 00');
          expect(closeStatus(await raw.next()), Status.ok);
          expect(mux.openPayloadBytes, 100);
          if (closeConnection) {
            await mux.close();
          }
          final subscription = mux.incoming.listen((_) => fail('paused'))
            ..pause();
          await subscription.cancel();
          expect(mux.openPayloadBytes, 0);
          expect(mux.bufferedBytes, 0);
        }
      },
    );

    test('a paused listener holds at most maxChannels of them', () async {
      final (mux, raw) = rawPair(options: rawOptions.copyWith(maxChannels: 2));
      addTearDown(mux.close);
      final received = <MuxChannel>[];
      final subscription = mux.incoming.listen(received.add)..pause();
      addTearDown(subscription.cancel);
      for (var i = 0; i < 2; i++) {
        raw.send(openHex(3, 10));
        raw.send('02 03 00 AA');
        raw.send('22 03 00');
        expect(closeStatus(await raw.next()), Status.ok);
      }
      // Its CLOSE confirms the rejection.
      raw.send(openHex(3, 10));
      raw.send('22 03 00');
      expect(closeStatus(await raw.next()).known, StatusCode.resourceExhausted);
      expect(mux.openPayloadBytes, 20);
      expect(received, isEmpty);
      subscription.resume();
      await pumpEventQueue();
      expect(received, hasLength(2));
      expect(mux.openPayloadBytes, 0);
      for (final channel in received) {
        expect(channel.state, MuxChannelState.closed);
        expect((await channel.stream.toList()).map(hexString), ['AA']);
      }
      expect(mux.bufferedBytes, 0);
    });

    test('cancelling incoming closes them with UNAVAILABLE', () async {
      final (a, b) = muxPair(
        acceptor: quiet.copyWith(goAwayGrace: const Duration(seconds: 5)),
      );
      final c1 = a.open(empty);
      final c2 = a.open(empty);
      final c3 = a.open(empty);
      unawaited(c2.send(hexBytes('01 02 03')));
      await a.ping();
      expect(b.openChannelCount, 3);
      expect(b.bufferedBytes, greaterThan(0));

      final first = await b.incoming.first;
      expect(first.id, c1.id);
      expect(await c2.done, hasCode(StatusCode.unavailable));
      expect(await c3.done, hasCode(StatusCode.unavailable));
      await a.ping();
      expect(b.openChannelCount, 1);
      expect(b.channels, [first]);
      expect(b.bufferedBytes, 0);
      // Later OPENs are refused the same way.
      expect(await a.open(empty).done, hasCode(StatusCode.unavailable));

      await first.close();
      expect(b.openChannelCount, 0);
      final watch = Stopwatch()..start();
      await b.goAway();
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
      expect(await c1.done, Status.ok);
      expect(await a.done, hasCode(StatusCode.goingAway));
    });

    test('a paused incoming subscription keeps them buffered', () async {
      final (a, b) = muxPair();
      final received = <MuxChannel>[];
      final sub = b.incoming.listen(received.add);
      a.open(empty);
      await a.ping();
      expect(received, hasLength(1));
      sub.pause();
      a.open(empty);
      a.open(empty);
      await a.ping();
      expect(received, hasLength(1));
      expect(b.openChannelCount, 3);
      sub.resume();
      await pumpEventQueue();
      expect(received.map((c) => c.id), [2, 4, 6]);
      await sub.cancel();
      await a.close();
    });
  });

  group('receive buffers', () {
    test('a channel nobody reads holds at most its window, the others '
        'flow; DATA beyond the window ends the connection', () async {
      final (mux, raw) = rawPair(
        options: rawOptions.copyWith(announceLimits: true, initialWindow: 4096),
      );
      expect(
        MuxLimits.decode((await raw.nextControl(MuxControlType.limits)).payload)
            .initialWindow,
        4096,
      );
      // Channels this side opens: the peer saw the LIMITS first, so their
      // window is the one announced.
      final unread = mux.open(empty);
      final read = mux.open(empty);
      expect(await raw.nextHex(), '12 02 00');
      expect(await raw.nextHex(), '12 04 00');
      final readData = read.stream.toList();
      for (var i = 0; i < 4; i++) {
        raw.send(dataHex(2, 1000));
        raw.send(dataHex(4, 1000));
      }
      raw.send('02 00 00 01 AA');
      // The channel that is read returns credit at half its window.
      final credits = <MuxCredit>[];
      while (true) {
        final frame = await raw.next();
        final control = MuxControlMessage.decode(frame.payload);
        if (control.knownType == MuxControlType.pong) {
          break;
        }
        credits.add(MuxCredit.decode(control.payload));
      }
      // In batches of at least half the window, as the listener takes
      // them; what is consumed and not returned yet is less than half.
      expect(credits, isNotEmpty);
      var returned = 0;
      for (final credit in credits) {
        expect(credit.channelId, 4);
        expect(credit.bytes, greaterThanOrEqualTo(2048));
        returned += credit.bytes;
      }
      expect(4064 - returned, inInclusiveRange(0, 2047));
      expect(read.receiveWindow, 4096 - 4064 + returned);
      // 4 * (1000 + 16) bytes buffered for the unread channel: its window
      // is used up.
      expect(unread.bufferedBytes, 4064);
      expect(unread.receiveWindow, 32);
      expect(mux.bufferedBytes, 4064);
      expect(unread.state, MuxChannelState.open);

      // Beyond it: GOAWAY PROTOCOL_ERROR.
      raw.send(dataHex(2, 17));
      final goAway = await raw.nextControl(MuxControlType.goAway);
      expect(goAway.goAwayStatus.known, StatusCode.protocolError);
      expect(goAway.goAwayStatus.reason, contains('beyond the window'));
      expect((await mux.done).known, StatusCode.protocolError);
      expect((await readData).map((d) => d.length), [1000, 1000, 1000, 1000]);
    });

    test('a channel the peer opened accepts 64 KiB however small the '
        'announced window', () async {
      final (mux, raw) = rawPair(
        options: rawOptions.copyWith(announceLimits: true, initialWindow: 4096),
      );
      // Opened before the LIMITS reached the peer, as far as this side can
      // tell: the peer's window is 64 KiB.
      raw.send(openHex(3));
      final channel = await mux.incoming.first;
      expect(channel.receiveWindow, 65536);
      for (var i = 0; i < 64; i++) {
        raw.send(dataHex(3, 1008));
      }
      await settleRaw(raw);
      expect(channel.receiveWindow, 0);
      expect(mux.isOpen, isTrue);
      raw.send(dataHex(3, 0));
      final goAway = await raw.nextControl(MuxControlType.goAway);
      expect(goAway.goAwayStatus.known, StatusCode.protocolError);
    });

    test('a cancelled channel subscription drops later DATA, returning its '
        'credit', () async {
      final (mux, raw) = rawPair();
      raw.send(openHex(3));
      final channel = await mux.incoming.first;
      final sub = channel.stream.listen((_) {});
      raw.send(dataHex(3, 3000));
      await pumpEventQueue();
      await sub.cancel();
      for (var i = 0; i < 10; i++) {
        raw.send(dataHex(3, 3000));
      }
      raw.send('02 00 00 01 AA');
      // 11 * 3016 bytes consumed: past half the window of 64 KiB.
      final credit = await raw.nextControl(MuxControlType.credit);
      expect(MuxCredit.decode(credit.payload), const MuxCredit(3, 33176));
      expect(await raw.nextHex(), '02 00 00 02 AA');
      expect(channel.state, MuxChannelState.open);
      expect(channel.receiveWindow, 65536);
      expect(mux.bufferedBytes, 0);
      await mux.close();
    });

    group('connection high-water mark', () {
      late StreamController<List<int>> toMux;
      // Closed through the transport.
      // ignore: close_sinks
      late StreamController<List<int>> fromMux;
      late MuxConnection mux;

      Future<MuxChannel> start(MuxOptions options) async {
        toMux = StreamController<List<int>>();
        fromMux = StreamController<List<int>>();
        unawaited(fromMux.stream.drain<void>());
        mux = MuxConnection(
          StreamTransport.wrap(toMux.stream, fromMux.sink),
          isInitiator: false,
          options: options,
        );
        toMux.add(StreamTransport.encodePreamble());
        toMux.add(StreamTransport.encodeFrame(hexBytes(openHex(2))));
        return mux.incoming.first;
      }

      // At most the channel's window of 64 KiB: 64 * 1016 bytes.
      void sendData(int count) {
        for (var i = 0; i < count; i++) {
          toMux.add(StreamTransport.encodeFrame(hexBytes(dataHex(2, 1000))));
        }
      }

      tearDown(() async {
        await mux.close();
        await toMux.close();
      });

      test('a paused channel pauses the transport input', () async {
        final channel = await start(
          rawOptions.copyWith(receiveHighWaterMarkBytes: 16 * 1024),
        );
        final sizes = <int>[];
        final sub = channel.stream.listen((d) => sizes.add(d.length))..pause();
        sendData(60);
        await pumpEventQueue();
        expect(mux.isReceivePaused, isTrue);
        expect(toMux.isPaused, isTrue);
        expect(mux.bufferedBytes, greaterThan(16 * 1024));
        // Bounded by the mark and what the transport had already decoded,
        // not by what the peer sent.
        expect(mux.bufferedBytes, lessThan(20 * 1024));
        expect(channel.bufferedBytes, mux.bufferedBytes);

        sub.resume();
        await pumpEventQueue();
        expect(sizes, hasLength(60));
        expect(mux.isReceivePaused, isFalse);
        expect(toMux.isPaused, isFalse);
        expect(mux.bufferedBytes, 0);
        await sub.cancel();
      });

      test('keep-alive does not probe while reading is paused', () async {
        final channel = await start(
          rawOptions.copyWith(
            receiveHighWaterMarkBytes: 4096,
            keepAliveInterval: const Duration(milliseconds: 20),
            keepAliveTimeout: const Duration(milliseconds: 20),
          ),
        );
        final sub = channel.stream.listen((_) {})..pause();
        sendData(10);
        await pumpEventQueue();
        expect(mux.isReceivePaused, isTrue);
        // The byte peer never answers PING: without the pause rule the
        // connection would be gone after 40 ms.
        await Future<void>.delayed(const Duration(milliseconds: 150));
        expect(mux.isOpen, isTrue);
        await sub.cancel();
      });
    });
  });

  group('output backpressure over TCP', () {
    test('a peer that never reads: output stays bounded, input pauses, '
        'close destroys the socket', () async {
      final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final acceptedSocket = listener.first;
      final client = await RawSocket.connect(
        InternetAddress.loopbackIPv4,
        listener.port,
      );
      // The client never reads; it only learns about the close.
      client.readEventsEnabled = false;
      final clientClosed = Completer<void>();
      client.listen(
        (event) {
          if (event == RawSocketEvent.readClosed ||
              event == RawSocketEvent.closed) {
            if (!clientClosed.isCompleted) {
              clientClosed.complete();
            }
          }
        },
        onError: (Object _) {
          if (!clientClosed.isCompleted) {
            clientClosed.complete();
          }
        },
        onDone: () {
          if (!clientClosed.isCompleted) {
            clientClosed.complete();
          }
        },
      );
      final serverSocket = await acceptedSocket;
      const mark = 64 * 1024;
      final transport = StreamTransport.fromSocket(
        serverSocket,
        outputHighWaterMark: mark,
      );
      final mux = MuxConnection(
        transport,
        isInitiator: false,
        options: rawOptions.copyWith(
          keepAliveTimeout: const Duration(milliseconds: 200),
        ),
      );

      // PINGs with 1024 byte payloads, each answered by an equal PONG.
      final ping = StreamTransport.encodeFrame(
        MuxControlMessage(1, Uint8List(1024)).toFrame().encode(),
      );
      final burst = BytesBuilder();
      for (var i = 0; i < 64; i++) {
        burst.add(ping);
      }
      final chunk = burst.takeBytes();

      /// Writes what the kernel accepts; returns the bytes written.
      int write(Uint8List bytes) {
        var offset = 0;
        while (offset < bytes.length) {
          final n = client.write(bytes, offset);
          if (n <= 0) {
            break;
          }
          offset += n;
        }
        return offset;
      }

      write(StreamTransport.encodePreamble());
      var sent = 0;
      final watch = Stopwatch()..start();
      while (!transport.isInputThrottled) {
        if (watch.elapsed > const Duration(seconds: 20) ||
            sent > 512 * 1024 * 1024) {
          fail('output never backed up after $sent bytes');
        }
        sent += write(chunk);
        await Future<void>.delayed(Duration.zero);
      }
      await pumpEventQueue();
      expect(transport.bufferedOutputBytes, greaterThan(mark));
      // The mark plus the PONGs for what had already been read.
      const bound = mark + 8 * 1024 * 1024;
      expect(transport.bufferedOutputBytes, lessThan(bound));

      // The client keeps sending until its own kernel buffers are full:
      // the server reads only while its output drains, so the
      // backpressure reaches the client and the server's output stays
      // bounded meanwhile.
      var extra = 0;
      while (true) {
        final n = write(chunk);
        extra += n;
        if (n < chunk.length) {
          break;
        }
        if (extra > 256 * 1024 * 1024) {
          fail('the server kept reading');
        }
        await Future<void>.delayed(Duration.zero);
        expect(transport.bufferedOutputBytes, lessThan(bound));
      }
      await pumpEventQueue();
      expect(transport.bufferedOutputBytes, lessThan(bound));
      expect(transport.isInputThrottled, isTrue);

      // Closing cannot flush to a peer that does not read: after
      // keepAliveTimeout the socket is destroyed.
      final closing = Stopwatch()..start();
      await mux.close();
      expect(closing.elapsed, lessThan(const Duration(seconds: 5)));
      expect(transport.bufferedOutputBytes, 0);
      await transport.sink.done;
      await clientClosed.future.timeout(const Duration(seconds: 5));
      await client.close();
      await listener.close();
    });
  });

  test('keep-alive counts a throttled peer that reads as alive', () async {
    final toMux = StreamController<List<int>>();
    final output = SlowSink();
    final transport = StreamTransport.wrap(
      toMux.stream,
      output,
      outputHighWaterMark: 4096,
    );
    final mux = MuxConnection(
      transport,
      isInitiator: true,
      options: rawOptions.copyWith(
        keepAliveInterval: const Duration(milliseconds: 20),
        keepAliveTimeout: const Duration(milliseconds: 20),
      ),
    );
    // OPEN frames are not flow controlled, so they fill the transport's
    // output where DATA would wait for credit.
    for (var i = 0; i < 2000; i++) {
      mux.open(Uint8List(1000));
    }
    expect(transport.isInputThrottled, isTrue);
    // Nothing arrives, but the peer reads a chunk every 10 ms: longer than
    // interval and timeout together, the connection stays.
    for (var i = 0; i < 15; i++) {
      output.take();
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(transport.isInputThrottled, isTrue);
    expect(mux.isOpen, isTrue);
    // The peer stops reading: keep-alive gives up, the transport is
    // aborted.
    expect(
      await mux.done.timeout(const Duration(seconds: 5)),
      hasCode(StatusCode.connectionLost),
    );
    await mux.close();
    await transport.sink.done;
    expect(transport.bufferedOutputBytes, 0);
    await output.close();
    await toMux.close();
  });

  group('reasons', () {
    test('truncation is UTF-8 safe', () {
      for (final (char, bytes) in [('x', 1), ('é', 2), ('€', 3), ('😀', 4)]) {
        final status = Status.of(StatusCode.unavailable, char * 2000);
        final cut = truncateStatus(status, 1024);
        final encoded = cut.encode();
        expect(encoded.length, lessThanOrEqualTo(1024), reason: char);
        expect(encoded.length, greaterThan(1024 - bytes), reason: char);
        expect(utf8.decode(encoded.sublist(2)), cut.reason);
        expect(cut.reason.replaceAll(char, ''), isEmpty, reason: char);
      }
      final short = Status.of(StatusCode.unavailable, 'ok');
      expect(identical(truncateStatus(short, 1024), short), isTrue);
      expect(truncateStatus(short, 2), const Status(14));
      expect(
        MuxControlMessage.goAway(Status.of(StatusCode.unavailable, 'x' * 2000))
            .payload,
        hasLength(MuxControlMessage.maxControlPayload),
      );
    });

    test('truncation keeps fixed fields before the reason', () {
      final moved = MovedStatus(
        owner: 0xFEDCBA987654,
        epoch: 7,
        reason: '€' * 400,
      ).toStatus();
      final cut = truncateStatus(moved, 1024);
      final encoded = cut.encode();
      expect(encoded.length, inInclusiveRange(1022, 1024));
      expect(encoded.sublist(0, 12), moved.encode().sublist(0, 12));
      final fields = MovedStatus.fromStatus(cut);
      expect(fields.owner, 0xFEDCBA987654);
      expect(fields.epoch, 7);
      expect(fields.reason.replaceAll('€', ''), isEmpty);
      // No room for the reason: the fields alone; no room for the fields:
      // nothing, never part of them.
      expect(
        MovedStatus.fromStatus(truncateStatus(moved, 12)).owner,
        0xFEDCBA987654,
      );
      expect(truncateStatus(moved, 11), const Status(37));
      expect(truncateStatus(moved, 2), const Status(37));
      // RELOCATED has the same fields.
      final relocated = Status.decode(
        Uint8List.fromList([38, 0, ...moved.encode().sublist(2)]),
      );
      expect(
        MovedStatus.fromStatus(truncateStatus(relocated, 12)).owner,
        0xFEDCBA987654,
      );
      expect(truncateStatus(relocated, 11), const Status(38));
    });

    test('a RELOCATED status crosses a CLOSE byte for byte', () async {
      final (a, b) = muxPair();
      final ca = a.open(empty);
      final cb = await b.incoming.first;
      final moved = MovedStatus(
        owner: 0x80FF80FF80FF,
        epoch: 0x80808080,
      ).toStatus(relocated: true);
      await cb.close(moved);
      final received = await ca.done;
      expect(received.encode(), moved.encode());
      expect(
        MovedStatus.fromStatus(received),
        MovedStatus(owner: 0x80FF80FF80FF, epoch: 0x80808080),
      );
    });

    test(
      'an 1100 byte GOAWAY reason does not break a conforming peer',
      () async {
        final (a, b) = muxPair();
        final ca = a.open(empty);
        await b.incoming.first;
        final goingAway = b.goAway(
          Status.of(StatusCode.unavailable, 'x' * 1100),
        );
        await a.ping();
        expect(a.peerGoingAway, isTrue);
        expect(a.isOpen, isTrue);
        await ca.close();
        final status = await a.done;
        expect(status.known, StatusCode.goingAway);
        expect(status.reason, startsWith('unavailable: xxx'));
        expect(utf8.encode(status.reason).length, lessThan(1100));
        await goingAway;
      },
    );

    test('a CLOSE reason fits the peer frame limit', () async {
      final (a, b) = muxPair(acceptor: quiet.copyWith(maxFrameSize: 64));
      await a.ping();
      final ca = a.open(empty);
      final rb = await b.incoming.first;
      final full = Status.of(StatusCode.cancelled, 'y' * 100);
      unawaited(ca.close(full));
      // 64 minus a 3 byte header and the 2 byte code.
      expect(await rb.done, Status.of(StatusCode.cancelled, 'y' * 59));
      expect(await ca.done, full);
      await a.ping();
      expect(b.isOpen, isTrue);
      await a.close();
    });
  });

  group('CONNECTION_LOST stays local', () {
    test('CLOSE sends UNAVAILABLE and retains the local status', () async {
      final (mux, raw) = rawPair();
      addTearDown(mux.close);
      final channel = mux.open(empty);
      await raw.next();
      final status = Status.of(StatusCode.connectionLost, 'upstream gone');
      unawaited(channel.close(status));
      expect(
        closeStatus(await raw.next()),
        Status.of(StatusCode.unavailable, 'upstream gone'),
      );
      raw.send('22 02 00');
      expect(await channel.done, status);
    });

    test('GOAWAY sends UNAVAILABLE and retains the local status', () async {
      final (mux, raw) = rawPair();
      final status = Status.of(StatusCode.connectionLost, 'upstream gone');
      await mux.goAway(status);
      final frames = await raw.rest();
      expect(frames, hasLength(1));
      expect(
        MuxControlMessage.decode(frames.single.payload).goAwayStatus,
        Status.of(StatusCode.unavailable, 'upstream gone'),
      );
      expect(await mux.done, status);
    });

    test('only the code changes: the bytes after it are relayed', () async {
      final (mux, raw) = rawPair();
      addTearDown(mux.close);
      final channel = mux.open(empty);
      await raw.next();
      // As a peer that broke the rule sent it, the reason not even UTF-8.
      final status = Status.decode(hexBytes('22 00 FF 41'));
      unawaited(channel.close(status));
      expect(hexString((await raw.next()).payload), '0E 00 FF 41');
      raw.send('22 02 00');
      expect(await channel.done, status);
    });
  });

  group('application codes from the peer', () {
    test('CLOSE: reported as UNKNOWN and relayable', () async {
      final (mux, raw) = rawPair();
      final channel = mux.open(empty);
      expect(await raw.nextHex(), '12 02 00');
      raw.send('22 02 00 2C 01 61');
      expect(await raw.nextHex(), '22 02 00');
      final status = await channel.done;
      expect(status, Status.of(StatusCode.unknown, 'code 300: a'));
      final relay = mux.open(empty);
      expect(await raw.nextHex(), '12 04 00');
      // Would throw ArgumentError for an application code.
      unawaited(relay.close(status));
      final close = await raw.next();
      expect(close.channelId, 4);
      expect(closeStatus(close), status);
      await mux.close();
    });

    test('GOAWAY: reported as GOING_AWAY with the code', () async {
      final (mux, raw) = rawPair();
      raw.send('02 00 00 03 2C 01');
      expect(
        await mux.done,
        Status.of(StatusCode.goingAway, 'unknown: code 300'),
      );
      await raw.rest();
    });
  });

  group('close confirmation timeout', () {
    const options = MuxOptions(
      keepAliveInterval: null,
      announceLimits: false,
      closeConfirmTimeout: Duration(milliseconds: 50),
    );

    test(
      'close() completes; the id stays reserved until the late CLOSE',
      () async {
        final (mux, raw) = rawPair(options: options);
        final channel = mux.open(empty);
        expect(await raw.nextHex(), '12 02 00');
        final watch = Stopwatch()..start();
        await channel.close(Status.of(StatusCode.cancelled));
        expect(
          watch.elapsed,
          greaterThanOrEqualTo(const Duration(milliseconds: 40)),
        );
        expect(await raw.nextHex(), '22 02 00 01 00');
        expect(await channel.done, Status.of(StatusCode.cancelled));
        expect(channel.state, MuxChannelState.closed);
        expect(mux.openChannelCount, 0);
        expect(mux.channels, isEmpty);
        expect(mux.unconfirmedCloseCount, 1);

        // Not reused while the peer may still consider it open.
        mux.nextChannelIdForTesting = 2;
        final other = mux.open(empty);
        expect(other.id, 4);
        expect(await raw.nextHex(), '12 04 00');

        // Late DATA is dropped, the late CLOSE frees the id.
        raw.send('02 02 00 01');
        raw.send('22 02 00');
        raw.send('02 00 00 01 AA');
        expect(await raw.nextHex(), '02 00 00 02 AA');
        expect(mux.unconfirmedCloseCount, 0);
        mux.nextChannelIdForTesting = 2;
        expect(mux.open(empty).id, 2);
        await mux.close();
      },
    );

    test('goAway does not wait for unconfirmed channels', () async {
      final (mux, raw) = rawPair(
        options: options.copyWith(goAwayGrace: const Duration(seconds: 5)),
      );
      final channel = mux.open(empty);
      unawaited(channel.close());
      await channel.done;
      final watch = Stopwatch()..start();
      await mux.goAway();
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
      await raw.rest();
    });

    test('too many unconfirmed closes end the connection', () async {
      final (mux, raw) = rawPair(
        options: options.copyWith(maxPendingRejections: 2),
      );
      final channels = [for (var i = 0; i < 3; i++) mux.open(empty)];
      for (final channel in channels) {
        unawaited(channel.close());
      }
      expect(await mux.done, hasCode(StatusCode.resourceExhausted));
      final goAway = await raw.nextControl(MuxControlType.goAway);
      expect(goAway.goAwayStatus.known, StatusCode.resourceExhausted);
    });

    test('Duration.zero waits forever', () async {
      final (mux, raw) = rawPair(
        options: options.copyWith(closeConfirmTimeout: Duration.zero),
      );
      final channel = mux.open(empty);
      final closed = channel.close();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(channel.state, MuxChannelState.halfClosedLocal);
      await mux.close();
      await closed;
      expect(await channel.done, hasCode(StatusCode.connectionLost));
      await raw.rest();
    });
  });

  group('open payload budget', () {
    test('peer OPENs beyond maxOpenPayloadBytes are refused until channels '
        'close', () async {
      final (a, b) = muxPair(
        acceptor: quiet.copyWith(maxOpenPayloadBytes: 100),
      );
      final atB = StreamQueue(b.incoming);
      final first = a.open(Uint8List(40));
      final second = a.open(Uint8List(40));
      final third = a.open(Uint8List(40));
      final empty = a.open(Uint8List(0));
      final firstAtB = await atB.next;
      await atB.next;
      expect(await third.done, hasCode(StatusCode.resourceExhausted));
      // An empty payload still fits.
      expect((await atB.next).id, empty.id);
      expect(b.openPayloadBytes, 80);
      // Held payloads count as buffered bytes.
      expect(b.bufferedBytes, 80);
      // Channels the acceptor opens itself do not count.
      b.open(Uint8List(90));
      await b.ping();
      expect(b.openPayloadBytes, 80);
      // A mutually closed channel releases its payload.
      await firstAtB.close();
      expect(await first.done, Status.ok);
      expect(b.openPayloadBytes, 40);
      expect(b.bufferedBytes, 40);
      final fourth = a.open(Uint8List(60));
      expect((await atB.next).openPayload, hasLength(60));
      expect(b.openPayloadBytes, 100);
      expect(fourth.state, MuxChannelState.open);
      expect(second.state, MuxChannelState.open);
      await a.close();
      await b.done;
      expect(b.openPayloadBytes, 0);
      expect(b.bufferedBytes, 0);
      await atB.cancel();
    });

    test('half a smaller receive high-water mark is the budget, so held '
        'payloads never keep the reading paused', () async {
      final (a, b) = muxPair(
        acceptor: quiet.copyWith(receiveHighWaterMarkBytes: 200),
      );
      final atB = StreamQueue(b.incoming);
      a.open(Uint8List(60));
      final refused = a.open(Uint8List(60));
      final second = a.open(Uint8List(40));
      await atB.next;
      final held = await atB.next;
      expect(held.openPayload, hasLength(40));
      expect(await refused.done, hasCode(StatusCode.resourceExhausted));
      expect(b.bufferedBytes, 100);
      expect(b.isReceivePaused, isFalse);
      // Unread data on top of them pauses it, and reading that data
      // resumes it although the payloads are still held.
      unawaited(second.send(Uint8List(120)));
      await pumpEventQueue();
      expect(b.isReceivePaused, isTrue);
      await held.stream.first;
      expect(b.bufferedBytes, 100);
      expect(b.isReceivePaused, isFalse);
      await a.close();
      await atB.cancel();
    });

    test(
      'a channel whose close is not confirmed releases its payload',
      () async {
        final (mux, raw) = rawPair(
          options: rawOptions.copyWith(
            closeConfirmTimeout: const Duration(milliseconds: 30),
          ),
        );
        raw.send(openHex(3, 50));
        final channel = await mux.incoming.first;
        expect(mux.openPayloadBytes, 50);
        await channel.close();
        expect(mux.openPayloadBytes, 0);
        expect(mux.bufferedBytes, 0);
        await mux.close();
        await raw.rest();
      },
    );
  });
}
