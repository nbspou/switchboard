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
import 'dart:io';
import 'dart:typed_data';

import 'package:async/async.dart';
import 'package:fake_async/fake_async.dart';
import 'package:logging/logging.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:switchboard/src/bytes.dart';
import 'package:switchboard/src/mux/mux_channel.dart';
import 'package:switchboard/src/mux/mux_connection.dart';
import 'package:switchboard/src/mux/mux_frame.dart';
import 'package:switchboard/src/status.dart';
import 'package:switchboard/src/transport/memory_transport.dart';
import 'package:switchboard/src/transport/stream_transport.dart';
import 'package:switchboard/src/transport/web_socket_transport.dart';
import 'package:switchboard/src/transport/web_socket_transport_io.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';

import 'mux_harness.dart';

void main() {
  test('a synchronous keep-alive reply and close leave no timer', () async {
    final timers = <Timer>[];
    addTearDown(() {
      for (final timer in timers) {
        timer.cancel();
      }
    });
    await runZoned(
      () async {
        final input = StreamController<Uint8List>(sync: true);
        // Closed through the mux transport's sink.
        // ignore: close_sinks
        final output = StreamController<Uint8List>(sync: true);
        final mux = MuxConnection(
          StreamChannel(input.stream, output.sink),
          isInitiator: true,
          options: rawOptions.copyWith(
            keepAliveInterval: const Duration(milliseconds: 5),
          ),
        );
        final closed = Completer<void>();
        final peer = output.stream.listen((bytes) {
          final message = MuxControlMessage.decode(
            MuxFrame.decode(bytes).payload,
          );
          if (message.knownType == MuxControlType.ping) {
            input.add(
              MuxControlMessage.pong(message.payload).toFrame().encode(),
            );
            closed.complete(mux.close());
          }
        });
        await closed.future;
        await peer.cancel();
        await input.close();
      },
      zoneSpecification: ZoneSpecification(
        createTimer: (self, parent, zone, duration, callback) {
          final timer = parent.createTimer(zone, duration, callback);
          timers.add(timer);
          return timer;
        },
      ),
    );
    expect(timers.where((timer) => timer.isActive), isEmpty);
  });

  group('channels', () {
    test('a synchronous CLOSE confirmation leaves no timer', () {
      fakeAsync((async) {
        final transport = StreamChannelController<Uint8List>(sync: true);
        final mux = MuxConnection(
          transport.local,
          isInitiator: true,
          options: rawOptions,
        );
        final peer = transport.foreign.stream.listen((bytes) {
          final frame = MuxFrame.decode(bytes);
          if (frame.command == MuxCommand.close) {
            transport.foreign.sink.add(
              MuxFrame.close(frame.channelId).encode(),
            );
          }
        });
        final channel = mux.open(empty);
        unawaited(channel.close());
        expect(channel.state, MuxChannelState.closed);
        async.flushMicrotasks();
        expect(async.nonPeriodicTimerCount, 0);
        unawaited(mux.close());
        unawaited(peer.cancel());
        async.flushMicrotasks();
      });
    });

    test('open from both sides, payloads and data both ways', () async {
      final (a, b) = muxPair();
      final aIncoming = StreamQueue(a.incoming);
      final bIncoming = StreamQueue(b.incoming);
      expect(a.isInitiator, isTrue);
      expect(b.isInitiator, isFalse);

      final ca = a.open(hexBytes('AA'));
      expect(ca.id, 2);
      expect(ca.isLocallyOpened, isTrue);
      expect(ca.connection, same(a));
      expect(ca.state, MuxChannelState.open);
      expect(ca.canSend, isTrue);
      final cb = b.open(hexBytes('BB CC'));
      expect(cb.id, 3);

      final ra = await bIncoming.next;
      expect(ra.id, 2);
      expect(ra.isLocallyOpened, isFalse);
      expect(hexString(ra.openPayload), 'AA');
      final rb = await aIncoming.next;
      expect(rb.id, 3);
      expect(hexString(rb.openPayload), 'BB CC');

      final raData = StreamQueue(ra.stream);
      final caData = StreamQueue(ca.stream);
      ca.send(hexBytes('01'));
      ca.sink.add(hexBytes('02 03'));
      ca.send(empty);
      ra.send(hexBytes('04'));
      expect(hexString(await raData.next), '01');
      expect(hexString(await raData.next), '02 03');
      expect(await raData.next, isEmpty);
      expect(hexString(await caData.next), '04');

      expect(a.openChannelCount, 2);
      expect(b.openChannelCount, 2);
      expect(a.channels, unorderedEquals([ca, rb]));
      expect(b.channels, unorderedEquals([cb, ra]));
      await a.close();
      await b.done;
    });

    test('close handshake started by the opener', () async {
      final (a, b) = muxPair();
      final bIncoming = StreamQueue(b.incoming);
      final ca = a.open(empty);
      final ra = await bIncoming.next;
      final raData = ra.stream.toList();

      final closing = ca.close();
      expect(ca.state, MuxChannelState.halfClosedLocal);
      expect(ca.canSend, isFalse);
      expect(() => ca.send(empty), throwsStatus(StatusCode.failedPrecondition));
      await closing;
      expect(ca.state, MuxChannelState.closed);
      expect(await ca.done, Status.ok);
      expect(await raData, isEmpty);
      expect(await ra.done, Status.ok);
      expect(ra.state, MuxChannelState.closed);
      expect(a.openChannelCount, 0);
      expect(b.openChannelCount, 0);
      expect(a.isOpen, isTrue);
      await a.close();
    });

    test('close handshake started by the accepting side', () async {
      final (a, b) = muxPair();
      final bIncoming = StreamQueue(b.incoming);
      final ca = a.open(empty);
      final ra = await bIncoming.next;
      final caData = ca.stream.toList();

      await ra.close(Status.of(StatusCode.notFound, 'x'));
      expect(await ra.done, Status.of(StatusCode.notFound, 'x'));
      expect(await caData, isEmpty);
      expect(await ca.done, Status.of(StatusCode.notFound, 'x'));
      expect(ca.state, MuxChannelState.closed);
      expect(() => ca.send(empty), throwsStatus(StatusCode.failedPrecondition));
      // The sink silently drops once the peer closed.
      ca.sink.add(hexBytes('01'));
      await ca.sink.close();
      expect(a.isOpen, isTrue);
      await a.close();
    });

    test('simultaneous close from both sides', () async {
      final (a, b) = muxPair();
      final bIncoming = StreamQueue(b.incoming);
      final ca = a.open(empty);
      final ra = await bIncoming.next;
      final c1 = ca.close(Status.of(StatusCode.aborted));
      final c2 = ra.close();
      await Future.wait([c1, c2]);
      expect(await ca.done, hasCode(StatusCode.aborted));
      expect(await ra.done, hasCode(StatusCode.aborted));
      await a.ping();
      expect(a.isOpen, isTrue);
      expect(b.isOpen, isTrue);
      expect(a.openChannelCount + b.openChannelCount, 0);
      await b.close();
    });

    test('data in flight is delivered after a local close', () async {
      final (a, b) = muxPair();
      final bIncoming = StreamQueue(b.incoming);
      final ca = a.open(empty);
      final ra = await bIncoming.next;
      final caData = ca.stream.map(hexString).toList();
      ra.send(hexBytes('05'));
      ra.send(hexBytes('06'));
      await ca.close();
      expect(await caData, ['05', '06']);
      await a.close();
    });

    test('sink close, sink done and addError', () async {
      final (a, b) = muxPair();
      final bIncoming = StreamQueue(b.incoming);
      final c1 = a.open(empty);
      final c2 = a.open(empty);
      final r1 = await bIncoming.next;
      final r2 = await bIncoming.next;

      await c1.sink.close();
      await c1.sink.done;
      expect(await r1.done, Status.ok);
      expect(() => c1.sink.add(empty), throwsStateError);

      c2.sink.addError(
        SwitchboardException.of(StatusCode.permissionDenied, 'no'),
      );
      expect(await r2.done, Status.of(StatusCode.permissionDenied, 'no'));
      expect(await c2.done, Status.of(StatusCode.permissionDenied, 'no'));

      final c3 = a.open(empty);
      final r3 = await bIncoming.next;
      c3.sink.addError(StateError('bug'));
      expect(await r3.done, hasCode(StatusCode.internal));
      await a.close();
    });

    test('sink addStream sends every subframe', () async {
      final (a, b) = muxPair();
      final bIncoming = StreamQueue(b.incoming);
      final ca = a.open(empty);
      final ra = await bIncoming.next;
      final received = ra.stream.map(hexString).toList();
      await ca.sink.addStream(
        Stream.fromIterable([hexBytes('01'), hexBytes('02')]),
      );
      await ca.sink.close();
      expect(await received, ['01', '02']);
      await a.close();
    });

    test('close is idempotent and completes after the fact', () async {
      final (a, b) = muxPair();
      final bIncoming = StreamQueue(b.incoming);
      final ca = a.open(empty);
      await bIncoming.next;
      final first = ca.close(Status.of(StatusCode.cancelled));
      final second = ca.close();
      await Future.wait([first, second]);
      await ca.close();
      expect(await ca.done, hasCode(StatusCode.cancelled));
      expect(() => ca.close(const Status(300)), throwsArgumentError);
      await a.close();
    });

    test('application status codes are refused for CLOSE', () async {
      final (a, _) = muxPair();
      final ca = a.open(empty);
      expect(() => ca.close(const Status(256)), throwsArgumentError);
      expect(ca.state, MuxChannelState.open);
      await a.close();
    });

    test('open payload is copied', () async {
      final (a, b) = muxPair();
      final bIncoming = StreamQueue(b.incoming);
      final payload = hexBytes('01 02');
      final ca = a.open(payload);
      payload[0] = 0xFF;
      expect(hexString(ca.openPayload), '01 02');
      expect(hexString((await bIncoming.next).openPayload), '01 02');
      await a.close();
    });

    test('wire bytes of a channel lifetime', () async {
      final (mux, raw) = rawPair(muxIsInitiator: false);
      final incoming = StreamQueue(mux.incoming);

      final channel = mux.open(hexBytes('AA'));
      expect(await raw.nextHex(), '12 03 00 AA');
      channel.send(hexBytes('01 02 03'));
      expect(await raw.nextHex(), '02 03 00 01 02 03');
      final closed = channel.close(Status.of(StatusCode.notFound, 'x'));
      expect(await raw.nextHex(), '22 03 00 05 00 78');
      raw.send('22 03 00');
      await closed;
      expect(await channel.done, Status.of(StatusCode.notFound, 'x'));

      raw.send('12 02 00 BB');
      final remote = await incoming.next;
      expect(remote.id, 2);
      raw.send('02 02 00 07');
      expect(hexString(await remote.stream.first), '07');
      raw.send('22 02 00 05 00 78');
      expect(await raw.nextHex(), '22 02 00');
      expect(await remote.done, Status.of(StatusCode.notFound, 'x'));

      final plain = mux.open(empty);
      expect(await raw.nextHex(), '12 05 00');
      unawaited(plain.close());
      expect(await raw.nextHex(), '22 05 00');
      raw.send('22 05 00 00 00');
      expect(await plain.done, Status.ok);
      await mux.close();
    });
  });

  group('rejection and limits', () {
    test(
      'peer OPEN beyond maxChannels gets CLOSE RESOURCE_EXHAUSTED',
      () async {
        final (a, b) = muxPair(
          acceptor: quiet.copyWith(maxChannels: 1, announceLimits: false),
        );
        final bIncoming = StreamQueue(b.incoming);
        final c1 = a.open(empty);
        final c2 = a.open(empty);
        // DATA racing the rejection is not an error.
        c2.send(hexBytes('01'));
        final c2Data = c2.stream.toList();
        expect(await c2.done, hasCode(StatusCode.resourceExhausted));
        expect(await c2Data, isEmpty);
        final r1 = await bIncoming.next;
        expect(r1.id, c1.id);
        await a.ping();
        expect(b.openChannelCount, 1);
        expect(a.openChannelCount, 1);
        expect(a.isOpen, isTrue);

        await c1.close();
        final c3 = a.open(empty);
        expect((await bIncoming.next).id, c3.id);
        await a.close();
      },
    );

    test('LIMITS announcement and peerLimits', () async {
      final (a, b) = muxPair(
        initiator: quiet.copyWith(maxFrameSize: 4096, maxChannels: 7),
      );
      expect(a.peerLimits, isNull);
      await b.ping();
      expect(b.peerLimits, const MuxLimits(maxFrameSize: 4096, maxChannels: 7));
      expect(
        a.peerLimits,
        const MuxLimits(
          maxFrameSize: MuxOptions.defaultMaxFrameSize,
          maxChannels: MuxOptions.defaultMaxChannels,
        ),
      );
      await a.close();
    });

    test('LIMITS is the first frame, byte exact', () async {
      final (mux, raw) = rawPair(
        options: rawOptions.copyWith(
          announceLimits: true,
          maxFrameSize: 4096,
          maxChannels: 7,
        ),
      );
      expect(await raw.nextHex(), '02 00 00 04 00 10 00 00 07 00 00 00');
      await mux.close();
    });

    test('no LIMITS when disabled', () async {
      final (a, b) = muxPair(initiator: quiet.copyWith(announceLimits: false));
      await b.ping();
      expect(b.peerLimits, isNull);
      expect(a.peerLimits, isNotNull);
      await a.close();
    });

    test('LIMITS mid-connection applies to later frames', () async {
      final (mux, raw) = rawPair();
      void announce(int maxFrameSize, int maxChannels) =>
          raw.transport.sink.add(
            MuxControlMessage.limits(
              MuxLimits(maxFrameSize: maxFrameSize, maxChannels: maxChannels),
            ).toFrame().encode(),
          );
      // Frames are handled in order: once the PONG is back, so is LIMITS.
      Future<void> settle() async {
        raw.send('02 00 00 01 5E');
        expect(await raw.nextHex(), '02 00 00 02 5E');
      }

      final channel = mux.open(empty);
      expect(await raw.nextHex(), '12 02 00');
      channel.send(Uint8List(200));
      expect((await raw.next()).payload, hasLength(200));

      announce(64, 1);
      await settle();
      expect(mux.peerLimits, const MuxLimits(maxFrameSize: 64, maxChannels: 1));
      expect(
        () => channel.send(Uint8List(62)),
        throwsStatus(StatusCode.frameTooLarge),
      );
      channel.send(Uint8List(61));
      expect((await raw.next()).encode(), hasLength(64));
      expect(() => mux.open(empty), throwsStatus(StatusCode.resourceExhausted));
      // The CLOSE reason is cut to the new limit.
      final closing = channel.close(Status.of(StatusCode.cancelled, 'z' * 100));
      final close = await raw.next();
      expect(close.command, MuxCommand.close);
      expect(close.encode(), hasLength(64));
      expect(
        Status.decode(close.payload),
        Status.of(StatusCode.cancelled, 'z' * 59),
      );
      raw.send('22 02 00');
      await closing;

      // Raised again: larger frames and more channels are back.
      announce(4096, 8);
      await settle();
      final second = mux.open(Uint8List(1000));
      expect((await raw.next()).payload, hasLength(1000));
      second.send(Uint8List(4000));
      expect((await raw.next()).payload, hasLength(4000));
      unawaited(second.close());
      expect(await raw.nextHex(), '22 04 00');
      raw.send('22 04 00');
      await second.done;

      // And GOAWAY fits the latest limit too.
      announce(32, 8);
      await settle();
      final goingAway = mux.goAway(
        Status.of(StatusCode.unavailable, 'w' * 100),
      );
      final goAway = await raw.next();
      expect(goAway.encode(), hasLength(32));
      expect(
        MuxControlMessage.decode(goAway.payload).goAwayStatus,
        Status.of(StatusCode.unavailable, 'w' * 26),
      );
      await goingAway;
      expect(await raw.rest(), isEmpty);
    });

    test('peer channel limit caps open() locally', () async {
      final (a, b) = muxPair(acceptor: quiet.copyWith(maxChannels: 1));
      await a.ping();
      a.open(empty);
      expect(() => a.open(empty), throwsStatus(StatusCode.resourceExhausted));
      await b.close();
    });

    test('peer frame limit is enforced on send and open', () async {
      final (a, b) = muxPair(acceptor: quiet.copyWith(maxFrameSize: 16));
      await a.ping();
      final channel = a.open(Uint8List(13));
      channel.send(Uint8List(13));
      expect(
        () => channel.send(Uint8List(14)),
        throwsStatus(StatusCode.frameTooLarge),
      );
      expect(
        () => a.open(Uint8List(14)),
        throwsStatus(StatusCode.frameTooLarge),
      );
      await a.ping();
      expect(b.isOpen, isTrue);
      await b.close();
    });

    test('frame over maxFrameSize ends the connection', () async {
      final (mux, raw) = rawPair(
        options: rawOptions.copyWith(maxFrameSize: 16),
      );
      raw.send('12 03 00');
      raw.send('02 03 00 ${'00 ' * 14}');
      final goAway = await raw.nextControl(MuxControlType.goAway);
      expect(goAway.goAwayStatus.known, StatusCode.frameTooLarge);
      expect(await mux.done, hasCode(StatusCode.frameTooLarge));
    });

    test('frame over the stream transport limit sends GOAWAY', () async {
      final toMux = StreamController<List<int>>();
      // Closed by the transport.
      // ignore: close_sinks
      final fromMux = StreamController<List<int>>();
      final mux = MuxConnection(
        StreamTransport.wrap(toMux.stream, fromMux.sink, maxFrameSize: 64),
        isInitiator: true,
        options: rawOptions,
      );
      final output = fromMux.stream.toList();
      toMux.add(StreamTransport.encodePreamble());
      // A length of 4096 and no body.
      toMux.add(hexBytes('00 10 00 00'));
      expect(await mux.done, hasCode(StatusCode.frameTooLarge));
      final frames = <Uint8List>[];
      StreamFrameDecoder().add([
        for (final chunk in await output) ...chunk,
      ], frames.add);
      expect(frames, hasLength(1));
      final goAway = MuxControlMessage.decode(
        MuxFrame.decode(frames[0]).payload,
      );
      expect(goAway.knownType, MuxControlType.goAway);
      expect(goAway.goAwayStatus.known, StatusCode.frameTooLarge);
      await toMux.close();
    });

    test('cancelling incoming rejects further OPENs', () async {
      final (a, b) = muxPair();
      a.open(empty);
      final first = await b.incoming.first;
      expect(first.id, 2);
      final late = a.open(empty);
      expect(await late.done, hasCode(StatusCode.unavailable));
      await a.close();
    });
  });

  group('channel ids', () {
    test('parity and increment', () async {
      final (a, b) = muxPair();
      expect([for (var i = 0; i < 3; i++) a.open(empty).id], [2, 4, 6]);
      expect([for (var i = 0; i < 3; i++) b.open(empty).id], [3, 5, 7]);
      await a.close();
    });

    test('reuse after mutual close, wrapping a short id space', () async {
      final (a, b) = muxPair(
        initiator: quiet.copyWith(shortIdsOnly: true, announceLimits: false),
        acceptor: quiet.copyWith(maxChannels: 0, shortIdsOnly: true),
      );
      final remote = <MuxChannel>[];
      b.incoming.listen(remote.add);
      // Even ids 2 to 0xFFFE.
      const count = 0xFFFE ~/ 2;
      final channels = [for (var i = 0; i < count; i++) a.open(empty)];
      expect(channels.first.id, 2);
      expect(channels.last.id, 0xFFFE);
      expect(() => a.open(empty), throwsStatus(StatusCode.resourceExhausted));
      await a.ping();
      expect(remote, hasLength(count));

      final victim = channels[99];
      expect(victim.id, 200);
      final closing = victim.close();
      // Half closed: the id is not free yet.
      expect(() => a.open(empty), throwsStatus(StatusCode.resourceExhausted));
      await closing;
      final reused = a.open(hexBytes('01'));
      expect(reused.id, 200);
      await a.ping();
      expect(remote.last.id, 200);
      expect(hexString(remote.last.openPayload), '01');
      expect(a.isOpen && b.isOpen, isTrue);
      await a.close();
    });

    test('allocation skips reserved short id 0xFFFF and wraps', () async {
      final (a, b) = muxPair(acceptor: quiet.copyWith(shortIdsOnly: true));
      b.nextChannelIdForTesting = 0xFFFD;
      expect(b.open(empty).id, 0xFFFD);
      expect(b.open(empty).id, 3);
      await a.close();
    });

    test('allocation skips reserved long ids and wraps', () async {
      final unlimited = quiet.copyWith(maxChannels: 0);
      final (a, b) = muxPair(initiator: unlimited, acceptor: unlimited);
      final atB = <MuxChannel>[];
      final atA = <MuxChannel>[];
      b.incoming.listen(atB.add);
      a.incoming.listen(atA.add);
      // The long range is only used once every short id is in use.
      for (var i = 0; i < 0x7FFF; i++) {
        a.open(empty);
      }
      a.nextChannelIdForTesting = 0xFFFEFFFFFFFE;
      expect(a.open(empty).id, 0xFFFEFFFFFFFE);
      expect(a.open(empty).id, 0xFFFF00000002);
      a.nextChannelIdForTesting = 0xFFFFFFFFFFFE;
      expect(a.open(empty).id, 0xFFFFFFFFFFFE);
      // Wraps within the long range.
      expect(a.open(empty).id, 0x10000);
      await a.ping();
      expect(atB.skip(0x7FFF).map((c) => c.id), [
        0xFFFEFFFFFFFE,
        0xFFFF00000002,
        0xFFFFFFFFFFFE,
        0x10000,
      ]);

      // Odd ids 3 to 0xFFFD, skipping the reserved 0xFFFF.
      for (var i = 0; i < 0x7FFE; i++) {
        b.open(empty);
      }
      b.nextChannelIdForTesting = 0xFFFFFFFFFFFD;
      expect(b.open(empty).id, 0xFFFFFFFFFFFD);
      expect(b.open(empty).id, 0x10001);
      await b.ping();
      expect(atA.skip(0x7FFE).map((c) => c.id), [0xFFFFFFFFFFFD, 0x10001]);
      expect(a.isOpen, isTrue);
      await a.close();
    });

    test('long ids use the long form on the wire', () async {
      final (mux, raw) = rawPair();
      for (var i = 0; i < 0x7FFF; i++) {
        mux.open(empty);
      }
      for (var i = 0; i < 0x7FFF; i++) {
        await raw.frames.next;
      }
      mux.open(hexBytes('AA'));
      expect(await raw.nextHex(), '10 00 00 01 00 00 00 AA');
      await mux.close();
    });

    test('ids wrap within the short range first', () async {
      final unlimited = quiet.copyWith(maxChannels: 0);
      final (a, b) = muxPair(acceptor: unlimited);
      b.incoming.listen((_) {});
      final channels = [for (var i = 0; i < 0x7FFF; i++) a.open(empty)];
      expect(channels.first.id, 2);
      expect(channels.last.id, 0xFFFE);
      // Every short id of our parity is in use: the next one is long.
      final long = a.open(empty);
      expect(long.id, 0x10000);
      // A freed short id is preferred over the long range again.
      await channels[10].close();
      expect(a.open(empty).id, channels[10].id);
      expect(a.open(empty).id, 0x10002);
      await a.ping();
      expect(a.isOpen && b.isOpen, isTrue);
      await a.close();
    });

    test('ids stay short over many channels to a short-id-only peer', () async {
      final (a, b) = muxPair(acceptor: quiet.copyWith(shortIdsOnly: true));
      b.incoming.listen((_) {});
      var largest = 0;
      // 40000 channels opened and closed, more than there are short ids.
      for (var round = 0; round < 40; round++) {
        final channels = [for (var i = 0; i < 1000; i++) a.open(empty)];
        for (final channel in channels) {
          largest = channel.id > largest ? channel.id : largest;
        }
        await Future.wait([for (final channel in channels) channel.close()]);
        for (final channel in channels) {
          expect(await channel.done, Status.ok);
        }
      }
      expect(largest, 0xFFFE);
      await a.ping();
      expect(a.isOpen && b.isOpen, isTrue);
      expect(a.open(empty).id, lessThan(0x10000));
      await a.close();
    });

    test('a long form id addresses a channel opened in short form', () async {
      final (mux, raw) = rawPair();
      raw.send('12 03 00');
      final channel = await mux.incoming.first;
      final data = StreamQueue(channel.stream);
      raw.send('00 03 00 00 00 00 00 77');
      expect(hexString(await data.next), '77');
      // CLOSE in the long form too.
      raw.send('20 03 00 00 00 00 00');
      expect(await raw.nextHex(), '22 03 00');
      expect(await channel.done, Status.ok);
      expect(await data.hasNext, isFalse);
      await mux.close();
    });

    test('shortIdsOnly refuses long form frames with UNSUPPORTED', () async {
      final (mux, raw) = rawPair(
        options: rawOptions.copyWith(shortIdsOnly: true),
      );
      raw.send('10 03 00 00 00 00 00');
      final goAway = await raw.nextControl(MuxControlType.goAway);
      expect(goAway.goAwayStatus.known, StatusCode.unsupported);
      expect(await mux.done, hasCode(StatusCode.unsupported));
    });
  });

  group('protocol errors', () {
    const cases = <(String, List<String>)>[
      ('DATA on an unknown channel', ['02 03 00 01']),
      ('OPEN on an id in use', ['12 03 00', '12 03 00']),
      ('OPEN with the wrong parity', ['12 02 00']),
      ('command 3', ['32 02 00']),
      ('OPEN on channel 0', ['12 00 00']),
      ('CLOSE on channel 0', ['22 00 00']),
      ('DATA on channel 1', ['02 01 00']),
      ('DATA on reserved id 0xFFFF', ['02 FF FF']),
      ('reserved flag', ['03 02 00']),
      ('truncated header', ['02 03']),
      ('CLOSE on an unknown channel', ['22 03 00']),
      (
        'DATA after the channel was closed',
        ['12 03 00', '22 03 00', '02 03 00'],
      ),
      ('CLOSE twice', ['12 03 00', '22 03 00', '22 03 00']),
      ('malformed CLOSE status', ['12 03 00', '22 03 00 05']),
      ('control message without type', ['02 00 00']),
      ('malformed GOAWAY', ['02 00 00 03 21']),
      ('malformed LIMITS', ['02 00 00 04 00 01']),
    ];

    for (final (name, frames) in cases) {
      test('$name: GOAWAY PROTOCOL_ERROR, close, stop processing', () async {
        final (mux, raw) = rawPair();
        final local = mux.open(empty);
        expect(await raw.nextHex(), '12 02 00');
        frames.forEach(raw.send);
        // Must not be answered: frames after the error are not processed.
        raw.send('02 00 00 01 AA');
        final rest = await raw.rest();
        final goAways = rest.where((f) => isControl(f, MuxControlType.goAway));
        expect(goAways, hasLength(1));
        expect(
          MuxControlMessage.decode(goAways.single.payload).goAwayStatus.known,
          StatusCode.protocolError,
        );
        expect(rest.where((f) => isControl(f, MuxControlType.pong)), isEmpty);
        expect(isControl(rest.last, MuxControlType.goAway), isTrue);
        expect(await mux.done, hasCode(StatusCode.protocolError));
        expect(await local.done, hasCode(StatusCode.connectionLost));
        expect(mux.isOpen, isFalse);
      });
    }

    test('control payload over 1024 bytes', () async {
      final (mux, raw) = rawPair();
      raw.send('02 00 00 01 ${'00 ' * 1025}');
      final goAway = await raw.nextControl(MuxControlType.goAway);
      expect(goAway.goAwayStatus.known, StatusCode.protocolError);
      expect(await mux.done, hasCode(StatusCode.protocolError));
    });

    test('OPEN on a locally half-closed id', () async {
      final (mux, raw) = rawPair();
      raw.send('12 03 00');
      final channel = await mux.incoming.first;
      unawaited(channel.close());
      expect(await raw.nextHex(), '22 03 00');
      // DATA in flight after our CLOSE is fine.
      raw.send('02 03 00 01');
      raw.send('12 03 00');
      final goAway = await raw.nextControl(MuxControlType.goAway);
      expect(goAway.goAwayStatus.known, StatusCode.protocolError);
      expect(await mux.done, hasCode(StatusCode.protocolError));
      expect(await channel.done, hasCode(StatusCode.connectionLost));
    });

    test('a broken channel handler does not affect the connection', () async {
      final (a, b) = muxPair();
      final bIncoming = StreamQueue(b.incoming);
      final c1 = a.open(empty);
      final c2 = a.open(empty);
      final r1 = await bIncoming.next;
      final r2 = await bIncoming.next;
      final errors = <Object>[];
      runZonedGuarded(() {
        r1.stream.listen((_) => throw StateError('application bug'));
      }, (error, _) => errors.add(error));
      final r2Data = StreamQueue(r2.stream);
      c1.send(hexBytes('01'));
      c2.send(hexBytes('02'));
      expect(hexString(await r2Data.next), '02');
      await a.ping();
      expect(errors, [isStateError]);
      expect(a.isOpen && b.isOpen, isTrue);
      await c1.close();
      expect(await r1.done, Status.ok);
      await a.close();
    });
  });

  group('control channel', () {
    test('PING/PONG round trip and ping() duration', () async {
      final (a, b) = muxPair();
      final rtt = await a.ping();
      expect(rtt, greaterThanOrEqualTo(Duration.zero));
      expect(rtt, lessThan(const Duration(seconds: 1)));
      final both = await Future.wait([
        b.ping(hexBytes('01')),
        b.ping(hexBytes('02')),
        b.ping(),
      ]);
      expect(both, hasLength(3));
      await a.close();
    });

    test('PING is answered with the same payload', () async {
      final (mux, raw) = rawPair();
      raw.send('02 00 00 01 DE AD');
      expect(await raw.nextHex(), '02 00 00 02 DE AD');
      // Unsolicited PONG and unknown types are ignored.
      raw.send('02 00 00 02 01');
      raw.send('02 00 00 7F 01 02');
      raw.send('02 00 00 01');
      expect(await raw.nextHex(), '02 00 00 02');
      expect(mux.isOpen, isTrue);
      await mux.close();
    });

    test('ping() sends PING and matches the PONG payload', () async {
      final (mux, raw) = rawPair();
      final pong = mux.ping(hexBytes('BE EF'));
      expect(await raw.nextHex(), '02 00 00 01 BE EF');
      raw.send('02 00 00 02 00');
      raw.send('02 00 00 02 BE EF');
      expect(await pong, isA<Duration>());
      await mux.close();
    });

    test('PINGs with 126 to 1024 byte payloads are answered', () async {
      final (mux, raw) = rawPair();
      for (final size in [126, 1000, 1024]) {
        final payload = Uint8List.fromList(
          List.generate(size, (i) => i & 0xFF),
        );
        raw.transport.sink.add(
          MuxControlMessage(
            MuxControlType.ping.code,
            payload,
          ).toFrame().encode(),
        );
        final pong = MuxControlMessage.decode((await raw.next()).payload);
        expect(pong.knownType, MuxControlType.pong);
        expect(pong.payload, payload);
      }
      expect(mux.isOpen, isTrue);
      await mux.close();
    });

    test('keep-alive PONGs over 125 bytes are accepted', () async {
      // The 125 byte PING limit binds senders; a receiver accepts control
      // payloads up to 1024 bytes, and any frame is a sign of life.
      final (mux, raw) = rawPair(
        options: rawOptions.copyWith(
          keepAliveInterval: const Duration(milliseconds: 20),
          keepAliveTimeout: const Duration(milliseconds: 200),
        ),
      );
      for (final size in [126, 1024]) {
        final ping = await raw.next();
        expect(isControl(ping, MuxControlType.ping), isTrue);
        raw.transport.sink.add(
          MuxControlMessage.pong(
            Uint8List.fromList(List.generate(size, (i) => i & 0xFF)),
          ).toFrame().encode(),
        );
      }
      // Neither a protocol error nor a missed answer: the next frame is
      // the next probe, not GOAWAY or the end of the connection.
      expect(isControl(await raw.next(), MuxControlType.ping), isTrue);
      expect(mux.isOpen, isTrue);
      await mux.close();
    });

    test('pending pings are bounded: the oldest fails with '
        'DEADLINE_EXCEEDED', () async {
      // A peer that withholds PONGs cannot make ping() accumulate.
      final (mux, raw) = rawPair();
      const max = MuxConnection.maxPendingPings;
      Matcher fails(StatusCode code) =>
          isA<SwitchboardException>().having((e) => e.code, 'code', code);
      final outcomes = [
        for (var i = 0; i <= max; i++)
          mux.ping().then<Object>((rtt) => rtt, onError: (Object e) => e),
      ];
      expect(await outcomes[0], fails(StatusCode.deadlineExceeded));
      final sent = [
        for (var i = 0; i <= max; i++)
          (await raw.nextControl(MuxControlType.ping)).payload,
      ];
      // The others still wait for their own PONGs.
      raw.transport.sink.add(
        MuxControlMessage.pong(sent[1]).toFrame().encode(),
      );
      expect(await outcomes[1], isA<Duration>());
      await mux.close();
      for (final outcome in outcomes.skip(2)) {
        expect(await outcome, isA<SwitchboardException>());
      }
    });

    test('ping payload over 125 bytes is refused', () async {
      final (a, _) = muxPair();
      expect(() => a.ping(Uint8List(126)), throwsArgumentError);
      await a.ping(Uint8List(125));
      await a.close();
    });

    test('pending ping fails when the connection ends', () async {
      final (mux, raw) = rawPair();
      final pong = mux.ping();
      await raw.next();
      await raw.transport.sink.close();
      await expectLater(pong, throwsStatus(StatusCode.connectionLost));
      await expectLater(
        mux.ping(),
        throwsStatus(StatusCode.failedPrecondition),
      );
    });

    test('second GOAWAY is ignored', () async {
      final (mux, raw) = rawPair();
      final incoming = StreamQueue(mux.incoming);
      raw.send('12 03 00');
      raw.send('02 00 00 03 21 00');
      raw.send('02 00 00 03 05 00');
      raw.send('02 00 00 01 01');
      expect(await raw.nextHex(), '02 00 00 02 01');
      expect(mux.peerGoingAway, isTrue);
      final channel = await incoming.next;
      // Idle after GOAWAY: the receiver confirms the CLOSE, then closes.
      raw.send('22 03 00');
      expect((await raw.rest()).map((f) => hexString(f.encode())), [
        '22 03 00',
      ]);
      expect(await channel.done, Status.ok);
      expect(await mux.done, Status.of(StatusCode.goingAway));
    });

    test('GOAWAY with another status is reported as GOING_AWAY', () async {
      final (mux, raw) = rawPair();
      raw.send('02 00 00 03 20 00 78');
      final status = await mux.done;
      expect(status.known, StatusCode.goingAway);
      expect(status.reason, contains('x'));
      await raw.rest();
    });
  });

  group('GOAWAY', () {
    test(
      'peer cannot open after GOAWAY; channels finish, then close',
      () async {
        final (a, b) = muxPair();
        final bIncoming = StreamQueue(b.incoming);
        final ca = a.open(empty);
        final rb = await bIncoming.next;
        final caData = StreamQueue(ca.stream);
        final rbData = StreamQueue(rb.stream);

        final goingAway = b.goAway();
        expect(b.isOpen, isFalse);
        expect(
          () => b.open(empty),
          throwsStatus(StatusCode.failedPrecondition),
        );
        await a.ping();
        expect(a.peerGoingAway, isTrue);
        expect(b.peerGoingAway, isFalse);
        expect(
          () => a.open(empty),
          throwsStatus(StatusCode.failedPrecondition),
        );

        ca.send(hexBytes('01'));
        expect(hexString(await rbData.next), '01');
        rb.send(hexBytes('02'));
        expect(hexString(await caData.next), '02');

        await ca.close();
        await goingAway;
        expect(await a.done, hasCode(StatusCode.goingAway));
        // The side that sent GOAWAY reports the status it sent.
        expect(await b.done, hasCode(StatusCode.goingAway));
        expect(await ca.done, Status.ok);
        expect(await rb.done, Status.ok);
      },
    );

    test('OPEN racing our GOAWAY is rejected with GOING_AWAY', () async {
      final (a, b) = muxPair();
      final bIncoming = StreamQueue(b.incoming);
      final keep = a.open(empty);
      final kept = await bIncoming.next;
      final goingAway = b.goAway();
      final racing = a.open(empty);
      expect(await racing.done, hasCode(StatusCode.goingAway));
      expect(b.openChannelCount, 1);
      await keep.close();
      await goingAway;
      expect(await kept.done, Status.ok);
    });

    test('grace expiry closes with channels still open', () async {
      final (a, b) = muxPair(
        acceptor: quiet.copyWith(goAwayGrace: const Duration(milliseconds: 30)),
      );
      final bIncoming = StreamQueue(b.incoming);
      final ca = a.open(empty);
      final rb = await bIncoming.next;
      final watch = Stopwatch()..start();
      await b.goAway(Status.of(StatusCode.unavailable, 'maintenance'));
      expect(watch.elapsed, greaterThan(const Duration(milliseconds: 20)));
      expect(await rb.done, hasCode(StatusCode.unavailable));
      expect(await ca.done, hasCode(StatusCode.goingAway));
      final status = await a.done;
      expect(status.known, StatusCode.goingAway);
      expect(status.reason, contains('maintenance'));
    });

    test('goAway with no channels closes at once', () async {
      final (mux, raw) = rawPair();
      await mux.goAway();
      final rest = await raw.rest();
      expect(rest.map((f) => hexString(f.encode())), ['02 00 00 03 21 00']);
      expect(await mux.done, hasCode(StatusCode.goingAway));
      await mux.goAway();
    });

    test('peerGoAwayStatus: the status the peer sent', () async {
      final (a, b) = muxPair();
      Status? seen;
      unawaited(a.peerGoAwayStatus.then((status) => seen = status));
      await a.ping();
      expect(seen, isNull);
      final keep = a.open(empty);
      final goingAway = b.goAway(Status.of(StatusCode.goingAway, 'deploy'));
      expect(
        await a.peerGoAwayStatus.timeout(const Duration(seconds: 5)),
        Status.of(StatusCode.goingAway, 'deploy'),
      );
      expect(a.peerGoingAway, isTrue);
      expect(a.isOpen, isTrue);
      await keep.close();
      await goingAway;
      // An error GOAWAY keeps its code here; done reports GOING_AWAY.
      final (c, d) = muxPair();
      final failing = d.goAway(Status.of(StatusCode.resourceExhausted, 'x'));
      expect(
        await c.peerGoAwayStatus.timeout(const Duration(seconds: 5)),
        Status.of(StatusCode.resourceExhausted, 'x'),
      );
      expect(await c.done, hasCode(StatusCode.goingAway));
      await failing;
    });

    test('peerGoAwayStatus never completes without a GOAWAY', () async {
      final (a, b) = muxPair();
      var completed = false;
      unawaited(a.peerGoAwayStatus.then((_) => completed = true));
      await b.close();
      expect(await a.done, hasCode(StatusCode.connectionLost));
      await pumpEventQueue();
      expect(completed, isFalse);
      // The side that sent GOAWAY never sees one.
      final (c, d) = muxPair();
      var dCompleted = false;
      unawaited(d.peerGoAwayStatus.then((_) => dCompleted = true));
      await d.goAway();
      await c.done;
      await pumpEventQueue();
      expect(dCompleted, isFalse);
    });

    test('application codes are refused for GOAWAY', () async {
      final (a, _) = muxPair();
      expect(() => a.goAway(const Status(1000)), throwsArgumentError);
      expect(a.isOpen, isTrue);
      await a.close();
    });
  });

  group('byte counters', () {
    test('sentBytes and receivedBytes count whole mux frames', () async {
      final (a, b) = muxPair(initiator: rawOptions, acceptor: rawOptions);
      expect(a.sentBytes, 0);
      expect(a.receivedBytes, 0);
      final bIncoming = StreamQueue(b.incoming);
      final ca = a.open(hexBytes('AA BB'));
      ca.send(Uint8List(100));
      final rb = await bIncoming.next;
      final data = StreamQueue(rb.stream);
      expect(await data.next, hasLength(100));
      final sent =
          MuxFrame.open(2, hexBytes('AA BB')).encode().length +
          MuxFrame.data(2, Uint8List(100)).encode().length;
      expect(a.sentBytes, sent);
      expect(b.receivedBytes, sent);
      rb.send(Uint8List(10));
      await ca.stream.first;
      expect(a.receivedBytes, MuxFrame.data(2, Uint8List(10)).encode().length);
      expect(b.sentBytes, a.receivedBytes);
      // Control frames count too.
      final before = a.sentBytes;
      await a.ping();
      expect(a.sentBytes, greaterThan(before));
      expect(b.receivedBytes, a.sentBytes);
      await a.close();
      await b.done;
    });
  });

  group('keep-alive', () {
    test('PING appears on an idle connection', () async {
      final (mux, raw) = rawPair(
        options: rawOptions.copyWith(
          keepAliveInterval: const Duration(milliseconds: 20),
          keepAliveTimeout: const Duration(seconds: 5),
        ),
      );
      for (var i = 0; i < 2; i++) {
        final ping = await raw.nextControl(MuxControlType.ping);
        raw.transport.sink.add(
          MuxControlMessage.pong(ping.payload).toFrame().encode(),
        );
      }
      expect(mux.isOpen, isTrue);
      await mux.close();
    });

    test('traffic postpones keep-alive PINGs', () async {
      final (mux, raw) = rawPair(
        options: rawOptions.copyWith(
          keepAliveInterval: const Duration(milliseconds: 80),
        ),
      );
      final timer = Timer.periodic(
        const Duration(milliseconds: 5),
        (_) => raw.send('02 00 00 7F'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      timer.cancel();
      await mux.close();
      final rest = await raw.rest();
      expect(rest.where((f) => isControl(f, MuxControlType.ping)), isEmpty);
    });

    test('any frame during the probe window cancels the timeout', () async {
      final (mux, raw) = rawPair(
        options: rawOptions.copyWith(
          keepAliveInterval: const Duration(milliseconds: 30),
          keepAliveTimeout: const Duration(milliseconds: 100),
        ),
      );
      final watch = Stopwatch()..start();
      // Longer than the probe window: without the rule the first probe
      // would end the connection.
      while (watch.elapsed < const Duration(milliseconds: 250)) {
        await raw.nextControl(MuxControlType.ping);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        // An unknown control type, not a PONG.
        raw.send('02 00 00 7F');
      }
      expect(mux.isOpen, isTrue);
      await mux.close();
    });

    test('a dead peer leads to CONNECTION_LOST', () async {
      final (mux, raw) = rawPair(
        options: rawOptions.copyWith(
          keepAliveInterval: const Duration(milliseconds: 20),
          keepAliveTimeout: const Duration(milliseconds: 20),
        ),
      );
      final channel = mux.open(empty);
      final status = await mux.done;
      expect(status.known, StatusCode.connectionLost);
      expect(await channel.done, hasCode(StatusCode.connectionLost));
      final rest = await raw.rest();
      expect(rest.where((f) => isControl(f, MuxControlType.ping)), isNotEmpty);
    });

    test('two live peers keep the connection open', () async {
      const options = MuxOptions(
        keepAliveInterval: Duration(milliseconds: 10),
        keepAliveTimeout: Duration(milliseconds: 20),
      );
      final (a, b) = muxPair(initiator: options, acceptor: options);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(a.isOpen && b.isOpen, isTrue);
      await a.close();
      await b.done;
    });

    test('a connection that ends while it starts arms no keep-alive', () {
      fakeAsync((async) {
        final transport = StreamChannelController<Uint8List>(sync: true);
        // A peer that hangs up on the LIMITS sent from the constructor.
        transport.foreign.stream.listen((_) {
          unawaited(transport.foreign.sink.close());
        });
        final mux = MuxConnection(
          transport.local,
          isInitiator: true,
          options: const MuxOptions(
            keepAliveInterval: Duration(seconds: 5),
            keepAliveTimeout: Duration(seconds: 1),
          ),
        );
        expect(mux.isOpen, isFalse);
        // Past the bound of the close on the transport.
        async.elapse(const Duration(seconds: 2));
        expect(async.nonPeriodicTimerCount, 0);
      });
    });
  });

  group('connection end', () {
    test('transport drop ends every channel with CONNECTION_LOST', () async {
      final (ta, tb) = MemoryTransport.pair();
      final a = MuxConnection(ta, isInitiator: true, options: quiet);
      final b = MuxConnection(tb, isInitiator: false, options: quiet);
      final aIncoming = StreamQueue(a.incoming);
      final bIncoming = StreamQueue(b.incoming);
      final local = a.open(empty);
      b.open(empty);
      final remote = await aIncoming.next;
      await bIncoming.next;
      final localData = local.stream.toList();
      final closing = remote.close();

      await tb.sink.close();
      expect(await a.done, Status.of(StatusCode.connectionLost));
      expect(await b.done, Status.of(StatusCode.connectionLost));
      await closing;
      for (final channel in [local, remote]) {
        expect(await channel.done, hasCode(StatusCode.connectionLost));
        expect(channel.state, MuxChannelState.closed);
        await channel.close();
      }
      expect(await localData, isEmpty);
      expect(a.openChannelCount, 0);
      expect(a.channels, isEmpty);
      expect(a.isOpen, isFalse);
      expect(await aIncoming.hasNext, isFalse);
      expect(() => a.open(empty), throwsStatus(StatusCode.failedPrecondition));
      await a.close();
    });

    test('close() ends channels, is idempotent and never throws', () async {
      final (a, b) = muxPair();
      final channel = a.open(empty);
      final c1 = a.close();
      final c2 = a.close();
      await Future.wait([c1, c2]);
      expect(await channel.done, hasCode(StatusCode.connectionLost));
      expect(await b.done, hasCode(StatusCode.connectionLost));
      await b.close();
      await a.goAway();
    });

    test('close() over a failed transport', () async {
      final (ta, tb) = MemoryTransport.pair();
      final mux = MuxConnection(ta, isInitiator: true, options: quiet);
      tb.sink.addError(StateError('gone'));
      await expectLater(tb.sink.done, throwsStateError);
      await mux.close();
      expect(await mux.done, hasCode(StatusCode.connectionLost));
    });

    test('incoming channels are buffered until listened to', () async {
      final (a, b) = muxPair();
      for (var i = 0; i < 3; i++) {
        a.open(Uint8List.fromList([i])).send(Uint8List.fromList([i + 10]));
      }
      await a.ping();
      final channels = await b.incoming.take(3).toList();
      expect(channels.map((c) => c.openPayload.single), [0, 1, 2]);
      for (final (i, channel) in channels.indexed) {
        expect((await channel.stream.first).single, i + 10);
      }
      await a.close();
    });

    test('re-entrant close from handlers', () async {
      final (a, b) = muxPair();
      final channel = a.open(empty);
      final done = Completer<void>();
      b.incoming.listen((remote) {
        remote.stream.listen((_) {
          unawaited(remote.close());
          unawaited(b.close().then((_) => done.complete()));
        });
      });
      channel.send(hexBytes('01'));
      await done.future;
      expect(await channel.done, isA<Status>());
      expect(await a.done, hasCode(StatusCode.connectionLost));
    });
  });

  group('transport failures end to end', () {
    /// Runs a mux over a byte pipe fed with [input]; returns its end status
    /// and the control messages it sent.
    Future<(Status, List<MuxControlMessage>)> overBytes(Uint8List input) async {
      final toMux = StreamController<List<int>>();
      // Closed through the transport.
      // ignore: close_sinks
      final fromMux = StreamController<List<int>>();
      final output = fromMux.stream.toList();
      final mux = MuxConnection(
        StreamTransport.wrap(toMux.stream, fromMux.sink),
        isInitiator: false,
        options: rawOptions,
      );
      toMux.add(input);
      final status = await mux.done;
      final frames = <Uint8List>[];
      StreamFrameDecoder().add([
        for (final chunk in await output) ...chunk,
      ], frames.add);
      await toMux.close();
      return (
        status,
        [
          for (final frame in frames)
            MuxControlMessage.decode(MuxFrame.decode(frame).payload),
        ],
      );
    }

    test('wrong preamble magic: GOAWAY PROTOCOL_ERROR', () async {
      final (status, sent) = await overBytes(
        hexBytes('53 57 42 58 01 00 00 00'),
      );
      expect(status, hasCode(StatusCode.protocolError));
      expect(sent.single.knownType, MuxControlType.goAway);
      expect(sent.single.goAwayStatus.known, StatusCode.protocolError);
    });

    test('unsupported preamble version: GOAWAY UNSUPPORTED', () async {
      final (status, sent) = await overBytes(
        StreamTransport.encodePreamble(version: 2),
      );
      expect(status, hasCode(StatusCode.unsupported));
      expect(sent.single.knownType, MuxControlType.goAway);
      expect(sent.single.goAwayStatus.known, StatusCode.unsupported);
    });

    group('WebSocket', () {
      late HttpServer http;
      late StreamController<MuxConnection> servers;
      // Closed by the server.
      // ignore: close_sinks
      late WebSocket ws;

      setUp(() async {
        http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        servers = StreamController<MuxConnection>();
        http.listen((request) async {
          servers.add(
            MuxConnection(
              await IOWebSocketTransport.upgrade(request, maxFrameSize: 64),
              isInitiator: false,
              options: rawOptions,
            ),
          );
        });
        ws = await WebSocket.connect(
          'ws://127.0.0.1:${http.port}/',
          protocols: [WebSocketTransport.subprotocol],
        );
      });

      tearDown(() async {
        await servers.close();
        await http.close(force: true);
      });

      Future<void> expectGoAway(StatusCode code) async {
        final received = ws.toList();
        final server = await servers.stream.first;
        expect(await server.done, hasCode(code));
        final messages = await received;
        final goAway = MuxControlMessage.decode(
          MuxFrame.decode(messages.single as Uint8List).payload,
        );
        expect(goAway.knownType, MuxControlType.goAway);
        expect(goAway.goAwayStatus.known, code);
        expect(ws.closeCode, WebSocketTransport.normalClosure);
      }

      test('a text message: GOAWAY PROTOCOL_ERROR', () async {
        ws.add('hello');
        await expectGoAway(StatusCode.protocolError);
      });

      test('a message over the limit: GOAWAY FRAME_TOO_LARGE', () async {
        ws.add(Uint8List(65));
        await expectGoAway(StatusCode.frameTooLarge);
      });
    });

    test(
      'memory transport limit: the sender sees GOAWAY FRAME_TOO_LARGE',
      () async {
        final (ta, tb) = MemoryTransport.pair(maxFrameSize: 64);
        final mux = MuxConnection(tb, isInitiator: false, options: rawOptions);
        final raw = RawPeer(ta);
        raw.send('02 02 00 ${'00 ' * 67}');
        expect(await mux.done, hasCode(StatusCode.frameTooLarge));
        final rest = await raw.rest();
        expect(rest, hasLength(1));
        final goAway = MuxControlMessage.decode(rest.single.payload);
        expect(goAway.knownType, MuxControlType.goAway);
        expect(goAway.goAwayStatus.known, StatusCode.frameTooLarge);
      },
    );

    test(
      'a transport limit below maxFrameSize: warned about and announced',
      () async {
        final records = <LogRecord>[];
        final logs = Logger.root.onRecord.listen(records.add);
        final (ta, tb) = MemoryTransport.pair(maxFrameSize: 512);
        final a = MuxConnection(ta, isInitiator: true, options: quiet);
        final b = MuxConnection(tb, isInitiator: false, options: quiet);
        await a.ping();
        expect(a.peerLimits?.maxFrameSize, 512);
        expect(b.peerLimits?.maxFrameSize, 512);
        expect(
          records.where(
            (r) =>
                r.level == Level.WARNING &&
                r.loggerName == 'Switchboard.Mux' &&
                r.message.contains('512'),
          ),
          hasLength(2),
        );
        await logs.cancel();
        await a.close();
        await b.done;
      },
    );
  });

  group('real transports', () {
    Future<void> exercise(MuxConnection client, MuxConnection server) async {
      final serverIncoming = StreamQueue(server.incoming);
      final channel = client.open(hexBytes('AA'));
      final accepted = await serverIncoming.next;
      expect(accepted.id, 2);
      expect(hexString(accepted.openPayload), 'AA');
      final echo = accepted.stream.listen(accepted.send);
      final replies = StreamQueue(channel.stream);
      final big = Uint8List(100000)..fillRange(0, 100000, 7);
      channel.send(hexBytes('01 02'));
      channel.send(big);
      expect(hexString(await replies.next), '01 02');
      expect(await replies.next, big);
      final back = server.open(hexBytes('BB'));
      expect(back.id, 3);
      await channel.close(Status.of(StatusCode.cancelled));
      expect(await accepted.done, hasCode(StatusCode.cancelled));
      await echo.cancel();
      await back.close();
      expect(await client.ping(), isA<Duration>());
      await server.goAway();
      expect(await client.done, hasCode(StatusCode.goingAway));
      expect(await server.done, hasCode(StatusCode.goingAway));
    }

    test('TCP', () async {
      final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final accepted = listener.first;
      final client = MuxConnection(
        await StreamTransport.connectTcp('127.0.0.1', listener.port),
        isInitiator: true,
        options: quiet,
      );
      final server = MuxConnection(
        StreamTransport.fromSocket(await accepted),
        isInitiator: false,
        options: quiet,
      );
      await exercise(client, server);
      await listener.close();
    });

    test('TCP: GOAWAY reaches a peer that is still sending', () async {
      // The server sends GOAWAY behind 4 MB of data and closes at once,
      // while the client keeps its socket full. Closing a socket with
      // unread input resets the connection, and the reset destroys the
      // GOAWAY in flight; fromSocket lingers (reads and discards until the
      // client closes) so the client ends with GOING_AWAY, not
      // CONNECTION_LOST.
      final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final accepted = listener.first;
      final clientTransport = await StreamTransport.connectTcp(
        '127.0.0.1',
        listener.port,
      );
      final client = MuxConnection(
        clientTransport,
        isInitiator: true,
        options: quiet,
      );
      final server = MuxConnection(
        StreamTransport.fromSocket(await accepted),
        isInitiator: false,
        options: quiet,
      );
      await listener.close();
      final channel = client.open(empty);
      final chunk = Uint8List(64 * 1024);
      // At most 1 MiB queued: the socket stays full, memory bounded.
      final flood = Timer.periodic(const Duration(milliseconds: 1), (_) {
        for (var i = 0; i < 32; i++) {
          if (!channel.canSend ||
              clientTransport.bufferedOutputBytes > 1 << 20) {
            return;
          }
          channel.send(chunk);
        }
      });
      addTearDown(flood.cancel);
      final fromServer = channel.stream.drain<void>();
      final serverSide = await server.incoming.first;
      final toServer = serverSide.stream.drain<void>();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      for (var i = 0; i < 64; i++) {
        serverSide.send(chunk);
      }
      final goingAway = server.goAway();
      await server.close();
      expect(await client.done, hasCode(StatusCode.goingAway));
      expect(client.peerGoingAway, isTrue);
      expect(await channel.done, hasCode(StatusCode.goingAway));
      await goingAway;
      await Future.wait([fromServer, toServer]);
    });

    test('WebSocket', () async {
      final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final servers = StreamController<MuxConnection>();
      http.listen((request) async {
        // Closed through the transport.
        // ignore: close_sinks
        final ws = await WebSocketTransformer.upgrade(
          request,
          protocolSelector: (_) => WebSocketTransport.subprotocol,
        );
        servers.add(
          MuxConnection(
            WebSocketTransport.wrap(IOWebSocketChannel(ws)),
            isInitiator: false,
            options: quiet,
          ),
        );
      });
      final client = MuxConnection(
        await WebSocketTransport.connect(
          Uri.parse('ws://127.0.0.1:${http.port}/'),
        ),
        isInitiator: true,
        options: quiet,
      );
      final server = await servers.stream.first;
      await servers.close();
      await exercise(client, server);
      await http.close(force: true);
    });
  });
}
