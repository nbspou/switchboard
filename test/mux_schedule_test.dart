/*
Polyverse Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Authors:
  Jan Boon <jan.boon@kaetemi.be>
  Claude Opus 5.5 <noreply@anthropic.com>
*/

// Output scheduling (wiki page "Polyverse Switchboard Mux", section "Output
// scheduling"): what waits for a transport that is not ready, and in which
// order it goes; bulk channels and their chunks.

import 'dart:async';
import 'dart:typed_data';

import 'package:async/async.dart';
import 'package:switchboard/src/mux/mux_channel.dart';
import 'package:switchboard/src/mux/mux_connection.dart';
import 'package:switchboard/src/mux/mux_frame.dart';
import 'package:switchboard/src/status.dart';
import 'package:switchboard/src/transport/stream_transport.dart';
import 'package:test/test.dart';

import 'mux_harness.dart';

bool isData(MuxFrame frame) =>
    frame.command == MuxCommand.data && frame.channelId != 0;

/// A subframe naming its channel and a sequence number.
Uint8List tagged(MuxChannel channel, int n) =>
    Uint8List.fromList([channel.id, n]);

/// The (channel, sequence number) of the DATA frames written so far.
List<(int, int)> order(GatedTransport gate) => [
  for (final frame in gate.written)
    if (isData(frame)) (frame.channelId, frame.payload[1]),
];

/// An output that takes one chunk, hands it to [target], and takes the
/// next only after [delay]: a socket whose peer reads at a fixed rate.
class RateSink implements StreamSink<List<int>> {
  RateSink(this.target, this.delay);

  final StreamSink<List<int>> target;
  final Duration delay;
  StreamSubscription<List<int>>? _subscription;

  @override
  Future<void> addStream(Stream<List<int>> stream) {
    final finished = Completer<void>();
    _subscription = stream.listen((chunk) {
      target.add(chunk);
      _subscription!.pause();
      Timer(delay, () => _subscription?.resume());
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
    await target.close();
  }

  @override
  Future<void> get done => target.done;
}

void main() {
  group('output scheduler', () {
    test('frames go straight out while the transport is ready', () async {
      final (a, b, gate) = gatedPair();
      addTearDown(a.close);
      gate.allow(1000);
      await a.ping();
      final channel = a.open(empty);
      await channel.send(tagged(channel, 0));
      expect(a.heldOutputBytes, 0);
      expect(order(gate), [(2, 0)]);
      expect(b.isOpen, isTrue);
    });

    test('control messages are never held', () async {
      final (a, b, gate) = gatedPair();
      addTearDown(a.close);
      final channel = a.open(empty);
      await channel.send(tagged(channel, 0));
      expect(a.heldOutputBytes, greaterThan(0));
      // The PING overtakes the DATA held for the transport, and so does
      // the OPEN of another channel.
      final pinged = a.ping();
      final other = a.open(empty);
      await pumpEventQueue();
      expect(
        gate.written.map((f) => (f.command, f.channelId)),
        containsAllInOrder([
          (MuxCommand.open, 2),
          (MuxCommand.data, 0),
          (MuxCommand.open, other.id),
        ]),
      );
      expect(order(gate), isEmpty);
      await pinged;
      gate.allow(1);
      await pumpEventQueue();
      expect(order(gate), [(2, 0)]);
      expect(a.heldOutputBytes, 0);
      expect(b.isOpen, isTrue);
    });

    test('ordinary channels take turns, one frame each', () async {
      final (a, _, gate) = gatedPair();
      addTearDown(a.close);
      final channels = [for (var i = 0; i < 3; i++) a.open(empty)];
      for (var n = 0; n < 3; n++) {
        for (final channel in channels) {
          await channel.send(tagged(channel, n));
        }
      }
      // Some more on the first channel only.
      for (var n = 3; n < 5; n++) {
        await channels[0].send(tagged(channels[0], n));
      }
      gate.allow(11);
      await pumpEventQueue();
      expect(order(gate), [
        (2, 0), (4, 0), (6, 0), //
        (2, 1), (4, 1), (6, 1), //
        (2, 2), (4, 2), (6, 2), //
        (2, 3), (2, 4),
      ]);
    });

    test('a bulk frame goes after bulkZipper ordinary ones while bulk work '
        'waits', () async {
      final (a, _, gate) = gatedPair(
        initiator: quiet.copyWith(bulkChunkSize: 10),
      );
      addTearDown(a.close);
      final bulk = a.open(empty)..priority = MuxPriority.bulk;
      final first = a.open(empty);
      final second = a.open(empty);
      // Five chunks of 10 bytes.
      await bulk.send(Uint8List(50)..fillRange(0, 50, bulk.id));
      for (var n = 0; n < 6; n++) {
        await first.send(tagged(first, n));
        await second.send(tagged(second, n));
      }
      gate.allow(17);
      await pumpEventQueue();
      final ids = [
        for (final frame in gate.written)
          if (isData(frame)) frame.channelId,
      ];
      const b = 2, o1 = 4, o2 = 6;
      expect(ids, [
        o1, o2, o1, o2, b, //
        o1, o2, o1, o2, b, //
        o1, o2, o1, o2, b, //
        b, b,
      ]);
      // The order within each channel is kept.
      expect(
        [
          for (final frame in gate.on(o1))
            if (isData(frame)) frame.payload[1],
        ],
        [0, 1, 2, 3, 4, 5],
      );
    });

    test(
      'a CLOSE follows the DATA queued before it, an OPEN does not wait',
      () async {
        final (a, b, gate) = gatedPair();
        addTearDown(a.close);
        final atB = StreamQueue(b.incoming);
        final channel = a.open(empty);
        await channel.send(tagged(channel, 0));
        await channel.send(tagged(channel, 1));
        final closed = channel.close();
        final later = a.open(empty);
        await pumpEventQueue();
        expect(
          gate.written.where((f) => f.channelId == 2).map((f) => f.command),
          [MuxCommand.open],
        );
        expect(gate.written.last.channelId, later.id);
        gate.allow(3);
        final atBChannel = await atB.next;
        expect(await atBChannel.stream.length, 2);
        await closed;
        expect(
          gate.written.where((f) => f.channelId == 2).map((f) => f.command),
          [MuxCommand.open, MuxCommand.data, MuxCommand.data, MuxCommand.close],
        );
        await atB.cancel();
      },
    );

    test('the peer\'s CLOSE drops what waits for the transport, and the '
        'confirmation goes at once', () async {
      final (a, b, gate) = gatedPair();
      addTearDown(a.close);
      final channel = a.open(empty);
      final atB = await b.incoming.first;
      for (var n = 0; n < 3; n++) {
        await channel.send(tagged(channel, n));
      }
      expect(a.heldOutputBytes, greaterThan(0));
      await atB.close(Status.of(StatusCode.cancelled));
      expect(await channel.done, hasCode(StatusCode.cancelled));
      expect(a.heldOutputBytes, 0);
      expect(order(gate), isEmpty);
      expect(gate.written.last.command, MuxCommand.close);
      gate.allow(10);
      await pumpEventQueue();
      expect(order(gate), isEmpty);
    });

    test('closing the connection writes the GOAWAY first, then what was '
        'held', () async {
      final (a, b, gate) = gatedPair();
      final channel = a.open(empty);
      final received = (await b.incoming.first).stream.toList();
      await channel.send(tagged(channel, 0));
      await channel.send(tagged(channel, 1));
      unawaited(a.goAway());
      await pumpEventQueue();
      final goAway = gate.written.indexWhere(
        (f) => isControl(f, MuxControlType.goAway),
      );
      expect(goAway, isNot(-1));
      expect(order(gate), isEmpty);
      await a.close();
      expect(order(gate), [(2, 0), (2, 1)]);
      expect(gate.written.indexWhere(isData), greaterThan(goAway));
      expect(await received, hasLength(2));
      expect(a.heldOutputBytes, 0);
    });
  });

  group('bulk channels', () {
    test('a payload is cut into chunks of bulkChunkSize', () async {
      final (a, b) = muxPair(acceptor: quiet.copyWith(initialWindow: 1 << 20));
      addTearDown(a.close);
      await a.ping();
      final channel = a.open(empty)..priority = MuxPriority.bulk;
      final atB = StreamQueue((await b.incoming.first).stream);
      final payload = Uint8List.fromList(
        List.generate(200000, (i) => i * 31 & 0xFF),
      );
      // The window takes it all: handed over at once.
      await channel.send(payload);
      final received = await atB.take(4);
      expect(received.map((d) => d.length), [65536, 65536, 65536, 3392]);
      expect(received.expand((d) => d).toList(), payload);
      // An empty one is one empty subframe.
      await channel.send(empty);
      expect(await atB.next, isEmpty);
      await atB.cancel();
    });

    test('chunks fit the window and the peer frame limit', () async {
      final (a, b) = muxPair(acceptor: quiet.copyWith(maxFrameSize: 1000));
      addTearDown(a.close);
      await a.ping();
      final limited = a.open(empty)..priority = MuxPriority.bulk;
      final atB = StreamQueue(b.incoming);
      final limitedAtB = await atB.next;
      await limited.send(Uint8List(2500));
      expect(await limitedAtB.stream.take(3).map((d) => d.length).toList(), [
        997,
        997,
        506,
      ]);
      // The default window, 64 KiB: each chunk takes what the window
      // allows, the transfer goes on as credit comes back.
      final wide = a.open(empty)..priority = MuxPriority.bulk;
      final wideAtB = await atB.next;
      final total = 300000;
      final payload = Uint8List.fromList(
        List.generate(total, (i) => i * 7 & 0xFF),
      );
      final sent = wide.send(payload);
      final received = <int>[];
      final sizes = <int>[];
      await for (final chunk in wideAtB.stream) {
        received.addAll(chunk);
        sizes.add(chunk.length);
        if (received.length == total) {
          break;
        }
      }
      await sent;
      expect(received, payload);
      for (final size in sizes) {
        expect(size, lessThanOrEqualTo(997));
      }
      await atB.cancel();
    });

    test(
      'a bulk send waits in order behind earlier ones and before a CLOSE',
      () async {
        final (a, b) = muxPair();
        addTearDown(a.close);
        await a.ping();
        final channel = a.open(empty)..priority = MuxPriority.bulk;
        final atB = await b.incoming.first;
        final all = atB.stream.fold<int>(0, (n, d) => n + d.length);
        final first = channel.send(Uint8List(100000));
        final second = channel.send(Uint8List(100000));
        unawaited(channel.close());
        await Future.wait([first, second]);
        expect(await all, 200000);
        expect(await channel.done, Status.ok);
      },
    );

    test(
      'an ordinary frame overtakes a transfer on a saturated transport',
      () async {
        // The initiator writes through a stream transport whose output takes
        // a chunk every 2 ms: the scheduler holds what the transport has not
        // taken.
        // Closed through the transports.
        // ignore: close_sinks
        final aToB = StreamController<List<int>>();
        // ignore: close_sinks
        final bToA = StreamController<List<int>>();
        final a = MuxConnection(
          StreamTransport.wrap(
            bToA.stream,
            RateSink(aToB.sink, const Duration(milliseconds: 2)),
          ),
          isInitiator: true,
          options: quiet,
        );
        final b = MuxConnection(
          StreamTransport.wrap(aToB.stream, bToA.sink),
          isInitiator: false,
          options: quiet.copyWith(initialWindow: 8 << 20),
        );
        addTearDown(() async {
          await a.close();
          await b.close();
        });
        await a.ping();
        await b.ping();
        final bulk = a.open(empty)..priority = MuxPriority.bulk;
        final normal = a.open(empty);
        final atB = StreamQueue(b.incoming);
        final bulkAtB = await atB.next;
        final normalAtB = StreamQueue((await atB.next).stream);
        var bulkBytes = 0;
        final transferred = bulkAtB.stream.listen((d) => bulkBytes += d.length);
        const total = 4 << 20;
        // The window takes it all at once: 64 chunks wait for the transport.
        final transfer = bulk.send(Uint8List(total));
        await transfer;
        expect(a.heldOutputBytes, greaterThan(total - 4 * 65536));
        final waits = <int>[];
        for (var i = 0; i < 5; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
          final before = bulkBytes;
          await normal.send(Uint8List(10));
          await normalAtB.next;
          waits.add(bulkBytes - before);
        }
        // Still transferring, and each ordinary frame waited for at most the
        // chunk the transport was writing and the one being read.
        expect(bulkBytes, lessThan(total));
        for (final wait in waits) {
          expect(wait, lessThanOrEqualTo(2 * 65536));
        }
        while (bulkBytes < total) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        await transferred.cancel();
        await atB.cancel();
        await normalAtB.cancel();
      },
    );
  });
}
