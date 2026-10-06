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

  /// Deadlines of `LOCATE` requests waiting for a backoff to end, and of
  /// `ASSIGN` and `DRAIN` requests ([NamingService.handoverMaxDuration]).
  final Set<Timer> _deadlines = {};

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
    space.wake(slot);
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
      space.wakeAll();
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
      // The candidates changed: LOCATE requests waiting for a backoff look
      // again.
      space.wakeAll();
    }
    settle(space, open: registration != null && request.capacity > 0);
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
    settle(spaces[request.type]!);
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
    final waiting = <int>[];
    for (final slot in request.slots) {
      if (!seen.add(slot)) {
        continue;
      }
      if (slot >= space.space.count) {
        discard.add(slot);
        continue;
      }
      _declareHeld(space, slot, me, discard, waiting);
    }
    if (waiting.isEmpty) {
      _answerHolding(message, space, me, discard);
      return;
    }
    // Being assigned fresh to another instance: answered once that is
    // decided, since a failed ASSIGN leaves the slot to this instance.
    wait(message);
    unawaited(
      _holdingAfterAssignments(
        session,
        message,
        space.type,
        me,
        discard,
        waiting,
      ),
    );
    scheduleBalance(space);
  }

  /// Applies a `HOLDING` declaration of [slot] by instance [me]: a free
  /// slot without holder gets [me] as holder; one being assigned to [me]
  /// is fine; one being assigned fresh (holder 0) to another instance goes
  /// to [waiting]; any other slot held elsewhere goes to [discard].
  void _declareHeld(
    _Space space,
    int slot,
    int me,
    List<int> discard,
    List<int> waiting,
  ) {
    final entry = space.entry(slot);
    if (entry.holder == me) {
      return;
    }
    if (entry.holder == 0 && entry.isFree) {
      final target = space.assigning[slot];
      if (target == null) {
        // Nothing recorded (a fresh or restarted naming service): this
        // instance becomes the holder, and gets the slot back first.
        setEntry(space, slot, SlotEntry.free(holder: me, epoch: entry.epoch));
        return;
      }
      if (target != me) {
        waiting.add(slot);
      }
      return;
    }
    discard.add(slot);
  }

  /// Answers a `HOLDING` once the fresh assignments of [waiting] to other
  /// instances are decided: a slot whose `ASSIGN` failed is this
  /// instance's again (it becomes the holder); one that went through is
  /// to discard.
  Future<void> _holdingAfterAssignments(
    _Session session,
    TalkMessage message,
    Name type,
    int me,
    List<int> discard,
    List<int> waiting,
  ) async {
    var slots = waiting;
    while (true) {
      final space = spaces[type]!;
      await Future.wait([
        for (final slot in slots)
          if (space.busy[slot] case final busy?) busy.future,
      ]);
      if (closed || !message.canReply || !session.active) {
        unwait(message);
        return;
      }
      final next = <int>[];
      for (final slot in slots) {
        if (slot < space.space.count) {
          _declareHeld(space, slot, me, discard, next);
        } else {
          discard.add(slot);
        }
      }
      if (next.isEmpty) {
        _answerHolding(message, space, me, discard);
        return;
      }
      slots = next;
    }
  }

  void _answerHolding(
    TalkMessage message,
    _Space space,
    int me,
    List<int> discard,
  ) {
    if (discard.isNotEmpty) {
      _log.info(
        '${ServiceAddress(space.type, me)} should discard '
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
    settle(spaces[request.type]!);
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

  /// Answers `LOCATE`, assigning a free slot of a managed space first. An
  /// instance that refuses the `ASSIGN` is in its backoff for the slot, so
  /// the next one is tried; once every instance that could take the slot
  /// is in its backoff, the request waits for the first backoff to end, at
  /// most [NamingService.handoverTimeout] in all (unbounded if that is
  /// zero), and then fails with `UNAVAILABLE`.
  Future<void> _locate(TalkMessage message, LocateRequest request) async {
    final type = request.type;
    final slot = request.slot;
    // Started when the request first has to wait for a backoff.
    Completer<void>? deadline;
    Timer? deadlineTimer;
    Status? failure;
    try {
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
        if (deadline != null && deadline.isCompleted) {
          abort(
            message,
            failure ??
                Status.of(
                  StatusCode.unavailable,
                  'no instance of $type took slot $slot',
                ),
          );
          return;
        }
        final candidates = this.candidates(space);
        final target = targetFor(space, slot, entry, candidates, locate: true);
        if (target == null) {
          if (candidates.isEmpty || _waitsForHolder(space, entry)) {
            reply(
              message,
              LocateResponse(SlotState.free, 0, entry.epoch).encode(),
            );
            return;
          }
          // Every instance that could take the slot is in its backoff for
          // it: wait for the first backoff to end, or for anything else to
          // change the slot or the candidates.
          wait(message);
          if (deadline == null) {
            final started = deadline = Completer<void>();
            if (service.handoverTimeout > Duration.zero) {
              late final Timer timer;
              timer = Timer(service.handoverTimeout, () {
                _deadlines.remove(timer);
                started.complete();
              });
              _deadlines.add(timer);
              deadlineTimer = timer;
            }
          }
          await Future.any([
            space.changeOf(slot),
            deadline.future,
            message.onCancel,
          ]);
          continue;
        }
        wait(message);
        final result = await assign(space, slot, target, holder: entry.holder);
        if (result != null) {
          // The target is in its backoff now; try the next one.
          failure = Status.of(StatusCode.unavailable, result.reason);
        }
      }
    } finally {
      if (deadlineTimer != null) {
        deadlineTimer.cancel();
        _deadlines.remove(deadlineTimer);
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
      final target = pickTarget(
        space,
        candidates(space),
        exclude: entry.owner,
        slot: slot,
      );
      if (target == null) {
        return 'no other instance of $type can take slot $slot now';
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
        : pickTarget(
            space,
            candidates(space),
            exclude: start.owner,
            slot: slot,
          )!;
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
          bounded: true,
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
        // Not moved away from it again by the allocator before the
        // backoff ends.
        drainFailed(space, slot, from);
        _resume(space, slot, from, epoch, holder);
        _rollBack(migration, '$what: DRAIN failed: ${_statusOf(failure)}');
        return;
      }
      drainSucceeded(space, slot, from.instance);
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
          bounded: true,
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
        if (response == null) {
          // Not migrated to it again before its backoff ends.
          assignFailed(space, slot, to);
        }
        if (!from.up) {
          _lost(space, slot, holder, epoch);
        } else {
          _resume(space, slot, from, epoch, holder);
        }
        _rollBack(migration, '$what: $reason');
        return;
      }
      final notHolding = AssignResponse.decode(response.payload).notHolding;
      assignSucceeded(space, slot, to.instance);
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
  /// with `UNAVAILABLE` as soon as the registration goes away. With
  /// [bounded] (`ASSIGN` and `DRAIN`) it also fails with
  /// `DEADLINE_EXCEEDED`, and the request is cancelled, once it has run
  /// for [NamingService.handoverMaxDuration], `EXTEND`s or not.
  Future<TalkMessage> ask(
    _Registration target,
    Name procedure,
    Uint8List payload, {
    bool bounded = false,
  }) {
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
    Timer? deadline;
    final bound = service.handoverMaxDuration;
    if (bounded && bound > Duration.zero) {
      deadline = Timer(bound, () {
        _deadlines.remove(deadline);
        if (completer.isCompleted) {
          return;
        }
        target.onGone.remove(onGone);
        final status = Status.of(
          StatusCode.deadlineExceeded,
          '$procedure to ${target.address} ran longer than $bound',
        );
        _log.warning(status.reason);
        request.cancel(status);
        completer.completeError(SwitchboardException(status));
      });
      _deadlines.add(deadline);
    }
    void settled() {
      target.onGone.remove(onGone);
      if (deadline != null) {
        deadline.cancel();
        _deadlines.remove(deadline);
      }
    }

    request.response.then(
      (response) {
        settled();
        if (!completer.isCompleted) {
          completer.complete(response);
        }
      },
      onError: (Object e, StackTrace st) {
        settled();
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
        response = await ask(
          target,
          Procedures.assign,
          request.encode(),
          bounded: true,
        );
      } catch (e) {
        final status = _statusOf(e);
        _log.info('$request to ${target.address} failed: $status');
        assignFailed(space, slot, target);
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
      assignSucceeded(space, slot, target.instance);
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
      if (entry.holder == 0 && space.settling) {
        // Its holder may be about to declare it (see [settle]).
        continue;
      }
      final target = targetFor(space, slot, entry, candidates);
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

  /// Where the free [slot] (in state [entry]) goes now, or null to leave
  /// it free.
  ///
  /// Its holder, if it is up and has capacity (the slot is reclaimed) and
  /// not in its backoff for the slot. A holder that is down, or registered
  /// but has not sent `SLOTS` yet, makes a holder-only slot wait for the
  /// holder's grace period. Otherwise the candidate with the most spare
  /// capacity among those not in their backoff for the slot (fetching the
  /// state from the holder, if any); a lazy space assigns slots other than
  /// a holder's only on `LOCATE` ([locate]).
  _Registration? targetFor(
    _Space space,
    int slot,
    SlotEntry entry,
    List<_Registration> candidates, {
    bool locate = false,
  }) {
    final holder = entry.holder;
    if (holder != 0) {
      final registration = live(space.type, holder);
      if (registration != null && registration.weight > 0) {
        if (!backingOff(space, slot, holder)) {
          return registration;
        }
      } else if (_waitsForHolder(space, entry)) {
        _startGrace(space, holder);
        return null;
      }
    }
    if (space.space.lazy && !locate) {
      return null;
    }
    return pickTarget(space, candidates, slot: slot);
  }

  /// The candidate with the most spare capacity, counting assignments in
  /// flight; ties go to the lower instance id. Leaves out [exclude] and,
  /// with a [slot], the candidates in their backoff for it.
  _Registration? pickTarget(
    _Space space,
    List<_Registration> candidates, {
    int exclude = 0,
    int? slot,
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
      if (c.instance == exclude ||
          (slot != null && backingOff(space, slot, c.instance))) {
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

  /// Moves one slot to the most under-share candidate when that one is
  /// short by at least one slot, from the most over-share candidate that
  /// has a slot it can move (not busy, and not in the `DRAIN` backoff of
  /// that owner), else from the next most over-share one, and so on among
  /// the candidates over their share. Runs only when nothing else is in
  /// flight in the space, so the allocator's migrations are strictly one
  /// at a time. A candidate in its backoff for any slot of the space is
  /// not given an owned slot: a failed hand-over costs the old owner a
  /// `DRAIN` and a `RESUME`, so the expiry of the backoff paces the
  /// attempts; a refused `DRAIN` is paced the same way.
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
    _Registration? under;
    for (final c in candidates) {
      if (!space.cooling.containsKey(c.instance) &&
          (under == null || deficit(c) > deficit(under))) {
        under = c;
      }
    }
    if (under == null || deficit(under) < total) {
      return;
    }
    // Most over-share first, ties to the lower id.
    final overs =
        [
          for (final c in candidates)
            if (!identical(c, under) && deficit(c) < 0) c,
        ]..sort((a, b) {
          final byDeficit = deficit(a).compareTo(deficit(b));
          return byDeficit != 0 ? byDeficit : a.instance.compareTo(b.instance);
        });
    for (final over in overs) {
      int? slot;
      for (final MapEntry(key: s, value: entry) in space.entries.entries) {
        if (entry.state == SlotState.owned &&
            entry.owner == over.instance &&
            !space.busy.containsKey(s) &&
            !drainBackingOff(space, s, over.instance) &&
            (slot == null || s < slot)) {
          slot = s;
        }
      }
      if (slot == null) {
        continue;
      }
      _log.info(
        'rebalancing ${space.type}: slot $slot from ${over.address} to '
        '${under.address}',
      );
      space.queue.add(_Migration(slot, under.instance, null));
      pumpMigrations(space);
      return;
    }
  }

  // ---------------------------------------------------------------------
  // ASSIGN backoff

  /// Whether [instance] is in its backoff for [slot]: it failed an `ASSIGN`
  /// of the slot recently, and the allocator, `LOCATE` and rebalancing do
  /// not offer it the slot until the backoff ends.
  bool backingOff(_Space space, int slot, int instance) =>
      space.backoffs[instance]?[slot]?.timer != null;

  /// [target] failed an `ASSIGN` of [slot]: starts its backoff for the slot,
  /// [NamingService.assignBackoff] the first time, doubled at every further
  /// failure up to [NamingService.assignBackoffMax]. When it ends, the
  /// allocator runs and `LOCATE` requests waiting for the slot look again.
  /// Nothing is kept for an instance that went down (it starts afresh if
  /// it comes back).
  void assignFailed(_Space space, int slot, _Registration target) {
    final delay = _startBackoff(
      space,
      space.backoffs,
      slot,
      target,
      onStart: () => space.cooling.update(
        target.instance,
        (n) => n + 1,
        ifAbsent: () => 1,
      ),
      onEnd: () {
        space.cooled(target.instance);
        space.wake(slot);
      },
    );
    if (delay != null) {
      _log.info(
        '${target.address} not offered ${space.type}/$slot again for $delay',
      );
    }
  }

  /// Starts or extends the backoff of [target] for [slot] in [backoffs]:
  /// [NamingService.assignBackoff] the first time, doubled at every
  /// further failure up to [NamingService.assignBackoffMax]. [onStart]
  /// runs when no backoff was running, [onEnd] when it ends; then the
  /// allocator runs. Returns the delay, or null when nothing is kept (the
  /// service is closed, or [target] went down).
  Duration? _startBackoff(
    _Space space,
    Map<int, Map<int, _Backoff>> backoffs,
    int slot,
    _Registration target, {
    void Function()? onStart,
    void Function()? onEnd,
  }) {
    if (closed || !target.up) {
      return null;
    }
    final backoff = backoffs
        .putIfAbsent(target.instance, () => {})
        .putIfAbsent(slot, _Backoff.new);
    final previous = backoff.delay;
    final doubled = previous == null ? service.assignBackoff : previous * 2;
    final delay = doubled > service.assignBackoffMax
        ? service.assignBackoffMax
        : doubled;
    backoff.delay = delay;
    final running = backoff.timer;
    if (running != null) {
      running.cancel();
    } else {
      onStart?.call();
    }
    backoff.timer = Timer(delay, () {
      backoff.timer = null;
      onEnd?.call();
      scheduleBalance(space);
    });
    return delay;
  }

  /// Whether the allocator leaves [slot] with its owner [instance] for
  /// now: the owner refused or failed a `DRAIN` of it recently.
  bool drainBackingOff(_Space space, int slot, int instance) =>
      space.drainBackoffs[instance]?[slot]?.timer != null;

  /// [from] refused or failed a `DRAIN` of [slot]: the allocator does not
  /// try to move the slot away from it again until its backoff ends, with
  /// the same intervals as the `ASSIGN` backoff.
  void drainFailed(_Space space, int slot, _Registration from) {
    final delay = _startBackoff(space, space.drainBackoffs, slot, from);
    if (delay != null) {
      _log.info(
        '${space.type}/$slot not moved away from ${from.address} again for '
        '$delay',
      );
    }
  }

  /// [instance] drained [slot]: its `DRAIN` backoff for the slot is over.
  void drainSucceeded(_Space space, int slot, int instance) {
    final bySlot = space.drainBackoffs[instance];
    final backoff = bySlot?.remove(slot);
    if (backoff == null) {
      return;
    }
    if (bySlot!.isEmpty) {
      space.drainBackoffs.remove(instance);
    }
    backoff.timer?.cancel();
  }

  /// [instance] accepted an `ASSIGN` of [slot]: its backoff for the slot is
  /// over and starts again from [NamingService.assignBackoff].
  void assignSucceeded(_Space space, int slot, int instance) {
    final bySlot = space.backoffs[instance];
    final backoff = bySlot?.remove(slot);
    if (backoff == null) {
      return;
    }
    if (bySlot!.isEmpty) {
      space.backoffs.remove(instance);
    }
    final timer = backoff.timer;
    if (timer != null) {
      timer.cancel();
      space.cooled(instance);
    }
  }

  // ---------------------------------------------------------------------
  // Settling after SLOTS

  /// Opens ([open]) or extends the settle window of [space].
  ///
  /// After a naming service restart the holders of free slots are only
  /// known again from `HOLDING`, which an instance sends after `SLOTS`. If
  /// the allocator assigned the free slots without a holder as soon as
  /// `SLOTS` gave an instance capacity, a slot whose storage that instance
  /// (or another one coming back) is about to declare would go elsewhere
  /// or start fresh. So a `SLOTS` with capacity opens a window in which
  /// the allocator leaves those slots alone; every `SLOTS`, `HOLDING` or
  /// `CLAIM` of the type extends it, so that a burst of returning instances
  /// keeps it open until it goes quiet for [NamingService.holdingSettle],
  /// but at most 5 times [NamingService.assignmentHold] (at least
  /// [NamingService.holdingSettle]) after it opened. Slots with a known
  /// holder still go back to it, and `LOCATE` (an explicit demand) still
  /// assigns.
  void settle(_Space space, {bool open = false}) {
    final quiet = service.holdingSettle;
    if (closed || quiet == Duration.zero) {
      return;
    }
    if (space.settleQuiet == null) {
      // Only eager spaces assign slots without a holder on their own.
      if (!open || space.space.mode != SlotMode.managed || space.space.lazy) {
        return;
      }
      final atMost = service.assignmentHold * 5;
      space.settleBound = Timer(
        atMost > quiet ? atMost : quiet,
        () => _settled(space),
      );
      _log.fine('${space.type}: waiting for HOLDING before assigning');
    }
    space.settleQuiet?.cancel();
    space.settleQuiet = Timer(quiet, () => _settled(space));
  }

  void _settled(_Space space) {
    space.stopSettling();
    scheduleBalance(space);
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
    space.dropBackoffs(registration.instance);
    space.wakeAll();
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
    for (final timer in _deadlines) {
      timer.cancel();
    }
    _deadlines.clear();
    for (final space in spaces.values) {
      for (final timer in space.grace.values) {
        timer.cancel();
      }
      space.grace.clear();
      space.clearBackoffs();
      space.stopSettling();
      space.wakeAll();
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

  /// `ASSIGN` backoffs by instance, then slot (see
  /// `_SlotManager.assignFailed`), and the number of running ones per
  /// instance.
  final Map<int, Map<int, _Backoff>> backoffs = {};
  final Map<int, int> cooling = {};

  /// `DRAIN` backoffs by owner, then slot (see `_SlotManager.drainFailed`).
  final Map<int, Map<int, _Backoff>> drainBackoffs = {};

  /// `LOCATE` requests waiting for a slot to change, by slot.
  final Map<int, Completer<void>> _wakers = {};

  /// The settle window after `SLOTS` (see `_SlotManager.settle`): open
  /// while [settleQuiet] runs; [settleBound] ends it at the latest.
  Timer? settleQuiet;
  Timer? settleBound;

  bool get settling => settleQuiet != null;

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
    clearBackoffs();
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

  /// Completes when [wake] is called for [slot] (or [wakeAll]).
  Future<void> changeOf(int slot) =>
      _wakers.putIfAbsent(slot, Completer<void>.new).future;

  void wake(int slot) => _wakers.remove(slot)?.complete();

  void wakeAll() {
    final wakers = _wakers.values.toList();
    _wakers.clear();
    for (final waker in wakers) {
      waker.complete();
    }
  }

  /// A backoff of [instance] ended.
  void cooled(int instance) {
    final n = cooling[instance]! - 1;
    if (n == 0) {
      cooling.remove(instance);
    } else {
      cooling[instance] = n;
    }
  }

  /// Forgets the backoffs of [instance] (it went down).
  void dropBackoffs(int instance) {
    cooling.remove(instance);
    for (final map in [backoffs, drainBackoffs]) {
      for (final backoff in map.remove(instance)?.values ?? <_Backoff>[]) {
        backoff.timer?.cancel();
      }
    }
  }

  void clearBackoffs() {
    for (final instance in {...backoffs.keys, ...drainBackoffs.keys}) {
      dropBackoffs(instance);
    }
  }

  void stopSettling() {
    settleQuiet?.cancel();
    settleQuiet = null;
    settleBound?.cancel();
    settleBound = null;
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

/// The `ASSIGN` backoff of one instance for one slot.
class _Backoff {
  /// The length of the last backoff; null before the first failure.
  Duration? delay;

  /// Runs while the instance is not offered the slot.
  Timer? timer;
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
