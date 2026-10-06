/*
Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Author: Jan Boon <jan.boon@kaetemi.be>
*/

import 'dart:async';

import 'package:logging/logging.dart';

import '../name.dart';
import '../status.dart';
import '../switchboard/resolver.dart';
import 'naming_client.dart';
import 'naming_protocol.dart';
import 'slot_table.dart';

/// Resolves through the table a [NamingClient] mirrors from the naming
/// service. The normal backend resolver.
///
/// Resolution waits until the client has been synced once, at most
/// [resolveTimeout]; see [resolve]. The resolver does not start the client.
class NamingResolver implements SlotResolver {
  /// Creates a resolver over [client], which may be in any state: whether
  /// the stale table is served depends only on [NamingClient.hasSynced].
  NamingResolver(
    this.client, {
    this.resolveTimeout = const Duration(seconds: 5),
  });

  /// The client whose table this resolver reads.
  final NamingClient client;

  /// How long [resolve] waits for the client to be synced.
  final Duration resolveTimeout;

  static final Logger _log = Logger('Switchboard.Naming');

  bool _closed = false;

  /// All instances of [type] in the client's table.
  ///
  /// Before the client's first `SYNCED` ([NamingClient.hasSynced]) this
  /// waits for [NamingClient.firstSynced], at most [resolveTimeout], and
  /// then fails with [SwitchboardException] [StatusCode.unavailable]. Once
  /// the client has been synced once, a later loss of the naming service
  /// does not block resolution, whether or not anything was resolved
  /// before: the mirrored table is served as it was (stale) until the
  /// client resynchronizes. Fails with [StatusCode.failedPrecondition]
  /// after [close] and with [StatusCode.cancelled] if the client is closed
  /// while waiting.
  @override
  Future<List<ServiceRecord>> resolve(Name type) async {
    _checkOpen();
    if (!client.hasSynced) {
      try {
        await client.firstSynced.timeout(resolveTimeout);
      } on TimeoutException {
        throw SwitchboardException.of(
          StatusCode.unavailable,
          'naming service not synced within $resolveTimeout',
        );
      }
      _checkOpen();
    }
    if (!client.isSynced) {
      _log.fine('serving stale table for $type while resynchronizing');
    }
    return [
      for (final record in client.table.values)
        if (record.address.type == type) record,
    ];
  }

  void _checkOpen() {
    if (_closed || client.isClosed) {
      throw SwitchboardException.of(
        StatusCode.failedPrecondition,
        'naming resolver closed',
      );
    }
  }

  /// The client's [NamingClient.events].
  @override
  Stream<ServiceEvent> get events => client.events;

  /// The client's mirrored slot table of [type]
  /// ([NamingClient.slotTable]), or null without a slot space.
  @override
  SlotTable? slotTable(Name type) => client.slotTable(type);

  /// Where traffic for [slot] of [type] goes, from the client's mirror
  /// ([NamingClient.slotOwner]): the entry if the slot is owned or
  /// migrating (route to [SlotEntry.owner]), null otherwise.
  @override
  SlotEntry? slotOwner(Name type, int slot) => client.slotOwner(type, slot);

  /// The distinct instances the slots of [type] are routed to
  /// ([NamingClient.slotOwners]).
  @override
  Set<int> slotOwners(Name type) => client.slotOwners(type);

  /// The client's [NamingClient.slotEvents].
  @override
  Stream<SlotEvent> get slotEvents => client.slotEvents;

  /// Asks the naming service for the owner of [slot] of [type]
  /// ([NamingClient.locate]); in a managed space a free slot is assigned
  /// first. Returns the mirrored entry if the mirror already shows an
  /// owner at least as recent, else an entry built from the answer; null
  /// when the slot stays free.
  @override
  Future<SlotEntry?> locateSlot(Name type, int slot) async {
    final located = await client.locate(type, slot);
    final mirrored = client.slotOwner(type, slot);
    if (mirrored != null && mirrored.epoch >= located.epoch) {
      return mirrored;
    }
    if (located.owner == 0) {
      return null;
    }
    return SlotEntry(
      state: located.state,
      owner: located.owner,
      epoch: located.epoch,
    );
  }

  /// The client's [NamingClient.firstSynced]: completes once the table has
  /// been synced at least once, and stays complete through later losses of
  /// the naming service (the stale table is served meanwhile). Fails with
  /// [StatusCode.cancelled] if the client is closed before its first
  /// `SYNCED`.
  @override
  Future<void> get ready => client.firstSynced;

  /// Closes the resolver and its client: the client stops reconnecting and
  /// its registrations are dropped by the naming service.
  @override
  Future<void> close() async {
    _closed = true;
    await client.close();
  }
}
