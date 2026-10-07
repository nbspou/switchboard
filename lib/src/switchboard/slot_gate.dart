/*
Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Author: Jan Boon <jan.boon@kaetemi.be>
*/

import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:logging/logging.dart';

import '../address/channel_address.dart';
import '../address/service_address.dart';
import '../mux/mux_channel.dart';
import '../name.dart';
import '../naming/naming_client.dart';
import '../naming/naming_protocol.dart';
import '../status.dart';
import '../talk/talk_channel.dart';
import '../talk/talk_message.dart';
import 'generic_status.dart';
import 'incoming_channel.dart';
import 'proxy.dart';
import 'slot_channel.dart';
import 'switchboard.dart';

final Logger _log = Logger('Switchboard.Router');

/// The epoch after [epoch], as the naming service assigns it (wrapping to
/// 1).
int _nextEpoch(int epoch) => epoch >= maxU32 ? 1 : epoch + 1;

/// How long a channel a gate forwards late requests on stays open without
/// a request in flight before it is closed (it is opened again for the
/// next one).
const Duration _forwardIdle = Duration(seconds: 1);

/// What a sharded service does with its slots: the application side of a
/// [SlotGate]. Extend this class (the gate attaches itself to it, see
/// [gate]); do not implement it.
///
/// The gate calls [load] when a slot is assigned to this instance, [drain]
/// when it moves away, [unload] when this instance no longer serves it,
/// and [serve] for every channel addressed to a slot it serves. See the
/// wiki page "Switchboard Sharding", sections "Requests from the naming
/// service to instances" and "The hand-over, step by step".
abstract class SlotLifecycle {
  SlotGate? _gate;

  /// The gate this lifecycle is attached to. Throws [StateError] before
  /// the gate is created.
  SlotGate get gate {
    final gate = _gate;
    if (gate == null) {
      throw StateError('$runtimeType is not attached to a slot gate');
    }
    return gate;
  }

  /// Loads or initialises [slot] and completes once it can be served.
  ///
  /// [holder] says where the slot's state is: 0 nowhere (start fresh),
  /// this instance (reclaim local storage), another instance (fetch it
  /// from there, for example over a channel to that instance without a
  /// shard slot, which its gate hands to `noSlotHandler`; or, when
  /// [shared] is set, load it from shared storage). Return
  /// [AssignResult.holding] when this instance now holds the slot's
  /// storage, [AssignResult.notHolding] when it does not (a stateless
  /// service, or state kept in shared storage only).
  ///
  /// Throw `SwitchboardException.of(StatusCode.unavailable)` when the slot
  /// cannot be served; it then stays free. Channels for the slot that
  /// arrive while this runs are queued and served once it completes.
  ///
  /// [context] is the `ASSIGN` request (null when the gate is driven
  /// without one). The naming service waits its `handoverTimeout` (60 s
  /// by default) for the answer; a load that may take longer declares how
  /// long with [SlotRequestContext.extend], at the steps where it knows
  /// (the transfer started, its size is known, a phase completed), and
  /// stops when [SlotRequestContext.onCancel] completes.
  Future<AssignResult> load(
    int slot, {
    required int epoch,
    required int holder,
    required bool shared,
    SlotRequestContext? context,
  });

  /// [slot] is moving to instance [to] and will have [epoch] there. The
  /// gate has locked it (new channels and gated requests are queued) and
  /// waited for the work in flight to end; make the state available to
  /// [to] (transfer it over a channel to [to], flush it to shared storage,
  /// or keep it for [to] to fetch) and close the long-lived channels that
  /// the slot's queued work must not overtake (with
  /// [SlotGate.relocatedStatus], since they were served). Throwing abandons
  /// the migration (the slot is resumed here). The default does nothing.
  ///
  /// When the wait for the work in flight timed out
  /// ([SlotGate.drainTimeout]), the gate has closed the slot's tracked
  /// channels with `RELOCATED` before this is called; [SlotGate.serveRequest]
  /// handlers still running cannot be stopped and may still act on the
  /// slot's state.
  ///
  /// [context] is the `DRAIN` request (null when the gate is driven without
  /// one). A drain that may take longer than the naming service waits
  /// declares how long with [SlotRequestContext.extend]: its
  /// `handoverTimeout` (60 s by default) when nothing was declared, or the
  /// [SlotGate.drainTimeout] the gate declared when it had to wait for work
  /// in flight.
  Future<void> drain(
    int slot, {
    required int epoch,
    required int to,
    SlotRequestContext? context,
  }) async {}

  /// This instance no longer serves [slot]: after the forwarding grace
  /// period of a migration, after the slot was revoked or released, or
  /// when the gate closes. Drop the slot's state unless this instance
  /// keeps its storage (it is still the holder). The default does
  /// nothing.
  Future<void> unload(int slot) async {}

  /// Serves [channel], addressed to [slot], which this instance serves.
  /// The handler owns the channel as a [ChannelHandler] does, and may be
  /// asynchronous: a throw, or a returned future that fails, closes it
  /// with `INTERNAL` (logged).
  ///
  /// Unless the gate was created with `trackChannels: false`, the channel
  /// counts as work in flight for [slot] until it ends (not until the
  /// returned future completes), so a migration waits for it
  /// ([SlotGate.drainTimeout]); call [SlotGate.detach] for a long-lived
  /// channel, and gate its requests with [SlotGate.serveRequest].
  FutureOr<void> serve(IncomingChannel channel, int slot);

  /// `HOLDING` reported [slots] as no longer held by this instance: their
  /// local storage should be discarded. Called for every `HOLDING`
  /// response, the one sent by `MeshNode.publishSharded` and those the
  /// naming client sends again after a reconnect
  /// ([SlotHandler.onDiscard]). May be asynchronous; a throw, or a
  /// returned future that fails, is logged. The default does nothing.
  FutureOr<void> discard(List<int> slots) {}
}

/// Where a [SlotGate] stands with one slot.
enum SlotGateState {
  /// `ASSIGN` arrived and [SlotLifecycle.load] runs; channels are queued.
  loading,

  /// Served here.
  serving,

  /// Locked by `DRAIN`, until `FORWARD` or `RESUME` (or an `ASSIGN`, see
  /// [SlotGate.onAssign]); channels are queued.
  locked,

  /// Handed over by `FORWARD`; channels and gated requests are forwarded
  /// to the new owner until the grace period ends.
  forwarding,
}

/// The instance side of sharding for one sharded type on a node: serves
/// the naming service's slot requests ([SlotHandler]) and gates the
/// channels addressed to the type's slots ([handler]).
///
/// Register [handler] for the instance the type was registered as
/// (`switchboard.registerService(type, gate.handler, instance: id)`), and
/// install the gate as the naming client's slot handler, through a
/// [SlotGates] when the client serves several sharded types.
/// `MeshNode.publishSharded` does all of it.
///
/// Channels are dispatched by their shard slot (wiki page "Switchboard
/// Sharding", sections "Requests from the naming service to instances" and
/// "Routing"):
///
/// * no shard slot: to [noSlotHandler] (state transfer between instances,
///   say), else rejected with `INVALID_ARGUMENT`; a slot outside the space
///   is rejected with `OUT_OF_RANGE`;
/// * a slot served here: to [SlotLifecycle.serve];
/// * a slot being loaded, or locked by `DRAIN`: queued, unread (the mux
///   buffers its subframes), at most [maxQueuedChannels] over all slots,
///   beyond which `UNAVAILABLE`; served here on `RESUME`, piped to the new
///   owner on `FORWARD`;
/// * a slot handed over by `FORWARD`, during [forwardGrace]: piped to the
///   new owner ([pipeChannels]) with the same open payload except the
///   instance, which is set to the new owner's so that its dispatch is
///   exact; the application payload (credential) is unchanged;
/// * any other slot: rejected with `MOVED` naming the owner from the
///   naming client's mirror ([movedStatus]).
///
/// Requests inside long-lived channels are gated with [serveRequest] the
/// same way, at the request level: served, queued, forwarded as message
/// chains ([forwardMessage]) over channels that carry the credential of the
/// channel each request arrived on, or answered `ABORT MOVED`.
///
/// `MOVED` always means that nothing was processed: the channel was
/// refused at open, or queued and never read, or the request was never
/// run, so the client may send it again to the new owner. A channel that
/// was served here (handed to [SlotLifecycle.serve]) and is ended because
/// the slot moved on is closed with `RELOCATED` carrying the same owner
/// and epoch fields ([relocatedStatus]): its work may have taken effect.
///
/// On `DRAIN` the gate locks the slot and waits until the slot's work in
/// flight has ended (its tracked channels have closed and its
/// [serveRequest] handlers have completed), at most [drainTimeout]; when
/// that wait times out, it closes the tracked channels still open with
/// `RELOCATED` naming the new owner and epoch (so that nothing more is
/// served on state that is being handed over) and logs a warning for the
/// [serveRequest] handlers still running, which cannot be stopped. Then
/// it calls [SlotLifecycle.drain]. On `FORWARD` it pipes the queued
/// channels to the new owner in arrival order, forwards the queued
/// requests, answers, and keeps forwarding for [forwardGrace], then calls
/// [SlotLifecycle.unload]. On `RESUME` it serves the queue itself, and so
/// on an `ASSIGN` of the locked slot when no other instance owned it since
/// (the `RESUME` was lost, see [onAssign]). On revocation (and [release],
/// [close]) it rejects the queue with `MOVED`, closes the slot's tracked
/// channels with `RELOCATED` ([relocatedStatus]) and calls
/// [SlotLifecycle.unload].
class SlotGate implements SlotHandler {
  /// Creates the gate of [type] on [switchboard], serving the slot
  /// requests [client] receives, with the application's [lifecycle] (which
  /// it attaches to; a lifecycle serves one gate at a time, and may be
  /// attached to a new gate once its gate is closed).
  ///
  /// [instance] is the id [type] is registered as (set it once known; it
  /// is used to tell this instance from others in the mirror).
  /// [trackChannels] makes every served channel count as work in flight
  /// until it ends (see [detach]). Throws [StateError] if [lifecycle] is
  /// attached to another gate that is not closed, [RangeError] for
  /// negative bounds.
  SlotGate(
    this.switchboard,
    this.client,
    this.type, {
    required this.lifecycle,
    this.forwardGrace = const Duration(seconds: 30),
    this.drainTimeout = const Duration(seconds: 30),
    this.maxQueuedChannels = 1024,
    this.maxQueuedRequests = 1024,
    this.trackChannels = true,
    this.noSlotHandler,
    this.instance = 0,
  }) {
    RangeError.checkNotNegative(maxQueuedChannels, 'maxQueuedChannels');
    RangeError.checkNotNegative(maxQueuedRequests, 'maxQueuedRequests');
    final attached = lifecycle._gate;
    if (attached != null && !attached._closed) {
      throw StateError('$lifecycle is attached to another slot gate');
    }
    lifecycle._gate = this;
  }

  /// The node channels are dispatched on and forwarded from.
  final Switchboard switchboard;

  /// The naming client whose slot requests this gate serves, and whose
  /// mirror names the owners in `MOVED` and `RELOCATED`.
  final NamingClient client;

  /// The sharded type.
  final Name type;

  /// The application side.
  final SlotLifecycle lifecycle;

  /// How long channels and gated requests keep being forwarded to the new
  /// owner after `FORWARD`. Default 30 s.
  final Duration forwardGrace;

  /// Longest wait for a locked slot's work in flight; then its tracked
  /// channels are closed with `RELOCATED` and [SlotLifecycle.drain] is
  /// called anyway. Default 30 s.
  final Duration drainTimeout;

  /// Most channels queued at a time, over all slots. Default 1024.
  final int maxQueuedChannels;

  /// Most requests queued by [serveRequest] at a time, over all slots; a
  /// queued request leaves the queue when it can no longer be answered.
  /// Default 1024.
  final int maxQueuedRequests;

  /// Whether served channels count as work in flight until they end.
  final bool trackChannels;

  /// Receives the channels that carry no shard slot; null rejects them
  /// with `INVALID_ARGUMENT`.
  ChannelHandler? noSlotHandler;

  /// The instance id of [type] on this node; 0 until known.
  int instance;

  final Map<int, _GateSlot> _slots = {};
  final Expando<_GateSlot> _servedBy = Expando<_GateSlot>('slot');

  /// The OPEN application payload of the channels requests arrived on.
  final Expando<Uint8List> _payloads = Expando<Uint8List>('payload');
  int _queuedChannels = 0;
  int _queuedRequests = 0;
  bool _closed = false;

  /// Dispatches channels addressed to [type]; register it with
  /// [Switchboard.registerService].
  ChannelHandler get handler => _onChannel;

  /// The slots this gate serves (loaded, serving or locked), with their
  /// epochs.
  Map<int, int> get servedSlots => Map.unmodifiable({
    for (final MapEntry(key: slot, value: s) in _slots.entries)
      if (s.state == SlotGateState.serving || s.state == SlotGateState.locked)
        slot: s.epoch,
  });

  /// Where the gate stands with [slot]; null when it has nothing to do
  /// with it.
  SlotGateState? stateOf(int slot) => _slots[slot]?.state;

  /// Whether [slot] is served here now (not loading, locked or handed
  /// over).
  bool serves(int slot) => _slots[slot]?.state == SlotGateState.serving;

  /// The owner and epoch of [slot] for `MOVED` and `RELOCATED` (wiki page
  /// "Switchboard Sharding", section "Routing"): the new owner while
  /// forwarding, else the owner in the naming client's mirror unless that
  /// is this instance, else unknown.
  MovedStatus movedTo(int slot) => _movedTo(slot, _slots[slot]);

  MovedStatus _movedTo(int slot, _GateSlot? s) {
    if (s != null && s.state == SlotGateState.forwarding) {
      return MovedStatus(owner: s.to, epoch: s.epoch);
    }
    final entry = client.slotOwner(type, slot);
    if (entry != null && entry.owner != instance) {
      return MovedStatus(owner: entry.owner, epoch: entry.epoch);
    }
    return MovedStatus.unknown;
  }

  /// The `MOVED` status for [slot], carrying [movedTo]: for channels and
  /// requests about [slot] that were not processed here, which the client
  /// may send again to the owner.
  Status movedStatus(int slot) => movedTo(slot).toStatus();

  /// The `RELOCATED` status for [slot], carrying [movedTo] like `MOVED`:
  /// for channels and requests about [slot] that were served here and are
  /// ended because the slot moved on, whose work may have taken effect.
  Status relocatedStatus(int slot) => movedTo(slot).toStatus(relocated: true);

  /// Stops counting [channel], served through [SlotLifecycle.serve], as
  /// work in flight of its slot: a long-lived channel whose requests the
  /// application gates with [serveRequest], or closes itself in
  /// [SlotLifecycle.drain]. Does nothing for other channels.
  void detach(IncomingChannel channel) {
    final s = _servedBy[channel];
    if (s != null && s.tracked.remove(channel)) {
      _checkIdle(s);
    }
  }

  // ---------------------------------------------------------------------
  // Channels

  FutureOr<void> _onChannel(IncomingChannel incoming) {
    final slot = incoming.address.shard;
    if (slot == null) {
      final other = noSlotHandler;
      if (other != null) {
        return other(incoming);
      }
      _log.fine('$type gate: $incoming has no shard slot');
      return incoming.reject(genericStatus(StatusCode.invalidArgument));
    }
    final count = client.slotTable(type)?.count;
    if (count != null && slot >= count) {
      _log.fine('$type gate: $incoming outside the $count slots');
      return incoming.reject(genericStatus(StatusCode.outOfRange));
    }
    final s = _slots[slot];
    switch (s?.state) {
      case null:
        return _rejectMoved(incoming, slot);
      case SlotGateState.loading || SlotGateState.locked:
        _queue(s!, incoming);
      case SlotGateState.serving:
        _serve(s!, incoming, slot);
      case SlotGateState.forwarding:
        _forwardChannelOf(s!, incoming);
    }
  }

  Future<void> _rejectMoved(IncomingChannel incoming, int slot) {
    final moved = movedTo(slot);
    _log.fine('$type gate: $incoming refused, moved: $moved');
    return incoming.reject(moved.toStatus());
  }

  void _queue(_GateSlot s, IncomingChannel incoming) {
    if (_queuedChannels >= maxQueuedChannels) {
      _log.info(
        '$type gate: $incoming refused, $maxQueuedChannels channels queued',
      );
      unawaited(incoming.reject(genericStatus(StatusCode.unavailable)));
      return;
    }
    _queuedChannels++;
    s.channels.add(incoming);
    // A queued channel its peer gives up on leaves the queue.
    unawaited(
      incoming.channel.done.then((_) {
        if (s.channels.remove(incoming)) {
          _queuedChannels--;
        }
      }),
    );
  }

  List<IncomingChannel> _takeQueue(_GateSlot s) {
    final queued = [
      for (final incoming in s.channels)
        if (incoming.channel.canSend) incoming,
    ];
    _queuedChannels -= s.channels.length;
    s.channels.clear();
    return queued;
  }

  void _serve(_GateSlot s, IncomingChannel incoming, int slot) {
    _servedBy[incoming] = s;
    if (trackChannels) {
      s.tracked.add(incoming);
      unawaited(
        incoming.channel.done.then((_) {
          if (s.tracked.remove(incoming)) {
            _checkIdle(s);
          }
        }),
      );
    }
    final FutureOr<void> served;
    try {
      served = lifecycle.serve(incoming, slot);
    } on Object catch (e, st) {
      _serveFailed(incoming, e, st);
      return;
    }
    if (served is Future<void>) {
      unawaited(
        served.then<void>(
          (_) {},
          onError: (Object e, StackTrace st) => _serveFailed(incoming, e, st),
        ),
      );
    }
  }

  void _serveFailed(IncomingChannel incoming, Object error, StackTrace st) {
    _log.severe('$type gate: serving $incoming failed', error, st);
    unawaited(
      incoming.reject(Status.of(StatusCode.internal, 'handler failed')),
    );
  }

  /// Pipes [incoming] to the new owner of [s] with its open payload, the
  /// instance set to the new owner's. The outgoing channels are opened one
  /// after the other, so the new owner sees them in arrival order.
  void _forwardChannelOf(_GateSlot s, IncomingChannel incoming) {
    final to = s.to;
    s.opening = s.opening.then((_) async {
      final MuxChannel target;
      try {
        target = await _open(
          to,
          incoming.address.copyWith(instance: to, clearHost: true),
        );
      } on Object catch (e) {
        _log.info('$type gate: cannot forward $incoming to $to: $e');
        unawaited(incoming.reject(genericStatus(StatusCode.unavailable)));
        return;
      }
      _log.fine('$type gate: $incoming forwarded to $type/$to');
      unawaited(pipeChannels(incoming.channel, target));
    });
  }

  /// Opens a channel to instance [to] of [type] with [header], never to
  /// this node's own listeners (a record of [to] that points back here
  /// would dispatch the channel into this gate again).
  Future<MuxChannel> _open(int to, ChannelAddress header) async {
    final bytes = header.encode();
    for (var attempt = 0; ; attempt++) {
      final (_, connection) = await switchboard.selectAndConnect(
        ServiceAddress(type, to),
        excludeOwnEndpoints: true,
      );
      try {
        return connection.open(bytes);
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

  // ---------------------------------------------------------------------
  // Requests

  /// Gates [message], a request (or plain message) about [slot] received
  /// on a long-lived channel, by the state of [slot]:
  ///
  /// * served here: runs [handler], counting it as work in flight of the
  ///   slot until its future completes (a throw is logged and answered
  ///   `ABORT INTERNAL` if still unanswered);
  /// * being loaded, or locked by `DRAIN`: queued (at most
  ///   [maxQueuedRequests] over all slots, beyond which `ABORT
  ///   UNAVAILABLE`); run here on `RESUME`, forwarded on `FORWARD`;
  /// * handed over, during [forwardGrace]: forwarded to the new owner as a
  ///   message chain ([forwardMessage]) over a channel this gate opens to
  ///   `(type, new owner)` with the slot and [payload] as the application
  ///   payload, so that the new owner sees the caller's credential and
  ///   serves the request as it would on any channel to the slot. The
  ///   requests for the slot with the same [payload] share that channel,
  ///   which is closed after a second without a request in flight and
  ///   opened again for the next one;
  /// * a slot outside the space: answered `ABORT OUT_OF_RANGE`;
  /// * otherwise: answered `ABORT MOVED` ([movedStatus]).
  ///
  /// [payload] defaults to the application payload of the OPEN of the
  /// channel [message] arrived on ([ChannelAddress.payload]): the
  /// credential its peer presented, passed on unchanged (an empty one stays
  /// empty, the node's [Switchboard.defaultPayload] is never used). For a
  /// channel this node opened, that is the payload this node sent; for a
  /// [TalkChannel] that is not over a mux channel, it is empty. Pass
  /// [payload] when the request's caller is not that channel's peer: an
  /// application that relays requests it received elsewhere, or one whose
  /// callers authenticate inside the channel.
  ///
  /// The future completes once the request has been handled, forwarded or
  /// refused; it never completes with an error. A queued request that can
  /// no longer be answered (cancelled, or its channel closed) leaves the
  /// queue and is dropped.
  Future<void> serveRequest(
    TalkMessage message,
    int slot,
    FutureOr<void> Function(TalkMessage message) handler, {
    Uint8List? payload,
  }) async {
    final s = _slots[slot];
    switch (s?.state) {
      case null:
        final count = client.slotTable(type)?.count;
        if (count != null && slot >= count) {
          _log.fine('$type gate: request for slot $slot outside $count');
          _abort(message, genericStatus(StatusCode.outOfRange));
          return;
        }
        _abort(message, movedStatus(slot));
      case SlotGateState.loading || SlotGateState.locked:
        if (_queuedRequests >= maxQueuedRequests) {
          _log.info('$type gate: request refused, $maxQueuedRequests queued');
          _abort(message, genericStatus(StatusCode.unavailable));
          return;
        }
        final parked = _Parked(message, handler, payload);
        _queuedRequests++;
        s!.requests.add(parked);
        // A request that can no longer be answered leaves the queue.
        final gone = message.expectsReply
            ? message.onCancel
            : message.channel.done.then<void>((_) {});
        unawaited(
          gone.then((_) {
            if (s.requests.remove(parked)) {
              _queuedRequests--;
              parked.finish();
            }
          }),
        );
        await parked.done.future;
      case SlotGateState.serving:
        await _run(s!, message, handler);
      case SlotGateState.forwarding:
        await _forwardRequest(s!, slot, message, payload);
    }
  }

  Future<void> _run(
    _GateSlot s,
    TalkMessage message,
    FutureOr<void> Function(TalkMessage message) handler,
  ) async {
    s.work++;
    try {
      await handler(message);
    } on Object catch (e, st) {
      _log.severe('$type gate: request handler failed', e, st);
      _abort(message, Status.of(StatusCode.internal, 'handler failed'));
    } finally {
      s.work--;
      _checkIdle(s);
    }
  }

  /// Forwards [message] to the new owner of [s] over the forwarding
  /// channel of [payload], by default the payload of the channel [message]
  /// arrived on.
  Future<void> _forwardRequest(
    _GateSlot s,
    int slot,
    TalkMessage message,
    Uint8List? payload,
  ) async {
    if (message.expectsReply && !message.canReply) {
      return;
    }
    final credential = payload ?? _arrivalPayload(message);
    // One forwarding channel per distinct credential: the bytes as the key.
    final key = String.fromCharCodes(credential);
    final f = s.forwards[key] ??= _Forward(key, Uint8List.fromList(credential));
    f.idle?.cancel();
    f.idle = null;
    f.pending++;
    final TalkChannel target;
    try {
      target = await _forwardChannel(s, slot, f);
    } on Object catch (e) {
      _log.info('$type gate: cannot forward a request for $slot: $e');
      _abort(message, genericStatus(StatusCode.unavailable));
      _relayEnded(s, f);
      return;
    }
    try {
      await forwardMessage(message, target);
    } on Object catch (e, st) {
      // The application forwarded it already: nothing more to do.
      _log.severe('$type gate: forwarding a request for $slot failed', e, st);
    } finally {
      _relayEnded(s, f);
    }
  }

  /// The application payload of the OPEN of the channel [message] arrived
  /// on, decoded once per channel; empty when that is not a mux channel.
  Uint8List _arrivalPayload(TalkMessage message) =>
      _payloads[message.channel] ??= _openPayloadOf(message.channel.raw);

  static Uint8List _openPayloadOf(Object raw) {
    final MuxChannel mux;
    switch (raw) {
      case MuxChannel():
        mux = raw;
      case SlotChannel():
        mux = raw.channel;
      default:
        return Uint8List(0);
    }
    try {
      return Uint8List.fromList(ChannelAddress.decode(mux.openPayload).payload);
    } on ProtocolException {
      // Not a Switchboard address (a raw mux channel): no credential.
      return Uint8List(0);
    }
  }

  /// A forwarded request through [f] ended: once none is in flight for
  /// [_forwardIdle], the channel is closed (the next request opens
  /// another). Once [s] was retired, it is closed with its last request.
  void _relayEnded(_GateSlot s, _Forward f) {
    if (--f.pending > 0) {
      return;
    }
    if (!identical(s.forwards[f.key], f)) {
      _closeForward(f);
      return;
    }
    f.idle?.cancel();
    f.idle = Timer(_forwardIdle, () {
      f.idle = null;
      if (f.pending > 0 || !identical(s.forwards[f.key], f)) {
        return;
      }
      s.forwards.remove(f.key);
      _log.fine('$type gate: forwarding channel idle, closed');
      _closeForward(f);
    });
  }

  static void _closeForward(_Forward f) {
    final channel = f.channel;
    f.channel = null;
    if (channel != null) {
      unawaited(
        channel.then((channel) => channel.close()).catchError((Object _) {}),
      );
    }
  }

  /// The channel of [f], opened on first use and again after it closed.
  Future<TalkChannel> _forwardChannel(_GateSlot s, int slot, _Forward f) {
    final current = f.channel;
    if (current == null) {
      return _openForward(s, slot, f);
    }
    // Requests that find it closed together open one replacement.
    Future<TalkChannel> again() => identical(f.channel, current)
        ? _openForward(s, slot, f)
        : _forwardChannel(s, slot, f);
    return current.then(
      (channel) => channel.isOpen ? channel : again(),
      // A failed open is retried by the next request.
      onError: (Object _) => again(),
    );
  }

  /// Opens the channel of [f] to the new owner of [s], addressed to [slot]
  /// with [f]'s credential as the application payload.
  Future<TalkChannel> _openForward(_GateSlot s, int slot, _Forward f) {
    final opening = _open(
      s.to,
      ChannelAddress(
        type: type,
        instance: s.to,
        shard: slot,
        payload: f.payload,
      ),
    ).then((channel) => TalkChannel(channel, options: switchboard.talkOptions));
    f.channel = opening;
    opening.ignore();
    return opening;
  }

  static void _abort(TalkMessage message, Status status) {
    if (!message.canReply) {
      return;
    }
    try {
      message.replyAbort(status);
    } on SwitchboardException catch (e) {
      _log.fine('abort not sent: ${e.status}');
    }
  }

  // ---------------------------------------------------------------------
  // Work in flight

  void _checkIdle(_GateSlot s) {
    final idle = s.idle;
    if (idle != null && s.isIdle && !idle.isCompleted) {
      idle.complete();
    }
  }

  /// Waits until [s] has no work in flight, at most [drainTimeout], which
  /// it declares to the naming service through [context] when it has to
  /// wait. Returns false when the wait timed out.
  Future<bool> _waitIdle(
    _GateSlot s,
    int slot,
    SlotRequestContext? context,
  ) async {
    if (s.isIdle) {
      return true;
    }
    context?.extend(deadline: drainTimeout);
    final idle = s.idle = Completer<void>();
    try {
      await idle.future.timeout(drainTimeout);
      return true;
    } on TimeoutException {
      _log.warning(
        '$type gate: slot $slot still has ${s.tracked.length} channels and '
        '${s.work} requests in flight after $drainTimeout; draining anyway',
      );
      return false;
    } finally {
      s.idle = null;
    }
  }

  // ---------------------------------------------------------------------
  // SlotHandler

  /// `ASSIGN`: loads the slot with [SlotLifecycle.load] (queueing its
  /// channels meanwhile), then serves it and its queue. For a slot already
  /// served (a claim confirmed after a naming service restart) only the
  /// epoch changes.
  ///
  /// A slot still locked whose `RESUME` was lost (the naming service set
  /// it free after its retries, then assigned it back here) is unlocked
  /// as on `RESUME`, with the new epoch, when no other instance owned it
  /// in between: the epoch is the next one after the epoch it was locked
  /// with, since only an assignment increments it. Its queue is served
  /// here and the answer is that of its load.
  ///
  /// A slot that another instance owned since (a locked slot with a later
  /// epoch, or a slot still being forwarded after a migration, which
  /// comes back) has stale state here: its queue is refused with `MOVED`,
  /// forwarding stops, [SlotLifecycle.unload] runs, then
  /// [SlotLifecycle.load], which receives [context]. Refused with
  /// `UNAVAILABLE` after [close].
  @override
  Future<AssignResult> onAssign(
    AssignRequest request, [
    SlotRequestContext? context,
  ]) async {
    _checkType(request.type);
    final slot = request.slot;
    if (_closed) {
      throw SwitchboardException.of(
        StatusCode.unavailable,
        '$type gate closed',
      );
    }
    final existing = _slots[slot];
    switch (existing?.state) {
      case SlotGateState.serving:
        existing!.epoch = request.epoch;
        return existing.result;
      case SlotGateState.locked
          when request.epoch == _nextEpoch(existing!.epoch):
        _log.info(
          '$type gate: slot $slot assigned back while locked (RESUME lost), '
          'serving it again, epoch ${request.epoch}',
        );
        _unlock(existing, slot, request.epoch);
        return existing.result;
      case SlotGateState.loading:
        throw SwitchboardException.of(
          StatusCode.unavailable,
          'slot $type/$slot is already being loaded',
        );
      case SlotGateState.locked || SlotGateState.forwarding || null:
        break;
    }
    final s = _GateSlot(request.epoch);
    _slots[slot] = s;
    if (existing != null) {
      // Owned by another instance since it was locked or handed over: its
      // state is stale, its queue (never read) refused with MOVED.
      await _retire(existing, slot);
    }
    final AssignResult result;
    try {
      result = await lifecycle.load(
        slot,
        epoch: request.epoch,
        holder: request.holder,
        shared: request.shared,
        context: context,
      );
    } catch (e) {
      if (identical(_slots[slot], s)) {
        _slots.remove(slot);
        _refuseQueue(s, movedStatus(slot));
      }
      rethrow;
    }
    if (!identical(_slots[slot], s)) {
      // Stopped while loading (closed or revoked).
      await _unload(slot);
      throw SwitchboardException.of(
        StatusCode.unavailable,
        'slot $type/$slot stopped while loading',
      );
    }
    s
      ..loaded = true
      ..result = result
      ..state = SlotGateState.serving;
    _log.fine('$type gate: serving slot $slot, epoch ${request.epoch}');
    _release(s, slot);
    return result;
  }

  /// `DRAIN`: locks the slot, waits for its work in flight (at most
  /// [drainTimeout], declared to the naming service through [context] when
  /// there is work to wait for; after it the slot's tracked channels still
  /// open are closed with `RELOCATED` naming the new owner and epoch), then
  /// runs [SlotLifecycle.drain], which receives [context]. Fails with
  /// `FAILED_PRECONDITION` for a slot not served here, and for a new owner
  /// that is no instance (0) or this one, leaving the slot served.
  @override
  Future<void> onDrain(
    DrainRequest request, [
    SlotRequestContext? context,
  ]) async {
    _checkType(request.type);
    final slot = request.slot;
    final selfForward = _selfForward('DRAIN', slot, request.to);
    if (selfForward != null) {
      throw selfForward;
    }
    final s = _slots[slot];
    if (s == null ||
        (s.state != SlotGateState.serving && s.state != SlotGateState.locked)) {
      throw SwitchboardException.of(
        StatusCode.failedPrecondition,
        'slot $type/$slot is not served here',
      );
    }
    s
      ..state = SlotGateState.locked
      ..to = request.to;
    _log.fine('$type gate: slot $slot locked for ${request.to}');
    final idle = await _waitIdle(s, slot, context);
    if (!identical(_slots[slot], s) || s.state != SlotGateState.locked) {
      throw SwitchboardException.of(
        StatusCode.unavailable,
        'slot $type/$slot stopped while draining',
      );
    }
    if (!idle) {
      _relocateTracked(s, slot, to: request.to, epoch: request.epoch);
    }
    await lifecycle.drain(
      slot,
      epoch: request.epoch,
      to: request.to,
      context: context,
    );
  }

  /// The wait for the work in flight of [slot] timed out during `DRAIN`:
  /// the tracked channels still open are closed with `RELOCATED` naming
  /// [to] at [epoch], so that nothing more is served here on state that is
  /// being handed over. Running [serveRequest] handlers cannot be stopped;
  /// they are logged.
  void _relocateTracked(
    _GateSlot s,
    int slot, {
    required int to,
    required int epoch,
  }) {
    final relocated = MovedStatus(
      owner: to,
      epoch: epoch,
    ).toStatus(relocated: true);
    final channels = List.of(s.tracked);
    s.tracked.clear();
    if (channels.isNotEmpty) {
      _log.warning(
        '$type gate: slot $slot: ${channels.length} channels still open '
        'after $drainTimeout closed with RELOCATED',
      );
    }
    for (final incoming in channels) {
      unawaited(incoming.reject(relocated));
    }
    if (s.work > 0) {
      _log.warning(
        '$type gate: slot $slot: ${s.work} requests still running after '
        '$drainTimeout cannot be stopped; they may act on state being '
        'handed over',
      );
    }
  }

  /// `FORWARD`: pipes the queued channels to the new owner in arrival
  /// order, forwards the queued requests, and keeps forwarding for
  /// [forwardGrace]; then [SlotLifecycle.unload].
  ///
  /// A new owner that is no instance (0) or this one fails with
  /// `FAILED_PRECONDITION`: forwarding there would bring the slot's
  /// channels back into this gate. The slot, which the naming client
  /// dropped on `FORWARD`, then stops being served here as on revocation:
  /// its queue is refused with `MOVED`, its tracked channels are closed
  /// with `RELOCATED`, and [SlotLifecycle.unload] runs (a slot already
  /// being forwarded goes on as it was).
  @override
  Future<void> onForward(
    ForwardRequest request, [
    SlotRequestContext? context,
  ]) async {
    _checkType(request.type);
    final slot = request.slot;
    final s = _slots[slot];
    final selfForward = _selfForward('FORWARD', slot, request.to);
    if (selfForward != null) {
      if (s != null && s.state != SlotGateState.forwarding) {
        await _stop(slot);
      }
      throw selfForward;
    }
    if (s == null) {
      return;
    }
    s
      ..state = SlotGateState.forwarding
      ..to = request.to
      ..epoch = request.epoch;
    final channels = _takeQueue(s);
    final requests = _takeRequests(s);
    _log.fine(
      '$type gate: slot $slot handed to ${request.to}, forwarding '
      '${channels.length} channels and ${requests.length} requests',
    );
    s.grace = Timer(forwardGrace, () => _graceOver(s, slot));
    for (final incoming in channels) {
      _forwardChannelOf(s, incoming);
    }
    for (final parked in requests) {
      unawaited(
        _forwardRequest(
          s,
          slot,
          parked.message,
          parked.payload,
        ).whenComplete(parked.finish),
      );
    }
    // Answered once the queued channels are handed over.
    await s.opening;
  }

  /// `RESUME`: unlocks the slot and serves its queue here. Does nothing
  /// for a slot that is not locked.
  @override
  Future<void> onResume(
    ResumeRequest request, [
    SlotRequestContext? context,
  ]) async {
    _checkType(request.type);
    final slot = request.slot;
    final s = _slots[slot];
    if (s == null || s.state != SlotGateState.locked) {
      return;
    }
    _log.fine('$type gate: slot $slot resumed');
    _unlock(s, slot, request.epoch);
  }

  /// Unlocks the locked slot [s] at [epoch] and serves its queue here.
  void _unlock(_GateSlot s, int slot, int epoch) {
    s
      ..state = SlotGateState.serving
      ..to = 0
      ..epoch = epoch;
    _release(s, slot);
  }

  /// The slot was revoked: stops serving it (see [release]).
  @override
  Future<void> onRevoke(Name type, int slot) async {
    _checkType(type);
    _log.info('$type gate: slot $slot revoked');
    await _stop(slot);
  }

  /// A `HOLDING` response listed [slots] as no longer held here: passes
  /// them to [SlotLifecycle.discard], whose failure is logged.
  @override
  void onDiscard(Name type, List<int> slots) {
    _checkType(type);
    _log.info('$type gate: discarding ${slots.length} slots');
    final FutureOr<void> discarded;
    try {
      discarded = lifecycle.discard(slots);
    } on Object catch (e, st) {
      _discardFailed(slots, e, st);
      return;
    }
    if (discarded is Future<void>) {
      unawaited(
        discarded.then<void>(
          (_) {},
          onError: (Object e, StackTrace st) => _discardFailed(slots, e, st),
        ),
      );
    }
  }

  void _discardFailed(List<int> slots, Object error, StackTrace st) {
    _log.warning('$type gate: discarding slots $slots failed', error, st);
  }

  /// The error for a [procedure] of [slot] whose new owner [to] is no
  /// instance or this one (logged), else null.
  SwitchboardException? _selfForward(String procedure, int slot, int to) {
    if (to != 0 && to != instance) {
      return null;
    }
    final owner = to == 0 ? 'no instance' : 'this instance';
    _log.warning('$type gate: $procedure of slot $slot to $owner refused');
    return SwitchboardException.of(
      StatusCode.failedPrecondition,
      '$procedure of $type/$slot names $owner as the new owner',
    );
  }

  void _checkType(Name requested) {
    if (requested != type) {
      throw SwitchboardException.of(
        StatusCode.unavailable,
        'slot request for $requested reached the gate of $type',
      );
    }
  }

  /// Serves what was queued while loading or locked.
  void _release(_GateSlot s, int slot) {
    for (final incoming in _takeQueue(s)) {
      _serve(s, incoming, slot);
    }
    for (final parked in _takeRequests(s)) {
      if (parked.message.expectsReply && !parked.message.canReply) {
        parked.finish();
        continue;
      }
      unawaited(
        _run(s, parked.message, parked.handler).whenComplete(parked.finish),
      );
    }
  }

  List<_Parked> _takeRequests(_GateSlot s) {
    final parked = List.of(s.requests);
    _queuedRequests -= parked.length;
    s.requests.clear();
    return parked;
  }

  /// Refuses the queue of [s], which is no longer served here, with
  /// [moved]: nothing in it was processed.
  void _refuseQueue(_GateSlot s, Status moved) {
    for (final incoming in _takeQueue(s)) {
      unawaited(incoming.reject(moved));
    }
    for (final parked in _takeRequests(s)) {
      _abort(parked.message, moved);
      parked.finish();
    }
  }

  void _graceOver(_GateSlot s, int slot) {
    if (!identical(_slots[slot], s)) {
      return;
    }
    _slots.remove(slot);
    _log.fine('$type gate: forwarding of slot $slot over');
    unawaited(_retire(s, slot));
  }

  /// Ends what is left of [s] after it stopped being served: refuses its
  /// queue with `MOVED`, closes its tracked channels, which were served,
  /// with `RELOCATED`, closes each forwarding channel once its requests
  /// are answered, and unloads the slot.
  Future<void> _retire(_GateSlot s, int slot) async {
    s.grace?.cancel();
    s.grace = null;
    final idle = s.idle;
    if (idle != null && !idle.isCompleted) {
      idle.complete();
    }
    // [s] is gone from the table, unless the slot came back (an ASSIGN
    // during the grace period): then the mirror tells.
    final moved = _movedTo(slot, _slots.containsKey(slot) ? null : s);
    _refuseQueue(s, moved.toStatus());
    final relocated = moved.toStatus(relocated: true);
    for (final incoming in List.of(s.tracked)) {
      unawaited(incoming.reject(relocated));
    }
    s.tracked.clear();
    // Out of the table, each closes with its last request (_relayEnded).
    final forwards = List.of(s.forwards.values);
    s.forwards.clear();
    for (final f in forwards) {
      f.idle?.cancel();
      f.idle = null;
      if (f.pending == 0) {
        _closeForward(f);
      }
    }
    if (s.loaded) {
      s.loaded = false;
      await _unload(slot);
    }
  }

  Future<void> _unload(int slot) async {
    try {
      await lifecycle.unload(slot);
    } on Object catch (e, st) {
      _log.warning('$type gate: unloading slot $slot failed', e, st);
    }
  }

  Future<void> _stop(int slot) async {
    final s = _slots.remove(slot);
    if (s != null) {
      await _retire(s, slot);
    }
  }

  // ---------------------------------------------------------------------
  // Claims and release

  /// Takes the free [slot] (`CLAIM`, see [NamingClient.claim]) and returns
  /// its epoch; the slot is loaded through `ASSIGN` before this completes.
  Future<int> claim(int slot, {bool holding = false}) =>
      client.claim(type, slot, holding: holding);

  /// Gives up [slot] (`RELEASE`, see [NamingClient.release]), then stops
  /// serving it here: its queue is refused with `MOVED`, its tracked
  /// channels are closed with `RELOCATED` ([relocatedStatus]), and
  /// [SlotLifecycle.unload] runs.
  Future<void> release(int slot, {bool keepStorage = false}) async {
    await client.release(type, slot, keepStorage: keepStorage);
    await _stop(slot);
  }

  /// Stops serving every slot here, as [release] does locally (the naming
  /// service is not told), and refuses later `ASSIGN`s. Channels arriving
  /// later are refused with `MOVED`, requests through [serveRequest]
  /// answered `ABORT MOVED`. The lifecycle may then be attached to a new
  /// gate (its [SlotLifecycle.gate] is this one until then).
  Future<void> close() async {
    _closed = true;
    await Future.wait([for (final slot in _slots.keys.toList()) _stop(slot)]);
  }

  @override
  String toString() => 'SlotGate($type/$instance, ${_slots.length} slots)';
}

/// The [SlotHandler] of a naming client that serves several sharded
/// types: dispatches each request to the [SlotGate] of its type.
///
/// `ASSIGN` for a type without a gate is refused with `UNAVAILABLE` (the
/// slot stays free), `DRAIN` with `FAILED_PRECONDITION`; `FORWARD`,
/// `RESUME`, revocations and discards of such a type are ignored.
class SlotGates extends SlotHandler {
  final Map<Name, SlotGate> _gates = {};

  /// The gates by type, read-only.
  late final Map<Name, SlotGate> gates = UnmodifiableMapView(_gates);

  /// The gate of [type], or null.
  SlotGate? operator [](Name type) => _gates[type];

  /// Adds [gate]. Throws [StateError] if its type already has one.
  void add(SlotGate gate) {
    if (_gates.containsKey(gate.type)) {
      throw StateError('${gate.type} already has a slot gate');
    }
    _gates[gate.type] = gate;
  }

  /// Removes the gate of [type] and returns it.
  SlotGate? remove(Name type) => _gates.remove(type);

  @override
  Future<AssignResult> onAssign(
    AssignRequest request, [
    SlotRequestContext? context,
  ]) {
    final gate = _gates[request.type];
    if (gate == null) {
      return Future.error(
        SwitchboardException.of(
          StatusCode.unavailable,
          'no slot gate for ${request.type}',
        ),
      );
    }
    return gate.onAssign(request, context);
  }

  @override
  Future<void> onDrain(DrainRequest request, [SlotRequestContext? context]) {
    final gate = _gates[request.type];
    if (gate == null) {
      return Future.error(
        SwitchboardException.of(
          StatusCode.failedPrecondition,
          'no slot gate for ${request.type}',
        ),
      );
    }
    return gate.onDrain(request, context);
  }

  @override
  Future<void> onForward(
    ForwardRequest request, [
    SlotRequestContext? context,
  ]) async => _gates[request.type]?.onForward(request, context);

  @override
  Future<void> onResume(
    ResumeRequest request, [
    SlotRequestContext? context,
  ]) async => _gates[request.type]?.onResume(request, context);

  @override
  Future<void> onRevoke(Name type, int slot) async =>
      _gates[type]?.onRevoke(type, slot);

  @override
  void onDiscard(Name type, List<int> slots) =>
      _gates[type]?.onDiscard(type, slots);
}

/// A gate's state of one slot.
class _GateSlot {
  _GateSlot(this.epoch);

  SlotGateState state = SlotGateState.loading;
  int epoch;
  AssignResult result = AssignResult.holding;

  /// [SlotLifecycle.load] completed and [SlotLifecycle.unload] has not run.
  bool loaded = false;

  /// The new owner while locked (as announced by `DRAIN`) or forwarding.
  int to = 0;

  final Queue<IncomingChannel> channels = Queue<IncomingChannel>();
  final Queue<_Parked> requests = Queue<_Parked>();

  /// Served channels counted as work in flight.
  final Set<IncomingChannel> tracked = {};

  /// [SlotGate.serveRequest] handlers running.
  int work = 0;

  /// Completed when nothing is in flight, while `DRAIN` waits for it.
  Completer<void>? idle;

  Timer? grace;

  /// The last forwarded channel's open, which the next one waits for.
  Future<void> opening = Future<void>.value();

  /// The channels requests are forwarded on, by credential
  /// ([_Forward.key]).
  final Map<String, _Forward> forwards = {};

  bool get isIdle => tracked.isEmpty && work == 0;
}

/// A channel a gate forwards the requests for one slot that carry one
/// credential on, opened to the new owner with that credential.
class _Forward {
  _Forward(this.key, this.payload);

  /// [payload] as a string, one character per byte.
  final String key;

  /// The application payload of the channel's OPEN.
  final Uint8List payload;

  /// The channel, once its open has been started.
  Future<TalkChannel>? channel;

  /// Requests being forwarded, from before the channel is open until they
  /// end.
  int pending = 0;

  /// Closes [channel] once no request was in flight for a while.
  Timer? idle;
}

/// A request queued by [SlotGate.serveRequest].
class _Parked {
  _Parked(this.message, this.handler, this.payload);

  final TalkMessage message;
  final FutureOr<void> Function(TalkMessage message) handler;

  /// The credential to forward it with; null for its channel's.
  final Uint8List? payload;
  final Completer<void> done = Completer<void>();

  void finish() {
    if (!done.isCompleted) {
      done.complete();
    }
  }
}
