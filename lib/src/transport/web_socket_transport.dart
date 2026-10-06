/*
Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Author: Jan Boon <jan.boon@kaetemi.be>
*/

import 'dart:async';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../status.dart';
import 'transport_capabilities.dart';

final Logger _log = Logger('Switchboard.Transport');

/// The WebSocket binding of the transport layer: one mux frame per binary
/// WebSocket message.
///
/// See the wiki page "Switchboard Transport", section "WebSocket binding".
abstract final class WebSocketTransport {
  /// The WebSocket subprotocol name.
  static const String subprotocol = 'switchboard';

  /// WebSocket close code used for every close. The reason a connection
  /// ends travels in the mux GOAWAY; client WebSocket implementations only
  /// allow 1000 and 3000 to 4999 anyway.
  static const int normalClosure = 1000;

  /// Default upper limit on an incoming message: 1 MiB, the same as
  /// `MuxOptions.defaultMaxFrameSize`.
  static const int defaultMaxFrameSize = 1024 * 1024;

  /// Wraps an established (or connecting) WebSocket as a transport.
  ///
  /// Binary messages become frames. A text message is a protocol error:
  /// the stream fails with a [ProtocolException], ends, and the WebSocket
  /// is closed once the listener has seen the error (so a mux layer can
  /// still send GOAWAY). A binary message longer than [maxFrameSize]
  /// (0 for no limit) fails the stream the same way with a
  /// [SwitchboardException] carrying [StatusCode.frameTooLarge]. The
  /// WebSocket is always closed with code 1000.
  ///
  /// [maxFrameSize] should agree with `MuxOptions.maxFrameSize`. The
  /// check runs on complete messages: the WebSocket implementation has
  /// already assembled the message in memory, so this limit protects the
  /// layers above but does not bound the memory a peer can make the
  /// WebSocket implementation use. On servers, accept connections with
  /// `WebSocketServerTransport.upgrade` (`dart:io`), which bounds whole
  /// messages before buffering them and never negotiates compression, or
  /// put a proxy with a message size limit in front.
  static StreamChannel<Uint8List> wrap(
    WebSocketChannel channel, {
    int maxFrameSize = defaultMaxFrameSize,
  }) => _WebSocketTransportChannel(channel, maxFrameSize);

  /// Connects to [uri] (`ws://` or `wss://`), offering the `switchboard`
  /// subprotocol, and wraps the connection with [maxFrameSize] as in
  /// [wrap].
  ///
  /// Throws whatever the WebSocket implementation reports if the
  /// connection cannot be established.
  static Future<StreamChannel<Uint8List>> connect(
    Uri uri, {
    int maxFrameSize = defaultMaxFrameSize,
  }) async {
    final channel = WebSocketChannel.connect(
      uri,
      protocols: const [subprotocol],
    );
    try {
      await channel.ready;
    } on Object {
      unawaited(channel.sink.close().then((_) {}, onError: (_) {}));
      rethrow;
    }
    return wrap(channel, maxFrameSize: maxFrameSize);
  }
}

class _WebSocketTransportChannel
    with StreamChannelMixin<Uint8List>
    implements FrameLimited {
  _WebSocketTransportChannel(this._ws, this.maxFrameSize) {
    _controller = StreamController<Uint8List>(
      onListen: _onListen,
      onPause: () => _wsSub?.pause(),
      onResume: () => _wsSub?.resume(),
      onCancel: () => _listenerGone = true,
    );
    _sink = _WebSocketTransportSink(this);
    // Failures also surface on the stream; keep [ready] from reporting an
    // unhandled error.
    _ws.ready.then((_) {}, onError: (_) {});
  }

  final WebSocketChannel _ws;

  @override
  final int maxFrameSize;

  late final StreamController<Uint8List> _controller;
  // The sink is handed to the user, who closes it.
  // ignore: close_sinks
  late final _WebSocketTransportSink _sink;
  StreamSubscription<dynamic>? _wsSub;
  bool _listenerGone = false;
  bool _ended = false;
  Future<void>? _closeFuture;

  @override
  Stream<Uint8List> get stream => _controller.stream;

  @override
  StreamSink<Uint8List> get sink => _sink;

  void _onListen() {
    if (_ended) {
      return;
    }
    _wsSub = _ws.stream.listen(_onMessage, onError: _onError, onDone: _onDone);
  }

  void _onMessage(Object? message) {
    if (_ended) {
      return;
    }
    final Uint8List frame;
    if (message is Uint8List) {
      frame = message;
    } else if (message is List<int>) {
      frame = Uint8List.fromList(message);
    } else {
      _log.warning('WebSocket transport: text message received');
      _fail(ProtocolException('text WebSocket message'));
      return;
    }
    if (maxFrameSize > 0 && frame.length > maxFrameSize) {
      _log.warning(
        'WebSocket transport: message of ${frame.length} bytes exceeds '
        '$maxFrameSize',
      );
      _fail(
        SwitchboardException.of(
          StatusCode.frameTooLarge,
          'message of ${frame.length} bytes exceeds limit of $maxFrameSize',
        ),
      );
      return;
    }
    if (!_listenerGone) {
      _controller.add(frame);
    }
  }

  void _onError(Object error, StackTrace stackTrace) {
    _log.fine('WebSocket transport error: $error');
    _fail(error, stackTrace: stackTrace);
  }

  void _onDone() {
    if (_ended) {
      return;
    }
    _ended = true;
    _wsSub = null;
    unawaited(_controller.close());
    // After the stream closes, the sink is closed automatically.
    unawaited(closeWebSocket());
  }

  void _fail(Object error, {StackTrace? stackTrace}) {
    if (_ended) {
      return;
    }
    _ended = true;
    final sub = _wsSub;
    _wsSub = null;
    if (sub != null) {
      unawaited(sub.cancel());
    }
    if (_listenerGone || !_controller.hasListener) {
      unawaited(_controller.close());
      unawaited(closeWebSocket());
      return;
    }
    _controller.addError(error, stackTrace);
    _controller.close().then((_) => closeWebSocket(), onError: (_) {});
  }

  void send(Uint8List frame) {
    // Dropped silently once the WebSocket is closing. After a failure it
    // stays open until the listener has seen the error, so a last frame
    // such as GOAWAY still goes out.
    if (_closeFuture != null) {
      return;
    }
    try {
      _ws.sink.add(frame);
    } on Object catch (e) {
      _log.fine('WebSocket transport send failed: $e');
    }
  }

  /// Closes the WebSocket once and completes the sink's `done`. Never
  /// throws.
  Future<void> closeWebSocket() {
    return _closeFuture ??= () async {
      try {
        await _ws.sink.close(WebSocketTransport.normalClosure);
      } on Object catch (e) {
        _log.fine('WebSocket transport close failed: $e');
      }
      _sink.complete();
    }();
  }

  /// Local close: the stream ends before emitting anything else.
  Future<void> closeLocal() {
    if (!_ended) {
      _ended = true;
      final sub = _wsSub;
      _wsSub = null;
      if (sub != null) {
        unawaited(sub.cancel());
      }
      unawaited(_controller.close());
    }
    return closeWebSocket();
  }
}

class _WebSocketTransportSink implements StreamSink<Uint8List> {
  _WebSocketTransportSink(this._channel);

  final _WebSocketTransportChannel _channel;
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
      throw StateError('WebSocket transport sink is closed');
    }
    _channel.send(event);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {
    if (_closed) {
      throw StateError('WebSocket transport sink is closed');
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
