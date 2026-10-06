/*
Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Author: Jan Boon <jan.boon@kaetemi.be>
*/

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:stream_channel/stream_channel.dart';

import '../status.dart';

final Logger _log = Logger('Switchboard.Transport');

/// The stream binding of the transport layer: an 8-byte preamble, then
/// frames prefixed with a `u32` little-endian length.
///
/// Used for TCP, TLS, Unix domain sockets, serial lines and any other
/// ordered byte stream. See the wiki page "Switchboard Transport".
abstract final class StreamTransport {
  /// Default upper limit on an incoming frame body: 1 MiB.
  static const int defaultMaxFrameSize = 1024 * 1024;

  /// Protocol version sent in the preamble and the only one accepted.
  static const int version = 1;

  /// Length of the preamble in bytes.
  static const int preambleLength = 8;

  /// Length of the frame length prefix in bytes.
  static const int lengthPrefixSize = 4;

  /// The preamble magic, "SWBD".
  static const List<int> magic = [0x53, 0x57, 0x42, 0x44];

  /// Encodes a preamble: magic, `u16` [version], `u16` [flags].
  static Uint8List encodePreamble({int version = version, int flags = 0}) =>
      Uint8List.fromList([
        ...magic,
        version & 0xFF,
        (version >> 8) & 0xFF,
        flags & 0xFF,
        (flags >> 8) & 0xFF,
      ]);

  /// Encodes one frame: `u32` length followed by [body].
  ///
  /// Throws [ArgumentError] if [body] is empty, since a length of 0 is a
  /// protocol error.
  static Uint8List encodeFrame(List<int> body) {
    if (body.isEmpty) {
      throw ArgumentError.value(body, 'body', 'frames are never empty');
    }
    final length = body.length;
    final out = Uint8List(lengthPrefixSize + length);
    out[0] = length & 0xFF;
    out[1] = (length >> 8) & 0xFF;
    out[2] = (length >> 16) & 0xFF;
    out[3] = (length >> 24) & 0xFF;
    out.setRange(lengthPrefixSize, out.length, body);
    return out;
  }

  /// Wraps a byte stream pair as a transport.
  ///
  /// Writes the preamble to [output] immediately, frames every outgoing
  /// frame with the `u32` length prefix and parses incoming bytes into
  /// frames once the returned channel's stream is listened to. The peer's
  /// preamble is checked before any frame.
  ///
  /// A wrong magic, an unsupported version or a zero length fails the
  /// stream with a [ProtocolException]. A length above [maxFrameSize]
  /// fails it with a [SwitchboardException] carrying
  /// [StatusCode.frameTooLarge], without reading the body. After such an
  /// error the stream closes, and [output] is closed once the listener has
  /// seen the error and the end of the stream, so a mux layer can still
  /// send GOAWAY from its error handler.
  ///
  /// When [input] ends, the stream ends and [output] is closed. Closing
  /// the returned sink closes [output] and stops reading [input].
  static StreamChannel<Uint8List> wrap(
    Stream<List<int>> input,
    StreamSink<List<int>> output, {
    int maxFrameSize = defaultMaxFrameSize,
  }) => _StreamTransportChannel(input, output, maxFrameSize);

  /// Connects over TCP to [host] (a `String` or an `InternetAddress`) and
  /// [port], and wraps the socket with [fromSocket].
  static Future<StreamChannel<Uint8List>> connectTcp(
    dynamic host,
    int port, {
    int maxFrameSize = defaultMaxFrameSize,
  }) async {
    final socket = await Socket.connect(host, port);
    return fromSocket(socket, maxFrameSize: maxFrameSize);
  }

  /// Wraps a connected [socket], enabling `TCP_NODELAY` where supported.
  static StreamChannel<Uint8List> fromSocket(
    Socket socket, {
    int maxFrameSize = defaultMaxFrameSize,
  }) {
    try {
      socket.setOption(SocketOption.tcpNoDelay, true);
    } on Object catch (e) {
      _log.fine('cannot set TCP_NODELAY: $e');
    }
    return wrap(socket, socket, maxFrameSize: maxFrameSize);
  }
}

/// Incremental parser for the receiving side of the stream binding.
///
/// Feed it chunks of any size with [add]; it emits complete frame bodies
/// in order. Frames may be split across chunks at any byte and a chunk may
/// hold any number of frames.
class StreamFrameDecoder {
  /// Creates a decoder that first expects the peer preamble.
  StreamFrameDecoder({this.maxFrameSize = StreamTransport.defaultMaxFrameSize});

  /// Largest accepted frame body.
  final int maxFrameSize;

  Uint8List _buf = Uint8List(0);
  int _len = 0;
  bool _preambleReceived = false;

  /// Whether the peer preamble has been read and accepted.
  bool get preambleReceived => _preambleReceived;

  /// Number of bytes held while waiting for the rest of a frame.
  int get bufferedBytes => _len;

  /// Parses [chunk], calling [onFrame] with a fresh copy of every frame
  /// body completed by it.
  ///
  /// Throws [ProtocolException] on a wrong magic, an unsupported version
  /// or a zero length, and [SwitchboardException] with
  /// [StatusCode.frameTooLarge] on a length above [maxFrameSize]. Frames
  /// completed before the offending bytes have already been passed to
  /// [onFrame]. After a throw the decoder must not be used again.
  void add(List<int> chunk, void Function(Uint8List frame) onFrame) {
    if (chunk.isEmpty) {
      return;
    }
    final Uint8List data;
    final int end;
    if (_len == 0) {
      data = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
      end = data.length;
    } else {
      _ensure(_len + chunk.length);
      _buf.setRange(_len, _len + chunk.length, chunk);
      _len += chunk.length;
      data = _buf;
      end = _len;
    }
    var pos = 0;
    try {
      while (true) {
        if (!_preambleReceived) {
          if (end - pos < StreamTransport.preambleLength) {
            break;
          }
          _checkPreamble(data, pos);
          pos += StreamTransport.preambleLength;
          _preambleReceived = true;
          continue;
        }
        if (end - pos < StreamTransport.lengthPrefixSize) {
          break;
        }
        final length =
            data[pos] |
            (data[pos + 1] << 8) |
            (data[pos + 2] << 16) |
            (data[pos + 3] << 24);
        if (length == 0) {
          throw ProtocolException('zero length frame');
        }
        if (length > maxFrameSize) {
          throw SwitchboardException.of(
            StatusCode.frameTooLarge,
            'frame of $length bytes exceeds limit of $maxFrameSize',
          );
        }
        final start = pos + StreamTransport.lengthPrefixSize;
        if (end - start < length) {
          break;
        }
        pos = start + length;
        onFrame(data.sublist(start, pos));
      }
    } finally {
      _keep(data, pos, end);
    }
  }

  void _checkPreamble(Uint8List data, int pos) {
    for (var i = 0; i < StreamTransport.magic.length; i++) {
      if (data[pos + i] != StreamTransport.magic[i]) {
        throw ProtocolException('wrong preamble magic');
      }
    }
    final version = data[pos + 4] | (data[pos + 5] << 8);
    if (version != StreamTransport.version) {
      throw ProtocolException('unsupported stream binding version $version');
    }
    // Flags at pos + 6 are ignored as the specification requires.
  }

  /// Keeps `data[pos, end)` as the buffered remainder.
  void _keep(Uint8List data, int pos, int end) {
    final rest = end - pos;
    if (identical(data, _buf)) {
      if (pos > 0 && rest > 0) {
        _buf.setRange(0, rest, _buf, pos);
      }
      _len = rest;
    } else {
      _len = 0;
      if (rest > 0) {
        _ensure(rest);
        _buf.setRange(0, rest, data, pos);
        _len = rest;
      }
    }
    // Do not hold on to a large buffer once it is drained.
    if (_len == 0 && _buf.length > 64 * 1024) {
      _buf = Uint8List(0);
    }
  }

  void _ensure(int capacity) {
    if (capacity <= _buf.length) {
      return;
    }
    var size = _buf.isEmpty ? 256 : _buf.length;
    while (size < capacity) {
      size *= 2;
    }
    final grown = Uint8List(size);
    grown.setRange(0, _len, _buf);
    _buf = grown;
  }
}

class _StreamTransportChannel with StreamChannelMixin<Uint8List> {
  _StreamTransportChannel(this._input, this._output, int maxFrameSize)
    : _decoder = StreamFrameDecoder(maxFrameSize: maxFrameSize) {
    _controller = StreamController<Uint8List>(
      onListen: _onListen,
      onPause: () => _inputSub?.pause(),
      onResume: () => _inputSub?.resume(),
      onCancel: _onCancel,
    );
    _sink = _StreamTransportSink(this);
    _output.done.then(
      (_) {
        _outputClosed = true;
      },
      onError: (Object error, StackTrace stackTrace) {
        _outputClosed = true;
        _log.fine('stream transport output failed: $error');
        _fail(error, stackTrace);
      },
    );
    _write(StreamTransport.encodePreamble());
  }

  final Stream<List<int>> _input;
  final StreamSink<List<int>> _output;
  final StreamFrameDecoder _decoder;
  late final StreamController<Uint8List> _controller;
  late final _StreamTransportSink _sink;
  StreamSubscription<List<int>>? _inputSub;
  bool _listenerGone = false;
  bool _ended = false;
  bool _outputClosed = false;
  Future<void>? _outputClose;

  @override
  Stream<Uint8List> get stream => _controller.stream;

  @override
  StreamSink<Uint8List> get sink => _sink;

  void _onListen() {
    if (_ended) {
      return;
    }
    _inputSub = _input.listen(_onChunk, onError: _fail, onDone: _onInputDone);
  }

  void _onCancel() {
    // The StreamChannel contract: cancelling the subscription has no
    // effect on the sink, and the channel must still notice the peer
    // closing. Keep reading and drop frames.
    _listenerGone = true;
  }

  void _onChunk(List<int> chunk) {
    if (_ended) {
      return;
    }
    try {
      _decoder.add(chunk, (frame) {
        if (!_ended && !_listenerGone) {
          _controller.add(frame);
        }
      });
    } on SwitchboardException catch (e, st) {
      _log.warning('stream transport: ${e.status}');
      _fail(e, st);
    }
  }

  void _onInputDone() {
    if (_ended) {
      return;
    }
    if (_decoder.bufferedBytes > 0) {
      _log.fine(
        'stream transport input ended inside a frame '
        '(${_decoder.bufferedBytes} bytes buffered)',
      );
    }
    _end();
    // After the stream closes, the sink is closed automatically.
    unawaited(closeOutput());
  }

  /// Fails the stream with [error], ends it, then closes the output once
  /// the listener has seen both, so it can still write a last frame.
  void _fail(Object error, [StackTrace? stackTrace]) {
    if (_ended) {
      return;
    }
    _ended = true;
    final sub = _inputSub;
    _inputSub = null;
    if (sub != null) {
      unawaited(sub.cancel());
    }
    if (_listenerGone || !_controller.hasListener) {
      unawaited(_controller.close());
      unawaited(closeOutput());
      return;
    }
    _controller.addError(error, stackTrace);
    _controller.close().then((_) => closeOutput(), onError: (_) {});
  }

  void _end() {
    if (_ended) {
      return;
    }
    _ended = true;
    final sub = _inputSub;
    _inputSub = null;
    if (sub != null) {
      unawaited(sub.cancel());
    }
    unawaited(_controller.close());
  }

  void _write(List<int> bytes) {
    if (_outputClosed) {
      return;
    }
    try {
      _output.add(bytes);
    } on Object catch (e) {
      _log.fine('stream transport write failed: $e');
      _outputClosed = true;
    }
  }

  void send(Uint8List frame) {
    // Once the output is closed (explicitly, or automatically after the
    // stream ended) frames are silently dropped, as StreamChannel requires.
    // After a failure the output stays open until the listener has seen
    // the error, so a last frame such as GOAWAY still goes out.
    _write(StreamTransport.encodeFrame(frame));
  }

  /// Closes the output once and completes the sink's `done`. Never
  /// throws.
  Future<void> closeOutput() {
    return _outputClose ??= () async {
      _outputClosed = true;
      try {
        await _output.close();
      } on Object catch (e) {
        _log.fine('stream transport close failed: $e');
      }
      _sink.complete();
    }();
  }

  /// Local close: the stream ends before emitting anything else.
  Future<void> closeLocal() {
    _end();
    return closeOutput();
  }
}

class _StreamTransportSink implements StreamSink<Uint8List> {
  _StreamTransportSink(this._channel);

  final _StreamTransportChannel _channel;
  bool _closed = false;
  Object? _error;
  StackTrace? _errorStackTrace;
  final Completer<void> _done = Completer<void>();

  void complete() {
    if (_done.isCompleted) {
      return;
    }
    final error = _error;
    if (error != null) {
      _done.completeError(error, _errorStackTrace);
    } else {
      _done.complete();
    }
  }

  @override
  void add(Uint8List event) {
    if (_closed) {
      throw StateError('stream transport sink is closed');
    }
    _channel.send(event);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {
    if (_closed) {
      throw StateError('stream transport sink is closed');
    }
    // Errors are not forwarded to the peer: the sink closes and reports
    // the error through [done], as StreamChannel allows.
    _closed = true;
    _error = error;
    _errorStackTrace = stackTrace;
    _done.future.ignore();
    complete();
    unawaited(_channel.closeLocal());
  }

  @override
  Future<void> addStream(Stream<Uint8List> stream) async {
    await for (final frame in stream) {
      if (_closed) {
        break;
      }
      _channel.send(frame);
    }
  }

  @override
  Future<void> close() {
    _closed = true;
    unawaited(_channel.closeLocal());
    return _done.future;
  }

  @override
  Future<void> get done => _done.future;
}
