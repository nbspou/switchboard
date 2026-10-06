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
import 'package:switchboard/src/transport/web_socket_transport.dart';
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

    test('addError closes the pair and fails done', () async {
      final (a, b) = MemoryTransport.pair();
      a.sink.addError(StateError('boom'));
      await expectLater(a.sink.done, throwsStateError);
      expect(await b.stream.isEmpty, isTrue);
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
      final frames = [for (var i = 1; i < 40; i++) bytesOf(i, i)];
      frames.forEach(a.sink.add);
      await a.sink.close();
      expect(await received, frames);
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

    for (final (name, hex) in [
      ('wrong magic', '53 57 42 58 01 00 00 00 01 00 00 00 AA'),
      ('unsupported version', '53 57 42 44 02 00 00 00 01 00 00 00 AA'),
      ('zero length frame', '$preambleHex 00 00 00 00'),
    ]) {
      test('$name fails the stream with a protocol error', () async {
        final peer = RawPeer();
        final queue = StreamQueue(peer.transport.stream);
        expect(await peer.read(8), preambleHex);
        peer.toTransport.add(hexBytes(hex));
        await expectLater(queue.next, throwsA(isA<ProtocolException>()));
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

    test('connect failure throws', () async {
      final port = server.port;
      await server.close(force: true);
      await expectLater(
        WebSocketTransport.connect(Uri.parse('ws://127.0.0.1:$port/')),
        throwsA(anything),
      );
    });
  });
}
