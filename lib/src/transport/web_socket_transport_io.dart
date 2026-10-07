/*
Polyverse Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Authors:
  Jan Boon <jan.boon@kaetemi.be>
  Claude Opus 5.5 <noreply@anthropic.com>
*/

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/io.dart';

import 'web_socket_server.dart';
import 'web_socket_transport.dart';

/// The WebSocket binding on `dart:io`: accepting connections on an
/// `HttpServer` and connecting with control over compression.
///
/// Both helpers turn per-message compression off by default. A compressed
/// message can inflate to far more than its wire size before any limit
/// applies, which is why the transport's frame limit is only meaningful
/// without it. Even so, `dart:io` assembles each message, fragments
/// included, before the transport's check sees it, so a peer can make it
/// allocate a message of any size first. For listeners facing untrusted
/// clients, use [WebSocketServerTransport], which bounds whole messages
/// before buffering them. See [WebSocketTransport] for the binding
/// itself.
abstract final class IOWebSocketTransport {
  /// Upgrades [request] to a WebSocket and wraps it with
  /// [WebSocketTransport.wrap] and [maxFrameSize].
  ///
  /// Selects the `switchboard` subprotocol when the client offers it and
  /// accepts clients that offer none, as the binding allows. A client that
  /// offers only other subprotocols is refused (the response is an HTTP
  /// error and the returned future fails). Fails as
  /// `WebSocketTransformer.upgrade` does for requests that are not
  /// WebSocket upgrades.
  ///
  /// [maxFrameSize] should agree with `MuxOptions.maxFrameSize`.
  static Future<StreamChannel<Uint8List>> upgrade(
    HttpRequest request, {
    int maxFrameSize = WebSocketTransport.defaultMaxFrameSize,
    bool compression = false,
  }) async {
    // Closed through the transport.
    // ignore: close_sinks
    final ws = await WebSocketTransformer.upgrade(
      request,
      protocolSelector: _selectProtocol,
      compression: _compression(compression),
    );
    return WebSocketTransport.wrap(
      IOWebSocketChannel(ws),
      maxFrameSize: maxFrameSize,
    );
  }

  /// Connects to [uri] (`ws://` or `wss://`), offering the `switchboard`
  /// subprotocol, and wraps the connection with [maxFrameSize] as
  /// [WebSocketTransport.connect] does, but with compression off unless
  /// [compression] is set.
  ///
  /// Throws whatever `WebSocket.connect` reports if the connection cannot
  /// be established.
  static Future<StreamChannel<Uint8List>> connect(
    Uri uri, {
    int maxFrameSize = WebSocketTransport.defaultMaxFrameSize,
    bool compression = false,
  }) async {
    // Closed through the transport.
    // ignore: close_sinks
    final ws = await WebSocket.connect(
      uri.toString(),
      protocols: const [WebSocketTransport.subprotocol],
      compression: _compression(compression),
    );
    return WebSocketTransport.wrap(
      IOWebSocketChannel(ws),
      maxFrameSize: maxFrameSize,
    );
  }

  static CompressionOptions _compression(bool enabled) => enabled
      ? CompressionOptions.compressionDefault
      : CompressionOptions.compressionOff;

  static String _selectProtocol(List<String> protocols) {
    if (protocols.contains(WebSocketTransport.subprotocol)) {
      return WebSocketTransport.subprotocol;
    }
    throw WebSocketException(
      'client offered ${protocols.join(', ')} but not '
      '${WebSocketTransport.subprotocol}',
    );
  }
}
