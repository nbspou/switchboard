/*
Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Author: Jan Boon <jan.boon@kaetemi.be>
*/

part of 'naming_service.dart';

/// At most this many `ASSIGN`s the allocator keeps in flight per space.
const int _maxConcurrentAssigns = 16;

/// The epoch after [epoch]; wraps to 1, since 0 is a slot never owned.
int _nextEpoch(int epoch) => epoch >= maxU32 ? 1 : epoch + 1;

Status _statusOf(Object error) => error is SwitchboardException
    ? error.status
    : Status.of(StatusCode.unknown, '$error');

/// The slot tables of the naming service and everything that changes them:
/// the slot procedures, the hand-over orchestration and the allocator. See
/// the wiki page "Switchboard Sharding".
class _SlotManager {
  _SlotManager(this.service);

  final NamingService service;

  /// Slot spaces by type. A space is never removed; a redefinition changes
  /// it in place.
  final Map<Name, _Space> spaces = {};
  final Map<Name, SlotTable> views = {};
  final StreamController<SlotItem> events =
      StreamController<SlotItem>.broadcast();

  /// Requests waiting for something slow (an `ASSIGN`, the end of the
  /// assignment hold, a migration), kept alive with `EXTEND`.
  final Set<TalkMessage> waiting = {};
  Timer? keepAliveTimer;

  /// `CLAIM` and `HOLDING` requests made during the assignment hold.
  final List<_HeldClaim> heldClaims = [];
  final List<_HeldHolding> heldHoldings = [];
  int _claimSequence = 0;
  final Completer<void> _holdOver = Completer<void>();
  bool closed = false;

  bool get holding => service.isHoldingAssignments;

  Future<void> get holdOver =>
      holding && !_holdOver.isCompleted ? _holdOver.future : Future.value();

  // ---------------------------------------------------------------------
  // Replies and keep-alive

  void reply(TalkMessage message, Uint8List payload) {
    unwait(message);
    NamingService._reply(message, payload);
  }

  void abort(TalkMessage message, Status status) {
    unwait(message);
    NamingService._abort(message, status);
  }

  void abortCode(TalkMessage message, StatusCode code, String reason) =>
      abort(message, Status.of(code, reason));

  /// Keeps [message] alive with `EXTEND` every heartbeat until answered.
  void wait(TalkMessage message) {
    if (!message.canReply || closed) {
      return;
    }
    waiting.add(message);
    keepAliveTimer ??= Timer.periodic(service.heartbeat, (_) => _tick());
  }

  void unwait(TalkMessage message) {
    if (waiting.remove(message) && waiting.isEmpty) {
      keepAliveTimer?.cancel();
      keepAliveTimer = null;
    }
  }

  void _tick() {
    waiting.removeWhere((m) => !m.canReply);
    for (final message in waiting.toList()) {
      try {
        message.extend();
      } on SwitchboardException catch (e) {
        _log.fine('${message.procedureName} not extended: $e');
        waiting.remove(message);
      }
    }
    if (waiting.isEmpty) {
      keepAliveTimer?.cancel();
      keepAliveTimer = null;
    }
  }

  T? decode<T>(TalkMessage message, T Function(Uint8List) decoder) {
    try {
      return decoder(message.payload);
    } on ProtocolException catch (e) {
      abortCode(message, StatusCode.invalidArgument, e.status.reason);
      return null;
    }
  }

  /// The space of [type] if [slot] is in it; otherwise answers `NOT_FOUND`
  /// and returns null.
  _Space? lookup(TalkMessage message, Name type, int slot) {
    final space = spaces[type];
    if (space == null) {
      abortCode(message, StatusCode.notFound, 'no slot space $type');
      return null;
    }
    if (slot >= space.space.count) {
      abortCode(
        message,
        StatusCode.notFound,
        'no slot $slot in $type (${space.space.count} slots)',
      );
      return null;
    }
    return space;
  }

  /// The registration of [type] on [session]; null if there is none.
  /// Throws `FAILED_PRECONDITION` if there are several: the requests from
  /// the naming service carry no instance id, so a channel serves the slots
  /// of a type for one instance only.
  _Registration? registrationOf(_Session session, Name type) {
    _Registration? found;
    for (final registration in session.owned) {
      if (registration.address.type == type) {
        if (found != null) {
          throw SwitchboardException.of(
            StatusCode.failedPrecondition,
            'several instances of $type registered on this channel',
          );
        }
        found = registration;
      }
    }
    return found;
  }

  /// The live registration `type/instance`, or null.
  _Registration? live(Name type, int instance) {
    final registration = service._instances[instance];
    return registration != null &&
            registration.address.type == type &&
            registration.up
        ? registration
        : null;
  }

  /// Live instances of the space's type with capacity: the allocator's
  /// candidates, by ascending instance id.
  List<_Registration> candidates(_Space space) => [
    for (final registration in service._instances.values)
      if (registration.address.type == space.type &&
          registration.up &&
          registration.weight > 0)
        registration,
  ]..sort((a, b) => a.instance.compareTo(b.instance));

  // ---------------------------------------------------------------------
  // Table

  /// Sets the state of [slot], keeps the allocator's counters, and
  /// publishes a `SLOT` item if it changed.
  void setEntry(_Space space, int slot, SlotEntry entry) {
    final old = space.entry(slot);
    if (old == entry) {
      return;
    }
    if (old.owner != 0) {
      final n = space.load[old.owner]! - 1;
      if (n == 0) {
        space.load.remove(old.owner);
      } else {
        space.load[old.owner] = n;
      }
    }
    if (entry.owner != 0) {
      space.load.update(entry.owner, (n) => n + 1, ifAbsent: () => 1);
    }
    if (entry == SlotEntry.unassigned) {
      space.entries.remove(slot);
    } else {
      space.entries[slot] = entry;
    }
    space.unpark(slot, old.holder);
    space.updateOpen(slot, entry);
    _log.fine('slot ${space.type}/$slot: $entry');
    final item = SlotItem(space.type, slot, entry);
    service._publishItem(space.type, Procedures.slot, item.encode());
    if (!events.isClosed) {
      events.add(item);
    }
  }

  void publishSpace(_Space space) {
    service._publishItem(
      space.type,
      Procedures.slotSpace,
      space.space.encode(),
    );
  }

  /// `SLOTSPC` and `SLOT` items of the spaces [matches] accepts, for a
  /// snapshot: each space before its slots, slots in ascending order,
  /// leaving out free slots with holder 0.
  Iterable<(Name, Uint8List)> snapshot(bool Function(Name type) matches) sync* {
    for (final space in spaces.values) {
      if (!matches(space.type)) {
        continue;
      }
      yield (Procedures.slotSpace, space.space.encode());
      final slots = space.entries.keys.toList()..sort();
      for (final slot in slots) {
        final entry = space.entries[slot]!;
        if (!entry.isEmpty) {
          yield (Procedures.slot, SlotItem(space.type, slot, entry).encode());
        }
      }
    }
  }

  void Function() markBusy(_Space space, int slot) {
    final completer = Completer<void>();
    space.busy[slot] = completer;
    return () {
      if (identical(space.busy[slot], completer)) {
        space.busy.remove(slot);
      }
      completer.complete();
    };
  }

  // ---------------------------------------------------------------------
  // SLOTS

  void onSlots(_Session session, TalkMessage message) {
    final request = decode(message, SlotsRequest.decode);
    if (request == null) {
      return;
    }
    final definition = request.space;
    final type = definition.type;
    if (type.isEmpty) {
      abortCode(message, StatusCode.invalidArgument, 'empty slot space type');
      return;
    }
    if (definition.count == 0) {
      abortCode(message, StatusCode.invalidArgument, 'slot count is 0');
      return;
    }
    if (definition.count > service.maxSlotCount) {
      abortCode(
        message,
        StatusCode.outOfRange,
        'slot count ${definition.count} over ${service.maxSlotCount}',
      );
      return;
    }
    final _Registration? registration;
    try {
      registration = registrationOf(session, type);
    } on SwitchboardException catch (e) {
      abort(message, e.status);
      return;
    }
    var space = spaces[type];
    if (space == null) {
      space = _Space(definition);
      spaces[type] = space;
      views[type] = space.view;
      _log.info('slot space defined: $definition');
      publishSpace(space);
    } else if (space.space != definition) {
      if (!space.isBlank) {
        abortCode(
          message,
          StatusCode.failedPrecondition,
          'slot space $type is defined as ${space.space}',
        );
        return;
      }
      _log.info('slot space redefined: ${space.space} -> $definition');
      for (final timer in space.grace.values) {
        timer.cancel();
      }
      space.define(definition);
      views[type] = space.view;
      publishSpace(space);
    }
    if (registration != null) {
      registration.capacity = request.capacity;
      // The holder is back: its slots are looked at again, given back to
      // it if it takes slots, or assigned elsewhere fetching from it.
      space.grace.remove(registration.instance)?.cancel();
      final parked = space.parked.remove(registration.instance);
      if (parked != null) {
        space.open.addAll(parked);
      }
      _log.fine(
        '${registration.address} capacity ${request.capacity} for $type',
      );
    }
    reply(message, Uint8List(0));
    scheduleBalance(space);
  }

  // ---------------------------------------------------------------------
  // HOLDING

  void onHolding(_Session session, TalkMessage message) {
    final request = decode(message, HoldingRequest.decode);
    if (request == null) {
      return;
    }
    if (!_checkHolding(session, message, request)) {
      return;
    }
    if (holding) {
      // Claims made during the hold are resolved first, so that a slot
      // someone was serving goes to its last owner rather than to a
      // holder of older storage.
      heldHoldings.add(_HeldHolding(session, message, request));
      wait(message);
      return;
    }
    _processHolding(session, message, request);
  }

  bool _checkHolding(
    _Session session,
    TalkMessage message,
    HoldingRequest request,
  ) {
    if (spaces[request.type] == null) {
      abortCode(message, StatusCode.notFound, 'no slot space ${request.type}');
      return false;
    }
    try {
      if (registrationOf(session, request.type) == null) {
        abortCode(
          message,
          StatusCode.failedPrecondition,
          'not registered as ${request.type} on this channel',
        );
        return false;
      }
    } on SwitchboardException catch (e) {
      abort(message, e.status);
      return false;
    }
    return true;
  }

  void _processHolding(
    _Session session,
    TalkMessage message,
    HoldingRequest request,
  ) {
    if (!message.canReply || !session.active) {
      unwait(message);
      return;
    }
    if (!_checkHolding(session, message, request)) {
      return;
    }
    final space = spaces[request.type]!;
    final me = registrationOf(session, request.type)!.instance;
    final discard = <int>[];
    final seen = <int>{};
    for (final slot in request.slots) {
      if (!seen.add(slot)) {
        continue;
      }
      if (slot >= space.space.count) {
        discard.add(slot);
        continue;
      }
      final entry = space.entry(slot);
      if (entry.holder == me) {
        continue;
      }
      if (entry.holder == 0 && entry.isFree) {
        final target = space.assigning[slot];
        if (target == null) {
          // Nothing recorded (a fresh or restarted naming service): this
          // instance becomes the holder, and gets the slot back first.
          setEntry(space, slot, SlotEntry.free(holder: me, epoch: entry.epoch));
          continue;
        }
        if (target == me) {
          continue;
        }
      }
      discard.add(slot);
    }
    if (discard.isNotEmpty) {
      _log.info(
        '${ServiceAddress(request.type, me)} should discard '
        '${discard.length} slots',
      );
    }
    reply(message, HoldingResponse(discard).encode());
    scheduleBalance(space);
  }

  // ---------------------------------------------------------------------
  // CLAIM

  void onClaim(_Session session, TalkMessage message) {
    final request = decode(message, ClaimRequest.decode);
    if (request == null ||
        lookup(message, request.type, request.slot) == null) {
      return;
    }
    try {
      if (registrationOf(session, request.type) == null) {
        abortCode(
          message,
          StatusCode.failedPrecondition,
          'not registered as ${request.type} on this channel',
        );
        return;
      }
    } on SwitchboardException catch (e) {
      abort(message, e.status);
      return;
    }
    if (holding) {
      heldClaims.add(_HeldClaim(session, message, request, _claimSequence++));
      wait(message);
      return;
    }
    unawaited(_claim(session, message, request));
  }

  Future<void> _claim(
    _Session session,
    TalkMessage message,
    ClaimRequest request,
  ) async {
    wait(message);
    final type = request.type;
    final slot = request.slot;
    while (true) {
      if (!message.canReply || !session.active) {
        unwait(message);
        return;
      }
      if (closed) {
        abortCode(message, StatusCode.goingAway, 'naming service closed');
        return;
      }
      final space = lookup(message, type, slot);
      if (space == null) {
        return;
      }
      final _Registration? claimant;
      try {
        claimant = registrationOf(session, type);
      } on SwitchboardException catch (e) {
        abort(message, e.status);
        return;
      }
      if (claimant == null) {
        abortCode(
          message,
          StatusCode.failedPrecondition,
          'not registered as $type on this channel',
        );
        return;
      }
      final entry = space.entry(slot);
      switch (entry.state) {
        case SlotState.migrating:
          abortCode(
            message,
            StatusCode.failedPrecondition,
            'slot $type/$slot is migrating',
          );
          return;
        case SlotState.owned:
          if (entry.owner == claimant.instance) {
            reply(message, ClaimResponse(entry.epoch).encode());
          } else {
            abortCode(
              message,
              StatusCode.alreadyExists,
              'slot $type/$slot is owned by '
              '${ServiceAddress(type, entry.owner)}',
            );
          }
          return;
        case SlotState.free:
          final busy = space.busy[slot];
          if (busy != null) {
            await busy.future;
            continue;
          }
          final holder = entry.holder != 0
              ? entry.holder
              : (request.holding ? claimant.instance : 0);
          final failure = await assign(
            space,
            slot,
            claimant,
            holder: holder,
            minEpoch: request.epoch,
          );
          if (failure != null) {
            abort(message, failure);
            return;
          }
      }
    }
  }

  // ---------------------------------------------------------------------
  // RELEASE

  void onRelease(_Session session, TalkMessage message) {
    final request = decode(message, ReleaseRequest.decode);
    if (request == null ||
        lookup(message, request.type, request.slot) == null) {
      return;
    }
    unawaited(_release(session, message, request));
  }

  Future<void> _release(
    _Session session,
    TalkMessage message,
    ReleaseRequest request,
  ) async {
    final type = request.type;
    final slot = request.slot;
    while (true) {
      if (!message.canReply || !session.active) {
        unwait(message);
        return;
      }
      final space = lookup(message, type, slot);
      if (space == null) {
        return;
      }
      final _Registration? caller;
      try {
        caller = registrationOf(session, type);
      } on SwitchboardException catch (e) {
        abort(message, e.status);
        return;
      }
      final entry = space.entry(slot);
      if (entry.state == SlotState.migrating) {
        abortCode(
          message,
          StatusCode.failedPrecondition,
          'slot $type/$slot is migrating',
        );
        return;
      }
      if (entry.state == SlotState.owned &&
          caller != null &&
          entry.owner == caller.instance) {
        setEntry(
          space,
          slot,
          SlotEntry.free(
            holder: request.keepStorage ? entry.holder : 0,
            epoch: entry.epoch,
          ),
        );
        _log.info('${caller.address} released $type/$slot');
        reply(message, Uint8List(0));
        scheduleBalance(space);
        return;
      }
      final busy = space.busy[slot];
      if (entry.isFree &&
          busy != null &&
          caller != null &&
          space.assigning[slot] == caller.instance) {
        // Being assigned to the caller: release once that is decided.
        wait(message);
        await busy.future;
        continue;
      }
      abortCode(
        message,
        StatusCode.permissionDenied,
        'slot $type/$slot is not owned by this instance',
      );
      return;
    }
  }

  // ---------------------------------------------------------------------
  // LOCATE

  void onLocate(TalkMessage message) {
    final request = decode(message, LocateRequest.decode);
    if (request == null ||
        lookup(message, request.type, request.slot) == null) {
      return;
    }
    unawaited(_locate(message, request));
  }

  Future<void> _locate(TalkMessage message, LocateRequest request) async {
    final type = request.type;
    final slot = request.slot;
    while (true) {
      if (!message.canReply) {
        unwait(message);
        return;
      }
      if (closed) {
        abortCode(message, StatusCode.goingAway, 'naming service closed');
        return;
      }
      final space = lookup(message, type, slot);
      if (space == null) {
        return;
      }
      final entry = space.entry(slot);
      if (!entry.isFree || space.space.mode == SlotMode.static) {
        reply(
          message,
          LocateResponse(entry.state, entry.owner, entry.epoch).encode(),
        );
        return;
      }
      final busy = space.busy[slot];
      if (busy != null) {
        wait(message);
        await busy.future;
        continue;
      }
      if (holding) {
        wait(message);
        await holdOver;
        continue;
      }
      final target = targetFor(space, entry, candidates(space), locate: true);
      if (target == null) {
        reply(message, LocateResponse(SlotState.free, 0, entry.epoch).encode());
        return;
      }
      wait(message);
      final failure = await assign(space, slot, target, holder: entry.holder);
      if (failure != null) {
        abort(message, failure);
        return;
      }
    }
  }

  // ---------------------------------------------------------------------
  // MIGRATE

  void onMigrate(TalkMessage message) {
    if (!message.expectsStream) {
      abortCode(
        message,
        StatusCode.invalidArgument,
        'MIGRATE is a stream request',
      );
      return;
    }
    final request = decode(message, MigrateRequest.decode);
    if (request == null) {
      return;
    }
    final space = lookup(message, request.type, request.slot);
    if (space == null) {
      return;
    }
    final problem = migrationProblem(space, request.slot, request.to);
    if (problem != null) {
      abortCode(message, StatusCode.failedPrecondition, problem);
      return;
    }
    final migration = _Migration(request.slot, request.to, message);
    space.queue.add(migration);
    // Migrations can take long: the responder timeout is replaced by the
    // heartbeat, which keeps the requester's timeout from firing.
    message.setReplyTimeout(Duration.zero);
    wait(message);
    unawaited(
      message.onCancel.then((_) {
        unwait(message);
        space.queue.remove(migration);
      }),
    );
    pumpMigrations(space);
  }

  /// Why [slot] cannot be migrated to [to] now, or null.
  String? migrationProblem(_Space space, int slot, int to) {
    final type = space.type;
    final entry = space.entry(slot);
    if (entry.state == SlotState.migrating ||
        space.active?.slot == slot ||
        space.queue.any((m) => m.slot == slot)) {
      return 'slot $type/$slot is already migrating';
    }
    if (entry.state != SlotState.owned) {
      return 'slot $type/$slot is not owned';
    }
    if (space.busy.containsKey(slot)) {
      return 'slot $type/$slot is busy';
    }
    if (to == 0) {
      if (pickTarget(space, candidates(space), exclude: entry.owner) == null) {
        return 'no other instance of $type can take slot $slot';
      }
      return null;
    }
    if (to == entry.owner) {
      return 'slot $type/$slot is already owned by '
          '${ServiceAddress(type, to)}';
    }
    if (live(type, to) == null) {
      return '${ServiceAddress(type, to)} is not registered';
    }
    return null;
  }

  /// Starts the next queued migration of [space], if none is running.
  void pumpMigrations(_Space space) {
    if (closed || holding || space.active != null) {
      return;
    }
    while (space.queue.isNotEmpty) {
      final migration = space.queue.removeFirst();
      final request = migration.request;
      if (request != null && !request.canReply) {
        unwait(request);
        continue;
      }
      final problem = migrationProblem(space, migration.slot, migration.to);
      if (problem != null) {
        if (request != null) {
          abortCode(request, StatusCode.failedPrecondition, problem);
        }
        continue;
      }
      space.active = migration;
      unawaited(_migrate(space, migration));
      return;
    }
  }

  /// The hand-over, as in the wiki section "The hand-over, step by step".
  Future<void> _migrate(_Space space, _Migration migration) async {
    final type = space.type;
    final slot = migration.slot;
    final start = space.entry(slot);
    final epoch = start.epoch;
    final next = _nextEpoch(epoch);
    final holder = start.holder;
    final from = service._instances[start.owner]!;
    final to = migration.to != 0
        ? live(type, migration.to)!
        : pickTarget(space, candidates(space), exclude: start.owner)!;
    final release = markBusy(space, slot);
    final what = '$type/$slot from ${from.address} to ${to.address}';
    try {
      _log.info('migrating $what');
      setEntry(
        space,
        slot,
        SlotEntry.migrating(
          from.instance,
          to.instance,
          holder: holder,
          epoch: epoch,
        ),
      );
      migration.phase(MigrationPhase.draining);
      Object? failure;
      try {
        await ask(
          from,
          Procedures.drain,
          DrainRequest(type, slot, epoch: next, to: to.instance).encode(),
        );
      } catch (e) {
        failure = e;
      }
      if (closed) {
        _abandon(migration, 'naming service closed');
        return;
      }
      if (!from.up) {
        _lost(space, slot, holder, epoch);
        _rollBack(migration, '$what: ${from.address} went down');
        return;
      }
      if (failure != null) {
        _resume(space, slot, from, epoch, holder);
        _rollBack(migration, '$what: DRAIN failed: ${_statusOf(failure)}');
        return;
      }
      migration.phase(MigrationPhase.assigning);
      TalkMessage? response;
      try {
        response = await ask(
          to,
          Procedures.assign,
          AssignRequest(
            type,
            slot,
            epoch: next,
            holder: holder,
            shared: space.space.shared,
          ).encode(),
        );
      } catch (e) {
        failure = e;
      }
      if (closed) {
        _abandon(migration, 'naming service closed');
        return;
      }
      if (response == null || !to.up) {
        final reason = response == null
            ? 'ASSIGN failed: ${_statusOf(failure!)}'
            : '${to.address} went down';
        if (!from.up) {
          _lost(space, slot, holder, epoch);
        } else {
          _resume(space, slot, from, epoch, holder);
        }
        _rollBack(migration, '$what: $reason');
        return;
      }
      final notHolding = AssignResponse.decode(response.payload).notHolding;
      setEntry(
        space,
        slot,
        SlotEntry.owned(
          to.instance,
          holder: notHolding ? holder : to.instance,
          epoch: next,
        ),
      );
      if (from.up) {
        migration.phase(MigrationPhase.forwarding);
        try {
          await ask(
            from,
            Procedures.forward,
            ForwardRequest(type, slot, epoch: next, to: to.instance).encode(),
          );
        } catch (e) {
          // The new owner serves already; the old one is either gone or
          // will answer MOVED.
          _log.warning('FORWARD of $what failed: ${_statusOf(e)}');
        }
      }
      _log.info('migrated $what, epoch $next');
      migration.phase(MigrationPhase.done);
      final request = migration.request;
      if (request != null) {
        reply(request, Uint8List(0));
      }
    } finally {
      release();
      space.active = null;
      final request = migration.request;
      if (request != null) {
        unwait(request);
      }
      pumpMigrations(space);
      scheduleBalance(space);
    }
  }

  /// The old owner went down during a migration: the slot is free with its
  /// holder kept, as for any slot of an instance that went down.
  void _lost(_Space space, int slot, int holder, int epoch) =>
      setEntry(space, slot, SlotEntry.free(holder: holder, epoch: epoch));

  /// Gives the slot back to [from] and tells it to unlock.
  void _resume(
    _Space space,
    int slot,
    _Registration from,
    int epoch,
    int holder,
  ) {
    setEntry(
      space,
      slot,
      SlotEntry.owned(from.instance, holder: holder, epoch: epoch),
    );
    unawaited(
      ask(
        from,
        Procedures.resume,
        ResumeRequest(space.type, slot, epoch: epoch).encode(),
      ).then<void>(
        (_) {},
        onError: (Object e) => _log.warning(
          'RESUME ${space.type}/$slot to ${from.address} failed: '
          '${_statusOf(e)}',
        ),
      ),
    );
  }

  void _rollBack(_Migration migration, String reason) {
    _log.warning('migration rolled back: $reason');
    migration.phase(MigrationPhase.rolledBack);
    final request = migration.request;
    if (request != null) {
      abortCode(request, StatusCode.unavailable, reason);
    }
  }

  void _abandon(_Migration migration, String reason) {
    final request = migration.request;
    if (request != null) {
      abortCode(request, StatusCode.goingAway, reason);
    }
  }

  // ---------------------------------------------------------------------
  // Requests to instances

  /// Sends a request to [target] over its registration channel. Fails with
  /// the instance's abort, with `DEADLINE_EXCEEDED` after
  /// [NamingService.handoverTimeout] without an answer or `EXTEND`, and
  /// with `UNAVAILABLE` as soon as the registration goes away.
  Future<TalkMessage> ask(
    _Registration target,
    Name procedure,
    Uint8List payload,
  ) {
    final session = target.owner;
    if (session == null || !target.up) {
      return Future.error(
        SwitchboardException.of(
          StatusCode.unavailable,
          '${target.address} is down',
        ),
      );
    }
    final TalkRequest request;
    try {
      request = session.channel.startRequest(
        procedure.toString(),
        payload,
        timeout: service.handoverTimeout,
      );
    } on SwitchboardException catch (e) {
      return Future.error(e);
    }
    final completer = Completer<TalkMessage>();
    void onGone() {
      if (!completer.isCompleted) {
        request.cancel(Status.of(StatusCode.unavailable, 'instance went down'));
        completer.completeError(
          SwitchboardException.of(
            StatusCode.unavailable,
            '${target.address} went down',
          ),
        );
      }
    }

    target.onGone.add(onGone);
    request.response.then(
      (response) {
        target.onGone.remove(onGone);
        if (!completer.isCompleted) {
          completer.complete(response);
        }
      },
      onError: (Object e, StackTrace st) {
        target.onGone.remove(onGone);
        if (!completer.isCompleted) {
          completer.completeError(e, st);
        }
      },
    );
    return completer.future;
  }

  /// Assigns the free [slot] to [target] through `ASSIGN`. Returns null
  /// once [target] owns it, or the failure; the slot then stays free with
  /// its holder unchanged.
  Future<Status?> assign(
    _Space space,
    int slot,
    _Registration target, {
    required int holder,
    int minEpoch = 0,
  }) async {
    final release = markBusy(space, slot);
    space.assigning[slot] = target.instance;
    space.pendingFor.update(target.instance, (n) => n + 1, ifAbsent: () => 1);
    final type = space.type;
    try {
      final current = space.entry(slot);
      final epoch = _nextEpoch(max(current.epoch, minEpoch));
      final request = AssignRequest(
        type,
        slot,
        epoch: epoch,
        holder: holder,
        shared: space.space.shared,
      );
      final TalkMessage response;
      try {
        response = await ask(target, Procedures.assign, request.encode());
      } catch (e) {
        final status = _statusOf(e);
        _log.info('$request to ${target.address} failed: $status');
        return Status.of(
          StatusCode.unavailable,
          'ASSIGN $type/$slot to ${target.address} failed: $status',
        );
      }
      if (closed) {
        return Status.of(StatusCode.goingAway, 'naming service closed');
      }
      if (!target.up) {
        return Status.of(
          StatusCode.unavailable,
          '${target.address} went down during ASSIGN',
        );
      }
      final notHolding = AssignResponse.decode(response.payload).notHolding;
      final now = space.entry(slot);
      setEntry(
        space,
        slot,
        SlotEntry.owned(
          target.instance,
          holder: notHolding ? now.holder : target.instance,
          epoch: epoch,
        ),
      );
      _log.fine('$type/$slot assigned to ${target.address}, epoch $epoch');
      return null;
    } finally {
      space.assigning.remove(slot);
      final n = space.pendingFor[target.instance]! - 1;
      if (n == 0) {
        space.pendingFor.remove(target.instance);
      } else {
        space.pendingFor[target.instance] = n;
      }
      release();
      scheduleBalance(space);
    }
  }

  // ---------------------------------------------------------------------
  // Allocator

  void scheduleBalance(_Space space) {
    if (space.balanceScheduled || closed) {
      return;
    }
    space.balanceScheduled = true;
    scheduleMicrotask(() {
      space.balanceScheduled = false;
      _balance(space);
    });
  }

  void _balance(_Space space) {
    if (closed ||
        holding ||
        space.space.mode != SlotMode.managed ||
        !identical(spaces[space.type], space)) {
      return;
    }
    final candidates = this.candidates(space);
    if (candidates.isEmpty) {
      return;
    }
    final parked = <int>[];
    for (final slot in space.open) {
      if (space.assigning.length >= _maxConcurrentAssigns) {
        break;
      }
      if (space.busy.containsKey(slot)) {
        continue;
      }
      final entry = space.entry(slot);
      final target = targetFor(space, entry, candidates);
      if (target != null) {
        unawaited(assign(space, slot, target, holder: entry.holder));
      } else if (_waitsForHolder(space, entry)) {
        parked.add(slot);
      }
    }
    // Slots waiting for their holder are left out of later passes until
    // it registers again or its grace period ends.
    for (final slot in parked) {
      space.park(slot, space.entry(slot).holder);
    }
    _rebalance(space, candidates);
  }

  /// A free slot of a holder-only space whose holder is down, or back but
  /// without having sent `SLOTS` yet.
  bool _waitsForHolder(_Space space, SlotEntry entry) =>
      !space.space.shared &&
      entry.isFree &&
      entry.holder != 0 &&
      live(space.type, entry.holder)?.capacity == null;

  /// Where the free slot [entry] goes now, or null to leave it free.
  ///
  /// Its holder, if it is up and has capacity (the slot is reclaimed). A
  /// holder that is down, or registered but has not sent `SLOTS` yet, makes
  /// a holder-only slot wait for the holder's grace period. Otherwise the
  /// candidate with the most spare capacity (fetching the state from a
  /// holder that takes no slots); a lazy space assigns other slots only on
  /// `LOCATE` ([locate]).
  _Registration? targetFor(
    _Space space,
    SlotEntry entry,
    List<_Registration> candidates, {
    bool locate = false,
  }) {
    final holder = entry.holder;
    if (holder != 0) {
      final registration = live(space.type, holder);
      if (registration != null && registration.weight > 0) {
        return registration;
      }
      if (_waitsForHolder(space, entry)) {
        _startGrace(space, holder);
        return null;
      }
    }
    if (space.space.lazy && !locate) {
      return null;
    }
    return pickTarget(space, candidates);
  }

  /// The candidate with the most spare capacity, counting assignments in
  /// flight; ties go to the lower instance id.
  _Registration? pickTarget(
    _Space space,
    List<_Registration> candidates, {
    int exclude = 0,
  }) {
    var total = 0;
    var assigned = 1;
    for (final c in candidates) {
      total += c.weight;
      assigned += space.loadOf(c.instance);
    }
    _Registration? best;
    var bestSpare = 0;
    for (final c in candidates) {
      if (c.instance == exclude) {
        continue;
      }
      // Spare share, scaled by the total capacity.
      final spare = c.weight * assigned - space.loadOf(c.instance) * total;
      if (best == null || spare > bestSpare) {
        best = c;
        bestSpare = spare;
      }
    }
    return best;
  }

  /// Moves one slot from the most over-share candidate to the most
  /// under-share one when that one is short by at least one slot. Runs
  /// only when nothing else is in flight in the space, so the allocator's
  /// migrations are strictly one at a time.
  void _rebalance(_Space space, List<_Registration> candidates) {
    if (candidates.length < 2 ||
        space.assigning.isNotEmpty ||
        space.active != null ||
        space.queue.isNotEmpty) {
      return;
    }
    var total = 0;
    var assigned = 0;
    for (final c in candidates) {
      total += c.weight;
      assigned += space.loadOf(c.instance);
    }
    if (assigned == 0) {
      return;
    }
    // deficit = (target - load) * total, target = capacity * assigned / total
    int deficit(_Registration c) =>
        c.weight * assigned - space.loadOf(c.instance) * total;
    var under = candidates.first;
    var over = candidates.first;
    for (final c in candidates.skip(1)) {
      if (deficit(c) > deficit(under)) {
        under = c;
      }
      if (deficit(c) < deficit(over)) {
        over = c;
      }
    }
    if (identical(under, over) || deficit(under) < total) {
      return;
    }
    int? slot;
    for (final MapEntry(key: s, value: entry) in space.entries.entries) {
      if (entry.state == SlotState.owned &&
          entry.owner == over.instance &&
          !space.busy.containsKey(s) &&
          (slot == null || s < slot)) {
        slot = s;
      }
    }
    if (slot == null) {
      return;
    }
    _log.info(
      'rebalancing ${space.type}: slot $slot from ${over.address} to '
      '${under.address}',
    );
    space.queue.add(_Migration(slot, under.instance, null));
    pumpMigrations(space);
  }

  void _startGrace(_Space space, int holder) {
    if (closed || space.grace.containsKey(holder)) {
      return;
    }
    _log.info(
      'waiting ${service.holderGrace} for holder '
      '${ServiceAddress(space.type, holder)} to return',
    );
    space.grace[holder] = Timer(service.holderGrace, () {
      space.grace.remove(holder);
      if (closed || !identical(spaces[space.type], space)) {
        return;
      }
      if (live(space.type, holder)?.capacity == null) {
        _log.warning(
          'holder ${ServiceAddress(space.type, holder)} did not return; '
          'its slots start fresh',
        );
        final slots = {...?space.parked[holder], ...space.open};
        for (final slot in slots) {
          final entry = space.entry(slot);
          if (entry.isFree &&
              entry.holder == holder &&
              !space.busy.containsKey(slot)) {
            setEntry(space, slot, SlotEntry.free(epoch: entry.epoch));
          }
        }
      }
      scheduleBalance(space);
    });
  }

  // ---------------------------------------------------------------------
  // Lifecycle

  /// [registration] was removed: its owned slots become free with their
  /// holder kept; running requests to it fail at once.
  void onDown(_Registration registration) {
    for (final callback in registration.onGone.toList()) {
      callback();
    }
    registration.onGone.clear();
    final space = spaces[registration.address.type];
    if (space == null) {
      return;
    }
    var freed = 0;
    for (final MapEntry(key: slot, value: entry)
        in space.entries.entries.toList()) {
      // Migrating slots are left to the migration, which sees the loss.
      if (entry.state == SlotState.owned &&
          entry.owner == registration.instance) {
        setEntry(
          space,
          slot,
          SlotEntry.free(holder: entry.holder, epoch: entry.epoch),
        );
        freed++;
      }
    }
    if (freed > 0) {
      _log.info('${registration.address} went down, $freed slots free');
      if (space.space.mode == SlotMode.managed && !space.space.shared) {
        _startGrace(space, registration.instance);
      }
    }
    scheduleBalance(space);
  }

  /// The assignment hold is over: resolves the claims made meanwhile
  /// (higher epoch first, then the earlier claim), then the `HOLDING`
  /// declarations, then lets the allocator and migrations run.
  void onHoldEnded() {
    if (closed) {
      return;
    }
    if (!_holdOver.isCompleted) {
      _holdOver.complete();
    }
    final claims = List.of(heldClaims)
      ..sort((a, b) {
        final byEpoch = b.request.epoch.compareTo(a.request.epoch);
        return byEpoch != 0 ? byEpoch : a.sequence.compareTo(b.sequence);
      });
    heldClaims.clear();
    if (claims.isNotEmpty) {
      _log.info('assignment hold over, resolving ${claims.length} claims');
    }
    // In that order: the first claim of a slot marks it busy, and the
    // others wait for it and then see who owns the slot.
    for (final claim in claims) {
      unawaited(_claim(claim.session, claim.message, claim.request));
    }
    final holdings = List.of(heldHoldings);
    heldHoldings.clear();
    for (final held in holdings) {
      _processHolding(held.session, held.message, held.request);
    }
    for (final space in spaces.values) {
      pumpMigrations(space);
      scheduleBalance(space);
    }
  }

  void close() {
    closed = true;
    final goingAway = Status.of(StatusCode.goingAway, 'naming service closed');
    keepAliveTimer?.cancel();
    keepAliveTimer = null;
    for (final held in heldClaims) {
      abort(held.message, goingAway);
    }
    heldClaims.clear();
    for (final held in heldHoldings) {
      abort(held.message, goingAway);
    }
    heldHoldings.clear();
    for (final space in spaces.values) {
      for (final timer in space.grace.values) {
        timer.cancel();
      }
      space.grace.clear();
      for (final migration in space.queue) {
        final request = migration.request;
        if (request != null) {
          abort(request, goingAway);
        }
      }
      space.queue.clear();
    }
    if (!_holdOver.isCompleted) {
      _holdOver.complete();
    }
    for (final message in waiting.toList()) {
      abort(message, goingAway);
    }
    waiting.clear();
  }
}

/// One slot space and the allocator's bookkeeping for it.
class _Space {
  _Space(SlotSpace definition) : space = definition {
    define(definition);
  }

  SlotSpace space;
  final Map<int, SlotEntry> entries = {};
  late SlotTable view;

  /// Slots routed to each instance (owned, or migrating away from it).
  final Map<int, int> load = {};

  /// `ASSIGN`s in flight: slot to target instance, and count per target.
  final Map<int, int> assigning = {};
  final Map<int, int> pendingFor = {};

  /// Slots with an operation in progress (an `ASSIGN` or a migration).
  final Map<int, Completer<void>> busy = {};

  /// Free slots the allocator looks at: every free slot of an eager
  /// managed space, the free slots with a holder of a lazy one.
  final SplayTreeSet<int> open = SplayTreeSet<int>();

  _Migration? active;
  final Queue<_Migration> queue = Queue<_Migration>();

  /// Free slots of a holder-only space waiting for their holder to return,
  /// by holder: taken out of [open] until it does or its grace ends.
  final Map<int, Set<int>> parked = {};

  /// Holder grace timers, by holder instance.
  final Map<int, Timer> grace = {};
  bool balanceScheduled = false;

  Name get type => space.type;

  SlotEntry entry(int slot) => entries[slot] ?? SlotEntry.unassigned;

  int loadOf(int instance) =>
      (load[instance] ?? 0) + (pendingFor[instance] ?? 0);

  /// True when the space may be redefined: every slot free with holder 0
  /// and nothing in progress.
  bool get isBlank =>
      entries.values.every((e) => e.isEmpty) &&
      busy.isEmpty &&
      active == null &&
      queue.isEmpty;

  void define(SlotSpace definition) {
    space = definition;
    entries.clear();
    load.clear();
    grace.clear();
    parked.clear();
    open.clear();
    if (definition.mode == SlotMode.managed && !definition.lazy) {
      open.addAll(Iterable<int>.generate(definition.count));
    }
    view = SlotTable(definition, entries);
  }

  void park(int slot, int holder) {
    open.remove(slot);
    parked.putIfAbsent(holder, () => <int>{}).add(slot);
  }

  void unpark(int slot, int holder) {
    final slots = parked[holder];
    if (slots != null && slots.remove(slot) && slots.isEmpty) {
      parked.remove(holder);
    }
  }

  void updateOpen(int slot, SlotEntry entry) {
    final wanted =
        space.mode == SlotMode.managed &&
        entry.isFree &&
        (!space.lazy || entry.holder != 0);
    if (wanted) {
      open.add(slot);
    } else {
      open.remove(slot);
    }
  }
}

/// A queued or running migration; [request] is null for the allocator's.
class _Migration {
  _Migration(this.slot, this.to, this.request);

  final int slot;

  /// The target, 0 to let the allocator choose when it starts.
  final int to;
  final TalkMessage? request;

  void phase(MigrationPhase phase) {
    final message = request;
    if (message == null || !message.canReply) {
      return;
    }
    try {
      message.replyItem(
        PhaseItem(phase).encode(),
        procedure: Procedures.phase.toString(),
      );
    } on SwitchboardException catch (e) {
      _log.fine('PHASE not sent: $e');
    }
  }
}

/// A `CLAIM` made during the assignment hold.
class _HeldClaim {
  _HeldClaim(this.session, this.message, this.request, this.sequence);

  final _Session session;
  final TalkMessage message;
  final ClaimRequest request;
  final int sequence;
}

/// A `HOLDING` made during the assignment hold.
class _HeldHolding {
  _HeldHolding(this.session, this.message, this.request);

  final _Session session;
  final TalkMessage message;
  final HoldingRequest request;
}
