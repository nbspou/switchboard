/*
Polyverse Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Authors:
  Jan Boon <jan.boon@kaetemi.be>
  Claude Opus 5.5 <noreply@anthropic.com>
*/

import 'dart:async';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:stream_channel/stream_channel.dart';

import '../mux/mux_channel.dart';
import '../mux/mux_connection.dart';
import '../mux/mux_frame.dart';
import '../name.dart';
import '../status.dart';
import '../status_closable.dart';

final Logger _log = Logger('Switchboard.Router');

/// Opens the replacement channel after a `MOVED` rejection, or returns
/// null when there is nowhere else to go. Fails with a
/// [SwitchboardException] [StatusCode.notFound] when the caller's filter
/// refuses the new owner: the [SlotChannel] then ends with that status.
typedef SlotReopen = Future<MuxChannel?> Function(Status moved);

/// A channel to the owner of a shard slot, opened with
/// `Switchboard.openChannelToSlot`.
///
/// It forwards to an underlying [MuxChannel] ([channel]) and behaves like
/// one. In addition it retries **once** when the owner rejects the channel
/// with CLOSE `MOVED` (the slot moved, and the router's table was stale)
/// **before anything was sent on it or received from it**: the
/// replacement channel is opened to the owner the rejection names
/// (`MovedStatus`; or, if it names none, the one the router finds by
/// refreshing the slot) with the same open payload, and takes over
/// transparently. Subframes the caller sends while the replacement is
/// being opened are sent on it, in order. At most [maxHeldBytes] are held
/// meanwhile (each subframe counted as its length plus 32 bytes, as
/// [MuxOptions.maxChannelBufferBytes] counts): a subframe beyond that is
/// dropped, the channel is closed with `RESOURCE_EXHAUSTED`, which [done]
/// reports at once, and a replacement opened after all is closed with it
/// too. Through `proxyHandler` the caller is a remote client, whose
/// subframes would otherwise grow the proxy's memory for as long as the
/// retry takes.
///
/// Once the caller has sent a subframe, or a subframe has arrived, a
/// `MOVED` close is surfaced like any other close ([done]), because the
/// subframes already sent are gone with the old channel. `MOVED` means
/// the owner processed nothing on the channel, so the caller may open the
/// slot again and send the same data. Protocols in which the server
/// speaks first (a greeting or a snapshot before the client sends) get
/// the retry on every open; Talk clients that send their first request at
/// once see a `MOVED` only when the router's table was stale, and retry
/// at their own level.
///
/// A channel the owner was serving when the slot moved on is closed with
/// `RELOCATED` carrying the same owner and epoch fields
/// (`MovedStatus.fromStatus` reads them). It is never retried: the work
/// may have taken effect, and only the application knows whether it can
/// be repeated.
class SlotChannel with StreamChannelMixin<Uint8List> implements StatusClosable {
  /// Wraps [channel], the first channel opened for [slot] of [type];
  /// [reopen] opens the replacement. Created by
  /// `Switchboard.openChannelToSlot` and `proxyHandler`, with the node's
  /// [MuxOptions.maxChannelBufferBytes] as [maxHeldBytes].
  @internal
  SlotChannel(
    this.type,
    this.slot,
    MuxChannel channel,
    this._reopen, {
    this.maxHeldBytes = MuxOptions.defaultMaxChannelBufferBytes,
  }) : _current = channel {
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

  /// Largest number of bytes held while the replacement is being opened,
  /// each subframe counted as its length plus 32; beyond, the channel is
  /// closed with `RESOURCE_EXHAUSTED`. 0 (or less) means no limit, as for
  /// [MuxOptions.maxChannelBufferBytes].
  final int maxHeldBytes;

  /// Accounting overhead of one held subframe, as the mux counts its
  /// receive buffers, so that floods of empty subframes are bounded too.
  static const int _subframeOverhead = 32;

  final SlotReopen _reopen;
  MuxChannel _current;
  // Closing it closes the channel; the caller decides when.
  // ignore: close_sinks
  late final _SlotChannelSink _sink;
  late final StreamController<Uint8List> _incoming;
  StreamSubscription<Uint8List>? _subscription;
  final Completer<Status> _done = Completer<Status>();
  final List<Uint8List> _pending = [];
  int _pendingBytes = 0;

  bool _sent = false;
  bool _received = false;
  bool _retried = false;
  bool _reopening = false;
  bool _final = false;
  bool _streamEnded = false;
  Status? _closeRequested;

  /// The status the channel was closed with when the held subframes went
  /// beyond [maxHeldBytes].
  Status? _overflow;

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
  /// not reported; a `MOVED` that was not is, as is a `RELOCATED`. Never
  /// completes with an error.
  @override
  Future<Status> get done => _done.future;

  /// Sends one DATA subframe, as [MuxChannel.send]. While the replacement
  /// channel is being opened the subframe is held and sent on it; one that
  /// would take the held subframes beyond [maxHeldBytes] is dropped and
  /// closes the channel with `RESOURCE_EXHAUSTED`.
  void send(Uint8List subframe) {
    if (_closeRequested != null) {
      throw SwitchboardException.of(
        StatusCode.failedPrecondition,
        'slot channel is closing',
      );
    }
    if (_holding) {
      final size = subframe.length + _subframeOverhead;
      if (maxHeldBytes > 0 && _pendingBytes + size > maxHeldBytes) {
        _overflowed();
        return;
      }
      _pending.add(subframe);
      _pendingBytes += size;
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
      _dropPending();
      if (!_reopening) {
        unawaited(_current.close(status));
      }
    }
    return _done.future.then<void>((_) {});
  }

  void _dropPending() {
    _pending.clear();
    _pendingBytes = 0;
  }

  /// Stops holding: the held subframes went beyond [maxHeldBytes]. The
  /// channel ends at once with `RESOURCE_EXHAUSTED`; a replacement being
  /// opened is closed with it as soon as it is open.
  void _overflowed() {
    final status = Status.of(
      StatusCode.resourceExhausted,
      'send buffer of $maxHeldBytes bytes exceeded',
    );
    _log.info(
      '$type/$slot: more than $maxHeldBytes bytes sent while the replacement '
      'channel was being opened; closed',
    );
    _overflow = status;
    _closeRequested = status;
    if (_reopening) {
      // Nothing is subscribed to meanwhile: the first channel's stream
      // was cancelled, the replacement's is not open yet.
      _streamEnded = true;
    } else {
      unawaited(_current.close(status));
    }
    _finish(status);
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
    _dropPending();
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
    Status? refused;
    if (_overflow == null) {
      try {
        next = await _reopen(moved);
      } on Object catch (e) {
        _log.fine('$type/$slot: retry after $moved failed: $e');
        if (e is SwitchboardException && e.code == StatusCode.notFound) {
          refused = e.status;
        }
      }
    }
    _reopening = false;
    final overflow = _overflow;
    if (overflow != null) {
      // Ended already; the replacement is not used.
      if (next != null) {
        unawaited(next.close(overflow));
      }
      return;
    }
    if (next == null) {
      // Reported as the rejection itself, so that the caller re-resolves;
      // or, when its filter refused the new owner, as that.
      _streamEnded = true;
      _finish(refused ?? moved);
      return;
    }
    _log.fine('$type/$slot moved ($moved), retried on $next');
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
    _dropPending();
    try {
      for (final subframe in pending) {
        _sent = true;
        unawaited(next.send(subframe));
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
