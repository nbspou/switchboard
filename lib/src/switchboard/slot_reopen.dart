/*
Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Author: Jan Boon <jan.boon@kaetemi.be>
*/

/// The `MOVED` retry shared by `Switchboard.openChannelToSlot` and
/// `proxyHandler`. Internal to the package; not exported.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:logging/logging.dart';

import '../address/channel_address.dart';
import '../address/service_address.dart';
import '../mux/mux_channel.dart';
import '../mux/mux_connection.dart';
import '../naming/naming_protocol.dart';
import '../status.dart';
import 'resolver.dart';
import 'switchboard.dart';

final Logger _log = Logger('Switchboard.Router');

/// Opens the replacement of a channel to the shard slot of [header] that
/// instance [rejectedBy] closed with [moved], or returns null when there is
/// nowhere else to go.
///
/// The target is the owner the status names ([MovedStatus]), unless the
/// resolver's table has an entry with a higher epoch; when the status
/// names none, the owner [SlotResolver.locateSlot] finds within
/// [Switchboard.slotRefreshTimeout].
/// An owner equal to [rejectedBy] does not count. Through a resolver
/// without a table for the type, the target is the named owner, or the
/// same address again (instance 0).
///
/// The replacement carries [header] with the instance set to the selected
/// one and no host hint; the application payload is unchanged unless
/// [payloadFor] is given, which then chooses it for the connection and
/// record selected (the per-destination credential of
/// `Switchboard.openChannelToSlot`). [resolver]
/// defaults to the node's; [excludeOwnEndpoints] as in
/// [Switchboard.selectAndConnect]. [mayLocate], when given, is asked
/// before a `LOCATE`; false gives up (null). [where] filters the records
/// as in [Switchboard.selectAndConnect]. Throws like
/// [Switchboard.selectAndConnect] and [SlotResolver.locateSlot].
Future<MuxChannel?> reopenAtSlotOwner(
  Switchboard switchboard,
  ChannelAddress header,
  int rejectedBy,
  Status moved, {
  Resolver? resolver,
  bool excludeOwnEndpoints = false,
  bool Function()? mayLocate,
  bool Function(ServiceRecord record)? where,
  FutureOr<Uint8List> Function(MuxConnection connection, ServiceRecord record)?
  payloadFor,
}) async {
  final type = header.type!;
  final slot = header.shard!;
  final named = MovedStatus.fromStatus(moved);
  var target = 0;
  if (named.hasOwner && named.owner != rejectedBy) {
    target = named.owner;
  }
  final r = resolver ?? switchboard.resolver;
  if (r is SlotResolver && r.slotTable(type) != null) {
    final mirrored = r.slotOwner(type, slot);
    if (mirrored != null &&
        mirrored.owner != rejectedBy &&
        (target == 0 || mirrored.epoch > named.epoch)) {
      target = mirrored.owner;
    }
    if (target == 0) {
      if (mayLocate != null && !mayLocate()) {
        _log.fine('$type/$slot: MOVED by $rejectedBy, no LOCATE allowed');
        return null;
      }
      final located = await r
          .locateSlot(type, slot)
          .timeout(switchboard.slotRefreshTimeout);
      if (located != null && located.owner != rejectedBy) {
        target = located.owner;
      }
    }
    if (target == 0) {
      _log.fine('$type/$slot: MOVED by $rejectedBy, no other owner known');
      return null;
    }
  }
  for (var attempt = 0; ; attempt++) {
    final (record, connection) = await switchboard.selectAndConnect(
      ServiceAddress(type, target),
      shard: slot,
      resolver: r,
      excludeOwnEndpoints: excludeOwnEndpoints,
      where: where,
    );
    var replacement = header.copyWith(
      instance: record.address.instance,
      clearHost: true,
    );
    if (payloadFor != null) {
      replacement = replacement.copyWith(
        payload: await payloadFor(connection, record),
      );
    }
    try {
      return connection.open(replacement.encode());
    } on SwitchboardException catch (e) {
      // A pooled connection may have received GOAWAY, or filled up, in
      // the meantime; one retry replaces it.
      if (attempt > 0 ||
          (e.code != StatusCode.failedPrecondition &&
              e.code != StatusCode.resourceExhausted)) {
        rethrow;
      }
    }
  }
}
