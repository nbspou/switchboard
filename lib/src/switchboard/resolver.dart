/*
Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Author: Jan Boon <jan.boon@kaetemi.be>
*/

import 'dart:async';

import '../address/service_address.dart';
import '../name.dart';
import '../naming/naming_protocol.dart';
import '../naming/slot_table.dart';

/// Maps a service type to the live instances of that type and where they
/// listen, and reports changes.
///
/// See the wiki page "Switchboard Addressing and Dispatch", section
/// "Resolvers".
abstract interface class Resolver {
  /// All known live instances of [type], in no particular order.
  ///
  /// Returns an empty list when nothing is known. Waits for [ready] first;
  /// a resolver may bound that wait (a naming resolver fails with
  /// `UNAVAILABLE` after its resolve timeout).
  Future<List<ServiceRecord>> resolve(Name type);

  /// Up and down events as the table changes. Broadcast stream.
  Stream<ServiceEvent> get events;

  /// Completes once the table has been usable at least once; a later loss
  /// of the source does not reset it. Completes immediately for static
  /// resolvers; for a naming resolver, after the first `SYNCED` (it fails if
  /// the resolver is closed before that).
  Future<void> get ready;

  /// Releases resources. [resolve] fails afterwards.
  Future<void> close();
}

/// A [Resolver] that also knows the slot tables of sharded types, so that
/// a router can send a channel for a shard slot to the slot's owner. See
/// the wiki page "Switchboard Sharding", section "Routing".
///
/// `Switchboard.selectAndConnect` routes `(type, slot)` through
/// [slotOwner] when the resolver implements this interface and
/// [slotTable] has a table for the type; types without a slot table keep
/// the plain rule of the addressing page (`sorted[slot mod n]`).
/// `NamingResolver` implements it over the naming service's mirrored
/// tables; [StaticResolver] over a configured slot map.
abstract interface class SlotResolver implements Resolver {
  /// The slot table of [type], or null if the type has no slot space.
  SlotTable? slotTable(Name type);

  /// Where traffic for [slot] of [type] goes: the entry if the slot is
  /// owned or migrating (route to [SlotEntry.owner], which is the old
  /// owner while migrating), null otherwise.
  SlotEntry? slotOwner(Name type, int slot);

  /// The distinct instances the slots of [type] are routed to.
  Set<int> slotOwners(Name type);

  /// Changes of the slot tables. Broadcast stream.
  Stream<SlotEvent> get slotEvents;

  /// Asks the authority for the owner of [slot] of [type], bypassing the
  /// table: the naming service's `LOCATE`, which in a managed space
  /// assigns a free slot first. Returns the entry to route to (owned or
  /// migrating), or null when the slot stays free. Fails like the
  /// underlying request (for example `UNAVAILABLE` while disconnected).
  Future<SlotEntry?> locateSlot(Name type, int slot);
}

/// A configured, in-memory table. Used by tests, embedded style peers and
/// deployments without a naming service.
///
/// It can also carry configured slot tables ([defineSlots], [setSlot]),
/// for routing shard slots without a naming service; [locateSlot] then
/// answers from the configured table, as there is no authority to ask.
class StaticResolver implements SlotResolver {
  /// Creates a resolver pre-populated with [records].
  StaticResolver([Iterable<ServiceRecord> records = const []]) {
    for (final record in records) {
      _table[record.address] = record;
    }
  }

  final Map<ServiceAddress, ServiceRecord> _table = {};
  final StreamController<ServiceEvent> _events =
      StreamController<ServiceEvent>.broadcast();
  final Map<Name, _StaticSlots> _slots = {};
  final StreamController<SlotEvent> _slotEvents =
      StreamController<SlotEvent>.broadcast();

  /// Read-only view of the table.
  Map<ServiceAddress, ServiceRecord> get table => Map.unmodifiable(_table);

  /// Adds or replaces [record] and emits an up event.
  void add(ServiceRecord record) {
    _table[record.address] = record;
    _events.add(ServiceEvent(up: true, record: record));
  }

  /// Removes the record for [address] if present and emits a down event.
  void remove(ServiceAddress address) {
    final removed = _table.remove(address);
    if (removed != null) {
      _events.add(
        ServiceEvent(
          up: false,
          record: ServiceRecord(address, endpoints: const []),
        ),
      );
    }
  }

  @override
  Future<List<ServiceRecord>> resolve(Name type) async => [
    for (final r in _table.values)
      if (r.address.type == type) r,
  ];

  @override
  Stream<ServiceEvent> get events => _events.stream;

  @override
  Future<void> get ready => Future.value();

  /// Defines (or redefines) the slot space of [space]'s type with every
  /// slot free. Slots of a previous definition are reported gone on
  /// [slotEvents].
  void defineSlots(SlotSpace space) {
    final previous = _slots[space.type];
    if (previous != null) {
      for (final slot in previous.entries.keys.toList()) {
        _set(previous, slot, SlotEntry.unassigned);
      }
    }
    _slots[space.type] = _StaticSlots(space);
  }

  /// Removes the slot space of [type]; its channels are routed by the
  /// plain rule again.
  void removeSlots(Name type) {
    final previous = _slots.remove(type);
    if (previous != null) {
      for (final slot in previous.entries.keys.toList()) {
        _set(previous, slot, SlotEntry.unassigned);
      }
    }
  }

  /// Sets the state of [slot] of [type] and reports it on [slotEvents].
  /// Throws [StateError] without a slot space for [type] ([defineSlots])
  /// and [RangeError] for a slot outside it.
  void setSlot(Name type, int slot, SlotEntry entry) {
    final slots = _slots[type];
    if (slots == null) {
      throw StateError('no slot space for $type');
    }
    RangeError.checkValueInInterval(slot, 0, slots.space.count - 1, 'slot');
    _set(slots, slot, entry);
  }

  void _set(_StaticSlots slots, int slot, SlotEntry entry) {
    final previous = slots.entries[slot] ?? SlotEntry.unassigned;
    if (entry.isEmpty) {
      slots.entries.remove(slot);
    } else {
      slots.entries[slot] = entry;
    }
    if (previous != entry && !_slotEvents.isClosed) {
      _slotEvents.add(SlotEvent(slots.space.type, slot, entry, previous));
    }
  }

  @override
  SlotTable? slotTable(Name type) => _slots[type]?.view;

  @override
  SlotEntry? slotOwner(Name type, int slot) {
    final entry = _slots[type]?.entries[slot];
    return entry != null && entry.owner != 0 ? entry : null;
  }

  @override
  Set<int> slotOwners(Name type) => _slots[type]?.view.owners ?? <int>{};

  @override
  Stream<SlotEvent> get slotEvents => _slotEvents.stream;

  /// The configured entry ([slotOwner]): a static table has no authority
  /// to ask.
  @override
  Future<SlotEntry?> locateSlot(Name type, int slot) async =>
      slotOwner(type, slot);

  @override
  Future<void> close() async {
    await _events.close();
    await _slotEvents.close();
  }
}

/// A configured slot table.
class _StaticSlots {
  _StaticSlots(this.space) {
    view = SlotTable(space, entries);
  }

  final SlotSpace space;
  final Map<int, SlotEntry> entries = {};
  late final SlotTable view;
}

/// Resolves every type to one fixed endpoint, instance `0` (any).
///
/// The frontend client resolver: the endpoint's proxy does the real
/// resolution. Also what an embedded device uses.
class EndpointResolver implements Resolver {
  /// Creates a resolver that always answers with [endpoint].
  EndpointResolver(this.endpoint);

  /// The endpoint every address resolves to.
  final Uri endpoint;

  @override
  Future<List<ServiceRecord>> resolve(Name type) async => [
    ServiceRecord(ServiceAddress(type), endpoints: [endpoint]),
  ];

  @override
  Stream<ServiceEvent> get events => const Stream.empty();

  @override
  Future<void> get ready => Future.value();

  @override
  Future<void> close() async {}
}
