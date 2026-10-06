/*
Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Author: Jan Boon <jan.boon@kaetemi.be>
*/

part of 'reconnecting_client.dart';

/// Close statuses after which a persistent channel is not re-opened: the
/// endpoint will refuse it again until the application changes something
/// (its credential, the address).
bool _isTerminal(Status status) => switch (status.known) {
  StatusCode.permissionDenied ||
  StatusCode.unauthenticated ||
  StatusCode.unimplemented ||
  StatusCode.notFound => true,
  _ => false,
};

/// A channel of a [ReconnectingClient] that is opened again on every
/// connection, created by [ReconnectingClient.openPersistent].
///
/// Each time a connection is established the channel is opened and the
/// `onOpen` callback receives it; when it ends, `onClosed` receives its end
/// status. Every `onOpen` is followed by exactly one `onClosed`.
///
/// * The connection ends: the channel is opened again on the next
///   connection.
/// * The channel ends while the connection stays up (the endpoint closed
///   it, or the application closed [current] itself): it is opened again
///   after a backoff following the client's schedule, kept per persistent
///   channel and reset by a channel that lasted longer than
///   [ReconnectingClient.maxBackoff]. If the connection received GOAWAY,
///   it waits for the next connection instead.
/// * The channel ends with `PERMISSION_DENIED`, `UNAUTHENTICATED`,
///   `UNIMPLEMENTED` or `NOT_FOUND`: the persistent channel ends for good
///   ([isClosed], [done] completes with that status, [opened] ends), since
///   the endpoint would refuse it again. The application decides what to
///   do, for example refresh [ReconnectingClient.defaultPayload] and call
///   [ReconnectingClient.openPersistent] again.
/// * [close] ends it for good.
///
/// An OPEN that cannot be sent is handled the same way: on a connection
/// that received GOAWAY it waits for the next connection; beyond the
/// endpoint's channel limit (`RESOURCE_EXHAUSTED`) it is retried after the
/// backoff; any other refusal (an OPEN beyond the endpoint's frame limit)
/// ends the persistent channel with `onClosed` called once with that
/// status.
///
/// ```dart
/// final events = client.openPersistent(
///   ChannelAddress(type: Name('events')),
///   (channel) => channel.stream.listen(onEvent),
///   onClosed: (status) => log.fine('events channel ended: $status'),
/// );
/// // Later:
/// await events.close();
/// ```
class PersistentChannel {
  PersistentChannel._(this._core);

  final _PersistentCore<MuxChannel> _core;

  /// The address every channel is opened with.
  ChannelAddress get address => _core.address;

  /// The open channel, or null between connections, while waiting to
  /// re-open, and once closed.
  MuxChannel? get current => _core.current;

  /// Each newly opened channel, after `onOpen` was called with it.
  /// Broadcast; ends when the persistent channel ends for good.
  Stream<MuxChannel> get opened => _core.opened.stream;

  /// Whether the persistent channel has ended for good or [close] was
  /// called: no channel will be opened for it again.
  bool get isClosed => _core.closing;

  /// Completes when the persistent channel has ended for good: with the
  /// end status of its last channel (OK after [close], unless the channel
  /// ended otherwise), or the terminal status that ended it. Never fails.
  Future<Status> get done => _core.done.future;

  /// Ends the persistent channel: stops re-opening it and closes [current]
  /// with OK. Completes when the channel is closed and `onClosed` has been
  /// called. Calling it again returns when the same has happened. Never
  /// throws.
  Future<void> close() => _core.close();

  @override
  String toString() => _core.toString();
}

/// A Talk channel of a [ReconnectingClient] that is opened again on every
/// connection, created by [ReconnectingClient.openPersistentTalk]. Behaves
/// like [PersistentChannel], each channel wrapped in a [TalkChannel]; the
/// status that decides whether it is opened again is the Talk channel's
/// end status ([TalkChannel.done]), so a channel abort with a terminal
/// status ends it too.
///
/// ```dart
/// final feed = client.openPersistentTalk(
///   ChannelAddress(type: Name('feed')),
///   (talk) async {
///     talk.messages.listen(onFeedMessage);
///     // Sent again on every connection.
///     await talk.request('SUB', topic);
///   },
/// );
/// ```
class PersistentTalk {
  PersistentTalk._(this._core);

  final _PersistentCore<TalkChannel> _core;

  /// The address every channel is opened with.
  ChannelAddress get address => _core.address;

  /// The open Talk channel, or null between connections, while waiting to
  /// re-open, and once closed.
  TalkChannel? get current => _core.current;

  /// Each newly opened Talk channel, after `onOpen` was called with it.
  /// Broadcast; ends when the persistent channel ends for good.
  Stream<TalkChannel> get opened => _core.opened.stream;

  /// Whether the persistent channel has ended for good or [close] was
  /// called: no channel will be opened for it again.
  bool get isClosed => _core.closing;

  /// Completes when the persistent channel has ended for good: with the
  /// end status of its last Talk channel (OK after [close], unless the
  /// channel ended otherwise), or the terminal status that ended it. Never
  /// fails.
  Future<Status> get done => _core.done.future;

  /// Ends the persistent channel: stops re-opening it and closes [current]
  /// with OK (outstanding requests fail with [StatusCode.cancelled]).
  /// Completes when the channel is closed and `onClosed` has been called.
  /// Never throws.
  Future<void> close() => _core.close();

  @override
  String toString() => _core.toString();
}

/// The re-opening logic shared by [PersistentChannel] and
/// [PersistentTalk]. [T] is what the application receives for each mux
/// channel.
class _PersistentCore<T extends Object> {
  _PersistentCore(
    this.client,
    this.address, {
    required this.kind,
    required this.wrap,
    required this.closeValue,
    required this.doneOf,
    required this.onOpen,
    required this.onClosed,
  });

  final ReconnectingClient client;
  final ChannelAddress address;
  final String kind;
  final T Function(MuxChannel channel) wrap;
  final Future<void> Function(T value, Status status) closeValue;
  final Future<Status> Function(T value) doneOf;
  final FutureOr<void> Function(T value) onOpen;
  final void Function(Status status)? onClosed;

  final StreamController<T> opened = StreamController<T>.broadcast();
  final Completer<Status> done = Completer<Status>();

  /// The mux channel under [current].
  MuxChannel? _channel;
  T? current;

  /// Will not be opened again: closed by the application, or finished.
  bool closing = false;
  bool _finished = false;
  int _failures = 0;
  bool _livedLong = false;
  Timer? _retryTimer;
  Timer? _lifetimeTimer;

  /// A connection became usable: open now unless already open.
  void connectionUp(MuxConnection connection) {
    if (closing || _channel != null) {
      return;
    }
    _openOn(connection);
  }

  /// The client stopped: close the channel on [connection]; it is opened
  /// again on the next connection.
  void retire(MuxConnection connection) {
    _cancelRetry();
    final value = current;
    if (value == null || !identical(_channel?.connection, connection)) {
      return;
    }
    _closeQuietly(value, Status.of(StatusCode.goingAway, 'client stopping'));
  }

  Future<void> close() {
    if (!closing) {
      closing = true;
      _cancelRetry();
      final value = current;
      if (value == null) {
        _finish(Status.ok);
      } else {
        // The end of the channel finishes.
        _closeQuietly(value, Status.ok);
      }
    }
    return done.future;
  }

  void _openOn(MuxConnection connection) {
    _cancelRetry();
    final MuxChannel channel;
    try {
      channel = connection.open(client._encode(address));
    } on SwitchboardException catch (e) {
      switch (e.code) {
        case StatusCode.failedPrecondition:
          _log.fine('$this: connection going away, waiting for the next');
        case StatusCode.resourceExhausted:
          _log.info('$this: cannot open: ${e.status}');
          _scheduleRetry();
        default:
          _log.warning('$this: cannot open: ${e.status}');
          _finish(e.status);
          _callOnClosed(e.status);
      }
      return;
    }
    final value = wrap(channel);
    _channel = channel;
    current = value;
    _livedLong = false;
    _lifetimeTimer = Timer(client.maxBackoff, () {
      _lifetimeTimer = null;
      _livedLong = true;
    });
    doneOf(value).then<void>((status) => _onEnded(channel, status)).ignore();
    _log.fine('$this: opened channel ${channel.id}');
    _callOnOpen(value);
    if (!opened.isClosed && identical(current, value)) {
      opened.add(value);
    }
  }

  Future<void> _onEnded(MuxChannel channel, Status status) async {
    if (!identical(_channel, channel)) {
      return;
    }
    final connection = channel.connection;
    if (identical(client._connection, connection) && !connection.isOpen) {
      // The connection is ending: let the client report the disconnect
      // first.
      await connection.done;
      if (!identical(_channel, channel)) {
        return;
      }
    }
    _channel = null;
    current = null;
    _lifetimeTimer?.cancel();
    _lifetimeTimer = null;
    if (_livedLong) {
      _failures = 0;
    }
    final ends = closing || _isTerminal(status);
    if (ends) {
      if (!closing) {
        _log.info('$this: ended with $status, not re-opening');
      }
      _finish(status);
    } else {
      _log.fine('$this: channel ${channel.id} ended with $status');
    }
    _callOnClosed(status);
    if (ends || closing) {
      return;
    }
    final usable = client._usableConnection;
    if (usable == null) {
      // Opened again by the client on the next connection.
      return;
    }
    if (identical(usable, connection)) {
      _scheduleRetry();
    } else {
      _openOn(usable);
    }
  }

  void _scheduleRetry() {
    _cancelRetry();
    final delay = client._backoff(_failures++);
    _log.fine('$this: re-opening in $delay');
    _retryTimer = Timer(delay, () {
      _retryTimer = null;
      if (closing || _channel != null) {
        return;
      }
      final connection = client._usableConnection;
      if (connection != null) {
        _openOn(connection);
      }
    });
  }

  void _cancelRetry() {
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  void _finish(Status status) {
    if (_finished) {
      return;
    }
    _finished = true;
    closing = true;
    _cancelRetry();
    _lifetimeTimer?.cancel();
    _lifetimeTimer = null;
    client._persistent.remove(this);
    done.complete(status);
    opened.close().ignore();
  }

  void _closeQuietly(T value, Status status) {
    try {
      closeValue(value, status)
          .then<void>(
            (_) {},
            onError: (Object e) => _log.fine('$this: close failed: $e'),
          )
          .ignore();
    } on Object catch (e) {
      _log.fine('$this: close failed: $e');
    }
  }

  void _callOnOpen(T value) {
    try {
      final result = onOpen(value);
      if (result is Future<void>) {
        result
            .then<void>(
              (_) {},
              onError: (Object e, StackTrace st) =>
                  _log.warning('$this: onOpen failed', e, st),
            )
            .ignore();
      }
    } on Object catch (e, st) {
      _log.warning('$this: onOpen failed', e, st);
    }
  }

  void _callOnClosed(Status status) {
    final callback = onClosed;
    if (callback == null) {
      return;
    }
    try {
      callback(status);
    } on Object catch (e, st) {
      _log.warning('$this: onClosed failed', e, st);
    }
  }

  @override
  String toString() => '$kind($address)';
}
