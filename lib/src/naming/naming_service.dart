/*
Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Author: Jan Boon <jan.boon@kaetemi.be>
*/

import 'dart:async';
import 'dart:collection';
import 'dart:math';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:meta/meta.dart';

import '../address/service_address.dart';
import '../monotonic.dart';
import '../name.dart';
import '../status.dart';
import '../switchboard/incoming_channel.dart';
import '../talk/talk_channel.dart';
import '../talk/talk_message.dart';
import '../talk/talk_request.dart';
import 'naming_protocol.dart';
import 'slot_table.dart';

part 'naming_service_slots.dart';

final Logger _log = Logger('Switchboard.Naming');

/// The naming service (`_ns`): hands out instance ids, keeps the
/// authoritative table of live service instances, and pushes changes to
/// the channels subscribed to them. See the wiki page "Switchboard Naming
/// Service".
///
/// The service speaks Talk over channels handed to [serve], one per client.
/// A registration is owned by the channel it was made on; when that channel
/// closes for any reason, every record it owns is removed and `DOWN` is
/// published for each. This is the only liveness mechanism. A record
/// carries the liveness of the channel that made it, not of the endpoint
/// it names: one channel may register many records for endpoints that
/// never talk to the naming service (a registrar, such as a scaler
/// registering its workers), and then retires them itself (`UNREGSTR`, or
/// closing the channel); see the wiki section "Registering on behalf of
/// others".
///
/// Procedures: `REGISTER`, `UNREGSTR`, `WATCH`, `UNWATCH` (requests),
/// `LOOKUP` (stream request), and for sharding `SLOTS`, `HOLDING`, `CLAIM`,
/// `RELEASE`, `LOCATE` (requests) and `MIGRATE` (stream request). Requests
/// for any other procedure are answered with `ABORT UNIMPLEMENTED`; plain
/// messages are ignored. Malformed payloads are answered with
/// `ABORT INVALID_ARGUMENT`.
///
/// Subscriptions: `WATCH` sends the snapshot of the matching records and
/// slot spaces as one-way events (`UP`, then `SLOTSPC` and `SLOT`), then
/// its reply, and subscribes the channel; from then on every change is
/// sent to it as an event (`UP`, `DOWN`, `SLOTSPC`, `SLOT`), at most once
/// per channel however many of its subscriptions match. A subscription is
/// per channel and type filter and counts the `WATCH`es that hold it:
/// `UNWATCH` with the same filter gives one back, the last one ends it,
/// and every subscription of a channel ends when the channel closes. There
/// is no heartbeat: a watcher detects a lost naming service through its
/// connection (mux keep-alive).
///
/// Sharding (wiki page "Switchboard Sharding"): the service keeps a slot
/// table per sharded type ([slotTables]), publishes it to watchers as
/// `SLOTSPC` and `SLOT` events, assigns the slots of managed spaces, and
/// orchestrates hand-overs by sending `ASSIGN`, `DRAIN`, `FORWARD` and
/// `RESUME` to instances over their registration channels. The instance
/// serving the slots of a type on a channel is the channel's registration
/// of that type; a channel registering several instances of a sharded type
/// cannot use the slot procedures for it. During [assignmentHold] slot
/// assignment waits too: `CLAIM`s are collected and resolved when the hold
/// ends (higher claimed epoch first, then the earlier claim), `HOLDING`
/// declarations are answered after them, and `LOCATE` of a free slot, the
/// allocator and migrations wait. After a restart this lets the instances
/// that were serving slots reclaim them before anything else is decided.
///
/// A request that waits (for the end of the hold, an `ASSIGN`, a step of a
/// migration, a backoff) is sent one `EXTEND` declaring how long the wait
/// can last when it starts waiting, and another whenever that changes: a
/// hand-over step starts, or the instance working on it declares a
/// deadline of its own. Nothing is sent from a timer. The service's own
/// responder timeout is off for such requests, since it answers each of
/// them when what it waits for ends.
///
/// The service registers nothing by itself. The wiki registers the naming
/// service in its own table as `_ns/1`; the host does that with
/// [registerLocal] once it knows its listening endpoints. Hosting it on a
/// `Switchboard` node:
///
/// ```dart
/// final ns = NamingService();
/// switchboard.registerService(Services.naming, ns.handler, instance: 1);
/// await switchboard.listenTcp(address, port);
/// ns.registerLocal(
///   Services.naming,
///   switchboard.listeningEndpoints,
///   instance: 1,
/// );
/// ```
class NamingService {
  /// Creates an empty service.
  ///
  /// [assignmentHold] is how long, counted from construction, a `REGISTER`
  /// that asks for any id (instance 0) waits before it is answered. After a
  /// naming service restart ids are assigned from 1 again, while surviving
  /// services reconnect asking for the ids they had; holding assignments
  /// for a moment lets them reclaim those ids before a fresh registration
  /// can take one (which would move the surviving service to a new id, see
  /// `NamingClient.register`). Requests for a specific id, [registerLocal]
  /// and everything else are served at once. A held request is sent one
  /// `EXTEND` declaring the time left in the hold as its deadline.
  /// [Duration.zero] disables the hold.
  ///
  /// [holderGrace] is how long a free slot of a holder-only managed space
  /// waits for its holder to come back after the holder went down; then the
  /// slot is reassigned with its holder cleared (it starts fresh).
  ///
  /// [handoverTimeout] is the requester timeout of the requests the service
  /// sends to instances (`ASSIGN`, `DRAIN`, `FORWARD`, `RESUME`): the gap
  /// that applies until the instance declares a deadline or a renewal with
  /// `EXTEND` (an empty `EXTEND` restarts it). [Duration.zero] disables it.
  ///
  /// [handoverMaxDuration] bounds an `ASSIGN` or `DRAIN` overall, whatever
  /// the instance declares: one still running after it is cancelled (Talk
  /// cancel with `DEADLINE_EXCEEDED`) and handled as a failure, so that a
  /// hung load or drain cannot keep a slot locked or busy forever. A
  /// migration is then rolled back with `RESUME`; an instance whose
  /// `ASSIGN` timed out enters its `ASSIGN` backoff. It is the requester's
  /// clamp of the deadlines instances declare for hand-over requests, and
  /// of those the service passes on to the requests waiting for them.
  /// [Duration.zero] removes the bound.
  ///
  /// [maxSlotCount] bounds the slot count of a space; `SLOTS` with more is
  /// refused with `OUT_OF_RANGE`.
  ///
  /// [assignBackoff] and [assignBackoffMax] pace the `ASSIGN`s of a slot to
  /// an instance that refused it (an instance answers `ABORT UNAVAILABLE`
  /// until it is ready) or failed it: after a failure the instance is not
  /// offered that slot again, by the allocator, `LOCATE` or a rebalancing
  /// migration, for [assignBackoff], doubled at every further failure up to
  /// [assignBackoffMax], and back to [assignBackoff] after the instance
  /// accepts it. Other instances with capacity take the slot meanwhile.
  /// While an instance is in its backoff for any slot of a space, the
  /// allocator moves no owned slot of that space to it. `CLAIM` and a
  /// `MIGRATE` to a given instance are explicit and not held back.
  ///
  /// The same backoff, per slot and owner, paces the rebalancing
  /// migrations of a slot whose owner refused or failed its `DRAIN`: the
  /// allocator does not try to move that slot away from that owner again
  /// until it ends.
  ///
  /// [holdingSettle] protects the storage of instances returning after a
  /// naming service restart, which only `HOLDING` makes known again: after
  /// a `SLOTS` that gives an instance capacity, the allocator leaves the
  /// free slots without a holder of that space alone until no `SLOTS`,
  /// `HOLDING` or `CLAIM` of the type has arrived for [holdingSettle], and
  /// at most for 5 times [assignmentHold] (but at least [holdingSettle]).
  /// Slots with a known holder still go back to it, and `LOCATE` still
  /// assigns. [Duration.zero] disables it.
  ///
  /// [resumeAttempts] bounds the `RESUME` of a rolled-back migration,
  /// which the old owner needs to unlock the slot: one that fails (refused,
  /// or not answered within [handoverTimeout]) is sent again once a backoff
  /// per slot and owner ends, with the intervals of the `ASSIGN` backoff,
  /// as long as the slot stays with that owner. After [resumeAttempts]
  /// failures in a row the slot is set free with its holder kept, and the
  /// old owner enters its `ASSIGN` backoff for it, so that the allocator
  /// places it elsewhere first.
  ///
  /// Throws [ArgumentError] if [assignBackoff] is not positive, if
  /// [assignBackoffMax] is shorter than [assignBackoff], if
  /// [assignmentHold], [holderGrace], [handoverTimeout],
  /// [handoverMaxDuration] or [holdingSettle] is negative, or if
  /// [maxSlotCount] or [resumeAttempts] is not positive.
  NamingService({
    this.assignmentHold = const Duration(seconds: 2),
    this.holderGrace = const Duration(minutes: 5),
    this.handoverTimeout = const Duration(seconds: 60),
    this.maxSlotCount = 65536,
    this.assignBackoff = const Duration(milliseconds: 200),
    this.assignBackoffMax = const Duration(seconds: 10),
    this.holdingSettle = const Duration(seconds: 1),
    this.handoverMaxDuration = const Duration(minutes: 10),
    this.resumeAttempts = 5,
  }) {
    if (assignBackoff <= Duration.zero) {
      throw ArgumentError.value(
        assignBackoff,
        'assignBackoff',
        'must be positive',
      );
    }
    if (assignBackoffMax < assignBackoff) {
      throw ArgumentError.value(
        assignBackoffMax,
        'assignBackoffMax',
        'must not be shorter than assignBackoff',
      );
    }
    for (final (name, value) in [
      ('assignmentHold', assignmentHold),
      ('holderGrace', holderGrace),
      ('handoverTimeout', handoverTimeout),
      ('handoverMaxDuration', handoverMaxDuration),
      ('holdingSettle', holdingSettle),
    ]) {
      if (value < Duration.zero) {
        throw ArgumentError.value(value, name, 'must not be negative');
      }
    }
    if (maxSlotCount < 1 || maxSlotCount > maxU32) {
      throw ArgumentError.value(maxSlotCount, 'maxSlotCount', 'out of range');
    }
    if (resumeAttempts < 1) {
      throw ArgumentError.value(
        resumeAttempts,
        'resumeAttempts',
        'must be positive',
      );
    }
    if (assignmentHold > Duration.zero) {
      _holdEnd = monotonicNow() + assignmentHold;
      _holdTimer = Timer(assignmentHold, _endHold);
    }
  }

  /// Largest number of subscriptions (distinct type filters) one channel
  /// may hold; a `WATCH` that would open one more is answered
  /// `ABORT RESOURCE_EXHAUSTED`.
  static const int maxWatchesPerChannel = 1024;

  /// How long after construction `REGISTER` requests for any id are held,
  /// and slot assignment waits for claims.
  final Duration assignmentHold;

  /// How long a holder-only slot waits for its holder to return.
  final Duration holderGrace;

  /// Requester timeout of the requests sent to instances.
  final Duration handoverTimeout;

  /// Largest slot count of a space.
  final int maxSlotCount;

  /// How long an instance that failed an `ASSIGN` of a slot is not offered
  /// that slot again, the first time.
  final Duration assignBackoff;

  /// The longest [assignBackoff] grows to with repeated failures.
  final Duration assignBackoffMax;

  /// Longest an `ASSIGN` or `DRAIN` may run, whatever the instance
  /// declares, before it is cancelled and handled as failed;
  /// [Duration.zero] for no bound.
  final Duration handoverMaxDuration;

  /// How long the allocator waits for `HOLDING` after a `SLOTS` with
  /// capacity before it assigns free slots that have no holder.
  final Duration holdingSettle;

  /// How many times the `RESUME` of a rolled-back migration is sent before
  /// its slot is set free.
  final int resumeAttempts;

  late final _SlotManager _slots = _SlotManager(this);

  final Map<ServiceAddress, ServiceRecord> _table = {};
  final Map<int, _Registration> _instances = {};
  final Set<_Session> _sessions = {};

  /// Sessions with at least one subscription.
  final Set<_Session> _watching = {};
  final StreamController<ServiceEvent> _events =
      StreamController<ServiceEvent>.broadcast();
  int _nextInstance = 1;
  bool _closed = false;
  Future<void>? _closeFuture;

  /// Runs while assignments are held.
  Timer? _holdTimer;

  /// When the hold ends ([monotonicNow]).
  Duration _holdEnd = Duration.zero;

  /// The time left in the assignment hold.
  Duration get _holdLeft {
    final left = _holdEnd - monotonicNow();
    return left.isNegative ? Duration.zero : left;
  }

  final List<_Held> _held = [];

  /// Read-only live view of the table: every registered record by address.
  late final Map<ServiceAddress, ServiceRecord> table = UnmodifiableMapView(
    _table,
  );

  /// Every `UP` and `DOWN` the service publishes, in order. Broadcast
  /// stream; it ends when the service is closed.
  Stream<ServiceEvent> get events => _events.stream;

  /// Number of subscriptions over all channels: one per channel and type
  /// filter, however many `WATCH`es hold it.
  int get watchCount {
    var count = 0;
    for (final session in _watching) {
      count += session.watches.length;
    }
    return count;
  }

  /// Read-only live view of the slot tables, by type. A redefinition of a
  /// space replaces its [SlotTable].
  late final Map<Name, SlotTable> slotTables = UnmodifiableMapView(
    _slots.views,
  );

  /// The slot table of [type], or null if it has no slot space.
  SlotTable? slotTable(Name type) => _slots.views[type];

  /// Every `SLOT` event the service publishes, in order. Broadcast stream;
  /// it ends when the service is closed.
  Stream<SlotItem> get slotEvents => _slots.events.stream;

  /// Number of channels currently served.
  int get channelCount => _sessions.length;

  /// True while `REGISTER` requests for any id are held; see
  /// [assignmentHold].
  bool get isHoldingAssignments => _holdTimer != null;

  /// The id the next assignment tries first. Ids in use are skipped.
  @visibleForTesting
  int get nextInstance => _nextInstance;

  @visibleForTesting
  set nextInstance(int id) {
    if (id < 1 || id > maxInstance) {
      throw RangeError.range(id, 1, maxInstance, 'id');
    }
    _nextInstance = id;
  }

  /// A [ChannelHandler] that serves every incoming channel: it wraps the
  /// channel with [IncomingChannel.talk] (the node's talk options) and
  /// passes it to [serve].
  ///
  /// Register it for `_ns/1` on the hosting node, together with the
  /// matching local record (see the class documentation):
  ///
  /// ```dart
  /// switchboard.registerService(Services.naming, ns.handler, instance: 1);
  /// ns.registerLocal(Services.naming, endpoints, instance: 1);
  /// ```
  ///
  /// Channels addressed to `_ns` with any instance (0), as
  /// `namingClientFor` opens them, reach it too: it is the first registered
  /// instance of the type.
  ChannelHandler get handler => _handle;

  void _handle(IncomingChannel incoming) => serve(incoming.talk());

  /// Serves one client over [channel] until it closes. Registrations made
  /// on this channel are removed, with `DOWN` events, when it closes.
  ///
  /// Takes over [TalkChannel.messages], so each channel can be served only
  /// once: throws [StateError] if its messages are already listened to, in
  /// which case the service keeps nothing of it. The channel keeps its own
  /// options. After [close] the channel is closed immediately with
  /// [StatusCode.goingAway].
  void serve(TalkChannel channel) {
    if (_closed) {
      unawaited(
        channel.close(Status.of(StatusCode.goingAway, 'naming service closed')),
      );
      return;
    }
    final session = _Session(channel);
    // Listen before keeping the session: if the stream is taken already,
    // this throws and nothing is left behind.
    session.subscription = channel.messages.listen(
      (message) => _onMessage(session, message),
      onError: (Object error) =>
          _log.fine('naming client channel failed: $error'),
      onDone: () => _drop(session),
    );
    _sessions.add(session);
    unawaited(channel.done.then((_) => _drop(session)));
  }

  /// Registers a record owned by the service itself rather than by a
  /// channel, for example `_ns/1` with the service's own endpoints. It stays
  /// until [unregisterLocal]; registering the same address locally again
  /// replaces its endpoints and [metadata] (`UP` if either changed).
  ///
  /// [instance] 0 assigns an id, at once ([assignmentHold] does not apply).
  /// [metadata] (copied; null is empty) is published with the record, see
  /// [ServiceRecord.metadata]. Returns the instance id. Throws
  /// [SwitchboardException] with [StatusCode.invalidArgument] for an empty
  /// type, [StatusCode.alreadyExists] if [instance] is in use by another
  /// registration, [StatusCode.resourceExhausted] if no id is left, and
  /// [StatusCode.failedPrecondition] after [close]; also
  /// [StatusCode.invalidArgument] for more than 255 endpoints, an endpoint
  /// that [ServiceRecord.checkEndpoint] refuses, or metadata longer than
  /// [maxMetadataLength]. Throws [RangeError] for an instance outside the
  /// `u48` range.
  int registerLocal(
    Name type,
    List<Uri> endpoints, {
    int instance = 0,
    Uint8List? metadata,
  }) {
    if (_closed) {
      throw SwitchboardException.of(
        StatusCode.failedPrecondition,
        'naming service closed',
      );
    }
    if (instance < 0 || instance > maxInstance) {
      throw RangeError.range(instance, 0, maxInstance, 'instance');
    }
    return _add(
      type,
      instance,
      endpoints,
      metadata == null ? Uint8List(0) : Uint8List.fromList(metadata),
      null,
    );
  }

  /// Removes a record made with [registerLocal] and publishes `DOWN`.
  ///
  /// Throws [SwitchboardException] with [StatusCode.notFound] if there is no
  /// such record and [StatusCode.permissionDenied] if it is owned by a
  /// channel.
  void unregisterLocal(ServiceAddress address) {
    final registration = _lookup(address.type, address.instance);
    if (registration.owner != null) {
      throw SwitchboardException.of(
        StatusCode.permissionDenied,
        '$address is owned by a channel',
      );
    }
    _remove(registration);
  }

  /// Ends every subscription, aborts every held `REGISTER` with
  /// [StatusCode.goingAway], removes the records of every channel
  /// (publishing `DOWN` on [events], not to the channels), closes the
  /// channels with [StatusCode.goingAway], and ends [events]. Records made
  /// with [registerLocal] stay in [table]. No timer is left running.
  /// Calling it again returns the same future.
  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    _closed = true;
    final goingAway = Status.of(StatusCode.goingAway, 'naming service closed');
    _slots.close();
    _holdTimer?.cancel();
    _holdTimer = null;
    final held = List.of(_held);
    _held.clear();
    for (final h in held) {
      if (h.message.canReply) {
        _abort(h.message, goingAway);
      }
    }
    for (final session in _watching.toList()) {
      _endWatches(session);
    }
    final sessions = _sessions.toList();
    for (final session in sessions) {
      _drop(session);
    }
    await Future.wait([
      for (final session in sessions) session.channel.close(goingAway),
    ]);
    await _events.close();
    await _slots.events.close();
  }

  // ---------------------------------------------------------------------
  // Dispatch

  void _onMessage(_Session session, TalkMessage message) {
    if (!session.active) {
      return;
    }
    final procedure = message.procedure;
    if (!message.expectsReply) {
      _log.fine('ignoring plain message ${message.procedureName}');
      return;
    }
    if (procedure == Procedures.register) {
      _onRegister(session, message);
    } else if (procedure == Procedures.unregister) {
      _onUnregister(session, message);
    } else if (procedure == Procedures.watch) {
      _onWatch(session, message);
    } else if (procedure == Procedures.unwatch) {
      _onUnwatch(session, message);
    } else if (procedure == Procedures.lookup) {
      _onLookup(message);
    } else if (procedure == Procedures.slots) {
      _slots.onSlots(session, message);
    } else if (procedure == Procedures.holding) {
      _slots.onHolding(session, message);
    } else if (procedure == Procedures.claim) {
      _slots.onClaim(session, message);
    } else if (procedure == Procedures.release) {
      _slots.onRelease(session, message);
    } else if (procedure == Procedures.locate) {
      _slots.onLocate(message);
    } else if (procedure == Procedures.migrate) {
      _slots.onMigrate(message);
    } else {
      _log.fine('unknown procedure ${message.procedureName}');
      _abort(
        message,
        Status.of(
          StatusCode.unimplemented,
          'unknown procedure ${message.procedureName}',
        ),
      );
    }
  }

  void _onRegister(_Session session, TalkMessage message) {
    final RegisterRequest request;
    try {
      request = RegisterRequest.decode(message.payload);
      _check(request.type, request.endpoints, request.metadata);
    } on ProtocolException catch (e) {
      _abort(message, Status.of(StatusCode.invalidArgument, e.status.reason));
      return;
    } on SwitchboardException catch (e) {
      _abort(message, e.status);
      return;
    }
    if (request.requestedInstance == 0 && _holdTimer != null) {
      _hold(session, message, request);
      return;
    }
    _register(session, message, request);
  }

  void _register(
    _Session session,
    TalkMessage message,
    RegisterRequest request,
  ) {
    final int instance;
    try {
      instance = _add(
        request.type,
        request.requestedInstance,
        request.endpoints,
        request.metadata,
        session,
      );
    } on SwitchboardException catch (e) {
      _abort(message, e.status);
      return;
    }
    _reply(message, RegisterResponse(instance).encode());
  }

  void _onUnregister(_Session session, TalkMessage message) {
    final UnregisterRequest request;
    try {
      request = UnregisterRequest.decode(message.payload);
    } on ProtocolException catch (e) {
      _abort(message, Status.of(StatusCode.invalidArgument, e.status.reason));
      return;
    }
    try {
      final registration = _lookup(request.type, request.instance);
      if (!identical(registration.owner, session)) {
        throw SwitchboardException.of(
          StatusCode.permissionDenied,
          '${registration.address} is owned by another channel',
        );
      }
      _remove(registration);
    } on SwitchboardException catch (e) {
      _abort(message, e.status);
      return;
    }
    _reply(message, Uint8List(0));
  }

  /// The payload of a `WATCH` or `UNWATCH`, or null once [message] is
  /// answered `INVALID_ARGUMENT` (malformed, or sent as a stream request).
  static WatchRequest? _subscriptionRequest(TalkMessage message) {
    if (message.expectsStream) {
      _abort(
        message,
        Status.of(
          StatusCode.invalidArgument,
          '${message.procedureName} is not a stream request',
        ),
      );
      return null;
    }
    try {
      return WatchRequest.decode(message.payload);
    } on ProtocolException catch (e) {
      _abort(message, Status.of(StatusCode.invalidArgument, e.status.reason));
      return null;
    }
  }

  void _onWatch(_Session session, TalkMessage message) {
    final request = _subscriptionRequest(message);
    if (request == null) {
      return;
    }
    final type = request.type;
    final count = session.watches[type];
    if (count == null && session.watches.length >= maxWatchesPerChannel) {
      _abort(
        message,
        Status.of(
          StatusCode.resourceExhausted,
          'more than $maxWatchesPerChannel subscriptions on one channel',
        ),
      );
      return;
    }
    bool matches(Name recordType) => type == null || type == recordType;
    // Snapshot, reply and subscription happen in one synchronous step: a
    // change is either in the snapshot or sent after the reply.
    for (final record in _table.values) {
      if (matches(record.address.type) &&
          !session.send(Procedures.up, record.encode())) {
        return;
      }
    }
    for (final (procedure, payload) in _slots.snapshot(matches)) {
      if (!session.send(procedure, payload)) {
        return;
      }
    }
    try {
      message.reply(Uint8List(0));
    } on SwitchboardException catch (e) {
      _log.fine('WATCH reply failed: $e');
      return;
    }
    session.watches[type] = (count ?? 0) + 1;
    _watching.add(session);
    _log.fine('watch ${type ?? '*'}: ${count ?? 0} -> ${(count ?? 0) + 1}');
  }

  void _onUnwatch(_Session session, TalkMessage message) {
    final request = _subscriptionRequest(message);
    if (request == null) {
      return;
    }
    final type = request.type;
    final count = session.watches[type];
    if (count == null) {
      _abort(
        message,
        Status.of(
          StatusCode.notFound,
          'no subscription to ${type ?? 'every type'} on this channel',
        ),
      );
      return;
    }
    // Ended before the reply: no event for it follows the reply.
    if (count > 1) {
      session.watches[type] = count - 1;
    } else {
      session.watches.remove(type);
      if (session.watches.isEmpty) {
        _watching.remove(session);
      }
    }
    _log.fine('watch ${type ?? '*'}: $count -> ${count - 1}');
    _reply(message, Uint8List(0));
  }

  /// Ends every subscription of [session].
  void _endWatches(_Session session) {
    session.watches.clear();
    _watching.remove(session);
  }

  void _onLookup(TalkMessage message) {
    if (!message.expectsStream) {
      _abort(
        message,
        Status.of(StatusCode.invalidArgument, 'LOOKUP is a stream request'),
      );
      return;
    }
    final Name? type;
    try {
      type = WatchRequest.decode(message.payload).type;
    } on ProtocolException catch (e) {
      _abort(message, Status.of(StatusCode.invalidArgument, e.status.reason));
      return;
    }
    if (type == null) {
      _abort(
        message,
        Status.of(StatusCode.invalidArgument, 'LOOKUP needs a type'),
      );
      return;
    }
    try {
      for (final record in _table.values) {
        if (record.address.type == type) {
          message.replyItem(
            record.encode(),
            procedure: Procedures.up.toString(),
          );
        }
      }
      for (final (procedure, payload) in _slots.snapshot((t) => t == type)) {
        message.replyItem(payload, procedure: procedure.toString());
      }
      message.reply(Uint8List(0));
    } on SwitchboardException catch (e) {
      _log.fine('LOOKUP reply failed: $e');
    }
  }

  // ---------------------------------------------------------------------
  // Assignment hold

  /// Keeps a `REGISTER` for any id until the hold ends, declaring the time
  /// left in the hold as its deadline with one `EXTEND`. If the requester
  /// cancels it meanwhile, it is answered `CANCELLED` and never registered.
  void _hold(_Session session, TalkMessage message, RegisterRequest request) {
    final held = _Held(session, message, request);
    _held.add(held);
    _log.fine(
      'holding REGISTER ${request.type} until the assignment hold ends',
    );
    _slots.declare(message, _holdLeft);
    unawaited(
      message.onCancel.then((_) {
        if (_held.remove(held)) {
          _abort(message, Status.of(StatusCode.cancelled, 'cancelled'));
        }
      }),
    );
  }

  /// Answers the held requests, in arrival order.
  void _endHold() {
    _holdTimer = null;
    final held = List.of(_held);
    _held.clear();
    if (held.isNotEmpty) {
      _log.info('assignment hold over, assigning ${held.length} held ids');
    }
    for (final h in held) {
      if (h.session.active && h.message.canReply && !h.message.isCancelled) {
        _register(h.session, h.message, h.request);
      }
    }
    _slots.onHoldEnded();
  }

  // ---------------------------------------------------------------------
  // Table

  /// Throws [SwitchboardException] with [StatusCode.invalidArgument] unless
  /// a record of [type] with [endpoints] and [metadata] can be stored and
  /// published: every watcher must be able to decode what the service
  /// accepts, or every later snapshot would fail.
  static void _check(Name type, List<Uri> endpoints, Uint8List metadata) {
    if (type.isEmpty) {
      throw SwitchboardException.of(
        StatusCode.invalidArgument,
        'empty service type',
      );
    }
    if (endpoints.length > 255) {
      throw SwitchboardException.of(
        StatusCode.invalidArgument,
        'more than 255 endpoints',
      );
    }
    if (metadata.length > maxMetadataLength) {
      throw SwitchboardException.of(
        StatusCode.invalidArgument,
        'metadata longer than $maxMetadataLength bytes',
      );
    }
    for (final endpoint in endpoints) {
      try {
        ServiceRecord.checkEndpoint(endpoint);
      } on ArgumentError catch (e) {
        throw SwitchboardException.of(
          StatusCode.invalidArgument,
          'invalid endpoint: ${e.message}',
        );
      }
    }
  }

  /// Adds or replaces a registration and publishes `UP` (for a replacement
  /// only if the endpoints or the metadata changed). [owner] null is a
  /// local registration.
  int _add(
    Name type,
    int requested,
    List<Uri> endpoints,
    Uint8List metadata,
    _Session? owner,
  ) {
    _check(type, endpoints, metadata);
    final ServiceAddress address;
    if (requested != 0) {
      final existing = _instances[requested];
      if (existing != null) {
        if (!identical(existing.owner, owner) ||
            existing.address.type != type) {
          throw SwitchboardException.of(
            StatusCode.alreadyExists,
            'instance ${requested.toRadixString(16)} is in use by '
            '${existing.address}',
          );
        }
        final record = ServiceRecord(
          existing.address,
          endpoints: List.unmodifiable(endpoints),
          metadata: metadata,
        );
        if (_table[existing.address] != record) {
          _log.info('re-registered $record');
          _table[existing.address] = record;
          _publish(ServiceEvent(up: true, record: record));
        }
        return requested;
      }
      address = ServiceAddress(type, requested);
    } else {
      address = ServiceAddress(type, _allocate());
    }
    final record = ServiceRecord(
      address,
      endpoints: List.unmodifiable(endpoints),
      metadata: metadata,
    );
    final registration = _Registration(address, owner);
    _instances[address.instance] = registration;
    owner?.owned.add(registration);
    _table[address] = record;
    _log.info('registered $record');
    _publish(ServiceEvent(up: true, record: record));
    return address.instance;
  }

  /// The next free instance id: increasing from 1, wrapping at the `u48`
  /// limit, skipping ids in use.
  int _allocate() {
    if (_instances.length >= maxInstance) {
      throw SwitchboardException.of(
        StatusCode.resourceExhausted,
        'no instance ids left',
      );
    }
    var id = _nextInstance;
    while (_instances.containsKey(id)) {
      id = id >= maxInstance ? 1 : id + 1;
    }
    _nextInstance = id >= maxInstance ? 1 : id + 1;
    return id;
  }

  _Registration _lookup(Name type, int instance) {
    final registration = _instances[instance];
    if (registration == null || registration.address.type != type) {
      final address = ServiceAddress(type, instance);
      throw SwitchboardException.of(
        StatusCode.notFound,
        'no registration $address',
      );
    }
    return registration;
  }

  void _remove(_Registration registration) {
    final address = registration.address;
    _instances.remove(address.instance);
    _table.remove(address);
    registration.owner?.owned.remove(registration);
    registration.removed = true;
    _log.info('unregistered $address');
    _publish(ServiceEvent(up: false, record: ServiceRecord(address)));
    _slots.onDown(registration);
  }

  /// Sends an event about [type] to every channel subscribed to it, once
  /// per channel. A channel that no longer takes events loses its
  /// subscriptions (it is closing, and dropped when it has closed).
  void _publishItem(Name type, Name procedure, Uint8List payload) {
    for (final session in _watching.toList()) {
      if (session.watchesType(type) && !session.send(procedure, payload)) {
        _endWatches(session);
      }
    }
  }

  void _publish(ServiceEvent event) {
    if (_watching.isNotEmpty) {
      _publishItem(event.record.address.type, event.procedure, event.encode());
    }
    if (!_events.isClosed) {
      _events.add(event);
    }
  }

  /// Forgets a channel: ends its subscriptions and removes its records.
  /// Idempotent.
  void _drop(_Session session) {
    if (!_sessions.remove(session)) {
      return;
    }
    session.active = false;
    _held.removeWhere((h) => identical(h.session, session));
    _endWatches(session);
    final owned = session.owned.toList();
    if (owned.isNotEmpty) {
      _log.info('naming client channel closed, removing ${owned.length}');
    }
    for (final registration in owned) {
      _remove(registration);
    }
    session.cancel();
  }

  // ---------------------------------------------------------------------
  // Replies

  static void _reply(TalkMessage message, Uint8List payload) {
    try {
      message.reply(payload);
    } on SwitchboardException catch (e) {
      _log.fine('reply to ${message.procedureName} failed: $e');
    }
  }

  static void _abort(TalkMessage message, Status status) {
    try {
      message.replyAbort(status);
    } on SwitchboardException catch (e) {
      _log.fine('abort of ${message.procedureName} failed: $e');
    }
  }
}

/// One served channel.
class _Session {
  _Session(this.channel);

  final TalkChannel channel;
  final Set<_Registration> owned = {};

  /// Subscriptions: the number of `WATCH`es holding each type filter (null:
  /// every type).
  final Map<Name?, int> watches = {};
  StreamSubscription<TalkMessage>? subscription;
  bool active = true;

  /// Whether a subscription of this channel covers [type].
  bool watchesType(Name type) =>
      watches.containsKey(null) || watches.containsKey(type);

  /// Sends one event. Returns false if the channel no longer takes any.
  bool send(Name procedure, Uint8List payload) {
    try {
      channel.send(procedure.toString(), payload, name: procedure);
      return true;
    } on SwitchboardException catch (e) {
      _log.fine('$procedure event not sent: $e');
      return false;
    }
  }

  /// Stops listening to the channel.
  void cancel() {
    subscription?.cancel().ignore();
    subscription = null;
  }
}

/// A `REGISTER` for any id waiting for the assignment hold to end.
class _Held {
  _Held(this.session, this.message, this.request);

  final _Session session;
  final TalkMessage message;
  final RegisterRequest request;
}

/// A record in the table and the channel that owns it (null: local).
class _Registration {
  _Registration(this.address, this.owner);

  final ServiceAddress address;
  final _Session? owner;

  /// Share weight in the slot space of its type, from `SLOTS`: 0 takes no
  /// slots, null until the instance sent `SLOTS`.
  int? capacity;

  /// [capacity], 0 when not declared.
  int get weight => capacity ?? 0;

  /// Removed from the table.
  bool removed = false;

  /// Called once when the registration is removed.
  final Set<void Function()> onGone = {};

  int get instance => address.instance;

  /// Registered on a channel that is still served.
  bool get up => !removed && (owner?.active ?? false);
}
