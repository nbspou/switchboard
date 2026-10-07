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
/// watchers. See the wiki page "Switchboard Naming Service".
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
/// Procedures: `REGISTER`, `UNREGSTR` (requests), `WATCH`, `LOOKUP` (stream
/// requests), and for sharding `SLOTS`, `HOLDING`, `CLAIM`, `RELEASE`,
/// `LOCATE` (requests) and `MIGRATE` (stream request). Requests for any
/// other procedure are answered with `ABORT UNIMPLEMENTED`; plain messages
/// are ignored. Malformed payloads are answered with
/// `ABORT INVALID_ARGUMENT`.
///
/// Sharding (wiki page "Switchboard Sharding"): the service keeps a slot
/// table per sharded type ([slotTables]), publishes it to watchers as
/// `SLOTSPC` and `SLOT` items, assigns the slots of managed spaces, and
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
  /// [heartbeat] is the interval at which an idle watch is sent `EXTEND`.
  /// It must be shorter than the [TalkOptions.replyTimeout] of every channel
  /// passed to [serve] (10 s by default), otherwise the responder timeout of
  /// the channel aborts the watch with `DEADLINE_EXCEEDED`; it must also be
  /// shorter than the watcher's request timeout. The wiki requires `EXTEND`
  /// at least every 5 s on an idle watch. A timer never fires early but
  /// often fires late (event loop latency, load), so a 5 s heartbeat would
  /// regularly overshoot that bound; the default of 4 s leaves a second of
  /// margin.
  ///
  /// [assignmentHold] is how long, counted from construction, a `REGISTER`
  /// that asks for any id (instance 0) waits before it is answered. After a
  /// naming service restart ids are assigned from 1 again, while surviving
  /// services reconnect asking for the ids they had; holding assignments
  /// for a moment lets them reclaim those ids before a fresh registration
  /// can take one (which would move the surviving service to a new id, see
  /// `NamingClient.register`). Requests for a specific id, [registerLocal]
  /// and everything else are served at once. Held requests are kept alive
  /// with `EXTEND` every [heartbeat]. [Duration.zero] disables the hold.
  ///
  /// [holderGrace] is how long a free slot of a holder-only managed space
  /// waits for its holder to come back after the holder went down; then the
  /// slot is reassigned with its holder cleared (it starts fresh).
  ///
  /// [handoverTimeout] is the requester timeout of the requests the service
  /// sends to instances (`ASSIGN`, `DRAIN`, `FORWARD`, `RESUME`); every
  /// `EXTEND` from the instance restarts it. [Duration.zero] disables it.
  ///
  /// [handoverMaxDuration] bounds an `ASSIGN` or `DRAIN` overall, whatever
  /// the `EXTEND`s: one still running after it is cancelled (Talk cancel
  /// with `DEADLINE_EXCEEDED`) and handled as a failure, so that a hung
  /// load or drain cannot keep a slot locked or busy forever. A migration
  /// is then rolled back with `RESUME`; an instance whose `ASSIGN` timed
  /// out enters its `ASSIGN` backoff. [Duration.zero] removes the bound.
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
  /// Throws [ArgumentError] if [heartbeat] or [assignBackoff] is not
  /// positive, if [assignBackoffMax] is shorter than [assignBackoff], if
  /// [assignmentHold], [holderGrace], [handoverTimeout],
  /// [handoverMaxDuration] or [holdingSettle] is negative, or if
  /// [maxSlotCount] is not positive.
  NamingService({
    this.heartbeat = const Duration(seconds: 4),
    this.assignmentHold = const Duration(seconds: 2),
    this.holderGrace = const Duration(minutes: 5),
    this.handoverTimeout = const Duration(seconds: 60),
    this.maxSlotCount = 65536,
    this.assignBackoff = const Duration(milliseconds: 200),
    this.assignBackoffMax = const Duration(seconds: 10),
    this.holdingSettle = const Duration(seconds: 1),
    this.handoverMaxDuration = const Duration(minutes: 10),
  }) {
    if (heartbeat <= Duration.zero) {
      throw ArgumentError.value(heartbeat, 'heartbeat', 'must be positive');
    }
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
    if (assignmentHold > Duration.zero) {
      _holdTimer = Timer(assignmentHold, _endHold);
    }
  }

  /// Interval at which an idle watch is sent `EXTEND`.
  final Duration heartbeat;

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

  /// Longest an `ASSIGN` or `DRAIN` may run, `EXTEND`s or not, before it
  /// is cancelled and handled as failed; [Duration.zero] for no bound.
  final Duration handoverMaxDuration;

  /// How long the allocator waits for `HOLDING` after a `SLOTS` with
  /// capacity before it assigns free slots that have no holder.
  final Duration holdingSettle;

  late final _SlotManager _slots = _SlotManager(this);

  final Map<ServiceAddress, ServiceRecord> _table = {};
  final Map<int, _Registration> _instances = {};
  final Set<_Session> _sessions = {};
  final Set<_Watch> _watches = {};
  final StreamController<ServiceEvent> _events =
      StreamController<ServiceEvent>.broadcast();
  int _nextInstance = 1;
  bool _closed = false;
  Future<void>? _closeFuture;

  /// Runs while assignments are held.
  Timer? _holdTimer;

  /// Extends the held requests while there are any.
  Timer? _heldHeartbeat;
  final List<_Held> _held = [];

  /// Read-only live view of the table: every registered record by address.
  late final Map<ServiceAddress, ServiceRecord> table = UnmodifiableMapView(
    _table,
  );

  /// Every `UP` and `DOWN` the service publishes, in order. Broadcast
  /// stream; it ends when the service is closed.
  Stream<ServiceEvent> get events => _events.stream;

  /// Number of outstanding `WATCH` requests over all channels.
  int get watchCount => _watches.length;

  /// Read-only live view of the slot tables, by type. A redefinition of a
  /// space replaces its [SlotTable].
  late final Map<Name, SlotTable> slotTables = UnmodifiableMapView(
    _slots.views,
  );

  /// The slot table of [type], or null if it has no slot space.
  SlotTable? slotTable(Name type) => _slots.views[type];

  /// Every `SLOT` item the service publishes, in order. Broadcast stream;
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
  /// instance of the type. Mind the [heartbeat] constraint on the node's
  /// [TalkOptions.replyTimeout].
  ChannelHandler get handler => _handle;

  void _handle(IncomingChannel incoming) => serve(incoming.talk());

  /// Serves one client over [channel] until it closes. Registrations made
  /// on this channel are removed, with `DOWN` events, when it closes.
  ///
  /// Takes over [TalkChannel.messages], so each channel can be served only
  /// once: throws [StateError] if its messages are already listened to, in
  /// which case the service keeps nothing of it. The channel keeps its own
  /// options; see [heartbeat] for the constraint on
  /// [TalkOptions.replyTimeout]. After [close] the channel is closed
  /// immediately with [StatusCode.goingAway].
  void serve(TalkChannel channel) {
    if (_closed) {
      unawaited(
        channel.close(Status.of(StatusCode.goingAway, 'naming service closed')),
      );
      return;
    }
    final replyTimeout = channel.options.replyTimeout;
    if (replyTimeout > Duration.zero && heartbeat >= replyTimeout) {
      _log.warning(
        'heartbeat $heartbeat is not shorter than the channel reply timeout '
        '$replyTimeout; watches on this channel will be aborted',
      );
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

  /// Aborts every watch and every held `REGISTER` with
  /// [StatusCode.goingAway], removes the records of every channel
  /// (publishing `DOWN`), closes the channels with [StatusCode.goingAway],
  /// and ends [events]. Records made with [registerLocal] stay in [table].
  /// No timer is left running. Calling it again returns the same future.
  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    _closed = true;
    final goingAway = Status.of(StatusCode.goingAway, 'naming service closed');
    _slots.close();
    _holdTimer?.cancel();
    _holdTimer = null;
    _heldHeartbeat?.cancel();
    _heldHeartbeat = null;
    final held = List.of(_held);
    _held.clear();
    for (final h in held) {
      if (h.message.canReply) {
        _abort(h.message, goingAway);
      }
    }
    for (final watch in _watches.toList()) {
      watch.end(goingAway);
    }
    _watches.clear();
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

  void _onWatch(_Session session, TalkMessage message) {
    if (!message.expectsStream) {
      _abort(
        message,
        Status.of(StatusCode.invalidArgument, 'WATCH is a stream request'),
      );
      return;
    }
    final WatchRequest request;
    try {
      request = WatchRequest.decode(message.payload);
    } on ProtocolException catch (e) {
      _abort(message, Status.of(StatusCode.invalidArgument, e.status.reason));
      return;
    }
    final watch = _Watch(this, session, message, request.type);
    // Snapshot, SYNCED and registration happen in one synchronous step, so
    // no change can fall between the snapshot and the live items.
    for (final record in _table.values) {
      if (watch.matches(record.address.type) &&
          !watch.send(Procedures.up, record.encode())) {
        return;
      }
    }
    for (final (procedure, payload) in _slots.snapshot(watch.matches)) {
      if (!watch.send(procedure, payload)) {
        return;
      }
    }
    if (!watch.send(Procedures.synced, Uint8List(0))) {
      return;
    }
    _watches.add(watch);
    session.watches.add(watch);
    _log.fine('watch ${request.type ?? '*'} started');
    unawaited(message.onCancel.then((_) => _onWatchCancelled(watch)));
  }

  void _onWatchCancelled(_Watch watch) {
    if (!_watches.remove(watch)) {
      return;
    }
    watch.session.watches.remove(watch);
    _log.fine('watch ${watch.type ?? '*'} cancelled');
    watch.end(Status.of(StatusCode.cancelled, 'watch cancelled'));
  }

  /// Called by a watch whose channel refused an item.
  void _onWatchFailed(_Watch watch) {
    _watches.remove(watch);
    watch.session.watches.remove(watch);
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

  /// Keeps a `REGISTER` for any id until the hold ends. If the requester
  /// cancels it meanwhile, it is answered `CANCELLED` and never registered.
  void _hold(_Session session, TalkMessage message, RegisterRequest request) {
    final held = _Held(session, message, request);
    _held.add(held);
    _log.fine(
      'holding REGISTER ${request.type} until the assignment hold ends',
    );
    unawaited(
      message.onCancel.then((_) {
        if (_held.remove(held)) {
          _abort(message, Status.of(StatusCode.cancelled, 'cancelled'));
        }
      }),
    );
    _heldHeartbeat ??= Timer.periodic(heartbeat, (_) {
      for (final h in _held) {
        if (h.message.canReply) {
          try {
            h.message.extend();
          } on SwitchboardException catch (e) {
            _log.fine('held REGISTER not extended: $e');
          }
        }
      }
    });
  }

  /// Answers the held requests, in arrival order.
  void _endHold() {
    _holdTimer = null;
    _heldHeartbeat?.cancel();
    _heldHeartbeat = null;
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

  /// Sends a watch item about [type] to every watch of it.
  void _publishItem(Name type, Name procedure, Uint8List payload) {
    for (final watch in _watches.toList()) {
      if (watch.matches(type)) {
        watch.send(procedure, payload);
      }
    }
  }

  void _publish(ServiceEvent event) {
    final procedure = event.procedure;
    final payload = event.encode();
    for (final watch in _watches.toList()) {
      if (watch.matches(event.record.address.type)) {
        watch.send(procedure, payload);
      }
    }
    if (!_events.isClosed) {
      _events.add(event);
    }
  }

  /// Forgets a channel: stops its watches and removes its records.
  /// Idempotent.
  void _drop(_Session session) {
    if (!_sessions.remove(session)) {
      return;
    }
    session.active = false;
    _held.removeWhere((h) => identical(h.session, session));
    if (_held.isEmpty) {
      _heldHeartbeat?.cancel();
      _heldHeartbeat = null;
    }
    for (final watch in session.watches) {
      _watches.remove(watch);
      watch.stop();
    }
    session.watches.clear();
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
  final Set<_Watch> watches = {};
  StreamSubscription<TalkMessage>? subscription;
  bool active = true;

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

/// One outstanding `WATCH` request.
class _Watch {
  _Watch(this.service, this.session, this.message, this.type);

  final NamingService service;
  final _Session session;
  final TalkMessage message;

  /// The watched type, or null for all.
  final Name? type;
  Timer? _timer;

  bool matches(Name recordType) => type == null || type == recordType;

  /// Sends one item and restarts the heartbeat. On failure the watch is
  /// dropped and false is returned.
  bool send(Name procedure, Uint8List payload) {
    try {
      message.replyItem(payload, procedure: procedure.toString());
    } on SwitchboardException catch (e) {
      _log.fine('watch item not sent: $e');
      _fail();
      return false;
    }
    _arm();
    return true;
  }

  void _arm() {
    _timer?.cancel();
    _timer = Timer(service.heartbeat, _beat);
  }

  void _beat() {
    _timer = null;
    try {
      message.extend();
    } on SwitchboardException catch (e) {
      _log.fine('watch heartbeat not sent: $e');
      _fail();
      return;
    }
    _arm();
  }

  void _fail() {
    stop();
    service._onWatchFailed(this);
  }

  /// Stops the heartbeat.
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Stops the heartbeat and sends the final abort, if still possible.
  void end(Status status) {
    stop();
    if (message.canReply) {
      NamingService._abort(message, status);
    }
  }
}
