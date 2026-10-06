/*
Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Author: Jan Boon <jan.boon@kaetemi.be>
*/

import 'dart:async';
import 'dart:collection';

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
import 'switchboard.dart';

final Logger _log = Logger('Switchboard.Router');

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
  Future<AssignResult> load(
    int slot, {
    required int epoch,
    required int holder,
    required bool shared,
  });

  /// [slot] is moving to instance [to] and will have [epoch] there. The
  /// gate has locked it (new channels and gated requests are queued) and
  /// waited for the work in flight to end; make the state available to
  /// [to] (transfer it over a channel to [to], flush it to shared storage,
  /// or keep it for [to] to fetch) and close the long-lived channels that
  /// the slot's queued work must not overtake. Throwing abandons the
  /// migration (the slot is resumed here). The default does nothing.
  Future<void> drain(int slot, {required int epoch, required int to}) async {}

  /// This instance no longer serves [slot]: after the forwarding grace
  /// period of a migration, after the slot was revoked or released, or
  /// when the gate closes. Drop the slot's state unless this instance
  /// keeps its storage (it is still the holder). The default does
  /// nothing.
  Future<void> unload(int slot) async {}

  /// Serves [channel], addressed to [slot], which this instance serves.
  /// The handler owns the channel as a [ChannelHandler] does; a throw
  /// closes it with `INTERNAL`.
  ///
  /// Unless the gate was created with `trackChannels: false`, the channel
  /// counts as work in flight for [slot] until it ends, so a migration
  /// waits for it ([SlotGate.drainTimeout]); call [SlotGate.detach] for a
  /// long-lived channel, and gate its requests with
  /// [SlotGate.serveRequest].
  void serve(IncomingChannel channel, int slot);

  /// `HOLDING` reported [slots] as no longer held by this instance: their
  /// local storage should be discarded. Called by
  /// `MeshNode.publishSharded`. The default does nothing.
  void discard(List<int> slots) {}
}

/// Where a [SlotGate] stands with one slot.
enum SlotGateState {
  /// `ASSIGN` arrived and [SlotLifecycle.load] runs; channels are queued.
  loading,

  /// Served here.
  serving,

  /// Locked by `DRAIN`, until `FORWARD` or `RESUME`; channels are queued.
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
/// chains ([forwardMessage]) or answered `ABORT MOVED`.
///
/// On `DRAIN` the gate locks the slot, waits until the slot's work in
/// flight has ended (its tracked channels have closed and its
/// [serveRequest] handlers have completed), at most [drainTimeout] (then
/// it goes on and logs a warning), and calls [SlotLifecycle.drain]. On
/// `FORWARD` it pipes the queued channels to the new owner in arrival
/// order, forwards the queued requests, answers, and keeps forwarding for
/// [forwardGrace], then calls [SlotLifecycle.unload]. On `RESUME` it
/// serves the queue itself. On revocation (and [release], [close]) it
/// rejects the queue with `MOVED`, closes the slot's tracked channels
/// with `MOVED` and calls [SlotLifecycle.unload].
class SlotGate implements SlotHandler {
  /// Creates the gate of [type] on [switchboard], serving the slot
  /// requests [client] receives, with the application's [lifecycle] (which
  /// it attaches to; a lifecycle serves one gate).
  ///
  /// [instance] is the id [type] is registered as (set it once known; it
  /// is used to tell this instance from others in the mirror).
  /// [trackChannels] makes every served channel count as work in flight
  /// until it ends (see [detach]). Throws [StateError] if [lifecycle] is
  /// attached to another gate, [RangeError] for negative bounds.
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
    if (lifecycle._gate != null) {
      throw StateError('$lifecycle is attached to another slot gate');
    }
    lifecycle._gate = this;
  }

  /// The node channels are dispatched on and forwarded from.
  final Switchboard switchboard;

  /// The naming client whose slot requests this gate serves, and whose
  /// mirror names the owners in `MOVED`.
  final NamingClient client;

  /// The sharded type.
  final Name type;

  /// The application side.
  final SlotLifecycle lifecycle;

  /// How long channels and gated requests keep being forwarded to the new
  /// owner after `FORWARD`. Default 30 s.
  final Duration forwardGrace;

  /// Longest wait for a locked slot's work in flight before
  /// [SlotLifecycle.drain] is called anyway. Default 30 s.
  final Duration drainTimeout;

  /// Most channels queued at a time, over all slots. Default 1024.
  final int maxQueuedChannels;

  /// Most requests queued by [serveRequest] at a time, over all slots.
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

  /// The `MOVED` status for [slot], whose reason names the current owner
  /// (wiki page "Switchboard Sharding", section "Routing"): the new owner
  /// while forwarding, else the owner in the naming client's mirror unless
  /// that is this instance, else no owner (empty reason).
  Status movedStatus(int slot) {
    final s = _slots[slot];
    if (s != null && s.state == SlotGateState.forwarding) {
      return MovedStatus(ServiceAddress(type, s.to), s.epoch).toStatus();
    }
    final entry = client.slotOwner(type, slot);
    if (entry != null && entry.owner != instance) {
      return MovedStatus(
        ServiceAddress(type, entry.owner),
        entry.epoch,
      ).toStatus();
    }
    return const MovedStatus().toStatus();
  }

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
    final status = movedStatus(slot);
    _log.fine('$type gate: $incoming refused, $status');
    return incoming.reject(status);
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
    try {
      lifecycle.serve(incoming, slot);
    } on Object catch (e, st) {
      _log.severe('$type gate: serving $incoming failed', e, st);
      unawaited(
        incoming.reject(Status.of(StatusCode.internal, 'handler failed')),
      );
    }
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

  /// Opens a channel to instance [to] of [type] with [header].
  Future<MuxChannel> _open(int to, ChannelAddress header) async {
    final bytes = header.encode();
    for (var attempt = 0; ; attempt++) {
      final (_, connection) = await switchboard.selectAndConnect(
        ServiceAddress(type, to),
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
  ///   `(type, new owner)` with the slot and [Switchboard.defaultPayload];
  ///   the new owner's application serves it as any channel to the slot;
  /// * otherwise: answered `ABORT MOVED` ([movedStatus]).
  ///
  /// The future completes once the request has been handled, forwarded or
  /// refused; it never completes with an error. A queued request that can
  /// no longer be answered (its channel closed) is dropped.
  Future<void> serveRequest(
    TalkMessage message,
    int slot,
    FutureOr<void> Function(TalkMessage message) handler,
  ) async {
    final s = _slots[slot];
    switch (s?.state) {
      case null:
        _abort(message, movedStatus(slot));
      case SlotGateState.loading || SlotGateState.locked:
        if (_queuedRequests >= maxQueuedRequests) {
          _log.info('$type gate: request refused, $maxQueuedRequests queued');
          _abort(message, genericStatus(StatusCode.unavailable));
          return;
        }
        final parked = _Parked(message, handler);
        _queuedRequests++;
        s!.requests.add(parked);
        await parked.done.future;
      case SlotGateState.serving:
        await _run(s!, message, handler);
      case SlotGateState.forwarding:
        await _forwardRequest(s!, slot, message);
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

  Future<void> _forwardRequest(
    _GateSlot s,
    int slot,
    TalkMessage message,
  ) async {
    if (message.expectsReply && !message.canReply) {
      return;
    }
    final TalkChannel target;
    try {
      target = await _forwardChannel(s, slot);
    } on Object catch (e) {
      _log.info('$type gate: cannot forward a request for $slot: $e');
      _abort(message, genericStatus(StatusCode.unavailable));
      return;
    }
    final relay = forwardMessage(message, target);
    s.relays.add(relay);
    await relay;
    s.relays.remove(relay);
  }

  /// The channel requests for [slot] are forwarded on, opened on first
  /// use and again after it closed.
  Future<TalkChannel> _forwardChannel(_GateSlot s, int slot) {
    final current = s.forward;
    if (current != null) {
      return current.then(
        (channel) => channel.isOpen ? channel : _openForward(s, slot),
      );
    }
    return _openForward(s, slot);
  }

  Future<TalkChannel> _openForward(_GateSlot s, int slot) {
    final opening = _open(
      s.to,
      ChannelAddress(
        type: type,
        instance: s.to,
        shard: slot,
        payload: switchboard.defaultPayload,
      ),
    ).then((channel) => TalkChannel(channel, options: switchboard.talkOptions));
    s.forward = opening;
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

  Future<void> _waitIdle(_GateSlot s, int slot) async {
    if (s.isIdle) {
      return;
    }
    final idle = s.idle = Completer<void>();
    try {
      await idle.future.timeout(drainTimeout);
    } on TimeoutException {
      _log.warning(
        '$type gate: slot $slot still has ${s.tracked.length} channels and '
        '${s.work} requests in flight after $drainTimeout; draining anyway',
      );
    } finally {
      s.idle = null;
    }
  }

  // ---------------------------------------------------------------------
  // SlotHandler

  /// `ASSIGN`: loads the slot with [SlotLifecycle.load] (queueing its
  /// channels meanwhile), then serves it and its queue. For a slot already
  /// served (a claim confirmed after a naming service restart) only the
  /// epoch changes. A slot still being forwarded after a migration comes
  /// back: forwarding stops, [SlotLifecycle.unload] runs, then
  /// [SlotLifecycle.load]. Refused with `UNAVAILABLE` after [close].
  @override
  Future<AssignResult> onAssign(AssignRequest request) async {
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
      case SlotGateState.serving || SlotGateState.locked:
        existing!.epoch = request.epoch;
        return existing.result;
      case SlotGateState.loading:
        throw SwitchboardException.of(
          StatusCode.unavailable,
          'slot $type/$slot is already being loaded',
        );
      case SlotGateState.forwarding || null:
        break;
    }
    final s = _GateSlot(request.epoch);
    _slots[slot] = s;
    if (existing != null) {
      // Coming back during the grace period: its queue is empty, its
      // state stale.
      await _retire(existing, slot);
    }
    final AssignResult result;
    try {
      result = await lifecycle.load(
        slot,
        epoch: request.epoch,
        holder: request.holder,
        shared: request.shared,
      );
    } catch (e) {
      if (identical(_slots[slot], s)) {
        _slots.remove(slot);
        _refuseQueue(s, slot);
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
  /// [drainTimeout]), then runs [SlotLifecycle.drain]. Fails with
  /// `FAILED_PRECONDITION` for a slot not served here.
  @override
  Future<void> onDrain(DrainRequest request) async {
    _checkType(request.type);
    final slot = request.slot;
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
    await _waitIdle(s, slot);
    if (!identical(_slots[slot], s) || s.state != SlotGateState.locked) {
      throw SwitchboardException.of(
        StatusCode.unavailable,
        'slot $type/$slot stopped while draining',
      );
    }
    await lifecycle.drain(slot, epoch: request.epoch, to: request.to);
  }

  /// `FORWARD`: pipes the queued channels to the new owner in arrival
  /// order, forwards the queued requests, and keeps forwarding for
  /// [forwardGrace]; then [SlotLifecycle.unload].
  @override
  Future<void> onForward(ForwardRequest request) async {
    _checkType(request.type);
    final slot = request.slot;
    final s = _slots[slot];
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
        _forwardRequest(s, slot, parked.message).whenComplete(parked.finish),
      );
    }
    // Answered once the queued channels are handed over.
    await s.opening;
  }

  /// `RESUME`: unlocks the slot and serves its queue here. Does nothing
  /// for a slot that is not locked.
  @override
  Future<void> onResume(ResumeRequest request) async {
    _checkType(request.type);
    final slot = request.slot;
    final s = _slots[slot];
    if (s == null || s.state != SlotGateState.locked) {
      return;
    }
    s
      ..state = SlotGateState.serving
      ..to = 0
      ..epoch = request.epoch;
    _log.fine('$type gate: slot $slot resumed');
    _release(s, slot);
  }

  /// The slot was revoked: stops serving it (see [release]).
  @override
  Future<void> onRevoke(Name type, int slot) async {
    _checkType(type);
    _log.info('$type gate: slot $slot revoked');
    await _stop(slot);
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

  /// Refuses the queue of [s], which is no longer served here.
  void _refuseQueue(_GateSlot s, int slot) {
    final moved = movedStatus(slot);
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

  /// Ends what is left of [s] after it stopped being served: closes its
  /// tracked channels with `MOVED`, closes the forwarding channel once its
  /// requests are answered, and unloads the slot.
  Future<void> _retire(_GateSlot s, int slot) async {
    s.grace?.cancel();
    s.grace = null;
    final idle = s.idle;
    if (idle != null && !idle.isCompleted) {
      idle.complete();
    }
    _refuseQueue(s, slot);
    final moved = movedStatus(slot);
    for (final incoming in List.of(s.tracked)) {
      unawaited(incoming.reject(moved));
    }
    s.tracked.clear();
    final forward = s.forward;
    s.forward = null;
    if (forward != null) {
      unawaited(
        Future.wait(List.of(s.relays))
            .then((_) => forward)
            .then((channel) => channel.close())
            .catchError((Object _) {}),
      );
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
  /// channels are closed with `MOVED`, and [SlotLifecycle.unload] runs.
  Future<void> release(int slot, {bool keepStorage = false}) async {
    await client.release(type, slot, keepStorage: keepStorage);
    await _stop(slot);
  }

  /// Stops serving every slot here, as [release] does locally (the naming
  /// service is not told), and refuses later `ASSIGN`s. Channels arriving
  /// later are refused with `MOVED`.
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
/// `RESUME` and revocations of such a type are ignored.
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
  Future<AssignResult> onAssign(AssignRequest request) {
    final gate = _gates[request.type];
    if (gate == null) {
      return Future.error(
        SwitchboardException.of(
          StatusCode.unavailable,
          'no slot gate for ${request.type}',
        ),
      );
    }
    return gate.onAssign(request);
  }

  @override
  Future<void> onDrain(DrainRequest request) {
    final gate = _gates[request.type];
    if (gate == null) {
      return Future.error(
        SwitchboardException.of(
          StatusCode.failedPrecondition,
          'no slot gate for ${request.type}',
        ),
      );
    }
    return gate.onDrain(request);
  }

  @override
  Future<void> onForward(ForwardRequest request) async =>
      _gates[request.type]?.onForward(request);

  @override
  Future<void> onResume(ResumeRequest request) async =>
      _gates[request.type]?.onResume(request);

  @override
  Future<void> onRevoke(Name type, int slot) async =>
      _gates[type]?.onRevoke(type, slot);
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

  /// The channel requests are forwarded on.
  Future<TalkChannel>? forward;

  /// Forwarded requests not yet ended.
  final Set<Future<void>> relays = {};

  bool get isIdle => tracked.isEmpty && work == 0;
}

/// A request queued by [SlotGate.serveRequest].
class _Parked {
  _Parked(this.message, this.handler);

  final TalkMessage message;
  final FutureOr<void> Function(TalkMessage message) handler;
  final Completer<void> done = Completer<void>();

  void finish() {
    if (!done.isCompleted) {
      done.complete();
    }
  }
}
