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

/// Resolves through the table a [NamingClient] mirrors from the naming
/// service. The normal backend resolver.
///
/// Resolution waits until the client is synced, at most [resolveTimeout];
/// see [resolve]. The resolver does not start the client.
class NamingResolver implements Resolver {
  /// Creates a resolver over [client].
  NamingResolver(
    this.client, {
    this.resolveTimeout = const Duration(seconds: 5),
  }) {
    // Remember the first sync even if nothing is resolved before the naming
    // service goes away, so that the stale table is served from then on.
    if (client.isSynced) {
      _everSynced = true;
    } else {
      client.synced.then<void>((_) => _everSynced = true, onError: (_) {});
    }
  }

  /// The client whose table this resolver reads.
  final NamingClient client;

  /// How long [resolve] waits for the client to be synced.
  final Duration resolveTimeout;

  static final Logger _log = Logger('Switchboard.Naming');

  bool _closed = false;
  bool _everSynced = false;

  /// All instances of [type] in the client's table.
  ///
  /// Before the first `SYNCED` this waits for [NamingClient.synced], at most
  /// [resolveTimeout], and then fails with [SwitchboardException]
  /// [StatusCode.unavailable]. Once the client has been synced once, a later
  /// loss of the naming service does not block resolution: the mirrored
  /// table is served as it was (stale) until the client resynchronizes.
  /// Fails with [StatusCode.failedPrecondition] after [close] and with
  /// [StatusCode.cancelled] if the client is closed while waiting.
  @override
  Future<List<ServiceRecord>> resolve(Name type) async {
    _checkOpen();
    if (!client.isSynced && !_everSynced) {
      try {
        await client.synced.timeout(resolveTimeout);
      } on TimeoutException {
        throw SwitchboardException.of(
          StatusCode.unavailable,
          'naming service not synced within $resolveTimeout',
        );
      }
      _checkOpen();
    }
    if (client.isSynced) {
      _everSynced = true;
    } else {
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

  /// The client's [NamingClient.synced] of the current session.
  @override
  Future<void> get ready => client.synced;

  /// Closes the resolver and its client: the client stops reconnecting and
  /// its registrations are dropped by the naming service.
  @override
  Future<void> close() async {
    _closed = true;
    await client.close();
  }
}
