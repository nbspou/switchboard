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
  /// is assigned (and logged). While disconnected, the returned future
  /// completes once the registration succeeds after the next connect.
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
  /// [ArgumentError] or [RangeError] for more than 255 endpoints, an endpoint
  /// longer than 255 bytes, or an instance outside the `u48` range.
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
      // Validates the endpoints.
      RegisterRequest(
        type,
        requestedInstance: instance,
        endpoints: endpoints,
      ).encode();
    } catch (e, st) {
      return Future.error(e, st);
    }
    if (instance != 0) {
      // Registering an id again replaces its endpoints; the older entry is
      // superseded.
      _entries.removeWhere(
        (e) =>
            e.type == type && e.instance == instance && e.completer.isCompleted,
      );
    }
    final entry = _Entry(
      type,
      List.unmodifiable(endpoints),
      instance,
      onAssigned,
    );
    _entries.add(entry);
    final session = _session;
    if (session != null && session.alive) {
      unawaited(_registerOn(session, entry));
    }
    return entry.completer.future;
  }

  /// Removes the registration of `type/instance` made through this client
  /// and stops re-registering it.
  ///
  /// While disconnected it completes immediately: the naming service already
  /// dropped the record with the channel. Fails with [StatusCode.notFound]
  /// if this client has no such registration, with the naming service's
  /// status if it refuses, and with [StatusCode.failedPrecondition] after
  /// [close].
  Future<void> unregister(Name type, int instance) async {
    if (_closed) {
      throw SwitchboardException.of(
        StatusCode.failedPrecondition,
        'naming client closed',
      );
    }
    _Entry? entry;
    for (final e in _entries) {
      if (e.type == type && e.instance == instance && instance != 0) {
        entry = e;
        break;
      }
    }
    if (entry == null) {
      throw SwitchboardException.of(
        StatusCode.notFound,
        'no registration $type/${instance.toRadixString(16)}',
      );
    }
    _entries.remove(entry);
    if (!entry.completer.isCompleted) {
      entry.completer.future.ignore();
      entry.completer.completeError(
        SwitchboardException.of(StatusCode.cancelled, 'unregistered'),
      );
    }
    final session = _session;
    if (session == null || !session.usable || entry.session != session) {
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

    // Re-register first, so other services' channels to our ids stay valid
    // where possible, then watch.
    await Future.wait([
      for (final entry in _entries.toList()) _registerOn(session, entry),
    ]);
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
    try {
      final response = await session.channel.request(
        Procedures.register.toString(),
        RegisterRequest(
          entry.type,
          requestedInstance: requested,
          endpoints: entry.endpoints,
        ).encode(),
      );
      final assigned = RegisterResponse.decode(response.payload).instance;
      if (!_entries.contains(entry)) {
        // Unregistered while the request was in flight.
        if (session.usable) {
          try {
            await _sendUnregister(session, entry.type, assigned);
          } on SwitchboardException catch (e) {
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
      final changed =
          !entry.completer.isCompleted || assigned != entry.instance;
      entry.instance = assigned;
      entry.session = session;
      _log.fine('registered ${ServiceAddress(entry.type, assigned)}');
      if (changed) {
        _notifyAssigned(entry, assigned);
      }
      if (!entry.completer.isCompleted) {
        entry.completer.complete(assigned);
      }
    } catch (e, st) {
      if (!_entries.contains(entry) || !session.usable) {
        // Gone, or the channel was lost: kept for the next connect.
        return;
      }
      final remembered = entry.completer.isCompleted;
      if (remembered &&
          requested != 0 &&
          e is SwitchboardException &&
          e.code == StatusCode.alreadyExists) {
        _log.warning(
          '${ServiceAddress(entry.type, requested)} is taken, '
          'asking for a new id',
        );
        entry.pending = null;
        await _registerOn(session, entry, instance: 0);
        return;
      }
      if (remembered) {
        _log.severe(
          're-registering ${ServiceAddress(entry.type, requested)} failed; '
          'retrying after the next reconnect',
          e,
          st,
        );
        return;
      }
      _entries.remove(entry);
      entry.completer.completeError(e, st);
    } finally {
      if (identical(entry.pending, session)) {
        entry.pending = null;
      }
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
    } on SwitchboardException {
      if (!session.usable) {
        // The record went away with the channel.
        return;
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
    _log.info('naming table synced, ${_table.length} records');
    if (!_synced.isCompleted) {
      _synced.complete();
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

  /// Marks the session lost and closes its channel with [status].
  /// Idempotent.
  void lose(Status status, String reason) {
    if (_lost.isCompleted) {
      return;
    }
    _log.info('naming service channel lost: $reason');
    closeChannel = channel.close(status);
    _lost.complete();
    _onLost();
  }

  /// Cancels the subscriptions, waits for the channel to close and
  /// completes [closed].
  Future<void> tearDown() async {
    await watchItems?.cancel();
    await messages?.cancel();
    await closeChannel;
    if (!_closed.isCompleted) {
      _closed.complete();
    }
  }
}
