/*
Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Author: Jan Boon <jan.boon@kaetemi.be>
*/

import 'dart:convert';
import 'dart:typed_data';

/// Status codes shared by every layer of the protocol.
///
/// Codes 0 to 16 are numerically identical to the gRPC status codes.
/// Codes from 32 upward are Switchboard specific.
/// See the wiki page "Switchboard Status Codes".
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
  moved(37);

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
/// The reason is for logs only; programs must not branch on it.
class Status {
  const Status(this.code, [this.reason = '']);

  Status.of(StatusCode code, [String reason = '']) : this(code.code, reason);

  /// Numeric code, 0 to 0xFFFF.
  final int code;

  /// Human readable reason, may be empty.
  final String reason;

  static const Status ok = Status(0);

  /// The well-known code, or null for unknown or application codes.
  StatusCode? get known => StatusCode.fromCode(code);

  bool get isOk => code == 0;

  /// Application codes are 256 and above and are only valid in Talk aborts.
  bool get isApplicationCode => code >= 256;

  /// Encodes as `u16 code` followed by the UTF-8 reason.
  Uint8List encode() {
    if (code < 0 || code > 0xFFFF) {
      throw ArgumentError.value(code, 'code', 'must fit in u16');
    }
    final reasonBytes = utf8.encode(reason);
    final out = Uint8List(2 + reasonBytes.length);
    out[0] = code & 0xFF;
    out[1] = (code >> 8) & 0xFF;
    out.setRange(2, out.length, reasonBytes);
    return out;
  }

  /// Decodes a status payload. An empty payload decodes as [Status.ok].
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
    final reason = bytes.length > 2
        ? utf8.decode(bytes.sublist(2), allowMalformed: true)
        : '';
    return Status(code, reason);
  }

  @override
  bool operator ==(Object other) =>
      other is Status && other.code == code && other.reason == reason;

  @override
  int get hashCode => Object.hash(code, reason);

  @override
  String toString() {
    final name = known?.name ?? 'code $code';
    return reason.isEmpty ? name : '$name: $reason';
  }
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
