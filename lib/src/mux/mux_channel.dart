/*
Polyverse Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Authors:
  Jan Boon <jan.boon@kaetemi.be>
  Claude Fable 5.1 <noreply@anthropic.com>
  Claude Opus 5.5 <noreply@anthropic.com>
  GPT-6 Astra <noreply@anthropic.com>
*/

import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:stream_channel/stream_channel.dart';

import '../status.dart';
import '../status_closable.dart';
import 'mux_connection.dart';
import 'mux_frame.dart';

/// State of a channel as seen by the local side.
///
/// See the wiki page "Polyverse Switchboard Mux", section "State summary per
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

/// Output tier of a channel for the connection's output scheduler: which
/// of the frames waiting for the transport goes first. Local to the sender;
/// nothing about it goes on the wire.
///
/// See the wiki page "Polyverse Switchboard Mux", section "Output
/// scheduling".
enum MuxPriority {
  /// Ordinary traffic: requests, responses, messages. Goes before bulk.
  normal,

  /// A bulk transfer: its frames go after ordinary ones, but get a turn
  /// after [MuxOptions.bulkZipper] ordinary frames while they wait, so
  /// that sustained ordinary traffic cannot starve them. [MuxChannel.send]
  /// splits a payload on such a channel into chunks of at most
  /// [MuxOptions.bulkChunkSize].
  bulk,
}

/// A channel that carries its subframes on a [MuxChannel] it may replace
/// before anything was sent or received on it (a slot channel retried
/// after `MOVED`), and passes flow control on to it: what a layer reading
/// it on the application's behalf (Talk) needs of the mux channel under
/// it. A [MuxChannel] is its own carrier and does not implement this.
@internal
abstract interface class MuxChannelCarrier {
  /// The mux channel the subframes travel on now.
  MuxChannel get channel;

  /// As [MuxChannel.manualCredit], for the current channel and a
  /// replacement.
  set manualCredit(bool value);

  /// As [MuxChannel.consumed], on the current channel.
  void consumed(int bytes, {int subframes = 1});
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
    this._initialSendWindow,
    this._receiveWindow,
    this._creditWindow, {
    required bool awaitingLimits,
  }) : _sendWindow = awaitingLimits ? 0 : _initialSendWindow,
       _awaitingLimits = awaitingLimits {
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
  // Whether we decided to close: close() was called or the peer's CLOSE
  // was confirmed. Our CLOSE may still wait behind subframes waiting for
  // credit ([_pendingClose]).
  bool _closeSent = false;
  bool _closeReceived = false;
  Timer? _confirmTimer;

  // Flow control, sending side: the window the peer granted, the
  // subframes waiting for it (in order), and our CLOSE waiting behind
  // them. While the peer's LIMITS is awaited the window is 0 and the
  // initial window the 64 KiB assumed without LIMITS.
  int _initialSendWindow;
  int _sendWindow;
  // Credit reserved for DATA handed to the scheduler but not written yet.
  // The peer cannot have consumed it: it still counts toward the u32 cap.
  int _reservedSendCost = 0;
  bool _awaitingLimits;
  final Queue<_PendingSend> _pendingSends = Queue<_PendingSend>();
  Status? _pendingClose;
  bool _closeQueued = false;
  bool _admitting = false;

  /// A completed future, returned by [send] for a subframe sent at once.
  /// Made in the caller's zone each time: one shared future would run the
  /// callbacks of every later caller in the zone that first made it (under
  /// fake_async, a zone whose microtasks nobody runs any more).
  static Future<void> get _sentAtOnce => Future<void>.value();

  // Flow control, receiving side: what the peer may still send, the
  // window credit is returned against (half of it is the batch), what was
  // consumed and not returned yet, and, with manual credit, what was
  // delivered and not reported consumed. Every byte of cost the peer may
  // send is in exactly one of these: the receive window, [_queuedBytes],
  // [_held] or [_unreturned].
  int _receiveWindow;
  int _creditWindow;
  int _unreturned = 0;
  int _held = 0;
  bool _manualCredit = false;
  // Set when the channel completes: nothing is held or returned any more.
  bool _released = false;

  /// Current state.
  MuxChannelState get state => _state;

  /// The output tier of what this side sends on the channel; see
  /// [MuxPriority]. [MuxPriority.normal] by default. Either side sets it
  /// for its own direction, at any time: it applies to the frames the
  /// scheduler picks from then on, and to the splitting of payloads [send]
  /// takes from then on.
  MuxPriority get priority => _priority;
  MuxPriority _priority = MuxPriority.normal;

  set priority(MuxPriority value) {
    if (_priority == value) return;
    _priority = value;
    _link.host.reprioritize(_link);
  }

  /// Whether DATA may be sent: the state is [MuxChannelState.open].
  bool get canSend => _state == MuxChannelState.open;

  /// Bytes received and not yet delivered to the [stream]'s listener,
  /// because nobody listens yet or the subscription is paused, each
  /// subframe counted at its flow-control cost (its length plus 16).
  /// Bounded by the window this side granted (see [receiveWindow]).
  int get bufferedBytes => _queuedBytes;

  /// Incoming DATA subframes, single subscription, buffered until
  /// listened to. Ends when the peer's CLOSE arrives or the connection
  /// drops; read [done] for the reason.
  ///
  /// Flow control: what the peer may send is bounded by the window this
  /// side grants ([receiveWindow]), and credit is returned as subframes
  /// are consumed. Without [manualCredit] a subframe counts as consumed
  /// once the listener has taken it: delivered, not merely buffered, so a
  /// paused subscription (or none yet) consumes nothing and stalls the
  /// channel, and only it, once the window is used up. Cancelling the
  /// subscription drops further DATA, which counts as consumed; it does
  /// not close the channel.
  @override
  Stream<Uint8List> get stream => _incoming.stream;

  /// Whether [stream] has a listener: something reads the channel.
  @internal
  bool get hasListener => _incoming.hasListener;

  /// Whether DATA waits for the peer's LIMITS (see [sendWindow]): until
  /// then [maxSubframeLength] reflects the 64 KiB assumed without one.
  @internal
  bool get awaitingLimits =>
      _awaitingLimits && _state != MuxChannelState.closed;

  /// Completes once the wait for the peer's LIMITS ended, or the channel
  /// ended first.
  @internal
  Future<void> get limitsKnown {
    if (!awaitingLimits) {
      return Future<void>.value();
    }
    return (_limitsKnownCompleter ??= Completer<void>()).future;
  }

  Completer<void>? _limitsKnownCompleter;

  /// Bytes of cost (a subframe's length plus 16) the peer may still send on
  /// the channel before this side returns credit.
  ///
  /// Starts at [MuxOptions.initialWindow] as announced in LIMITS (64 KiB
  /// without LIMITS); for a channel the peer opened, which it may have
  /// opened before our LIMITS reached it and so with 64 KiB, at the larger
  /// of the two. Shrinks with every DATA frame received and grows with
  /// every CREDIT sent. A DATA frame beyond it is a protocol error that
  /// ends the connection with GOAWAY `PROTOCOL_ERROR`.
  ///
  /// Credit is sent once the consumed and unreturned cost reaches half the
  /// window credit is returned against: the initial window (the smaller of
  /// the two for a channel the peer opened) plus what [grant] added. There
  /// is no timer; a peer that sends a frame costing more than half that
  /// window may wait for ever, which is why [send] refuses such frames.
  int get receiveWindow => _receiveWindow;

  /// Whether a layer that reads the channel on the application's behalf
  /// returns credit itself with [consumed]; false by default.
  ///
  /// While true, a subframe the [stream]'s listener takes does not count
  /// as consumed: it stays held ([heldBytes]) until [consumed] reports it,
  /// typically when the application has taken the message it belongs to,
  /// or, in a proxy, when the other side has taken it. Set it before
  /// listening. Setting it back to false counts what is held as consumed.
  ///
  /// What is held is bounded by the window, and does not count toward the
  /// connection's [MuxConnection.bufferedBytes] and its receive high-water
  /// mark: pausing the connection would not release it, since that takes
  /// the application, or another connection, to read, and it would stall
  /// every other channel of the connection (all the clients of a proxy
  /// sharing a backend connection, for one that does not read).
  bool get manualCredit => _manualCredit;

  set manualCredit(bool value) {
    if (value == _manualCredit) {
      return;
    }
    _manualCredit = value;
    if (!value && _held > 0) {
      final cost = _held;
      _held = 0;
      _consume(cost);
    }
  }

  /// With [manualCredit]: the cost of the subframes [stream] delivered
  /// that [consumed] has not reported yet. 0 once the channel is closed.
  int get heldBytes => _held;

  /// With [manualCredit]: reports that [subframes] subframes delivered by
  /// [stream], [bytes] bytes long together, have been consumed, so that
  /// their cost ([bytes] plus 16 per subframe) can be returned to the peer.
  /// For one subframe: `consumed(subframe.length)`.
  ///
  /// Credit goes out in batches, once half the window is consumed and
  /// unreturned (see [receiveWindow]). Does nothing once the channel is
  /// closed. Throws [ArgumentError] for negative values and [StateError]
  /// when more is reported than was delivered and not yet reported (always
  /// the case without [manualCredit], where delivery is consumption).
  void consumed(int bytes, {int subframes = 1}) {
    if (bytes < 0 || subframes < 0) {
      throw ArgumentError('negative bytes ($bytes) or subframes ($subframes)');
    }
    if (_released) {
      return;
    }
    final cost = bytes + MuxCredit.frameOverhead * subframes;
    if (cost > _held) {
      throw StateError(
        'channel $id: $cost bytes of cost reported consumed, $_held '
        'delivered and not consumed',
      );
    }
    _held -= cost;
    _consume(cost);
  }

  /// Raises the window the peer may use on this channel by [bytes] at once,
  /// for a transfer this side expects to be large: sends CREDIT for them
  /// (with the credit consumed and not returned yet), and returns credit
  /// against the larger window from then on. What this side may have to
  /// hold for the channel grows by as much.
  ///
  /// Does nothing once this side can no longer receive DATA on the channel
  /// that it would want more of (its CLOSE went out, or the peer's came).
  /// Throws [ArgumentError] if [bytes] is not positive, or if the window
  /// would exceed `2^32 - 1`.
  void grant(int bytes) {
    if (bytes <= 0) {
      throw ArgumentError.value(bytes, 'bytes', 'must be positive');
    }
    final credit = bytes + _unreturned;
    // What is queued and held comes back as credit too.
    if (_receiveWindow + _queuedBytes + _held + credit > MuxLimits.maxWindow) {
      throw ArgumentError.value(
        bytes,
        'bytes',
        'the window of channel $id would exceed 2^32 - 1',
      );
    }
    if (!_mayReturnCredit) {
      return;
    }
    _creditWindow += bytes;
    _unreturned = 0;
    _receiveWindow += credit;
    _link.host.sendFrame(
      MuxControlMessage.credit(MuxCredit(id, credit)).toFrame(),
    );
  }

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
  /// first: [StatusCode.goingAway] if the peer had sent GOAWAY (the peer's
  /// status in the reason when it was another), else the status of our own
  /// `goAway` if we had called it, else [StatusCode.connectionLost]. Never
  /// completes with an error.
  ///
  /// Application codes (256 and above) received from a peer, which must
  /// not be sent in CLOSE, are reported as [StatusCode.unknown] with the
  /// original code in the reason, so the status can always be relayed with
  /// [close].
  @override
  Future<Status> get done => _done.future;

  /// Bytes of cost (a subframe's length plus 16, [MuxCredit.costOf]) this
  /// side may still send on the channel before the peer returns credit.
  ///
  /// Starts at the initial window the peer announced in LIMITS before the
  /// channel was opened, grows with every CREDIT the peer sends for the
  /// channel and shrinks with every DATA frame sent on it. On a channel
  /// opened before the peer's LIMITS arrived it is 0 until then, so that
  /// DATA waits for it (see [MuxOptions.awaitPeerLimits]); it then starts
  /// at the window announced, or at 64 KiB if the wait ended without one.
  /// Credit reserved by DATA waiting in the output scheduler is excluded
  /// here, but still counts toward the `2^32 - 1` cap on peer grants until
  /// that DATA is written to the transport.
  /// See the wiki page "Polyverse Switchboard Mux", section "Flow
  /// control".
  int get sendWindow => _sendWindow;

  /// The largest subframe [send] takes on this channel, in bytes, or a
  /// negative number when not even an empty one fits.
  ///
  /// A DATA frame's cost is kept to half the channel's initial window (the
  /// one [sendWindow] started at), so that a peer returning credit in
  /// batches of up to half its window can never leave a subframe waiting
  /// for ever; with the default window of 64 KiB that is 32752 bytes. The
  /// frame must also fit the frame limit the peer announced with LIMITS
  /// (its 3 or 7 byte header included). Larger payloads go on a channel
  /// whose [priority] is [MuxPriority.bulk], where [send] splits them.
  ///
  /// While the peer's LIMITS is awaited (see [sendWindow]) this reflects
  /// the 64 KiB window assumed without one; a subframe taken meanwhile
  /// that the window or frame limit then announced does not fit fails its
  /// [send] future with [StatusCode.frameTooLarge].
  int get maxSubframeLength {
    var max = _frameCostLimit - MuxCredit.frameOverhead;
    final peerMax = _link.host.peerMaxFrameSize;
    if (peerMax > 0) {
      final fits = peerMax - MuxFrame.headerSizeFor(id);
      if (fits < max) {
        max = fits;
      }
    }
    return max;
  }

  /// The largest cost of one DATA frame: half the initial window, but at
  /// least an empty subframe's when the window takes one.
  int get _frameCostLimit {
    final half = _initialSendWindow ~/ 2;
    if (half >= MuxCredit.frameOverhead) {
      return half;
    }
    return _initialSendWindow < MuxCredit.frameOverhead
        ? _initialSendWindow
        : MuxCredit.frameOverhead;
  }

  /// Sends one DATA subframe, which may be empty.
  ///
  /// Flow control: the subframe costs its length plus 16 bytes of
  /// [sendWindow]. When the window takes it, and no earlier subframe is
  /// still waiting, it is handed to the connection at once and the
  /// returned future is already complete. Otherwise it waits, in order
  /// behind the subframes before it, until the peer returns enough credit,
  /// and the future completes when it has been handed to the connection.
  /// Handing over copies it: the caller may reuse [subframe] once the
  /// future completes, not before. The connection writes it when the
  /// transport takes it, in the order its output scheduler chooses
  /// ([priority]; the order within the channel is kept).
  ///
  /// On a channel whose [priority] is [MuxPriority.bulk] when [send] is
  /// called, a non-empty [subframe] of any length is a run of bytes rather
  /// than one subframe: it goes out in chunks of at most
  /// [MuxOptions.bulkChunkSize] (and the peer's frame limit), each sized to
  /// the window at hand, never smaller than what half the initial window
  /// allows unless the rest is. The receiver sees several subframes. The
  /// future completes when the last chunk has been handed over.
  ///
  /// So what this side holds for a channel is bounded: a sender that awaits
  /// each future has at most one window handed over and not written yet,
  /// plus the one subframe it waits for. A sender that does not await
  /// (as [sink]'s `add` does not) queues every subframe here until the
  /// window takes it; what the peer receives is bounded by the window
  /// either way.
  ///
  /// The future fails with a [SwitchboardException]
  /// ([StatusCode.failedPrecondition]) if the channel can no longer send
  /// before the subframe goes out: the peer closed it, the connection
  /// ended, or [close]'s confirmation timed out. Such a failure is never
  /// reported as unhandled. A [close] called meanwhile waits for the
  /// subframes before it.
  ///
  /// Throws [SwitchboardException] with [StatusCode.failedPrecondition] if
  /// [canSend] is false, and with [StatusCode.frameTooLarge] if the
  /// subframe is longer than [maxSubframeLength] (on a bulk channel: if
  /// the peer's frame limit leaves no room for a byte of payload).
  Future<void> send(Uint8List subframe) {
    if (!canSend) {
      throw SwitchboardException.of(
        StatusCode.failedPrecondition,
        'channel $id is ${_state.name}',
      );
    }
    if (priority == MuxPriority.bulk && subframe.isNotEmpty) {
      _checkChunkable();
      final pending = _PendingSend(subframe, split: true);
      if (_pendingSends.isEmpty && _admitChunks(pending)) {
        return _sentAtOnce;
      }
      _pendingSends.add(pending);
      return pending.future;
    }
    _checkSize(subframe.length);
    final cost = MuxCredit.costOf(subframe.length);
    if (_pendingSends.isEmpty && cost <= _sendWindow) {
      _sendWindow -= cost;
      _reservedSendCost += cost;
      _link.host.sendChannelFrame(_link, MuxFrame.data(id, subframe));
      return _sentAtOnce;
    }
    final pending = _PendingSend(subframe, split: false);
    _pendingSends.add(pending);
    return pending.future;
  }

  /// Opens a channel on the same connection, as [MuxConnection.open] does,
  /// whose OPEN keeps its place among the frames of this channel: it goes
  /// out after the subframes handed to [send] before the call (those
  /// waiting for credit included, and those the output scheduler holds)
  /// and before the ones after it, so that the peer receives the OPEN
  /// before any of them, and never long before. DATA and the CLOSE of the
  /// new channel wait until its OPEN has gone out; what the window takes
  /// of them meanwhile is held in the channel.
  ///
  /// This is how a Talk bulk channel is opened: the peer must see it
  /// before the message referencing it, and a receiver bounds the bulk
  /// channels opened ahead of their messages, which an OPEN sent at once
  /// could overtake while the message waits for credit or for the
  /// transport.
  ///
  /// Such a channel continues work the connection admitted already, so a
  /// GOAWAY, sent or received, does not refuse it (a peer of this
  /// implementation admits a `_bulk` OPEN for an open channel after its
  /// own GOAWAY likewise): an answer in flight can still carry a bulk
  /// payload while the connection drains.
  ///
  /// If this channel stops sending before the OPEN goes out (the peer
  /// closed it, the connection ended, or this channel's close confirmation
  /// timed out with the OPEN still waiting for credit), the new channel is
  /// never opened: it ends at once with [StatusCode.cancelled], its id
  /// released. Throws like [MuxConnection.open] (except after a GOAWAY),
  /// and with [StatusCode.failedPrecondition] when [canSend] is false.
  MuxChannel openAfter(Uint8List openPayload) {
    if (!canSend) {
      throw SwitchboardException.of(
        StatusCode.failedPrecondition,
        'channel $id is ${_state.name}',
      );
    }
    final link = _link.host.openAfter(_link, openPayload);
    final frame = MuxFrame.open(link.id, link.channel.openPayload);
    if (_pendingSends.isEmpty) {
      _link.host.sendChannelFrame(_link, frame, opens: link);
    } else {
      _pendingSends.add(_PendingSend.open(frame, link));
    }
    return link.channel;
  }

  /// The largest chunk of a bulk payload: [MuxOptions.bulkChunkSize], and
  /// what the peer's frame limit leaves after the header.
  int get _bulkChunkMax {
    var max = _link.host.options.bulkChunkSize;
    final peerMax = _link.host.peerMaxFrameSize;
    if (peerMax > 0) {
      final fits = peerMax - MuxFrame.headerSizeFor(id);
      if (fits < max) {
        max = fits;
      }
    }
    return max;
  }

  void _checkChunkable() {
    if (_bulkChunkMax < 1) {
      throw SwitchboardException.of(
        StatusCode.frameTooLarge,
        'the peer frame limit of ${_link.host.peerMaxFrameSize} leaves no '
        'room for a chunk on channel $id',
      );
    }
    if (_initialSendWindow <= MuxCredit.frameOverhead) {
      throw SwitchboardException.of(
        StatusCode.frameTooLarge,
        'the initial window of $_initialSendWindow of channel $id leaves no '
        'room for a chunk',
      );
    }
  }

  /// Hands over the chunks of [pending] the window takes; true once the
  /// whole payload is handed over.
  ///
  /// A chunk waits until the window takes the smallest of the rest, a
  /// whole chunk and what half the initial window allows, so that the
  /// chunks stay large; it then takes what the window allows, up to a
  /// whole chunk. A receiver returns credit before half its window is
  /// unreturned, so that much is always available eventually.
  bool _admitChunks(_PendingSend pending) {
    final data = pending.subframe;
    final chunkMax = _bulkChunkMax;
    var floor = _frameCostLimit - MuxCredit.frameOverhead;
    if (floor > chunkMax) {
      floor = chunkMax;
    }
    if (floor < 1) {
      floor = 1;
    }
    while (pending.offset < data.length) {
      final rest = data.length - pending.offset;
      final room = _sendWindow - MuxCredit.frameOverhead;
      if (room < (rest < floor ? rest : floor)) {
        return false;
      }
      var n = rest < chunkMax ? rest : chunkMax;
      if (room < n) {
        n = room;
      }
      final start = pending.offset;
      // Accounted before the write, which could come back here.
      _sendWindow -= MuxCredit.costOf(n);
      _reservedSendCost += MuxCredit.costOf(n);
      pending.offset += n;
      _link.host.sendChannelFrame(
        _link,
        MuxFrame.data(id, Uint8List.sublistView(data, start, start + n)),
      );
    }
    return true;
  }

  void _checkSize(int length) {
    final max = _link.host.peerMaxFrameSize;
    final size = MuxFrame.headerSizeFor(id) + length;
    if (max > 0 && size > max) {
      throw SwitchboardException.of(
        StatusCode.frameTooLarge,
        'frame of $size bytes exceeds the peer limit of $max',
      );
    }
    final cost = MuxCredit.costOf(length);
    final limit = _frameCostLimit;
    if (cost > limit) {
      throw SwitchboardException.of(
        StatusCode.frameTooLarge,
        'subframe of $length bytes costs $cost, more than $limit, half the '
        'initial window of channel $id',
      );
    }
  }

  /// Hands the waiting subframes the window now takes to the connection,
  /// in order, then our CLOSE if it waited behind them.
  void _admitPending() {
    if (_admitting) {
      // A write that came back here (a synchronous transport and peer):
      // the loop below takes what the new credit allows.
      return;
    }
    _admitting = true;
    try {
      while (_pendingSends.isNotEmpty) {
        final head = _pendingSends.first;
        final opens = head.opens;
        if (opens != null) {
          // An OPEN ordered behind what came before it; not flow
          // controlled.
          _pendingSends.removeFirst();
          _link.host.sendChannelFrame(_link, head.openFrame!, opens: opens);
          head.completer.complete();
          continue;
        }
        try {
          // The peer may have lowered its frame limit meanwhile.
          if (head.split) {
            _checkChunkable();
            if (!_admitChunks(head)) {
              break;
            }
            _pendingSends.removeFirst();
          } else {
            // Checked first: a subframe the window never takes would wait
            // for ever.
            _checkSize(head.subframe.length);
            final cost = MuxCredit.costOf(head.subframe.length);
            if (cost > _sendWindow) {
              break;
            }
            _sendWindow -= cost;
            _reservedSendCost += cost;
            _pendingSends.removeFirst();
            _link.host.sendChannelFrame(
              _link,
              MuxFrame.data(id, head.subframe),
            );
          }
        } on SwitchboardException catch (e) {
          _pendingSends.removeFirst();
          head.completer.completeError(e);
          continue;
        }
        head.completer.complete();
      }
    } finally {
      _admitting = false;
    }
    final close = _pendingClose;
    if (_pendingSends.isEmpty && close != null) {
      _pendingClose = null;
      _queueClose(close);
    }
  }

  /// Fails every subframe still waiting for credit; a channel whose OPEN
  /// waited behind them ([openAfter]) is never opened.
  void _failPendingSends() {
    if (_pendingSends.isEmpty) {
      return;
    }
    final error = SwitchboardException.of(
      StatusCode.failedPrecondition,
      'channel $id closed before the subframe was sent',
    );
    final pending = List.of(_pendingSends);
    _pendingSends.clear();
    for (final send in pending) {
      send.completer.completeError(error);
      final opens = send.opens;
      if (opens != null) {
        _link.host.openFailed(
          opens,
          Status.of(
            StatusCode.cancelled,
            'channel $id stopped sending before the OPEN went out',
          ),
        );
      }
    }
  }

  /// The wait for the peer's LIMITS ended: the window starts at [window],
  /// and what waited for it goes.
  void _limitsKnown(int window) {
    if (!_awaitingLimits) {
      return;
    }
    _awaitingLimits = false;
    _initialSendWindow = window;
    _sendWindow += window;
    if (_state != MuxChannelState.closed) {
      _admitPending();
    }
    final known = _limitsKnownCompleter;
    _limitsKnownCompleter = null;
    known?.complete();
  }

  /// Applies the peer's CREDIT of [bytes]. Ignored once the channel can
  /// send no more DATA. Throws [ProtocolException] if the window would
  /// exceed `2^32 - 1`.
  void _receiveCredit(int bytes) {
    if (_closeReceived || _closeQueued || _state == MuxChannelState.closed) {
      return;
    }
    final window = _sendWindow + bytes;
    if (window + _reservedSendCost > MuxLimits.maxWindow) {
      throw ProtocolException(
        'CREDIT of $bytes takes the window of channel $id to $window, '
        'plus $_reservedSendCost reserved for unwritten DATA, above 2^32 - 1',
      );
    }
    _sendWindow = window;
    _admitPending();
  }

  /// Sends our CLOSE carrying [status], behind the DATA handed over
  /// before it.
  void _queueClose(Status status) {
    _closeQueued = true;
    _link.host.sendChannelFrame(_link, _closeFrame(status));
  }

  /// Sends our CLOSE now if it waits behind subframes waiting for credit,
  /// failing them: the close confirmation timed out. The CLOSE then
  /// carries `DEADLINE_EXCEEDED` rather than an `OK` that would claim
  /// everything was sent, and so does [done].
  void _flushPendingClose() {
    var close = _pendingClose;
    if (close == null) {
      return;
    }
    _pendingClose = null;
    var bytes = 0;
    for (final pending in _pendingSends) {
      bytes += pending.subframe.length - pending.offset;
    }
    _failPendingSends();
    if (close.isOk) {
      close = Status.of(
        StatusCode.deadlineExceeded,
        '$bytes bytes not sent: no credit within the close timeout',
      );
      _noteStatus(close);
    }
    _queueClose(close);
  }

  /// Sends CLOSE carrying [status] unless already sent.
  ///
  /// Subframes still waiting for credit ([send]) go first: the CLOSE
  /// follows them, so that what was sent before it arrives before it. If
  /// they are still waiting when the confirmation times out
  /// ([MuxOptions.closeConfirmTimeout]), or the peer closes meanwhile, they
  /// are dropped (their futures fail) and the CLOSE goes at once.
  ///
  /// The reason is shortened on the wire if needed, on a UTF-8 character
  /// boundary, so that the frame fits the peer's announced frame limit and
  /// the status payload stays within 1024 bytes; [done] reports [status]
  /// as given. The local-only `CONNECTION_LOST` code is sent as `UNAVAILABLE`.
  ///
  /// Completes when the channel is mutually closed or the connection is
  /// lost, whichever comes first; completes at once if the channel is
  /// already closed. If the peer does not confirm within
  /// [MuxOptions.closeConfirmTimeout], the channel is considered closed
  /// locally and this completes then; see that option. Completion cancels
  /// the confirmation timer even on synchronous transports. Never completes
  /// with an error. Throws [ArgumentError] synchronously for application
  /// status codes (256 and above), which must not be used in CLOSE.
  @override
  Future<void> close([Status status = Status.ok]) {
    checkMuxStatus(status);
    if (_state == MuxChannelState.open) {
      _closeSent = true;
      _state = MuxChannelState.halfClosedLocal;
      _noteStatus(status);
      // A synchronous transport can confirm during sendFrame; install
      // the timer first so that completion cancels it. A channel whose
      // OPEN waits behind its parent's frames ([openAfter]) arms it when
      // the OPEN goes out: the peer cannot confirm a channel it does not
      // know.
      if (_link.openWritten) {
        _link._startConfirmTimer();
      }
      if (_pendingSends.isEmpty) {
        _queueClose(status);
      } else {
        _pendingClose = status;
      }
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

  /// Takes a DATA payload. Throws [ProtocolException] if it goes beyond
  /// the window granted to the peer.
  void _receive(Uint8List payload) {
    final cost = MuxCredit.costOf(payload.length);
    if (cost > _receiveWindow) {
      throw ProtocolException(
        'DATA costing $cost bytes on channel $id, beyond the window of '
        '$_receiveWindow granted',
      );
    }
    _receiveWindow -= cost;
    if (_discarding || _endRequested) {
      // Dropped: as good as consumed.
      _consume(cost);
      return;
    }
    _queue.add(payload);
    _queuedBytes += cost;
    _link.host.noteBuffered(cost);
    _scheduleDrain();
  }

  /// Drops buffered subframes and every later one; they count as consumed.
  void _discard() {
    _discarding = true;
    final cost = _queuedBytes;
    _queue.clear();
    _queuedBytes = 0;
    if (cost != 0) {
      _link.host.noteBuffered(-cost);
      _consume(cost);
    }
  }

  /// Whether credit may still go to the peer: it may still send DATA, and
  /// our CLOSE (which tells it to stop) has not gone out.
  bool get _mayReturnCredit => !_released && !_closeReceived && !_closeQueued;

  /// Counts [cost] as consumed and returns credit once half the window is
  /// consumed and unreturned.
  void _consume(int cost) {
    _unreturned += cost;
    if (_unreturned == 0 || !_mayReturnCredit) {
      return;
    }
    final half = _creditWindow ~/ 2;
    if (_unreturned < (half < 1 ? 1 : half)) {
      return;
    }
    final credit = _unreturned;
    _unreturned = 0;
    _receiveWindow += credit;
    _link.host.sendFrame(
      MuxControlMessage.credit(MuxCredit(id, credit)).toFrame(),
    );
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
      final cost = MuxCredit.costOf(payload.length);
      _queuedBytes -= cost;
      _link.host.noteBuffered(-cost);
      if (_manualCredit && !_released) {
        // Held by the listener until it reports it consumed.
        _held += cost;
      } else {
        // Already taken when the callback runs. Keep the cost in the
        // accounting if it calls grant; return the batch after delivery.
        _unreturned += cost;
      }
      _incoming.add(payload);
    }
    _consume(0);
    if (_endRequested && _queue.isEmpty && !_incoming.isClosed) {
      unawaited(_incoming.close());
    }
  }

  void _complete() {
    _state = MuxChannelState.closed;
    final known = _limitsKnownCompleter;
    _limitsKnownCompleter = null;
    known?.complete();
    _confirmTimer?.cancel();
    _confirmTimer = null;
    _pendingClose = null;
    _failPendingSends();
    if (!_link.openWritten) {
      // The OPEN never goes out: neither does what waited for it. A
      // channel the peer closes while its OPEN is being written (a
      // synchronous transport) still sends what waited behind the OPEN:
      // our CLOSE, and the OPENs of the channels opened after it.
      _link.preOpen = const [];
    }
    _reservedSendCost = 0;
    _released = true;
    _held = 0;
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
  /// Moves queued output to [link]'s current priority tier.
  void reprioritize(MuxChannelLink link);

  /// The connection's options.
  MuxOptions get options;

  /// Sends [frame] if the transport is still writable; never throws. Not
  /// held by the output scheduler: for control messages and frames of
  /// channels with nothing waiting for the transport.
  void sendFrame(MuxFrame frame);

  /// Hands [frame] of [link] to the output scheduler: DATA waits for the
  /// transport to take it, in [link]'s queue; a CLOSE follows what is
  /// queued before it, and goes at once when nothing is. An OPEN of the
  /// channel [opens] ([MuxChannel.openAfter]) likewise; once it is
  /// written, what that channel sent meanwhile follows. Frames of a
  /// channel whose OPEN has not gone out wait for it.
  void sendChannelFrame(
    MuxChannelLink link,
    MuxFrame frame, {
    MuxChannelLink? opens,
  });

  /// Creates the channel of [MuxChannel.openAfter] on [parent]'s
  /// connection, its OPEN not sent: the caller hands it to
  /// [sendChannelFrame] in its place. Throws like [MuxConnection.open].
  MuxChannelLink openAfter(MuxChannelLink parent, Uint8List openPayload);

  /// The OPEN of [link] ([MuxChannel.openAfter]) will never go out: ends
  /// the channel locally with [status] and frees its id.
  void openFailed(MuxChannelLink link, Status status);

  /// Drops the DATA of [link] waiting for the transport (the peer closed
  /// the channel) and sends at once what remains queued for it.
  void dropQueuedData(MuxChannelLink link);

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
    required int sendWindow,
    required int receiveWindow,
    required int creditWindow,
    bool awaitingLimits = false,
  }) {
    channel = MuxChannel._(
      this,
      connection,
      id,
      isLocallyOpened,
      openPayload,
      awaitingLimits ? MuxLimits.defaultInitialWindow : sendWindow,
      receiveWindow,
      creditWindow,
      awaitingLimits: awaitingLimits,
    );
  }

  /// The owning connection's hooks.
  final MuxChannelHost host;

  /// The channel.
  late final MuxChannel channel;

  /// Channel id.
  int get id => channel.id;

  /// Whether the connection still holds this channel for incoming delivery.
  /// Kept separately so queue removal and membership checks stay constant time.
  bool incomingPending = false;

  /// False while the OPEN of a channel opened with [MuxChannel.openAfter]
  /// waits behind its parent's frames: the id is only reserved locally,
  /// and the peer's frames on it are refused. Set just before the OPEN is
  /// written, so that a synchronous peer may answer it.
  bool openWritten = true;

  /// Whether the frames handed over for this channel wait in [preOpen]:
  /// from [MuxChannel.openAfter] until its OPEN is written and the frames
  /// that waited have followed it. Frames handed over meanwhile, while a
  /// synchronous peer answers the OPEN or those frames, queue behind them.
  bool holdsFrames = false;

  /// Frames of this channel handed to the connection before its OPEN was
  /// written, in order, each with the channel it opens if it is an OPEN
  /// ordered behind this channel's frames. Payloads are owned copies,
  /// since handing them over completes their send futures.
  List<(MuxFrame, MuxChannelLink?)> preOpen = const [];

  /// Ends a channel whose OPEN never went out, with [status].
  void neverOpened(Status status) {
    final c = channel;
    preOpen = const [];
    c._noteStatus(status);
    c._closeSent = true;
    c._closeReceived = true;
    c._complete();
  }

  /// Whether the peer's CLOSE has been received.
  bool get closeReceived => channel._closeReceived;

  /// Delivers a DATA payload. The caller has checked that the peer's
  /// CLOSE has not been received. Throws [ProtocolException] if the
  /// payload goes beyond the window granted to the peer.
  void receiveData(Uint8List payload) => channel._receive(payload);

  /// Applies the peer's CREDIT of [bytes] for this channel. Throws
  /// [ProtocolException] if the window would exceed `2^32 - 1`.
  void receiveCredit(int bytes) => channel._receiveCredit(bytes);

  /// DATA of [cost] bytes of credit is going to the transport now: its
  /// reservation ends. After local completion no reservation remains.
  void dataWritten(int cost) {
    if (channel._state != MuxChannelState.closed) {
      channel._reservedSendCost -= cost;
    }
  }

  /// The wait for the peer's LIMITS ended; [window] is the initial window
  /// of a channel opened before it.
  void limitsKnown(int window) => channel._limitsKnown(window);

  /// Handles the peer's CLOSE: frees the id, sends the confirming CLOSE if
  /// we have not sent ours (or ours if it still waited behind subframes,
  /// which are dropped), and completes the channel.
  void receiveClose(Status status) {
    final c = channel;
    c._closeReceived = true;
    c._noteStatus(status);
    final confirm = !c._closeSent;
    final ours = c._pendingClose;
    c._pendingClose = null;
    c._failPendingSends();
    c._closeSent = true;
    c._state = MuxChannelState.closed;
    // Free the id before sending the confirmation so that a peer reacting
    // to it synchronously may reuse the id.
    host.release(this);
    // DATA after the peer's CLOSE must not go out, and our own CLOSE, if
    // it was queued behind such DATA, goes now.
    host.dropQueuedData(this);
    if (confirm) {
      c._closeQueued = true;
      host.sendFrame(MuxFrame.close(c.id));
    } else if (ours != null) {
      c._queueClose(ours);
    }
    c._complete();
  }

  /// Closes a channel the application never received, with CLOSE
  /// carrying [status], dropping whatever it buffered.
  void closeUndelivered(Status status) {
    final c = channel;
    // Closed first, so that dropping what it buffered returns no credit.
    if (c._state == MuxChannelState.open) {
      unawaited(c.close(status));
    }
    c._discard();
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

  /// Arms the close confirmation timer of a channel whose CLOSE was
  /// requested before its OPEN went out.
  void openWrittenAfterClose() {
    if (channel._closeSent &&
        channel._state == MuxChannelState.halfClosedLocal) {
      _startConfirmTimer();
    }
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
        c._flushPendingClose();
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
      // Waits for credit inside the channel if it must; see send.
      _channel.send(event).ignore();
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

  /// Sends every subframe of [stream], waiting for each to be handed to
  /// the connection before taking the next, so that the stream is paused
  /// while the channel waits for credit. Subframes are dropped once the
  /// channel can no longer send. Size refusals, including those after
  /// waiting for LIMITS, fail the call.
  @override
  Future<void> addStream(Stream<Uint8List> stream) async {
    await for (final subframe in stream) {
      if (_closed) {
        break;
      }
      if (_channel.canSend) {
        // A subframe the channel refuses (too large) fails the call.
        final sent = _channel.send(subframe);
        try {
          await sent;
        } on SwitchboardException catch (e) {
          if (e.code != StatusCode.failedPrecondition) {
            rethrow;
          }
          // Closed while waiting: dropped, as add drops it.
        }
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

/// A subframe waiting for flow-control credit, or the rest of a bulk
/// payload.
class _PendingSend {
  _PendingSend(this.subframe, {required this.split})
    : openFrame = null,
      opens = null;

  /// The OPEN of [opens], ordered behind the subframes before it.
  _PendingSend.open(MuxFrame this.openFrame, MuxChannelLink this.opens)
    : subframe = Uint8List(0),
      split = false;

  final Uint8List subframe;

  /// The OPEN frame of [opens] ([MuxChannel.openAfter]); null for DATA.
  final MuxFrame? openFrame;

  /// The channel [openFrame] opens.
  final MuxChannelLink? opens;

  /// Whether [subframe] is a bulk payload, sent in chunks.
  final bool split;

  /// Bytes of a bulk payload handed over so far.
  int offset = 0;

  late final Completer<void> completer = Completer<void>()
    // A failure is reported to whoever awaits the future, never as an
    // unhandled error.
    ..future.ignore();

  Future<void> get future => completer.future;
}
