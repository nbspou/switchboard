/*
Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Author: Jan Boon <jan.boon@kaetemi.be>
*/

import 'dart:convert';
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

  /// Define or confirm a slot space (request).
  static final Name slots = Name('SLOTS');

  /// Declare the slots whose storage this instance holds (request).
  static final Name holding = Name('HOLDING');

  /// Take a free slot (request).
  static final Name claim = Name('CLAIM');

  /// Give up an owned slot (request).
  static final Name release = Name('RELEASE');

  /// Find, and in a managed space assign, the owner of a slot (request).
  static final Name locate = Name('LOCATE');

  /// Move a slot to another instance (stream request).
  static final Name migrate = Name('MIGRATE');

  /// Stream item of `MIGRATE`: progress of the hand-over.
  static final Name phase = Name('PHASE');

  /// From the naming service to an instance: serve a slot (request).
  static final Name assign = Name('ASSIGN');

  /// From the naming service to the owner: lock a slot and make its state
  /// available to the new owner (request).
  static final Name drain = Name('DRAIN');

  /// From the naming service to the old owner: the new owner serves, hand
  /// the queued work over (request).
  static final Name forward = Name('FORWARD');

  /// From the naming service to the owner: the migration was abandoned,
  /// unlock and serve (request).
  static final Name resume = Name('RESUME');

  /// Watch item: a slot space definition.
  static final Name slotSpace = Name('SLOTSPC');

  /// Watch item: the state of one slot.
  static final Name slot = Name('SLOT');
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
  return [for (var i = 0; i < count; i++) _readEndpoint(r)];
}

/// Reads one endpoint and rejects any that [ServiceRecord.checkEndpoint]
/// refuses, so that a decoded record can always be encoded again and the
/// result decodes to an equal record.
Uri _readEndpoint(ByteReader r) {
  final text = r.string8('endpoint');
  final Uri uri;
  try {
    uri = Uri.parse(text);
  } on FormatException catch (e) {
    throw ProtocolException('invalid endpoint uri: ${e.message}');
  }
  final problem = _endpointProblem(uri);
  if (problem != null) {
    throw ProtocolException('invalid endpoint uri: $problem');
  }
  return uri;
}

/// Why [uri] cannot be carried as an endpoint, or null if it can.
String? _endpointProblem(Uri uri) {
  if (!uri.hasScheme) {
    return 'no scheme';
  }
  final text = uri.toString();
  if (utf8.encode(text).length > 0xFF) {
    return 'longer than 255 bytes once normalized';
  }
  // Uri normalisation is not idempotent for every input: the text form of
  // some parsed URIs parses differently, or not at all. Such an endpoint
  // would be accepted once and then be undecodable for every watcher. Uri
  // equality is checked both ways: depending on the representation the
  // parser picks it compares either the text or the components, so
  // `tcp:/../..//` (no authority, path `//`) equals its own reparse
  // `tcp://` (empty authority, empty path) one way only.
  final again = Uri.tryParse(text);
  if (again == null || again != uri || uri != again) {
    return 'text form does not parse back to the same uri';
  }
  return null;
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

  /// Throws [ArgumentError] unless [endpoint] can be carried in a record:
  /// it must have a scheme, its text form must fit in 255 bytes of UTF-8,
  /// and parsing that text form must give the same URI again.
  ///
  /// The decoders refuse (with [ProtocolException]) every endpoint this
  /// refuses, and a record whose endpoints all pass encodes to bytes that
  /// decode to an equal record. The naming service refuses such endpoints
  /// with [StatusCode.invalidArgument], so that whatever it accepts, its
  /// watchers can decode.
  static void checkEndpoint(Uri endpoint) {
    final problem = _endpointProblem(endpoint);
    if (problem != null) {
      throw ArgumentError.value(endpoint, 'endpoint', problem);
    }
  }

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
  /// Throws [ProtocolException] on truncation, instance 0, or an endpoint
  /// that [checkEndpoint] refuses.
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
  ///
  /// Throws [ProtocolException] on truncation or an endpoint that
  /// [ServiceRecord.checkEndpoint] refuses.
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

// ---------------------------------------------------------------------------
// Sharding (wiki page "Switchboard Sharding")

void _checkU32(int value, String name) {
  if (value < 0 || value > 0xFFFFFFFF) {
    throw RangeError.range(value, 0, 0xFFFFFFFF, name);
  }
}

void _checkU48(int value, String name) {
  if (value < 0 || value > maxInstance) {
    throw RangeError.range(value, 0, maxInstance, name);
  }
}

/// Largest slot number and epoch (`u32`).
const int maxU32 = 0xFFFFFFFF;

/// How a slot space is governed.
enum SlotMode {
  /// The naming service assigns free slots and rebalances.
  managed(0),

  /// Instances claim the slots they are configured for; the naming service
  /// only records, arbitrates and orchestrates.
  static(1);

  const SlotMode(this.code);

  /// Wire value.
  final int code;

  /// The mode for wire value [code], or null if there is none.
  static SlotMode? fromCode(int code) => switch (code) {
    0 => managed,
    1 => static,
    _ => null,
  };
}

/// State of one slot.
enum SlotState {
  /// Nobody serves it.
  free(0),

  /// Served by its owner.
  owned(1),

  /// Hand-over in progress; routed to the old owner (`from`).
  migrating(2);

  const SlotState(this.code);

  /// Wire value.
  final int code;

  /// The state for wire value [code], or null if there is none.
  static SlotState? fromCode(int code) =>
      code >= 0 && code < values.length ? values[code] : null;
}

/// Progress of a migration, reported in `PHASE` items of `MIGRATE`.
enum MigrationPhase {
  /// `DRAIN` sent to the old owner.
  draining(1),

  /// `ASSIGN` sent to the new owner.
  assigning(2),

  /// The new owner serves; `FORWARD` sent to the old owner.
  forwarding(3),

  /// The hand-over is complete.
  done(4),

  /// The hand-over failed and was rolled back.
  rolledBack(5);

  const MigrationPhase(this.code);

  /// Wire value.
  final int code;

  /// The phase for wire value [code], or null if there is none.
  static MigrationPhase? fromCode(int code) =>
      code >= 1 && code <= values.length ? values[code - 1] : null;
}

/// A slot space definition, also the payload of a `SLOTSPC` watch item.
///
/// Wire: name type, u32 count, u8 mode, u8 flags (0x01 lazy, 0x02 shared
/// recovery). Unknown flag bits are ignored when decoding.
class SlotSpace {
  /// Creates a definition.
  const SlotSpace(
    this.type, {
    required this.count,
    this.mode = SlotMode.managed,
    this.lazy = false,
    this.shared = false,
  });

  /// Flag bit: slots are assigned on first `LOCATE` (managed mode).
  static const int lazyFlag = 0x01;

  /// Flag bit: shared recovery; state is recoverable from shared storage.
  static const int sharedFlag = 0x02;

  /// The sharded service type.
  final Name type;

  /// Number of slots, numbered `0 .. count - 1`.
  final int count;

  /// Managed or static.
  final SlotMode mode;

  /// Slots are assigned when first located rather than up front.
  final bool lazy;

  /// Shared recovery: a slot whose owner went down is reassigned at once,
  /// since its state can be loaded from shared storage. Otherwise
  /// holder-only: it waits for its holder.
  final bool shared;

  /// The flags byte.
  int get flags => (lazy ? lazyFlag : 0) | (shared ? sharedFlag : 0);

  void _write(ByteWriter w) {
    _checkU32(count, 'count');
    w.name(type);
    w.u32(count);
    w.u8(mode.code);
    w.u8(flags);
  }

  static SlotSpace _read(ByteReader r) {
    final type = r.name('type');
    final count = r.u32('count');
    final modeCode = r.u8('mode');
    final mode = SlotMode.fromCode(modeCode);
    if (mode == null) {
      throw FormatException('unknown slot mode $modeCode');
    }
    final flags = r.u8('flags');
    return SlotSpace(
      type,
      count: count,
      mode: mode,
      lazy: flags & lazyFlag != 0,
      shared: flags & sharedFlag != 0,
    );
  }

  /// Encodes the `SLOTSPC` item payload. Throws [RangeError] if [count] is
  /// outside the `u32` range.
  Uint8List encode() {
    final w = ByteWriter(14);
    _write(w);
    return w.toBytes();
  }

  /// Decodes a `SLOTSPC` item payload; trailing bytes are ignored.
  /// Throws [ProtocolException] on truncation or an unknown mode.
  static SlotSpace decode(Uint8List bytes) =>
      _guard('SLOTSPC', () => _read(ByteReader(bytes)));

  @override
  bool operator ==(Object other) =>
      other is SlotSpace &&
      other.type == type &&
      other.count == count &&
      other.mode == mode &&
      other.lazy == lazy &&
      other.shared == shared;

  @override
  int get hashCode => Object.hash(type, count, mode, lazy, shared);

  @override
  String toString() =>
      'SlotSpace($type, $count, ${mode.name}'
      '${lazy ? ', lazy' : ''}${shared ? ', shared' : ', holder-only'})';
}

/// `SLOTS` request payload: a [SlotSpace] and this instance's capacity.
///
/// Wire: the `SLOTSPC` layout followed by u32 capacity.
class SlotsRequest {
  /// Creates a request.
  const SlotsRequest(this.space, {required this.capacity});

  /// The space to define or confirm.
  final SlotSpace space;

  /// The caller's share weight in a managed space; 0 means it takes no
  /// slots (it only defines or confirms the space).
  final int capacity;

  /// Encodes the payload. Throws [RangeError] for values outside `u32`.
  Uint8List encode() {
    _checkU32(capacity, 'capacity');
    final w = ByteWriter(18);
    space._write(w);
    w.u32(capacity);
    return w.toBytes();
  }

  /// Decodes the payload; trailing bytes are ignored. Throws
  /// [ProtocolException] on truncation or an unknown mode.
  static SlotsRequest decode(Uint8List bytes) => _guard('SLOTS request', () {
    final r = ByteReader(bytes);
    final space = SlotSpace._read(r);
    return SlotsRequest(space, capacity: r.u32('capacity'));
  });
}

void _writeSlots(ByteWriter w, List<int> slots) {
  _checkU32(slots.length, 'slot count');
  w.u32(slots.length);
  for (final slot in slots) {
    _checkU32(slot, 'slot');
    w.u32(slot);
  }
}

List<int> _readSlots(ByteReader r) {
  final n = r.u32('slot count');
  if (n > r.remaining ~/ 4) {
    throw FormatException('truncated slot list of $n');
  }
  return List<int>.unmodifiable([for (var i = 0; i < n; i++) r.u32('slot')]);
}

/// `HOLDING` request payload.
///
/// Wire: name type, u32 n, u32 slot × n.
class HoldingRequest {
  /// Creates a request.
  const HoldingRequest(this.type, this.slots);

  /// The sharded type.
  final Name type;

  /// Slots whose storage the caller holds.
  final List<int> slots;

  /// Encodes the payload. Throws [RangeError] for a slot outside `u32`.
  Uint8List encode() {
    final w = ByteWriter(12 + 4 * slots.length);
    w.name(type);
    _writeSlots(w, slots);
    return w.toBytes();
  }

  /// Decodes the payload; trailing bytes are ignored. Throws
  /// [ProtocolException] on truncation.
  static HoldingRequest decode(Uint8List bytes) =>
      _guard('HOLDING request', () {
        final r = ByteReader(bytes);
        final type = r.name('type');
        return HoldingRequest(type, _readSlots(r));
      });
}

/// `HOLDING` final response payload: the slots whose holder is no longer
/// the caller, whose local storage it should discard.
///
/// Wire: u32 m, u32 slot × m.
class HoldingResponse {
  /// Creates a response.
  const HoldingResponse(this.discard);

  /// Slots to discard.
  final List<int> discard;

  /// Encodes the payload. Throws [RangeError] for a slot outside `u32`.
  Uint8List encode() {
    final w = ByteWriter(4 + 4 * discard.length);
    _writeSlots(w, discard);
    return w.toBytes();
  }

  /// Decodes the payload; trailing bytes are ignored. Throws
  /// [ProtocolException] on truncation.
  static HoldingResponse decode(Uint8List bytes) => _guard(
    'HOLDING response',
    () => HoldingResponse(_readSlots(ByteReader(bytes))),
  );
}

/// `CLAIM` request payload.
///
/// Wire: name type, u32 slot, u8 flags (0x01 holding), u32 epoch. The epoch
/// is the claimant's last known epoch of the slot (0 if none); the naming
/// service uses it to resolve conflicting claims after a restart.
class ClaimRequest {
  /// Creates a request.
  const ClaimRequest(
    this.type,
    this.slot, {
    this.holding = false,
    this.epoch = 0,
  });

  /// Flag bit: the claimant holds the slot's storage.
  static const int holdingFlag = 0x01;

  /// The sharded type.
  final Name type;

  /// The slot to take.
  final int slot;

  /// The claimant holds the slot's storage.
  final bool holding;

  /// The claimant's last known epoch of the slot, 0 if none.
  final int epoch;

  /// Encodes the payload. Throws [RangeError] for values outside `u32`.
  Uint8List encode() {
    _checkU32(slot, 'slot');
    _checkU32(epoch, 'epoch');
    final w = ByteWriter(17);
    w.name(type);
    w.u32(slot);
    w.u8(holding ? holdingFlag : 0);
    w.u32(epoch);
    return w.toBytes();
  }

  /// Decodes the payload; trailing bytes are ignored. Throws
  /// [ProtocolException] on truncation.
  static ClaimRequest decode(Uint8List bytes) => _guard('CLAIM request', () {
    final r = ByteReader(bytes);
    final type = r.name('type');
    final slot = r.u32('slot');
    final flags = r.u8('flags');
    return ClaimRequest(
      type,
      slot,
      holding: flags & holdingFlag != 0,
      epoch: r.u32('epoch'),
    );
  });
}

/// `CLAIM` final response payload: the slot's epoch.
///
/// Wire: u32 epoch.
class ClaimResponse {
  /// Creates a response.
  const ClaimResponse(this.epoch);

  /// The slot's epoch with the claimant as owner.
  final int epoch;

  /// Encodes the payload. Throws [RangeError] outside `u32`.
  Uint8List encode() {
    _checkU32(epoch, 'epoch');
    final w = ByteWriter(4);
    w.u32(epoch);
    return w.toBytes();
  }

  /// Decodes the payload; trailing bytes are ignored. Throws
  /// [ProtocolException] on truncation.
  static ClaimResponse decode(Uint8List bytes) => _guard(
    'CLAIM response',
    () => ClaimResponse(ByteReader(bytes).u32('epoch')),
  );
}

/// `RELEASE` request payload.
///
/// Wire: name type, u32 slot, u8 flags (0x01 keep storage).
class ReleaseRequest {
  /// Creates a request.
  const ReleaseRequest(this.type, this.slot, {this.keepStorage = false});

  /// Flag bit: the caller keeps the storage and stays holder.
  static const int keepStorageFlag = 0x01;

  /// The sharded type.
  final Name type;

  /// The slot to give up.
  final int slot;

  /// The caller keeps the slot's storage and stays its holder.
  final bool keepStorage;

  /// Encodes the payload. Throws [RangeError] outside `u32`.
  Uint8List encode() {
    _checkU32(slot, 'slot');
    final w = ByteWriter(13);
    w.name(type);
    w.u32(slot);
    w.u8(keepStorage ? keepStorageFlag : 0);
    return w.toBytes();
  }

  /// Decodes the payload; trailing bytes are ignored. Throws
  /// [ProtocolException] on truncation.
  static ReleaseRequest decode(Uint8List bytes) =>
      _guard('RELEASE request', () {
        final r = ByteReader(bytes);
        final type = r.name('type');
        final slot = r.u32('slot');
        final flags = r.u8('flags');
        return ReleaseRequest(
          type,
          slot,
          keepStorage: flags & keepStorageFlag != 0,
        );
      });
}

/// `LOCATE` request payload.
///
/// Wire: name type, u32 slot.
class LocateRequest {
  /// Creates a request.
  const LocateRequest(this.type, this.slot);

  /// The sharded type.
  final Name type;

  /// The slot to locate.
  final int slot;

  /// Encodes the payload. Throws [RangeError] outside `u32`.
  Uint8List encode() {
    _checkU32(slot, 'slot');
    final w = ByteWriter(12);
    w.name(type);
    w.u32(slot);
    return w.toBytes();
  }

  /// Decodes the payload; trailing bytes are ignored. Throws
  /// [ProtocolException] on truncation.
  static LocateRequest decode(Uint8List bytes) => _guard('LOCATE request', () {
    final r = ByteReader(bytes);
    return LocateRequest(r.name('type'), r.u32('slot'));
  });
}

/// `LOCATE` final response payload.
///
/// Wire: u8 state, u48 owner, u32 epoch. While migrating, [owner] is the
/// old owner (`from`), which keeps receiving the slot's traffic.
class LocateResponse {
  /// Creates a response.
  const LocateResponse(this.state, this.owner, this.epoch);

  /// The slot's state.
  final SlotState state;

  /// The instance to route to, 0 when the slot is free.
  final int owner;

  /// The slot's epoch.
  final int epoch;

  /// Encodes the payload. Throws [RangeError] for values out of range.
  Uint8List encode() {
    _checkU48(owner, 'owner');
    _checkU32(epoch, 'epoch');
    final w = ByteWriter(11);
    w.u8(state.code);
    w.u48(owner);
    w.u32(epoch);
    return w.toBytes();
  }

  /// Decodes the payload; trailing bytes are ignored. Throws
  /// [ProtocolException] on truncation or an unknown state.
  static LocateResponse decode(Uint8List bytes) =>
      _guard('LOCATE response', () {
        final r = ByteReader(bytes);
        final code = r.u8('state');
        final state = SlotState.fromCode(code);
        if (state == null) {
          throw FormatException('unknown slot state $code');
        }
        return LocateResponse(state, r.u48('owner'), r.u32('epoch'));
      });

  @override
  bool operator ==(Object other) =>
      other is LocateResponse &&
      other.state == state &&
      other.owner == owner &&
      other.epoch == epoch;

  @override
  int get hashCode => Object.hash(state, owner, epoch);

  @override
  String toString() =>
      'LocateResponse(${state.name}, ${owner.toRadixString(16)}, $epoch)';
}

/// `MIGRATE` request payload.
///
/// Wire: name type, u32 slot, u48 to (0 lets the allocator choose).
class MigrateRequest {
  /// Creates a request.
  const MigrateRequest(this.type, this.slot, {this.to = 0});

  /// The sharded type.
  final Name type;

  /// The slot to move.
  final int slot;

  /// The new owner, 0 to let the allocator choose.
  final int to;

  /// Encodes the payload. Throws [RangeError] for values out of range.
  Uint8List encode() {
    _checkU32(slot, 'slot');
    _checkU48(to, 'to');
    final w = ByteWriter(18);
    w.name(type);
    w.u32(slot);
    w.u48(to);
    return w.toBytes();
  }

  /// Decodes the payload; trailing bytes are ignored. Throws
  /// [ProtocolException] on truncation.
  static MigrateRequest decode(Uint8List bytes) =>
      _guard('MIGRATE request', () {
        final r = ByteReader(bytes);
        return MigrateRequest(r.name('type'), r.u32('slot'), to: r.u48('to'));
      });
}

/// `PHASE` item payload of a `MIGRATE` stream.
///
/// Wire: u8 phase.
class PhaseItem {
  /// Creates an item.
  const PhaseItem(this.phase);

  /// The phase reached.
  final MigrationPhase phase;

  /// Encodes the payload.
  Uint8List encode() => Uint8List.fromList([phase.code]);

  /// Decodes the payload; trailing bytes are ignored. Throws
  /// [ProtocolException] on truncation or an unknown phase.
  static PhaseItem decode(Uint8List bytes) => _guard('PHASE', () {
    final code = ByteReader(bytes).u8('phase');
    final phase = MigrationPhase.fromCode(code);
    if (phase == null) {
      throw FormatException('unknown migration phase $code');
    }
    return PhaseItem(phase);
  });

  @override
  bool operator ==(Object other) => other is PhaseItem && other.phase == phase;

  @override
  int get hashCode => phase.hashCode;

  @override
  String toString() => 'PhaseItem(${phase.name})';
}

/// `ASSIGN` request payload, from the naming service to an instance.
///
/// Wire: name type, u32 slot, u32 epoch, u48 holder, u8 flags (0x01 shared
/// recovery).
class AssignRequest {
  /// Creates a request.
  const AssignRequest(
    this.type,
    this.slot, {
    required this.epoch,
    this.holder = 0,
    this.shared = false,
  });

  /// Flag bit: state may be loaded from shared storage.
  static const int sharedFlag = 0x01;

  /// The sharded type.
  final Name type;

  /// The slot to serve.
  final int slot;

  /// The slot's epoch once this instance serves it.
  final int epoch;

  /// Where the slot's state is: 0 nowhere (start fresh), this instance
  /// (reclaim local state), another instance (fetch it from there).
  final int holder;

  /// Shared recovery: state may be loaded from shared storage instead of
  /// the holder.
  final bool shared;

  /// Encodes the payload. Throws [RangeError] for values out of range.
  Uint8List encode() {
    _checkU32(slot, 'slot');
    _checkU32(epoch, 'epoch');
    _checkU48(holder, 'holder');
    final w = ByteWriter(23);
    w.name(type);
    w.u32(slot);
    w.u32(epoch);
    w.u48(holder);
    w.u8(shared ? sharedFlag : 0);
    return w.toBytes();
  }

  /// Decodes the payload; trailing bytes are ignored. Throws
  /// [ProtocolException] on truncation.
  static AssignRequest decode(Uint8List bytes) => _guard('ASSIGN request', () {
    final r = ByteReader(bytes);
    final type = r.name('type');
    final slot = r.u32('slot');
    final epoch = r.u32('epoch');
    final holder = r.u48('holder');
    final flags = r.u8('flags');
    return AssignRequest(
      type,
      slot,
      epoch: epoch,
      holder: holder,
      shared: flags & sharedFlag != 0,
    );
  });

  @override
  String toString() =>
      'ASSIGN $type/$slot epoch $epoch holder ${holder.toRadixString(16)}'
      '${shared ? ' shared' : ''}';
}

/// `ASSIGN` final response payload.
///
/// Wire: empty (the instance now holds the slot's storage), or u8 flags with
/// 0x01 "not holding" (the previous holder is kept; a stateless service
/// always answers this).
class AssignResponse {
  /// Creates a response.
  const AssignResponse({this.notHolding = false});

  /// Flag bit: not holding.
  static const int notHoldingFlag = 0x01;

  /// The instance does not hold the slot's storage.
  final bool notHolding;

  /// Encodes the payload: empty unless [notHolding].
  Uint8List encode() =>
      notHolding ? Uint8List.fromList([notHoldingFlag]) : Uint8List(0);

  /// Decodes the payload. Empty means holding; unknown flag bits and
  /// trailing bytes are ignored.
  static AssignResponse decode(Uint8List bytes) => AssignResponse(
    notHolding: bytes.isNotEmpty && bytes[0] & notHoldingFlag != 0,
  );
}

/// `DRAIN` request payload, from the naming service to the owner.
///
/// Wire: name type, u32 slot, u32 epoch (the slot's epoch after the
/// migration), u48 to.
class DrainRequest {
  /// Creates a request.
  const DrainRequest(
    this.type,
    this.slot, {
    required this.epoch,
    required this.to,
  });

  /// The sharded type.
  final Name type;

  /// The slot to drain.
  final int slot;

  /// The epoch the slot will have after the migration.
  final int epoch;

  /// The new owner.
  final int to;

  /// Encodes the payload. Throws [RangeError] for values out of range.
  Uint8List encode() => _encodeHandover(type, slot, epoch, to);

  /// Decodes the payload; trailing bytes are ignored. Throws
  /// [ProtocolException] on truncation.
  static DrainRequest decode(Uint8List bytes) => _guard('DRAIN request', () {
    final r = ByteReader(bytes);
    return DrainRequest(
      r.name('type'),
      r.u32('slot'),
      epoch: r.u32('epoch'),
      to: r.u48('to'),
    );
  });

  @override
  String toString() =>
      'DRAIN $type/$slot epoch $epoch to ${to.toRadixString(16)}';
}

/// `FORWARD` request payload, from the naming service to the old owner.
///
/// Wire: name type, u32 slot, u32 epoch (the new epoch), u48 to.
class ForwardRequest {
  /// Creates a request.
  const ForwardRequest(
    this.type,
    this.slot, {
    required this.epoch,
    required this.to,
  });

  /// The sharded type.
  final Name type;

  /// The slot handed over.
  final int slot;

  /// The slot's new epoch.
  final int epoch;

  /// The new owner, which now serves the slot.
  final int to;

  /// Encodes the payload. Throws [RangeError] for values out of range.
  Uint8List encode() => _encodeHandover(type, slot, epoch, to);

  /// Decodes the payload; trailing bytes are ignored. Throws
  /// [ProtocolException] on truncation.
  static ForwardRequest decode(Uint8List bytes) =>
      _guard('FORWARD request', () {
        final r = ByteReader(bytes);
        return ForwardRequest(
          r.name('type'),
          r.u32('slot'),
          epoch: r.u32('epoch'),
          to: r.u48('to'),
        );
      });

  @override
  String toString() =>
      'FORWARD $type/$slot epoch $epoch to ${to.toRadixString(16)}';
}

Uint8List _encodeHandover(Name type, int slot, int epoch, int to) {
  _checkU32(slot, 'slot');
  _checkU32(epoch, 'epoch');
  _checkU48(to, 'to');
  final w = ByteWriter(22);
  w.name(type);
  w.u32(slot);
  w.u32(epoch);
  w.u48(to);
  return w.toBytes();
}

/// `RESUME` request payload, from the naming service to the owner of a
/// slot whose migration was abandoned.
///
/// Wire: name type, u32 slot, u32 epoch (the slot's epoch, unchanged).
class ResumeRequest {
  /// Creates a request.
  const ResumeRequest(this.type, this.slot, {required this.epoch});

  /// The sharded type.
  final Name type;

  /// The slot to unlock.
  final int slot;

  /// The slot's epoch, unchanged by the abandoned migration.
  final int epoch;

  /// Encodes the payload. Throws [RangeError] for values out of range.
  Uint8List encode() {
    _checkU32(slot, 'slot');
    _checkU32(epoch, 'epoch');
    final w = ByteWriter(16);
    w.name(type);
    w.u32(slot);
    w.u32(epoch);
    return w.toBytes();
  }

  /// Decodes the payload; trailing bytes are ignored. Throws
  /// [ProtocolException] on truncation.
  static ResumeRequest decode(Uint8List bytes) => _guard('RESUME request', () {
    final r = ByteReader(bytes);
    return ResumeRequest(r.name('type'), r.u32('slot'), epoch: r.u32('epoch'));
  });

  @override
  String toString() => 'RESUME $type/$slot epoch $epoch';
}

/// The state of one slot in a slot table.
///
/// For [SlotState.migrating], [owner] is the old owner (`from`), which
/// keeps receiving the slot's traffic, and [to] the new one.
class SlotEntry {
  /// Creates an entry.
  const SlotEntry({
    required this.state,
    this.owner = 0,
    this.to = 0,
    this.holder = 0,
    this.epoch = 0,
  });

  /// A free slot.
  const SlotEntry.free({this.holder = 0, this.epoch = 0})
    : state = SlotState.free,
      owner = 0,
      to = 0;

  /// An owned slot.
  const SlotEntry.owned(this.owner, {this.holder = 0, this.epoch = 0})
    : state = SlotState.owned,
      to = 0;

  /// A slot being handed over from [owner] to [to].
  const SlotEntry.migrating(
    this.owner,
    this.to, {
    this.holder = 0,
    this.epoch = 0,
  }) : state = SlotState.migrating;

  /// A slot nobody serves, holds or has ever served: free, holder 0,
  /// epoch 0.
  static const SlotEntry unassigned = SlotEntry(state: SlotState.free);

  /// The state.
  final SlotState state;

  /// The instance traffic for the slot goes to: the owner, or while
  /// migrating the old owner (`from`). 0 when free.
  final int owner;

  /// The new owner while migrating, else 0.
  final int to;

  /// The instance holding the slot's durable state, 0 if none.
  final int holder;

  /// Incremented at every ownership change.
  final int epoch;

  /// True when free.
  bool get isFree => state == SlotState.free;

  /// True when free with holder 0: such slots are left out of snapshots.
  bool get isEmpty => state == SlotState.free && holder == 0;

  @override
  bool operator ==(Object other) =>
      other is SlotEntry &&
      other.state == state &&
      other.owner == owner &&
      other.to == to &&
      other.holder == holder &&
      other.epoch == epoch;

  @override
  int get hashCode => Object.hash(state, owner, to, holder, epoch);

  @override
  String toString() {
    String hex(int v) => v.toRadixString(16);
    return switch (state) {
      SlotState.free => 'free holder ${hex(holder)} epoch $epoch',
      SlotState.owned =>
        'owned ${hex(owner)} holder ${hex(holder)} epoch $epoch',
      SlotState.migrating =>
        'migrating ${hex(owner)}->${hex(to)} holder ${hex(holder)} '
            'epoch $epoch',
    };
  }
}

/// `SLOT` watch item payload: one slot of a type and its state.
///
/// Wire: name type, u32 slot, u8 state, u48 owner (or from), u48 to,
/// u48 holder, u32 epoch.
class SlotItem {
  /// Creates an item.
  const SlotItem(this.type, this.slot, this.entry);

  /// The sharded type.
  final Name type;

  /// The slot number.
  final int slot;

  /// The slot's state.
  final SlotEntry entry;

  /// Encodes the payload. Throws [RangeError] for values out of range.
  Uint8List encode() {
    _checkU32(slot, 'slot');
    _checkU48(entry.owner, 'owner');
    _checkU48(entry.to, 'to');
    _checkU48(entry.holder, 'holder');
    _checkU32(entry.epoch, 'epoch');
    final w = ByteWriter(35);
    w.name(type);
    w.u32(slot);
    w.u8(entry.state.code);
    w.u48(entry.owner);
    w.u48(entry.to);
    w.u48(entry.holder);
    w.u32(entry.epoch);
    return w.toBytes();
  }

  /// Decodes the payload; trailing bytes are ignored. Throws
  /// [ProtocolException] on truncation or an unknown state.
  static SlotItem decode(Uint8List bytes) => _guard('SLOT', () {
    final r = ByteReader(bytes);
    final type = r.name('type');
    final slot = r.u32('slot');
    final code = r.u8('state');
    final state = SlotState.fromCode(code);
    if (state == null) {
      throw FormatException('unknown slot state $code');
    }
    return SlotItem(
      type,
      slot,
      SlotEntry(
        state: state,
        owner: r.u48('owner'),
        to: r.u48('to'),
        holder: r.u48('holder'),
        epoch: r.u32('epoch'),
      ),
    );
  });

  @override
  bool operator ==(Object other) =>
      other is SlotItem &&
      other.type == type &&
      other.slot == slot &&
      other.entry == entry;

  @override
  int get hashCode => Object.hash(type, slot, entry);

  @override
  String toString() => 'SLOT $type/$slot $entry';
}

/// The fixed fields of a `MOVED` or `RELOCATED` status (wiki pages
/// "Switchboard Status Codes" and "Switchboard Sharding", section
/// "Routing").
///
/// The status payload is `u16 code`, `u48 owner` (the slot's current
/// owner instance, 0 = unknown), `u32 epoch` (the slot's current epoch,
/// 0 = unknown), then the usual optional UTF-8 reason. The owner's type is
/// the one the channel was addressed to.
///
/// `MOVED` (37) means nothing on the channel (or in the request) was
/// processed, so it may be sent again to the owner; `RELOCATED` (38) means
/// the slot moved after work on the channel (or request) had started, so
/// the work may or may not have taken effect, and it is never retried
/// automatically.
class MovedStatus {
  /// Creates the fields; [owner] and [epoch] 0 mean unknown.
  ///
  /// Throws [RangeError] if [owner] is not a `u48` or [epoch] not a `u32`.
  MovedStatus({this.owner = 0, this.epoch = 0, this.reason = ''}) {
    _checkU48(owner, 'owner');
    _checkU32(epoch, 'epoch');
  }

  const MovedStatus._unknown() : owner = 0, epoch = 0, reason = '';

  /// No owner, no epoch, no reason.
  static const MovedStatus unknown = MovedStatus._unknown();

  /// Bytes of the fixed fields after the code: `u48 owner`, `u32 epoch`.
  static const int fieldsLength = 10;

  /// The slot's current owner instance, 0 if unknown.
  final int owner;

  /// The slot's current epoch, 0 if unknown.
  final int epoch;

  /// The human readable reason after the fields, for logs; may be empty.
  final String reason;

  /// Whether the owner is known.
  bool get hasOwner => owner != 0;

  /// The owner as an address of [type] (the channel's type), or null when
  /// unknown.
  ServiceAddress? ownerOf(Name type) =>
      owner == 0 ? null : ServiceAddress(type, owner);

  /// Whether [status] is a `MOVED` or a `RELOCATED`, the two codes that
  /// carry these fields.
  static bool carriesFields(Status status) {
    final code = status.known;
    return code == StatusCode.moved || code == StatusCode.relocated;
  }

  /// The status payload: `u16` code ([StatusCode.moved], or
  /// [StatusCode.relocated] when [relocated]), the fields and the reason.
  Uint8List encode({bool relocated = false}) {
    final w = ByteWriter(2 + fieldsLength + reason.length * 3)
      ..u16(relocated ? StatusCode.relocated.code : StatusCode.moved.code)
      ..u48(owner)
      ..u32(epoch);
    if (reason.isNotEmpty) {
      w.bytes(utf8.encode(reason));
    }
    return w.toBytes();
  }

  /// A [StatusCode.moved] status carrying the fields, or a
  /// [StatusCode.relocated] one when [relocated].
  Status toStatus({bool relocated = false}) =>
      Status.decode(encode(relocated: relocated));

  /// Reads the fields of a status payload. Never throws: a payload whose
  /// code is neither `MOVED` (37) nor `RELOCATED` (38), or that is too
  /// short for the fields, reads as [unknown].
  static MovedStatus parse(Uint8List statusPayload) {
    if (statusPayload.length < 2 + fieldsLength) {
      return unknown;
    }
    final r = ByteReader(statusPayload);
    final code = r.u16();
    if (code != StatusCode.moved.code && code != StatusCode.relocated.code) {
      return unknown;
    }
    final owner = r.u48();
    final epoch = r.u32();
    final rest = r.rest();
    return MovedStatus(
      owner: owner,
      epoch: epoch,
      reason: rest.isEmpty ? '' : utf8.decode(rest, allowMalformed: true),
    );
  }

  /// Reads the fields of [status] (see [parse]): [unknown] unless it is a
  /// `MOVED` or `RELOCATED` status long enough to carry them.
  static MovedStatus fromStatus(Status status) {
    if (!carriesFields(status)) {
      return unknown;
    }
    return parse(status.encode());
  }

  @override
  bool operator ==(Object other) =>
      other is MovedStatus &&
      other.owner == owner &&
      other.epoch == epoch &&
      other.reason == reason;

  @override
  int get hashCode => Object.hash(owner, epoch, reason);

  @override
  String toString() {
    final where = owner == 0
        ? 'unknown owner'
        : 'owner ${owner.toRadixString(16)}';
    final when = epoch == 0 ? '' : ', epoch $epoch';
    return 'MovedStatus($where$when${reason.isEmpty ? '' : ', $reason'})';
  }
}
