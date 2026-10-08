/*
Polyverse Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Authors:
  Jan Boon <jan.boon@kaetemi.be>
  Claude Fable 5.1 <noreply@anthropic.com>
  Claude Opus 5.5 <noreply@anthropic.com>
*/

import 'dart:async';
import 'dart:typed_data';

import '../address/service_address.dart';
import '../name.dart';
import '../naming/naming_protocol.dart';
import '../naming/slot_table.dart';
import '../status.dart';

/// How `Switchboard.selectAndConnect` picks among the candidate instances
/// of a type when the caller gives no shard slot (with a shard slot the
/// choice is fixed by the slot, see the wiki page "Polyverse Switchboard Addressing
/// and Dispatch", section "Opening channels").
///
/// Either way, if the chosen instance cannot be reached, the others are
/// tried in turn from there.
enum SelectionPolicy {
  /// A per-type counter rotates over the candidates sorted by instance id.
  roundRobin,

  /// A uniformly random candidate, from the node's `Random`.
  random,
}

/// Maps a service type to the live instances of that type and where they
/// listen, and reports changes.
///
/// See the wiki page "Polyverse Switchboard Addressing and Dispatch", section
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
  /// resolvers; for a naming resolver, after the first sync (it fails if
  /// the resolver is closed before that).
  Future<void> get ready;

  /// Releases resources. [resolve] fails afterwards.
  Future<void> close();
}

/// A [Resolver] that also knows the slot tables of sharded types, so that
/// a router can send a channel for a shard slot to the slot's owner. See
/// the wiki page "Polyverse Switchboard Sharding", section "Routing".
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

/// A [Resolver] that can have an instance which registered without
/// endpoints dial the caller: the naming service's `CONNECT` (wiki page
/// "Switchboard Identity and Credentials", section "Reverse
/// connections").
///
/// `Switchboard` brokers a connection through it to an instance whose
/// record has no endpoints, when the resolver implements this interface
/// (`Switchboard.broker`); `NamingResolver` implements it over its
/// client's [connectTo].
abstract interface class BrokeringResolver implements Resolver {
  /// Has the instance at [address] dial [endpoint] and identify there with
  /// [intent] (at most 64 bytes). Completes once it has, with the identity
  /// it presents. [timeout], when given, bounds the whole request. Fails
  /// like `NamingClient.connectTo`.
  Future<String> connectTo(
    ServiceAddress address,
    Uri endpoint,
    Uint8List intent, {
    Duration? timeout,
  });
}

/// A configured, in-memory table. Used by tests, embedded style peers and
/// deployments without a naming service.
///
/// It can also carry configured slot tables ([defineSlots], [setSlot]),
/// for routing shard slots without a naming service; [locateSlot] then
/// answers from the configured table, as there is no authority to ask.
/// After [close], resolution and changes fail with
/// [StatusCode.failedPrecondition]; the last table remains readable.
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
  bool _closed = false;

  void _checkOpen() {
    if (_closed) {
      throw SwitchboardException.of(
        StatusCode.failedPrecondition,
        'static resolver closed',
      );
    }
  }

  /// Read-only view of the table.
  Map<ServiceAddress, ServiceRecord> get table => Map.unmodifiable(_table);

  /// Adds or replaces [record] and emits an up event.
  void add(ServiceRecord record) {
    _checkOpen();
    _table[record.address] = record;
    _events.add(ServiceEvent(up: true, record: record));
  }

  /// Removes the record for [address] if present and emits a down event.
  void remove(ServiceAddress address) {
    _checkOpen();
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
  Future<List<ServiceRecord>> resolve(Name type) async {
    _checkOpen();
    return [
      for (final r in _table.values)
        if (r.address.type == type) r,
    ];
  }

  @override
  Stream<ServiceEvent> get events => _events.stream;

  @override
  Future<void> get ready => Future.value();

  /// Defines (or redefines) the slot space of [space]'s type with every
  /// slot free. Slots of a previous definition are reported gone on
  /// [slotEvents].
  void defineSlots(SlotSpace space) {
    _checkOpen();
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
    _checkOpen();
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
    _checkOpen();
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
  Future<SlotEntry?> locateSlot(Name type, int slot) async {
    _checkOpen();
    return slotOwner(type, slot);
  }

  @override
  Future<void> close() async {
    _closed = true;
    // Not awaited: a paused listener would hold it for ever.
    unawaited(_events.close());
    unawaited(_slotEvents.close());
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
  bool _closed = false;

  /// Resolves to [endpoint], or fails with [StatusCode.failedPrecondition]
  /// after [close].
  @override
  Future<List<ServiceRecord>> resolve(Name type) async {
    if (_closed) {
      throw SwitchboardException.of(
        StatusCode.failedPrecondition,
        'endpoint resolver closed',
      );
    }
    return [
      ServiceRecord(ServiceAddress(type), endpoints: [endpoint]),
    ];
  }

  @override
  Stream<ServiceEvent> get events => const Stream.empty();

  @override
  Future<void> get ready => Future.value();

  @override
  Future<void> close() async {
    _closed = true;
  }
}
