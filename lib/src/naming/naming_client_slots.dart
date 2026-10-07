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

/// One request from the naming service to a sharded instance (`ASSIGN`,
/// `DRAIN`, `FORWARD` or `RESUME`), as its [SlotHandler] method sees it.
///
/// The naming service waits for the answer its `handoverTimeout` (60 s by
/// default), unless the handler declares an estimate with [extend]. Nothing
/// is sent on the handler's behalf while it runs: a load or a drain that
/// may take longer declares how long, at the steps where it knows (the
/// state transfer started, a phase completed, the estimate changed).
abstract class SlotRequestContext {
  /// The slot's type.
  Name get type;

  /// The slot.
  int get slot;

  /// The epoch the request carries: for `ASSIGN`, `DRAIN` and `FORWARD`
  /// the slot's epoch at its new owner, for `RESUME` its current one.
  int get epoch;

  /// True once the request is cancelled: the naming service gave up on it
  /// (its timeout, its bound, a cancel), the handler ran past its declared
  /// deadline or [NamingClient.slotHandlerMaxDuration], the channel to the
  /// naming service ended, or the client closed. Work on it should stop;
  /// its outcome is ignored.
  bool get isCancelled;

  /// Completes when [isCancelled] becomes true; never if the request is
  /// answered first. A load can abort the query it waits for on it.
  Future<void> get onCancel;

  /// Declares how long the work may still take, with one `EXTEND` (see
  /// `TalkMessage.extend`): the answer comes within [deadline] from now
  /// and, with [renew], within [renew] of the last declaration. The naming
  /// service then waits that long (plus `TalkOptions.extendBuffer`),
  /// instead of its default timeout, and passes the estimate on to whoever
  /// waits for the hand-over (the `MIGRATE` requester, a `LOCATE`). This
  /// instance gives up at the declared time itself: the request is
  /// answered `ABORT DEADLINE_EXCEEDED` and [onCancel] completes. A later
  /// call replaces the estimate, and may shorten it.
  ///
  /// The values are lowered to what is left of
  /// [NamingClient.slotHandlerMaxDuration]. With neither value, sends an
  /// empty `EXTEND`, which restarts the naming service's default timeout.
  /// Does nothing (logged at FINE) once the request can no longer be
  /// answered. Throws [ArgumentError] for a negative value.
  void extend({Duration? deadline, Duration? renew});
}

/// Serves the requests the naming service sends to a sharded instance over
/// its registration channel. Set it with [NamingClient.slotHandler]. See
/// the wiki page "Switchboard Sharding", section "Requests from the naming
/// service to instances".
///
/// Each method receives the request's [SlotRequestContext], through which
/// a slow handler declares how long it may take; the naming service waits
/// its `handoverTimeout` otherwise. The client sends nothing on the
/// handler's behalf while it runs. It bounds a handler call to
/// [NamingClient.slotHandlerMaxDuration] (then it answers
/// `ABORT DEADLINE_EXCEEDED` and ignores the handler's late outcome),
/// answers the request when the returned future completes, and answers
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
  Future<AssignResult> onAssign(
    AssignRequest request,
    SlotRequestContext context,
  );

  /// Lock the slot: queue new work for it, let work in flight complete, and
  /// make its state available to [DrainRequest.to] (transfer it or flush it
  /// to shared storage). Complete once nothing is in flight and the state
  /// is flushed. The slot stays locked until [onForward] or [onResume].
  Future<void> onDrain(DrainRequest request, SlotRequestContext context);

  /// The new owner serves: forward the queued work to [ForwardRequest.to]
  /// and keep forwarding late arrivals for a grace period, then answer
  /// `MOVED`. Complete once the queue has been handed over. The slot is no
  /// longer served by this instance.
  Future<void> onForward(ForwardRequest request, SlotRequestContext context);

  /// The migration was abandoned, or the naming service was lost while the
  /// slot was locked: unlock and serve the queued work. Must be idempotent:
  /// it may come for a slot that was never locked, after a `DRAIN` that
  /// failed.
  Future<void> onResume(ResumeRequest request, SlotRequestContext context);

  /// This instance must stop serving [slot] of [type]: its claim was
  /// refused after a reconnect (another instance owns it), or an `ASSIGN`
  /// it accepted could not be confirmed (or ran longer than
  /// [NamingClient.slotHandlerMaxDuration]). The default does nothing.
  Future<void> onRevoke(Name type, int slot) async {}

  /// A `HOLDING` response listed [slots] of [type] as no longer held by
  /// this instance (their holder is another instance now, or they are
  /// outside the space): their local storage should be discarded. Called
  /// for every `HOLDING` response with a non-empty list, those of
  /// [NamingClient.declareHolding] and those the client sends again after
  /// a reconnect, before the [NamingClient.declareHolding] future
  /// completes. The default does nothing.
  void onDiscard(Name type, List<int> slots) {}
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
    final _SlotContext context;
    try {
      context = _SlotContext.of(message, client.slotHandlerMaxDuration);
    } on ProtocolException catch (e) {
      _abort(message, Status.of(StatusCode.invalidArgument, e.status.reason));
      return;
    }
    // Loading or draining a slot may take long, as long as the handler
    // declares (context.extend); the naming service waits its own timeout
    // otherwise. No default gap here: this side gives up at a declared
    // deadline, and after slotHandlerMaxDuration in any case.
    message.setReplyTimeout(client.slotHandlerMaxDuration);
    final bound = client.slotHandlerMaxDuration;
    final deadline = bound > Duration.zero
        ? Timer(bound, () {
            if (message.canReply) {
              _log.warning(
                '${message.procedureName} handler still running after '
                '$bound; answered DEADLINE_EXCEEDED',
              );
              _abort(
                message,
                Status.of(
                  StatusCode.deadlineExceeded,
                  'slot handler ran longer than $bound',
                ),
              );
            }
            context._cancel();
          })
        : null;
    void stop() {
      deadline?.cancel();
    }

    // A request that can no longer be answered (the channel closed, the
    // client too) needs no timer.
    context.onCancel.then((_) => stop()).ignore();
    unawaited(_serve(session, message, handler, context).whenComplete(stop));
  }

  Future<void> _serve(
    _Session session,
    TalkMessage message,
    SlotHandler handler,
    _SlotContext context,
  ) async {
    final procedure = message.procedure;
    try {
      if (procedure == Procedures.assign) {
        await _assign(session, message, handler, context);
      } else if (procedure == Procedures.drain) {
        await _drain(message, handler, context);
      } else if (procedure == Procedures.forward) {
        final request = ForwardRequest.decode(message.payload);
        draining.remove((request.type, request.slot));
        served[request.type]?.remove(request.slot);
        await handler.onForward(request, context);
        _reply(message);
      } else {
        final request = ResumeRequest.decode(message.payload);
        draining.remove((request.type, request.slot));
        await handler.onResume(request, context);
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
    _SlotContext context,
  ) async {
    final request = AssignRequest.decode(message.payload);
    final type = request.type;
    final slot = request.slot;
    final result = await handler.onAssign(request, context);
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

  Future<void> _drain(
    TalkMessage message,
    SlotHandler handler,
    _SlotContext context,
  ) async {
    final request = DrainRequest.decode(message.payload);
    final key = (request.type, request.slot);
    final drained = Completer<void>();
    draining[key] = _Draining(
      served[request.type]?[request.slot]?.epoch ?? 0,
      drained.future,
    );
    try {
      await handler.onDrain(request, context);
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

  /// The channel to the naming service was lost, or the client closed:
  /// every locked slot is unlocked and served (as `RESUME`), once its
  /// `DRAIN` handler is done.
  void onLost() {
    final locked = Map.of(draining);
    draining.clear();
    final handler = this.handler;
    if (handler == null) {
      return;
    }
    for (final MapEntry(key: (type, slot), value: lock) in locked.entries) {
      _log.info(
        '${client._closed ? 'naming client closed' : 'naming service lost'} '
        'while $type/$slot was draining, resuming',
      );
      unawaited(
        lock.drained
            .then(
              (_) => handler.onResume(
                ResumeRequest(type, slot, epoch: lock.epoch),
                _SlotContext.local(type, slot, lock.epoch),
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
  /// `SLOTS` and `HOLDING`, then a `CLAIM` of every slot this instance
  /// serves, pipelined (all in the same turn). Waits for the registration
  /// of [type] on [session] if this client registers that type. Without
  /// any registration of it (a router or an operator tool) only `SLOTS` is
  /// sent, and the `HOLDING` of the [declareHolding] calls waiting to be
  /// sent, which the naming service refuses.
  ///
  /// The `HOLDING` also lists the served slots whose storage this instance
  /// holds. It is a single request, so it reaches a restarted naming
  /// service within its assignment hold even when the claims (sent a
  /// window at a time) do not; the service then gives those slots back to
  /// this instance as their holder instead of assigning them fresh.
  ///
  /// `HOLDING` goes first when the mirror, synced on [session], shows the
  /// space as defined: the holders are then known before `SLOTS` gives
  /// this instance capacity, so the allocator never sees those slots
  /// without their holder. Otherwise (after a reconnect the mirror is not
  /// synced yet, and a restarted naming service may not know the space, so
  /// `HOLDING` would fail) `SLOTS` goes first, with `HOLDING` right behind
  /// it; the naming service's settle window after `SLOTS` covers the gap
  /// (`NamingService.holdingSettle`).
  ///
  /// A request refused before it was sent (the channel's
  /// `TalkOptions.maxOutgoingRequests`) stops the restoration there, so
  /// that nothing overtakes it, and [_retry] resumes it later without
  /// sending again what went out. [type] counts as restored on [session]
  /// once everything went out.
  void restore(_Session session, Name type) {
    if (!session.usable || session.retrying.contains(type)) {
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
    final definition = definitions[type];
    bool slots() {
      final sent = session.sentSlots[type];
      if (definition == null ||
          (sent != null &&
              identical(sent.$1, definition) &&
              sent.$2 == registered)) {
        return true;
      }
      return _sendSlots(session, definition);
    }

    final bool sent;
    if (!registered) {
      sent = slots() && _flushHolding(session, type, const {});
    } else {
      final declared = holdings[type];
      final bySlot = served[type];
      final held = {
        ...?declared?.slots,
        for (final MapEntry(key: slot, value: state)
            in (bySlot ?? const <int, _Served>{}).entries)
          if (state.holding) slot,
      };
      final declare =
          (declared?.pending.isNotEmpty ?? false) ||
          (held.isNotEmpty && !session.sentHolding.contains(type));
      bool holding() {
        if (!declare) {
          return true;
        }
        if (!_flushHolding(session, type, held)) {
          return false;
        }
        session.sentHolding.add(type);
        return true;
      }

      final holdingFirst =
          declare &&
          definition != null &&
          !session.syncing &&
          mirrors[type]?.space == definition.request.space;
      sent = holdingFirst ? holding() && slots() : slots() && holding();
      if (sent && session.reclaimed.add(type) && bySlot != null) {
        for (final MapEntry(key: slot, value: state) in bySlot.entries) {
          session.reclaims.add((type, slot, state));
        }
        _pumpReclaims(session);
      }
    }
    if (sent) {
      session.restored[type] = registered;
    } else {
      _retry(session, type);
    }
  }

  /// A request restoring [type] on [session] was refused before it was
  /// sent: [type] is not restored there, and [restore] sends the rest after
  /// [NamingClient.reconnectDelay], again until it all went out. Nothing is
  /// left of it when the session is lost: the next one restores everything.
  void _retry(_Session session, Name type) {
    session.restored.remove(type);
    if (!session.usable || !session.retrying.add(type)) {
      return;
    }
    final delay = client.reconnectDelay;
    _log.info('slot state of $type not sent yet, retrying in $delay');
    session.later(delay, () {
      session.retrying.remove(type);
      restore(session, type);
    });
  }

  /// Sends queued claims of served slots, at most [_reclaimWindow] at a
  /// time. Claims beyond the window that reach a freshly restarted naming
  /// service after its assignment hold are served first come, first
  /// served rather than by epoch.
  void _pumpReclaims(_Session session) {
    while (!session.reclaimsPaused &&
        session.reclaiming < _reclaimWindow &&
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

  /// A claim was refused before it was sent: the claims left wait
  /// [NamingClient.reconnectDelay], in order.
  void _pauseReclaims(_Session session) {
    if (session.reclaimsPaused) {
      return;
    }
    session.reclaimsPaused = true;
    final delay = client.reconnectDelay;
    _log.info('claims of served slots not sent yet, retrying in $delay');
    session.later(delay, () {
      session.reclaimsPaused = false;
      _pumpReclaims(session);
    });
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

  /// Sends [definition] on [session]. Returns false if the request was
  /// refused before it was sent.
  bool _sendSlots(_Session session, _SpaceDefinition definition) {
    final type = definition.request.space.type;
    final Future<TalkMessage> response;
    try {
      response = session.channel.request(
        Procedures.slots.toString(),
        definition.request.encode(),
      );
    } on SwitchboardException catch (e) {
      _log.fine('SLOTS $type not sent: $e');
      return false;
    }
    session.sentSlots[type] = (definition, client._registeredOn(session, type));
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
    return true;
  }

  /// Sends one `HOLDING` of [type] on [session] for [slots] and the
  /// [declareHolding] calls waiting to be sent, unless both are empty.
  /// Returns false if the request was refused before it was sent; the
  /// calls then wait for the next attempt.
  bool _flushHolding(_Session session, Name type, Set<int> slots) {
    final declared = holdings[type];
    final pending = List.of(declared?.pending ?? const <_PendingHolding>[]);
    declared?.pending.clear();
    if (slots.isEmpty && pending.isEmpty) {
      return true;
    }
    return _sendHolding(
      session,
      type,
      {...slots, for (final p in pending) ...p.slots}.toList()..sort(),
      pending,
    );
  }

  /// Sends `HOLDING` of [slots] of [type] on [session], answering
  /// [pending]. Returns false if the request was refused before it was
  /// sent; [pending] then waits for the next attempt.
  bool _sendHolding(
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
      holdings[type]?.pending.insertAll(0, pending);
      return false;
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
        final handler = this.handler;
        if (discard.isNotEmpty && handler != null) {
          try {
            handler.onDiscard(type, List.unmodifiable(discard));
          } on Object catch (e, st) {
            _log.warning('onDiscard $type failed', e, st);
          }
        }
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
    return true;
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
      if (session.usable) {
        // Refused before it was sent (the request limit): first in line
        // when the claims go on.
        session.reclaims.addFirst((type, slot, state));
        _pauseReclaims(session);
      }
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
      if (session.restored[type] == null) {
        // Sent with the rest of the slot state of the type.
        restore(session, type);
      } else if (!_sendSlots(session, definition)) {
        _retry(session, type);
      }
    }
    return definition.completer.future;
  }

  Future<List<int>> declareHolding(Name type, List<int> slots) {
    final declared = holdings.putIfAbsent(type, _Holdings.new);
    declared.slots.addAll(slots);
    final pending = _PendingHolding(slots.toSet());
    final session = client._session;
    if (session == null || !_ready(session, type)) {
      // Sent with the slot state of the type, after the next connect or
      // once its registration is back.
      declared.pending.add(pending);
    } else if (session.restored[type] == null) {
      declared.pending.add(pending);
      restore(session, type);
    } else if (!_sendHolding(session, type, slots, [pending])) {
      _retry(session, type);
    }
    return pending.completer.future;
  }

  /// Sends a request of the client's slot API on [session] and returns
  /// its response. The channel's request limit
  /// (`TalkOptions.maxOutgoingRequests`) never fails it: a request the
  /// channel refuses for it waits here, with the requests made after it,
  /// and goes out once one of these requests completes, or after
  /// [NamingClient.reconnectDelay] when none is in flight (other requests
  /// hold the limit). Waiting requests fail with [StatusCode.unavailable]
  /// when the channel is lost.
  Future<TalkMessage> call(_Session session, Name procedure, Uint8List data) {
    final call = _Call(procedure, data);
    session.calls.add(call);
    _pumpCalls(session);
    return call.completer.future;
  }

  void _pumpCalls(_Session session) {
    while (session.calls.isNotEmpty && !session.callsPaused) {
      final call = session.calls.first;
      final Future<TalkMessage> response;
      try {
        response = session.channel.request(
          call.procedure.toString(),
          call.payload,
        );
      } on SwitchboardException catch (e) {
        if (e.code == StatusCode.resourceExhausted && session.usable) {
          if (session.calling == 0) {
            // Nothing of these to wait for: try again later.
            session.callsPaused = true;
            session.later(client.reconnectDelay, () {
              session.callsPaused = false;
              _pumpCalls(session);
            });
          }
          return;
        }
        session.calls.removeFirst();
        call.completer.completeError(e);
        continue;
      }
      session.calls.removeFirst();
      session.calling++;
      unawaited(
        response
            .then(
              call.completer.complete,
              onError: call.completer.completeError,
            )
            .whenComplete(() {
              session.calling--;
              _pumpCalls(session);
            }),
      );
    }
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
    final response = await call(
      session,
      Procedures.claim,
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
    await call(
      session,
      Procedures.release,
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
    final response = await call(
      session,
      Procedures.locate,
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
      _log.warning('SLOT event outside any known space: $item');
      return;
    }
    if (session.syncing) {
      session.seenSlots.add((item.type, item.slot));
    }
    _set(mirror, item.slot, item.entry);
  }

  /// On the `WATCH` reply: spaces and slots missing from the snapshot are
  /// gone.
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

/// A request of the client's slot API waiting for the channel to take it.
class _Call {
  _Call(this.procedure, this.payload);

  final Name procedure;
  final Uint8List payload;
  final Completer<TalkMessage> completer = Completer<TalkMessage>();
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
/// The [SlotRequestContext] of one request from the naming service, or of
/// a resume the client makes by itself ([_SlotContext.local]).
class _SlotContext implements SlotRequestContext {
  _SlotContext._(this.message, this.type, this.slot, this.epoch, this.bound)
    : _started = monotonicNow() {
    message?.onCancel.then((_) => _cancel()).ignore();
  }

  /// The context of a resume the client makes without a request (the
  /// naming service was lost): nothing to answer, nothing to extend.
  _SlotContext.local(this.type, this.slot, this.epoch)
    : message = null,
      bound = Duration.zero,
      _started = monotonicNow();

  /// The context of [message], whose payload starts with the slot's type
  /// and slot and carries its epoch. Throws [ProtocolException] for a
  /// malformed payload.
  factory _SlotContext.of(TalkMessage message, Duration bound) {
    final procedure = message.procedure;
    final payload = message.payload;
    if (procedure == Procedures.assign) {
      final r = AssignRequest.decode(payload);
      return _SlotContext._(message, r.type, r.slot, r.epoch, bound);
    }
    if (procedure == Procedures.drain) {
      final r = DrainRequest.decode(payload);
      return _SlotContext._(message, r.type, r.slot, r.epoch, bound);
    }
    if (procedure == Procedures.forward) {
      final r = ForwardRequest.decode(payload);
      return _SlotContext._(message, r.type, r.slot, r.epoch, bound);
    }
    final r = ResumeRequest.decode(payload);
    return _SlotContext._(message, r.type, r.slot, r.epoch, bound);
  }

  /// The request; null for a local resume.
  final TalkMessage? message;

  @override
  final Name type;

  @override
  final int slot;

  @override
  final int epoch;

  /// [NamingClient.slotHandlerMaxDuration]; zero for no bound.
  final Duration bound;
  final Duration _started;
  final Completer<void> _cancelled = Completer<void>();

  void _cancel() {
    if (!_cancelled.isCompleted) {
      _cancelled.complete();
    }
  }

  @override
  bool get isCancelled => _cancelled.isCompleted;

  @override
  Future<void> get onCancel => _cancelled.future;

  @override
  void extend({Duration? deadline, Duration? renew}) {
    for (final (name, value) in [('deadline', deadline), ('renew', renew)]) {
      if (value != null && value.isNegative) {
        throw ArgumentError.value(value, name, 'must not be negative');
      }
    }
    final message = this.message;
    if (message == null || !message.canReply) {
      _log.fine(
        '${message?.procedureName ?? 'local RESUME'} $type/$slot can no '
        'longer be answered; not extended',
      );
      return;
    }
    if (bound > Duration.zero) {
      var left = bound - (monotonicNow() - _started);
      if (left.isNegative) {
        left = Duration.zero;
      }
      if (deadline != null && deadline > left) {
        deadline = left;
      }
      if (renew != null && renew > left) {
        renew = left;
      }
    }
    try {
      message.extend(deadline: deadline, renew: renew);
    } on SwitchboardException catch (e) {
      _log.fine('${message.procedureName} $type/$slot not extended: $e');
    }
  }
}

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
