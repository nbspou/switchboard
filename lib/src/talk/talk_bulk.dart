/*
Polyverse Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Authors:
  Jan Boon <jan.boon@kaetemi.be>
  Claude Opus 5.5 <noreply@anthropic.com>
*/

/// The wire structures of Talk bulk payloads (wiki page "Polyverse
/// Switchboard Talk", section "Bulk payloads"): the reference a `BULK`
/// message carries, and the open payload of a `_bulk` channel.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:meta/meta.dart';

import '../address/channel_address.dart';
import '../bytes.dart';
import '../mux/mux_channel.dart';
import '../name.dart';
import '../status.dart';

final Logger _log = Logger('Switchboard.Talk');

/// The payload field of a Talk message with the `BULK` flag
/// ([TalkFrame.bulk]): which bulk channel carries the payload, and how
/// long it is.
///
/// ```
/// u32   bulk number   among the bulk channels the sender opened for the
///                     message's channel, from 1
/// u48   length        payload bytes to expect; 0xFFFFFFFFFFFF unknown
/// ```
class TalkBulkReference {
  /// A reference to bulk channel [number] carrying [length] bytes (null:
  /// not known in advance).
  ///
  /// Throws [RangeError] for a [number] outside 1 to [maxNumber] or a
  /// [length] outside 0 to [maxLength].
  TalkBulkReference(this.number, {this.length}) {
    RangeError.checkValueInInterval(number, 1, maxNumber, 'number');
    final length = this.length;
    if (length != null) {
      RangeError.checkValueInInterval(length, 0, maxLength, 'length');
    }
  }

  /// Bytes of an encoded reference: the whole payload field of a `BULK`
  /// message. Any other length is a channel protocol error.
  static const int encodedLength = 10;

  /// The length field meaning "not known in advance".
  static const int unknownLength = 0xFFFFFFFFFFFF;

  /// The largest declared length.
  static const int maxLength = unknownLength - 1;

  /// The largest bulk number (`u32`).
  static const int maxNumber = 0xFFFFFFFF;

  /// The number of the bulk channel among those the sender opened for the
  /// channel the message travels on, from 1.
  final int number;

  /// The payload length in bytes, or null when the sender did not know it.
  final int? length;

  /// The 10 bytes of the payload field.
  Uint8List encode() {
    final w = ByteWriter(encodedLength)
      ..u32(number)
      ..u48(length ?? unknownLength);
    return w.toBytes();
  }

  /// Decodes the payload field of a `BULK` message. Throws
  /// [ProtocolException] unless it is exactly [encodedLength] bytes with a
  /// bulk number of at least 1.
  static TalkBulkReference decode(Uint8List payload) {
    if (payload.length != encodedLength) {
      throw ProtocolException('bulk reference of ${payload.length} bytes');
    }
    final r = ByteReader(payload);
    final number = r.u32('bulk number');
    final length = r.u48('bulk length');
    if (number == 0) {
      throw ProtocolException('bulk number 0');
    }
    return TalkBulkReference(
      number,
      length: length == unknownLength ? null : length,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is TalkBulkReference &&
      other.number == number &&
      other.length == length;

  @override
  int get hashCode => Object.hash(number, length);

  @override
  String toString() =>
      'TalkBulkReference($number, ${length ?? 'unknown'} bytes)';
}

/// The open payload of a bulk channel: an address header of the reserved
/// type `_bulk` (instance 0, no shard), whose application payload names
/// the parent channel and the bulk number.
///
/// ```
/// u48   parent channel id   the channel the message travels on, as the
///                           receiver of the OPEN sees it (a channel has
///                           the same id at both ends of a connection)
/// u32   bulk number         the number the message's reference carries
/// ```
///
/// A receiver admits a `_bulk` channel only while its parent is open on
/// the connection the OPEN arrived on, without consulting any listener
/// policy, and hands it to the parent's Talk layer (see
/// `TalkChannel.adoptBulk`).
class TalkBulkOpen {
  /// The open payload of bulk channel [number] for the channel [parentId].
  ///
  /// Throws [RangeError] for a [parentId] outside `u48` or a [number]
  /// outside 1 to [TalkBulkReference.maxNumber].
  TalkBulkOpen(this.parentId, this.number) {
    RangeError.checkValueInInterval(parentId, 0, 0xFFFFFFFFFFFF, 'parentId');
    RangeError.checkValueInInterval(
      number,
      1,
      TalkBulkReference.maxNumber,
      'number',
    );
  }

  /// The reserved service type of bulk channels.
  static final Name type = Name('_bulk');

  /// Bytes of the application payload.
  static const int payloadLength = 10;

  /// The id of the channel whose message the bulk channel carries.
  final int parentId;

  /// The bulk number, as the message's [TalkBulkReference] carries it.
  final int number;

  /// The address header and application payload of the OPEN.
  ChannelAddress get address =>
      ChannelAddress(type: type, payload: _applicationPayload());

  /// The complete OPEN payload.
  Uint8List encode() => address.encode();

  Uint8List _applicationPayload() {
    final w = ByteWriter(payloadLength)
      ..u48(parentId)
      ..u32(number);
    return w.toBytes();
  }

  /// Whether [address] is that of a bulk channel.
  static bool isBulk(ChannelAddress address) => address.type == type;

  /// Decodes the application payload of a `_bulk` OPEN ([address] must be
  /// of [type]); bytes after the two fields are ignored. Throws
  /// [ProtocolException] when it is shorter, or names bulk number 0.
  static TalkBulkOpen decode(ChannelAddress address) {
    final payload = address.payload;
    if (payload.length < payloadLength) {
      throw ProtocolException('_bulk open payload of ${payload.length} bytes');
    }
    final r = ByteReader(payload);
    final parent = r.u48('parent channel id');
    final number = r.u32('bulk number');
    if (number == 0) {
      throw ProtocolException('bulk number 0');
    }
    return TalkBulkOpen(parent, number);
  }

  @override
  String toString() => 'TalkBulkOpen(parent $parentId, number $number)';
}

/// Takes a bulk channel the peer opened for a parent channel, with its bulk
/// number: the parent's Talk layer, or a pipe forwarding it.
typedef BulkTarget = void Function(MuxChannel bulk, int number);

/// Where the `_bulk` channels of a connection go: per parent channel, the
/// target that takes them (wiki page "Polyverse Switchboard Addressing and
/// Dispatch", reserved type `_bulk`). Internal to the package; Talk
/// registers its channels, `pipeChannels` its piped ones, and the
/// Switchboard dispatcher (or `TalkChannel.adoptBulk`) routes.
@internal
abstract final class BulkRoutes {
  static final Expando<Map<int, _Route>> _routes = Expando<Map<int, _Route>>(
    'bulk routes',
  );
  static final Expando<bool> _bulk = Expando<bool>('bulk channel');

  /// Bulk channels held for a parent that no target took yet, beyond
  /// which a `_bulk` OPEN is closed `RESOURCE_EXHAUSTED`.
  static const int maxHeld = 16;

  /// Marks [channel] as a bulk channel, which no bulk channel may name as
  /// its parent.
  static void markBulk(MuxChannel channel) => _bulk[channel] = true;

  /// Whether [channel] is a bulk channel.
  static bool isBulk(MuxChannel channel) => _bulk[channel] ?? false;

  /// [target] takes the bulk channels the peer opens for [parent] from now
  /// on, and first those held for it until now, in order. Does nothing
  /// once [parent] is closed.
  static void register(MuxChannel parent, BulkTarget target) {
    if (parent.state == MuxChannelState.closed) {
      return;
    }
    final route = _routeOf(parent);
    route.target = target;
    final held = route.held;
    route.held = [];
    for (final (bulk, number) in held) {
      target(bulk, number);
    }
  }

  /// Routes [bulk], a channel the peer opened with the open payload
  /// [open], to the target of its parent: closed `FAILED_PRECONDITION` when
  /// no such channel is open on its connection (or it is itself a bulk
  /// channel), or when something that is not a target reads it; held for
  /// a target to come while nothing reads it yet, at most [maxHeld], then
  /// `RESOURCE_EXHAUSTED`. Held channels are closed `CANCELLED` when the
  /// parent closes.
  static void route(MuxChannel bulk, TalkBulkOpen open) {
    markBulk(bulk);
    bulk.priority = MuxPriority.bulk;
    final parent = bulk.connection.channelWithId(open.parentId);
    if (parent == null ||
        identical(parent, bulk) ||
        isBulk(parent) ||
        parent.state == MuxChannelState.closed) {
      _refuse(
        bulk,
        Status.of(
          StatusCode.failedPrecondition,
          'no open parent channel for the bulk channel',
        ),
      );
      return;
    }
    final route = _routeOf(parent);
    final target = route.target;
    if (target != null) {
      target(bulk, open.number);
      return;
    }
    if (parent.hasListener) {
      _refuse(
        bulk,
        Status.of(
          StatusCode.failedPrecondition,
          'the parent channel takes no bulk payloads',
        ),
      );
      return;
    }
    if (route.held.length >= maxHeld) {
      _refuse(
        bulk,
        Status.of(
          StatusCode.resourceExhausted,
          'too many bulk channels before their messages',
        ),
      );
      return;
    }
    route.held.add((bulk, open.number));
  }

  static void _refuse(MuxChannel bulk, Status status) {
    _log.fine('bulk channel ${bulk.id} refused: $status');
    unawaited(bulk.close(status));
  }

  static _Route _routeOf(MuxChannel parent) {
    final routes = _routes[parent.connection] ??= <int, _Route>{};
    final existing = routes[parent.id];
    if (existing != null && identical(existing.parent, parent)) {
      return existing;
    }
    final route = routes[parent.id] = _Route(parent);
    unawaited(
      parent.done.then((_) {
        if (identical(routes[parent.id], route)) {
          routes.remove(parent.id);
        }
        final held = route.held;
        route
          ..held = []
          ..target = null;
        for (final (bulk, _) in held) {
          unawaited(
            bulk.close(
              Status.of(StatusCode.cancelled, 'parent channel closed'),
            ),
          );
        }
      }),
    );
    return route;
  }
}

class _Route {
  _Route(this.parent);

  final MuxChannel parent;
  BulkTarget? target;
  List<(MuxChannel, int)> held = [];
}
