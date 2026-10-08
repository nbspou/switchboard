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
import 'dart:math';
import 'dart:typed_data';

import 'package:logging/logging.dart';

import '../address/channel_address.dart';
import '../mux/mux_channel.dart';
import '../mux/mux_connection.dart';
import '../name.dart';
import '../naming/naming_protocol.dart';
import '../status.dart';
import 'forwarding.dart';
import 'generic_status.dart';
import 'incoming_channel.dart';
import 'resolver.dart';
import 'slot_channel.dart';
import 'slot_reopen.dart';
import 'switchboard.dart';

final Logger _log = Logger('Switchboard.Router');

/// Channel proxying: forwards every DATA subframe between [a] and [b], in
/// order and unchanged, and forwards the close.
///
/// Flow control passes through hop by hop: both channels are switched to
/// [MuxChannel.manualCredit], and a subframe received on one counts as
/// consumed, and its credit goes back to that side's peer, only once the
/// other side's [MuxChannel.send] has taken it (its future completed). So
/// a slow consumer behind one side slows the sender behind the other, and
/// what the proxy holds for each direction is bounded by the window it
/// grants the sending side plus the window the receiving side grants it.
/// The output tier ([MuxChannel.priority]) of each side is its own; set it
/// on the channels before or after the call.
///
/// When one side's stream ends (its peer sent CLOSE, or its connection was
/// lost) the other side is closed with that side's end status.
/// `CONNECTION_LOST`, which is local only, is sent as `UNAVAILABLE`, and
/// application codes (256 and above), which mux CLOSE must not carry, as
/// `UNKNOWN`. A subframe that cannot be forwarded (it exceeds the frame
/// limit the receiving peer announced) closes both sides with that error.
///
/// Both streams are listened to before this returns, so subframes that
/// arrived before the call (buffered by the channels) are forwarded too.
/// Neither stream may have been listened to already (for example by
/// wrapping the channel in a `TalkChannel`); if one has, both channels are
/// closed with `INTERNAL`. Completes when both channels are done; never
/// throws and never completes with an error.
///
/// See the wiki page "Polyverse Switchboard Proxying", section "Channel proxying".
Future<void> pipeChannels(MuxChannel a, MuxChannel b) =>
    _pipe(_MuxEnd(a), _MuxEnd(b));

/// [pipeChannels] over [_End]s; [toA] rewrites the status [a] is closed
/// with when [b] ends.
Future<void> _pipe(_End a, _End b, {Status Function(Status status)? toA}) {
  try {
    _forward(a, b);
    _forward(b, a, rewrite: toA);
  } on Object catch (e) {
    _log.warning('proxy: cannot pipe channels ${a.id} and ${b.id}: $e');
    final status = Status.of(StatusCode.internal, 'cannot pipe channels');
    unawaited(a.close(status));
    unawaited(b.close(status));
  }
  return Future.wait<Status>([a.done, b.done]).then<void>((_) {});
}

/// One side of a pipe: a mux channel, or a [SlotChannel] (which may
/// replace its mux channel once).
abstract interface class _End {
  Stream<Uint8List> get stream;
  bool get canSend;
  Future<void> send(Uint8List subframe);
  set manualCredit(bool value);
  void consumed(int bytes);
  Future<void> close(Status status);
  Future<Status> get done;
  int get id;
}

class _MuxEnd implements _End {
  _MuxEnd(this.channel);

  final MuxChannel channel;

  @override
  Stream<Uint8List> get stream => channel.stream;
  @override
  bool get canSend => channel.canSend;
  @override
  Future<void> send(Uint8List subframe) => channel.send(subframe);
  @override
  set manualCredit(bool value) => channel.manualCredit = value;
  @override
  void consumed(int bytes) => channel.consumed(bytes);
  @override
  Future<void> close(Status status) => channel.close(status);
  @override
  Future<Status> get done => channel.done;
  @override
  int get id => channel.id;
}

class _SlotEnd implements _End {
  _SlotEnd(this.channel);

  final SlotChannel channel;

  @override
  Stream<Uint8List> get stream => channel.stream;
  @override
  bool get canSend => channel.canSend;
  @override
  Future<void> send(Uint8List subframe) => channel.send(subframe);
  @override
  set manualCredit(bool value) => channel.manualCredit = value;
  @override
  void consumed(int bytes) => channel.consumed(bytes);
  @override
  Future<void> close(Status status) => channel.close(status);
  @override
  Future<Status> get done => channel.done;
  @override
  int get id => channel.channel.id;
}

/// Returns the credit of a subframe of [length] bytes [from] delivered.
void _consumed(_End from, int length) {
  try {
    from.consumed(length);
  } on StateError catch (e) {
    _log.warning('proxy: credit accounting of channel ${from.id}: $e');
  }
}

void _forward(_End from, _End to, {Status Function(Status status)? rewrite}) {
  // Credit for what [from] receives goes back once [to] has taken it.
  from.manualCredit = true;
  from.stream.listen(
    (subframe) {
      final length = subframe.length;
      if (!to.canSend) {
        // The other side is closing; its CLOSE ends this side too.
        _consumed(from, length);
        return;
      }
      try {
        to
            .send(subframe)
            .then(
              (_) => _consumed(from, length),
              // [to] ended while the subframe waited: its end closes
              // [from] too.
              onError: (Object _) => _consumed(from, length),
            );
      } on SwitchboardException catch (e) {
        _consumed(from, length);
        _log.warning(
          'proxy: cannot forward ${subframe.length} bytes from channel '
          '${from.id} to channel ${to.id}: ${e.status}',
        );
        final status = e.code == null
            ? Status.of(StatusCode.internal)
            : genericStatus(e.code!);
        unawaited(to.close(status));
        unawaited(from.close(status));
      }
    },
    onError: (Object e) => _log.fine('proxy: channel ${from.id} failed: $e'),
    onDone: () {
      unawaited(
        from.done.then((status) {
          final forwarded = _closeStatusFor(status);
          return to.close(rewrite == null ? forwarded : rewrite(forwarded));
        }),
      );
    },
  );
}

/// The status a proxy sends in CLOSE when the channel on the other side
/// ended with [status]: `CONNECTION_LOST` becomes `UNAVAILABLE` (with a
/// generic reason, as the local reason concerns the proxy's own
/// connection) and application codes become `UNKNOWN`; everything else,
/// which the peer on the other side sent, is forwarded as is.
Status _closeStatusFor(Status status) {
  if (status.known == StatusCode.connectionLost) {
    return Status.of(StatusCode.unavailable, 'connection lost');
  }
  if (status.isApplicationCode) {
    return Status.of(
      StatusCode.unknown,
      'application status ${status.code}'
      '${status.reason.isEmpty ? '' : ': ${status.reason}'}',
    );
  }
  return status;
}

/// A [ChannelHandler] that proxies channels to the service they address,
/// for use as [Switchboard.catchAll] on a frontend endpoint or a relay.
///
/// For each channel:
///
/// 1. If [allow] returns false for the address header, or throws, the
///    channel is rejected with `PERMISSION_DENIED`. The default [allow]
///    refuses the reserved types (`_ns` and the rest of the `_`
///    namespace), so that the naming service of the mesh behind the proxy
///    is not reachable through it; pass an explicit [allow] to proxy those
///    deliberately. A channel without a service type is rejected with
///    `NOT_FOUND`.
/// 2. If the client connection the channel arrived on already has
///    [maxChannelsPerConnection] channels being forwarded or authorized
///    (0 = no limit), the channel is rejected with `RESOURCE_EXHAUSTED`.
///    All clients share the proxy's pooled connections to a backend, so
///    without this bound one client could use up the channels a backend
///    accepts for everyone.
/// 3. If [authorize] is given, it is called with the channel and may take
///    its time, for example to verify the session credential in the
///    application payload with an authentication service; meanwhile the
///    channel is not read (the mux buffers what the client sends, within
///    its limits). It returns the address to forward to: the channel's
///    own [IncomingChannel.address], or a rewritten one (the shard slot
///    set from the verified account, the payload replaced by a credential
///    the backends trust, and so on), which steps 4 and 5 use instead of
///    the client's. It returns null to reject the channel with
///    `UNAUTHENTICATED`; a throw rejects it with `PERMISSION_DENIED`; an
///    address without a service type is rejected with `NOT_FOUND`. If it
///    has not answered within [authorizeTimeout] (default 10 s,
///    [Duration.zero] for no bound) the channel is rejected with
///    `UNAUTHENTICATED` and its late answer is ignored. A channel whose
///    client closed it meanwhile is dropped.
/// 4. If the header carries a host hint and [Switchboard.allowHostHint] is
///    set, the proxy connects to that host: a URI, or `host:port` meaning
///    `tcp://host:port`. Otherwise the hint is ignored and the destination
///    is resolved with [resolver] (default: [Switchboard.resolver]) as in
///    [Switchboard.selectAndConnect]. Destinations that are this node's own
///    listeners ([Switchboard.isOwnEndpoint]) are never connected to: a
///    record or hint pointing back at the proxy would otherwise make it
///    forward to itself without end. A failure rejects the channel with
///    its status code (`NOT_FOUND`, `UNAVAILABLE`, ...); a missing
///    resolver or a closing node is `UNAVAILABLE`.
///    A channel with a shard slot whose type has a slot table in the
///    resolver goes to the slot's owner (the old owner while the slot
///    migrates; see [Switchboard.selectAndConnect]). Unless
///    [allowExplicitInstance] is set, an instance in its address (the
///    client's, or one [authorize] set) is ignored for such a channel:
///    it is routed by the slot table, and the instance is replaced by the
///    selected owner, so that a client cannot reach an instance that is
///    still loading the slot, or one that handed it over, and overtake
///    the hand-over. When the table has no owner for the slot and the
///    proxy would have to ask the naming service (`LOCATE`, which assigns
///    a free slot of a managed space), the client connection must have a
///    token left in its bucket of [maxLocatesPerConnection] tokens,
///    refilled by one every [locateRefillInterval]; otherwise the channel
///    is rejected with `RESOURCE_EXHAUSTED`. The `LOCATE` itself waits at
///    most [Switchboard.slotRefreshTimeout] (then `UNAVAILABLE`).
///    A channel *without* a shard slot (in the address as [authorize]
///    returned it) whose type has a slot table in the resolver is rejected
///    with `PERMISSION_DENIED` unless [allowNoSlot] returns true for the
///    type: on a sharded type's instances such a channel reaches the
///    `noSlotHandler` of their `SlotGate`, the state transfer between
///    instances, which clients have no business with. The default (null)
///    refuses every such channel. An admitted one is routed like a channel
///    to a type without a slot table: to the instance its address names,
///    else round robin over the type's instances, the selected instance
///    filled in. The slot tables are looked at once the resolver is ready
///    (its `resolve` answered; a failure rejects the channel with the code
///    the forwarding would fail with), so that a resolver still syncing
///    lets neither a channel without a slot nor an instance the client
///    named past a table. Channels relayed to a host hint are not checked:
///    they bypass the resolver and its tables.
/// 5. A channel is opened to the destination with the same open payload
///    (as rewritten by [authorize]), except that the host hint is removed
///    and the instance is set to the selected one. The application payload
///    is forwarded unchanged; the proxy's own [Switchboard.defaultPayload]
///    is not applied.
/// 6. The two channels are joined with [pipeChannels]. For a slot routed
///    by a slot table, if the owner rejects the channel with CLOSE `MOVED`
///    before any subframe has been piped either way, the proxy opens it
///    once more at the new owner (named by the rejection, or a newer table
///    entry, or found with [SlotResolver.locateSlot] within
///    [Switchboard.slotRefreshTimeout]) with the same open payload, the
///    instance set to the new owner's, and the client does not notice.
///    What the client sends meanwhile is held, and its credit goes back
///    only once the replacement has taken it, so the client waits once it
///    has used the window the proxy grants it: the proxy holds at most
///    that window.
///    After the first subframe, or when no other owner is found, the
///    `MOVED` is forwarded to the client, which may open the channel again
///    and resend, since `MOVED` means nothing was processed (see
///    `Switchboard.openChannelToSlot`). A `RELOCATED` (the owner was
///    serving the channel when the slot moved) is forwarded and never
///    retried. The retry counts as the same channel for
///    [maxChannelsPerConnection], and a `LOCATE` it needs takes a token as
///    in step 4.
///
/// A `MOVED` or `RELOCATED` a backend closes the channel with reaches the
/// client with its owner and epoch fields set to 0 (unknown) and no
/// reason, unless [revealOwners] is set: instance ids are internal to the
/// mesh, and a client behind the proxy reopens through the proxy, which
/// routes by its own table. With [revealOwners] the status is forwarded
/// byte for byte. Statuses inside the channel (a Talk `ABORT`) are not
/// looked at.
///
/// Rejections carry the status code and a generic reason only; the
/// details (instance ids, endpoints, resolver state) are logged locally.
///
/// Honouring host hints makes the node an open relay; see
/// [Switchboard.allowHostHint].
///
/// If [allowNoSlot] throws, the error is logged and the channel is
/// refused, as when it returns false.
///
/// Throws [RangeError] if [maxChannelsPerConnection] or
/// [maxLocatesPerConnection] is negative, [ArgumentError] if
/// [authorizeTimeout] or [locateRefillInterval] is negative.
ChannelHandler proxyHandler(
  Switchboard switchboard, {
  bool Function(ChannelAddress address)? allow,
  FutureOr<ChannelAddress?> Function(IncomingChannel incoming)? authorize,
  Duration authorizeTimeout = const Duration(seconds: 10),
  Resolver? resolver,
  int maxChannelsPerConnection = 256,
  bool allowExplicitInstance = false,
  bool revealOwners = false,
  int maxLocatesPerConnection = 32,
  Duration locateRefillInterval = const Duration(seconds: 1),
  bool Function(Name type)? allowNoSlot,
}) {
  RangeError.checkNotNegative(
    maxChannelsPerConnection,
    'maxChannelsPerConnection',
  );
  RangeError.checkNotNegative(
    maxLocatesPerConnection,
    'maxLocatesPerConnection',
  );
  for (final (name, value) in [
    ('authorizeTimeout', authorizeTimeout),
    ('locateRefillInterval', locateRefillInterval),
  ]) {
    if (value.isNegative) {
      throw ArgumentError.value(value, name, 'must not be negative');
    }
  }
  final permitted = allow ?? _notReserved;
  // Channels being forwarded, per client connection.
  final forwarding = ForwardingBound(maxChannelsPerConnection);
  final locates = _LocateBuckets(maxLocatesPerConnection, locateRefillInterval);
  final Status Function(Status status)? hide = revealOwners ? null : _hideOwner;
  return (incoming) async {
    var address = incoming.address;
    bool allowed;
    try {
      allowed = permitted(address);
    } catch (error, stackTrace) {
      _log.warning(
        'proxy: allow filter threw for $incoming',
        error,
        stackTrace,
      );
      allowed = false;
    }
    if (!allowed) {
      _log.fine('proxy: $incoming not allowed');
      await incoming.reject(genericStatus(StatusCode.permissionDenied));
      return;
    }
    if (address.type == null) {
      _log.fine('proxy: $incoming has no service type');
      await incoming.reject(genericStatus(StatusCode.notFound));
      return;
    }
    final client = incoming.connection;
    if (!forwarding.enter(client)) {
      _log.info(
        'proxy: $incoming refused, ${forwarding.countOf(client)} channels '
        'of this connection are being forwarded',
      );
      await incoming.reject(genericStatus(StatusCode.resourceExhausted));
      return;
    }
    try {
      if (authorize != null) {
        final (authorized, refusal) = await _authorize(
          incoming,
          authorize,
          authorizeTimeout,
        );
        if (authorized == null) {
          await incoming.reject(genericStatus(refusal));
          return;
        }
        if (!incoming.channel.canSend) {
          _log.fine('proxy: $incoming closed while being authorized');
          return;
        }
        address = authorized;
      }
      final type = address.type;
      if (type == null) {
        _log.fine('proxy: $incoming authorized without a service type');
        await incoming.reject(genericStatus(StatusCode.notFound));
        return;
      }
      final r = resolver ?? switchboard.resolver;
      final shard = address.shard;
      final relaying = address.host != null && switchboard.allowHostHint;
      if (!relaying && r is SlotResolver) {
        // The slot tables are complete once the resolver answers: one
        // still syncing has none yet, and would let a channel without a
        // slot, or a client-named instance, past its table.
        final failure = await _resolved(r, type, incoming);
        if (failure != null) {
          await incoming.reject(genericStatus(failure));
          return;
        }
        final table = r.slotTable(type);
        if (table != null &&
            shard == null &&
            !_admitNoSlot(type, allowNoSlot, incoming)) {
          await incoming.reject(genericStatus(StatusCode.permissionDenied));
          return;
        }
        if (table != null && shard != null) {
          if (address.instance != 0 && !allowExplicitInstance) {
            _log.fine('proxy: $incoming routed by the slot table instead');
            address = address.copyWith(instance: 0);
          }
          if (address.instance == 0 &&
              shard < table.count &&
              table.space.mode == SlotMode.managed &&
              r.slotOwner(type, shard) == null &&
              !locates.take(client)) {
            _log.info('proxy: $incoming refused, too many LOCATEs');
            await incoming.reject(genericStatus(StatusCode.resourceExhausted));
            return;
          }
        }
      }
      final ForwardTarget backend;
      try {
        backend = await openForwarded(
          switchboard,
          address,
          type,
          resolver: resolver,
        );
      } on SwitchboardException catch (e) {
        _log.fine('proxy: $incoming: ${e.status}');
        await incoming.reject(genericStatus(e.code ?? StatusCode.unavailable));
        return;
      }
      final channel = backend.channel;
      _log.fine(
        'proxy: $incoming piped to channel ${channel.id} of '
        '${channel.connection}',
      );
      final header = backend.header;
      if (!backend.hostHint &&
          shard != null &&
          r is SlotResolver &&
          r.slotTable(type) != null) {
        // The owner may have moved since the table was read: one retry
        // while nothing has been piped.
        final slotChannel = SlotChannel(
          type,
          shard,
          channel,
          (moved) => reopenAtSlotOwner(
            switchboard,
            header,
            header.instance,
            moved,
            resolver: r,
            excludeOwnEndpoints: true,
            mayLocate: () => locates.take(client),
          ),
          // Bounded by flow control: what the client sends is held within
          // the window granted to it, and its credit goes back only once
          // the replacement takes it.
          maxHeldBytes: 0,
        );
        await _pipe(
          _MuxEnd(incoming.channel),
          _SlotEnd(slotChannel),
          toA: hide,
        );
        return;
      }
      await _pipe(_MuxEnd(incoming.channel), _MuxEnd(channel), toA: hide);
    } finally {
      forwarding.exit(client);
    }
  };
}

/// Waits for [r] to answer for [type], after which its slot tables are
/// complete: null once it has, else the code [proxyHandler] rejects the
/// channel with, the one the forwarding would fail with.
Future<StatusCode?> _resolved(
  SlotResolver r,
  Name type,
  IncomingChannel incoming,
) async {
  try {
    await r.resolve(type);
    return null;
  } on SwitchboardException catch (e) {
    _log.fine('proxy: $incoming: ${e.status}');
    final code = e.code ?? StatusCode.unavailable;
    return code == StatusCode.failedPrecondition
        ? StatusCode.unavailable
        : code;
  }
}

/// Whether [proxyHandler] forwards a channel without a shard slot to
/// [type], which has a slot table: only when [allow] (null: nothing)
/// admits the type. A throwing [allow] refuses.
bool _admitNoSlot(
  Name type,
  bool Function(Name type)? allow,
  IncomingChannel incoming,
) {
  var allowed = false;
  if (allow != null) {
    try {
      allowed = allow(type);
    } catch (error, stackTrace) {
      _log.warning('proxy: allowNoSlot threw for $incoming', error, stackTrace);
    }
  }
  if (!allowed) {
    _log.fine('proxy: $incoming has no shard slot for a table-routed type');
  }
  return allowed;
}

bool _notReserved(ChannelAddress address) =>
    !(address.type?.isReserved ?? false);

/// A `MOVED` or `RELOCATED` with its owner and epoch unknown and no
/// reason; any other status unchanged.
Status _hideOwner(Status status) {
  if (!MovedStatus.carriesFields(status)) {
    return status;
  }
  return MovedStatus.unknown.toStatus(
    relocated: status.known == StatusCode.relocated,
  );
}

/// The `LOCATE` budget of [proxyHandler]: a token bucket per client
/// connection, [burst] tokens, refilled by one every [refill] (never when
/// zero). A [burst] of 0 is no limit.
class _LocateBuckets {
  _LocateBuckets(this.burst, this.refill);

  final int burst;
  final Duration refill;
  final Stopwatch _clock = Stopwatch()..start();
  final Expando<_Bucket> _buckets = Expando<_Bucket>('LOCATE tokens');

  /// Takes a token for [connection]; false when there is none left.
  bool take(MuxConnection connection) {
    if (burst == 0) {
      return true;
    }
    final now = _clock.elapsedMicroseconds;
    final bucket = _buckets[connection] ??= _Bucket(burst.toDouble(), now);
    if (refill > Duration.zero) {
      bucket.tokens = min(
        burst.toDouble(),
        bucket.tokens + (now - bucket.at) / refill.inMicroseconds,
      );
    }
    bucket.at = now;
    if (bucket.tokens < 1) {
      return false;
    }
    bucket.tokens -= 1;
    return true;
  }
}

class _Bucket {
  _Bucket(this.tokens, this.at);

  double tokens;

  /// Microseconds of [_LocateBuckets._clock] at the last refill.
  int at;
}

/// Runs the `authorize` hook of [proxyHandler] on [incoming], bounded by
/// [timeout] (zero: no bound). Returns the address to forward to, or null
/// and the code to reject with.
Future<(ChannelAddress?, StatusCode)> _authorize(
  IncomingChannel incoming,
  FutureOr<ChannelAddress?> Function(IncomingChannel incoming) authorize,
  Duration timeout,
) async {
  try {
    var answer = Future<ChannelAddress?>.sync(() => authorize(incoming));
    if (timeout > Duration.zero) {
      answer = answer.timeout(
        timeout,
        onTimeout: () => throw const _AuthorizeTimedOut(),
      );
    }
    final address = await answer;
    if (address == null) {
      _log.fine('proxy: $incoming not authenticated');
    }
    return (address, StatusCode.unauthenticated);
  } on _AuthorizeTimedOut {
    _log.info('proxy: $incoming not authorized within $timeout');
    return (null, StatusCode.unauthenticated);
  } catch (error, stackTrace) {
    // Clients can trigger this at will (a malformed credential, say).
    _log.fine('proxy: authorize refused $incoming', error, stackTrace);
    return (null, StatusCode.permissionDenied);
  }
}

/// The `authorize` hook of [proxyHandler] did not answer in time.
class _AuthorizeTimedOut implements Exception {
  const _AuthorizeTimedOut();
}
