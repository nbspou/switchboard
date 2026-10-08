/*
Polyverse Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Authors:
  Jan Boon <jan.boon@kaetemi.be>
  Claude Opus 5.5 <noreply@anthropic.com>
*/

/// The machinery shared by the transports that run a framing over a pair
/// of byte streams: the stream binding ([StreamTransportChannel]) and the
/// server side of the WebSocket binding (`WebSocketServerChannel`).
///
/// Internal to the package; not exported.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:logging/logging.dart';

final Logger _log = Logger('Switchboard.Transport');

/// The wire format a [FramedByteTransport] runs over its byte streams.
abstract class ByteFraming {
  /// Name of the transport for log messages.
  String get name;

  /// Bytes written before anything else, or null for none.
  List<int>? get preamble => null;

  /// Parses [chunk], the next piece of input.
  ///
  /// Complete frames go to [FramedByteTransport.deliver], control replies
  /// (a WebSocket pong) to [FramedByteTransport.writeRaw], and the end of
  /// the peer's stream announced inside the framing (a WebSocket close) to
  /// [FramedByteTransport.endByPeer]. Throws a `SwitchboardException`
  /// (including a `ProtocolException`) when the input is invalid; the
  /// transport then fails its stream with it.
  void parse(List<int> chunk, FramedByteTransport transport);

  /// Bytes of an incomplete frame held by the parser, for logs.
  int get bufferedBytes;

  /// Encodes one outgoing frame.
  List<int> encode(Uint8List frame);

  /// Called once when the output is about to close; returns the bytes to
  /// write last (a WebSocket close frame), or null.
  List<int>? closing() => null;
}

/// A transport over an input stream and an output sink of bytes, framed by
/// a [ByteFraming].
///
/// Behaviour, as documented on `StreamTransport.wrap`:
///
/// * The stream yields one frame per event, parsed from [_input] once the
///   stream is listened to. A parse error or an input error fails the
///   stream, ends it, and the output is closed once the listener has seen
///   both, so the layer above can still send a last frame (GOAWAY).
/// * Output is fed to the sink with `addStream`, so a sink that cannot
///   keep up pauses the transport rather than buffering inside the sink;
///   above [outputHighWaterMark] queued bytes the input is paused until
///   half has drained.
/// * Closing the sink ends the stream and closes the output; a close that
///   takes longer than [closeTimeout] aborts.
/// * With [linger], the input is not dropped when the transport closes
///   while the peer may still be sending: it is read and discarded until
///   the peer closes its side or [closeTimeout] expires (then the
///   connection is aborted). Closing a TCP socket with unread input makes
///   the kernel reset the connection, and a reset can destroy the last
///   frames still in flight to the peer, such as a GOAWAY.
class FramedByteTransport {
  /// Starts the transport; writes the framing's preamble at once.
  FramedByteTransport(
    this._input,
    this._output,
    this._framing, {
    required this.outputHighWaterMark,
    required this.closeTimeout,
    void Function()? abort,
    this.linger = false,
  }) : _abortHook = abort {
    _controller = StreamController<Uint8List>(
      onListen: _onListen,
      onPause: _onListenerPause,
      onResume: _onListenerResume,
      onCancel: _onCancel,
    );
    _sink = _FramedSink(this);
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
    final preamble = _framing.preamble;
    if (preamble != null) {
      _write(preamble);
    }
  }

  /// Bytes waiting for the output above which the input is paused, until
  /// they drop to half of it. 0 means never.
  final int outputHighWaterMark;

  /// How long closing the output (and, with [linger], waiting for the peer
  /// to close its side) may take before the transport aborts.
  final Duration closeTimeout;

  /// Whether input is drained after the transport closes; see the class
  /// documentation.
  final bool linger;

  final Stream<List<int>> _input;
  final StreamSink<List<int>> _output;
  final ByteFraming _framing;
  final void Function()? _abortHook;
  late final StreamController<Uint8List> _controller;
  // The sink is handed to the user, who closes it.
  // ignore: close_sinks
  late final _FramedSink _sink;
  // Closed by _drain once the output is closing and drained.
  // ignore: close_sinks
  late final StreamController<List<int>> _out;
  final Queue<List<int>> _outQueue = Queue<List<int>>();
  final Completer<void> _outputFinished = Completer<void>();
  StreamSubscription<List<int>>? _inputSub;
  Timer? _lingerTimer;
  int _outQueuedBytes = 0;
  int _outAcceptedBytes = 0;
  bool _drainScheduled = false;
  bool _outEndRequested = false;
  bool _outputStreamCompleted = false;
  bool _throttled = false;
  bool _listenerGone = false;
  bool _ended = false;
  bool _inputListened = false;
  bool _listenerPaused = false;
  bool _inputDone = false;
  bool _lingering = false;
  bool _outputClosed = false;
  bool _aborted = false;
  Future<void>? _outputClose;

  /// Frames received.
  Stream<Uint8List> get stream => _controller.stream;

  /// Frames to send; closing it closes the transport.
  StreamSink<Uint8List> get sink => _sink;

  /// Bytes written that the output has not accepted yet.
  int get bufferedOutputBytes => _outQueuedBytes;

  /// Total bytes the output has accepted.
  int get acceptedOutputBytes => _outAcceptedBytes;

  /// Whether reading the input is paused because too much output waits.
  bool get isInputThrottled => _throttled;

  /// Whether reading the input is paused for any reason (throttled, or the
  /// listener paused its subscription).
  bool get isInputPaused => _inputSub?.isPaused ?? false;

  /// Whether reading the input has started: the stream was listened to, or
  /// the transport started draining the input.
  bool get isInputStarted => _inputListened;

  /// Whether the stream has ended.
  bool get isEnded => _ended;

  /// Destroys the connection: calls the abort hook, drops buffered output,
  /// ends the stream and completes the sink's `done`. Idempotent.
  void abort() {
    if (_aborted) {
      return;
    }
    _aborted = true;
    _log.fine(
      '${_framing.name}: aborting with $_outQueuedBytes bytes unwritten',
    );
    _outputClosed = true;
    _dropOutput();
    _end();
    _stopLinger();
    _cancelInput();
    final hook = _abortHook;
    if (hook != null) {
      try {
        hook();
      } on Object catch (e) {
        _log.fine('${_framing.name} abort failed: $e');
      }
    }
    if (!_outputFinished.isCompleted) {
      _outputFinished.complete();
    }
    _sink.complete();
  }

  // Interface for the framing ---------------------------------------------

  /// Delivers a parsed frame to the stream's listener.
  void deliver(Uint8List frame) {
    if (!_ended && !_listenerGone) {
      _controller.add(frame);
    }
  }

  /// Writes [bytes] to the output as they are, behind what is queued.
  /// Dropped once the output is closing.
  void writeRaw(List<int> bytes) => _write(bytes);

  /// The peer closed its stream inside the framing: the stream ends and the
  /// output is closed. With [linger] the input is still drained until the
  /// peer closes the connection.
  void endByPeer() {
    if (_ended) {
      return;
    }
    _end();
    unawaited(_closeOutput());
  }

  // Input -----------------------------------------------------------------

  void _onListen() {
    if (_ended) {
      return;
    }
    _inputListened = true;
    _inputSub = _input.listen(
      _onChunk,
      onError: _onInputError,
      onDone: _onInputDone,
    );
    if (_throttled) {
      _inputSub!.pause();
    }
  }

  void _onListenerPause() {
    if (_lingering || _listenerPaused) {
      return;
    }
    _listenerPaused = true;
    _inputSub?.pause();
  }

  void _onListenerResume() {
    if (_lingering || !_listenerPaused) {
      return;
    }
    _listenerPaused = false;
    _inputSub?.resume();
  }

  void _onCancel() {
    // The StreamChannel contract: cancelling the subscription has no
    // effect on the sink, and the channel must still notice the peer
    // closing. Release the listener's pause, keeping any output throttle,
    // then keep reading and drop frames.
    _listenerGone = true;
    _onListenerResume();
  }

  void _onChunk(List<int> chunk) {
    if (_ended) {
      // Lingering: the input is drained and discarded.
      return;
    }
    try {
      _framing.parse(chunk, this);
    } on Exception catch (e, st) {
      _log.warning('${_framing.name}: $e');
      _fail(e, st, drain: true);
    }
  }

  void _onInputDone() {
    _inputDone = true;
    _inputSub = null;
    _stopLinger();
    if (_ended) {
      return;
    }
    if (_framing.bufferedBytes > 0) {
      _log.fine(
        '${_framing.name} input ended inside a frame '
        '(${_framing.bufferedBytes} bytes buffered)',
      );
    }
    _end();
    // After the stream closes, the sink is closed automatically.
    unawaited(_closeOutput());
  }

  void _onInputError(Object error, StackTrace stackTrace) =>
      _fail(error, stackTrace, drain: false);

  /// Fails the stream with [error], ends it, then closes the output once
  /// the listener has seen both, so it can still write a last frame.
  /// [drain] (with [linger]) keeps reading the input until the peer closes:
  /// true for errors in what the peer sent, false when the input itself
  /// failed.
  void _fail(Object error, StackTrace? stackTrace, {required bool drain}) {
    if (_ended) {
      if (!drain) {
        // The input failed while draining: nothing more will come.
        _stopLinger();
        _cancelInput();
      }
      return;
    }
    _ended = true;
    if (drain) {
      _startLinger();
    } else {
      _cancelInput();
    }
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
    _startLinger();
    unawaited(_controller.close());
  }

  /// Keeps reading (and discarding) the input until it ends, for at most
  /// [closeTimeout], when [linger] is set; otherwise stops reading.
  void _startLinger() {
    if (!linger || _inputDone || _aborted) {
      _cancelInput();
      return;
    }
    if (_lingering) {
      return;
    }
    _lingering = true;
    final sub = _inputSub;
    if (sub == null) {
      if (_inputListened) {
        // Already cancelled.
        return;
      }
      // Never listened to: listen now, only to drain.
      _inputListened = true;
      _inputSub = _input.listen(
        _onChunk,
        onError: _onInputError,
        onDone: _onInputDone,
      );
    } else if (_listenerPaused) {
      // The listener no longer matters. A pause for output throttling
      // stays: a peer that does not read our output is not drained, and is
      // reset when the close times out.
      _listenerPaused = false;
      sub.resume();
    }
    _lingerTimer = Timer(closeTimeout, () {
      _lingerTimer = null;
      if (!_inputDone) {
        _log.fine(
          '${_framing.name}: peer did not close within $closeTimeout, '
          'aborting',
        );
        abort();
      }
    });
  }

  void _stopLinger() {
    _lingerTimer?.cancel();
    _lingerTimer = null;
  }

  void _cancelInput() {
    final sub = _inputSub;
    _inputSub = null;
    if (sub != null) {
      unawaited(sub.cancel());
    }
  }

  // Output ----------------------------------------------------------------

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
          '${_framing.name}: $_outQueuedBytes bytes wait for the output, '
          'pausing input',
        );
        _inputSub?.pause();
      }
    } else if (_outQueuedBytes <= mark ~/ 2) {
      _throttled = false;
      _log.fine('${_framing.name}: output drained, resuming input');
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
    _log.fine('${_framing.name}: output gone');
    _outputClosed = true;
    _dropOutput();
    if (!_outputFinished.isCompleted) {
      _outputFinished.complete();
    }
  }

  void _onOutputError(Object error, StackTrace stackTrace) {
    _log.fine('${_framing.name} output failed: $error');
    _outputClosed = true;
    _dropOutput();
    if (!_outputFinished.isCompleted) {
      _outputFinished.complete();
    }
    // Nothing can be written any more, so there is no point in draining.
    _fail(error, stackTrace, drain: false);
    _stopLinger();
    _cancelInput();
  }

  /// Sends one frame.
  void send(Uint8List frame) => _write(_framing.encode(frame));

  /// Closes the output once: writes the framing's last bytes and what is
  /// buffered, then closes it, and completes the sink's `done`. Aborts
  /// after [closeTimeout]. Never throws.
  Future<void> _closeOutput() => _outputClose ??= _doCloseOutput();

  Future<void> _doCloseOutput() async {
    final last = _framing.closing();
    if (last != null) {
      _write(last);
    }
    _outEndRequested = true;
    _drain();
    try {
      await _closeSequence().timeout(closeTimeout);
    } on TimeoutException {
      _log.fine(
        '${_framing.name}: output not closed within $closeTimeout '
        '($_outQueuedBytes bytes unwritten)',
      );
      abort();
    } on Object catch (e) {
      _log.fine('${_framing.name} close failed: $e');
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
  Future<void> closeLocal() {
    _end();
    return _closeOutput();
  }
}

class _FramedSink implements StreamSink<Uint8List> {
  _FramedSink(this._transport);

  final FramedByteTransport _transport;
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

  String get _name => _transport._framing.name;

  @override
  void add(Uint8List event) {
    if (_closed) {
      throw StateError('$_name sink is closed');
    }
    _transport.send(event);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {
    if (_closed) {
      throw StateError('$_name sink is closed');
    }
    // Errors are not forwarded to the peer: the sink closes and reports
    // the error through [done], as StreamChannel allows.
    _closed = true;
    _error = error;
    _errorStackTrace = stackTrace;
    _done.future.ignore();
    complete();
    unawaited(_transport.closeLocal());
  }

  @override
  Future<void> addStream(Stream<Uint8List> stream) async {
    await for (final frame in stream) {
      if (_closed) {
        break;
      }
      _transport.send(frame);
    }
  }

  @override
  Future<void> close() {
    _closed = true;
    unawaited(_transport.closeLocal());
    return _done.future;
  }

  @override
  Future<void> get done => _done.future;
}
