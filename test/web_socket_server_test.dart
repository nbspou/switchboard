// Sockets and WebSockets below are closed through the transports or the
// raw client, which the close_sinks lint cannot see.
// ignore_for_file: close_sinks

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:async/async.dart';
import 'package:switchboard/switchboard.dart';
import 'package:test/test.dart';

const opContinuation = 0x0;
const opText = 0x1;
const opBinary = 0x2;
const opClose = 0x8;
const opPing = 0x9;
const opPong = 0xA;

/// The sample nonce of RFC 6455 section 1.3 and its accept value.
const sampleKey = 'dGhlIHNhbXBsZSBub25jZQ==';
const sampleAccept = 's3pPLMBiTxaQ9kYGzzhZRbK+xOo=';

Uint8List pattern(int length, [int seed = 0]) =>
    Uint8List.fromList(List.generate(length, (i) => (i * 31 + seed) & 0xFF));

/// A queue over [stream] that listens at once: the transport reads its
/// socket only while its stream is listened to.
StreamQueue<T> eager<T>(Stream<T> stream) {
  final controller = StreamController<T>();
  stream.listen(
    controller.add,
    onError: controller.addError,
    onDone: controller.close,
  );
  return StreamQueue(controller.stream);
}

Matcher isStatusError(StatusCode code) =>
    isA<SwitchboardException>().having((e) => e.code, 'code', code);

/// A client frame: masked unless [mask] is false.
Uint8List clientFrame(
  int opcode,
  List<int> payload, {
  bool fin = true,
  bool mask = true,
  int rsv = 0,
}) {
  final builder = BytesBuilder()..addByte((fin ? 0x80 : 0) | rsv | opcode);
  final maskBit = mask ? 0x80 : 0;
  final length = payload.length;
  if (length < 126) {
    builder.addByte(maskBit | length);
  } else if (length <= 0xFFFF) {
    builder
      ..addByte(maskBit | 126)
      ..add([length >> 8, length & 0xFF]);
  } else {
    builder.addByte(maskBit | 127);
    for (var i = 7; i >= 0; i--) {
      builder.addByte((length >> (8 * i)) & 0xFF);
    }
  }
  if (!mask) {
    return (builder..add(payload)).takeBytes();
  }
  const key = [0x37, 0xFA, 0x21, 0x3D];
  builder.add(key);
  builder.add([for (var i = 0; i < length; i++) payload[i] ^ key[i & 3]]);
  return builder.takeBytes();
}

/// A frame header only, claiming [length] payload bytes.
Uint8List clientHeader(int opcode, int length, {bool fin = true}) {
  final builder = BytesBuilder()
    ..addByte((fin ? 0x80 : 0) | opcode)
    ..addByte(0x80 | 127);
  for (var i = 7; i >= 0; i--) {
    builder.addByte((length >> (8 * i)) & 0xFF);
  }
  return (builder..add([0, 0, 0, 0])).takeBytes();
}

Uint8List closePayload(int code, [String reason = '']) =>
    Uint8List.fromList([code >> 8, code & 0xFF, ...utf8.encode(reason)]);

/// A frame received from the server.
class ServerFrame {
  ServerFrame(this.opcode, this.payload, {required this.fin});

  final int opcode;
  final Uint8List payload;
  final bool fin;

  int? get closeCode =>
      payload.length >= 2 ? (payload[0] << 8) | payload[1] : null;

  @override
  String toString() => 'ServerFrame($opcode, ${payload.length} bytes)';
}

/// A WebSocket client over a raw socket: writes whatever it is told to and
/// parses the server's frames, checking that they are not masked.
class RawClient {
  RawClient._(this.socket);

  final Socket socket;

  /// Whether pings are answered with pongs as they arrive.
  bool autoPong = false;
  final StreamController<ServerFrame> _frames = StreamController();
  late final StreamQueue<ServerFrame> frames = StreamQueue(_frames.stream);
  final Completer<String> _head = Completer();
  final Completer<void> closed = Completer();
  final BytesBuilder _buffer = BytesBuilder();

  /// The status line and headers of the response, lower case names.
  late final int status;
  late final Map<String, String> headers;

  static String handshake({
    String path = '/',
    String? key = sampleKey,
    String? version = '13',
    String? protocols = 'switchboard',
    String? extensions,
    bool upgrade = true,
  }) => [
    'GET $path HTTP/1.1',
    'Host: localhost',
    if (upgrade) ...['Upgrade: websocket', 'Connection: keep-alive, Upgrade'],
    if (key != null) 'Sec-WebSocket-Key: $key',
    if (version != null) 'Sec-WebSocket-Version: $version',
    if (protocols != null) 'Sec-WebSocket-Protocol: $protocols',
    if (extensions != null) 'Sec-WebSocket-Extensions: $extensions',
    '',
    '',
  ].join('\r\n');

  static Future<RawClient> connect(int port, [String? request]) async {
    final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
    final client = RawClient._(socket);
    socket.listen(
      client._onData,
      onError: (Object _) => client._onDone(),
      onDone: client._onDone,
    );
    socket.write(request ?? handshake());
    final head = await client._head.future.timeout(const Duration(seconds: 5));
    final lines = head.split('\r\n');
    client.status = int.parse(lines.first.split(' ')[1]);
    client.headers = {
      for (final line in lines.skip(1))
        if (line.contains(':'))
          line.substring(0, line.indexOf(':')).trim().toLowerCase(): line
              .substring(line.indexOf(':') + 1)
              .trim(),
    };
    return client;
  }

  void _onData(Uint8List data) {
    _buffer.add(data);
    if (!_head.isCompleted) {
      final bytes = _buffer.toBytes();
      for (var i = 0; i + 3 < bytes.length; i++) {
        if (bytes[i] == 13 &&
            bytes[i + 1] == 10 &&
            bytes[i + 2] == 13 &&
            bytes[i + 3] == 10) {
          _head.complete(latin1.decode(bytes.sublist(0, i)));
          _buffer
            ..clear()
            ..add(bytes.sublist(i + 4));
          break;
        }
      }
      if (!_head.isCompleted) {
        return;
      }
    }
    _parse();
  }

  void _parse() {
    var bytes = _buffer.toBytes();
    while (bytes.length >= 2) {
      final fin = (bytes[0] & 0x80) != 0;
      final opcode = bytes[0] & 0x0F;
      expect(bytes[1] & 0x80, 0, reason: 'server frames are not masked');
      var length = bytes[1] & 0x7F;
      var offset = 2;
      if (length == 126) {
        if (bytes.length < 4) {
          break;
        }
        length = (bytes[2] << 8) | bytes[3];
        offset = 4;
      } else if (length == 127) {
        if (bytes.length < 10) {
          break;
        }
        length = 0;
        for (var i = 2; i < 10; i++) {
          length = (length << 8) | bytes[i];
        }
        offset = 10;
      }
      if (bytes.length < offset + length) {
        break;
      }
      final payload = Uint8List.fromList(
        bytes.sublist(offset, offset + length),
      );
      if (autoPong && opcode == opPing) {
        send(clientFrame(opPong, payload));
      }
      _frames.add(ServerFrame(opcode, payload, fin: fin));
      bytes = Uint8List.fromList(bytes.sublist(offset + length));
    }
    _buffer
      ..clear()
      ..add(bytes);
  }

  void _onDone() {
    if (!_head.isCompleted) {
      _head.complete(latin1.decode(_buffer.takeBytes()));
    }
    if (!closed.isCompleted) {
      closed.complete();
      unawaited(_frames.close());
    }
  }

  void send(Uint8List bytes) => socket.add(bytes);

  /// Writes [bytes] a few at a time, so the server reads them in pieces.
  Future<void> trickle(Uint8List bytes, {int step = 3}) async {
    for (var i = 0; i < bytes.length; i += step) {
      socket.add(bytes.sublist(i, i + step > bytes.length ? null : i + step));
      await socket.flush();
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// The next frame that is not a ping or pong.
  Future<ServerFrame> next() async {
    while (true) {
      final frame = await frames.next;
      if (frame.opcode != opPing && frame.opcode != opPong) {
        return frame;
      }
    }
  }

  void destroy() => socket.destroy();
}

/// An HTTP server upgrading every request with [WebSocketServerTransport].
class Harness {
  late HttpServer server;
  final StreamController<WebSocketServerChannel> _accepted = StreamController();
  late final StreamQueue<WebSocketServerChannel> accepted = StreamQueue(
    _accepted.stream,
  );
  final List<Object> refused = [];

  int get port => server.port;

  Uri get uri => Uri.parse('ws://127.0.0.1:$port/');

  static Future<Harness> start({
    int maxFrameSize = 1000,
    Duration? pingInterval,
  }) async {
    final h = Harness();
    h.server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    h.server.listen((request) async {
      try {
        h._accepted.add(
          await WebSocketServerTransport.upgrade(
            request,
            maxFrameSize: maxFrameSize,
            pingInterval: pingInterval,
          ),
        );
      } on Object catch (e) {
        h.refused.add(e);
      }
    });
    addTearDown(() async {
      await h.accepted.cancel(immediate: true);
      await h.server.close(force: true);
    });
    return h;
  }

  /// A raw client connected and upgraded, and the server side of it.
  Future<(RawClient, WebSocketServerChannel)> pair([String? request]) async {
    final client = await RawClient.connect(port, request);
    addTearDown(client.destroy);
    expect(client.status, HttpStatus.switchingProtocols);
    return (client, await accepted.next);
  }
}

void main() {
  group('handshake', () {
    late Harness h;

    setUp(() async => h = await Harness.start());

    test('a good request is switched with the switchboard protocol', () async {
      final (client, server) = await h.pair(
        RawClient.handshake(
          protocols: 'other, switchboard',
          extensions: 'permessage-deflate; client_max_window_bits',
        ),
      );
      // Its stream is never listened to, so it never reads the client's
      // close: it is torn down here.
      addTearDown(server.abort);
      expect(client.headers['sec-websocket-accept'], sampleAccept);
      expect(client.headers['upgrade']?.toLowerCase(), 'websocket');
      expect(client.headers['connection']?.toLowerCase(), 'upgrade');
      expect(client.headers['sec-websocket-protocol'], 'switchboard');
      // No extension is negotiated, compression included.
      expect(client.headers['sec-websocket-extensions'], isNull);
      expect(server.protocol, 'switchboard');
      expect(server.maxFrameSize, 1000);
      expect(server, isA<FrameLimited>());
      expect(server, isA<AbortableTransport>());
      expect(server, isA<OutputBufferedTransport>());
    });

    test('a client offering no subprotocol is accepted', () async {
      final (client, server) = await h.pair(
        RawClient.handshake(protocols: null),
      );
      addTearDown(server.abort);
      expect(client.headers['sec-websocket-protocol'], isNull);
      expect(server.protocol, isNull);
    });

    for (final (name, request, status) in [
      ('missing key', RawClient.handshake(key: null), 400),
      ('malformed key', RawClient.handshake(key: 'c2hvcnQ='), 400),
      ('wrong version', RawClient.handshake(version: '8'), 426),
      ('missing version', RawClient.handshake(version: null), 426),
      ('other subprotocol', RawClient.handshake(protocols: 'chat'), 400),
      ('not an upgrade', RawClient.handshake(upgrade: false), 426),
    ]) {
      test('$name is refused with $status', () async {
        final client = await RawClient.connect(h.port, request);
        addTearDown(client.destroy);
        expect(client.status, status);
        if (name == 'wrong version' || name == 'missing version') {
          expect(client.headers['sec-websocket-version'], '13');
        }
        if (name == 'not an upgrade') {
          expect(client.headers['upgrade'], 'websocket');
        }
        await pumpEventQueue();
        expect(h.refused.single, isA<WebSocketException>());
      });
    }
  });

  group('frames', () {
    late Harness h;
    late RawClient client;
    late WebSocketServerChannel server;
    late StreamQueue<Uint8List> received;

    setUp(() async {
      h = await Harness.start(maxFrameSize: 1024 * 1024);
      (client, server) = await h.pair();
      received = eager(server.stream);
    });

    test('binary messages both ways, every length encoding', () async {
      for (final length in [3, 125, 126, 0xFFFF, 0x10000, 300000]) {
        client.send(clientFrame(opBinary, pattern(length, length)));
        expect(await received.next, pattern(length, length));
        server.sink.add(pattern(length, 7));
        final frame = await client.next();
        expect(frame.opcode, opBinary);
        expect(frame.fin, isTrue);
        expect(frame.payload, pattern(length, 7));
      }
    });

    test('a fragmented message is reassembled, with a ping between '
        'fragments', () async {
      client
        ..send(clientFrame(opBinary, [1, 2], fin: false))
        ..send(clientFrame(opPing, utf8.encode('mid')))
        ..send(clientFrame(opContinuation, [3, 4], fin: false))
        ..send(clientFrame(opContinuation, [5, 6]));
      expect(await received.next, [1, 2, 3, 4, 5, 6]);
      final pong = await client.frames.next;
      expect(pong.opcode, opPong);
      expect(utf8.decode(pong.payload), 'mid');
      // Large fragments, and a message after it.
      final big = pattern(900000, 3);
      client
        ..send(clientFrame(opBinary, big.sublist(0, 300000), fin: false))
        ..send(
          clientFrame(opContinuation, big.sublist(300000, 600000), fin: false),
        )
        ..send(clientFrame(opContinuation, big.sublist(600000)))
        ..send(clientFrame(opBinary, [9]));
      expect(await received.next, big);
      expect(await received.next, [9]);
    });

    test('frames split across reads', () async {
      await client.trickle(
        Uint8List.fromList([
          ...clientFrame(opBinary, pattern(300, 1), fin: false),
          ...clientFrame(opContinuation, pattern(20, 2)),
          ...clientFrame(opPing, [7]),
        ]),
      );
      expect(await received.next, [...pattern(300, 1), ...pattern(20, 2)]);
      expect((await client.frames.next).payload, [7]);
    });

    test('ping is answered, an unsolicited pong ignored', () async {
      client.send(clientFrame(opPing, utf8.encode('hello')));
      final pong = await client.frames.next;
      expect(pong.opcode, opPong);
      expect(utf8.decode(pong.payload), 'hello');
      client.send(clientFrame(opPing, const []));
      expect((await client.frames.next).payload, isEmpty);
      client
        ..send(clientFrame(opPong, [1, 2]))
        ..send(clientFrame(opBinary, [3]));
      expect(await received.next, [3]);
    });

    test('a close from the client is echoed and ends the stream', () async {
      client
        ..send(clientFrame(opBinary, [1]))
        ..send(clientFrame(opClose, closePayload(1000, 'bye')));
      expect(await received.next, [1]);
      expect(await received.hasNext, isFalse);
      final close = await client.next();
      expect(close.opcode, opClose);
      expect(close.closeCode, 1000);
      expect(server.closeCode, 1000);
      expect(server.closeReason, 'bye');
      // Nothing is sent after the close frame, and the server closes its
      // side once the client has closed.
      server.sink.add(Uint8List.fromList([2]));
      await client.socket.close();
      await client.closed.future;
      expect(await client.frames.hasNext, isFalse);
      await server.sink.done;
    });

    test('a close without a code is echoed without one', () async {
      client.send(clientFrame(opClose, const []));
      final close = await client.next();
      expect(close.opcode, opClose);
      expect(close.payload, isEmpty);
      expect(await received.hasNext, isFalse);
      expect(server.closeCode, isNull);
    });

    test(
      'closing the sink sends close 1000 and waits for the client',
      () async {
        server.sink.add(Uint8List.fromList([5]));
        final closing = server.sink.close();
        expect((await client.next()).payload, [5]);
        final close = await client.next();
        expect(close.opcode, opClose);
        expect(close.closeCode, 1000);
        await closing;
        expect(await received.hasNext, isFalse);
        // The server closed its side: the client sees the end and closes.
        await client.closed.future;
      },
    );
  });

  group('limits and protocol errors', () {
    late Harness h;

    setUp(() async => h = await Harness.start(maxFrameSize: 1000));

    /// Sends [frames] and expects the stream to fail with [matcher] and
    /// the connection to be closed with [code].
    Future<void> expectFailure(
      List<Uint8List> frames,
      Matcher matcher,
      int code,
    ) async {
      final (client, server) = await h.pair();
      final received = eager(server.stream);
      frames.forEach(client.send);
      await expectLater(received.next, throwsA(matcher));
      expect(await received.hasNext, isFalse);
      final close = await client.next();
      expect(close.opcode, opClose);
      expect(close.closeCode, code);
      await client.closed.future;
    }

    test('a single message over the limit: 1009 and FRAME_TOO_LARGE', () {
      return expectFailure(
        [clientFrame(opBinary, pattern(1001))],
        isStatusError(StatusCode.frameTooLarge),
        1009,
      );
    });

    test('the limit counts every fragment of a message', () async {
      final (client, server) = await h.pair();
      final received = eager(server.stream);
      // Exactly at the limit in three fragments: fine.
      client
        ..send(clientFrame(opBinary, pattern(400), fin: false))
        ..send(clientFrame(opContinuation, pattern(400), fin: false))
        ..send(clientFrame(opContinuation, pattern(200)));
      expect(await received.next, hasLength(1000));
      // One byte more over three fragments: refused at the last header.
      client
        ..send(clientFrame(opBinary, pattern(400), fin: false))
        ..send(clientFrame(opContinuation, pattern(400), fin: false))
        ..send(clientFrame(opContinuation, pattern(201)));
      await expectLater(
        received.next,
        throwsA(isStatusError(StatusCode.frameTooLarge)),
      );
      expect((await client.next()).closeCode, 1009);
    });

    test('a fragment is refused on its header, before its payload', () async {
      // The reviewer's case: fragments each within the limit, adding up to
      // far more. The second header alone is enough to refuse it.
      final big = await Harness.start(maxFrameSize: 1024 * 1024);
      final (client, server) = await big.pair();
      final received = eager(server.stream);
      client
        ..send(clientFrame(opBinary, Uint8List(1024 * 1024), fin: false))
        ..send(clientHeader(opContinuation, 1024 * 1024, fin: false));
      await expectLater(
        received.next,
        throwsA(isStatusError(StatusCode.frameTooLarge)),
      );
      expect((await client.next()).closeCode, 1009);
      // A header claiming an absurd length is refused the same way.
      final (other, otherServer) = await big.pair();
      other.send(clientHeader(opBinary, 1 << 40));
      await expectLater(
        otherServer.stream.first,
        throwsA(isStatusError(StatusCode.frameTooLarge)),
      );
      expect((await other.next()).closeCode, 1009);
    });

    test('after a failure the stream listener can still send a last frame '
        'before the close frame', () async {
      final (client, server) = await h.pair();
      server.stream.listen(
        null,
        onError: (Object e) => server.sink.add(Uint8List.fromList([0xEE])),
      );
      client.send(clientFrame(opBinary, pattern(2000)));
      final last = await client.next();
      expect(last.opcode, opBinary);
      expect(last.payload, [0xEE]);
      expect((await client.next()).closeCode, 1009);
      await server.sink.close();
    });

    test('an unmasked client frame: 1002', () {
      return expectFailure(
        [
          clientFrame(opBinary, [1, 2, 3], mask: false),
        ],
        isA<ProtocolException>(),
        1002,
      );
    });

    test('a text message: 1003', () {
      return expectFailure(
        [clientFrame(opText, utf8.encode('hello'))],
        isA<ProtocolException>(),
        1003,
      );
    });

    for (final (name, frames) in [
      (
        'reserved bits (no extension)',
        [
          clientFrame(opBinary, [1], rsv: 0x40),
        ],
      ),
      (
        'reserved opcode',
        [
          clientFrame(0x3, [1]),
        ],
      ),
      (
        'continuation outside a message',
        [
          clientFrame(opContinuation, [1]),
        ],
      ),
      (
        'new message inside a fragmented one',
        [
          clientFrame(opBinary, [1], fin: false),
          clientFrame(opBinary, [2]),
        ],
      ),
      ('control frame over 125 bytes', [clientFrame(opPing, Uint8List(126))]),
      (
        'fragmented control frame',
        [
          clientFrame(opPing, [1], fin: false),
        ],
      ),
      (
        'close with a one byte payload',
        [
          clientFrame(opClose, [3]),
        ],
      ),
      (
        'close with a reserved code',
        [clientFrame(opClose, closePayload(1005))],
      ),
    ]) {
      test('$name: 1002', () {
        return expectFailure(frames, isA<ProtocolException>(), 1002);
      });
    }

    test('a close reason that is not UTF-8: 1007', () {
      return expectFailure(
        [
          clientFrame(opClose, [0x03, 0xE8, 0xC3, 0x28]),
        ],
        isA<ProtocolException>(),
        1007,
      );
    });
  });

  group('ping interval', () {
    test('a client that does not answer is dropped', () async {
      final h = await Harness.start(
        pingInterval: const Duration(milliseconds: 30),
      );
      final client = await RawClient.connect(h.port);
      addTearDown(client.destroy);
      final server = await h.accepted.next;
      final ping = await client.frames.next;
      expect(ping.opcode, opPing);
      // Never answered: the server aborts after two more intervals.
      final watch = Stopwatch()..start();
      await server.stream.drain<void>();
      await client.closed.future;
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
    });

    test('a client that answers stays', () async {
      final h = await Harness.start(
        pingInterval: const Duration(milliseconds: 30),
      );
      final client = await RawClient.connect(h.port);
      addTearDown(client.destroy);
      client.autoPong = true;
      final server = await h.accepted.next;
      final received = eager(server.stream);
      // Several pings, each answered: the connection stays.
      for (var i = 0; i < 4; i++) {
        expect((await client.frames.next).opcode, opPing);
      }
      client.send(clientFrame(opBinary, [1, 2, 3]));
      expect(await received.next, [1, 2, 3]);
      server.sink.add(Uint8List.fromList([4]));
      expect((await client.next()).payload, [4]);
      await server.sink.close();
    });
  });

  group('interoperability', () {
    late Harness h;

    setUp(() async => h = await Harness.start(maxFrameSize: 1024 * 1024));

    test('dart:io WebSocket client: messages, compression refused, client '
        'close', () async {
      final ws = await WebSocket.connect(
        h.uri.toString(),
        protocols: const ['switchboard'],
      );
      expect(ws.protocol, 'switchboard');
      // dart:io offers permessage-deflate by default; it is not accepted.
      expect(ws.extensions, isEmpty);
      final server = await h.accepted.next;
      final received = eager(server.stream);
      final atClient = eager<dynamic>(ws);
      final big = pattern(900 * 1024, 5);
      ws
        ..add(Uint8List.fromList([1]))
        ..add(big);
      expect(await received.next, [1]);
      expect(await received.next, big);
      server.sink
        ..add(Uint8List.fromList([2]))
        ..add(big);
      expect(await atClient.next, [2]);
      expect(await atClient.next, big);
      await ws.close(1000, 'done');
      expect(await received.hasNext, isFalse);
      expect(server.closeCode, 1000);
      expect(server.closeReason, 'done');
      expect(await atClient.hasNext, isFalse);
      expect(ws.closeCode, 1000);
      await server.sink.done;
    });

    test('dart:io WebSocket client: server close and message limit', () async {
      final ws = await WebSocket.connect(h.uri.toString());
      final server = await h.accepted.next;
      final atClient = eager<dynamic>(ws);
      await server.sink.close();
      expect(await atClient.hasNext, isFalse);
      expect(ws.closeCode, 1000);

      final over = await WebSocket.connect(h.uri.toString());
      final overServer = await h.accepted.next;
      final overDone = over.drain<void>();
      over.add(Uint8List(1024 * 1024 + 1));
      await expectLater(
        overServer.stream.first,
        throwsA(isStatusError(StatusCode.frameTooLarge)),
      );
      await overDone;
      expect(over.closeCode, 1009);
    });

    test(
      'package:web_socket_channel client through WebSocketTransport',
      () async {
        final client = await WebSocketTransport.connect(h.uri);
        final server = await h.accepted.next;
        expect(server.protocol, 'switchboard');
        final received = eager(server.stream);
        final atClient = StreamQueue(client.stream);
        client.sink.add(Uint8List.fromList([2, 2, 0, 1]));
        expect(await received.next, [2, 2, 0, 1]);
        server.sink.add(Uint8List.fromList([2, 3, 0, 2]));
        expect(await atClient.next, [2, 3, 0, 2]);
        await client.sink.close();
        expect(await received.hasNext, isFalse);
        expect(await atClient.hasNext, isFalse);
        expect(server.closeCode, 1000);
      },
    );

    test('a mux connection over it, both closes give goingAway', () async {
      const options = MuxOptions(keepAliveInterval: null);
      for (final serverCloses in [false, true]) {
        final client = MuxConnection(
          await IOWebSocketTransport.connect(h.uri),
          isInitiator: true,
          options: options,
        );
        final server = MuxConnection(
          await h.accepted.next,
          isInitiator: false,
          options: options,
        );
        await client.ping();
        await server.ping();
        if (serverCloses) {
          await server.goAway();
          expect(await client.done, Status.of(StatusCode.goingAway));
        } else {
          await client.goAway();
          expect(await server.done, Status.of(StatusCode.goingAway));
        }
      }
    });
  });

  group('Switchboard listener', () {
    test('upgrade requests for another path get 403', () async {
      final node = Switchboard(
        muxOptions: const MuxOptions(keepAliveInterval: null),
      );
      addTearDown(node.close);
      final uri = await node.listenWebSocket('127.0.0.1', 0, path: '/mesh');
      final other = await RawClient.connect(
        uri.port,
        RawClient.handshake(path: '/other'),
      );
      addTearDown(other.destroy);
      expect(other.status, HttpStatus.forbidden);
      final good = await RawClient.connect(
        uri.port,
        RawClient.handshake(path: '/mesh'),
      );
      addTearDown(good.destroy);
      expect(good.status, HttpStatus.switchingProtocols);
      expect(good.headers['sec-websocket-accept'], sampleAccept);
      // Only other subprotocols, no upgrade headers, a bad version.
      for (final (request, status) in [
        (RawClient.handshake(path: '/mesh', protocols: 'chat'), 400),
        (RawClient.handshake(path: '/mesh', upgrade: false), 426),
        (RawClient.handshake(path: '/mesh', version: '12'), 426),
      ]) {
        final refused = await RawClient.connect(uri.port, request);
        addTearDown(refused.destroy);
        expect(refused.status, status);
      }
    });

    test(
      'the listener bounds fragmented messages by the mux frame limit',
      () async {
        final node = Switchboard(
          muxOptions: const MuxOptions(
            keepAliveInterval: null,
            maxFrameSize: 4096,
          ),
        );
        addTearDown(node.close);
        final uri = await node.listenWebSocket('127.0.0.1', 0);
        final accepted = node.connections.first;
        final client = await RawClient.connect(uri.port);
        addTearDown(client.destroy);
        final connection = await accepted;
        for (var i = 0; i < 4; i++) {
          client.send(
            clientFrame(
              i == 0 ? opBinary : opContinuation,
              Uint8List(1024),
              fin: false,
            ),
          );
        }
        client.send(clientHeader(opContinuation, 1024));
        expect((await connection.done).known, StatusCode.frameTooLarge);
        // The client gets the node's LIMITS, then GOAWAY FRAME_TOO_LARGE,
        // then the close frame.
        final goAways = <Status>[];
        while (true) {
          final frame = await client.next();
          if (frame.opcode != opBinary) {
            expect(frame.opcode, opClose);
            expect(frame.closeCode, 1009);
            break;
          }
          final mux = MuxFrame.decode(frame.payload);
          final control = MuxControlMessage.decode(mux.payload);
          if (control.knownType == MuxControlType.goAway) {
            goAways.add(control.goAwayStatus);
          }
        }
        expect(goAways.single.known, StatusCode.frameTooLarge);
      },
    );

    test('acceptWebSocket bounds messages by its own maxFrameSize', () async {
      final node = Switchboard(
        muxOptions: const MuxOptions(keepAliveInterval: null),
      );
      addTearDown(node.close);
      final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => http.close(force: true));
      final accepted = Completer<MuxConnection>();
      http.listen((request) async {
        accepted.complete(
          await node.acceptWebSocket(request, maxFrameSize: 4096),
        );
      });
      final client = await RawClient.connect(http.port);
      addTearDown(client.destroy);
      expect(client.status, HttpStatus.switchingProtocols);
      final connection = await accepted.future;
      // 5 KiB: over the limit given, far below the node's 1 MiB.
      for (var i = 0; i < 4; i++) {
        client.send(
          clientFrame(
            i == 0 ? opBinary : opContinuation,
            Uint8List(1024),
            fin: false,
          ),
        );
      }
      client.send(clientHeader(opContinuation, 1024));
      expect((await connection.done).known, StatusCode.frameTooLarge);
    });
  });
}
