/*
Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Author: Jan Boon <jan.boon@kaetemi.be>
*/

import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:meta/meta.dart';

import '../address/service_address.dart';
import '../name.dart';
import '../status.dart';
import '../talk/talk_channel.dart';
import '../talk/talk_message.dart';
import 'naming_protocol.dart';

final Logger _log = Logger('Switchboard.Naming');

/// The naming service (`_ns`): hands out instance ids, keeps the
/// authoritative table of live service instances, and pushes changes to
/// watchers. See the wiki page "Switchboard Naming Service".
///
/// The service speaks Talk over channels handed to [serve], one per client.
/// A registration is owned by the channel it was made on; when that channel
/// closes for any reason, every record it owns is removed and `DOWN` is
/// published for each. This is the only liveness mechanism.
///
/// Procedures: `REGISTER`, `UNREGSTR` (requests), `WATCH`, `LOOKUP` (stream
/// requests). Requests for any other procedure are answered with
/// `ABORT UNIMPLEMENTED`; plain messages are ignored. Malformed payloads are
/// answered with `ABORT INVALID_ARGUMENT`.
///
/// The service registers nothing by itself. The wiki registers the naming
/// service in its own table as `_ns/1`; the host does that with
/// [registerLocal] once it knows its listening endpoints.
class NamingService {
  /// Creates an empty service.
  ///
  /// [heartbeat] is the interval at which an idle watch is sent `EXTEND`.
  /// It must be shorter than the [TalkOptions.replyTimeout] of every channel
  /// passed to [serve] (10 s by default), otherwise the responder timeout of
  /// the channel aborts the watch with `DEADLINE_EXCEEDED`; it must also be
  /// shorter than the watcher's request timeout. The wiki requires at most
  /// 5 s, the default. Throws [ArgumentError] if it is not positive.
  NamingService({this.heartbeat = const Duration(seconds: 5)}) {
    if (heartbeat <= Duration.zero) {
      throw ArgumentError.value(heartbeat, 'heartbeat', 'must be positive');
    }
  }

  /// Interval at which an idle watch is sent `EXTEND`.
  final Duration heartbeat;

  final Map<ServiceAddress, ServiceRecord> _table = {};
  final Map<int, _Registration> _instances = {};
  final Set<_Session> _sessions = {};
  final Set<_Watch> _watches = {};
  final StreamController<ServiceEvent> _events =
      StreamController<ServiceEvent>.broadcast();
  int _nextInstance = 1;
  bool _closed = false;
  Future<void>? _closeFuture;

  /// Read-only live view of the table: every registered record by address.
  late final Map<ServiceAddress, ServiceRecord> table = UnmodifiableMapView(
    _table,
  );

  /// Every `UP` and `DOWN` the service publishes, in order. Broadcast
  /// stream; it ends when the service is closed.
  Stream<ServiceEvent> get events => _events.stream;

  /// Number of outstanding `WATCH` requests over all channels.
  int get watchCount => _watches.length;

  /// Number of channels currently served.
  int get channelCount => _sessions.length;

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

  /// Serves one client over [channel] until it closes. Registrations made
  /// on this channel are removed, with `DOWN` events, when it closes.
  ///
  /// Takes over [TalkChannel.messages], so each channel can be served only
  /// once. The channel keeps its own options; see [heartbeat] for the
  /// constraint on [TalkOptions.replyTimeout]. After [close] the channel is
  /// closed immediately with [StatusCode.goingAway].
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
    _sessions.add(session);
    session.subscription = channel.messages.listen(
      (message) => _onMessage(session, message),
      onError: (Object error) =>
          _log.fine('naming client channel failed: $error'),
      onDone: () => _drop(session),
    );
    unawaited(channel.done.then((_) => _drop(session)));
  }

  /// Registers a record owned by the service itself rather than by a
  /// channel, for example `_ns/1` with the service's own endpoints. It stays
  /// until [unregisterLocal]; registering the same address locally again
  /// replaces its endpoints.
  ///
  /// [instance] 0 assigns an id. Returns the instance id. Throws
  /// [SwitchboardException] with [StatusCode.invalidArgument] for an empty
  /// type, [StatusCode.alreadyExists] if [instance] is in use by another
  /// registration, [StatusCode.resourceExhausted] if no id is left, and
  /// [StatusCode.failedPrecondition] after [close]; also
  /// [StatusCode.invalidArgument] for more than 255 endpoints or an endpoint
  /// longer than 255 bytes. Throws [RangeError] for an instance outside the
  /// `u48` range.
  int registerLocal(Name type, List<Uri> endpoints, {int instance = 0}) {
    if (_closed) {
      throw SwitchboardException.of(
        StatusCode.failedPrecondition,
        'naming service closed',
      );
    }
    if (instance < 0 || instance > maxInstance) {
      throw RangeError.range(instance, 0, maxInstance, 'instance');
    }
    return _add(type, instance, endpoints, null);
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

  /// Aborts every watch with [StatusCode.goingAway], removes the records of
  /// every channel (publishing `DOWN`), closes the channels with
  /// [StatusCode.goingAway], and ends [events]. Records made with
  /// [registerLocal] stay in [table]. Calling it again returns the same
  /// future.
  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    _closed = true;
    final goingAway = Status.of(StatusCode.goingAway, 'naming service closed');
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
    } on ProtocolException catch (e) {
      _abort(message, Status.of(StatusCode.invalidArgument, e.status.reason));
      return;
    }
    final int instance;
    try {
      instance = _add(
        request.type,
        request.requestedInstance,
        request.endpoints,
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
      message.reply(Uint8List(0));
    } on SwitchboardException catch (e) {
      _log.fine('LOOKUP reply failed: $e');
    }
  }

  // ---------------------------------------------------------------------
  // Table

  /// Adds or replaces a registration and publishes `UP`. [owner] null is a
  /// local registration.
  int _add(Name type, int requested, List<Uri> endpoints, _Session? owner) {
    if (type.isEmpty) {
      throw SwitchboardException.of(
        StatusCode.invalidArgument,
        'empty service type',
      );
    }
    // A decoded endpoint can re-encode longer than it arrived (Uri
    // normalisation); a record that cannot be encoded must never reach the
    // table, or every later snapshot would fail.
    try {
      ServiceRecord(ServiceAddress(type, 1), endpoints: endpoints).encode();
    } on ArgumentError catch (e) {
      throw SwitchboardException.of(
        StatusCode.invalidArgument,
        'endpoints not encodable: ${e.message}',
      );
    }
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
    _log.info('unregistered $address');
    _publish(ServiceEvent(up: false, record: ServiceRecord(address)));
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

/// A record in the table and the channel that owns it (null: local).
class _Registration {
  _Registration(this.address, this.owner);

  final ServiceAddress address;
  final _Session? owner;
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
