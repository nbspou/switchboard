/*
Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Author: Jan Boon <jan.boon@kaetemi.be>
*/

import 'dart:typed_data';

import '../bytes.dart';
import '../name.dart';
import '../status.dart';

/// The kind of a Talk message, bits `0x30` of the flags byte.
///
/// The enum index is the wire value: `(flags & 0x30) >> 4`.
enum TalkKind {
  /// Kind 0: plain message, request, final response or chained response.
  message,

  /// Kind 1: a non-final response to a `STREAM` request.
  streamItem,

  /// Kind 2: abort response, cancel, or channel abort, by the ids present.
  abort,

  /// Kind 3: response timeout extension (heartbeat).
  extend,
}

/// One Talk message header plus payload, as carried in one mux subframe.
///
/// A [requestId] or [responseId] of 0 means the field is absent (0 is never
/// a valid id on the wire). A null [procedure] means the procedure field is
/// absent, which receivers treat as the all-zero name.
///
/// See the wiki page "Switchboard Talk" for the layout and the flag rules.
class TalkFrame {
  /// Creates a frame. Nothing is validated until [encode].
  TalkFrame({
    required this.kind,
    this.procedure,
    this.requestId = 0,
    this.responseId = 0,
    this.stream = false,
    Uint8List? payload,
  }) : payload = payload ?? _emptyPayload;

  /// Flag bit: an 8-byte procedure name follows.
  static const int flagHasProcedure = 0x01;

  /// Flag bit: a request id follows; the sender expects a response.
  static const int flagHasRequest = 0x02;

  /// Flag bit: a response id follows; this responds to the peer's request.
  static const int flagHasResponse = 0x04;

  /// Flag bit: with [flagHasRequest], the sender accepts stream items.
  static const int flagStream = 0x08;

  /// Mask of the kind field.
  static const int kindMask = 0x30;

  /// Reserved bits; receiving either set is a channel protocol error.
  static const int reservedMask = 0xC0;

  /// Largest valid request or response id (`u24`).
  static const int maxId = 0xFFFFFF;

  static final Uint8List _emptyPayload = Uint8List(0);

  /// Message kind.
  final TalkKind kind;

  /// Procedure name, or null when the field is absent.
  final Name? procedure;

  /// The sender's request id, or 0 if the sender expects no response.
  final int requestId;

  /// The peer's request id this frame responds to, or 0 if not a response.
  final int responseId;

  /// The `STREAM` flag: the sender accepts `STREAM_ITEM` responses.
  final bool stream;

  /// The payload. After [decode] this is a view into the decoded buffer.
  final Uint8List payload;

  /// True when [requestId] is present.
  bool get hasRequest => requestId != 0;

  /// True when [responseId] is present.
  bool get hasResponse => responseId != 0;

  /// The flags byte this frame encodes to.
  int get flags =>
      (procedure != null ? flagHasProcedure : 0) |
      (hasRequest ? flagHasRequest : 0) |
      (hasResponse ? flagHasResponse : 0) |
      (stream ? flagStream : 0) |
      (kind.index << 4);

  /// The status carried by an [TalkKind.abort] frame.
  ///
  /// An empty payload decodes as [Status.ok]. Throws [StateError] for other
  /// kinds.
  Status get status {
    if (kind != TalkKind.abort) {
      throw StateError('only abort frames carry a status');
    }
    return Status.decode(payload);
  }

  /// Encodes to the short canonical form: optional fields are present only
  /// when set.
  ///
  /// Throws [ArgumentError] if the frame breaks a rule a receiver would
  /// reject as a protocol error, so that this implementation never sends
  /// such a frame.
  Uint8List encode() {
    if (requestId < 0 || requestId > maxId) {
      throw ArgumentError.value(requestId, 'requestId', 'must fit in u24');
    }
    if (responseId < 0 || responseId > maxId) {
      throw ArgumentError.value(responseId, 'responseId', 'must fit in u24');
    }
    final error = _ruleViolation(
      kind: kind,
      hasProcedure: procedure != null,
      hasRequest: hasRequest,
      hasResponse: hasResponse,
      stream: stream,
      payloadLength: payload.length,
    );
    if (error != null) {
      throw ArgumentError(error);
    }
    if (kind == TalkKind.extend && payload.isNotEmpty) {
      throw ArgumentError('EXTEND payload must be empty');
    }
    final length =
        1 +
        (procedure != null ? Name.byteLength : 0) +
        (hasRequest ? 3 : 0) +
        (hasResponse ? 3 : 0) +
        payload.length;
    final out = Uint8List(length);
    out[0] = flags;
    var offset = 1;
    final name = procedure;
    if (name != null) {
      name.writeTo(out, offset);
      offset += Name.byteLength;
    }
    if (hasRequest) {
      out[offset++] = requestId & 0xFF;
      out[offset++] = (requestId >> 8) & 0xFF;
      out[offset++] = (requestId >> 16) & 0xFF;
    }
    if (hasResponse) {
      out[offset++] = responseId & 0xFF;
      out[offset++] = (responseId >> 8) & 0xFF;
      out[offset++] = (responseId >> 16) & 0xFF;
    }
    out.setRange(offset, length, payload);
    return out;
  }

  /// Decodes one Talk message.
  ///
  /// Throws [ProtocolException] for a truncated header, reserved bits, an
  /// invalid flag combination, an invalid procedure name, or a violation of
  /// the kind rules. The payload of an `EXTEND` is discarded, since
  /// receivers ignore it.
  static TalkFrame decode(Uint8List bytes) {
    final reader = ByteReader(bytes);
    try {
      final flags = reader.u8('flags');
      if (flags & reservedMask != 0) {
        throw ProtocolException(
          'reserved talk flag bits set: 0x${flags.toRadixString(16)}',
        );
      }
      final kind = TalkKind.values[(flags & kindMask) >> 4];
      final hasProcedure = flags & flagHasProcedure != 0;
      final hasRequest = flags & flagHasRequest != 0;
      final hasResponse = flags & flagHasResponse != 0;
      final stream = flags & flagStream != 0;
      final procedure = hasProcedure ? reader.name('procedure') : null;
      final requestId = hasRequest ? reader.u24('request id') : 0;
      if (hasRequest && requestId == 0) {
        throw ProtocolException('request id 0');
      }
      final responseId = hasResponse ? reader.u24('response id') : 0;
      if (hasResponse && responseId == 0) {
        throw ProtocolException('response id 0');
      }
      final payload = reader.rest();
      final error = _ruleViolation(
        kind: kind,
        hasProcedure: hasProcedure,
        hasRequest: hasRequest,
        hasResponse: hasResponse,
        stream: stream,
        payloadLength: payload.length,
      );
      if (error != null) {
        throw ProtocolException(error);
      }
      return TalkFrame(
        kind: kind,
        procedure: procedure,
        requestId: requestId,
        responseId: responseId,
        stream: stream,
        payload: kind == TalkKind.extend ? _emptyPayload : payload,
      );
    } on FormatException catch (e) {
      throw ProtocolException(e.message);
    }
  }

  /// The flag and kind rules shared by [encode] and [decode]. Returns a
  /// description of the first violation, or null if the combination is
  /// valid.
  static String? _ruleViolation({
    required TalkKind kind,
    required bool hasProcedure,
    required bool hasRequest,
    required bool hasResponse,
    required bool stream,
    required int payloadLength,
  }) {
    if (stream && !hasRequest) {
      return 'STREAM without HAS_REQUEST';
    }
    switch (kind) {
      case TalkKind.message:
        if (!hasResponse && !hasProcedure) {
          return hasRequest
              ? 'request without procedure'
              : 'plain message without procedure';
        }
      case TalkKind.streamItem:
        if (!hasResponse) {
          return 'STREAM_ITEM without HAS_RESPONSE';
        }
      case TalkKind.abort:
        if (hasRequest && hasResponse) {
          return 'ABORT with both request and response id';
        }
        if (payloadLength == 1) {
          return 'ABORT payload is not a status';
        }
      case TalkKind.extend:
        if (!hasResponse) {
          return 'EXTEND without HAS_RESPONSE';
        }
        if (hasRequest) {
          return 'EXTEND with HAS_REQUEST';
        }
    }
    return null;
  }

  @override
  bool operator ==(Object other) {
    if (other is! TalkFrame ||
        other.kind != kind ||
        other.procedure != procedure ||
        other.requestId != requestId ||
        other.responseId != responseId ||
        other.stream != stream ||
        other.payload.length != payload.length) {
      return false;
    }
    for (var i = 0; i < payload.length; i++) {
      if (other.payload[i] != payload[i]) {
        return false;
      }
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
    kind,
    procedure,
    requestId,
    responseId,
    stream,
    payload.length,
  );

  @override
  String toString() {
    final parts = <String>[kind.name];
    if (procedure != null) {
      parts.add('"$procedure"');
    }
    if (hasRequest) {
      parts.add('req=$requestId');
    }
    if (hasResponse) {
      parts.add('resp=$responseId');
    }
    if (stream) {
      parts.add('stream');
    }
    parts.add('${payload.length} bytes');
    return 'TalkFrame(${parts.join(', ')})';
  }
}
