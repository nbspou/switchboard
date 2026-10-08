/*
Polyverse Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Authors:
  Jan Boon <jan.boon@kaetemi.be>
  Claude Opus 5.5 <noreply@anthropic.com>
  GPT-6 Astra <noreply@anthropic.com>
*/

import 'dart:typed_data';

import '../status.dart';

/// The wire format of the stream binding, without any I/O: the 8-byte
/// preamble and the frames prefixed with a `u32` little-endian length.
///
/// Platform independent. `StreamTransport` (which needs `dart:io` for its
/// TCP helpers) builds on it. See the wiki page "Polyverse Switchboard Transport",
/// section "Stream binding".
abstract final class StreamFraming {
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
}

/// Incremental parser for the receiving side of the stream binding.
///
/// Feed it chunks of any size with [add]; it emits complete frame bodies
/// in order. Frames may be split across chunks at any byte and a chunk may
/// hold any number of frames.
class StreamFrameDecoder {
  /// Creates a decoder that first expects the peer preamble.
  StreamFrameDecoder({this.maxFrameSize = StreamFraming.defaultMaxFrameSize});

  /// Largest accepted frame body; 0 means no limit.
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
  /// Throws [ProtocolException] on a wrong magic or a zero length,
  /// [SwitchboardException] with [StatusCode.unsupported] on a preamble
  /// version other than [StreamFraming.version], and [SwitchboardException]
  /// with [StatusCode.frameTooLarge] on a length above [maxFrameSize].
  /// Frames completed before the offending bytes have already been passed
  /// to [onFrame]. After a throw the decoder must not be used again.
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
          if (end - pos < StreamFraming.preambleLength) {
            break;
          }
          _checkPreamble(data, pos);
          pos += StreamFraming.preambleLength;
          _preambleReceived = true;
          continue;
        }
        if (end - pos < StreamFraming.lengthPrefixSize) {
          break;
        }
        final length = _u32(data, pos);
        if (length == 0) {
          throw ProtocolException('zero length frame');
        }
        if (maxFrameSize > 0 && length > maxFrameSize) {
          throw SwitchboardException.of(
            StatusCode.frameTooLarge,
            'frame of $length bytes exceeds limit of $maxFrameSize',
          );
        }
        final start = pos + StreamFraming.lengthPrefixSize;
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

  /// Little-endian `u32`, correct when compiled to JavaScript too, where
  /// bitwise operations are 32-bit signed.
  static int _u32(Uint8List data, int pos) {
    final v =
        data[pos] |
        (data[pos + 1] << 8) |
        (data[pos + 2] << 16) |
        (data[pos + 3] << 24);
    return v < 0 ? v + 0x100000000 : v;
  }

  void _checkPreamble(Uint8List data, int pos) {
    for (var i = 0; i < StreamFraming.magic.length; i++) {
      if (data[pos + i] != StreamFraming.magic[i]) {
        throw ProtocolException('wrong preamble magic');
      }
    }
    final version = data[pos + 4] | (data[pos + 5] << 8);
    if (version != StreamFraming.version) {
      throw SwitchboardException.of(
        StatusCode.unsupported,
        'unsupported stream binding version $version',
      );
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
