/*
Polyverse Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Authors:
  Jan Boon <jan.boon@kaetemi.be>
  Claude Opus 5.5 <noreply@anthropic.com>
*/

import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:logging/logging.dart';

import '../address/service_address.dart';
import '../identity/credential.dart';
import '../monotonic.dart';
import '../name.dart';
import '../status.dart';
import '../talk/talk_channel.dart';
import '../talk/talk_message.dart';
import '../talk/talk_request.dart';
import '../talk/talk_stream.dart';
import 'naming_protocol.dart';
import 'slot_table.dart';

part 'naming_client_slots.dart';

final Logger _log = Logger('Switchboard.Naming');

/// Opens a fresh Talk channel to the naming service.
typedef TalkConnector = Future<TalkChannel> Function();

/// Serves a `CONNECT` the naming service relays to this instance over the
/// client's channel: dial [DialBackRequest.endpoint], identify there with
/// [DialBackRequest.intent] naming [DialBackRequest.requester] as the
/// receiver, and complete once that identification is confirmed. A
/// failure, whatever it is, is answered `ABORT UNAVAILABLE` (wiki page
/// "Switchboard Identity and Credentials", "Reverse connections"); its
/// cause goes to the log. `MeshNode` installs one (see
/// [NamingClient.connectHandler]).
typedef ConnectHandler = Future<void> Function(DialBackRequest request);

/// A client of the naming service: registers this process's services and
/// mirrors the service table through a `WATCH` subscription.
///
/// The client keeps one channel to the naming service. On every connect it
/// first re-registers the services registered through it (asking for the
/// ids they had), then subscribes to every type with `WATCH` and rebuilds
/// [table] from the snapshot: the events that arrive before the `WATCH`
/// reply are the snapshot, the reply marks the table synced, and the
/// events after it are live. The client keeps that single subscription to
/// every type for the life of the channel; it never sends `UNWATCH`.
///
/// The client sends no heartbeat and expects none: the subscription lives
/// as long as the channel, and a naming service that stops answering is
/// detected by the connection under the channel (the mux keep-alive of a
/// `Switchboard` node, see `MuxOptions.keepAliveInterval`), which then
/// ends the channel. When the channel is lost (it ends, or the `WATCH`
/// request fails or times out) the client marks the table stale, keeps
/// it, and reconnects after [reconnectDelay], until [close].
///
/// When a `REGISTER` or `UNREGSTR` has no clear outcome (no answer in time,
/// or an unreadable answer) the client drops the channel itself: the naming
/// service then discards everything registered on it, and the reconnect
/// registers the remembered set again. Neither a phantom record nor an
/// untracked one is left behind.
///
/// Sharding (wiki page "Polyverse Switchboard Sharding"): the client mirrors the slot
/// tables too ([slotTables], [slotEvents]), and a sharded instance uses
/// [defineSlots], [declareHolding], [claim], [release], [locate] and
/// [migrate], and sets [slotHandler] to serve the `ASSIGN`, `DRAIN`,
/// `FORWARD` and `RESUME` requests the naming service sends over this
/// client's channel. The client serves the slots of a type for the one
/// instance of that type it registers. It remembers the slot space
/// definitions, the declared storage and the slots it serves; after a
/// reconnect it registers again, then re-sends `SLOTS` and `HOLDING` and
/// claims every slot it was serving with its last epoch; a request the
/// channel refuses to send (its `TalkOptions.maxOutgoingRequests`) is
/// sent after [reconnectDelay], with what follows it. Calls of [claim],
/// [release] and [locate] beyond that limit wait for their turn, in call
/// order, rather than fail with [StatusCode.resourceExhausted]. When the
/// channel is lost, or the client is closed, every slot locked by `DRAIN`
/// is unlocked through [SlotHandler.onResume]. Every `HOLDING` response's
/// list of slots to discard reaches [SlotHandler.onDiscard].
///
/// See the wiki page "Polyverse Switchboard Naming Service", section "Mirror
/// behaviour".
class NamingClient {
  /// Creates a client. Nothing happens until [start].
  ///
  /// [connect] opens a fresh Talk channel to the naming service; it is
  /// called on start and again after a loss, with [reconnectDelay] between
  /// attempts. The channel's [TalkOptions.requestTimeout] bounds every
  /// request, `WATCH` included: its reply comes after the whole snapshot.
  ///
  /// [slotHandlerMaxDuration] bounds a [slotHandler] call: one still
  /// running after it is answered `ABORT DEADLINE_EXCEEDED` (the naming
  /// service rolls the hand-over back) and its late outcome is ignored (an
  /// `ASSIGN` answered so is revoked, [SlotHandler.onRevoke]); the
  /// deadlines a handler declares with [SlotRequestContext.extend] are
  /// lowered to what is left of it. [Duration.zero] removes the bound.
  ///
  /// [watch] false makes a client that only registers (a worker whose
  /// credential has no `watch` scope): it sends no `WATCH`, so its [table]
  /// stays empty and it is never [synced]. A `WATCH` the naming service
  /// refuses with `PERMISSION_DENIED` is not retried either: the channel
  /// and its registrations are kept, and the table is not mirrored.
  ///
  /// Throws [ArgumentError] if [slotHandlerMaxDuration] is negative.
  NamingClient(
    TalkConnector connect, {
    this.reconnectDelay = const Duration(seconds: 1),
    this.slotHandlerMaxDuration = const Duration(minutes: 10),
    this.watch = true,
  }) : _connect = connect {
    if (slotHandlerMaxDuration < Duration.zero) {
      throw ArgumentError.value(
        slotHandlerMaxDuration,
        'slotHandlerMaxDuration',
        'must not be negative',
      );
    }
  }

  final TalkConnector _connect;

  /// Delay before each reconnect attempt.
  final Duration reconnectDelay;

  /// Longest a [slotHandler] call may run, whatever it declares, before
  /// the request is answered `ABORT DEADLINE_EXCEEDED`; [Duration.zero] for
  /// no bound. Default 10 minutes.
  final Duration slotHandlerMaxDuration;

  /// Whether the client mirrors the table (`WATCH` on every connect).
  final bool watch;

  late final _ClientSlots _slots = _ClientSlots(this);

  final Map<ServiceAddress, ServiceRecord> _table = {};
  final StreamController<ServiceEvent> _events =
      StreamController<ServiceEvent>.broadcast();
  final Set<_Entry> _entries = {};
  final Completer<void> _started = Completer<void>();
  Completer<void> _synced = _newSynced();
  final Completer<void> _firstSynced = _newSynced();
  bool _hasSynced = false;
  _Session? _session;
  Future<void>? _startFuture;
  Future<void>? _closeFuture;
  bool _closed = false;
  bool _isSynced = false;
  Timer? _delayTimer;
  Completer<void>? _delay;
  int _failedConnects = 0;

  static Completer<void> _newSynced() {
    final completer = Completer<void>();
    // Only fails on close; never report that as unhandled.
    completer.future.ignore();
    return completer;
  }

  /// Read-only live view of the mirrored table. It is incomplete before the
  /// first `WATCH` reply ([hasSynced]) and stale while not [isSynced].
  late final Map<ServiceAddress, ServiceRecord> table = UnmodifiableMapView(
    _table,
  );

  /// Changes of [table]: `UP` when a record appears or its endpoints or
  /// metadata change, `DOWN` (address only) when it disappears, including records
  /// found missing when a new snapshot arrives after a reconnect. Broadcast
  /// stream; it ends on [close].
  Stream<ServiceEvent> get events => _events.stream;

  /// True while a channel to the naming service is open.
  bool get isConnected => _session?.alive ?? false;

  /// True once the `WATCH` of the current channel has been answered (the
  /// snapshot is in [table]); false while disconnected.
  bool get isSynced => _isSynced;

  /// True once any channel has been synced: [table] has been complete at
  /// least once. A later loss of the naming service does not reset it; the
  /// table is then stale ([isSynced] is false) but still served.
  bool get hasSynced => _hasSynced;

  /// Completes on the first sync ever, when [hasSynced] becomes true.
  /// One-shot: unlike [synced] it is never replaced after a loss. Fails
  /// with [StatusCode.cancelled] if [close] is called before that.
  Future<void> get firstSynced => _firstSynced.future;

  /// True after [close].
  bool get isClosed => _closed;

  /// Completes once the current session is synced (its `WATCH` answered).
  /// After a loss of the channel this returns a new future for the next
  /// session (unless the previous one never completed, in which case it is
  /// the same one). Fails with [StatusCode.cancelled] if [close] is called
  /// first.
  Future<void> get synced => _synced.future;

  // ---------------------------------------------------------------------
  // Sharding

  /// Serves the requests the naming service sends to this instance. Without
  /// one, they are answered `ABORT UNIMPLEMENTED`.
  SlotHandler? get slotHandler => _slots.handler;

  set slotHandler(SlotHandler? handler) => _slots.handler = handler;

  /// Serves the `CONNECT` requests the naming service relays to this
  /// instance (a consumer asked it to dial back; wiki page "Switchboard
  /// Identity and Credentials", section "Reverse connections"). Without
  /// one, they are answered `ABORT UNIMPLEMENTED`.
  ConnectHandler? connectHandler;

  // ---------------------------------------------------------------------
  // Identity

  /// Asks the naming service for a renewed credential (`RENEW`): the same
  /// identity, scopes and holder key, with a new expiry. [current] is sent
  /// as the credential to renew; null renews the one that identifies this
  /// client's channel (its connection's, or its payload's).
  ///
  /// Fails with the naming service's [SwitchboardException]
  /// ([StatusCode.unimplemented] when it issues no credentials,
  /// [StatusCode.unauthenticated] when the credential is not valid,
  /// [StatusCode.permissionDenied] when it is not renewed),
  /// [StatusCode.unavailable] while disconnected, [StatusCode.failedPrecondition]
  /// after [close], and [ProtocolException] for an answer that is not a
  /// credential.
  Future<Credential> renew({Credential? current}) async {
    final response = await _startRequest(
      Procedures.renew,
      current == null ? Uint8List(0) : current.encode(),
    ).response;
    try {
      return Credential.decode(response.payload);
    } on ProtocolException catch (e) {
      throw ProtocolException('RENEW answered ${e.status.reason}');
    }
  }

  /// Asks the naming service to have instance [instance] of [type], which
  /// registered without endpoints, dial [endpoint] and identify there with
  /// [intent] (`CONNECT`; at most 64 bytes). Completes once the instance
  /// has done so, with the identity it presents: the caller matches the
  /// accepted connection by that identity and [intent]. [timeout], when
  /// given, bounds the request whatever the naming service declares (it
  /// declares its own bound with `EXTEND`); the request is then cancelled,
  /// and the naming service cancels its request to the instance.
  ///
  /// Fails with the naming service's [SwitchboardException]
  /// ([StatusCode.notFound] for no such record, or one with endpoints;
  /// [StatusCode.permissionDenied] without the `broker` right;
  /// [StatusCode.unavailable] when the instance did not dial back in
  /// time), with [StatusCode.deadlineExceeded] after [timeout], with
  /// [StatusCode.unavailable] while disconnected,
  /// [StatusCode.failedPrecondition] after [close], and with
  /// [ArgumentError] or [RangeError] for an endpoint
  /// [ServiceRecord.checkEndpoint] refuses, an intent over 64 bytes, or an
  /// instance outside `u48`.
  Future<String> connectTo(
    Name type,
    int instance,
    Uri endpoint,
    Uint8List intent, {
    Duration? timeout,
  }) async {
    final payload = ConnectRequest(
      type,
      instance,
      endpoint,
      intent: intent,
    ).encode();
    final request = _startRequest(Procedures.connect, payload);
    var response = request.response;
    if (timeout != null && timeout > Duration.zero) {
      response = response.timeout(
        timeout,
        onTimeout: () {
          final status = Status.of(
            StatusCode.deadlineExceeded,
            'CONNECT not answered within $timeout',
          );
          request.cancel(status);
          throw SwitchboardException(status);
        },
      );
    }
    return ConnectResponse.decode((await response).payload).identity;
  }

  /// Starts [procedure] with [payload] on the live channel. Throws
  /// [SwitchboardException] when closed or disconnected, and like
  /// [TalkChannel.startRequest].
  TalkRequest _startRequest(Name procedure, Uint8List payload) {
    if (_closed) {
      throw SwitchboardException.of(
        StatusCode.failedPrecondition,
        'naming client closed',
      );
    }
    final session = _session;
    if (session == null || !session.usable) {
      throw SwitchboardException.of(
        StatusCode.unavailable,
        'not connected to the naming service',
      );
    }
    return session.channel.startRequest(
      procedure.toString(),
      payload,
      name: procedure,
    );
  }

  /// Serves a `CONNECT` relayed by the naming service with
  /// [connectHandler].
  Future<void> _serveConnect(TalkMessage message) async {
    final handler = connectHandler;
    if (handler == null) {
      _abortRequest(
        message,
        Status.of(StatusCode.unimplemented, 'this instance does not dial back'),
      );
      return;
    }
    final DialBackRequest request;
    try {
      request = DialBackRequest.decode(message.payload);
    } on ProtocolException catch (e) {
      _abortRequest(
        message,
        Status.of(StatusCode.invalidArgument, e.status.reason),
      );
      return;
    }
    // The handler's dial and identification are bounded by the node; the
    // naming service bounds the request and cancels it when it gives up.
    message.setReplyTimeout(Duration.zero);
    try {
      await handler(request);
    } on Object catch (e, st) {
      if (e is! SwitchboardException) {
        _log.warning('CONNECT handler failed', e, st);
      } else {
        _log.info('CONNECT to ${request.endpoint} failed: ${e.status}');
      }
      _abortRequest(
        message,
        Status.of(StatusCode.unavailable, 'dial back failed'),
      );
      return;
    }
    if (message.canReply) {
      try {
        message.reply(Uint8List(0));
      } on SwitchboardException catch (e) {
        _log.fine('CONNECT reply failed: $e');
      }
    }
  }

  static void _abortRequest(TalkMessage message, Status status) {
    if (!message.canReply) {
      return;
    }
    try {
      message.replyAbort(status);
    } on SwitchboardException catch (e) {
      _log.fine('abort failed: $e');
    }
  }

  /// Read-only live view of the mirrored slot tables, by type. Like
  /// [table], incomplete before the first sync and stale while not
  /// [isSynced]. A redefinition of a space replaces its [SlotTable].
  late final Map<Name, SlotTable> slotTables = UnmodifiableMapView(
    _slots.views,
  );

  /// The mirrored slot table of [type], or null if it has no slot space.
  SlotTable? slotTable(Name type) => _slots.views[type];

  /// The mirrored entry of [slot] of [type] if traffic for it has somewhere
  /// to go: owned, or migrating (route to [SlotEntry.owner], the old
  /// owner). Null when the slot is free, out of range, or the type has no
  /// slot space.
  SlotEntry? slotOwner(Name type, int slot) => _slots.slotOwner(type, slot);

  /// The distinct instances the slots of [type] are routed to (owners, and
  /// the old owner of a migrating slot), from the mirror. A new set, exact
  /// when read; empty without a slot space.
  Set<int> slotOwners(Name type) => _slots.views[type]?.owners ?? <int>{};

  /// Changes of the mirrored slot tables, including slots found gone when a
  /// new snapshot arrives after a reconnect. Broadcast stream; it ends on
  /// [close].
  Stream<SlotEvent> get slotEvents => _slots.events.stream;

  /// The slots of [type] this instance serves (confirmed `ASSIGN`s, until
  /// `FORWARD`, [release] or a revocation), with their epochs. A snapshot.
  Map<int, int> servedSlots(Name type) => _slots.servedSlots(type);

  /// Defines or confirms the slot space of [type] (`SLOTS`) and offers
  /// [capacity] as this instance's share weight. [capacity] 0 takes no
  /// slots: the call only defines or confirms the space, as a router or an
  /// operator tool does; 1 or more makes this instance a candidate for the
  /// allocator of a managed space.
  ///
  /// Remembered and sent again after every reconnect, once the
  /// registration of [type] made through this client is back (right away
  /// if this client registers no instance of [type]). Calling it again for
  /// the same type replaces the remembered definition. While disconnected,
  /// or before the registration of [type] completes, the future completes
  /// when the definition is sent.
  ///
  /// Fails with the naming service's [SwitchboardException]
  /// ([StatusCode.failedPrecondition] for a definition that conflicts with
  /// the existing space, [StatusCode.outOfRange] for too many slots), and
  /// the definition is then forgotten; with [StatusCode.invalidArgument]
  /// for an empty type, [StatusCode.failedPrecondition] after [close],
  /// [StatusCode.cancelled] on [close]; [RangeError] for a count or
  /// capacity outside `u32`, or a count of 0.
  Future<void> defineSlots(
    Name type, {
    required int count,
    SlotMode mode = SlotMode.managed,
    bool lazy = false,
    bool shared = false,
    int capacity = 1,
  }) {
    try {
      _checkSlotType(type);
      RangeError.checkValueInInterval(count, 1, maxU32, 'count');
      RangeError.checkValueInInterval(capacity, 0, maxU32, 'capacity');
    } catch (e, st) {
      return Future.error(e, st);
    }
    return _slots.defineSlots(
      SlotsRequest(
        SlotSpace(type, count: count, mode: mode, lazy: lazy, shared: shared),
        capacity: capacity,
      ),
    );
  }

  /// Declares that this instance holds the storage of [slots] of [type]
  /// (`HOLDING`) and returns the slots among them whose holder is no longer
  /// this instance; their local storage should be discarded. Free slots it
  /// holds are given back to it first (managed mode).
  ///
  /// The declaration is remembered (minus the slots to discard) and sent
  /// again after every reconnect, once the registration of [type] made
  /// through this client is back. While disconnected, or before that
  /// registration is back, the future completes when the declaration is
  /// sent and answered. A client that registers no instance of [type]
  /// sends it right away (after the next connect while disconnected), and
  /// the naming service refuses it, since only a registered instance holds
  /// storage. Fails with the naming service's [SwitchboardException]
  /// ([StatusCode.notFound] without a slot space,
  /// [StatusCode.failedPrecondition] without a registration of [type] on
  /// the channel); those slots are then forgotten. Fails with
  /// [StatusCode.cancelled] on [close].
  Future<List<int>> declareHolding(Name type, List<int> slots) {
    try {
      _checkSlotType(type);
      for (final slot in slots) {
        RangeError.checkValueInInterval(slot, 0, maxU32, 'slot');
      }
    } catch (e, st) {
      return Future.error(e, st);
    }
    return _slots.declareHolding(type, List.of(slots));
  }

  /// Takes the free [slot] of [type] (`CLAIM`) and returns its epoch. The
  /// naming service confirms it through `ASSIGN` to [slotHandler] before
  /// answering. [holding] says this instance holds the slot's storage.
  /// Claiming a slot this instance owns returns the current epoch.
  ///
  /// Fails with the naming service's [SwitchboardException]:
  /// [StatusCode.alreadyExists] if another instance owns it,
  /// [StatusCode.failedPrecondition] while it migrates,
  /// [StatusCode.notFound] without such a space or slot,
  /// [StatusCode.unavailable] if the `ASSIGN` failed. Fails with
  /// [StatusCode.unavailable] while disconnected, or if the channel is lost
  /// while the call waits for the channel's request limit.
  Future<int> claim(Name type, int slot, {bool holding = false}) =>
      _slotCall(type, slot, () => _slots.claim(type, slot, holding: holding));

  /// Gives up [slot] of [type] (`RELEASE`). With [keepStorage] this
  /// instance stays its holder (and keeps declaring it after reconnects).
  ///
  /// Fails with [StatusCode.permissionDenied] if this instance does not own
  /// it, [StatusCode.failedPrecondition] while it migrates, and
  /// [StatusCode.unavailable] while disconnected (or if the channel is lost
  /// while the call waits for the channel's request limit).
  Future<void> release(Name type, int slot, {bool keepStorage = false}) =>
      _slotCall(
        type,
        slot,
        () => _slots.release(type, slot, keepStorage: keepStorage),
      );

  /// Finds the owner of [slot] of [type] (`LOCATE`). In a managed space a
  /// free slot is assigned first, and the answer comes once its new owner
  /// confirmed. A free slot answers [SlotState.free] with owner 0.
  ///
  /// Fails with [StatusCode.notFound] without such a space or slot,
  /// [StatusCode.unavailable] if the assignment failed, while disconnected,
  /// or if the channel is lost while the call waits for the channel's
  /// request limit.
  Future<LocateResponse> locate(Name type, int slot) =>
      _slotCall(type, slot, () => _slots.locate(type, slot));

  /// Moves [slot] of [type] to instance [to] (0 lets the allocator choose)
  /// through the hand-over (`MIGRATE`). The stream reports each
  /// [PhaseItem] and ends when the migration is done; at most one
  /// migration per space runs at a time, others queue.
  ///
  /// Errors: [StatusCode.notFound], [StatusCode.failedPrecondition]
  /// (already migrating, [to] is the owner or not registered),
  /// [StatusCode.unavailable] (rolled back, after a
  /// [MigrationPhase.rolledBack] item; or disconnected). Cancelling the
  /// subscription cancels the request; a migration already running
  /// completes anyway.
  Stream<PhaseItem> migrate(Name type, int slot, {int to = 0}) {
    try {
      _checkSlotType(type);
      RangeError.checkValueInInterval(slot, 0, maxU32, 'slot');
      RangeError.checkValueInInterval(to, 0, maxInstance, 'to');
    } catch (e, st) {
      return Stream.error(e, st);
    }
    return _slots.migrate(type, slot, to);
  }

  Future<T> _slotCall<T>(Name type, int slot, Future<T> Function() call) {
    try {
      _checkSlotType(type);
      RangeError.checkValueInInterval(slot, 0, maxU32, 'slot');
      return call();
    } catch (e, st) {
      return Future.error(e, st);
    }
  }

  void _checkSlotType(Name type) {
    if (_closed) {
      throw SwitchboardException.of(
        StatusCode.failedPrecondition,
        'naming client closed',
      );
    }
    if (type.isEmpty) {
      throw SwitchboardException.of(
        StatusCode.invalidArgument,
        'empty service type',
      );
    }
  }

  /// Whether this client registers an instance of [type].
  bool _registers(Name type) => _entries.any((e) => e.type == type);

  /// Whether an instance of [type] is registered on [session].
  bool _registeredOn(_Session session, Name type) =>
      _entries.any((e) => e.type == type && identical(e.session, session));

  /// Starts the connection loop: connects, re-registers remembered
  /// registrations, starts `WATCH`. Completes once the first connection is
  /// established (not synced; see [synced]), or when [close] is called
  /// before that. Calling it again returns the same future.
  Future<void> start() => _startFuture ??= _start();

  Future<void> _start() {
    if (!_closed) {
      unawaited(_run());
    }
    return _started.future;
  }

  /// Registers an instance of [type] reachable at [endpoints] and returns
  /// the instance id the naming service assigned ([instance] 0) or
  /// accepted. [metadata] (copied; null is empty, at most
  /// [maxMetadataLength] bytes) is published with the record for consumers
  /// to select on ([ServiceRecord.metadata]). Every watcher of the naming
  /// table sees it, so a key placed there authenticates the mesh to the
  /// instance, not the instance to the mesh.
  ///
  /// The endpoints need not be this process's: a registrar (a scaler, an
  /// operator tool) may register any number of records for endpoints that
  /// never talk to the naming service. Each record lives as long as this
  /// client's channel, so the registrar retires dead endpoints itself with
  /// [unregister].
  ///
  /// The registration is remembered and made again after every reconnect,
  /// asking for the same id; if that id has been taken meanwhile, a new one
  /// is assigned (and logged). If the naming service refuses such a
  /// re-registration for another reason, it is retried on the same channel
  /// every [reconnectDelay]. While disconnected, and if the channel is lost
  /// while the request is in flight, the returned future completes once the
  /// registration succeeds after the next connect.
  ///
  /// Registering a non-zero [instance] of [type] again supersedes the
  /// earlier registration of `type/instance` made through this client,
  /// whether or not it has completed: the naming service replaces the
  /// endpoints and metadata (publishing `UP` if either changed), only the
  /// newest registration is remembered, and the earlier call's future
  /// completes (or fails) like this one.
  /// If the replacement is refused while the earlier registration may be
  /// published on the channel (it was made, or was in flight, on it), the
  /// client drops the channel, so that the record it no longer tracks
  /// goes away with it.
  ///
  /// [onAssigned], if given, is called synchronously with the instance id
  /// whenever the registration gets an id different from the one it had:
  /// once on the first success, just before the returned future completes,
  /// and again after a reconnect that had to assign a new id. A host uses
  /// it to keep its local dispatch registration in step with the id the
  /// mesh routes to. Exceptions it throws are logged and ignored.
  ///
  /// Fails with the naming service's [SwitchboardException]
  /// ([StatusCode.alreadyExists] for a requested id in use,
  /// [StatusCode.invalidArgument]), with [StatusCode.invalidArgument] for an
  /// empty type, [StatusCode.cancelled] if [unregister] or [close] is called
  /// first, and [StatusCode.failedPrecondition] after [close]. Fails with
  /// [StatusCode.deadlineExceeded] if the naming service does not answer
  /// within the channel's request timeout: the outcome is then unknown, so
  /// the client also drops the channel (the naming service discards the
  /// record, if it made one) and reconnects; the registration is not
  /// remembered. Fails with [ArgumentError] or [RangeError] for more than
  /// 255 endpoints, an endpoint [ServiceRecord.checkEndpoint] refuses (no
  /// scheme, longer than 255 bytes, or not stable through its text form),
  /// metadata longer than [maxMetadataLength], or an instance outside the
  /// `u48` range.
  Future<int> register(
    Name type,
    List<Uri> endpoints, {
    int instance = 0,
    void Function(int instance)? onAssigned,
    Uint8List? metadata,
  }) {
    if (_closed) {
      return Future.error(
        SwitchboardException.of(
          StatusCode.failedPrecondition,
          'naming client closed',
        ),
      );
    }
    if (type.isEmpty) {
      return Future.error(
        SwitchboardException.of(
          StatusCode.invalidArgument,
          'empty service type',
        ),
      );
    }
    try {
      if (instance < 0 || instance > maxInstance) {
        throw RangeError.range(instance, 0, maxInstance, 'instance');
      }
      if (endpoints.length > 255) {
        throw ArgumentError.value(endpoints.length, 'endpoints', 'over 255');
      }
      endpoints.forEach(ServiceRecord.checkEndpoint);
      if (metadata != null && metadata.length > maxMetadataLength) {
        throw ArgumentError.value(
          metadata.length,
          'metadata',
          'more than $maxMetadataLength bytes',
        );
      }
    } catch (e, st) {
      return Future.error(e, st);
    }
    final entry = _Entry(
      type,
      List.unmodifiable(endpoints),
      metadata == null ? Uint8List(0) : Uint8List.fromList(metadata),
      instance,
      onAssigned,
    );
    if (instance != 0) {
      // Registering an id again replaces its record: the older entry is
      // superseded, even while its own request is still in flight.
      for (final older in [
        for (final e in _entries)
          if (e.type == type && e.instance == instance) e,
      ]) {
        _supersede(older, entry);
      }
    }
    _entries.add(entry);
    final session = _session;
    if (session != null && session.alive) {
      unawaited(_registerOn(session, entry));
    }
    return entry.completer.future;
  }

  /// Removes the registration of `type/instance` made through this client
  /// and stops re-registering it. A [register] of it still in flight fails
  /// with [StatusCode.cancelled]; if the naming service registers it anyway,
  /// the client unregisters it as soon as the answer arrives, and if one
  /// that replaced a registration on the channel is refused, the client
  /// drops the channel, which takes the replaced record with it.
  ///
  /// While disconnected it completes immediately: the naming service already
  /// dropped the record with the channel. Fails with [StatusCode.notFound]
  /// if this client has no such registration, with the naming service's
  /// status if it refuses, and with [StatusCode.failedPrecondition] after
  /// [close]. If the naming service refuses (other than with
  /// [StatusCode.notFound]) or does not answer in time
  /// ([StatusCode.deadlineExceeded]), the client also drops its channel, so
  /// that the record goes away with it, and reconnects; either way the
  /// registration is no longer remembered.
  Future<void> unregister(Name type, int instance) async {
    if (_closed) {
      throw SwitchboardException.of(
        StatusCode.failedPrecondition,
        'naming client closed',
      );
    }
    final matching = [
      for (final e in _entries)
        if (e.type == type && e.instance == instance && instance != 0) e,
    ];
    if (matching.isEmpty) {
      throw SwitchboardException.of(
        StatusCode.notFound,
        'no registration ${ServiceAddress(type, instance)}',
      );
    }
    final session = _session;
    var registeredHere = false;
    for (final entry in matching) {
      _entries.remove(entry);
      if (!entry.completer.isCompleted) {
        entry.completer.future.ignore();
        entry.completer.completeError(
          SwitchboardException.of(StatusCode.cancelled, 'unregistered'),
        );
      }
      if (session != null && identical(entry.session, session)) {
        registeredHere = true;
      }
    }
    if (session == null || !session.usable || !registeredHere) {
      // Not registered on the live channel. A registration still in flight
      // removes itself when it completes.
      return;
    }
    await _sendUnregister(session, type, instance);
  }

  /// Stops reconnecting, closes the channel (the naming service then drops
  /// this client's registrations and frees their slots), fails pending
  /// [register] futures and [synced] with [StatusCode.cancelled], and ends
  /// [events]. Slots locked by `DRAIN` are unlocked through
  /// [SlotHandler.onResume] once their `DRAIN` handler is done, as on a
  /// loss of the naming service. No timer is left running. Calling it
  /// again returns the same future.
  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    _closed = true;
    _delayTimer?.cancel();
    _delayTimer = null;
    final delay = _delay;
    if (delay != null && !delay.isCompleted) {
      delay.complete();
    }
    if (!_started.isCompleted) {
      _started.complete();
    }
    final cancelled = SwitchboardException.of(
      StatusCode.cancelled,
      'naming client closed',
    );
    for (final entry in _entries) {
      if (!entry.completer.isCompleted) {
        entry.completer.future.ignore();
        entry.completer.completeError(cancelled);
      }
    }
    _entries.clear();
    final session = _session;
    if (session != null) {
      session.lose(Status.ok, 'naming client closed');
      await session.closed;
    }
    _isSynced = false;
    if (!_synced.isCompleted) {
      _synced.completeError(cancelled);
    }
    if (!_firstSynced.isCompleted) {
      _firstSynced.completeError(cancelled);
    }
    // Not awaited: a listener that is paused (an `await for` body calling
    // close, an idle StreamQueue) would hold it for ever.
    unawaited(_events.close());
    await _slots.close();
  }

  // ---------------------------------------------------------------------
  // Connection loop

  Future<void> _run() async {
    while (!_closed) {
      final TalkChannel channel;
      try {
        channel = await _connect();
      } catch (e, st) {
        if (_closed) {
          break;
        }
        _failedConnects++;
        if (_failedConnects == 1) {
          _log.warning('cannot connect to the naming service', e, st);
        } else {
          _log.fine('cannot connect to the naming service: $e');
        }
        await _wait();
        continue;
      }
      if (_closed) {
        unawaited(channel.close());
        break;
      }
      _failedConnects = 0;
      await _runSession(channel);
      if (!_closed) {
        await _wait();
      }
    }
  }

  /// Waits [reconnectDelay]; [close] cuts it short.
  Future<void> _wait() {
    final delay = Completer<void>();
    _delay = delay;
    _delayTimer = Timer(reconnectDelay, () {
      _delayTimer = null;
      if (!delay.isCompleted) {
        delay.complete();
      }
    });
    return delay.future;
  }

  Future<void> _runSession(TalkChannel channel) async {
    final session = _Session(channel, _onLost);
    _session = session;
    _log.info('connected to the naming service');
    if (!_started.isCompleted) {
      _started.complete();
    }
    session.messages = channel.messages.listen(
      (message) => _onServerMessage(session, message),
      onError: (Object e) => session.lose(Status.ok, 'channel aborted: $e'),
      onDone: () => session.lose(Status.ok, 'channel closed'),
    );
    unawaited(
      channel.done.then(
        (status) => session.lose(Status.ok, 'channel closed: $status'),
      ),
    );

    // Register the ids we had (or asked for) first, so other services'
    // channels to them stay valid where possible and the snapshot already
    // holds them, then watch. Registrations that ask for any id are sent
    // after them (so that an assignment cannot take one of our ids), but
    // not waited for: a freshly started naming service may hold
    // assignments for a while (see NamingService.assignmentHold).
    final entries = _entries.toList();
    final known = [
      for (final entry in entries)
        if (entry.instance != 0) _registerOn(session, entry),
    ];
    for (final entry in entries) {
      if (entry.instance == 0) {
        unawaited(_registerOn(session, entry));
      }
    }
    await Future.wait(known);
    if (session.alive) {
      // SLOTS, HOLDING and the claims of served slots, for every type not
      // restored yet when its registration came back.
      _slots.restoreAll(session);
      if (watch) {
        _startWatch(session);
      }
    }
    await session.lost;
    if (identical(_session, session)) {
      _session = null;
    }
    await session.tearDown();
  }

  /// Called synchronously when a session is lost: the table is stale from
  /// now on, and [synced] is a new future for the next session.
  void _onLost() {
    _isSynced = false;
    if (_synced.isCompleted && !_closed) {
      _synced = _newSynced();
    }
    _slots.onLost();
  }

  void _onServerMessage(_Session session, TalkMessage message) {
    if (!message.expectsReply) {
      _onEvent(session, message);
      return;
    }
    if (message.canReply &&
        _ClientSlots.procedures.contains(message.procedure)) {
      if (session.alive) {
        _slots.serve(session, message);
      }
      return;
    }
    if (message.canReply && message.procedure == Procedures.connect) {
      if (session.alive) {
        unawaited(_serveConnect(message));
      }
      return;
    }
    // The naming service sends no other requests.
    if (message.canReply) {
      try {
        message.replyAbort(
          Status.of(
            StatusCode.unimplemented,
            'unknown procedure ${message.procedureName}',
          ),
        );
      } on SwitchboardException catch (e) {
        _log.fine('abort failed: $e');
      }
    } else {
      _log.fine('ignoring request ${message.procedureName}');
    }
  }

  // ---------------------------------------------------------------------
  // Registration

  /// Registers [entry] on [session], asking for [instance] (default: the
  /// entry's id). Never throws.
  Future<void> _registerOn(
    _Session session,
    _Entry entry, {
    int? instance,
  }) async {
    if (identical(entry.session, session) ||
        identical(entry.pending, session)) {
      return;
    }
    entry.pending = session;
    final requested = entry.pendingInstance = instance ?? entry.instance;
    final int assigned;
    try {
      // Ordered: the UP of the record, which the naming service sends
      // before the reply, is in the table when this completes.
      final response = await session.channel.request(
        Procedures.register.toString(),
        RegisterRequest(
          entry.type,
          requestedInstance: requested,
          endpoints: entry.endpoints,
          metadata: entry.metadata,
        ).encode(),
        ordered: true,
      );
      assigned = RegisterResponse.decode(response.payload).instance;
      if (assigned == 0 || (requested != 0 && assigned != requested)) {
        throw ProtocolException(
          'REGISTER for ${ServiceAddress(entry.type, requested)} answered '
          'with id ${assigned.toRadixString(16)}',
        );
      }
    } catch (e, st) {
      if (identical(entry.pending, session)) {
        entry.pending = null;
      }
      await _onRegisterFailed(session, entry, requested, e, st);
      return;
    }
    if (identical(entry.pending, session)) {
      entry.pending = null;
    }
    await _onRegistered(session, entry, assigned);
  }

  Future<void> _onRegistered(
    _Session session,
    _Entry entry,
    int assigned,
  ) async {
    if (entry.superseded || !_entries.contains(entry)) {
      // Superseded by a newer registration, or unregistered, while the
      // request was in flight. The record is the newer registration's if
      // that one registers the same id on this channel: its REGISTER
      // follows this one, and replaces the record. Otherwise nothing
      // tracks the record any more (this one may have been given another
      // id than the newer one asked for), and it is removed.
      final successor = _successorOn(session, entry, assigned);
      if (successor != null) {
        if (!identical(successor.session, session)) {
          // Should its REGISTER be refused, the record would stay.
          successor.replacesOn = session;
        }
        return;
      }
      if (session.usable) {
        try {
          await _sendUnregister(session, entry.type, assigned);
        } catch (e) {
          _log.fine('late unregister failed: $e');
        }
      }
      return;
    }
    if (entry.completer.isCompleted &&
        entry.instance != 0 &&
        assigned != entry.instance) {
      _log.warning(
        're-registered ${ServiceAddress(entry.type, entry.instance)} as '
        '${ServiceAddress(entry.type, assigned)}',
      );
    }
    final changed = !entry.completer.isCompleted || assigned != entry.instance;
    entry.instance = assigned;
    entry.session = session;
    entry.refusals = 0;
    // At most one remembered registration per address: an older one that
    // ended up with the same id on this channel (it asked for any id and
    // was given the one this entry asked for) is superseded by this, the
    // later answer. A remembered one that is not registered on this channel
    // (it waits to be registered again) has lost its id to this entry, and
    // asks for a new one when it is.
    for (final other in [
      for (final e in _entries)
        if (!identical(e, entry) &&
            e.type == entry.type &&
            e.instance == assigned &&
            e.completer.isCompleted &&
            !identical(e.pending, session))
          e,
    ]) {
      if (identical(other.session, session)) {
        _supersede(other, entry);
      } else {
        _log.warning(
          '${ServiceAddress(entry.type, assigned)} went to another '
          'registration of this client; asking for a new id',
        );
        other.instance = 0;
      }
    }
    // Whatever it replaced, it replaced.
    entry.replacesOn = null;
    _log.fine('registered ${ServiceAddress(entry.type, assigned)}');
    if (changed) {
      _notifyAssigned(entry, assigned);
    }
    if (!entry.completer.isCompleted) {
      entry.completer.complete(assigned);
    }
    _slots.restore(session, entry.type);
  }

  Future<void> _onRegisterFailed(
    _Session session,
    _Entry entry,
    int requested,
    Object error,
    StackTrace stackTrace,
  ) async {
    if (entry.superseded) {
      // Its successor carries the outcome.
      return;
    }
    if (!session.usable) {
      // The channel is gone, and with it anything the request registered.
      // A remembered or pending entry is registered again after the next
      // connect.
      return;
    }
    final address = ServiceAddress(entry.type, requested);
    final indeterminate = _isIndeterminate(error);
    if (!_entries.contains(entry)) {
      // Unregistered while the request was in flight. If the naming service
      // may have registered it after all, or still publishes the record it
      // was to replace, the record must not outlive the channel unnoticed.
      if (indeterminate) {
        session.lose(
          Status.of(StatusCode.aborted, 'REGISTER outcome unknown'),
          'REGISTER $address has no clear outcome ($error)',
        );
      } else if (identical(entry.replacesOn, session)) {
        session.lose(
          Status.of(StatusCode.aborted, 'replacement REGISTER failed'),
          'replacement REGISTER $address failed after unregister; dropping '
          'the old record',
        );
      }
      return;
    }
    final remembered = entry.completer.isCompleted;
    if (indeterminate) {
      // The naming service may or may not hold the record. Drop the
      // channel: it then discards everything registered on it, and the
      // reconnect registers the remembered set again.
      _log.warning(
        'REGISTER $address has no clear outcome, dropping the channel',
        error,
      );
      if (!remembered) {
        _entries.remove(entry);
        entry.completer.completeError(error, stackTrace);
      }
      session.lose(
        Status.of(StatusCode.aborted, 'REGISTER outcome unknown'),
        'REGISTER $address has no clear outcome',
      );
      return;
    }
    if (remembered &&
        requested != 0 &&
        error is SwitchboardException &&
        error.code == StatusCode.alreadyExists) {
      _log.warning('$address is taken, asking for a new id');
      await _registerOn(session, entry, instance: 0);
      return;
    }
    if (remembered) {
      // Refused on a healthy channel: try again later on the same channel,
      // without disturbing the other registrations.
      entry.refusals++;
      final message =
          're-registering $address failed; retrying in $reconnectDelay';
      if (entry.refusals == 1) {
        _log.severe(message, error, stackTrace);
      } else {
        _log.fine('$message: $error');
      }
      session.later(reconnectDelay, () {
        if (_entries.contains(entry)) {
          unawaited(_registerOn(session, entry));
        }
      });
      return;
    }
    _entries.remove(entry);
    entry.completer.completeError(error, stackTrace);
    if (identical(entry.replacesOn, session)) {
      session.lose(
        Status.of(StatusCode.aborted, 'replacement REGISTER failed'),
        'replacement REGISTER $address failed; dropping the old record',
      );
    }
  }

  /// The registration other than [entry] that holds `type/assigned` on
  /// [session], or whose `REGISTER` of it is in flight there; null if none.
  _Entry? _successorOn(_Session session, _Entry entry, int assigned) {
    for (final e in _entries) {
      if (!identical(e, entry) &&
          e.type == entry.type &&
          ((identical(e.session, session) && e.instance == assigned) ||
              (identical(e.pending, session) &&
                  e.pendingInstance == assigned))) {
        return e;
      }
    }
    return null;
  }

  /// Whether a failed request may still have taken effect: the naming
  /// service did not answer in time, or answered something unreadable. A
  /// refusal is an answer; a lost channel is handled separately.
  static bool _isIndeterminate(Object error) =>
      error is! SwitchboardException ||
      error is ProtocolException ||
      error.code == StatusCode.deadlineExceeded;

  /// Replaces [older] by [newer], which registers the same address: [older]
  /// is forgotten, its late answer ignored, and its pending future
  /// completes like [newer]'s.
  void _supersede(_Entry older, _Entry newer) {
    _entries.remove(older);
    older.superseded = true;
    final live = _session;
    if (live != null &&
        (identical(older.session, live) ||
            identical(older.pending, live) ||
            identical(older.replacesOn, live))) {
      newer.replacesOn = live;
    }
    if (!older.completer.isCompleted) {
      newer.completer.future.then(
        older.completer.complete,
        onError: (Object error, StackTrace stackTrace) {
          if (error is SwitchboardException &&
              error.code == StatusCode.cancelled) {
            // By [close] or [unregister], which do not report it as an
            // unhandled error to a caller that dropped the future.
            older.completer.future.ignore();
          }
          older.completer.completeError(error, stackTrace);
        },
      );
    }
  }

  static void _notifyAssigned(_Entry entry, int assigned) {
    final callback = entry.onAssigned;
    if (callback == null) {
      return;
    }
    try {
      callback(assigned);
    } catch (e, st) {
      _log.severe(
        'onAssigned for ${ServiceAddress(entry.type, assigned)} failed',
        e,
        st,
      );
    }
  }

  /// Sends `UNREGSTR`. A lost channel counts as success: the record went
  /// away with it. Any other failure but [StatusCode.notFound] may leave
  /// the record registered without the client tracking it, so the channel
  /// is dropped (taking the record with it) before the error is rethrown.
  Future<void> _sendUnregister(
    _Session session,
    Name type,
    int instance,
  ) async {
    try {
      await session.channel.request(
        Procedures.unregister.toString(),
        UnregisterRequest(type, instance).encode(),
        ordered: true,
      );
    } catch (e) {
      if (!session.usable) {
        // The record went away with the channel.
        return;
      }
      if (e is! SwitchboardException || e.code != StatusCode.notFound) {
        session.lose(
          Status.of(StatusCode.aborted, 'UNREGSTR failed'),
          'UNREGSTR ${ServiceAddress(type, instance)} failed ($e)',
        );
      }
      rethrow;
    }
  }

  // ---------------------------------------------------------------------
  // Watch

  /// Subscribes to every type. The reply is ordered with the events: every
  /// event before it is part of the snapshot, every event after it is live.
  /// A `WATCH` the channel refuses for its request limit (the slot state
  /// restored ahead of it fills it) is sent after [reconnectDelay].
  void _startWatch(_Session session) {
    final Future<TalkMessage> reply;
    try {
      reply = session.channel.request(
        Procedures.watch.toString(),
        const WatchRequest().encode(),
        ordered: true,
      );
    } on SwitchboardException catch (e) {
      if (e.code == StatusCode.resourceExhausted && session.usable) {
        _log.info('WATCH not sent yet, retrying in $reconnectDelay: $e');
        session.later(reconnectDelay, () => _startWatch(session));
        return;
      }
      session.lose(Status.ok, 'cannot watch: $e');
      return;
    }
    reply
        .then(
          (_) => _onSynced(session),
          onError: (Object e) {
            final status = e is SwitchboardException
                ? e.status
                : Status.of(StatusCode.unknown, '$e');
            if (status.known == StatusCode.permissionDenied && session.usable) {
              // The credential grants no watch scope: asking again would
              // be refused again. The registrations stay.
              _log.severe(
                'the naming service refuses WATCH ($status); the table is '
                'not mirrored',
              );
              return;
            }
            session.lose(
              Status.of(StatusCode.unavailable, 'WATCH failed: $status'),
              'WATCH failed: $status',
            );
          },
        )
        .ignore();
  }

  /// A one-way message from the naming service: an event of the
  /// subscription. Events before the `WATCH` reply ([_Session.syncing])
  /// belong to the snapshot.
  void _onEvent(_Session session, TalkMessage event) {
    if (!session.alive) {
      return;
    }
    final procedure = event.procedure;
    try {
      if (procedure == Procedures.up) {
        final record = ServiceRecord.decode(event.payload);
        if (session.syncing) {
          session.seen.add(record.address);
        }
        _applyUp(record);
      } else if (procedure == Procedures.down) {
        final address = ServiceEvent.decodeDown(event.payload).record.address;
        session.seen.remove(address);
        _applyDown(address);
      } else if (procedure == Procedures.slotSpace) {
        _slots.onSpaceItem(session, SlotSpace.decode(event.payload));
      } else if (procedure == Procedures.slot) {
        _slots.onSlotItem(session, SlotItem.decode(event.payload));
      } else {
        _log.fine('ignoring message ${event.procedureName}');
      }
    } on ProtocolException catch (e) {
      _log.warning('malformed ${event.procedureName} event: $e');
    }
  }

  /// The `WATCH` reply: the snapshot is complete. Records, spaces and
  /// slots it did not mention are gone.
  void _onSynced(_Session session) {
    if (!session.alive || !session.syncing) {
      return;
    }
    session.syncing = false;
    final gone = [
      for (final address in _table.keys)
        if (!session.seen.contains(address)) address,
    ];
    session.seen.clear();
    for (final address in gone) {
      _applyDown(address);
    }
    _slots.onSynced(session);
    _isSynced = true;
    _hasSynced = true;
    _log.info('naming table synced, ${_table.length} records');
    if (!_synced.isCompleted) {
      _synced.complete();
    }
    if (!_firstSynced.isCompleted) {
      _firstSynced.complete();
    }
  }

  void _applyUp(ServiceRecord record) {
    final previous = _table[record.address];
    _table[record.address] = record;
    if (previous != record) {
      _emit(ServiceEvent(up: true, record: record));
    }
  }

  void _applyDown(ServiceAddress address) {
    if (_table.remove(address) != null) {
      _emit(ServiceEvent(up: false, record: ServiceRecord(address)));
    }
  }

  void _emit(ServiceEvent event) {
    if (!_events.isClosed) {
      _events.add(event);
    }
  }
}

/// A registration remembered for re-registration.
class _Entry {
  _Entry(
    this.type,
    this.endpoints,
    this.metadata,
    this.instance,
    this.onAssigned,
  );

  final Name type;
  final List<Uri> endpoints;

  /// A private copy of the caller's metadata.
  final Uint8List metadata;

  /// Told about every new id.
  final void Function(int instance)? onAssigned;

  /// The assigned id once registered, else the requested id (0: any).
  int instance;

  /// The session this entry is registered on.
  _Session? session;

  /// The session a REGISTER for this entry is in flight on.
  _Session? pending;

  /// The id that REGISTER asks for (0: any).
  int pendingInstance = 0;

  /// Replaced by a newer registration of the same address.
  bool superseded = false;

  /// The session on which a registration this entry superseded may still
  /// be published (registered, or in flight, there): if this entry is
  /// refused on it, the channel is dropped. Null once registered.
  _Session? replacesOn;

  /// Refusals of re-registration in a row.
  int refusals = 0;

  /// Completes with the first assigned id.
  final Completer<int> completer = Completer<int>();
}

/// One channel to the naming service.
class _Session {
  _Session(this.channel, this._onLost);

  final TalkChannel channel;
  final void Function() _onLost;
  final Completer<void> _lost = Completer<void>();
  final Completer<void> _closed = Completer<void>();
  StreamSubscription<TalkMessage>? messages;
  Future<void>? closeChannel;
  final Set<Timer> _timers = {};

  /// Until the `WATCH` reply: events are the snapshot, and the addresses
  /// they mention are collected.
  bool syncing = true;
  final Set<ServiceAddress> seen = {};

  /// Until the `WATCH` reply: slot spaces and slots seen in the snapshot.
  final Set<Name> seenSpaces = {};
  final Set<(Name, int)> seenSlots = {};

  /// Types whose slot state was sent on this channel: true once with the
  /// registration of the type, false when sent without one. Set once every
  /// request of the restoration went out.
  final Map<Name, bool> restored = {};

  /// What of the slot state went out on this channel: the definition sent
  /// per type (and whether the type was registered on the channel then:
  /// only then does it carry the instance's capacity), the types whose
  /// `HOLDING` was sent with their registration, and those whose served
  /// slots were queued for claiming. A restoration that resumes after a
  /// retry does not send these again.
  final Map<Name, (_SpaceDefinition, bool)> sentSlots = {};
  final Set<Name> sentHolding = {};
  final Set<Name> reclaimed = {};

  /// Types whose restoration waits for a retry: one of its requests was
  /// refused before it was sent (the channel's request limit).
  final Set<Name> retrying = {};

  /// Claims of served slots waiting to be sent, and the number in flight.
  final Queue<(Name, int, _Served)> reclaims = Queue();
  int reclaiming = 0;

  /// The claims wait for a retry: one was refused before it was sent.
  bool reclaimsPaused = false;

  /// Requests of the client's slot API waiting for the channel to take
  /// them (see `_ClientSlots.call`), the number of them in flight, and
  /// whether they wait for a retry timer.
  final Queue<_Call> calls = Queue();
  int calling = 0;
  bool callsPaused = false;

  bool get alive => !_lost.isCompleted;

  /// Alive and the channel still open. A failed request on a channel that
  /// is no longer open is a loss of the channel, not a refusal, even before
  /// [lose] runs.
  bool get usable => alive && channel.isOpen;

  /// Completes when the session is lost.
  Future<void> get lost => _lost.future;

  /// Completes when the session is torn down and its channel closed.
  Future<void> get closed => _closed.future;

  /// Runs [action] after [delay] unless the session is lost first.
  void later(Duration delay, void Function() action) {
    if (!alive) {
      return;
    }
    late final Timer timer;
    timer = Timer(delay, () {
      _timers.remove(timer);
      if (alive) {
        action();
      }
    });
    _timers.add(timer);
  }

  /// Marks the session lost and closes its channel with [status].
  /// Idempotent.
  void lose(Status status, String reason) {
    if (_lost.isCompleted) {
      return;
    }
    _log.info('naming service channel lost: $reason');
    for (final timer in _timers) {
      timer.cancel();
    }
    _timers.clear();
    final waiting = List.of(calls);
    calls.clear();
    for (final call in waiting) {
      call.completer.completeError(
        SwitchboardException.of(
          StatusCode.unavailable,
          'naming service channel lost',
        ),
      );
    }
    closeChannel = channel.close(status);
    _lost.complete();
    _onLost();
  }

  /// Cancels the subscriptions, waits for the channel to close and
  /// completes [closed].
  Future<void> tearDown() async {
    // Nothing worth waiting for in the cancels. Cancelling a subscription
    // to a stream that already ended returns a future of the root zone,
    // which a fake clock (package:fake_async) never completes.
    messages?.cancel().ignore();
    await closeChannel;
    if (!_closed.isCompleted) {
      _closed.complete();
    }
  }
}
