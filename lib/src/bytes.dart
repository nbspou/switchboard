/*
Polyverse Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Authors:
  Jan Boon <jan.boon@kaetemi.be>
  Claude Fable 5.1 <noreply@anthropic.com>
*/

import 'dart:convert';
import 'dart:typed_data';

import 'name.dart';

/// Sequential little-endian reader over a byte list.
///
/// Every read throws [FormatException] when the input is too short, so
/// codecs can decode without length checks of their own.
class ByteReader {
  ByteReader(this.bytes, [this.offset = 0]);

  final Uint8List bytes;
  int offset;

  int get remaining => bytes.length - offset;
  bool get isDone => offset >= bytes.length;

  void _need(int n, String what) {
    if (offset + n > bytes.length) {
      throw FormatException('truncated $what at offset $offset');
    }
  }

  int u8([String what = 'u8']) {
    _need(1, what);
    return bytes[offset++];
  }

  int u16([String what = 'u16']) {
    _need(2, what);
    final v = bytes[offset] | (bytes[offset + 1] << 8);
    offset += 2;
    return v;
  }

  int u24([String what = 'u24']) {
    _need(3, what);
    final v =
        bytes[offset] | (bytes[offset + 1] << 8) | (bytes[offset + 2] << 16);
    offset += 3;
    return v;
  }

  int u32([String what = 'u32']) {
    _need(4, what);
    final v =
        bytes[offset] |
        (bytes[offset + 1] << 8) |
        (bytes[offset + 2] << 16) |
        (bytes[offset + 3] << 24);
    offset += 4;
    // Bitwise operations are 32-bit signed when compiled to JavaScript.
    return v < 0 ? v + 0x100000000 : v;
  }

  /// Assembled without shifting past 32 bits, so that it is correct when
  /// compiled to JavaScript as well as on the VM.
  int u48([String what = 'u48']) {
    _need(6, what);
    final lo =
        bytes[offset] |
        (bytes[offset + 1] << 8) |
        (bytes[offset + 2] << 16) |
        (bytes[offset + 3] << 24);
    final hi = bytes[offset + 4] | (bytes[offset + 5] << 8);
    offset += 6;
    return (lo < 0 ? lo + 0x100000000 : lo) + hi * 0x100000000;
  }

  Name name([String what = 'name']) {
    _need(Name.byteLength, what);
    final n = Name.fromBytes(
      Uint8List.sublistView(bytes, offset, offset + Name.byteLength),
    );
    offset += Name.byteLength;
    return n;
  }

  /// A `u8` length followed by that many bytes of UTF-8.
  String string8([String what = 'string']) {
    final len = u8('$what length');
    _need(len, what);
    final s = utf8.decode(
      Uint8List.sublistView(bytes, offset, offset + len),
      allowMalformed: true,
    );
    offset += len;
    return s;
  }

  /// Exactly [n] bytes as a view.
  Uint8List take(int n, [String what = 'bytes']) {
    _need(n, what);
    final v = Uint8List.sublistView(bytes, offset, offset + n);
    offset += n;
    return v;
  }

  /// Everything left, as a view. Empty if nothing is left.
  Uint8List rest() {
    final v = Uint8List.sublistView(bytes, offset);
    offset = bytes.length;
    return v;
  }
}

/// Growable little-endian writer.
class ByteWriter {
  ByteWriter([int initialCapacity = 64])
    : _buf = Uint8List(initialCapacity < 8 ? 8 : initialCapacity);

  Uint8List _buf;
  int _len = 0;

  int get length => _len;

  void _ensure(int n) {
    if (_len + n <= _buf.length) {
      return;
    }
    var cap = _buf.length * 2;
    while (cap < _len + n) {
      cap *= 2;
    }
    final grown = Uint8List(cap);
    grown.setRange(0, _len, _buf);
    _buf = grown;
  }

  void u8(int v) {
    assert(v >= 0 && v <= 0xFF);
    _ensure(1);
    _buf[_len++] = v;
  }

  void u16(int v) {
    assert(v >= 0 && v <= 0xFFFF);
    _ensure(2);
    _buf[_len++] = v & 0xFF;
    _buf[_len++] = (v >> 8) & 0xFF;
  }

  void u24(int v) {
    assert(v >= 0 && v <= 0xFFFFFF);
    _ensure(3);
    _buf[_len++] = v & 0xFF;
    _buf[_len++] = (v >> 8) & 0xFF;
    _buf[_len++] = (v >> 16) & 0xFF;
  }

  void u32(int v) {
    assert(v >= 0 && v <= 0xFFFFFFFF);
    _ensure(4);
    _buf[_len++] = v & 0xFF;
    _buf[_len++] = (v >> 8) & 0xFF;
    _buf[_len++] = (v >> 16) & 0xFF;
    _buf[_len++] = (v >> 24) & 0xFF;
  }

  /// Split without shifting past 32 bits, so that it is correct when
  /// compiled to JavaScript as well as on the VM.
  void u48(int v) {
    assert(v >= 0 && v <= 0xFFFFFFFFFFFF);
    _ensure(6);
    final hi = v ~/ 0x100000000;
    final lo = v - hi * 0x100000000;
    _buf[_len++] = lo & 0xFF;
    _buf[_len++] = (lo >> 8) & 0xFF;
    _buf[_len++] = (lo >> 16) & 0xFF;
    _buf[_len++] = (lo >> 24) & 0xFF;
    _buf[_len++] = hi & 0xFF;
    _buf[_len++] = (hi >> 8) & 0xFF;
  }

  void name(Name n) {
    _ensure(Name.byteLength);
    n.writeTo(_buf, _len);
    _len += Name.byteLength;
  }

  /// A `u8` length followed by UTF-8. Throws [ArgumentError] over 255 bytes.
  void string8(String s) {
    final encoded = utf8.encode(s);
    if (encoded.length > 0xFF) {
      throw ArgumentError.value(s, 's', 'string longer than 255 bytes');
    }
    u8(encoded.length);
    bytes(encoded);
  }

  void bytes(List<int> b) {
    _ensure(b.length);
    _buf.setRange(_len, _len + b.length, b);
    _len += b.length;
  }

  /// The written bytes as a copy of exactly [length] bytes.
  Uint8List toBytes() =>
      Uint8List.fromList(Uint8List.sublistView(_buf, 0, _len));
}

/// Parses a hex string like `02 02 00 01` (spaces optional) into bytes.
/// Intended for test vectors.
Uint8List hexBytes(String hex) {
  final clean = hex.replaceAll(RegExp(r'\s+'), '');
  if (clean.length.isOdd) {
    throw FormatException('odd length hex', hex);
  }
  final out = Uint8List(clean.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

/// Formats bytes as upper-case hex separated by spaces.
String hexString(List<int> bytes) => bytes
    .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
    .join(' ');
