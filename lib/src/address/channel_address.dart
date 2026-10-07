/*
Polyverse Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Authors:
  Jan Boon <jan.boon@kaetemi.be>
  Claude Fable 5.1 <noreply@anthropic.com>
  Claude Sonnet 5.5 <noreply@anthropic.com>
*/

import 'dart:convert';
import 'dart:typed_data';

import '../bytes.dart';
import '../name.dart';
import '../status.dart';
import 'service_address.dart';

/// The address header and application payload of a mux OPEN payload.
///
/// Wire layout: a flags byte, then service type, instance, shard slot and
/// host hint when their flag is set, then the opaque application payload.
class ChannelAddress {
  /// Creates a channel address. A null [payload] is the empty payload.
  ///
  /// Throws [RangeError] if [instance] is outside u48 or [shard] outside
  /// u32, and [ArgumentError] if [host] exceeds 255 bytes of UTF-8.
  ChannelAddress({
    this.type,
    this.instance = 0,
    this.shard,
    this.host,
    Uint8List? payload,
  }) : payload = payload ?? Uint8List(0) {
    if (instance < 0 || instance > maxInstance) {
      throw RangeError.range(instance, 0, maxInstance, 'instance');
    }
    final s = shard;
    if (s != null && (s < 0 || s > 0xFFFFFFFF)) {
      throw RangeError.range(s, 0, 0xFFFFFFFF, 'shard');
    }
    final h = host;
    if (h != null && utf8.encode(h).length > 0xFF) {
      throw ArgumentError.value(h, 'host', 'longer than 255 bytes');
    }
  }

  static const int _hasService = 0x01;
  static const int _hasInstance = 0x02;
  static const int _hasShard = 0x04;
  static const int _hasHost = 0x08;
  static const int _reserved = 0xF0;

  /// Service type, or null for the receiver's default service.
  final Name? type;

  /// Instance id (`u48`), 0 for any.
  final int instance;

  /// Shard slot (`u32`), a routing hint, or null.
  final int? shard;

  /// Host hint for relaying proxies, or null.
  final String? host;

  /// Opaque application payload, passed through unchanged.
  final Uint8List payload;

  /// The service address, or null when [type] is null.
  ServiceAddress? get address {
    final t = type;
    return t == null ? null : ServiceAddress(t, instance);
  }

  /// Encodes the address header followed by [payload].
  ///
  /// HAS_INSTANCE is set only when [instance] is not 0.
  Uint8List encode() {
    final t = type;
    final s = shard;
    final h = host;
    final w = ByteWriter(16 + payload.length);
    w.u8(
      (t != null ? _hasService : 0) |
          (instance != 0 ? _hasInstance : 0) |
          (s != null ? _hasShard : 0) |
          (h != null ? _hasHost : 0),
    );
    if (t != null) {
      w.name(t);
    }
    if (instance != 0) {
      w.u48(instance);
    }
    if (s != null) {
      w.u32(s);
    }
    if (h != null) {
      w.string8(h);
    }
    w.bytes(payload);
    return w.toBytes();
  }

  /// Decodes an OPEN payload. An empty payload is the default address.
  ///
  /// Throws [ProtocolException] on reserved flag bits, truncation or an
  /// invalid name. The application payload is a copy of the remaining bytes.
  static ChannelAddress decode(Uint8List openPayload) {
    if (openPayload.isEmpty) {
      return ChannelAddress();
    }
    try {
      final r = ByteReader(openPayload);
      final flags = r.u8('flags');
      if (flags & _reserved != 0) {
        throw ProtocolException(
          'reserved address flags 0x${(flags & _reserved).toRadixString(16)}',
        );
      }
      final type = flags & _hasService != 0 ? r.name('service type') : null;
      final instance = flags & _hasInstance != 0 ? r.u48('instance') : 0;
      final shard = flags & _hasShard != 0 ? r.u32('shard') : null;
      final host = flags & _hasHost != 0 ? r.string8('host') : null;
      return ChannelAddress(
        type: type,
        instance: instance,
        shard: shard,
        host: host,
        payload: Uint8List.fromList(r.rest()),
      );
    } on FormatException catch (e) {
      throw ProtocolException('bad open payload: ${e.message}');
    } on ArgumentError catch (e) {
      // A malformed host hint can decode (with replacement characters) to
      // more than 255 bytes and be refused by the constructor.
      throw ProtocolException('bad open payload: ${e.message}');
    }
  }

  /// A copy with the given fields replaced.
  ///
  /// [clearHost] and [clearShard] drop the host hint and shard slot; a proxy
  /// uses [clearHost] once it has acted on the hint.
  ChannelAddress copyWith({
    Name? type,
    int? instance,
    int? shard,
    String? host,
    Uint8List? payload,
    bool clearHost = false,
    bool clearShard = false,
  }) => ChannelAddress(
    type: type ?? this.type,
    instance: instance ?? this.instance,
    shard: clearShard ? null : (shard ?? this.shard),
    host: clearHost ? null : (host ?? this.host),
    payload: payload ?? this.payload,
  );

  @override
  String toString() =>
      'ChannelAddress(${address ?? 'default'}'
      '${shard != null ? ' shard $shard' : ''}'
      '${host != null ? ' host $host' : ''}, ${payload.length} payload bytes)';
}
