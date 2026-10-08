/*
Polyverse Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Authors:
  Jan Boon <jan.boon@kaetemi.be>
  Claude Opus 5.5 <noreply@anthropic.com>
*/

/// The `MOVED` retry shared by `Switchboard.openChannelToSlot` and
/// `proxyHandler`. Internal to the package; not exported.
library;

import 'dart:async';

import 'package:logging/logging.dart';

import '../address/channel_address.dart';
import '../address/service_address.dart';
import '../mux/mux_channel.dart';
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
/// An owner equal to [rejectedBy] does not count. With a newer table
/// entry pointing back to [rejectedBy], the retry is
/// abandoned rather than following the older rejection to another owner.
/// Through a resolver without a table for the type, the target is the
/// named owner, or the same address again (instance 0).
///
/// The replacement carries [header] with the instance set to the selected
/// one and no host hint; the application payload is unchanged unless
/// [implicitPayload] is set, which then has the node choose it for the
/// connection and record selected (the per-destination credential of
/// `Switchboard.openChannelToSlot`). [resolver]
/// defaults to the node's; [excludeOwnEndpoints] as in
/// [Switchboard.selectAndConnect]; with [mayRelay] an owner without
/// endpoints is reached through the node's relay when the node cannot
/// broker (`Switchboard.relay`). [mayLocate], when given, is asked
/// before a `LOCATE`; false gives up (null). [where] filters the records
/// as in [Switchboard.selectAndConnect]: a target it refuses fails with
/// [StatusCode.notFound], whereas a target the resolver does not know
/// gives up (null). Throws like [Switchboard.selectAndConnect] and
/// [SlotResolver.locateSlot].
Future<MuxChannel?> reopenAtSlotOwner(
  Switchboard switchboard,
  ChannelAddress header,
  int rejectedBy,
  Status moved, {
  Resolver? resolver,
  bool excludeOwnEndpoints = false,
  bool Function()? mayLocate,
  bool Function(ServiceRecord record)? where,
  bool implicitPayload = false,
  bool mayRelay = false,
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
        ((target == 0 && mirrored.owner != rejectedBy) ||
            (target != 0 && mirrored.epoch > named.epoch))) {
      target = mirrored.owner;
    }
    if (target == rejectedBy) {
      _log.fine('$type/$slot: newer table still names $rejectedBy; no retry');
      return null;
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
  var refused = false;
  final filter = where == null
      ? null
      : (ServiceRecord record) {
          final accepted = where(record);
          refused |= !accepted;
          return accepted;
        };
  try {
    // A pooled connection that went away or filled up in the meantime is
    // replaced once.
    final (channel, _) = await switchboard.openSelected(
      ServiceAddress(type, target),
      header,
      resolver: r,
      excludeOwnEndpoints: excludeOwnEndpoints,
      where: filter,
      implicitPayload: implicitPayload,
      mayRelay: mayRelay,
    );
    return channel;
  } on SwitchboardException catch (e) {
    if (e.code != StatusCode.notFound || refused) {
      rethrow;
    }
    // Not in the resolver's table (yet): nowhere to go.
    _log.fine('$type/$slot: MOVED by $rejectedBy, ${e.status}');
    return null;
  }
}
