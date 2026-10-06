/*
Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Author: Jan Boon <jan.boon@kaetemi.be>
*/

import 'dart:async';
import 'dart:collection';

import 'package:logging/logging.dart';

import '../address/service_address.dart';
import '../name.dart';
import '../status.dart';
import '../talk/talk_channel.dart';
import '../talk/talk_message.dart';
import '../talk/talk_stream.dart';
import 'naming_protocol.dart';

final Logger _log = Logger('Switchboard.Naming');

/// Opens a fresh Talk channel to the naming service.
typedef TalkConnector = Future<TalkChannel> Function();

/// A client of the naming service: registers this process's services and
/// mirrors the service table through a `WATCH` stream.
///
/// The client keeps one channel to the naming service. On every connect it
/// first re-registers the services registered through it (asking for the
/// ids they had), then watches every type and rebuilds [table] from the
/// snapshot. When the channel is lost (it closes, the watch fails or times
/// out) the client marks the table stale, keeps it, and reconnects after
/// [reconnectDelay], until [close].
///
/// When a `REGISTER` or `UNREGSTR` has no clear outcome (no answer in time,
/// or an unreadable answer) the client drops the channel itself: the naming
/// service then discards everything registered on it, and the reconnect
/// registers the remembered set again. Neither a phantom record nor an
/// untracked one is left behind.
///
/// See the wiki page "Switchboard Naming Service", section "Mirror
/// behaviour".
class NamingClient {
  /// Creates a client. Nothing happens until [start].
  ///
  /// [connect] opens a fresh Talk channel to the naming service; it is
  /// called on start and again after a loss, with [reconnectDelay] between
  /// attempts. [watchTimeout] is the requester timeout of the `WATCH`
  /// request (default 15 s): if nothing, not even a heartbeat `EXTEND`,
  /// arrives for that long the naming service is considered lost. It must be
  /// longer than the service's heartbeat.
  NamingClient(
    TalkConnector connect, {
    this.reconnectDelay = const Duration(seconds: 1),
    Duration? watchTimeout,
  }) : _connect = connect,
       watchTimeout = watchTimeout ?? const Duration(seconds: 15);

  final TalkConnector _connect;

  /// Delay before each reconnect attempt.
  final Duration reconnectDelay;

  /// Requester timeout of the `WATCH` request.
  final Duration watchTimeout;

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
  /// first `SYNCED` and stale while not [isSynced].
  late final Map<ServiceAddress, ServiceRecord> table = UnmodifiableMapView(
    _table,
  );

  /// Changes of [table]: `UP` when a record appears or its endpoints
  /// change, `DOWN` (address only) when it disappears, including records
  /// found missing when a new snapshot arrives after a reconnect. Broadcast
  /// stream; it ends on [close].
  Stream<ServiceEvent> get events => _events.stream;

  /// True while a channel to the naming service is open.
  bool get isConnected => _session?.alive ?? false;

  /// True after `SYNCED` on the current channel; false while disconnected.
  bool get isSynced => _isSynced;

  /// True once any channel has reached `SYNCED`: [table] has been complete
  /// at least once. A later loss of the naming service does not reset it;
  /// the table is then stale ([isSynced] is false) but still served.
  bool get hasSynced => _hasSynced;

  /// Completes on the first `SYNCED` ever, when [hasSynced] becomes true.
  /// One-shot: unlike [synced] it is never replaced after a loss. Fails
  /// with [StatusCode.cancelled] if [close] is called before that.
  Future<void> get firstSynced => _firstSynced.future;

  /// True after [close].
  bool get isClosed => _closed;

  /// Completes after `SYNCED` of the current session. After a loss of the
  /// channel this returns a new future for the next session (unless the
  /// previous one never completed, in which case it is the same one).
  /// Fails with [StatusCode.cancelled] if [close] is called first.
  Future<void> get synced => _synced.future;

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
  /// accepted.
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
  /// endpoints, only the newest registration is remembered, and the earlier
  /// call's future completes (or fails) like this one.
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
  /// or an instance outside the `u48` range.
  Future<int> register(
    Name type,
    List<Uri> endpoints, {
    int instance = 0,
    void Function(int instance)? onAssigned,
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
    } catch (e, st) {
      return Future.error(e, st);
    }
    final entry = _Entry(
      type,
      List.unmodifiable(endpoints),
      instance,
      onAssigned,
    );
    if (instance != 0) {
      // Registering an id again replaces its endpoints: the older entry is
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
  /// the client unregisters it as soon as the answer arrives.
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
  /// this client's registrations), fails pending [register] futures and
  /// [synced] with [StatusCode.cancelled], and ends [events]. No timer is
  /// left running. Calling it again returns the same future.
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
    await _events.close();
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
      _onServerMessage,
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
      _startWatch(session);
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
  }

  void _onServerMessage(TalkMessage message) {
    // The naming service sends no requests of its own.
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
      _log.fine('ignoring message ${message.procedureName}');
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
    final requested = instance ?? entry.instance;
    final int assigned;
    try {
      final response = await session.channel.request(
        Procedures.register.toString(),
        RegisterRequest(
          entry.type,
          requestedInstance: requested,
          endpoints: entry.endpoints,
        ).encode(),
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
    if (entry.superseded) {
      // A newer registration of the same id took over; it registers the
      // endpoints it wants on its own.
      return;
    }
    if (!_entries.contains(entry)) {
      // Unregistered while the request was in flight.
      if (session.usable) {
        try {
          await _sendUnregister(session, entry.type, assigned);
        } catch (e) {
          _log.fine('late unregister failed: $e');
        }
      }
      return;
    }
    if (entry.completer.isCompleted && assigned != entry.instance) {
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
    // ended up with the same id (it asked for any id and was given the one
    // this entry asked for) is superseded by this, the later answer.
    for (final older in [
      for (final e in _entries)
        if (!identical(e, entry) &&
            e.type == entry.type &&
            e.instance == assigned &&
            e.completer.isCompleted)
          e,
    ]) {
      _supersede(older, entry);
    }
    _log.fine('registered ${ServiceAddress(entry.type, assigned)}');
    if (changed) {
      _notifyAssigned(entry, assigned);
    }
    if (!entry.completer.isCompleted) {
      entry.completer.complete(assigned);
    }
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
      // may have registered it after all, the record must not outlive the
      // channel unnoticed.
      if (indeterminate) {
        session.lose(
          Status.of(StatusCode.aborted, 'REGISTER outcome unknown'),
          'REGISTER $address has no clear outcome ($error)',
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
    if (!older.completer.isCompleted) {
      newer.completer.future.then(
        older.completer.complete,
        onError: older.completer.completeError,
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

  void _startWatch(_Session session) {
    final TalkStream watch;
    try {
      watch = session.channel.streamRequest(
        Procedures.watch.toString(),
        const WatchRequest().encode(),
        timeout: watchTimeout,
      );
    } on SwitchboardException catch (e) {
      session.lose(Status.ok, 'cannot watch: $e');
      return;
    }
    session.watchItems = watch.items.listen(
      (item) => _onWatchItem(session, item),
      onError: (Object e) {
        final status = e is SwitchboardException
            ? e.status
            : Status.of(StatusCode.unknown, '$e');
        session.lose(
          Status.of(StatusCode.unavailable, 'watch failed: $status'),
          'watch failed: $status',
        );
      },
      onDone: () => session.lose(
        Status.of(StatusCode.unavailable, 'watch ended'),
        'watch ended',
      ),
    );
  }

  void _onWatchItem(_Session session, TalkMessage item) {
    if (!session.alive) {
      return;
    }
    if (item.canReply) {
      try {
        item.replyAbort(
          Status.of(StatusCode.unimplemented, 'no reply to watch items'),
        );
      } on SwitchboardException catch (e) {
        _log.fine('abort failed: $e');
      }
    }
    final procedure = item.procedure;
    try {
      if (procedure == Procedures.up) {
        final record = ServiceRecord.decode(item.payload);
        if (session.syncing) {
          session.seen.add(record.address);
        }
        _applyUp(record);
      } else if (procedure == Procedures.down) {
        final address = ServiceEvent.decodeDown(item.payload).record.address;
        session.seen.remove(address);
        _applyDown(address);
      } else if (procedure == Procedures.synced) {
        _onSynced(session);
      } else {
        _log.fine('ignoring watch item ${item.procedureName}');
      }
    } on ProtocolException catch (e) {
      _log.warning('malformed ${item.procedureName} item: $e');
    }
  }

  void _onSynced(_Session session) {
    if (!session.syncing) {
      _log.warning('second SYNCED on one watch ignored');
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
  _Entry(this.type, this.endpoints, this.instance, this.onAssigned);

  final Name type;
  final List<Uri> endpoints;

  /// Told about every new id.
  final void Function(int instance)? onAssigned;

  /// The assigned id once registered, else the requested id (0: any).
  int instance;

  /// The session this entry is registered on.
  _Session? session;

  /// The session a REGISTER for this entry is in flight on.
  _Session? pending;

  /// Replaced by a newer registration of the same address.
  bool superseded = false;

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
  StreamSubscription<TalkMessage>? watchItems;
  Future<void>? closeChannel;
  final Set<Timer> _timers = {};

  /// Before `SYNCED`: addresses seen in the snapshot.
  bool syncing = true;
  final Set<ServiceAddress> seen = {};

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
    watchItems?.cancel().ignore();
    messages?.cancel().ignore();
    await closeChannel;
    if (!_closed.isCompleted) {
      _closed.complete();
    }
  }
}
