/*
Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Author: Jan Boon <jan.boon@kaetemi.be>
*/

import 'dart:async';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:stream_channel/stream_channel.dart';

import '../mux/mux_channel.dart';
import '../mux/mux_frame.dart';
import '../name.dart';
import '../status.dart';
import '../status_closable.dart';

final Logger _log = Logger('Switchboard.Router');

/// Opens the replacement channel after a `MOVED` rejection, or returns
/// null when there is nowhere else to go.
typedef SlotReopen = Future<MuxChannel?> Function(Status moved);

/// A channel to the owner of a shard slot, opened with
/// `Switchboard.openChannelToSlot`.
///
/// It forwards to an underlying [MuxChannel] ([channel]) and behaves like
/// one. In addition it retries **once** when the owner rejects the channel
/// with CLOSE `MOVED` (the slot moved, and the router's table was stale)
/// **before anything was sent on it or received from it**: the
/// replacement channel is opened to the owner the rejection names (or, if
/// it names none, the one the router finds by refreshing the slot) with
/// the same open payload, and takes over transparently. Subframes the
/// caller sends while the replacement is being opened are sent on it, in
/// order.
///
/// Once the caller has sent a subframe, or a subframe has arrived, a
/// `MOVED` close is surfaced like any other close ([done]): the owner may
/// have acted on what was sent (an instance that loses a slot closes the
/// channels it was serving with `MOVED`), so resending it could apply it
/// twice. Protocols in which the server speaks first (a greeting or a
/// snapshot before the client sends) get the retry on every open; Talk
/// clients that send their first request at once see a `MOVED` only when
/// the router's table was stale, and retry at their own level.
class SlotChannel with StreamChannelMixin<Uint8List> implements StatusClosable {
  /// Wraps [channel], the first channel opened for [slot] of [type];
  /// [reopen] opens the replacement. Created by
  /// `Switchboard.openChannelToSlot`.
  @internal
  SlotChannel(this.type, this.slot, MuxChannel channel, this._reopen)
    : _current = channel {
    _sink = _SlotChannelSink(this);
    _incoming = StreamController<Uint8List>(
      onListen: () {
        // While a replacement is being opened, the retry subscribes to it.
        if (!_reopening) {
          _subscribe(_current);
        }
      },
      onPause: () => _subscription?.pause(),
      onResume: () => _subscription?.resume(),
      onCancel: () => _subscription?.cancel(),
    );
    _watch(channel);
  }

  /// The sharded type.
  final Name type;

  /// The slot this channel is addressed to.
  final int slot;

  final SlotReopen _reopen;
  MuxChannel _current;
  // Closing it closes the channel; the caller decides when.
  // ignore: close_sinks
  late final _SlotChannelSink _sink;
  late final StreamController<Uint8List> _incoming;
  StreamSubscription<Uint8List>? _subscription;
  final Completer<Status> _done = Completer<Status>();
  final List<Uint8List> _pending = [];

  bool _sent = false;
  bool _received = false;
  bool _retried = false;
  bool _reopening = false;
  bool _final = false;
  bool _streamEnded = false;
  Status? _closeRequested;

  /// The current underlying channel: the first one, or the replacement
  /// after a retry.
  MuxChannel get channel => _current;

  /// Whether the channel was rejected with `MOVED` and replaced.
  bool get retried => _retried;

  /// Whether DATA may be sent: the current channel is open, or its
  /// replacement is being opened.
  bool get canSend => _closeRequested == null && (_holding || _current.canSend);

  /// Incoming DATA subframes of the current channel; single subscription,
  /// buffered until listened to. Ends when the final channel ends; read
  /// [done] for the reason.
  @override
  Stream<Uint8List> get stream => _incoming.stream;

  /// Sink for outgoing subframes, as [MuxChannel.sink].
  @override
  StreamSink<Uint8List> get sink => _sink;

  /// The end status of the final channel. A `MOVED` that was retried is
  /// not reported; a `MOVED` that was not is. Never completes with an
  /// error.
  @override
  Future<Status> get done => _done.future;

  /// Sends one DATA subframe, as [MuxChannel.send]. While the replacement
  /// channel is being opened the subframe is held and sent on it.
  void send(Uint8List subframe) {
    if (_closeRequested != null) {
      throw SwitchboardException.of(
        StatusCode.failedPrecondition,
        'slot channel is closing',
      );
    }
    if (_holding) {
      _pending.add(subframe);
      return;
    }
    _sent = true;
    _current.send(subframe);
  }

  /// Whether a subframe must be held for a possible replacement: one is
  /// being opened, or the first channel is already closing (a rejection
  /// on its way) and nothing has gone out on it.
  bool get _holding =>
      _reopening || (!_retried && !_sent && !_current.canSend && !_final);

  /// Closes the current channel with [status], as [MuxChannel.close]; a
  /// replacement being opened is closed as soon as it is open. Completes
  /// when [done] does.
  @override
  Future<void> close([Status status = Status.ok]) {
    checkMuxStatus(status);
    if (_closeRequested == null && !_done.isCompleted) {
      _closeRequested = status;
      _pending.clear();
      if (!_reopening) {
        unawaited(_current.close(status));
      }
    }
    return _done.future.then<void>((_) {});
  }

  void _watch(MuxChannel channel) {
    unawaited(channel.done.then((status) => _ended(channel, status)));
  }

  void _subscribe(MuxChannel channel) {
    _streamEnded = false;
    _subscription = channel.stream.listen(
      (subframe) {
        if (identical(channel, _current)) {
          _received = true;
          _incoming.add(subframe);
        }
      },
      onError: (Object e, StackTrace st) {
        if (identical(channel, _current)) {
          _incoming.addError(e, st);
        }
      },
      onDone: () {
        if (!identical(channel, _current)) {
          return;
        }
        _streamEnded = true;
        if (_final) {
          unawaited(_incoming.close());
        }
      },
    );
    if (_incoming.isPaused) {
      _subscription!.pause();
    }
  }

  void _ended(MuxChannel channel, Status status) {
    if (!identical(channel, _current)) {
      return;
    }
    final retry =
        status.known == StatusCode.moved &&
        !_retried &&
        !_sent &&
        !_received &&
        channel.bufferedBytes == 0 &&
        _closeRequested == null;
    if (retry) {
      unawaited(_retry(status));
    } else {
      _finish(status);
    }
  }

  void _finish(Status status) {
    _final = true;
    _pending.clear();
    if (!_done.isCompleted) {
      _done.complete(status);
    }
    if (_streamEnded) {
      unawaited(_incoming.close());
    }
  }

  Future<void> _retry(Status moved) async {
    _retried = true;
    _reopening = true;
    final old = _subscription;
    _subscription = null;
    _streamEnded = false;
    await old?.cancel();
    MuxChannel? next;
    try {
      next = await _reopen(moved);
    } on Object catch (e) {
      _log.fine('$type/$slot: retry after ${moved.reason} failed: $e');
    }
    _reopening = false;
    if (next == null) {
      // Reported as the rejection itself: the caller re-resolves.
      _streamEnded = true;
      _finish(moved);
      return;
    }
    _log.fine('$type/$slot moved (${moved.reason}), retried on $next');
    _current = next;
    _watch(next);
    if (_incoming.hasListener) {
      _subscribe(next);
    }
    final requested = _closeRequested;
    if (requested != null) {
      unawaited(next.close(requested));
      return;
    }
    final pending = List.of(_pending);
    _pending.clear();
    try {
      for (final subframe in pending) {
        _sent = true;
        next.send(subframe);
      }
    } on SwitchboardException catch (e) {
      _log.fine('$type/$slot: held subframes not sent: ${e.status}');
      unawaited(next.close(e.status.isOk ? Status.ok : e.status));
    }
  }

  @override
  String toString() =>
      'SlotChannel($type/$slot on $_current${_retried ? ', retried' : ''})';
}

/// The sink of a [SlotChannel], as the mux channel's sink.
class _SlotChannelSink implements StreamSink<Uint8List> {
  _SlotChannelSink(this._channel);

  final SlotChannel _channel;
  bool _closed = false;

  @override
  void add(Uint8List event) {
    if (_closed) {
      throw StateError('slot channel sink is closed');
    }
    if (_channel.canSend) {
      _channel.send(event);
    }
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {
    if (_closed) {
      throw StateError('slot channel sink is closed');
    }
    _closed = true;
    var status = error is SwitchboardException
        ? error.status
        : Status.of(StatusCode.internal, error.toString());
    if (status.isApplicationCode) {
      status = Status.of(StatusCode.unknown, status.toString());
    }
    unawaited(_channel.close(status));
  }

  @override
  Future<void> addStream(Stream<Uint8List> stream) async {
    await for (final subframe in stream) {
      if (_closed) {
        break;
      }
      if (_channel.canSend) {
        _channel.send(subframe);
      }
    }
  }

  @override
  Future<void> close() {
    _closed = true;
    return _channel.close();
  }

  @override
  Future<void> get done => _channel.done;
}
