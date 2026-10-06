/*
Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Author: Jan Boon <jan.boon@kaetemi.be>
*/

import 'dart:typed_data';

import '../address/service_address.dart';
import '../bytes.dart';
import '../name.dart';
import '../status.dart';

/// Talk procedure names of the naming service.
class Procedures {
  Procedures._();

  /// Register a service instance (request).
  static final Name register = Name('REGISTER');

  /// Remove a registration (request).
  static final Name unregister = Name('UNREGSTR');

  /// Watch the service table (stream request).
  static final Name watch = Name('WATCH');

  /// One-shot table query (stream request).
  static final Name lookup = Name('LOOKUP');

  /// Stream item: a service record came up.
  static final Name up = Name('UP');

  /// Stream item: a service instance went away.
  static final Name down = Name('DOWN');

  /// Stream item: the initial snapshot is complete.
  static final Name synced = Name('SYNCED');
}

/// Well-known service types.
class Services {
  Services._();

  /// The naming service.
  static final Name naming = Name('_ns');
}

// All decoders in this file ignore trailing bytes after a complete
// structure, for forward compatibility.

T _guard<T>(String what, T Function() body) {
  try {
    return body();
  } on FormatException catch (e) {
    throw ProtocolException('bad $what: ${e.message}');
  }
}

void _writeEndpoints(ByteWriter w, List<Uri> endpoints) {
  if (endpoints.length > 255) {
    throw ArgumentError.value(endpoints.length, 'endpoints', 'more than 255');
  }
  w.u8(endpoints.length);
  for (final e in endpoints) {
    w.string8(e.toString());
  }
}

List<Uri> _readEndpoints(ByteReader r) {
  final count = r.u8('endpoint count');
  return [for (var i = 0; i < count; i++) Uri.parse(r.string8('endpoint'))];
}

/// A service record: address with a non-zero instance and its endpoints.
///
/// Wire: name, u48 instance, u8 count, count times len8 URI.
class ServiceRecord {
  /// Creates a record.
  const ServiceRecord(this.address, {this.endpoints = const []});

  /// Type and instance id.
  final ServiceAddress address;

  /// URIs the instance can be reached at; may be empty.
  final List<Uri> endpoints;

  /// Encodes the record. Throws [ArgumentError] if the instance is 0 or
  /// there are more than 255 endpoints.
  Uint8List encode() {
    if (address.isAny) {
      throw ArgumentError.value(
        address,
        'address',
        'instance must be non-zero',
      );
    }
    final w = ByteWriter();
    w.name(address.type);
    w.u48(address.instance);
    _writeEndpoints(w, endpoints);
    return w.toBytes();
  }

  /// Decodes a record; trailing bytes are ignored.
  ///
  /// Throws [ProtocolException] on truncation or instance 0.
  static ServiceRecord decode(Uint8List bytes) => _guard('service record', () {
    final r = ByteReader(bytes);
    final type = r.name('type');
    final instance = r.u48('instance');
    if (instance == 0) {
      throw const FormatException('record instance is 0');
    }
    return ServiceRecord(
      ServiceAddress(type, instance),
      endpoints: _readEndpoints(r),
    );
  });

  @override
  bool operator ==(Object other) =>
      other is ServiceRecord &&
      other.address == address &&
      other.endpoints.length == endpoints.length &&
      Iterable<int>.generate(endpoints.length)
          .every((i) => endpoints[i] == other.endpoints[i]);

  @override
  int get hashCode => Object.hash(address, Object.hashAll(endpoints));

  @override
  String toString() => 'ServiceRecord($address, $endpoints)';
}

/// REGISTER request payload.
class RegisterRequest {
  /// Creates a request; [requestedInstance] 0 asks the service to assign one.
  const RegisterRequest(
    this.type, {
    this.requestedInstance = 0,
    this.endpoints = const [],
  });

  /// Service type to register.
  final Name type;

  /// Requested instance id, 0 to have one assigned.
  final int requestedInstance;

  /// Endpoints the instance listens on.
  final List<Uri> endpoints;

  /// Encodes the payload. Throws [ArgumentError] for over 255 endpoints.
  Uint8List encode() {
    final w = ByteWriter();
    w.name(type);
    w.u48(requestedInstance);
    _writeEndpoints(w, endpoints);
    return w.toBytes();
  }

  /// Decodes the payload; trailing bytes are ignored.
  static RegisterRequest decode(Uint8List bytes) =>
      _guard('REGISTER request', () {
        final r = ByteReader(bytes);
        final type = r.name('type');
        final instance = r.u48('instance');
        return RegisterRequest(
          type,
          requestedInstance: instance,
          endpoints: _readEndpoints(r),
        );
      });
}

/// REGISTER final response payload.
class RegisterResponse {
  /// Creates a response.
  const RegisterResponse(this.instance);

  /// The assigned instance id.
  final int instance;

  /// Encodes the payload (u48).
  Uint8List encode() {
    final w = ByteWriter(6);
    w.u48(instance);
    return w.toBytes();
  }

  /// Decodes the payload; trailing bytes are ignored.
  static RegisterResponse decode(Uint8List bytes) => _guard(
    'REGISTER response',
    () => RegisterResponse(ByteReader(bytes).u48('instance')),
  );
}

/// UNREGSTR request payload, also the layout of a DOWN item.
class UnregisterRequest {
  /// Creates a request.
  const UnregisterRequest(this.type, this.instance);

  /// Service type.
  final Name type;

  /// Instance id.
  final int instance;

  /// Encodes the payload (name, u48).
  Uint8List encode() {
    final w = ByteWriter(14);
    w.name(type);
    w.u48(instance);
    return w.toBytes();
  }

  /// Decodes the payload; trailing bytes are ignored.
  static UnregisterRequest decode(Uint8List bytes) =>
      _guard('UNREGSTR request', () {
        final r = ByteReader(bytes);
        return UnregisterRequest(r.name('type'), r.u48('instance'));
      });
}

/// WATCH request payload.
class WatchRequest {
  /// Creates a request; a null [type] watches every type.
  const WatchRequest([this.type]);

  /// Type to watch, or null for all.
  final Name? type;

  /// Encodes the payload: empty when [type] is null.
  Uint8List encode() {
    final t = type;
    if (t == null) {
      return Uint8List(0);
    }
    final w = ByteWriter(8);
    w.name(t);
    return w.toBytes();
  }

  /// Decodes the payload. Empty or an all-zero name means all types;
  /// trailing bytes are ignored.
  static WatchRequest decode(Uint8List bytes) {
    if (bytes.isEmpty) {
      return const WatchRequest();
    }
    return _guard('WATCH request', () {
      final t = ByteReader(bytes).name('type');
      return WatchRequest(t.isEmpty ? null : t);
    });
  }
}

/// An UP or DOWN stream item.
///
/// UP carries a full [ServiceRecord]; DOWN carries only the address, so
/// a decoded DOWN event has an empty endpoint list.
class ServiceEvent {
  /// Creates an event.
  const ServiceEvent({required this.up, required this.record});

  /// True for UP, false for DOWN.
  final bool up;

  /// The record (address only for DOWN).
  final ServiceRecord record;

  /// Decodes an UP item payload.
  static ServiceEvent decodeUp(Uint8List bytes) =>
      ServiceEvent(up: true, record: ServiceRecord.decode(bytes));

  /// Decodes a DOWN item payload.
  static ServiceEvent decodeDown(Uint8List bytes) {
    final u = UnregisterRequest.decode(bytes);
    return ServiceEvent(
      up: false,
      record: ServiceRecord(ServiceAddress(u.type, u.instance)),
    );
  }

  /// Procedure name for this event ([Procedures.up] or [Procedures.down]).
  Name get procedure => up ? Procedures.up : Procedures.down;

  /// Encodes the item payload: full record for UP, name and instance for DOWN.
  Uint8List encode() => up
      ? record.encode()
      : UnregisterRequest(
          record.address.type,
          record.address.instance,
        ).encode();

  @override
  bool operator ==(Object other) =>
      other is ServiceEvent && other.up == up && other.record == record;

  @override
  int get hashCode => Object.hash(up, record);

  @override
  String toString() => 'ServiceEvent(${up ? 'UP' : 'DOWN'} $record)';
}
