/*
Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Author: Jan Boon <jan.boon@kaetemi.be>
*/

import 'dart:async';
import 'dart:collection';
import 'dart:math';

import 'package:logging/logging.dart';

import '../address/service_address.dart';
import '../name.dart';
import '../naming/naming_client.dart';
import '../naming/naming_client_io.dart';
import '../naming/naming_protocol.dart';
import '../naming/naming_resolver.dart';
import '../status.dart';
import '../talk/talk_channel.dart';
import 'incoming_channel.dart';
import 'slot_gate.dart';
import 'switchboard.dart';

final Logger _log = Logger('Switchboard.Naming');

/// At most this many `RELEASE`s, and as many hand-over migrations,
/// [MeshNode.leave] keeps in flight: well under the request limit of the
/// naming channel (`TalkOptions.maxOutgoingRequests`, 1024 by default),
/// refilled as the answers arrive.
const int _leaveWindow = 64;

/// Wires a [Switchboard] into a mesh run by a naming service: the usual
/// setup of a backend service node.
///
/// [MeshNode.join] creates a [NamingClient] that reaches the naming service
/// through the node, installs a [NamingResolver] over it as the node's
/// [Switchboard.resolver], and starts the client. [publish] registers a
/// local service with the naming service and dispatches channels for the
/// instance id it was assigned to the handler. [leave] undoes all of it.
///
/// ```dart
/// final node = Switchboard();
/// await node.listenTcp('10.0.0.5', 9101);
/// final mesh = MeshNode.join(node, Uri.parse('tcp://10.0.0.2:9100'));
/// final id = await mesh.publish(Name('npc'), npcHandler);
/// // ... node.openTalk(ServiceAddress(Name('chat'))) reaches the mesh.
/// await mesh.leave();
/// await node.close();
/// ```
///
/// A sharded type is published with [publishSharded], which also defines
/// its slot space and installs a [SlotGate]; [claimSlot], [releaseSlot],
/// [migrateSlot] and [slotOwners] work on its slots. See the wiki page
/// "Switchboard Sharding".
class MeshNode {
  MeshNode._(this.switchboard, this.client, this.resolver, this.leaveTimeout);

  /// Joins the mesh whose naming service listens at [namingEndpoint].
  ///
  /// Creates the client with [namingClientFor] (passing [reconnectDelay]
  /// and [talkOptions]), sets `switchboard.resolver` to a
  /// [NamingResolver] with [resolveTimeout], replacing any resolver the
  /// node had, and starts the client. Returns at once; the client keeps
  /// connecting in the background until [leave], and [synced] completes
  /// once the table is mirrored. [leaveTimeout] bounds what [leave] waits
  /// for the naming service, once for the hand-overs and once for the
  /// releases.
  factory MeshNode.join(
    Switchboard switchboard,
    Uri namingEndpoint, {
    Duration reconnectDelay = const Duration(seconds: 1),
    Duration resolveTimeout = const Duration(seconds: 5),
    TalkOptions? talkOptions,
    Duration leaveTimeout = const Duration(seconds: 5),
  }) {
    final client = namingClientFor(
      switchboard,
      namingEndpoint,
      reconnectDelay: reconnectDelay,
      talkOptions: talkOptions,
    );
    final resolver = NamingResolver(client, resolveTimeout: resolveTimeout);
    switchboard.resolver = resolver;
    unawaited(client.start());
    return MeshNode._(switchboard, client, resolver, leaveTimeout);
  }

  /// The node this joined to the mesh.
  final Switchboard switchboard;

  /// The naming client: registrations and the mirrored table.
  final NamingClient client;

  /// The resolver installed on [switchboard].
  final NamingResolver resolver;

  /// Longest time [leave] spends handing this node's slots over to other
  /// instances, and then again releasing those it could not hand over.
  final Duration leaveTimeout;

  /// The slot gates of the types published with [publishSharded]; the
  /// [client]'s slot handler once one is published.
  final SlotGates gates = SlotGates();

  final Map<Name, SlotSpace> _spaces = {};

  final Map<ServiceAddress, ChannelHandler> _published = {};
  bool _leaving = false;
  Future<LeaveReport>? _leaveFuture;

  /// The client's [NamingClient.synced]: completes once the current
  /// session has mirrored the table.
  Future<void> get synced => client.synced;

  /// The addresses of the services published through this object and
  /// dispatched locally, with their current instance ids.
  Iterable<ServiceAddress> get published => List.unmodifiable(_published.keys);

  /// Registers a local service of [type] with the naming service and
  /// returns its instance id.
  ///
  /// [instance] 0 lets the naming service assign the id; a non-zero id is
  /// requested as is. [endpoints] (default: the node's
  /// [Switchboard.listeningEndpoints] at the time of the call, so listen
  /// first, on an address other nodes can reach) are what other nodes
  /// connect to. Once the id is known, [handler] is registered with
  /// [Switchboard.registerService] for exactly `(type, id)`, so channels
  /// addressed to this instance, and channels to any instance of [type]
  /// that reach this node, are dispatched to it. If a reconnect to the
  /// naming service has to assign a different id (the old one was taken),
  /// the local registration moves to the new id.
  ///
  /// Fails like [NamingClient.register], and with
  /// [StatusCode.failedPrecondition] after [leave].
  Future<int> publish(
    Name type,
    ChannelHandler handler, {
    int instance = 0,
    List<Uri>? endpoints,
  }) {
    if (_leaving) {
      return Future.error(
        SwitchboardException.of(StatusCode.failedPrecondition, 'left mesh'),
      );
    }
    return _publish(type, handler, instance, endpoints, null);
  }

  Future<int> _publish(
    Name type,
    ChannelHandler handler,
    int instance,
    List<Uri>? endpoints,
    void Function(int id)? onId,
  ) {
    ServiceAddress? current;
    return client.register(
      type,
      endpoints ?? switchboard.listeningEndpoints,
      instance: instance,
      onAssigned: (id) {
        if (_leaving) {
          return;
        }
        final previous = current;
        if (previous != null && _published.remove(previous) != null) {
          switchboard.unregisterService(type, instance: previous.instance);
        }
        final address = ServiceAddress(type, id);
        current = address;
        _published[address] = handler;
        switchboard.registerService(type, handler, instance: id);
        onId?.call(id);
      },
    );
  }

  /// Publishes a sharded service of [type]: creates its [SlotGate] with
  /// [lifecycle], registers the type like [publish] (with the gate's
  /// handler, under [instance], which stateful services set to a stable
  /// configured id so that holders survive a reboot), defines or confirms
  /// the slot space (`SLOTS` with [count], [mode], [lazy], [shared] and
  /// this instance's [capacity]; 0 takes no slots from the allocator) and,
  /// when [holding] lists slots whose storage this instance has, declares
  /// them (`HOLDING`); the slots it should discard reach
  /// [SlotLifecycle.discard] (through [SlotGate.onDiscard], as do those of
  /// the `HOLDING` the naming client sends again after a reconnect).
  /// Returns the gate once all of that is done; in a managed space slots
  /// may already be assigned by then.
  ///
  /// The node's [gates] become the naming client's slot handler. The
  /// remaining parameters configure the gate (see [SlotGate.new]).
  ///
  /// Fails with [StatusCode.failedPrecondition] if [type] is already
  /// published sharded here, if the client has a slot handler other than
  /// [gates], or after [leave]; otherwise like [NamingClient.register],
  /// [NamingClient.defineSlots] (for example
  /// [StatusCode.failedPrecondition] when the space is defined
  /// differently) and [NamingClient.declareHolding]. On failure the type is
  /// unregistered again.
  Future<SlotGate> publishSharded(
    Name type,
    SlotLifecycle lifecycle, {
    required int count,
    SlotMode mode = SlotMode.managed,
    bool lazy = false,
    bool shared = false,
    int capacity = 1,
    Iterable<int> holding = const [],
    int instance = 0,
    List<Uri>? endpoints,
    Duration forwardGrace = const Duration(seconds: 30),
    Duration drainTimeout = const Duration(seconds: 30),
    int maxQueuedChannels = 1024,
    int maxQueuedRequests = 1024,
    bool trackChannels = true,
    ChannelHandler? noSlotHandler,
  }) async {
    if (_leaving) {
      throw SwitchboardException.of(StatusCode.failedPrecondition, 'left mesh');
    }
    if (gates[type] != null) {
      throw SwitchboardException.of(
        StatusCode.failedPrecondition,
        '$type is already published sharded',
      );
    }
    final current = client.slotHandler;
    if (current != null && !identical(current, gates)) {
      throw SwitchboardException.of(
        StatusCode.failedPrecondition,
        'the naming client has another slot handler',
      );
    }
    client.slotHandler = gates;
    final gate = SlotGate(
      switchboard,
      client,
      type,
      lifecycle: lifecycle,
      forwardGrace: forwardGrace,
      drainTimeout: drainTimeout,
      maxQueuedChannels: maxQueuedChannels,
      maxQueuedRequests: maxQueuedRequests,
      trackChannels: trackChannels,
      noSlotHandler: noSlotHandler,
      instance: instance,
    );
    gates.add(gate);
    var id = 0;
    try {
      id = await _publish(
        type,
        gate.handler,
        instance,
        endpoints,
        (id) => gate.instance = id,
      );
      final space = SlotSpace(
        type,
        count: count,
        mode: mode,
        lazy: lazy,
        shared: shared,
      );
      // Start SLOTS and HOLDING back to back, so that the naming service
      // sees them in one burst and no round trip separates them.
      final defined = client.defineSlots(
        type,
        count: count,
        mode: mode,
        lazy: lazy,
        shared: shared,
        capacity: capacity,
      );
      final held = holding.toList();
      final declared = held.isNotEmpty
          ? client.declareHolding(type, held)
          : Future<List<int>>.value(const []);
      await defined;
      _spaces[type] = space;
      // The slots to discard reach lifecycle.discard through the gate.
      await declared;
      return gate;
    } catch (_) {
      gates.remove(type);
      _spaces.remove(type);
      if (id != 0 && !_leaving) {
        await unpublish(type, id).catchError((Object _) {});
      }
      await gate.close();
      rethrow;
    }
  }

  SlotGate _gateOf(Name type) {
    final gate = gates[type];
    if (gate == null) {
      throw SwitchboardException.of(
        StatusCode.failedPrecondition,
        '$type is not published sharded here',
      );
    }
    return gate;
  }

  /// Claims the free [slot] of [type], published with [publishSharded]
  /// ([SlotGate.claim]): the slot is loaded before this completes. Returns
  /// its epoch. Fails with [StatusCode.alreadyExists] if another instance
  /// owns it, [StatusCode.failedPrecondition] if [type] is not published
  /// sharded here, and like [NamingClient.claim].
  Future<int> claimSlot(Name type, int slot, {bool holding = false}) async =>
      _gateOf(type).claim(slot, holding: holding);

  /// Releases [slot] of [type] ([SlotGate.release]) and stops serving it
  /// here. Fails like [NamingClient.release], and with
  /// [StatusCode.failedPrecondition] if [type] is not published sharded
  /// here.
  Future<void> releaseSlot(
    Name type,
    int slot, {
    bool keepStorage = false,
  }) async => _gateOf(type).release(slot, keepStorage: keepStorage);

  /// Moves [slot] of [type] to instance [to] (0 lets the allocator choose)
  /// through the hand-over ([NamingClient.migrate]); any node may ask.
  /// The stream reports the phases and ends when the migration is done.
  Stream<PhaseItem> migrateSlot(Name type, int slot, {int to = 0}) =>
      client.migrate(type, slot, to: to);

  /// The distinct instances the slots of [type] are routed to, from the
  /// mirror ([NamingClient.slotOwners]): for example to reach every node
  /// that serves a slot of [type].
  Set<int> slotOwners(Name type) => client.slotOwners(type);

  /// Unregisters `type/instance`, published through this object, from the
  /// naming service, then stops dispatching it locally.
  ///
  /// Fails like [NamingClient.unregister] ([StatusCode.notFound] if it was
  /// not published here) and with [StatusCode.failedPrecondition] after
  /// [leave]. The local registration is removed even if the naming service
  /// refuses.
  Future<void> unpublish(Name type, int instance) async {
    if (_leaving) {
      throw SwitchboardException.of(StatusCode.failedPrecondition, 'left mesh');
    }
    try {
      await client.unregister(type, instance);
    } finally {
      if (_published.remove(ServiceAddress(type, instance)) != null) {
        switchboard.unregisterService(type, instance: instance);
      }
    }
  }

  /// Leaves the mesh: hands over or gives up the slots of the types
  /// published with [publishSharded], closes the resolver and with it the
  /// client (the naming service then drops every registration of this
  /// node and publishes `DOWN` for each), stops dispatching the published
  /// services locally, and removes the resolver from [switchboard] if it
  /// is still installed there. Channels already open are unaffected.
  ///
  /// The slots are handled while connected to the naming service, and
  /// while the gates (and their `noSlotHandler`, which serves state
  /// transfers) are still up:
  ///
  /// 1. For each managed type, `SLOTS` with capacity 0, so that the
  ///    allocator gives this node no slot back.
  /// 2. In a holder-only managed space, every served slot is handed over,
  ///    one after the other (types in parallel, at most 64 migrations at
  ///    a time), with a migration to an instance the
  ///    allocator chooses ([migrateSlot] with `to: 0`): the new owner
  ///    takes the drained state over (fetching it from this node) while
  ///    this node is still up, so no data stays behind on a node that is
  ///    about to stop. Steps 1 and 2 take at most [leaveTimeout] in all.
  /// 3. Every slot still served (not handed over in time, a space with no
  ///    other instance to take it, a static space, or a `shared` space,
  ///    whose state is in shared storage and is reassigned at once) is
  ///    released keeping its storage (`RELEASE`, [SlotGate.release]), at
  ///    most [leaveTimeout] more, 64 at a time. In a holder-only managed space the
  ///    allocator then assigns such a slot elsewhere, the new owner
  ///    fetching the state from this node only while it is reachable.
  ///
  /// Then every gate is closed ([SlotGate.close]). The returned
  /// [LeaveReport] tells which slots were handed over, released, or
  /// dropped (stopped here without the naming service taking them: not
  /// connected, or the release failed). A node that is going to come back
  /// with its storage (a reboot) should rather not leave, so that its
  /// holder-only slots wait for it.
  ///
  /// Call this before closing [switchboard]. Calling it again returns the
  /// same future.
  Future<LeaveReport> leave() => _leaveFuture ??= _leave();

  Future<LeaveReport> _leave() async {
    _leaving = true;
    final served = {
      for (final gate in gates.gates.values)
        gate.type: gate.servedSlots.keys.toSet(),
    };
    final handedOver = <Name, Set<int>>{};
    final released = <Name, Set<int>>{};
    if (client.isConnected && gates.gates.isNotEmpty) {
      final handOvers = Stopwatch()..start();
      var over = false;
      Duration left() => leaveTimeout - handOvers.elapsed;
      final window = _Window(_leaveWindow);
      await Future.wait([
        for (final gate in gates.gates.values)
          _handOver(gate, window, left, () => over, handedOver[gate.type] = {}),
      ]).timeout(
        leaveTimeout,
        onTimeout: () {
          _log.warning('leaving: slots not handed over within $leaveTimeout');
          return const [];
        },
      );
      over = true;
      if (client.isConnected) {
        var stop = false;
        await _releaseAll(released, () => stop).timeout(
          leaveTimeout,
          onTimeout: () =>
              _log.warning('leaving: slots not released within $leaveTimeout'),
        );
        stop = true;
      }
    }
    final report = LeaveReport._(
      handedOver: _sorted(handedOver),
      released: _sorted(released),
      dropped: _sorted({
        for (final MapEntry(key: type, value: slots) in served.entries)
          type: slots
              .difference(handedOver[type] ?? const {})
              .difference(released[type] ?? const {}),
      }),
    );
    if (report.dropped.isNotEmpty) {
      _log.warning('leaving: slots dropped: ${report.dropped}');
    }
    await Future.wait([for (final gate in gates.gates.values) gate.close()]);
    if (identical(switchboard.resolver, resolver)) {
      switchboard.resolver = null;
    }
    await resolver.close();
    for (final address in _published.keys) {
      switchboard.unregisterService(address.type, instance: address.instance);
    }
    _published.clear();
    return report;
  }

  static Map<Name, List<int>> _sorted(Map<Name, Set<int>> slots) =>
      Map.unmodifiable({
        for (final MapEntry(key: type, value: set) in slots.entries)
          if (set.isNotEmpty)
            type: List<int>.unmodifiable(set.toList()..sort()),
      });

  /// Takes this instance out of the allocator for [gate]'s type, then, in
  /// a holder-only managed space, hands every served slot over to another
  /// instance, one at a time and each in its turn of [window], while [left]
  /// has time and [over] is false. Adds the slots handed over to [done].
  Future<void> _handOver(
    SlotGate gate,
    _Window window,
    Duration Function() left,
    bool Function() over,
    Set<int> done,
  ) async {
    final type = gate.type;
    final space = _spaces[type];
    if (space == null || space.mode != SlotMode.managed) {
      return;
    }
    try {
      await client.defineSlots(
        type,
        count: space.count,
        mode: space.mode,
        lazy: space.lazy,
        shared: space.shared,
        capacity: 0,
      );
    } on Object catch (e) {
      _log.info('leaving: capacity of $type not withdrawn: $e');
    }
    if (space.shared) {
      // The state is in shared storage: a RELEASE is enough.
      return;
    }
    for (final slot in gate.servedSlots.keys.toList()..sort()) {
      await window.enter();
      try {
        final time = left();
        if (over() || time <= Duration.zero || !client.isConnected) {
          return;
        }
        if (!gate.serves(slot)) {
          continue;
        }
        await client.migrate(type, slot).drain<void>().timeout(time);
        done.add(slot);
      } on TimeoutException {
        _log.info('leaving: $type/$slot not handed over in time');
        return;
      } on Object catch (e) {
        _log.info('leaving: $type/$slot not handed over: $e');
      } finally {
        window.exit();
      }
    }
  }

  /// Releases the slots the gates still serve, keeping the storage, at
  /// most [_leaveWindow] at a time and until [stop]; adds those released
  /// to [released].
  Future<void> _releaseAll(
    Map<Name, Set<int>> released,
    bool Function() stop,
  ) async {
    final work = Queue<(SlotGate, int)>();
    for (final gate in gates.gates.values) {
      released[gate.type] = {};
      for (final slot in gate.servedSlots.keys.toList()..sort()) {
        work.add((gate, slot));
      }
    }
    Future<void> releasing() async {
      while (work.isNotEmpty && !stop()) {
        final (gate, slot) = work.removeFirst();
        try {
          await gate.release(slot, keepStorage: true);
          released[gate.type]!.add(slot);
        } on Object catch (e) {
          _log.info('leaving: ${gate.type}/$slot not released: $e');
        }
      }
    }

    await Future.wait([
      for (var i = min(_leaveWindow, work.length); i > 0; i--) releasing(),
    ]);
  }
}

/// Lets at most [size] operations in at a time; the others wait for their
/// turn, in order.
class _Window {
  _Window(this.size);

  final int size;
  int _inside = 0;
  final Queue<Completer<void>> _waiting = Queue();

  /// Completes when it is the caller's turn; [exit] ends it.
  Future<void> enter() {
    if (_inside < size) {
      _inside++;
      return Future.value();
    }
    final turn = Completer<void>();
    _waiting.add(turn);
    return turn.future;
  }

  void exit() {
    if (_waiting.isNotEmpty) {
      // The turn passes on.
      _waiting.removeFirst().complete();
    } else {
      _inside--;
    }
  }
}

/// What [MeshNode.leave] did with the slots the node served, by type.
class LeaveReport {
  const LeaveReport._({
    required this.handedOver,
    required this.released,
    required this.dropped,
  });

  /// Slots handed over to another instance through a migration while this
  /// node was still up: their state was drained here and taken over.
  final Map<Name, List<int>> handedOver;

  /// Slots released keeping their storage (`RELEASE`): not handed over in
  /// time, or in a space where no other instance could take them, a
  /// static space or a `shared` one. In a holder-only managed space their
  /// new owner fetches the state from this node only while it is still
  /// reachable.
  final Map<Name, List<int>> released;

  /// Slots stopped here without the naming service taking them: the node
  /// was not connected to it, or the release failed or timed out. The
  /// naming service frees them when this node's registration goes away.
  final Map<Name, List<int>> dropped;

  /// Whether every slot was handed over (nothing released or dropped).
  bool get isComplete => released.isEmpty && dropped.isEmpty;

  @override
  String toString() =>
      'LeaveReport(handed over $handedOver, released $released, '
      'dropped $dropped)';
}
