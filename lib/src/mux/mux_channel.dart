/*
Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Author: Jan Boon <jan.boon@kaetemi.be>
*/

import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:stream_channel/stream_channel.dart';

import '../status.dart';
import '../talk/talk_channel.dart' show StatusClosable;
import 'mux_connection.dart';
import 'mux_frame.dart';

/// State of a channel as seen by the local side.
///
/// See the wiki page "Switchboard Mux", section "State summary per
/// channel". There is no "half closed remote" state: receiving CLOSE on an
/// open channel sends the confirming CLOSE at once and moves to [closed].
enum MuxChannelState {
  /// Both sides may send.
  open,

  /// We sent CLOSE and wait for the peer's CLOSE. DATA already in flight
  /// from the peer is still delivered.
  halfClosedLocal,

  /// Mutually closed, the connection ended, or the peer did not confirm
  /// our CLOSE within [MuxOptions.closeConfirmTimeout].
  closed,
}

/// One channel of a [MuxConnection].
///
/// A [StreamChannel] of subframes: [stream] yields incoming DATA payloads
/// and [sink] sends DATA. Channels are created by [MuxConnection.open] or
/// delivered by [MuxConnection.incoming]; they are never constructed
/// directly.
///
/// Unlike the general [StreamChannel] guarantee, closing the [sink] does
/// not end [stream] at once: DATA the peer sent before it saw our CLOSE is
/// still delivered, and [stream] ends when the peer's CLOSE arrives or the
/// connection drops, as the mux specification describes.
class MuxChannel with StreamChannelMixin<Uint8List> implements StatusClosable {
  MuxChannel._(
    this._link,
    this.connection,
    this.id,
    this.isLocallyOpened,
    this.openPayload,
  ) {
    // Synchronous, fed from [_queue] only while the listener is active, so
    // that every buffered byte is in [_queue] and accounted for.
    _incoming = StreamController<Uint8List>(
      sync: true,
      onListen: _scheduleDrain,
      onResume: _scheduleDrain,
      onCancel: _onCancel,
    );
    _sink = _MuxChannelSink(this);
  }

  /// Accounting overhead of one buffered subframe, so that floods of empty
  /// subframes are bounded by [MuxOptions.maxChannelBufferBytes] too.
  static const int _subframeOverhead = 32;

  final MuxChannelLink _link;

  /// The connection this channel belongs to.
  final MuxConnection connection;

  /// Channel id. Even ids are allocated by the initiator, odd ids by the
  /// acceptor.
  final int id;

  /// Whether the local side opened this channel.
  final bool isLocallyOpened;

  /// The payload of the OPEN frame, passed through unchanged.
  final Uint8List openPayload;

  late final StreamController<Uint8List> _incoming;
  final Queue<Uint8List> _queue = Queue<Uint8List>();
  int _queuedBytes = 0;
  bool _drainScheduled = false;
  bool _discarding = false;
  bool _endRequested = false;
  // The sink is handed to the user, who closes it.
  // ignore: close_sinks
  late final _MuxChannelSink _sink;
  final Completer<Status> _done = Completer<Status>();
  MuxChannelState _state = MuxChannelState.open;
  Status _endStatus = Status.ok;
  bool _closeSent = false;
  bool _closeReceived = false;
  Timer? _confirmTimer;

  /// Current state.
  MuxChannelState get state => _state;

  /// Whether DATA may be sent: the state is [MuxChannelState.open].
  bool get canSend => _state == MuxChannelState.open;

  /// Bytes received and not yet delivered to the [stream]'s listener,
  /// because nobody listens yet or the subscription is paused. Each
  /// subframe counts as its length plus a small fixed overhead. Bounded by
  /// [MuxOptions.maxChannelBufferBytes].
  int get bufferedBytes => _queuedBytes;

  /// Incoming DATA subframes, single subscription, buffered until
  /// listened to. Ends when the peer's CLOSE arrives or the connection
  /// drops; read [done] for the reason.
  ///
  /// At most [MuxOptions.maxChannelBufferBytes] are buffered while nobody
  /// listens or the subscription is paused. Beyond that the channel is
  /// closed with `RESOURCE_EXHAUSTED`, the buffered subframes are dropped
  /// and the stream ends without them. Cancelling the subscription drops
  /// further DATA; it does not close the channel.
  @override
  Stream<Uint8List> get stream => _incoming.stream;

  /// Sink for outgoing subframes.
  ///
  /// `add` sends DATA (silently dropped once the channel can no longer
  /// send), `close` is [close] with [Status.ok] and `done` completes when
  /// the channel is closed. `addError` closes the channel with the error's
  /// status if it is a [SwitchboardException], else with
  /// [StatusCode.internal].
  @override
  StreamSink<Uint8List> get sink => _sink;

  /// Completes with the channel's end status once it is closed: the first
  /// non-OK status sent or received, else OK. If the connection ended
  /// first, [StatusCode.connectionLost], or [StatusCode.goingAway] if the
  /// peer had sent GOAWAY. Never completes with an error.
  ///
  /// Application codes (256 and above) received from a peer, which must
  /// not be sent in CLOSE, are reported as [StatusCode.unknown] with the
  /// original code in the reason, so the status can always be relayed with
  /// [close].
  @override
  Future<Status> get done => _done.future;

  /// Sends one DATA subframe, which may be empty.
  ///
  /// Throws [SwitchboardException] with [StatusCode.failedPrecondition] if
  /// [canSend] is false, and with [StatusCode.frameTooLarge] if the frame
  /// would exceed the limit the peer announced with LIMITS.
  void send(Uint8List subframe) {
    if (!canSend) {
      throw SwitchboardException.of(
        StatusCode.failedPrecondition,
        'channel $id is ${_state.name}',
      );
    }
    final max = _link.host.peerMaxFrameSize;
    final size = MuxFrame.headerSizeFor(id) + subframe.length;
    if (max > 0 && size > max) {
      throw SwitchboardException.of(
        StatusCode.frameTooLarge,
        'frame of $size bytes exceeds the peer limit of $max',
      );
    }
    _link.host.sendFrame(MuxFrame.data(id, subframe));
  }

  /// Sends CLOSE carrying [status] unless already sent.
  ///
  /// The reason is shortened on the wire if needed, on a UTF-8 character
  /// boundary, so that the frame fits the peer's announced frame limit and
  /// the status payload stays within 1024 bytes; [done] reports [status]
  /// as given.
  ///
  /// Completes when the channel is mutually closed or the connection is
  /// lost, whichever comes first; completes at once if the channel is
  /// already closed. If the peer does not confirm within
  /// [MuxOptions.closeConfirmTimeout], the channel is considered closed
  /// locally and this completes then; see that option. Never completes
  /// with an error. Throws [ArgumentError] synchronously for application
  /// status codes (256 and above), which must not be used in CLOSE.
  @override
  Future<void> close([Status status = Status.ok]) {
    checkMuxStatus(status);
    if (_state == MuxChannelState.open) {
      _closeSent = true;
      _state = MuxChannelState.halfClosedLocal;
      _noteStatus(status);
      _link.host.sendFrame(_closeFrame(status));
      _link._startConfirmTimer();
    }
    return _done.future;
  }

  MuxFrame _closeFrame(Status status) => status.isOk && status.reason.isEmpty
      ? MuxFrame.close(id)
      : MuxFrame.close(
          id,
          fitStatus(
            status,
            MuxFrame.headerSizeFor(id),
            _link.host.peerMaxFrameSize,
          ),
        );

  void _noteStatus(Status status) {
    if (_endStatus.isOk && !status.isOk) {
      _endStatus = status;
    }
  }

  // Receive buffer --------------------------------------------------------

  void _receive(Uint8List payload) {
    if (_discarding || _endRequested) {
      return;
    }
    final size = payload.length + _subframeOverhead;
    _queue.add(payload);
    _queuedBytes += size;
    _link.host.noteBuffered(size);
    final cap = _link.host.options.maxChannelBufferBytes;
    if (cap > 0 && _queuedBytes > cap) {
      _discard();
      if (_state == MuxChannelState.open) {
        unawaited(
          close(
            Status.of(
              StatusCode.resourceExhausted,
              'receive buffer of $cap bytes exceeded',
            ),
          ),
        );
      }
      return;
    }
    _scheduleDrain();
  }

  /// Drops buffered subframes and every later one.
  void _discard() {
    _discarding = true;
    if (_queuedBytes != 0) {
      _link.host.noteBuffered(-_queuedBytes);
    }
    _queue.clear();
    _queuedBytes = 0;
  }

  void _onCancel() => _discard();

  void _scheduleDrain() {
    if (_drainScheduled) {
      return;
    }
    _drainScheduled = true;
    scheduleMicrotask(_drain);
  }

  void _drain() {
    _drainScheduled = false;
    while (_queue.isNotEmpty && _incoming.hasListener && !_incoming.isPaused) {
      final payload = _queue.removeFirst();
      final size = payload.length + _subframeOverhead;
      _queuedBytes -= size;
      _link.host.noteBuffered(-size);
      _incoming.add(payload);
    }
    if (_endRequested && _queue.isEmpty && !_incoming.isClosed) {
      unawaited(_incoming.close());
    }
  }

  void _complete() {
    _state = MuxChannelState.closed;
    _confirmTimer?.cancel();
    _confirmTimer = null;
    _endRequested = true;
    _scheduleDrain();
    if (!_done.isCompleted) {
      _done.complete(_endStatus);
    }
  }

  @override
  String toString() =>
      'MuxChannel($id, ${_state.name}, '
      '${isLocallyOpened ? 'local' : 'remote'})';
}

/// Connection side hooks used by [MuxChannelLink].
@internal
abstract interface class MuxChannelHost {
  /// The connection's options.
  MuxOptions get options;

  /// Sends [frame] if the transport is still writable; never throws.
  void sendFrame(MuxFrame frame);

  /// Called once when [link] is mutually closed, so its id can be reused.
  void release(MuxChannelLink link);

  /// Called once when the peer did not confirm [link]'s CLOSE in time.
  void abandon(MuxChannelLink link);

  /// Adds [delta] (negative when bytes are delivered or dropped) to the
  /// bytes buffered in channel receive queues.
  void noteBuffered(int delta);

  /// Largest frame the peer accepts, 0 when unknown or unlimited.
  int get peerMaxFrameSize;
}

/// The connection's handle on a channel: delivers received frames and
/// connection loss. Keeps these operations off the public [MuxChannel]
/// API.
@internal
class MuxChannelLink {
  /// Creates the channel.
  MuxChannelLink(
    this.host,
    MuxConnection connection,
    int id, {
    required bool isLocallyOpened,
    required Uint8List openPayload,
  }) {
    channel = MuxChannel._(this, connection, id, isLocallyOpened, openPayload);
  }

  /// The owning connection's hooks.
  final MuxChannelHost host;

  /// The channel.
  late final MuxChannel channel;

  /// Channel id.
  int get id => channel.id;

  /// Whether the peer's CLOSE has been received.
  bool get closeReceived => channel._closeReceived;

  /// Delivers a DATA payload. The caller has checked that the peer's
  /// CLOSE has not been received.
  void receiveData(Uint8List payload) => channel._receive(payload);

  /// Handles the peer's CLOSE: frees the id, sends the confirming CLOSE if
  /// we have not sent ours, and completes the channel.
  void receiveClose(Status status) {
    final c = channel;
    c._closeReceived = true;
    c._noteStatus(status);
    final confirm = !c._closeSent;
    c._closeSent = true;
    c._state = MuxChannelState.closed;
    // Free the id before sending the confirmation so that a peer reacting
    // to it synchronously may reuse the id.
    host.release(this);
    if (confirm) {
      host.sendFrame(MuxFrame.close(c.id));
    }
    c._complete();
  }

  /// Closes a channel the application never received, with CLOSE
  /// carrying [status], dropping whatever it buffered.
  void closeUndelivered(Status status) {
    final c = channel;
    c._discard();
    if (c._state == MuxChannelState.open) {
      unawaited(c.close(status));
    }
  }

  /// Completes the channel locally because the peer did not confirm our
  /// CLOSE in time. The connection keeps the id reserved.
  void abandoned() => channel._complete();

  /// Ends the channel because the connection ended.
  void connectionLost(Status status) {
    final c = channel;
    c._noteStatus(status);
    c._complete();
  }

  void _startConfirmTimer() {
    final timeout = host.options.closeConfirmTimeout;
    final c = channel;
    if (timeout <= Duration.zero || c._confirmTimer != null) {
      return;
    }
    c._confirmTimer = Timer(timeout, () {
      c._confirmTimer = null;
      if (c._state == MuxChannelState.halfClosedLocal) {
        host.abandon(this);
      }
    });
  }
}

class _MuxChannelSink implements StreamSink<Uint8List> {
  _MuxChannelSink(this._channel);

  final MuxChannel _channel;
  bool _closed = false;

  @override
  void add(Uint8List event) {
    if (_closed) {
      throw StateError('channel ${_channel.id} sink is closed');
    }
    if (_channel.canSend) {
      _channel.send(event);
    }
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {
    if (_closed) {
      throw StateError('channel ${_channel.id} sink is closed');
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
