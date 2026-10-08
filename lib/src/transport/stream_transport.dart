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

import 'package:logging/logging.dart';
import 'package:stream_channel/stream_channel.dart';

import '../status.dart';
import 'framed_byte_transport.dart';
import 'stream_framing.dart';
import 'transport_capabilities.dart';

export 'stream_framing.dart';

final Logger _log = Logger('Switchboard.Transport');

/// The stream binding of the transport layer: an 8-byte preamble, then
/// frames prefixed with a `u32` little-endian length.
///
/// Used for TCP, TLS, Unix domain sockets, serial lines and any other
/// ordered byte stream. See the wiki page "Polyverse Switchboard Transport". The
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
  /// Cancelling the stream subscription, even while paused, leaves the
  /// sink writable and keeps reading to observe the peer closing; input
  /// paused for output throttling stays paused until the output drains.
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
  ///
  /// Unlike [wrap], the transport lingers when it closes: after its last
  /// bytes and the end of its output have been written, it keeps reading
  /// and discarding input until the peer closes its side, for at most
  /// [closeTimeout] (then the socket is destroyed). Closing a socket with
  /// unread input makes the operating system reset the connection, and the
  /// reset can destroy frames still on their way to the peer, such as the
  /// GOAWAY sent just before the close. The stream still ends at once and
  /// the sink's `done` completes when the output is closed.
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
    return StreamTransportChannel._(
      socket,
      socket,
      maxFrameSize: maxFrameSize,
      outputHighWaterMark: outputHighWaterMark,
      closeTimeout: closeTimeout,
      abort: socket.destroy,
      linger: true,
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
    Stream<List<int>> input,
    StreamSink<List<int>> output, {
    required this.maxFrameSize,
    required int outputHighWaterMark,
    required Duration closeTimeout,
    void Function()? abort,
    bool linger = false,
  }) : _core = FramedByteTransport(
         input,
         output,
         _StreamBindingFraming(StreamFrameDecoder(maxFrameSize: maxFrameSize)),
         outputHighWaterMark: outputHighWaterMark,
         closeTimeout: closeTimeout,
         abort: abort,
         linger: linger,
       );

  final FramedByteTransport _core;

  /// Largest incoming frame body accepted.
  @override
  final int maxFrameSize;

  /// Bytes waiting for the output above which the transport stops reading
  /// its input, until they drop to half of it. 0 means never.
  int get outputHighWaterMark => _core.outputHighWaterMark;

  /// How long closing the output may take before the transport aborts.
  Duration get closeTimeout => _core.closeTimeout;

  @override
  Stream<Uint8List> get stream => _core.stream;

  @override
  StreamSink<Uint8List> get sink => _core.sink;

  /// Bytes written to the transport that the output has not accepted yet,
  /// preamble and length prefixes included.
  @override
  int get bufferedOutputBytes => _core.bufferedOutputBytes;

  /// Total bytes the output has accepted, preamble and length prefixes
  /// included.
  @override
  int get acceptedOutputBytes => _core.acceptedOutputBytes;

  /// Whether reading the input is paused because more than
  /// [outputHighWaterMark] bytes wait for the output.
  @override
  bool get isInputThrottled => _core.isInputThrottled;

  /// Destroys the connection: calls the `abort` hook given to
  /// [StreamTransport.wrap] (`Socket.destroy` for sockets), drops buffered
  /// output, ends the stream and completes the sink's `done`. Idempotent.
  @override
  void abort() => _core.abort();
}

/// The stream binding wire format for [FramedByteTransport].
class _StreamBindingFraming extends ByteFraming {
  _StreamBindingFraming(this._decoder);

  final StreamFrameDecoder _decoder;

  @override
  String get name => 'stream transport';

  @override
  List<int> get preamble => StreamFraming.encodePreamble();

  @override
  void parse(List<int> chunk, FramedByteTransport transport) =>
      _decoder.add(chunk, transport.deliver);

  @override
  int get bufferedBytes => _decoder.bufferedBytes;

  @override
  List<int> encode(Uint8List frame) => StreamFraming.encodeFrame(frame);
}
