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

/// An 8-byte name: UTF-8, zero padded on the right, compared bytewise.
///
/// Used for procedure ids and service types. A name is immutable and cheap
/// to compare; the wire form is exactly 8 bytes.
///
/// Names beginning with `_` are reserved for the protocol.
class Name {
  /// Creates a name from its 8 wire bytes.
  ///
  /// Throws [FormatException] if [bytes] is not 8 long or if a non-zero
  /// byte follows a zero byte.
  factory Name.fromBytes(List<int> bytes) {
    if (bytes.length != byteLength) {
      throw FormatException('name must be $byteLength bytes', bytes);
    }
    final copy = Uint8List.fromList(bytes);
    var seenZero = false;
    for (final b in copy) {
      if (b == 0) {
        seenZero = true;
      } else if (seenZero) {
        throw FormatException('non-zero byte after zero byte in name', bytes);
      }
    }
    return Name._(copy);
  }

  /// Creates a name from a string of at most 8 bytes of UTF-8.
  ///
  /// Throws [ArgumentError] if the encoded string is longer than 8 bytes or
  /// contains a zero byte.
  factory Name(String text) {
    final encoded = utf8.encode(text);
    if (encoded.length > byteLength) {
      throw ArgumentError.value(
        text,
        'text',
        'name longer than $byteLength bytes of UTF-8',
      );
    }
    if (encoded.contains(0)) {
      throw ArgumentError.value(text, 'text', 'name contains a zero byte');
    }
    final bytes = Uint8List(byteLength);
    bytes.setRange(0, encoded.length, encoded);
    return Name._(bytes);
  }

  Name._(this._bytes);

  static const int byteLength = 8;

  /// The empty (all zero) name.
  static final Name empty = Name._(Uint8List(byteLength));

  final Uint8List _bytes;

  /// The 8 wire bytes. The returned view must not be modified.
  Uint8List get bytes => _bytes;

  bool get isEmpty => _bytes[0] == 0;

  /// True for names starting with `_`, reserved for the protocol.
  bool get isReserved => _bytes[0] == 0x5F;

  /// Length of the name in bytes, without padding.
  int get length {
    var n = 0;
    while (n < byteLength && _bytes[n] != 0) {
      n++;
    }
    return n;
  }

  /// Writes the 8 bytes into [out] at [offset].
  void writeTo(Uint8List out, int offset) {
    out.setRange(offset, offset + byteLength, _bytes);
  }

  // Not inlined: the Dart 3.13.5 AOT compiler hoists the receiver's
  // `_bytes` load out of an enclosing loop, above the null check, when
  // the receiver is a nullable variable compared as `n == null || n == x`
  // inside the loop (the JIT does not), and a native binary then dies
  // with SIGSEGV on the first such loop with a null receiver. See
  // tool/aot_smoke.dart and https://github.com/dart-lang/sdk/issues/64528.
  @pragma('vm:never-inline')
  @override
  bool operator ==(Object other) {
    if (other is! Name) {
      return false;
    }
    for (var i = 0; i < byteLength; i++) {
      if (_bytes[i] != other._bytes[i]) {
        return false;
      }
    }
    return true;
  }

  @override
  int get hashCode {
    var h = 0;
    for (var i = 0; i < byteLength; i++) {
      h = (h * 31 + _bytes[i]) & 0x3FFFFFFF;
    }
    return h;
  }

  @override
  String toString() =>
      utf8.decode(_bytes.sublist(0, length), allowMalformed: true);
}
