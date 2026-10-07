/*
Polyverse Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Authors:
  Jan Boon <jan.boon@kaetemi.be>
  Claude Fable 5.1 <noreply@anthropic.com>
  Claude Opus 5.5 <noreply@anthropic.com>
*/

import 'dart:convert';
import 'dart:typed_data';

/// Status codes shared by every layer of the protocol.
///
/// Codes 0 to 16 are numerically identical to the gRPC status codes.
/// Codes from 32 upward are Switchboard specific.
/// See the wiki page "Polyverse Switchboard Status Codes".
enum StatusCode {
  ok(0),
  cancelled(1),
  unknown(2),
  invalidArgument(3),
  deadlineExceeded(4),
  notFound(5),
  alreadyExists(6),
  permissionDenied(7),
  resourceExhausted(8),
  failedPrecondition(9),
  aborted(10),
  outOfRange(11),
  unimplemented(12),
  internal(13),
  unavailable(14),
  dataLoss(15),
  unauthenticated(16),
  protocolError(32),
  goingAway(33),
  connectionLost(34),
  frameTooLarge(35),
  unsupported(36),
  moved(37),
  relocated(38);

  const StatusCode(this.code);

  /// Numeric wire value.
  final int code;

  static final Map<int, StatusCode> _byCode = {
    for (final value in values) value.code: value,
  };

  /// The well-known code for [code], or null if it is not in the table.
  static StatusCode? fromCode(int code) => _byCode[code];
}

/// A status: a `u16` code and an optional human readable reason.
///
/// The reason is for logs only; programs must not branch on it. A code's
/// definition may place fixed fields before the reason (`MOVED` and
/// `RELOCATED`, see `MovedStatus`); this class does not interpret them: a
/// decoded status keeps the bytes after the code exactly as received,
/// [encode] writes them back unchanged (so relaying a status is lossless),
/// and [reason] is their UTF-8 decoding.
class Status {
  /// A status with [code] and the human readable [reason].
  const Status(this.code, [this.reason = '']) : _body = null;

  /// A status with a well-known [code] and the human readable [reason].
  Status.of(StatusCode code, [String reason = '']) : this(code.code, reason);

  Status._decoded(this.code, this.reason, this._body);

  /// Numeric code, 0 to 0xFFFF.
  final int code;

  /// Human readable reason, may be empty. For a decoded status, the bytes
  /// after the code decoded as UTF-8 (malformed sequences replaced), fixed
  /// fields included.
  final String reason;

  /// The bytes after the code as received; null when built from [reason].
  final Uint8List? _body;

  static const Status ok = Status(0);

  /// The well-known code, or null for unknown or application codes.
  StatusCode? get known => StatusCode.fromCode(code);

  bool get isOk => code == 0;

  /// Application codes are 256 and above and are only valid in Talk aborts.
  bool get isApplicationCode => code >= 256;

  /// Encodes as `u16 code` followed by the UTF-8 reason, or, for a decoded
  /// status, by the bytes after the code exactly as they were received.
  Uint8List encode() {
    if (code < 0 || code > 0xFFFF) {
      throw ArgumentError.value(code, 'code', 'must fit in u16');
    }
    final body = _body ?? utf8.encode(reason);
    final out = Uint8List(2 + body.length);
    out[0] = code & 0xFF;
    out[1] = (code >> 8) & 0xFF;
    out.setRange(2, out.length, body);
    return out;
  }

  /// Decodes a status payload. An empty payload decodes as [Status.ok].
  ///
  /// The bytes after the code become the [reason] and are also kept as
  /// they are, so that [encode] reproduces [bytes] exactly.
  ///
  /// Throws [FormatException] if the payload is exactly one byte, which
  /// cannot be a status.
  static Status decode(Uint8List bytes) {
    if (bytes.isEmpty) {
      return ok;
    }
    if (bytes.length < 2) {
      throw const FormatException('status payload shorter than 2 bytes');
    }
    final code = bytes[0] | (bytes[1] << 8);
    if (bytes.length == 2) {
      return Status(code);
    }
    final body = Uint8List.fromList(bytes.sublist(2));
    return Status._decoded(code, utf8.decode(body, allowMalformed: true), body);
  }

  @override
  bool operator ==(Object other) =>
      other is Status &&
      other.code == code &&
      other.reason == reason &&
      ((_body == null && other._body == null) || _sameBody(other));

  bool _sameBody(Status other) {
    final a = _body ?? utf8.encode(reason);
    final b = other._body ?? utf8.encode(other.reason);
    if (a.length != b.length) {
      return false;
    }
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) {
        return false;
      }
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(code, reason);

  /// The code's name and the reason; a reason with control characters or
  /// malformed UTF-8 (fixed fields before it, say) is shown as hex bytes.
  @override
  String toString() {
    final name = known?.name ?? 'code $code';
    if (reason.isEmpty) {
      return name;
    }
    if (_printable.hasMatch(reason)) {
      return '$name: $reason';
    }
    final body = _body ?? utf8.encode(reason);
    final hex = [for (final b in body) b.toRadixString(16).padLeft(2, '0')]
        .join(' ');
    return '$name: [$hex]';
  }

  static final RegExp _printable = RegExp(r'^[^\x00-\x1F\x7F\uFFFD]*$');
}

/// Base exception for every failure reported by the library.
class SwitchboardException implements Exception {
  SwitchboardException(this.status);

  SwitchboardException.of(StatusCode code, [String reason = ''])
    : status = Status.of(code, reason);

  final Status status;

  StatusCode? get code => status.known;

  @override
  String toString() => 'SwitchboardException: $status';
}

/// A peer violated the protocol.
class ProtocolException extends SwitchboardException {
  ProtocolException(String reason)
    : super(Status.of(StatusCode.protocolError, reason));

  @override
  String toString() => 'ProtocolException: ${status.reason}';
}
