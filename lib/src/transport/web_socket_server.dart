/*
Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Author: Jan Boon <jan.boon@kaetemi.be>
*/

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:logging/logging.dart';
import 'package:stream_channel/stream_channel.dart';

import '../status.dart';
import 'framed_byte_transport.dart';
import 'stream_transport.dart';
import 'transport_capabilities.dart';
import 'web_socket_transport.dart';

final Logger _log = Logger('Switchboard.Transport');

/// The server side of the WebSocket binding with its own RFC 6455
/// implementation on `dart:io`, for listeners facing untrusted clients.
///
/// `dart:io`'s `WebSocket` assembles a fragmented message without bounding
/// its total size (64 fragments of 1 MiB arrive as one 64 MiB message even
/// with a 1 MiB per-frame limit), so a frame limit applied to complete
/// messages comes too late to protect memory. This transport performs the
/// HTTP upgrade itself, takes over the socket and reads frames with a
/// cumulative limit checked before each fragment is buffered. It negotiates
/// no extensions, so permessage-deflate is never used.
///
/// [IOWebSocketTransport.upgrade] remains available as the simpler
/// alternative built on `dart:io`'s `WebSocket`.
abstract final class WebSocketServerTransport {
  /// Default upper limit on an incoming message: 1 MiB, the same as
  /// `MuxOptions.defaultMaxFrameSize`.
  static const int defaultMaxFrameSize = WebSocketTransport.defaultMaxFrameSize;

  /// The GUID of RFC 6455 section 1.3, appended to the client's key.
  static const String _acceptGuid = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

  /// Upgrades [request] to a WebSocket and returns it as a transport.
  ///
  /// The handshake follows RFC 6455 section 4.2. A request that is not a
  /// WebSocket upgrade (not a `GET` over HTTP/1.1 with `Upgrade: websocket`
  /// and `Connection: Upgrade`) is answered `426 Upgrade Required` with
  /// `Upgrade: websocket`; a `Sec-WebSocket-Version` other than 13 is
  /// answered 426 with `Sec-WebSocket-Version: 13`; a missing or malformed
  /// `Sec-WebSocket-Key`, or a client offering subprotocols but not
  /// `switchboard`, gets `400 Bad Request`. In those cases the response is
  /// sent and the returned future fails with a [WebSocketException].
  /// Otherwise the response is `101 Switching Protocols`, selecting the
  /// `switchboard` subprotocol when it is offered (a client offering none
  /// is accepted) and no extensions.
  ///
  /// The transport then reads the socket itself:
  ///
  /// * Client frames must be masked; an unmasked frame, reserved bits or
  ///   opcodes, a fragmented or oversized control frame, or a continuation
  ///   outside a message fail the stream with a [ProtocolException] and the
  ///   connection is closed with code 1002.
  /// * A text message is a [ProtocolException] (close code 1003).
  /// * Binary messages, fragmented or not, become frames. The sum of the
  ///   fragments of a message is checked against [maxFrameSize] (0 = no
  ///   limit) before each fragment is buffered; a message over it fails the
  ///   stream with a [SwitchboardException] carrying
  ///   [StatusCode.frameTooLarge] and closes with code 1009.
  /// * Pings are answered with pongs; pongs are noted as signs of life.
  /// * A close frame from the client is echoed with its code, and the
  ///   stream ends.
  ///
  /// As with the stream binding, after a failure the transport stays
  /// writable until the stream's listener has seen the error and the end,
  /// so a mux layer can still send GOAWAY; then the close frame is sent.
  /// Closing the sink sends a close frame with code 1000. After its close
  /// frame, the transport closes its side of the connection and drains the
  /// socket until the client closes its own (at most [closeTimeout]).
  ///
  /// With [pingInterval], the client's liveness is checked at that
  /// interval: after an interval in which nothing arrived from the client,
  /// a ping is sent, and when two further intervals pass without anything
  /// arriving (pongs included), the connection is aborted. Intervals in
  /// which reading was paused, or the client was reading output that held
  /// back our reading, count as signs of life. Null (the default) leaves
  /// liveness to the mux keep-alive.
  ///
  /// Output is buffered and throttled as for `StreamTransport.wrap`, with
  /// [outputHighWaterMark] and [closeTimeout].
  ///
  /// [maxFrameSize] should agree with `MuxOptions.maxFrameSize`.
  static Future<WebSocketServerChannel> upgrade(
    HttpRequest request, {
    int maxFrameSize = defaultMaxFrameSize,
    Duration? pingInterval,
    int outputHighWaterMark = StreamTransport.defaultOutputHighWaterMark,
    Duration closeTimeout = StreamTransport.defaultCloseTimeout,
  }) async {
    final response = request.response;
    final headers = request.headers;
    if (request.method != 'GET' ||
        request.protocolVersion != '1.1' ||
        !_hasToken(headers, HttpHeaders.upgradeHeader, 'websocket') ||
        !_hasToken(headers, HttpHeaders.connectionHeader, 'upgrade')) {
      return _refuse(
        response,
        HttpStatus.upgradeRequired,
        'WebSocket upgrade required',
        {HttpHeaders.upgradeHeader: 'websocket'},
      );
    }
    if (_single(headers, 'sec-websocket-version') != '13') {
      return _refuse(
        response,
        HttpStatus.upgradeRequired,
        'unsupported WebSocket version',
        {'Sec-WebSocket-Version': '13'},
      );
    }
    final key = _single(headers, 'sec-websocket-key');
    if (key == null || !_validKey(key)) {
      return _refuse(
        response,
        HttpStatus.badRequest,
        'missing or malformed Sec-WebSocket-Key',
      );
    }
    final offered = offeredProtocols(request);
    String? protocol;
    if (offered.isNotEmpty) {
      if (!offered.contains(WebSocketTransport.subprotocol)) {
        return _refuse(
          response,
          HttpStatus.badRequest,
          'the ${WebSocketTransport.subprotocol} subprotocol is required',
        );
      }
      protocol = WebSocketTransport.subprotocol;
    }
    final accept = base64.encode(
      sha1.convert(ascii.encode('${key.trim()}$_acceptGuid')).bytes,
    );
    response
      ..statusCode = HttpStatus.switchingProtocols
      ..headers.set(HttpHeaders.connectionHeader, 'Upgrade')
      ..headers.set(HttpHeaders.upgradeHeader, 'websocket')
      ..headers.set('Sec-WebSocket-Accept', accept)
      ..headers.contentLength = 0;
    if (protocol != null) {
      response.headers.set('Sec-WebSocket-Protocol', protocol);
    }
    // Closed through the transport.
    // ignore: close_sinks
    final socket = await response.detachSocket();
    try {
      socket.setOption(SocketOption.tcpNoDelay, true);
    } on Object catch (e) {
      _log.fine('cannot set TCP_NODELAY: $e');
    }
    return WebSocketServerChannel._(
      socket,
      protocol: protocol,
      maxFrameSize: maxFrameSize,
      pingInterval: pingInterval,
      outputHighWaterMark: outputHighWaterMark,
      closeTimeout: closeTimeout,
    );
  }

  /// The subprotocols [request] offers in `Sec-WebSocket-Protocol`.
  static Set<String> offeredProtocols(HttpRequest request) => {
    for (final value
        in request.headers['Sec-WebSocket-Protocol'] ?? const <String>[])
      for (final part in value.split(','))
        if (part.trim().isNotEmpty) part.trim(),
  };

  static Future<Never> _refuse(
    HttpResponse response,
    int status,
    String message, [
    Map<String, String> headers = const {},
  ]) async {
    try {
      response.statusCode = status;
      headers.forEach(response.headers.set);
      response.write(message);
      // Not awaited: dart:io sends the response only once the request body
      // has arrived, which the client may withhold.
      unawaited(
        response.close().then(
          (_) {},
          onError: (Object e) => _log.fine('refused upgrade not answered: $e'),
        ),
      );
    } on Object catch (e) {
      _log.fine('cannot answer a refused WebSocket upgrade: $e');
    }
    throw WebSocketException('upgrade refused ($status): $message');
  }

  /// Whether the comma separated values of header [name] include [token],
  /// ignoring case.
  static bool _hasToken(HttpHeaders headers, String name, String token) {
    for (final value in headers[name] ?? const <String>[]) {
      for (final part in value.split(',')) {
        if (part.trim().toLowerCase() == token) {
          return true;
        }
      }
    }
    return false;
  }

  /// The value of header [name] if it occurs exactly once, else null.
  static String? _single(HttpHeaders headers, String name) {
    final values = headers[name];
    return values != null && values.length == 1 ? values.single.trim() : null;
  }

  /// A key is the base64 encoding of 16 bytes.
  static bool _validKey(String key) {
    try {
      return base64.decode(key.trim()).length == 16;
    } on FormatException {
      return false;
    }
  }
}

/// A WebSocket accepted by [WebSocketServerTransport.upgrade]: a transport
/// carrying one mux frame per binary message.
///
/// See [WebSocketServerTransport.upgrade] for the behaviour. The extra
/// members report output congestion, the close the client sent, and let
/// the connection be torn down.
final class WebSocketServerChannel
    with StreamChannelMixin<Uint8List>
    implements FrameLimited, AbortableTransport, OutputBufferedTransport {
  WebSocketServerChannel._(
    Socket socket, {
    required this.protocol,
    required this.maxFrameSize,
    required this.pingInterval,
    required int outputHighWaterMark,
    required Duration closeTimeout,
  }) : _framing = _WebSocketFraming(maxFrameSize) {
    _core = FramedByteTransport(
      socket,
      socket,
      _framing,
      outputHighWaterMark: outputHighWaterMark,
      closeTimeout: closeTimeout,
      abort: socket.destroy,
      linger: true,
    );
    final interval = pingInterval;
    if (interval != null) {
      _pingTimer = Timer.periodic(interval, _onPingTimer);
    }
  }

  final _WebSocketFraming _framing;
  late final FramedByteTransport _core;
  Timer? _pingTimer;
  int _silentIntervals = 0;
  int _lastAcceptedOutput = -1;

  /// The selected subprotocol: `switchboard`, or null if the client
  /// offered none.
  final String? protocol;

  /// Largest incoming message accepted, counting all its fragments; 0 for
  /// no limit.
  @override
  final int maxFrameSize;

  /// Interval of the transport's own pings, or null.
  final Duration? pingInterval;

  /// The code of the close frame the client sent, or null if none arrived
  /// or it carried no code.
  int? get closeCode => _framing.peerCloseCode;

  /// The reason of the close frame the client sent, or null.
  String? get closeReason => _framing.peerCloseReason;

  @override
  Stream<Uint8List> get stream => _core.stream;

  @override
  StreamSink<Uint8List> get sink => _core.sink;

  /// Bytes written to the transport that the socket has not accepted yet,
  /// WebSocket headers included.
  @override
  int get bufferedOutputBytes => _core.bufferedOutputBytes;

  /// Total bytes the socket has accepted, WebSocket headers included.
  @override
  int get acceptedOutputBytes => _core.acceptedOutputBytes;

  /// Whether reading the socket is paused because too much output waits.
  @override
  bool get isInputThrottled => _core.isInputThrottled;

  /// Destroys the socket, drops buffered output, ends the stream and
  /// completes the sink's `done`. Idempotent.
  @override
  void abort() {
    _stopPing();
    _core.abort();
  }

  void _onPingTimer(Timer timer) {
    if (_core.isEnded) {
      _stopPing();
      return;
    }
    final accepted = _core.acceptedOutputBytes;
    final alive =
        _framing.takeActivity() ||
        // Not reading, so silence says nothing about the client; or the
        // client is reading output that holds back our reading.
        (_core.isInputPaused && !_core.isInputThrottled) ||
        (_core.isInputThrottled && accepted != _lastAcceptedOutput);
    _lastAcceptedOutput = accepted;
    if (alive) {
      _silentIntervals = 0;
      return;
    }
    _silentIntervals++;
    if (_silentIntervals > 2) {
      _log.info('WebSocket transport: no answer to pings, aborting');
      abort();
      return;
    }
    _core.writeRaw(_WebSocketFraming.encodeFrame(_WebSocketFraming.opPing));
  }

  void _stopPing() {
    _pingTimer?.cancel();
    _pingTimer = null;
  }
}

/// RFC 6455 framing, server side: masked frames in, unmasked frames out.
class _WebSocketFraming extends ByteFraming {
  _WebSocketFraming(this.maxMessageSize);

  static const int opContinuation = 0x0;
  static const int opText = 0x1;
  static const int opBinary = 0x2;
  static const int opClose = 0x8;
  static const int opPing = 0x9;
  static const int opPong = 0xA;

  static const int closeProtocolError = 1002;
  static const int closeUnsupportedData = 1003;
  static const int closeInvalidPayload = 1007;
  static const int closeMessageTooBig = 1009;

  /// Largest buffer allocated at once for a frame payload, so that a
  /// claimed length is only backed by memory as the bytes arrive.
  static const int _pieceSize = 1024 * 1024;

  final int maxMessageSize;

  // Header of the frame being read.
  final Uint8List _header = Uint8List(14);
  int _headerFill = 0;
  int _headerNeeded = 2;

  // Frame being read.
  bool _inPayload = false;
  int _opcode = 0;
  bool _fin = false;
  final Uint8List _mask = Uint8List(4);
  int _payloadLength = 0;
  int _payloadRead = 0;
  Uint8List? _control;
  Uint8List? _piece;
  int _pieceFill = 0;

  // Data message being assembled.
  bool _inMessage = false;
  int _messageLength = 0;
  int _buffered = 0;
  final List<Uint8List> _fragments = [];

  bool _stopped = false;
  bool _closeSent = false;
  bool _activity = false;
  int _closeCode = WebSocketTransport.normalClosure;

  int? peerCloseCode;
  String? peerCloseReason;

  @override
  String get name => 'WebSocket transport';

  @override
  int get bufferedBytes => _buffered + (_inPayload ? 0 : _headerFill);

  /// Whether anything arrived since the last call.
  bool takeActivity() {
    final activity = _activity;
    _activity = false;
    return activity;
  }

  @override
  List<int> encode(Uint8List frame) => encodeFrame(opBinary, frame);

  @override
  List<int>? closing() {
    if (_closeSent) {
      return null;
    }
    _closeSent = true;
    return _closeFrame(_closeCode);
  }

  /// An unmasked server frame with FIN set.
  static Uint8List encodeFrame(int opcode, [List<int> payload = const []]) {
    final length = payload.length;
    final headerLength = length < 126
        ? 2
        : length <= 0xFFFF
        ? 4
        : 10;
    final out = Uint8List(headerLength + length);
    out[0] = 0x80 | opcode;
    if (length < 126) {
      out[1] = length;
    } else if (length <= 0xFFFF) {
      out[1] = 126;
      out[2] = length >> 8;
      out[3] = length & 0xFF;
    } else {
      out[1] = 127;
      for (var i = 0; i < 8; i++) {
        out[2 + i] = (length >> (8 * (7 - i))) & 0xFF;
      }
    }
    out.setRange(headerLength, headerLength + length, payload);
    return out;
  }

  static Uint8List _closeFrame(int? code) =>
      encodeFrame(opClose, code == null ? const [] : [code >> 8, code & 0xFF]);

  @override
  void parse(List<int> chunk, FramedByteTransport transport) {
    if (_stopped) {
      return;
    }
    _activity = true;
    var offset = 0;
    final length = chunk.length;
    while (offset < length && !_stopped) {
      if (_inPayload) {
        offset = _readPayload(chunk, offset, transport);
        continue;
      }
      while (_headerFill < _headerNeeded && offset < length) {
        _header[_headerFill++] = chunk[offset++];
      }
      if (_headerFill < _headerNeeded) {
        return;
      }
      if (_headerNeeded == 2) {
        final lengthCode = _header[1] & 0x7F;
        final needed =
            2 +
            (lengthCode == 126
                ? 2
                : lengthCode == 127
                ? 8
                : 0) +
            ((_header[1] & 0x80) != 0 ? 4 : 0);
        if (needed > 2) {
          _headerNeeded = needed;
          continue;
        }
      }
      _startFrame(transport);
    }
  }

  ProtocolException _protocolError(String reason) {
    _closeCode = closeProtocolError;
    return ProtocolException('WebSocket: $reason');
  }

  void _startFrame(FramedByteTransport transport) {
    final b0 = _header[0];
    final b1 = _header[1];
    final fin = (b0 & 0x80) != 0;
    final opcode = b0 & 0x0F;
    if ((b0 & 0x70) != 0) {
      throw _protocolError('reserved bits set, no extension was negotiated');
    }
    if ((b1 & 0x80) == 0) {
      throw _protocolError('unmasked frame from the client');
    }
    var length = b1 & 0x7F;
    var position = 2;
    if (length == 126) {
      length = (_header[2] << 8) | _header[3];
      position = 4;
    } else if (length == 127) {
      if ((_header[2] & 0x80) != 0) {
        throw _protocolError('frame length over 63 bits');
      }
      length = 0;
      for (var i = 2; i < 10; i++) {
        length = (length << 8) | _header[i];
      }
      position = 10;
    }
    _mask.setRange(0, 4, _header, position);
    _headerFill = 0;
    _headerNeeded = 2;
    switch (opcode) {
      case opContinuation:
        if (!_inMessage) {
          throw _protocolError('continuation frame outside a message');
        }
      case opBinary:
        if (_inMessage) {
          throw _protocolError('new message inside a fragmented message');
        }
      case opText:
        _closeCode = closeUnsupportedData;
        throw ProtocolException('text WebSocket message');
      case opClose || opPing || opPong:
        if (!fin) {
          throw _protocolError('fragmented control frame');
        }
        if (length > 125) {
          throw _protocolError('control frame of $length bytes');
        }
      default:
        throw _protocolError('reserved opcode $opcode');
    }
    _opcode = opcode;
    _fin = fin;
    _payloadLength = length;
    _payloadRead = 0;
    if (opcode == opBinary || opcode == opContinuation) {
      final limit = maxMessageSize;
      // Checked before anything of the fragment is buffered.
      if (limit > 0 && _messageLength + length > limit) {
        _closeCode = closeMessageTooBig;
        throw SwitchboardException.of(
          StatusCode.frameTooLarge,
          'message of at least ${_messageLength + length} bytes exceeds '
          'limit of $limit',
        );
      }
      _inMessage = true;
      _messageLength += length;
      _control = null;
      _piece = null;
    } else {
      _control = Uint8List(length);
    }
    _inPayload = true;
    if (length == 0) {
      _endFrame(transport);
    }
  }

  int _readPayload(List<int> chunk, int offset, FramedByteTransport t) {
    final remaining = _payloadLength - _payloadRead;
    final Uint8List target;
    final int targetOffset;
    final int take;
    final control = _control;
    if (control != null) {
      target = control;
      targetOffset = _payloadRead;
      take = min(remaining, chunk.length - offset);
    } else {
      var piece = _piece;
      if (piece == null || _pieceFill == piece.length) {
        piece = _piece = Uint8List(min(remaining, _pieceSize));
        _pieceFill = 0;
        _fragments.add(piece);
      }
      target = piece;
      targetOffset = _pieceFill;
      take = min(piece.length - _pieceFill, chunk.length - offset);
      _pieceFill += take;
      _buffered += take;
    }
    final mask = _mask;
    final maskOffset = _payloadRead;
    for (var i = 0; i < take; i++) {
      target[targetOffset + i] = chunk[offset + i] ^ mask[(maskOffset + i) & 3];
    }
    _payloadRead += take;
    if (_payloadRead == _payloadLength) {
      _endFrame(t);
    }
    return offset + take;
  }

  void _endFrame(FramedByteTransport transport) {
    _inPayload = false;
    final control = _control;
    _control = null;
    switch (_opcode) {
      case opPing:
        transport.writeRaw(encodeFrame(opPong, control!));
      case opPong:
        break;
      case opClose:
        _onClose(control!, transport);
      default:
        _piece = null;
        if (_fin) {
          final message = _assemble();
          _fragments.clear();
          _messageLength = 0;
          _buffered = 0;
          _inMessage = false;
          transport.deliver(message);
        }
    }
  }

  Uint8List _assemble() {
    if (_fragments.length == 1) {
      return _fragments.single;
    }
    final out = Uint8List(_messageLength);
    var at = 0;
    for (final fragment in _fragments) {
      out.setRange(at, at + fragment.length, fragment);
      at += fragment.length;
    }
    return out;
  }

  void _onClose(Uint8List payload, FramedByteTransport transport) {
    int? code;
    var reason = '';
    if (payload.length == 1) {
      throw _protocolError('close frame with a one byte payload');
    }
    if (payload.length >= 2) {
      code = (payload[0] << 8) | payload[1];
      if (!_validCloseCode(code)) {
        throw _protocolError('invalid close code $code');
      }
      try {
        reason = utf8.decode(payload.sublist(2));
      } on FormatException {
        _closeCode = closeInvalidPayload;
        throw ProtocolException('WebSocket: close reason is not UTF-8');
      }
    }
    peerCloseCode = code;
    peerCloseReason = reason;
    _stopped = true;
    _log.fine('WebSocket transport: client closed with ${code ?? 'no code'}');
    if (!_closeSent) {
      _closeSent = true;
      transport.writeRaw(_closeFrame(code));
    }
    transport.endByPeer();
  }

  /// Codes a peer may send (RFC 6455 section 7.4 and the IANA registry).
  static bool _validCloseCode(int code) =>
      (code >= 1000 && code <= 1003) ||
      (code >= 1007 && code <= 1014) ||
      (code >= 3000 && code <= 4999);
}
