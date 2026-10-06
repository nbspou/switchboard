/*
Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Author: Jan Boon <jan.boon@kaetemi.be>
*/

part of 'naming_client.dart';

/// What an instance answers to `ASSIGN`.
enum AssignResult {
  /// The instance now holds the slot's storage (the usual answer of a
  /// stateful service).
  holding,

  /// The instance does not hold the slot's storage; the previous holder is
  /// kept. A stateless service always answers this.
  notHolding,
}

/// Serves the requests the naming service sends to a sharded instance over
/// its registration channel. Set it with [NamingClient.slotHandler]. See
/// the wiki page "Switchboard Sharding", section "Requests from the naming
/// service to instances".
///
/// The client keeps each request alive with `EXTEND` while the handler
/// runs, answers it when the returned future completes, and answers
/// `ABORT` with the status of a thrown [SwitchboardException]
/// (`UNAVAILABLE` for any other error).
abstract class SlotHandler {
  /// Load or initialise the slot and complete once ready to serve it.
  ///
  /// [AssignRequest.holder] says where the state is: 0 nowhere (start
  /// fresh), this instance (reclaim local state), another instance (fetch
  /// it from there, or from shared storage when [AssignRequest.shared]).
  /// Throw `SwitchboardException.of(StatusCode.unavailable)` when the slot
  /// cannot be served; it then stays free.
  ///
  /// May arrive for a slot this instance already serves: after a naming
  /// service restart, the claim of a slot it was serving is confirmed with
  /// an `ASSIGN` carrying the new epoch.
  Future<AssignResult> onAssign(AssignRequest request);

  /// Lock the slot: queue new work for it, let work in flight complete, and
  /// make its state available to [DrainRequest.to] (transfer it or flush it
  /// to shared storage). Complete once nothing is in flight and the state
  /// is flushed. The slot stays locked until [onForward] or [onResume].
  Future<void> onDrain(DrainRequest request);

  /// The new owner serves: forward the queued work to [ForwardRequest.to]
  /// and keep forwarding late arrivals for a grace period, then answer
  /// `MOVED`. Complete once the queue has been handed over. The slot is no
  /// longer served by this instance.
  Future<void> onForward(ForwardRequest request);

  /// The migration was abandoned, or the naming service was lost while the
  /// slot was locked: unlock and serve the queued work. Must be idempotent:
  /// it may come for a slot that was never locked, after a `DRAIN` that
  /// failed.
  Future<void> onResume(ResumeRequest request);

  /// This instance must stop serving [slot] of [type]: its claim was
  /// refused after a reconnect (another instance owns it), or an `ASSIGN`
  /// it accepted could not be confirmed. The default does nothing.
  Future<void> onRevoke(Name type, int slot) async {}
}

/// At most this many `CLAIM`s of served slots are in flight per channel
/// after a reconnect, well below the default Talk request limits (1024).
const int _reclaimWindow = 256;

/// The slot state of a [NamingClient]: what it remembers to restore after
/// a reconnect, what it serves, and the mirrored slot tables.
class _ClientSlots {
  _ClientSlots(this.client);

  final NamingClient client;
  SlotHandler? handler;

  /// Remembered `SLOTS` per type, re-sent after every reconnect.
  final Map<Name, _SpaceDefinition> definitions = {};

  /// Remembered `HOLDING` per type, re-sent after every reconnect.
  final Map<Name, _Holdings> holdings = {};

  /// Slots this instance serves (confirmed `ASSIGN`), by type and slot.
  final Map<Name, Map<int, _Served>> served = {};

  /// Slots locked by `DRAIN`, until `FORWARD` or `RESUME`.
  final Map<(Name, int), _Draining> draining = {};

  final Map<Name, _Mirror> mirrors = {};
  final Map<Name, SlotTable> views = {};
  final StreamController<SlotEvent> events =
      StreamController<SlotEvent>.broadcast();

  static final Set<Name> procedures = {
    Procedures.assign,
    Procedures.drain,
    Procedures.forward,
    Procedures.resume,
  };

  // ---------------------------------------------------------------------
  // Requests from the naming service

  void serve(_Session session, TalkMessage message) {
    final handler = this.handler;
    if (handler == null) {
      _abort(
        message,
        Status.of(StatusCode.unimplemented, 'this instance does not shard'),
      );
      return;
    }
    // Loading or draining a slot may take long; the naming service's
    // requester timeout is kept from firing with EXTEND.
    message.setReplyTimeout(Duration.zero);
    final extend = Timer.periodic(client.slotExtendInterval, (timer) {
      if (!message.canReply) {
        timer.cancel();
        return;
      }
      try {
        message.extend();
      } on SwitchboardException {
        timer.cancel();
      }
    });
    unawaited(_serve(session, message, handler).whenComplete(extend.cancel));
  }

  Future<void> _serve(
    _Session session,
    TalkMessage message,
    SlotHandler handler,
  ) async {
    final procedure = message.procedure;
    try {
      if (procedure == Procedures.assign) {
        await _assign(session, message, handler);
      } else if (procedure == Procedures.drain) {
        await _drain(message, handler);
      } else if (procedure == Procedures.forward) {
        final request = ForwardRequest.decode(message.payload);
        draining.remove((request.type, request.slot));
        served[request.type]?.remove(request.slot);
        await handler.onForward(request);
        _reply(message);
      } else {
        final request = ResumeRequest.decode(message.payload);
        draining.remove((request.type, request.slot));
        await handler.onResume(request);
        _reply(message);
      }
    } on ProtocolException catch (e) {
      _abort(message, Status.of(StatusCode.invalidArgument, e.status.reason));
    } catch (e, st) {
      _log.warning('${message.procedureName} handler failed', e, st);
      _abort(message, _failure(e));
    }
  }

  Future<void> _assign(
    _Session session,
    TalkMessage message,
    SlotHandler handler,
  ) async {
    final request = AssignRequest.decode(message.payload);
    final type = request.type;
    final slot = request.slot;
    final result = await handler.onAssign(request);
    final bySlot = served.putIfAbsent(type, () => {});
    final before = bySlot[slot];
    // Recorded before the reply, so that the slot is served by the time
    // the naming service publishes the new owner.
    bySlot[slot] = _Served(
      request.epoch,
      holding: result == AssignResult.holding,
    );
    try {
      if (!message.canReply || !session.usable) {
        throw SwitchboardException.of(StatusCode.cancelled, 'not confirmed');
      }
      message.reply(
        AssignResponse(notHolding: result == AssignResult.notHolding).encode(),
      );
    } on SwitchboardException {
      if (before != null) {
        bySlot[slot] = before;
        return;
      }
      bySlot.remove(slot);
      _log.info('ASSIGN $type/$slot not confirmed, revoking it');
      revoke(type, slot);
    }
  }

  Future<void> _drain(TalkMessage message, SlotHandler handler) async {
    final request = DrainRequest.decode(message.payload);
    final key = (request.type, request.slot);
    final drained = Completer<void>();
    draining[key] = _Draining(
      served[request.type]?[request.slot]?.epoch ?? 0,
      drained.future,
    );
    try {
      await handler.onDrain(request);
    } finally {
      drained.complete();
    }
    _reply(message);
  }

  static Status _failure(Object error) {
    if (error is SwitchboardException && !error.status.isOk) {
      return error.status;
    }
    return Status.of(StatusCode.unavailable, '$error');
  }

  static void _reply(TalkMessage message) {
    try {
      message.reply(Uint8List(0));
    } on SwitchboardException catch (e) {
      _log.fine('${message.procedureName} not answered: $e');
    }
  }

  static void _abort(TalkMessage message, Status status) {
    try {
      message.replyAbort(status);
    } on SwitchboardException catch (e) {
      _log.fine('${message.procedureName} not aborted: $e');
    }
  }

  void revoke(Name type, int slot) {
    draining.remove((type, slot));
    final handler = this.handler;
    if (handler == null) {
      return;
    }
    unawaited(
      Future(() => handler.onRevoke(type, slot)).catchError(
        (Object e, StackTrace st) =>
            _log.warning('onRevoke $type/$slot failed', e, st),
      ),
    );
  }

  /// The channel to the naming service was lost: every locked slot is
  /// unlocked and served (as `RESUME`), once its `DRAIN` handler is done.
  void onLost() {
    final locked = Map.of(draining);
    draining.clear();
    final handler = this.handler;
    if (handler == null || client._closed) {
      return;
    }
    for (final MapEntry(key: (type, slot), value: lock) in locked.entries) {
      _log.info('naming service lost while $type/$slot was draining, resuming');
      unawaited(
        lock.drained
            .then(
              (_) => handler.onResume(
                ResumeRequest(type, slot, epoch: lock.epoch),
              ),
            )
            .catchError(
              (Object e, StackTrace st) =>
                  _log.warning('onResume $type/$slot failed', e, st),
            ),
      );
    }
  }

  // ---------------------------------------------------------------------
  // Restoring after a (re)connect

  /// Sends what is remembered for [type] on [session], once per session:
  /// `SLOTS`, then `HOLDING`, then a `CLAIM` of every slot this instance
  /// serves, pipelined. Waits for the registration of [type] on [session]
  /// if this client registers that type; without any registration of it
  /// (a router or an operator tool) only `SLOTS` is sent.
  ///
  /// The `HOLDING` also lists the served slots whose storage this instance
  /// holds. It is a single request, so it reaches a restarted naming
  /// service within its assignment hold even when the claims (sent a
  /// window at a time) do not; the service then gives those slots back to
  /// this instance as their holder instead of assigning them fresh.
  void restore(_Session session, Name type) {
    if (!session.usable) {
      return;
    }
    final registered = client._registeredOn(session, type);
    if (!registered && client._registers(type)) {
      return;
    }
    final previous = session.restored[type];
    if (previous != null && (previous || !registered)) {
      return;
    }
    session.restored[type] = registered;
    final definition = definitions[type];
    if (definition != null) {
      _sendSlots(session, definition);
    }
    if (!registered) {
      return;
    }
    final declared = holdings[type];
    final bySlot = served[type];
    final held = {
      ...?declared?.slots,
      for (final MapEntry(key: slot, value: state)
          in (bySlot ?? const <int, _Served>{}).entries)
        if (state.holding) slot,
    };
    final pending = List.of(declared?.pending ?? const <_PendingHolding>[]);
    declared?.pending.clear();
    if (held.isNotEmpty || pending.isNotEmpty) {
      _sendHolding(session, type, held.toList()..sort(), pending);
    }
    if (bySlot != null) {
      for (final MapEntry(key: slot, value: state) in bySlot.entries) {
        session.reclaims.add((type, slot, state));
      }
      _pumpReclaims(session);
    }
  }

  /// Sends queued claims of served slots, at most [_reclaimWindow] at a
  /// time. Claims beyond the window that reach a freshly restarted naming
  /// service after its assignment hold are served first come, first
  /// served rather than by epoch.
  void _pumpReclaims(_Session session) {
    while (session.reclaiming < _reclaimWindow &&
        session.reclaims.isNotEmpty &&
        session.usable) {
      final (type, slot, state) = session.reclaims.removeFirst();
      if (!identical(served[type]?[slot], state)) {
        continue;
      }
      session.reclaiming++;
      _reclaim(session, type, slot, state).whenComplete(() {
        session.reclaiming--;
        _pumpReclaims(session);
      });
    }
  }

  void restoreAll(_Session session) {
    for (final type in {
      ...definitions.keys,
      ...holdings.keys,
      ...served.keys,
    }) {
      restore(session, type);
    }
  }

  /// Whether requests about [type] can go out on [session] now.
  bool _ready(_Session session, Name type) =>
      session.usable &&
      (client._registeredOn(session, type) || !client._registers(type));

  void _sendSlots(_Session session, _SpaceDefinition definition) {
    final type = definition.request.space.type;
    final Future<TalkMessage> response;
    try {
      response = session.channel.request(
        Procedures.slots.toString(),
        definition.request.encode(),
      );
    } on SwitchboardException catch (e) {
      _log.fine('SLOTS $type not sent: $e');
      return;
    }
    response.then(
      (_) => definition.complete(),
      onError: (Object e, StackTrace st) {
        if (!session.usable) {
          // Sent again after the next connect.
          return;
        }
        _log.warning('SLOTS $type refused: $e');
        if (identical(definitions[type], definition)) {
          definitions.remove(type);
        }
        definition.fail(e, st);
      },
    );
  }

  void _sendHolding(
    _Session session,
    Name type,
    List<int> slots,
    List<_PendingHolding> pending,
  ) {
    final Future<TalkMessage> response;
    try {
      response = session.channel.request(
        Procedures.holding.toString(),
        HoldingRequest(type, slots).encode(),
      );
    } on SwitchboardException catch (e) {
      _log.fine('HOLDING $type not sent: $e');
      holdings[type]?.pending.addAll(pending);
      return;
    }
    response.then(
      (message) {
        final List<int> discard;
        try {
          discard = HoldingResponse.decode(message.payload).discard;
        } on ProtocolException catch (e, st) {
          for (final p in pending) {
            p.completer.completeError(e, st);
          }
          return;
        }
        final drop = discard.toSet();
        holdings[type]?.slots.removeAll(drop);
        for (final p in pending) {
          p.completer.complete(
            [
              for (final slot in p.slots)
                if (drop.contains(slot)) slot,
            ]..sort(),
          );
        }
      },
      onError: (Object e, StackTrace st) {
        if (!session.usable) {
          holdings[type]?.pending.addAll(pending);
          return;
        }
        _log.warning('HOLDING $type refused: $e');
        holdings[type]?.slots.removeAll(slots);
        for (final p in pending) {
          p.completer.completeError(e, st);
        }
      },
    );
  }

  Future<void> _reclaim(
    _Session session,
    Name type,
    int slot,
    _Served state,
  ) async {
    final Future<TalkMessage> response;
    try {
      response = session.channel.request(
        Procedures.claim.toString(),
        ClaimRequest(
          type,
          slot,
          holding: state.holding,
          epoch: state.epoch,
        ).encode(),
      );
    } on SwitchboardException catch (e) {
      _log.fine('CLAIM $type/$slot not sent: $e');
      return;
    }
    await response.then<void>(
      (message) {
        final current = served[type]?[slot];
        if (current != null) {
          try {
            current.epoch = ClaimResponse.decode(message.payload).epoch;
          } on ProtocolException catch (e) {
            _log.warning('malformed CLAIM response: $e');
          }
        }
      },
      onError: (Object e) {
        if (!session.usable) {
          return;
        }
        final bySlot = served[type];
        if (bySlot == null || !identical(bySlot[slot], state)) {
          return;
        }
        _log.warning('lost $type/$slot after reconnect: $e');
        bySlot.remove(slot);
        revoke(type, slot);
      },
    );
  }

  // ---------------------------------------------------------------------
  // Client API

  Future<void> defineSlots(SlotsRequest request) {
    final type = request.space.type;
    final definition = _SpaceDefinition(request);
    final previous = definitions[type];
    definitions[type] = definition;
    previous?.supersede(definition);
    final session = client._session;
    if (session != null && _ready(session, type)) {
      session.restored[type] ??= client._registeredOn(session, type);
      _sendSlots(session, definition);
    }
    return definition.completer.future;
  }

  Future<List<int>> declareHolding(Name type, List<int> slots) {
    final declared = holdings.putIfAbsent(type, _Holdings.new);
    declared.slots.addAll(slots);
    final pending = _PendingHolding(slots.toSet());
    final session = client._session;
    if (session != null &&
        session.usable &&
        client._registeredOn(session, type) &&
        session.restored[type] == true) {
      _sendHolding(session, type, slots, [pending]);
    } else {
      declared.pending.add(pending);
    }
    return pending.completer.future;
  }

  _Session usableSession() {
    final session = client._session;
    if (client._closed) {
      throw SwitchboardException.of(
        StatusCode.failedPrecondition,
        'naming client closed',
      );
    }
    if (session == null || !session.usable) {
      throw SwitchboardException.of(
        StatusCode.unavailable,
        'not connected to the naming service',
      );
    }
    return session;
  }

  Future<int> claim(Name type, int slot, {required bool holding}) async {
    final session = usableSession();
    final response = await session.channel.request(
      Procedures.claim.toString(),
      ClaimRequest(
        type,
        slot,
        holding: holding,
        epoch: served[type]?[slot]?.epoch ?? 0,
      ).encode(),
    );
    final epoch = ClaimResponse.decode(response.payload).epoch;
    served[type]?[slot]?.epoch = epoch;
    return epoch;
  }

  Future<void> release(Name type, int slot, {required bool keepStorage}) async {
    final session = usableSession();
    await session.channel.request(
      Procedures.release.toString(),
      ReleaseRequest(type, slot, keepStorage: keepStorage).encode(),
    );
    served[type]?.remove(slot);
    draining.remove((type, slot));
    if (keepStorage) {
      holdings.putIfAbsent(type, _Holdings.new).slots.add(slot);
    } else {
      holdings[type]?.slots.remove(slot);
    }
  }

  Future<LocateResponse> locate(Name type, int slot) async {
    final session = usableSession();
    final response = await session.channel.request(
      Procedures.locate.toString(),
      LocateRequest(type, slot).encode(),
    );
    return LocateResponse.decode(response.payload);
  }

  Stream<PhaseItem> migrate(Name type, int slot, int to) {
    final controller = StreamController<PhaseItem>();
    final TalkStream stream;
    try {
      stream = usableSession().channel.streamRequest(
        Procedures.migrate.toString(),
        MigrateRequest(type, slot, to: to).encode(),
      );
    } catch (e, st) {
      controller
        ..addError(e, st)
        ..close();
      return controller.stream;
    }
    late final StreamSubscription<TalkMessage> items;
    controller
      ..onListen = () {
        items = stream.items.listen(
          (item) {
            try {
              controller.add(PhaseItem.decode(item.payload));
            } on ProtocolException catch (e, st) {
              controller.addError(e, st);
            }
          },
          onError: controller.addError,
          onDone: controller.close,
        );
      }
      ..onPause = (() => items.pause())
      ..onResume = (() => items.resume())
      ..onCancel = () {
        stream.cancel();
        return items.cancel();
      };
    return controller.stream;
  }

  Map<int, int> servedSlots(Name type) => Map.unmodifiable({
    for (final MapEntry(key: slot, value: state)
        in (served[type] ?? const <int, _Served>{}).entries)
      slot: state.epoch,
  });

  // ---------------------------------------------------------------------
  // Mirror

  void onSpaceItem(_Session session, SlotSpace space) {
    if (session.syncing) {
      session.seenSpaces.add(space.type);
    }
    final old = mirrors[space.type];
    if (old != null && old.space == space) {
      return;
    }
    if (old != null) {
      _dropEntries(old);
    }
    final mirror = _Mirror(space);
    mirrors[space.type] = mirror;
    views[space.type] = mirror.view;
  }

  void onSlotItem(_Session session, SlotItem item) {
    final mirror = mirrors[item.type];
    if (mirror == null || item.slot >= mirror.space.count) {
      _log.warning('SLOT item outside any known space: $item');
      return;
    }
    if (session.syncing) {
      session.seenSlots.add((item.type, item.slot));
    }
    _set(mirror, item.slot, item.entry);
  }

  /// After `SYNCED`: spaces and slots missing from the snapshot are gone.
  void onSynced(_Session session) {
    for (final type in mirrors.keys.toList()) {
      final mirror = mirrors[type]!;
      if (!session.seenSpaces.contains(type)) {
        _dropEntries(mirror);
        mirrors.remove(type);
        views.remove(type);
        continue;
      }
      for (final slot in mirror.entries.keys.toList()) {
        if (!session.seenSlots.contains((type, slot))) {
          _set(mirror, slot, SlotEntry.unassigned);
        }
      }
    }
    session.seenSpaces.clear();
    session.seenSlots.clear();
  }

  void _set(_Mirror mirror, int slot, SlotEntry entry) {
    final previous = mirror.entries[slot] ?? SlotEntry.unassigned;
    if (entry.isEmpty) {
      mirror.entries.remove(slot);
    } else {
      mirror.entries[slot] = entry;
    }
    if (previous != entry && !events.isClosed) {
      events.add(SlotEvent(mirror.space.type, slot, entry, previous));
    }
  }

  void _dropEntries(_Mirror mirror) {
    for (final slot in mirror.entries.keys.toList()) {
      _set(mirror, slot, SlotEntry.unassigned);
    }
  }

  SlotEntry? slotOwner(Name type, int slot) {
    final entry = mirrors[type]?.entries[slot];
    return entry != null && entry.owner != 0 ? entry : null;
  }

  Future<void> close() async {
    final cancelled = SwitchboardException.of(
      StatusCode.cancelled,
      'naming client closed',
    );
    for (final definition in definitions.values) {
      definition.fail(cancelled, StackTrace.current);
    }
    for (final declared in holdings.values) {
      for (final p in declared.pending) {
        if (!p.completer.isCompleted) {
          p.completer.completeError(cancelled);
        }
      }
      declared.pending.clear();
    }
    draining.clear();
    await events.close();
  }
}

/// A remembered `SLOTS`.
class _SpaceDefinition {
  _SpaceDefinition(this.request) {
    // Only fails on refusal or close; a caller may drop the future.
    completer.future.ignore();
  }

  final SlotsRequest request;
  final Completer<void> completer = Completer<void>();

  void complete() {
    if (!completer.isCompleted) {
      completer.complete();
    }
  }

  void fail(Object error, StackTrace stackTrace) {
    if (!completer.isCompleted) {
      completer.completeError(error, stackTrace);
    }
  }

  /// A newer definition of the same type replaces this one: a pending
  /// caller learns the newer one's outcome.
  void supersede(_SpaceDefinition newer) {
    if (!completer.isCompleted) {
      newer.completer.future.then(
        (_) => complete(),
        onError: (Object e, StackTrace st) => fail(e, st),
      );
    }
  }
}

/// The remembered `HOLDING` declarations of one type.
class _Holdings {
  final Set<int> slots = {};

  /// Calls of [NamingClient.declareHolding] not sent yet.
  final List<_PendingHolding> pending = [];
}

class _PendingHolding {
  _PendingHolding(this.slots) {
    completer.future.ignore();
  }

  final Set<int> slots;
  final Completer<List<int>> completer = Completer<List<int>>();
}

/// A slot this instance serves.
class _Served {
  _Served(this.epoch, {required this.holding});

  int epoch;

  /// The instance holds the slot's storage (it answered `ASSIGN` without
  /// "not holding").
  final bool holding;
}

/// A slot locked by `DRAIN`.
class _Draining {
  _Draining(this.epoch, this.drained);

  /// The slot's epoch before the migration.
  final int epoch;

  /// Completes when the `DRAIN` handler is done.
  final Future<void> drained;
}

/// The mirrored slot table of one type.
class _Mirror {
  _Mirror(this.space) {
    view = SlotTable(space, entries);
  }

  final SlotSpace space;
  final Map<int, SlotEntry> entries = {};
  late final SlotTable view;
}
