/*
Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Author: Jan Boon <jan.boon@kaetemi.be>
*/

import 'dart:collection';

import '../name.dart';
import 'naming_protocol.dart';

/// A read-only view of the slot table of one type: its [space] and the
/// state of its slots.
///
/// The naming service exposes the authoritative tables
/// (`NamingService.slotTables`), a naming client the mirrored ones
/// (`NamingClient.slotTables`). The view is live: it reflects later
/// changes, until the space is redefined, which replaces the view.
class SlotTable {
  /// Creates a view over [entries], which the owner of the table keeps
  /// updating. Only for the naming service and client.
  SlotTable(this.space, Map<int, SlotEntry> entries)
    : entries = UnmodifiableMapView(entries);

  /// The slot space definition.
  final SlotSpace space;

  /// The slots that have a recorded state, by slot number. A slot that is
  /// missing is [SlotEntry.unassigned]. A mirror holds only the slots that
  /// are not free with holder 0 (those are left out of snapshots); the
  /// naming service also keeps free slots that only have an epoch.
  final Map<int, SlotEntry> entries;

  /// The sharded type.
  Name get type => space.type;

  /// The number of slots.
  int get count => space.count;

  /// The state of [slot]. Throws [RangeError] unless `0 <= slot < count`.
  SlotEntry operator [](int slot) {
    RangeError.checkValueInInterval(slot, 0, count - 1, 'slot');
    return entries[slot] ?? SlotEntry.unassigned;
  }

  /// The distinct instances traffic is routed to: the owners of owned
  /// slots and, while a slot migrates, its old owner (`from`). A new set,
  /// exact when read.
  Set<int> get owners => {
    for (final entry in entries.values)
      if (entry.owner != 0) entry.owner,
  };

  /// The slots routed to [instance] (owned by it, or migrating away from
  /// it), in ascending order.
  List<int> slotsOf(int instance) => [
    for (final MapEntry(key: slot, value: entry) in entries.entries)
      if (entry.owner == instance) slot,
  ]..sort();

  @override
  String toString() => 'SlotTable($space, ${entries.length} entries)';
}

/// A change of one slot in a mirrored slot table.
class SlotEvent {
  /// Creates an event.
  const SlotEvent(this.type, this.slot, this.entry, this.previous);

  /// The sharded type.
  final Name type;

  /// The slot number.
  final int slot;

  /// The new state ([SlotEntry.unassigned] when the slot left the table).
  final SlotEntry entry;

  /// The state before the change.
  final SlotEntry previous;

  @override
  String toString() => 'SlotEvent($type/$slot: $previous -> $entry)';
}
