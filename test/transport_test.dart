// The byte pipes and WebSockets below are closed through the transports
// under test, which the close_sinks lint cannot see.
// ignore_for_file: close_sinks

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:async/async.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:switchboard/src/bytes.dart';
import 'package:switchboard/src/status.dart';
import 'package:switchboard/src/transport/memory_transport.dart';
import 'package:switchboard/src/transport/stream_transport.dart';
import 'package:switchboard/src/transport/transport_capabilities.dart';
import 'package:switchboard/src/transport/web_socket_transport.dart';
import 'package:switchboard/src/transport/web_socket_transport_io.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';

const preambleHex = '53 57 42 44 01 00 00 00';

/// Re-chunks a byte stream into pieces of [size] bytes.
StreamTransformer<T, List<int>> rechunk<T extends List<int>>(int size) =>
    StreamTransformer<T, List<int>>.fromHandlers(
      handleData: (data, sink) {
        for (var i = 0; i < data.length; i += size) {
          sink.add(data.sublist(i, min(i + size, data.length)));
        }
      },
    );

/// Two byte pipes wrapped as stream transports.
(StreamChannel<Uint8List>, StreamChannel<Uint8List>) streamPair({
  int maxFrameSize = StreamTransport.defaultMaxFrameSize,
  StreamTransformer<List<int>, List<int>>? transformer,
}) {
  final aToB = StreamController<List<int>>();
  final bToA = StreamController<List<int>>();
  Stream<List<int>> wrapInput(Stream<List<int>> s) =>
      transformer == null ? s : s.transform(transformer);
  final a = StreamTransport.wrap(
    wrapInput(bToA.stream),
    aToB.sink,
    maxFrameSize: maxFrameSize,
  );
  final b = StreamTransport.wrap(
    wrapInput(aToB.stream),
    bToA.sink,
    maxFrameSize: maxFrameSize,
  );
  return (a, b);
}

/// A transport whose peer is driven with raw bytes.
class RawPeer {
  RawPeer({int maxFrameSize = StreamTransport.defaultMaxFrameSize}) {
    transport = StreamTransport.wrap(
      toTransport.stream,
      fromTransport.sink,
      maxFrameSize: maxFrameSize,
    );
    output = StreamQueue(
      fromTransport.stream.expand((chunk) => chunk).map((b) => b),
    );
    // The peer goes away with the test: a transport closing its output
    // would otherwise wait for a reader until its close timeout.
    addTearDown(output.cancel);
  }

  final StreamController<List<int>> toTransport = StreamController();
  final StreamController<List<int>> fromTransport = StreamController();
  late final StreamChannel<Uint8List> transport;

  /// Bytes written by the transport, one byte per event.
  late final StreamQueue<int> output;

  Future<String> read(int count) async => hexString(await output.take(count));
}

Uint8List bytesOf(int length, [int seed = 0]) =>
    Uint8List.fromList(List.generate(length, (i) => (i * 31 + seed) & 0xFF));

Matcher isStatusError(StatusCode code) =>
    isA<SwitchboardException>().having((e) => e.code, 'code', code);

void main() {
  group('MemoryTransport', () {
    test('frames flow both ways in order and are copied', () async {
      final (a, b) = MemoryTransport.pair();
      final qa = StreamQueue(a.stream);
      final qb = StreamQueue(b.stream);
      final frame = hexBytes('02 02 00 01');
      a.sink.add(frame);
      frame[3] = 0xFF;
      a.sink.add(hexBytes('02 02 00 02'));
      b.sink.add(hexBytes('02 03 00 03'));
      expect(hexString(await qb.next), '02 02 00 01');
      expect(hexString(await qb.next), '02 02 00 02');
      expect(hexString(await qa.next), '02 03 00 03');
      await a.sink.close();
      expect(await qa.hasNext, isFalse);
      expect(await qb.hasNext, isFalse);
    });

    test('closing one side ends both streams and drops later frames', () async {
      final (a, b) = MemoryTransport.pair();
      final bDone = b.stream.toList();
      final aDone = a.stream.toList();
      await b.sink.close();
      expect(await aDone, isEmpty);
      expect(await bDone, isEmpty);
      // The other sink silently drops after the stream closed.
      a.sink.add(hexBytes('02 02 00'));
      await a.sink.close();
      await a.sink.done;
    });

    test('delay keeps order and delivers the close last', () async {
      final (a, b) = MemoryTransport.pair(
        delay: const Duration(milliseconds: 5),
      );
      final received = b.stream.map(hexString).toList();
      final watch = Stopwatch()..start();
      a.sink
        ..add(hexBytes('01'))
        ..add(hexBytes('02'))
        ..add(hexBytes('03'));
      await a.sink.close();
      expect(await received, ['01', '02', '03']);
      expect(
        watch.elapsed,
        greaterThanOrEqualTo(const Duration(milliseconds: 4)),
      );
    });

    test('maxFrameSize fails the receiving side', () async {
      final (a, b) = MemoryTransport.pair(maxFrameSize: 4);
      final queue = StreamQueue(b.stream);
      a.sink
        ..add(hexBytes('01 02 03 04'))
        ..add(hexBytes('01 02 03 04 05'));
      expect(hexString(await queue.next), '01 02 03 04');
      await expectLater(
        queue.next,
        throwsA(
          isA<SwitchboardException>().having(
            (e) => e.code,
            'code',
            StatusCode.frameTooLarge,
          ),
        ),
      );
      expect(await queue.hasNext, isFalse);
      expect(await a.stream.isEmpty, isTrue);
    });

    test('maxFrameSize keeps the failed side writable until it '
        'reacted', () async {
      final (a, b) = MemoryTransport.pair(maxFrameSize: 8);
      expect((a as FrameLimited).maxFrameSize, 8);
      expect((b as FrameLimited).maxFrameSize, 8);
      final qa = StreamQueue(a.stream);
      final data = <Uint8List>[];
      final errors = <Object>[];
      final bDone = Completer<void>();
      b.stream.listen(
        data.add,
        onError: (Object e) {
          errors.add(e);
          // A mux layer sends GOAWAY from here; it must reach the sender.
          b.sink.add(hexBytes('02 00 00 03 23 00'));
        },
        onDone: bDone.complete,
      );
      a.sink
        ..add(Uint8List(9))
        // Dropped: the receiving side has failed.
        ..add(hexBytes('01'));
      await bDone.future;
      expect(data, isEmpty);
      expect(errors.single, isStatusError(StatusCode.frameTooLarge));
      expect(hexString(await qa.next), '02 00 00 03 23 00');
      // Closed on b's behalf once its listener saw the end.
      expect(await qa.hasNext, isFalse);
      await b.sink.done;
    });

    test('without maxFrameSize there is no limit', () {
      final (a, b) = MemoryTransport.pair();
      expect((a as FrameLimited).maxFrameSize, 0);
      unawaited(b.sink.close());
    });

    test('addError closes the pair and fails done', () async {
      final (a, b) = MemoryTransport.pair();
      a.sink.addError(StateError('boom'));
      await expectLater(a.sink.done, throwsStateError);
      expect(await b.stream.isEmpty, isTrue);
    });

    test('done after addError is one future, failed once', () async {
      final (a, _) = MemoryTransport.pair();
      a.sink.addError(StateError('boom'));
      // Reading done again, or closing, gives the same future, and leaving
      // it unobserved is not an unhandled error.
      final done = a.sink.done;
      expect(identical(a.sink.done, done), isTrue);
      expect(identical(a.sink.close(), done), isTrue);
      await pumpEventQueue();
      await expectLater(done, throwsStateError);
    });
  });

  group('StreamTransport over byte pipes', () {
    test('writes the preamble immediately', () async {
      final peer = RawPeer();
      expect(await peer.read(8), preambleHex);
      peer.transport.sink.add(hexBytes('02 02 00 AA'));
      expect(await peer.read(8), '04 00 00 00 02 02 00 AA');
      // Closing completes once the output has been drained.
      final closed = peer.transport.sink.close();
      expect(await peer.output.hasNext, isFalse);
      await closed;
    });

    test('round trip between two wrapped endpoints', () async {
      final (a, b) = streamPair();
      final qa = StreamQueue(a.stream);
      final qb = StreamQueue(b.stream);
      a.sink
        ..add(hexBytes('02 02 00 01'))
        ..add(bytesOf(70000));
      b.sink.add(hexBytes('02 03 00 02'));
      expect(hexString(await qb.next), '02 02 00 01');
      expect(await qb.next, bytesOf(70000));
      expect(hexString(await qa.next), '02 03 00 02');
      final closed = a.sink.close();
      expect(await qb.hasNext, isFalse);
      expect(await qa.hasNext, isFalse);
      await closed;
      await b.sink.done;
    });

    test('several frames in one chunk', () async {
      final peer = RawPeer();
      final queue = StreamQueue(peer.transport.stream);
      peer.toTransport.add(
        hexBytes(
          '$preambleHex 01 00 00 00 AA 02 00 00 00 BB CC '
          '03 00 00 00 DD EE FF',
        ),
      );
      expect(hexString(await queue.next), 'AA');
      expect(hexString(await queue.next), 'BB CC');
      expect(hexString(await queue.next), 'DD EE FF');
      unawaited(peer.toTransport.close());
      expect(await queue.hasNext, isFalse);
    });

    test('one byte chunks', () async {
      final (a, b) = streamPair(transformer: rechunk(1));
      final received = b.stream.toList();
      // Read too, so that b's output has a reader when b closes it.
      final returned = a.stream.toList();
      final frames = [for (var i = 1; i < 40; i++) bytesOf(i, i)];
      frames.forEach(a.sink.add);
      await a.sink.close();
      expect(await received, frames);
      expect(await returned, isEmpty);
    });

    test('arbitrary chunk boundaries', () async {
      final random = Random(7);
      final frames = [
        for (var i = 0; i < 200; i++) bytesOf(1 + random.nextInt(3000), i),
      ];
      final peer = RawPeer();
      final received = peer.transport.stream.toList();
      final all = BytesBuilder()..add(StreamTransport.encodePreamble());
      for (final f in frames) {
        all.add(StreamTransport.encodeFrame(f));
      }
      final bytes = all.takeBytes();
      var pos = 0;
      while (pos < bytes.length) {
        final n = min(1 + random.nextInt(5000), bytes.length - pos);
        peer.toTransport.add(bytes.sublist(pos, pos + n));
        pos += n;
      }
      await peer.toTransport.close();
      expect(await received, frames);
    });

    for (final (name, hex, code) in [
      (
        'wrong magic',
        '53 57 42 58 01 00 00 00 01 00 00 00 AA',
        StatusCode.protocolError,
      ),
      (
        'unsupported version',
        '53 57 42 44 02 00 00 00 01 00 00 00 AA',
        StatusCode.unsupported,
      ),
      (
        'zero length frame',
        '$preambleHex 00 00 00 00',
        StatusCode.protocolError,
      ),
    ]) {
      test('$name fails the stream with ${code.name}', () async {
        final peer = RawPeer();
        final queue = StreamQueue(peer.transport.stream);
        expect(await peer.read(8), preambleHex);
        peer.toTransport.add(hexBytes(hex));
        await expectLater(
          queue.next,
          throwsA(
            isA<SwitchboardException>().having((e) => e.code, 'code', code),
          ),
        );
        expect(await queue.hasNext, isFalse);
        // Output closes once the error and the end were delivered.
        expect(await peer.output.hasNext, isFalse);
      });
    }

    test('frame over the limit fails with FRAME_TOO_LARGE', () async {
      final peer = RawPeer(maxFrameSize: 16);
      final events = <Object>[];
      final done = Completer<void>();
      peer.transport.stream.listen(
        events.add,
        onError: (Object e) {
          events.add(e);
          // A mux layer sends GOAWAY from here; it must still go out.
          peer.transport.sink.add(hexBytes('02 00 00 03 23 00'));
        },
        onDone: done.complete,
      );
      // Length only: the body is never needed to fail.
      peer.toTransport.add(hexBytes('$preambleHex 01 00 00 00 AA 11 00 00 00'));
      await done.future;
      expect(events, hasLength(2));
      expect(hexString(events[0] as Uint8List), 'AA');
      expect(
        events[1],
        isA<SwitchboardException>().having(
          (e) => e.code,
          'code',
          StatusCode.frameTooLarge,
        ),
      );
      expect(await peer.read(8), preambleHex);
      expect(await peer.read(10), '06 00 00 00 02 00 00 03 23 00');
      expect(await peer.output.hasNext, isFalse);
    });

    test('input end closes the stream and the output', () async {
      final peer = RawPeer();
      final queue = StreamQueue(peer.transport.stream);
      peer.toTransport.add(hexBytes('$preambleHex 01 00 00 00 AA 05 00'));
      expect(hexString(await queue.next), 'AA');
      unawaited(peer.toTransport.close());
      expect(await queue.hasNext, isFalse);
      expect(await peer.read(8), preambleHex);
      expect(await peer.output.hasNext, isFalse);
      // Silently dropped after the stream closed.
      peer.transport.sink.add(hexBytes('01'));
      await peer.transport.sink.close();
    });

    test('closing the sink ends the stream', () async {
      final peer = RawPeer();
      final received = peer.transport.stream.toList();
      final closed = peer.transport.sink.close();
      peer.toTransport.add(hexBytes('$preambleHex 01 00 00 00 AA'));
      expect(await received, isEmpty);
      expect(await peer.read(8), preambleHex);
      expect(await peer.output.hasNext, isFalse);
      await closed;
    });

    test('the static codec helpers are the stream framing ones', () {
      expect(StreamTransport.encodePreamble(), StreamFraming.encodePreamble());
      expect(
        StreamTransport.encodePreamble(version: 2, flags: 0x0102),
        StreamFraming.encodePreamble(version: 2, flags: 0x0102),
      );
      expect(
        StreamTransport.encodeFrame([1, 2]),
        StreamFraming.encodeFrame([1, 2]),
      );
      expect(StreamTransport.magic, StreamFraming.magic);
      expect(StreamTransport.version, StreamFraming.version);
      expect(StreamTransport.defaultMaxFrameSize, 1024 * 1024);
      final peer = RawPeer(maxFrameSize: 77);
      expect((peer.transport as FrameLimited).maxFrameSize, 77);
      unawaited(peer.transport.sink.close());
    });

    test('output that does not keep up throttles the input', () async {
      final toTransport = StreamController<List<int>>();
      final fromTransport = StreamController<List<int>>();
      final transport = StreamTransport.wrap(
        toTransport.stream,
        fromTransport.sink,
        outputHighWaterMark: 1000,
      );
      final received = transport.stream.toList();
      final written = <int>[];
      final output = fromTransport.stream.listen(written.addAll)..pause();
      await pumpEventQueue();
      expect(transport.isInputThrottled, isFalse);
      for (var i = 0; i < 9; i++) {
        transport.sink.add(Uint8List(100));
      }
      // Preamble plus nine frames of 104 bytes wait for the output.
      expect(transport.bufferedOutputBytes, 8 + 9 * 104);
      expect(transport.isInputThrottled, isFalse);
      transport.sink.add(Uint8List(100));
      expect(transport.bufferedOutputBytes, 8 + 10 * 104);
      expect(transport.isInputThrottled, isTrue);
      expect(toTransport.isPaused, isTrue);

      output.resume();
      await pumpEventQueue();
      expect(transport.bufferedOutputBytes, 0);
      expect(transport.isInputThrottled, isFalse);
      expect(toTransport.isPaused, isFalse);
      expect(written, hasLength(8 + 10 * 104));
      expect(hexString(written.sublist(0, 8)), preambleHex);

      await toTransport.close();
      expect(await received, isEmpty);
      await transport.sink.done;
      await output.cancel();
    });

    test('a close that cannot drain the output aborts', () async {
      final toTransport = StreamController<List<int>>();
      final fromTransport = StreamController<List<int>>();
      var aborts = 0;
      final transport = StreamTransport.wrap(
        toTransport.stream,
        fromTransport.sink,
        closeTimeout: const Duration(milliseconds: 50),
        abort: () => aborts++,
      );
      final received = transport.stream.toList();
      final output = fromTransport.stream.listen((_) {})..pause();
      transport.sink.add(hexBytes('02 02 00'));
      expect(transport.bufferedOutputBytes, 15);
      await transport.sink.close();
      expect(aborts, 1);
      expect(transport.bufferedOutputBytes, 0);
      expect(await received, isEmpty);
      transport.abort();
      expect(aborts, 1);
      await output.cancel();
      await toTransport.close();
    });

    test('addError closes and fails done', () async {
      final peer = RawPeer();
      peer.transport.sink.addError(StateError('boom'));
      await expectLater(peer.transport.sink.done, throwsStateError);
      expect(await peer.read(8), preambleHex);
      expect(await peer.output.hasNext, isFalse);
    });
  });

  group('StreamTransport over TCP', () {
    late ServerSocket server;
    late StreamQueue<Socket> accepted;

    setUp(() async {
      server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      accepted = StreamQueue(server);
    });

    tearDown(() async {
      await accepted.cancel(immediate: true);
      await server.close();
    });

    test('frames both ways, close propagates', () async {
      final client = await StreamTransport.connectTcp(
        InternetAddress.loopbackIPv4,
        server.port,
      );
      final serverSide = StreamTransport.fromSocket(await accepted.next);
      final qc = StreamQueue(client.stream);
      final qs = StreamQueue(serverSide.stream);
      final big = bytesOf(300000);
      client.sink
        ..add(hexBytes('02 02 00 01'))
        ..add(big);
      for (var i = 0; i < 100; i++) {
        serverSide.sink.add(bytesOf(1 + i, i));
      }
      expect(hexString(await qs.next), '02 02 00 01');
      expect(await qs.next, big);
      for (var i = 0; i < 100; i++) {
        expect(await qc.next, bytesOf(1 + i, i));
      }
      await client.sink.close();
      expect(await qs.hasNext, isFalse);
      expect(await qc.hasNext, isFalse);
      await serverSide.sink.done;
    });

    test('frames split into one byte chunks', () async {
      final client = await StreamTransport.connectTcp('127.0.0.1', server.port);
      final socket = await accepted.next;
      final serverSide = StreamTransport.wrap(
        socket.transform(rechunk(1)),
        socket,
      );
      final frames = [for (var i = 1; i < 60; i++) bytesOf(i * 7, i)];
      final received = serverSide.stream.take(frames.length).toList();
      frames.forEach(client.sink.add);
      expect(await received, frames);
      await client.sink.close();
      await serverSide.sink.close();
    });

    test('abort destroys the socket', () async {
      final client = await StreamTransport.connectTcp('127.0.0.1', server.port);
      final socket = await accepted.next;
      final serverSide = StreamTransport.fromSocket(socket);
      expect(serverSide.maxFrameSize, StreamTransport.defaultMaxFrameSize);
      final serverEnd = serverSide.stream.drain<void>();
      final clientEnd = Completer<void>();
      client.stream.listen(
        (_) {},
        onError: (Object _) {},
        onDone: clientEnd.complete,
      );
      serverSide.abort();
      await serverEnd;
      await serverSide.sink.done;
      // The peer sees the connection go away.
      await clientEnd.future;
      await client.sink.close();
    });

    test('frame over the limit fails the stream', () async {
      final client = await StreamTransport.connectTcp('127.0.0.1', server.port);
      final serverSide = StreamTransport.fromSocket(
        await accepted.next,
        maxFrameSize: 100,
      );
      final queue = StreamQueue(serverSide.stream);
      client.sink.add(bytesOf(101));
      await expectLater(
        queue.next,
        throwsA(
          isA<SwitchboardException>().having(
            (e) => e.code,
            'code',
            StatusCode.frameTooLarge,
          ),
        ),
      );
      expect(await queue.hasNext, isFalse);
      // The server closed its side, which ends the client stream.
      expect(await client.stream.isEmpty, isTrue);
      await client.sink.close();
    });
  });

  group('WebSocketTransport', () {
    late HttpServer server;
    late StreamQueue<WebSocket> accepted;
    late Uri uri;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = StreamController<WebSocket>();
      server.listen((request) async {
        sockets.add(
          await WebSocketTransformer.upgrade(
            request,
            protocolSelector: (protocols) => WebSocketTransport.subprotocol,
          ),
        );
      });
      accepted = StreamQueue(sockets.stream);
      uri = Uri.parse('ws://127.0.0.1:${server.port}/');
    });

    tearDown(() async {
      await accepted.cancel(immediate: true);
      await server.close(force: true);
    });

    test('binary frames both ways and close', () async {
      final client = await WebSocketTransport.connect(uri);
      final ws = await accepted.next;
      expect(ws.protocol, WebSocketTransport.subprotocol);
      final serverSide = WebSocketTransport.wrap(IOWebSocketChannel(ws));
      final qc = StreamQueue(client.stream);
      final qs = StreamQueue(serverSide.stream);
      client.sink
        ..add(hexBytes('02 02 00 01'))
        ..add(bytesOf(200000));
      serverSide.sink.add(hexBytes('02 03 00 02'));
      expect(hexString(await qs.next), '02 02 00 01');
      expect(await qs.next, bytesOf(200000));
      expect(hexString(await qc.next), '02 03 00 02');
      await client.sink.close();
      expect(await qs.hasNext, isFalse);
      expect(await qc.hasNext, isFalse);
      expect(ws.closeCode, WebSocketTransport.normalClosure);
    });

    test('a text message is a protocol error', () async {
      final client = await WebSocketTransport.connect(uri);
      final ws = await accepted.next;
      // dart:io only processes the close handshake while listened to.
      final serverDrained = ws.drain<void>();
      final queue = StreamQueue(client.stream);
      ws.add(Uint8List.fromList([2, 2, 0]));
      ws.add('hello');
      expect(hexString(await queue.next), '02 02 00');
      await expectLater(queue.next, throwsA(isA<ProtocolException>()));
      expect(await queue.hasNext, isFalse);
      await serverDrained;
      expect(ws.closeCode, WebSocketTransport.normalClosure);
    });

    test('a message over maxFrameSize fails with FRAME_TOO_LARGE', () async {
      final client = await WebSocketTransport.connect(uri, maxFrameSize: 16);
      expect((client as FrameLimited).maxFrameSize, 16);
      final ws = await accepted.next;
      final serverDrained = ws.drain<void>();
      final queue = StreamQueue(client.stream);
      ws.add(Uint8List(16));
      ws.add(Uint8List(17));
      expect(await queue.next, hasLength(16));
      await expectLater(
        queue.next,
        throwsA(isStatusError(StatusCode.frameTooLarge)),
      );
      expect(await queue.hasNext, isFalse);
      await serverDrained;
      expect(ws.closeCode, WebSocketTransport.normalClosure);
    });

    test('the default limit is 1 MiB', () async {
      final client = await WebSocketTransport.connect(uri);
      expect((client as FrameLimited).maxFrameSize, 1024 * 1024);
      final ws = await accepted.next;
      final serverDrained = ws.drain<void>();
      await client.sink.close();
      await serverDrained;
    });

    test('connect timeout: UNAVAILABLE when the handshake stalls', () async {
      final silent = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final held = <Socket>[];
      silent.listen(held.add);
      addTearDown(() async {
        for (final socket in held) {
          socket.destroy();
        }
        await silent.close();
      });
      await expectLater(
        WebSocketTransport.connect(
          Uri.parse('ws://127.0.0.1:${silent.port}/'),
          timeout: const Duration(milliseconds: 50),
        ),
        throwsA(isStatusError(StatusCode.unavailable)),
      );
    });

    test('connect timeout: a connection completed late is closed', () async {
      final slow = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => slow.close(force: true));
      final upgraded = Completer<WebSocket>();
      slow.listen((request) async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        upgraded.complete(
          await WebSocketTransformer.upgrade(
            request,
            protocolSelector: (protocols) => WebSocketTransport.subprotocol,
          ),
        );
      });
      await expectLater(
        WebSocketTransport.connect(
          Uri.parse('ws://127.0.0.1:${slow.port}/'),
          timeout: const Duration(milliseconds: 20),
        ),
        throwsA(isStatusError(StatusCode.unavailable)),
      );
      final ws = await upgraded.future.timeout(const Duration(seconds: 5));
      await ws.drain<void>().timeout(const Duration(seconds: 5));
      expect(ws.closeCode, WebSocketTransport.normalClosure);
    });

    test('connect with a timeout in time works as without', () async {
      final client = await WebSocketTransport.connect(
        uri,
        timeout: const Duration(seconds: 5),
      );
      final ws = await accepted.next;
      final serverDrained = ws.drain<void>();
      await client.sink.close();
      await serverDrained;
    });

    test('connect failure throws', () async {
      final port = server.port;
      await server.close(force: true);
      await expectLater(
        WebSocketTransport.connect(Uri.parse('ws://127.0.0.1:$port/')),
        throwsA(anything),
      );
    });
  });

  group('IOWebSocketTransport', () {
    late HttpServer server;
    late StreamQueue<StreamChannel<Uint8List>> accepted;
    late List<Object> refused;
    late Uri uri;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final transports = StreamController<StreamChannel<Uint8List>>();
      refused = [];
      server.listen((request) async {
        try {
          transports.add(
            await IOWebSocketTransport.upgrade(request, maxFrameSize: 64),
          );
        } on Object catch (e) {
          refused.add(e);
        }
      });
      accepted = StreamQueue(transports.stream);
      uri = Uri.parse('ws://127.0.0.1:${server.port}/');
    });

    tearDown(() async {
      await accepted.cancel(immediate: true);
      await server.close(force: true);
    });

    test('upgrade and connect: frames, subprotocol, limit', () async {
      final client = await IOWebSocketTransport.connect(uri);
      expect((client as FrameLimited).maxFrameSize, 1024 * 1024);
      final serverSide = await accepted.next;
      expect((serverSide as FrameLimited).maxFrameSize, 64);
      final qc = StreamQueue(client.stream);
      final qs = StreamQueue(serverSide.stream);
      client.sink.add(hexBytes('02 02 00 01'));
      serverSide.sink.add(hexBytes('02 03 00 02'));
      expect(hexString(await qs.next), '02 02 00 01');
      expect(hexString(await qc.next), '02 03 00 02');
      // Over the server's limit.
      client.sink.add(Uint8List(65));
      await expectLater(
        qs.next,
        throwsA(isStatusError(StatusCode.frameTooLarge)),
      );
      expect(await qs.hasNext, isFalse);
      expect(await qc.hasNext, isFalse);
      await client.sink.done;
    });

    test('the switchboard subprotocol is selected', () async {
      final ws = await WebSocket.connect(
        uri.toString(),
        protocols: ['other', WebSocketTransport.subprotocol],
      );
      expect(ws.protocol, WebSocketTransport.subprotocol);
      final serverSide = await accepted.next;
      final received = serverSide.stream.first;
      ws.add(Uint8List.fromList([2, 2, 0]));
      expect(hexString(await received), '02 02 00');
      await ws.close();
      await serverSide.sink.close();
    });

    test('clients offering no subprotocol are accepted', () async {
      final ws = await WebSocket.connect(uri.toString());
      expect(ws.protocol, isNull);
      final serverSide = await accepted.next;
      final received = serverSide.stream.first;
      ws.add(Uint8List.fromList([2, 2, 0]));
      expect(hexString(await received), '02 02 00');
      await ws.close();
      await serverSide.sink.close();
    });

    test('clients offering only other subprotocols are refused', () async {
      await expectLater(
        WebSocket.connect(uri.toString(), protocols: ['chat']),
        throwsA(anything),
      );
      expect(refused, hasLength(1));
    });

    test('compression is not negotiated by default', () async {
      final http = HttpClient();
      final request = await http.getUrl(uri.replace(scheme: 'http'));
      request.headers
        ..set('Connection', 'Upgrade')
        ..set('Upgrade', 'websocket')
        ..set('Sec-WebSocket-Version', '13')
        ..set('Sec-WebSocket-Key', 'dGhlIHNhbXBsZSBub25jZQ==')
        ..set('Sec-WebSocket-Protocol', WebSocketTransport.subprotocol)
        ..set('Sec-WebSocket-Extensions', 'permessage-deflate');
      final response = await request.close();
      expect(response.statusCode, HttpStatus.switchingProtocols);
      expect(response.headers.value('sec-websocket-protocol'), 'switchboard');
      expect(response.headers.value('sec-websocket-extensions'), isNull);
      final socket = await response.detachSocket();
      socket.destroy();
      http.close(force: true);
      final serverSide = await accepted.next;
      await serverSide.stream.drain<void>();
    });
  });
}
