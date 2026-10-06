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

/// Maps a service type to the live instances of that type and where they
/// listen, and reports changes.
///
/// See the wiki page "Switchboard Addressing and Dispatch", section
/// "Resolvers".
abstract interface class Resolver {
  /// All known live instances of [type], in no particular order.
  ///
  /// Returns an empty list when nothing is known. Waits for [ready] first.
  Future<List<ServiceRecord>> resolve(Name type);

  /// Up and down events as the table changes. Broadcast stream.
  Stream<ServiceEvent> get events;

  /// Completes once the table is usable. Completes immediately for static
  /// resolvers; for a naming resolver, after the current session's `SYNCED`.
  Future<void> get ready;

  /// Releases resources. [resolve] fails afterwards.
  Future<void> close();
}

/// A configured, in-memory table. Used by tests, embedded style peers and
/// deployments without a naming service.
class StaticResolver implements Resolver {
  /// Creates a resolver pre-populated with [records].
  StaticResolver([Iterable<ServiceRecord> records = const []]) {
    for (final record in records) {
      _table[record.address] = record;
    }
  }

  final Map<ServiceAddress, ServiceRecord> _table = {};
  final StreamController<ServiceEvent> _events =
      StreamController<ServiceEvent>.broadcast();

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

  @override
  Future<void> close() => _events.close();
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
