/*
Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Author: Jan Boon <jan.boon@kaetemi.be>
*/

import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:stream_channel/stream_channel.dart';

import '../status.dart';
import 'stream_framing.dart';
import 'transport_capabilities.dart';

export 'stream_framing.dart';

final Logger _log = Logger('Switchboard.Transport');

/// The stream binding of the transport layer: an 8-byte preamble, then
/// frames prefixed with a `u32` little-endian length.
///
/// Used for TCP, TLS, Unix domain sockets, serial lines and any other
/// ordered byte stream. See the wiki page "Switchboard Transport". The
/// wire format itself is in [StreamFraming] and [StreamFrameDecoder],
/// which do not need `dart:io`.
abstract final class StreamTransport {
  /// Default upper limit on an incoming frame body: 1 MiB.
  static const int defaultMaxFrameSize = StreamFraming.defaultMaxFrameSize;

  /// Default [StreamTransportChannel.outputHighWaterMark]: 16 MiB.
  static const int defaultOutputHighWaterMark = 16 * 1024 * 1024;

  /// Default [StreamTransportChannel.closeTimeout]: 10 seconds.
  static const Duration defaultCloseTimeout = Duration(seconds: 10);

  /// Protocol version sent in the preamble and the only one accepted.
  static const int version = StreamFraming.version;

  /// Length of the preamble in bytes.
  static const int preambleLength = StreamFraming.preambleLength;

  /// Length of the frame length prefix in bytes.
  static const int lengthPrefixSize = StreamFraming.lengthPrefixSize;

  /// The preamble magic, "SWBD".
  static const List<int> magic = StreamFraming.magic;

  /// Encodes a preamble: magic, `u16` [version], `u16` [flags]. Same as
  /// [StreamFraming.encodePreamble].
  static Uint8List encodePreamble({int version = version, int flags = 0}) =>
      StreamFraming.encodePreamble(version: version, flags: flags);

  /// Encodes one frame: `u32` length followed by [body]. Same as
  /// [StreamFraming.encodeFrame].
  ///
  /// Throws [ArgumentError] if [body] is empty, since a length of 0 is a
  /// protocol error.
  static Uint8List encodeFrame(List<int> body) =>
      StreamFraming.encodeFrame(body);

  /// Wraps a byte stream pair as a transport.
  ///
  /// Writes the preamble to [output] immediately, frames every outgoing
  /// frame with the `u32` length prefix and parses incoming bytes into
  /// frames once the returned channel's stream is listened to. The peer's
  /// preamble is checked before any frame.
  ///
  /// A wrong magic or a zero length fails the stream with a
  /// [ProtocolException]; an unsupported preamble version fails it with a
  /// [SwitchboardException] carrying [StatusCode.unsupported]. A length
  /// above [maxFrameSize] fails it with a [SwitchboardException] carrying
  /// [StatusCode.frameTooLarge], without reading the body. After such an
  /// error the stream closes, and [output] is closed once the listener has
  /// seen the error and the end of the stream, so a mux layer can still
  /// send GOAWAY from its error handler.
  ///
  /// Outgoing bytes are fed to [output] with `addStream`, so that a sink
  /// that cannot keep up (a socket whose peer does not read) pauses the
  /// transport rather than buffering without bound: bytes it has not
  /// accepted yet wait in the transport, and while more than
  /// [outputHighWaterMark] bytes wait, the transport stops reading
  /// [input]. 0 disables the high-water mark. [output] must therefore not
  /// be written to by anyone else.
  ///
  /// When [input] ends, the stream ends and [output] is closed. Closing
  /// the returned sink closes [output] and stops reading [input]. If
  /// closing [output] (which first writes the buffered bytes) takes longer
  /// than [closeTimeout], the transport gives up: it calls [abort], if
  /// given, which should destroy the underlying connection.
  static StreamTransportChannel wrap(
    Stream<List<int>> input,
    StreamSink<List<int>> output, {
    int maxFrameSize = defaultMaxFrameSize,
    int outputHighWaterMark = defaultOutputHighWaterMark,
    Duration closeTimeout = defaultCloseTimeout,
    void Function()? abort,
  }) => StreamTransportChannel._(
    input,
    output,
    maxFrameSize: maxFrameSize,
    outputHighWaterMark: outputHighWaterMark,
    closeTimeout: closeTimeout,
    abort: abort,
  );

  /// Connects over TCP to [host] (a `String` or an `InternetAddress`) and
  /// [port], and wraps the socket with [fromSocket].
  static Future<StreamTransportChannel> connectTcp(
    dynamic host,
    int port, {
    int maxFrameSize = defaultMaxFrameSize,
    int outputHighWaterMark = defaultOutputHighWaterMark,
    Duration closeTimeout = defaultCloseTimeout,
  }) async {
    final socket = await Socket.connect(host, port);
    return fromSocket(
      socket,
      maxFrameSize: maxFrameSize,
      outputHighWaterMark: outputHighWaterMark,
      closeTimeout: closeTimeout,
    );
  }

  /// Wraps a connected [socket], enabling `TCP_NODELAY` where supported.
  ///
  /// [StreamTransportChannel.abort] destroys the socket.
  static StreamTransportChannel fromSocket(
    Socket socket, {
    int maxFrameSize = defaultMaxFrameSize,
    int outputHighWaterMark = defaultOutputHighWaterMark,
    Duration closeTimeout = defaultCloseTimeout,
  }) {
    try {
      socket.setOption(SocketOption.tcpNoDelay, true);
    } on Object catch (e) {
      _log.fine('cannot set TCP_NODELAY: $e');
    }
    return wrap(
      socket,
      socket,
      maxFrameSize: maxFrameSize,
      outputHighWaterMark: outputHighWaterMark,
      closeTimeout: closeTimeout,
      abort: socket.destroy,
    );
  }
}

/// A stream binding transport, created by [StreamTransport.wrap],
/// [StreamTransport.fromSocket] or [StreamTransport.connectTcp].
///
/// A `StreamChannel` of mux frames; see [StreamTransport.wrap] for the
/// behaviour. The extra members report output congestion and let the
/// connection be torn down.
final class StreamTransportChannel
    with StreamChannelMixin<Uint8List>
    implements FrameLimited, AbortableTransport, OutputBufferedTransport {
  StreamTransportChannel._(
    this._input,
    this._output, {
    required this.maxFrameSize,
    required this.outputHighWaterMark,
    required this.closeTimeout,
    void Function()? abort,
  }) : _decoder = StreamFrameDecoder(maxFrameSize: maxFrameSize),
       _abortHook = abort {
    _controller = StreamController<Uint8List>(
      onListen: _onListen,
      onPause: () => _inputSub?.pause(),
      onResume: () => _inputSub?.resume(),
      onCancel: _onCancel,
    );
    _sink = _StreamTransportSink(this);
    _out = StreamController<List<int>>(
      sync: true,
      onListen: _scheduleDrain,
      onResume: _scheduleDrain,
      onCancel: _onOutputCancel,
    );
    try {
      _output
          .addStream(_out.stream)
          .then<void>(
            (_) => _onOutputStreamDone(),
            onError: (Object error, StackTrace stackTrace) =>
                _onOutputError(error, stackTrace),
          );
      _output.done.then<void>(
        (_) {},
        onError: (Object error, StackTrace stackTrace) =>
            _onOutputError(error, stackTrace),
      );
    } on Object catch (e, st) {
      _onOutputError(e, st);
    }
    _write(StreamFraming.encodePreamble());
  }

  /// Largest incoming frame body accepted.
  @override
  final int maxFrameSize;

  /// Bytes waiting for the output above which the transport stops reading
  /// its input, until they drop to half of it. 0 means never.
  final int outputHighWaterMark;

  /// How long closing the output may take before the transport aborts.
  final Duration closeTimeout;

  final Stream<List<int>> _input;
  final StreamSink<List<int>> _output;
  final StreamFrameDecoder _decoder;
  final void Function()? _abortHook;
  late final StreamController<Uint8List> _controller;
  // The sink is handed to the user, who closes it.
  // ignore: close_sinks
  late final _StreamTransportSink _sink;
  // Closed by _drain once the output is closing and drained.
  // ignore: close_sinks
  late final StreamController<List<int>> _out;
  final Queue<List<int>> _outQueue = Queue<List<int>>();
  final Completer<void> _outputFinished = Completer<void>();
  StreamSubscription<List<int>>? _inputSub;
  int _outQueuedBytes = 0;
  int _outAcceptedBytes = 0;
  bool _drainScheduled = false;
  bool _outEndRequested = false;
  bool _outputStreamCompleted = false;
  bool _throttled = false;
  bool _listenerGone = false;
  bool _ended = false;
  bool _outputClosed = false;
  bool _aborted = false;
  Future<void>? _outputClose;

  @override
  Stream<Uint8List> get stream => _controller.stream;

  @override
  StreamSink<Uint8List> get sink => _sink;

  /// Bytes written to the transport that the output has not accepted yet,
  /// preamble and length prefixes included.
  @override
  int get bufferedOutputBytes => _outQueuedBytes;

  /// Total bytes the output has accepted, preamble and length prefixes
  /// included.
  @override
  int get acceptedOutputBytes => _outAcceptedBytes;

  /// Whether reading the input is paused because more than
  /// [outputHighWaterMark] bytes wait for the output.
  @override
  bool get isInputThrottled => _throttled;

  /// Destroys the connection: calls the `abort` hook given to
  /// [StreamTransport.wrap] (`Socket.destroy` for sockets), drops buffered
  /// output, ends the stream and completes the sink's `done`. Idempotent.
  @override
  void abort() {
    if (_aborted) {
      return;
    }
    _aborted = true;
    _log.fine(
      'stream transport: aborting with $_outQueuedBytes bytes unwritten',
    );
    _outputClosed = true;
    _dropOutput();
    _end();
    final hook = _abortHook;
    if (hook != null) {
      try {
        hook();
      } on Object catch (e) {
        _log.fine('stream transport abort failed: $e');
      }
    }
    if (!_outputFinished.isCompleted) {
      _outputFinished.complete();
    }
    _sink.complete();
  }

  // Input ---------------------------------------------------------------

  void _onListen() {
    if (_ended) {
      return;
    }
    _inputSub = _input.listen(_onChunk, onError: _fail, onDone: _onInputDone);
    if (_throttled) {
      _inputSub!.pause();
    }
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
    unawaited(_closeOutput());
  }

  /// Fails the stream with [error], ends it, then closes the output once
  /// the listener has seen both, so it can still write a last frame.
  void _fail(Object error, [StackTrace? stackTrace]) {
    if (_ended) {
      return;
    }
    _ended = true;
    _cancelInput();
    if (_listenerGone || !_controller.hasListener) {
      unawaited(_controller.close());
      unawaited(_closeOutput());
      return;
    }
    _controller.addError(error, stackTrace);
    _controller.close().then((_) => _closeOutput(), onError: (_) {});
  }

  void _end() {
    if (_ended) {
      return;
    }
    _ended = true;
    _cancelInput();
    unawaited(_controller.close());
  }

  void _cancelInput() {
    final sub = _inputSub;
    _inputSub = null;
    if (sub != null) {
      unawaited(sub.cancel());
    }
  }

  // Output --------------------------------------------------------------

  /// Largest chunk assembled from queued writes when the output resumes.
  static const int _coalesceLimit = 64 * 1024;

  bool get _canDeliver => _out.hasListener && !_out.isPaused && !_out.isClosed;

  void _write(List<int> bytes) {
    // Once the output is closing (explicitly, or automatically after the
    // stream ended) bytes are silently dropped, as StreamChannel requires.
    // After a failure the output stays open until the listener has seen
    // the error, so a last frame such as GOAWAY still goes out.
    if (_outputClosed || _outEndRequested) {
      return;
    }
    if (_outQueue.isEmpty && _canDeliver) {
      _outAcceptedBytes += bytes.length;
      _out.add(bytes);
      return;
    }
    _outQueue.add(bytes);
    _outQueuedBytes += bytes.length;
    _updateThrottle();
    if (_canDeliver) {
      _scheduleDrain();
    }
  }

  void _scheduleDrain() {
    if (_drainScheduled) {
      return;
    }
    _drainScheduled = true;
    scheduleMicrotask(_drain);
  }

  void _drain() {
    _drainScheduled = false;
    while (_outQueue.isNotEmpty && _canDeliver) {
      var chunk = _outQueue.removeFirst();
      if (_outQueue.isNotEmpty && chunk.length < _coalesceLimit) {
        final builder = BytesBuilder()..add(chunk);
        while (_outQueue.isNotEmpty &&
            builder.length + _outQueue.first.length <= _coalesceLimit) {
          builder.add(_outQueue.removeFirst());
        }
        chunk = builder.takeBytes();
      }
      _outQueuedBytes -= chunk.length;
      _outAcceptedBytes += chunk.length;
      _out.add(chunk);
    }
    _updateThrottle();
    if (_outEndRequested && _outQueue.isEmpty && !_out.isClosed) {
      unawaited(_out.close());
    }
  }

  /// Pauses the input while too much output waits, resumes it once half
  /// of it has been written.
  void _updateThrottle() {
    final mark = outputHighWaterMark;
    if (!_throttled) {
      if (mark > 0 && _outQueuedBytes > mark) {
        _throttled = true;
        _log.fine(
          'stream transport: $_outQueuedBytes bytes wait for the output, '
          'pausing input',
        );
        _inputSub?.pause();
      }
    } else if (_outQueuedBytes <= mark ~/ 2) {
      _throttled = false;
      _log.fine('stream transport: output drained, resuming input');
      _inputSub?.resume();
    }
  }

  void _dropOutput() {
    _outQueue.clear();
    _outQueuedBytes = 0;
    _updateThrottle();
  }

  void _onOutputStreamDone() {
    _outputStreamCompleted = true;
    _outputClosed = true;
    if (!_outputFinished.isCompleted) {
      _outputFinished.complete();
    }
  }

  void _onOutputCancel() {
    if (_out.isClosed && _outQueue.isEmpty) {
      // The end of the output stream was delivered: a normal close.
      return;
    }
    // The output stopped consuming (destroyed socket, cancelled
    // listener): nothing more can be written.
    _log.fine('stream transport: output gone');
    _outputClosed = true;
    _dropOutput();
    if (!_outputFinished.isCompleted) {
      _outputFinished.complete();
    }
  }

  void _onOutputError(Object error, StackTrace stackTrace) {
    _log.fine('stream transport output failed: $error');
    _outputClosed = true;
    _dropOutput();
    if (!_outputFinished.isCompleted) {
      _outputFinished.complete();
    }
    _fail(error, stackTrace);
  }

  void _send(Uint8List frame) => _write(StreamFraming.encodeFrame(frame));

  /// Closes the output once: writes what is buffered, then closes it, and
  /// completes the sink's `done`. Aborts after [closeTimeout]. Never
  /// throws.
  Future<void> _closeOutput() => _outputClose ??= _doCloseOutput();

  Future<void> _doCloseOutput() async {
    _outEndRequested = true;
    _drain();
    try {
      await _closeSequence().timeout(closeTimeout);
    } on TimeoutException {
      _log.fine(
        'stream transport: output not closed within $closeTimeout '
        '($_outQueuedBytes bytes unwritten)',
      );
      abort();
    } on Object catch (e) {
      _log.fine('stream transport close failed: $e');
    }
    _outputClosed = true;
    _sink.complete();
  }

  Future<void> _closeSequence() async {
    await _outputFinished.future;
    if (!_aborted && _outputStreamCompleted) {
      await _output.close();
    }
  }

  /// Local close: the stream ends before emitting anything else.
  Future<void> _closeLocal() {
    _end();
    return _closeOutput();
  }
}

class _StreamTransportSink implements StreamSink<Uint8List> {
  _StreamTransportSink(this._channel);

  final StreamTransportChannel _channel;
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
    _channel._send(event);
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
    unawaited(_channel._closeLocal());
  }

  @override
  Future<void> addStream(Stream<Uint8List> stream) async {
    await for (final frame in stream) {
      if (_closed) {
        break;
      }
      _channel._send(frame);
    }
  }

  @override
  Future<void> close() {
    _closed = true;
    unawaited(_channel._closeLocal());
    return _done.future;
  }

  @override
  Future<void> get done => _done.future;
}
