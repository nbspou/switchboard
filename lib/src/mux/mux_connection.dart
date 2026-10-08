/*
Polyverse Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Authors:
  Jan Boon <jan.boon@kaetemi.be>
  Claude Fable 5.1 <noreply@anthropic.com>
  Claude Opus 5.5 <noreply@anthropic.com>
*/

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:stream_channel/stream_channel.dart';

import '../identity/credential.dart';
import '../identity/credential_verifier.dart';
import '../identity/ed25519.dart';
import '../identity/holder_key.dart';
import '../identity/peer_identity.dart';
import '../identity/secure_random.dart';
import '../status.dart';
import '../transport/transport_capabilities.dart';
import 'mux_channel.dart';
import 'mux_frame.dart';

final Logger _log = Logger('Switchboard.Mux');

/// Local configuration of a [MuxConnection].
class MuxOptions {
  /// Creates options. Every value has a general purpose default.
  const MuxOptions({
    this.maxFrameSize = defaultMaxFrameSize,
    this.maxChannels = defaultMaxChannels,
    this.shortIdsOnly = false,
    this.keepAliveInterval = const Duration(seconds: 10),
    this.keepAliveTimeout = const Duration(seconds: 10),
    this.goAwayGrace = const Duration(seconds: 10),
    this.announceLimits = true,
    this.maxPendingRejections = defaultMaxPendingRejections,
    this.maxChannelBufferBytes = defaultMaxChannelBufferBytes,
    this.receiveHighWaterMarkBytes = defaultReceiveHighWaterMarkBytes,
    this.closeConfirmTimeout = const Duration(seconds: 30),
    this.maxOpenPayloadBytes = defaultMaxOpenPayloadBytes,
    this.identityVerifier,
    this.identityTimeout = const Duration(seconds: 10),
    this.requireNamedIdent = false,
  });

  /// Default [maxFrameSize]: 1 MiB.
  static const int defaultMaxFrameSize = 1024 * 1024;

  /// Default [maxChannels].
  static const int defaultMaxChannels = 65536;

  /// Default [maxPendingRejections].
  static const int defaultMaxPendingRejections = 1024;

  /// Default [maxChannelBufferBytes]: 4 MiB.
  static const int defaultMaxChannelBufferBytes = 4 * 1024 * 1024;

  /// Default [receiveHighWaterMarkBytes]: 16 MiB.
  static const int defaultReceiveHighWaterMarkBytes = 16 * 1024 * 1024;

  /// Default [maxOpenPayloadBytes]: 16 MiB.
  static const int defaultMaxOpenPayloadBytes = 16 * 1024 * 1024;

  /// Largest incoming mux frame, header included, that we accept; a larger
  /// one ends the connection with GOAWAY `FRAME_TOO_LARGE`. Announced with
  /// LIMITS. 0 means no limit at the mux layer (the transport may still
  /// enforce one).
  ///
  /// Should agree with the transport's own limit (for example
  /// `StreamTransport.wrap`'s `maxFrameSize`). If the transport implements
  /// [FrameLimited] with a smaller limit, the connection logs a warning and
  /// announces the transport's limit instead.
  final int maxFrameSize;

  /// Largest number of simultaneously open channels (in both directions)
  /// before peer OPENs are rejected with CLOSE `RESOURCE_EXHAUSTED`.
  /// Also caps channels waiting for delivery on [MuxConnection.incoming],
  /// including ones the peer already closed, independently of the open cap.
  /// Announced with LIMITS. 0 means unlimited.
  final int maxChannels;

  /// Embedded style: allocate only short ids and refuse long form frames
  /// from the peer with GOAWAY `UNSUPPORTED`.
  final bool shortIdsOnly;

  /// Silence after which a PING is sent. Null disables keep-alive.
  final Duration? keepAliveInterval;

  /// How long to wait for any frame after a keep-alive PING before the
  /// connection is closed with `CONNECTION_LOST`. Also bounds how long
  /// [MuxConnection.close] waits for the transport to close; after that
  /// the transport is aborted if it implements [AbortableTransport].
  ///
  /// While a transport implementing [OutputBufferedTransport] has stopped
  /// reading because of our unsent output, the peer reading that output
  /// counts as hearing from it.
  final Duration keepAliveTimeout;

  /// How long [MuxConnection.goAway] waits for open channels to finish.
  final Duration goAwayGrace;

  /// Whether LIMITS is sent when the connection starts.
  final bool announceLimits;

  /// Largest number of channel ids for which we sent CLOSE without keeping
  /// a channel and still wait for the peer's CLOSE: peer OPENs we rejected
  /// (beyond [maxChannels], after GOAWAY, or with nobody listening to
  /// [MuxConnection.incoming]) and channels whose close confirmation timed
  /// out ([closeConfirmTimeout]). Each costs only its id; beyond the cap
  /// the connection ends with GOAWAY `RESOURCE_EXHAUSTED`. 0 means
  /// unlimited.
  final int maxPendingRejections;

  /// Largest number of bytes buffered for one channel while nobody listens
  /// to its stream or the subscription is paused. Each subframe counts as
  /// its length plus 32 bytes. Beyond it the channel is closed with CLOSE
  /// `RESOURCE_EXHAUSTED` and its buffer dropped; the connection is not
  /// affected. 0 means unlimited.
  final int maxChannelBufferBytes;

  /// Bytes buffered over all channels (counted as for
  /// [maxChannelBufferBytes]) above which the connection stops reading the
  /// transport, which pushes back on the peer through the transport's own
  /// flow control. Reading resumes once the buffers drain to half of it.
  /// Keep-alive does not probe while reading is paused. 0 means never
  /// pause.
  final int receiveHighWaterMarkBytes;

  /// How long [MuxChannel.close] waits for the peer's confirming CLOSE.
  ///
  /// On expiry the channel is considered closed locally: [MuxChannel.done]
  /// completes with the first status sent or received and the channel no
  /// longer counts as open. Nothing is sent. The id stays reserved until
  /// the peer's CLOSE arrives after all, or until the connection ends,
  /// because reusing it while the peer may still consider the channel open
  /// would let the peer's late frames for the old channel land on a new
  /// one. Such ids count toward [maxPendingRejections].
  /// [Duration.zero] waits forever.
  final Duration closeConfirmTimeout;

  /// Largest number of bytes of OPEN payloads held for the channels the
  /// peer opened and that are not closed yet (mutually, or by
  /// [closeConfirmTimeout]), or still await delivery on
  /// [MuxConnection.incoming]. A channel keeps its open payload for its
  /// whole life, so without this budget a peer could open [maxChannels]
  /// channels with frame-sized OPEN payloads and never send DATA while a
  /// handler holds them. A peer OPEN that would exceed it is rejected with
  /// CLOSE `RESOURCE_EXHAUSTED`.
  ///
  /// The held payloads count toward [MuxConnection.bufferedBytes], so
  /// [receiveHighWaterMarkBytes] reacts to them. Since reading resumes
  /// only once the buffered bytes drop to half of that mark, the budget is
  /// at most half of [receiveHighWaterMarkBytes] when that is set:
  /// otherwise held payloads alone could keep the reading paused, and with
  /// it the CLOSE frames that would release them. With the defaults the
  /// effective budget is therefore 8 MiB. 0 means no budget of its own
  /// (half the high-water mark still applies when set). Default 16 MiB.
  final int maxOpenPayloadBytes;

  /// Verifies the credential of an `IDENT` from the peer, which then sets
  /// [MuxConnection.peerIdentity]. Null: nothing can verify a credential,
  /// so a well-formed `IDENT` is ignored (and logged). A `NONCE` is
  /// answered either way, and an `IDENT` that breaks the envelope rules
  /// (before both nonces, truncated, or with an intent over 64 bytes) is a
  /// protocol error either way.
  final CredentialVerifier? identityVerifier;

  /// How long [MuxConnection.identify] waits for the peer's `NONCE` and the
  /// confirmation of its `IDENT`, unless given a timeout of its own.
  /// [Duration.zero] waits without bound. Default 10 s.
  final Duration identityTimeout;

  /// Whether an `IDENT` must name this side as its receiver: one with an
  /// empty receiver field is then refused like one that fails
  /// verification (GOAWAY `UNAUTHENTICATED`). An `IDENT` naming another
  /// receiver than [MuxConnection.localIdentity] is refused either way.
  /// Default false; a naming service sets it for its listener, so that no
  /// node's identification can be relayed to it.
  final bool requireNamedIdent;

  /// A copy with the given fields replaced. Pass [disableKeepAlive] to set
  /// [keepAliveInterval] to null.
  MuxOptions copyWith({
    int? maxFrameSize,
    int? maxChannels,
    bool? shortIdsOnly,
    Duration? keepAliveInterval,
    bool disableKeepAlive = false,
    Duration? keepAliveTimeout,
    Duration? goAwayGrace,
    bool? announceLimits,
    int? maxPendingRejections,
    int? maxChannelBufferBytes,
    int? receiveHighWaterMarkBytes,
    Duration? closeConfirmTimeout,
    int? maxOpenPayloadBytes,
    CredentialVerifier? identityVerifier,
    Duration? identityTimeout,
    bool? requireNamedIdent,
  }) => MuxOptions(
    maxFrameSize: maxFrameSize ?? this.maxFrameSize,
    maxChannels: maxChannels ?? this.maxChannels,
    shortIdsOnly: shortIdsOnly ?? this.shortIdsOnly,
    keepAliveInterval: disableKeepAlive
        ? null
        : keepAliveInterval ?? this.keepAliveInterval,
    keepAliveTimeout: keepAliveTimeout ?? this.keepAliveTimeout,
    goAwayGrace: goAwayGrace ?? this.goAwayGrace,
    announceLimits: announceLimits ?? this.announceLimits,
    maxPendingRejections: maxPendingRejections ?? this.maxPendingRejections,
    maxChannelBufferBytes: maxChannelBufferBytes ?? this.maxChannelBufferBytes,
    receiveHighWaterMarkBytes:
        receiveHighWaterMarkBytes ?? this.receiveHighWaterMarkBytes,
    closeConfirmTimeout: closeConfirmTimeout ?? this.closeConfirmTimeout,
    maxOpenPayloadBytes: maxOpenPayloadBytes ?? this.maxOpenPayloadBytes,
    identityVerifier: identityVerifier ?? this.identityVerifier,
    identityTimeout: identityTimeout ?? this.identityTimeout,
    requireNamedIdent: requireNamedIdent ?? this.requireNamedIdent,
  );
}

/// The mux layer over one transport connection: any number of channels
/// opened by either side, plus the control channel.
///
/// See the wiki page "Polyverse Switchboard Mux".
class MuxConnection {
  /// Starts the mux over [transport], a [StreamChannel] carrying one mux
  /// frame per event. [isInitiator] is true on the side that established
  /// the connection; it allocates even channel ids, the acceptor odd ones.
  ///
  /// Sends LIMITS at once if [MuxOptions.announceLimits] is set. If the
  /// transport implements [FrameLimited] with a limit below
  /// [MuxOptions.maxFrameSize], logs a warning and announces the
  /// transport's limit.
  MuxConnection(
    StreamChannel<Uint8List> transport, {
    required this.isInitiator,
    this.options = const MuxOptions(),
  }) : _transport = transport,
       _firstId = isInitiator ? 2 : 3,
       _firstLongId = MuxFrame.maxShortId + (isInitiator ? 1 : 2) {
    _nextShortId = _firstId;
    _nextLongId = _firstLongId;
    var shortIds = (MuxFrame.maxShortId - _firstId) ~/ 2 + 1;
    for (var id = _firstId; id <= MuxFrame.maxShortId; id += 2) {
      if (MuxFrame.isReservedId(id)) {
        shortIds--;
      }
    }
    _shortIdCapacity = shortIds;
    _host = _Host(this);
    // Synchronous, fed from [_undelivered] only while the listener is
    // active, so the connection knows which channels the application has.
    _incoming = StreamController<MuxChannel>(
      sync: true,
      onListen: _scheduleIncomingDrain,
      onResume: _scheduleIncomingDrain,
      onCancel: _onIncomingCancel,
    );
    var receiveLimit = options.maxFrameSize;
    if (transport is FrameLimited) {
      final transportLimit = (transport as FrameLimited).maxFrameSize;
      if (transportLimit > 0 &&
          (receiveLimit <= 0 || transportLimit < receiveLimit)) {
        _log.warning(
          '$this: the transport accepts frames of at most $transportLimit '
          'bytes, less than MuxOptions.maxFrameSize $receiveLimit; '
          'announcing $transportLimit',
        );
        receiveLimit = transportLimit;
      }
    }
    _subscription = transport.stream.listen(
      _onFrame,
      onError: _onTransportError,
      onDone: _onTransportDone,
    );
    if (options.announceLimits) {
      _sendFrame(
        MuxControlMessage.limits(
          MuxLimits(
            maxFrameSize: _clampU32(receiveLimit),
            maxChannels: _clampU32(options.maxChannels),
          ),
        ).toFrame(),
      );
    }
    _startKeepAlive();
  }

  /// Whether this side initiated the connection.
  final bool isInitiator;

  /// Local configuration.
  final MuxOptions options;

  final StreamChannel<Uint8List> _transport;
  late final StreamSubscription<Uint8List> _subscription;
  late final _Host _host;
  late final StreamController<MuxChannel> _incoming;
  final Queue<MuxChannelLink> _undelivered = Queue<MuxChannelLink>();
  final Map<int, MuxChannelLink> _links = {};
  // Ids we sent CLOSE for, without a channel, awaiting the peer's CLOSE.
  final Set<int> _awaitingClose = {};
  final Completer<Status> _done = Completer<Status>();
  final List<_PendingPing> _pings = [];
  final int _firstId;
  final int _firstLongId;
  late final int _shortIdCapacity;
  late int _nextShortId;
  late int _nextLongId;
  // Ids of our parity below 0x10000 that are open or await a CLOSE.
  int _shortIdsInUse = 0;
  int _openCount = 0;
  int _pingCounter = 0;
  int _bufferedBytes = 0;
  // OPEN payload bytes of the peer's channels still open or undelivered.
  int _openPayloadBytes = 0;
  bool _incomingCancelled = false;
  bool _incomingEndRequested = false;
  bool _incomingDrainScheduled = false;
  bool _receivePaused = false;
  bool _closing = false;
  bool _writable = true;
  bool _goAwaySent = false;
  Status? _peerGoAway;
  final Completer<Status> _peerGoAwayStatus = Completer<Status>();
  int _sentBytes = 0;
  int _receivedBytes = 0;
  MuxLimits? _peerLimits;
  Completer<void>? _idle;
  Future<void>? _closeFuture;

  // Identity (wiki "Switchboard Identity and Credentials").
  Uint8List? _localNonce;
  Uint8List? _peerNonce;
  Completer<Uint8List>? _peerNonceWaiter;
  final Completer<void> _identityRequested = Completer<void>();
  PeerIdentity? _peerIdentity;
  final Completer<PeerIdentity> _peerIdentified = Completer<PeerIdentity>();
  Completer<void>? _identityEvent;
  // Frames that arrived while an IDENT was being verified; handled after
  // it, in order, so that they see its outcome.
  final Queue<Uint8List> _heldFrames = Queue<Uint8List>();
  bool _verifyingIdent = false;
  // The peer's GOAWAY status as sent, for identify().
  Status? _peerGoAwayReceived;

  Timer? _keepAliveTimer;
  final Stopwatch _sinceReceive = Stopwatch()..start();
  bool _keepAliveProbing = false;
  int _lastAcceptedOutput = -1;

  /// Channels opened by the peer, single subscription. Buffered until
  /// listened to; ends when the connection ends.
  /// The backlog, including closed channels, is capped by
  /// [MuxOptions.maxChannels]; further OPENs receive `RESOURCE_EXHAUSTED`.
  ///
  /// Cancelling the subscription makes the connection reject further peer
  /// OPENs with CLOSE `UNAVAILABLE`, and closes the channels it had
  /// buffered but not delivered yet the same way.
  Stream<MuxChannel> get incoming => _incoming.stream;

  /// Completes when the connection has ended, never with an error.
  ///
  /// The status is `GOING_AWAY` if the peer sent GOAWAY (the peer's status
  /// is in the reason if it was not `GOING_AWAY`); the status sent with our
  /// GOAWAY if we ended the connection because the peer broke the protocol
  /// (`PROTOCOL_ERROR`, `FRAME_TOO_LARGE` or `UNSUPPORTED`), left too
  /// many CLOSEs unconfirmed (`RESOURCE_EXHAUSTED`, see
  /// [MuxOptions.maxPendingRejections]) or sent an `IDENT` that failed
  /// verification (`UNAUTHENTICATED`); otherwise `CONNECTION_LOST`.
  Future<Status> get done => _done.future;

  /// Whether the transport is open and no local close (including
  /// [goAway]) has started.
  bool get isOpen => !_closing && !_goAwaySent;

  /// Whether the peer sent GOAWAY.
  bool get peerGoingAway => _peerGoAway != null;

  /// Completes with the status of the peer's GOAWAY when it arrives:
  /// `GOING_AWAY` for a graceful shutdown, or the error the peer ended the
  /// connection with (`PROTOCOL_ERROR`, `RESOURCE_EXHAUSTED`, ...), with
  /// its reason. An application code, which GOAWAY must not carry, reads
  /// as `UNKNOWN` as in [done].
  ///
  /// Never completes if the connection ends without a GOAWAY from the
  /// peer, and never completes with an error. Lets a client that cannot
  /// see the transport notice a server draining (to reconnect elsewhere
  /// before [done]), and tell it from a loss.
  Future<Status> get peerGoAwayStatus => _peerGoAwayStatus.future;

  /// Bytes of the mux frames handed to the transport so far, headers
  /// included. The transport's own framing (the stream binding's length
  /// prefix, WebSocket headers, TLS) is not counted, and frames handed
  /// over are not necessarily sent yet (see `OutputBufferedTransport`).
  int get sentBytes => _sentBytes;

  /// Bytes of the mux frames received from the transport so far, headers
  /// included, counted as [sentBytes] is.
  int get receivedBytes => _receivedBytes;

  /// Limits the peer announced with LIMITS, or null if none arrived.
  MuxLimits? get peerLimits => _peerLimits;

  /// Number of channels not yet mutually closed, in both directions.
  /// Incoming channels rejected by the connection itself, and channels
  /// whose close confirmation timed out, are not counted.
  int get openChannelCount => _openCount;

  /// The channels counted by [openChannelCount], as a snapshot.
  Iterable<MuxChannel> get channels => [
    for (final link in _links.values) link.channel,
  ];

  /// Bytes buffered in the receive queues of all channels, counted as for
  /// [MuxOptions.maxChannelBufferBytes], plus the OPEN payloads held for
  /// the channels the peer opened until they are closed and delivered (see
  /// [MuxOptions.maxOpenPayloadBytes]).
  int get bufferedBytes => _bufferedBytes;

  /// Bytes of OPEN payloads held for the channels the peer opened that are
  /// still open or awaiting delivery; bounded by [MuxOptions.maxOpenPayloadBytes].
  int get openPayloadBytes => _openPayloadBytes;

  /// Whether reading the transport is paused because more than
  /// [MuxOptions.receiveHighWaterMarkBytes] are buffered.
  bool get isReceivePaused => _receivePaused && !_closing;

  /// Number of channel ids we sent CLOSE for without keeping a channel and
  /// for which the peer's CLOSE has not arrived yet; bounded by
  /// [MuxOptions.maxPendingRejections].
  int get unconfirmedCloseCount => _awaitingClose.length;

  /// Who the peer proved to be with its last valid `IDENT`, or null if it
  /// has not identified (or [MuxOptions.identityVerifier] is null, so its
  /// `IDENT` was ignored). Null again once the credential has expired, by
  /// the time of `package:clock`, until a valid `IDENT` with a renewed one
  /// arrives.
  ///
  /// Frames the peer sends after an `IDENT` are handled only once that
  /// `IDENT` is verified, so a channel opened right after it already sees
  /// the identity it establishes.
  PeerIdentity? get peerIdentity {
    final identity = _peerIdentity;
    return identity == null || identity.isExpired() ? null : identity;
  }

  /// Completes with the first valid `IDENT` of the peer. Never completes
  /// if the connection ends without one, and never completes with an
  /// error.
  Future<PeerIdentity> get peerIdentified => _peerIdentified.future;

  /// This side's identity (its credential's identity string), which the
  /// receiver field of the peer's `IDENT` must name when it names anyone:
  /// an `IDENT` whose receiver is not empty and differs from it is
  /// refused (GOAWAY `UNAUTHENTICATED`), so that a peer cannot relay
  /// another node's identification to this one. Null, the default, for a
  /// side without a credential, which refuses every `IDENT` that names a
  /// receiver. A `Switchboard` sets it on every connection from its
  /// credential. See also [MuxOptions.requireNamedIdent].
  String? get localIdentity => _localIdentity;

  set localIdentity(String? identity) {
    _localIdentity = identity;
    _localIdentityBytes = identity == null
        ? null
        : Uint8List.fromList(utf8.encode(identity));
  }

  String? _localIdentity;
  Uint8List? _localIdentityBytes;

  /// Completes when the peer's `NONCE` arrives before this side sent one:
  /// the peer intends to identify, or asks this side to (the two cannot be
  /// told apart). The connection has answered with its own `NONCE`
  /// already; whether to [identify] in return is the application's choice.
  /// Never completes otherwise, and never with an error.
  Future<void> get identityRequested => _identityRequested.future;

  /// Completes at the next valid `IDENT` of the peer, or when the
  /// connection ends. For holding channels until the peer identifies.
  @internal
  Future<void> get identityChanged =>
      (_identityEvent ??= Completer<void>()).future;

  /// Identifies this side to the peer with [credential] (wiki page
  /// "Switchboard Identity and Credentials", section "Connection
  /// identity"): sends `NONCE` unless this side has sent one, waits for
  /// the peer's `NONCE`, sends `IDENT` with [intent] (at most 64 bytes,
  /// default empty) and [receiver] (the identity the peer is expected to
  /// have, at most 255 bytes of UTF-8; null or empty names nobody) and,
  /// for a credential with a holder key, the proof signed with [holderKey]
  /// over `"SWBIDENT" ‖ our nonce ‖ the peer's nonce ‖ len8 intent ‖
  /// intent ‖ len8 receiver ‖ receiver` ([MuxIdent.proofMessage]). A
  /// bearer credential carries no proof, and [holderKey] is not used for
  /// it. A peer whose identity is not [receiver] refuses the `IDENT`, so
  /// that it cannot pass this side's identification on to a third node.
  ///
  /// Completes once the peer has handled the `IDENT`: a PING sent right
  /// after it has been answered. A peer handles the frames after an
  /// `IDENT` only once it has verified it, so the answer means it accepted
  /// the credential (or does not check identity); a peer that refuses it
  /// ends the connection with GOAWAY `UNAUTHENTICATED`. Calling again sends
  /// another `IDENT`, which replaces the first at the peer (to present a
  /// renewed credential).
  ///
  /// [timeout] (default [MuxOptions.identityTimeout]; [Duration.zero]: no
  /// bound) bounds the whole exchange. Fails with [SwitchboardException]:
  /// [StatusCode.unauthenticated] when the peer refused the credential,
  /// [StatusCode.deadlineExceeded] when the peer's `NONCE` or the
  /// confirmation did not arrive in time, [StatusCode.failedPrecondition]
  /// when the connection is closed, and the connection's end status when it
  /// ends meanwhile. Throws [ArgumentError] when the credential names a
  /// holder key and [holderKey] is missing or another, and when the
  /// intent, the receiver or the `IDENT` is too long.
  Future<void> identify(
    Credential credential, {
    HolderKey? holderKey,
    Uint8List? intent,
    String? receiver,
    Duration? timeout,
  }) async {
    final holder = credential.holderKey;
    if (holder != null) {
      if (holderKey == null) {
        throw ArgumentError.value(
          holderKey,
          'holderKey',
          'the credential names a holder key, the proof needs its key pair',
        );
      }
      if (!_bytesEqual(holderKey.publicKey, holder)) {
        throw ArgumentError.value(
          holderKey,
          'holderKey',
          'not the holder key the credential names',
        );
      }
    }
    final intentBytes = intent == null
        ? Uint8List(0)
        : Uint8List.fromList(intent);
    final receiverBytes = receiver == null
        ? Uint8List(0)
        : Uint8List.fromList(utf8.encode(receiver));
    final credentialBytes = credential.encode();
    // Checks the lengths before anything is sent.
    MuxIdent(
      credential: credentialBytes,
      intent: intentBytes,
      receiver: receiverBytes,
      proof: holder == null ? null : Uint8List(MuxIdent.proofLength),
    ).encode();
    if (_closing) {
      throw SwitchboardException.of(
        StatusCode.failedPrecondition,
        'connection is closed',
      );
    }
    final limit = timeout ?? options.identityTimeout;
    final watch = Stopwatch()..start();
    Future<T> bounded<T>(Future<T> future, String what) {
      if (limit <= Duration.zero) {
        return future;
      }
      final left = limit - watch.elapsed;
      return future.timeout(
        left > Duration.zero ? left : Duration.zero,
        onTimeout: () => throw SwitchboardException.of(
          StatusCode.deadlineExceeded,
          '$what within $limit',
        ),
      );
    }

    final localNonce = _localNonce ?? _sendNonce();
    final Uint8List peerNonce;
    try {
      peerNonce =
          _peerNonce ??
          await bounded(
            (_peerNonceWaiter ??= Completer<Uint8List>()..future.ignore())
                .future,
            'no NONCE from the peer',
          );
    } on SwitchboardException catch (e) {
      throw e.code == StatusCode.deadlineExceeded ? e : _identifyFailure();
    }
    final proof = holder == null
        ? null
        : await bounded(
            holderKey!.sign(
              MuxIdent.proofMessage(
                localNonce,
                peerNonce,
                intentBytes,
                receiverBytes,
              ),
            ),
            'proof not signed',
          );
    if (_closing) {
      throw _identifyFailure();
    }
    _log.fine(
      '$this: identifying as "${credential.identity}"'
      '${receiver == null || receiver.isEmpty ? '' : ' to "$receiver"'}',
    );
    _sendFrame(
      MuxControlMessage.ident(
        MuxIdent(
          credential: credentialBytes,
          intent: intentBytes,
          receiver: receiverBytes,
          proof: proof,
        ),
      ).toFrame(),
    );
    try {
      await bounded(ping(), 'IDENT not confirmed');
    } on SwitchboardException catch (e) {
      throw e.code == StatusCode.deadlineExceeded ? e : _identifyFailure();
    }
  }

  /// Why [identify] failed once the connection ended.
  SwitchboardException _identifyFailure() {
    final peer = _peerGoAwayReceived;
    if (peer != null && peer.known == StatusCode.unauthenticated) {
      return SwitchboardException.of(
        StatusCode.unauthenticated,
        'the peer refused the credential',
      );
    }
    if (_done.isCompleted || _closing) {
      return SwitchboardException(_closeStatus ?? _lostStatus());
    }
    return SwitchboardException.of(
      StatusCode.failedPrecondition,
      'connection is closed',
    );
  }

  /// Opens a channel carrying [openPayload] in its OPEN frame.
  ///
  /// The channel is usable at once. Throws [SwitchboardException] with
  /// [StatusCode.failedPrecondition] if the connection is closing, we sent
  /// GOAWAY, or the peer sent GOAWAY; with [StatusCode.resourceExhausted]
  /// if no channel id is free or the peer's announced channel limit is
  /// reached; with [StatusCode.frameTooLarge] if the OPEN frame would
  /// exceed the peer's announced frame limit.
  MuxChannel open(Uint8List openPayload) {
    if (_closing || _goAwaySent) {
      throw SwitchboardException.of(
        StatusCode.failedPrecondition,
        'connection is closing',
      );
    }
    if (_peerGoAway != null) {
      throw SwitchboardException.of(
        StatusCode.failedPrecondition,
        'peer is going away',
      );
    }
    final peerMaxChannels = _peerLimits?.maxChannels ?? 0;
    if (peerMaxChannels > 0 && _openCount >= peerMaxChannels) {
      throw SwitchboardException.of(
        StatusCode.resourceExhausted,
        'peer accepts at most $peerMaxChannels channels',
      );
    }
    final id = _allocateId();
    final peerMaxFrame = _peerLimits?.maxFrameSize ?? 0;
    final size = MuxFrame.headerSizeFor(id) + openPayload.length;
    if (peerMaxFrame > 0 && size > peerMaxFrame) {
      throw SwitchboardException.of(
        StatusCode.frameTooLarge,
        'OPEN of $size bytes exceeds the peer limit of $peerMaxFrame',
      );
    }
    final payload = Uint8List.fromList(openPayload);
    final link = MuxChannelLink(
      _host,
      this,
      id,
      isLocallyOpened: true,
      openPayload: payload,
    );
    _links[id] = link;
    _openCount++;
    if (_isOwnShortId(id)) {
      _shortIdsInUse++;
    }
    _sendFrame(MuxFrame.open(id, payload));
    return link.channel;
  }

  /// Most PINGs of [ping] awaiting their PONG. Beyond it, the oldest
  /// fails with [StatusCode.deadlineExceeded], so that a peer that
  /// withholds PONGs cannot make them accumulate.
  static const int maxPendingPings = 1024;

  /// Sends PING and completes with the round trip time when the matching
  /// PONG arrives.
  ///
  /// Without [payload] a unique one is generated. Fails with
  /// [SwitchboardException] if the connection is closed or ends before
  /// the PONG arrives, and with [StatusCode.deadlineExceeded] if
  /// [maxPendingPings] later PINGs are sent before it arrives. Throws
  /// [ArgumentError] if [payload] is longer than 125 bytes.
  Future<Duration> ping([Uint8List? payload]) {
    final message = MuxControlMessage.ping(payload ?? _nextPingPayload());
    if (_closing) {
      return Future.error(
        SwitchboardException.of(
          StatusCode.failedPrecondition,
          'connection is closed',
        ),
      );
    }
    if (_pings.length >= maxPendingPings) {
      _pings
          .removeAt(0)
          .completer
          .completeError(
            SwitchboardException.of(
              StatusCode.deadlineExceeded,
              'no PONG before $maxPendingPings later PINGs',
            ),
          );
    }
    final pending = _PendingPing(Uint8List.fromList(message.payload));
    _pings.add(pending);
    _sendFrame(message.toFrame());
    return pending.completer.future;
  }

  /// Graceful shutdown: sends GOAWAY carrying [status] (default
  /// `GOING_AWAY`), stops accepting channels (peer OPENs get CLOSE
  /// `GOING_AWAY`), waits up to [MuxOptions.goAwayGrace] for the open
  /// channels to finish, then [close]s.
  ///
  /// The reason is shortened on the wire if needed, on a UTF-8 character
  /// boundary, so that the GOAWAY payload stays within 1024 bytes and the
  /// frame fits the peer's announced frame limit.
  ///
  /// Throws [ArgumentError] synchronously for application status codes.
  Future<void> goAway([Status status = const Status(33)]) {
    checkMuxStatus(status);
    if (_closing) {
      return close();
    }
    if (!_goAwaySent) {
      _goAwaySent = true;
      _ownGoAway = status;
      _log.fine('$this: sending GOAWAY $status');
      _sendGoAway(status);
    }
    return _goAwayWait();
  }

  Future<void> _goAwayWait() async {
    if (_openCount > 0 && !_closing) {
      final idle = _idle ??= Completer<void>();
      final grace = Timer(options.goAwayGrace, () {
        if (!idle.isCompleted) {
          _log.fine('$this: GOAWAY grace expired with $_openCount channels');
          idle.complete();
        }
      });
      await idle.future;
      grace.cancel();
    }
    await close();
  }

  /// Closes the transport now. Every channel ends with `CONNECTION_LOST`
  /// (or the GOAWAY status if either side sent GOAWAY) and [done] completes.
  ///
  /// Completes once the transport has closed, waiting at most
  /// [MuxOptions.keepAliveTimeout] for it; a transport still open then is
  /// aborted if it implements [AbortableTransport]. Never throws.
  Future<void> close() => _shutdown(_lostStatus(), null);

  @override
  String toString() =>
      'MuxConnection(${isInitiator ? 'initiator' : 'acceptor'}, '
      '$_openCount channels${_closing ? ', closed' : ''})';

  /// Sets the next id the allocator tries: in the short range for ids
  /// below 0x10000, else in the long range (used only once every short id
  /// of our parity is in use). For tests of id wrapping.
  @visibleForTesting
  set nextChannelIdForTesting(int id) {
    if (id <= MuxFrame.maxShortId) {
      _nextShortId = id;
    } else {
      _nextLongId = id;
    }
  }

  // Allocation ----------------------------------------------------------

  bool _isOwnShortId(int id) =>
      id <= MuxFrame.maxShortId && (id & 1) == (_firstId & 1);

  /// Allocates by incrementing within the short range (ids below 0x10000
  /// of our parity), wrapping there, so that a long-lived connection keeps
  /// using short ids however many channels come and go. The long range is
  /// used only while every short id of our parity is in use, and never
  /// with [MuxOptions.shortIdsOnly]. Ids that are reserved, open or await
  /// the peer's CLOSE are skipped.
  int _allocateId() {
    if (_shortIdsInUse < _shortIdCapacity) {
      final id = _scan(_nextShortId, _firstId, MuxFrame.maxShortId);
      if (id != null) {
        _nextShortId = id + 2;
        return id;
      }
      _log.severe('$this: short id accounting is off, $_shortIdsInUse used');
    }
    if (!options.shortIdsOnly) {
      final id = _scan(_nextLongId, _firstLongId, MuxFrame.maxId);
      if (id != null) {
        _nextLongId = id + 2;
        return id;
      }
    }
    throw SwitchboardException.of(
      StatusCode.resourceExhausted,
      'no free channel id',
    );
  }

  /// The first free id of our parity from [start], wrapping from [last] to
  /// [first]; null if there is none.
  int? _scan(int start, int first, int last) {
    final candidates = (last - first) ~/ 2 + 1;
    var id = start < first ? first : start;
    for (var i = 0; i < candidates; i++) {
      if (id > last) {
        id = first;
      }
      final candidate = id;
      id += 2;
      if (MuxFrame.isReservedId(candidate) ||
          _links.containsKey(candidate) ||
          _awaitingClose.contains(candidate)) {
        continue;
      }
      return candidate;
    }
    return null;
  }

  // Sending -------------------------------------------------------------

  void _sendFrame(MuxFrame frame) {
    if (!_writable) {
      return;
    }
    try {
      final bytes = frame.encode();
      _transport.sink.add(bytes);
      _sentBytes += bytes.length;
    } on Object catch (e) {
      _log.fine('$this: transport write failed: $e');
      _writable = false;
    }
  }

  /// Sends GOAWAY with [status] shortened to fit the peer's frame limit.
  void _sendGoAway(Status status) {
    // Header and control type byte.
    const overhead = MuxFrame.shortHeaderSize + 1;
    final fitted = fitStatus(status, overhead, _peerMaxFrameSize);
    _sendFrame(MuxControlMessage.goAway(fitted).toFrame());
  }

  int get _peerMaxFrameSize => _peerLimits?.maxFrameSize ?? 0;

  Uint8List _nextPingPayload() {
    final n = _pingCounter;
    _pingCounter = (n + 1) & 0x7FFFFFFF;
    return Uint8List.fromList([
      n & 0xFF,
      (n >> 8) & 0xFF,
      (n >> 16) & 0xFF,
      (n >> 24) & 0xFF,
    ]);
  }

  // Receiving -----------------------------------------------------------

  void _onFrame(Uint8List bytes) {
    if (_closing) {
      return;
    }
    _receivedBytes += bytes.length;
    _noteReceive();
    if (_verifyingIdent) {
      // The transport is paused; a frame it delivered all the same waits
      // for the IDENT like the rest.
      _heldFrames.add(bytes);
      return;
    }
    _processFrame(bytes);
  }

  void _processFrame(Uint8List bytes) {
    try {
      _handleFrame(bytes);
    } on SwitchboardException catch (e) {
      _fail(e.status);
    } on Object catch (e, st) {
      _log.severe('$this: internal error while handling a frame', e, st);
      _fail(Status.of(StatusCode.internal, 'internal error'));
    }
  }

  void _handleFrame(Uint8List bytes) {
    final maxFrame = options.maxFrameSize;
    if (maxFrame > 0 && bytes.length > maxFrame) {
      throw SwitchboardException.of(
        StatusCode.frameTooLarge,
        'frame of ${bytes.length} bytes exceeds limit of $maxFrame',
      );
    }
    final frame = MuxFrame.decode(bytes);
    if (frame.longForm && options.shortIdsOnly) {
      throw SwitchboardException.of(
        StatusCode.unsupported,
        'long channel ids are not supported',
      );
    }
    final id = frame.channelId;
    if (id == MuxFrame.controlChannelId) {
      _handleControl(frame.payload);
      return;
    }
    switch (frame.command) {
      case MuxCommand.open:
        _handleOpen(id, frame.payload);
      case MuxCommand.data:
        final link = _links[id];
        if (link != null && !link.closeReceived) {
          link.receiveData(frame.payload);
        } else if (link == null && _awaitingClose.contains(id)) {
          // In flight before the peer saw our CLOSE: dropped.
        } else {
          throw ProtocolException('DATA on channel $id which is not open');
        }
      case MuxCommand.close:
        final status = statusFromWire(
          decodeStatusPayload(frame.payload, 'CLOSE'),
        );
        final link = _links[id];
        if (link != null && !link.closeReceived) {
          link.receiveClose(status);
        } else if (link == null && _awaitingClose.remove(id)) {
          // The confirmation of a CLOSE we sent without a channel: the id
          // is mutually closed and free again.
          if (_isOwnShortId(id)) {
            _shortIdsInUse--;
          }
        } else {
          throw ProtocolException('CLOSE on channel $id which is not open');
        }
    }
  }

  void _handleOpen(int id, Uint8List payload) {
    // The peer allocates odd ids if we are the initiator, even otherwise.
    if (id.isOdd != isInitiator) {
      throw ProtocolException('OPEN on channel $id with the wrong parity');
    }
    if (_links.containsKey(id) || _awaitingClose.contains(id)) {
      throw ProtocolException('OPEN on channel $id which is in use');
    }
    Status? rejection;
    final payloadBudget = _openPayloadBudget;
    if (_goAwaySent) {
      rejection = Status.of(StatusCode.goingAway);
    } else if (_incomingCancelled) {
      rejection = Status.of(StatusCode.unavailable, 'not accepting channels');
    } else if (options.maxChannels > 0 &&
        (_openCount >= options.maxChannels ||
            _undelivered.length >= options.maxChannels)) {
      rejection = Status.of(
        StatusCode.resourceExhausted,
        'at most ${options.maxChannels} channels',
      );
    } else if (payloadBudget != null &&
        _openPayloadBytes + payload.length > payloadBudget) {
      rejection = Status.of(
        StatusCode.resourceExhausted,
        'open payloads exceed $payloadBudget bytes',
      );
    }
    if (rejection != null) {
      _reject(id, rejection);
      return;
    }
    final link = MuxChannelLink(
      _host,
      this,
      id,
      isLocallyOpened: false,
      openPayload: Uint8List.fromList(payload),
    )..incomingPending = true;
    _links[id] = link;
    _openCount++;
    _openPayloadBytes += payload.length;
    _noteBuffered(payload.length);
    _undelivered.add(link);
    _scheduleIncomingDrain();
  }

  /// [MuxOptions.maxOpenPayloadBytes], or half of
  /// [MuxOptions.receiveHighWaterMarkBytes] if that is smaller; null for
  /// none.
  int? get _openPayloadBudget {
    final budget = options.maxOpenPayloadBytes;
    final mark = options.receiveHighWaterMarkBytes;
    final half = mark > 0 ? mark ~/ 2 : null;
    if (budget <= 0) {
      return half;
    }
    return half != null && half < budget ? half : budget;
  }

  /// Releases the accounting of the OPEN payload of a channel the peer
  /// opened, once it is both closed and no longer awaiting delivery.
  void _releaseOpenPayload(MuxChannelLink link) {
    if (link.channel.isLocallyOpened || _closing || link.incomingPending) {
      return;
    }
    final size = link.channel.openPayload.length;
    _openPayloadBytes -= size;
    _noteBuffered(-size);
  }

  /// Rejects a peer OPEN with CLOSE carrying [status], remembering only
  /// the id until the peer confirms.
  void _reject(int id, Status status) {
    final cap = options.maxPendingRejections;
    if (cap > 0 && _awaitingClose.length >= cap) {
      throw SwitchboardException.of(
        StatusCode.resourceExhausted,
        'peer left $cap rejected channels unconfirmed',
      );
    }
    _log.fine('$this: rejecting channel $id: $status');
    _awaitingClose.add(id);
    _sendFrame(
      MuxFrame.close(
        id,
        fitStatus(status, MuxFrame.headerSizeFor(id), _peerMaxFrameSize),
      ),
    );
  }

  void _handleControl(Uint8List payload) {
    final message = MuxControlMessage.decode(payload);
    switch (message.knownType) {
      case MuxControlType.ping:
        _sendFrame(MuxControlMessage.pong(message.payload).toFrame());
      case MuxControlType.pong:
        _completePing(message.payload);
      case MuxControlType.goAway:
        final status = statusFromWire(message.goAwayStatus);
        if (_peerGoAway != null) {
          return;
        }
        _log.fine('$this: peer sent GOAWAY $status');
        _peerGoAwayReceived = status;
        _peerGoAway = status.known == StatusCode.goingAway
            ? status
            : Status.of(StatusCode.goingAway, status.toString());
        _peerGoAwayStatus.complete(status);
        scheduleMicrotask(_checkIdle);
      case MuxControlType.limits:
        _peerLimits = MuxLimits.decode(message.payload);
        _log.fine('$this: peer limits $_peerLimits');
      case MuxControlType.nonce:
        _onPeerNonce(message.payload);
      case MuxControlType.ident:
        _onIdent(message.payload);
      case null:
        _log.fine('$this: ignoring control type ${message.type}');
    }
  }

  // Identity ------------------------------------------------------------

  /// Sends our NONCE (once per connection) and returns it.
  Uint8List _sendNonce() {
    final nonce = secureRandomBytes(MuxIdent.nonceLength);
    _localNonce = nonce;
    _sendFrame(MuxControlMessage.nonce(nonce).toFrame());
    return nonce;
  }

  void _onPeerNonce(Uint8List payload) {
    if (payload.length != MuxIdent.nonceLength) {
      throw ProtocolException('NONCE of ${payload.length} bytes');
    }
    if (_peerNonce != null) {
      throw ProtocolException('second NONCE');
    }
    final nonce = Uint8List.fromList(payload);
    _peerNonce = nonce;
    final requested = _localNonce == null;
    if (requested) {
      _sendNonce();
    }
    final waiter = _peerNonceWaiter;
    _peerNonceWaiter = null;
    waiter?.complete(nonce);
    if (requested && !_identityRequested.isCompleted) {
      _identityRequested.complete();
    }
  }

  void _onIdent(Uint8List payload) {
    final localNonce = _localNonce;
    final peerNonce = _peerNonce;
    if (localNonce == null || peerNonce == null) {
      throw ProtocolException('IDENT before both nonces were exchanged');
    }
    // The envelope rules hold with or without a verifier, so that a
    // malformed IDENT does not tell whether this side checks identity.
    final ident = MuxIdent.decode(payload);
    final verifier = options.identityVerifier;
    if (verifier == null) {
      _log.fine('$this: ignoring IDENT, no identity verifier');
      return;
    }
    // Frames after the IDENT wait for its verification, so that they see
    // the identity it establishes (or never run if it fails).
    _verifyingIdent = true;
    _subscription.pause();
    unawaited(_verifyIdent(verifier, ident, peerNonce, localNonce));
  }

  /// Verifies [ident], sent by the peer with [senderNonce] (the peer's) and
  /// [receiverNonce] (ours); then sets the identity or ends the connection
  /// with GOAWAY `UNAUTHENTICATED`, and handles the frames held meanwhile.
  /// Never fails.
  Future<void> _verifyIdent(
    CredentialVerifier verifier,
    MuxIdent ident,
    Uint8List senderNonce,
    Uint8List receiverNonce,
  ) async {
    PeerIdentity? identity;
    var failure = _receiverProblem(ident.receiver) ?? '';
    // Checked against this side's identity: valid UTF-8 when not empty.
    final receiver = utf8.decode(ident.receiver, allowMalformed: true);
    try {
      if (failure.isNotEmpty) {
        // Refused for its receiver: nothing else is checked.
        throw SwitchboardException.of(StatusCode.unauthenticated, failure);
      }
      final credential = await verifier.verify(
        Uint8List.fromList(ident.credential),
      );
      final holder = credential.holderKey;
      if (holder == null) {
        if (ident.proof.isNotEmpty) {
          failure = 'a proof with a bearer credential';
        }
      } else if (ident.proof.length != MuxIdent.proofLength ||
          !await ed25519Verify(
            holder,
            MuxIdent.proofMessage(
              senderNonce,
              receiverNonce,
              ident.intent,
              ident.receiver,
            ),
            ident.proof,
          )) {
        failure = 'proof of possession does not verify';
      }
      if (failure.isEmpty) {
        identity = PeerIdentity(
          credential: credential,
          intent: Uint8List.fromList(ident.intent),
          verifiedAt: clock.now(),
          receiver: receiver,
        );
      }
    } on SwitchboardException catch (e) {
      failure = e.status.reason;
    } on Object catch (e, st) {
      _log.warning('$this: IDENT verification failed', e, st);
      failure = 'verification failed';
    }
    _verifyingIdent = false;
    if (_closing) {
      _heldFrames.clear();
      return;
    }
    if (identity == null) {
      _log.info('$this: IDENT refused: $failure');
      _heldFrames.clear();
      _fail(_unauthenticated);
      return;
    }
    _log.fine('$this: peer identified as $identity');
    _peerIdentity = identity;
    if (!_peerIdentified.isCompleted) {
      _peerIdentified.complete(identity);
    }
    _signalIdentity();
    while (_heldFrames.isNotEmpty && !_verifyingIdent && !_closing) {
      _processFrame(_heldFrames.removeFirst());
    }
    if (!_closing) {
      _subscription.resume();
    }
  }

  /// Why an `IDENT` naming [receiver] is refused here, or null when it is
  /// not: a receiver other than [localIdentity], or none while
  /// [MuxOptions.requireNamedIdent].
  String? _receiverProblem(Uint8List receiver) {
    if (receiver.isEmpty) {
      return options.requireNamedIdent ? 'the IDENT names no receiver' : null;
    }
    final own = _localIdentityBytes;
    if (own == null || !_bytesEqual(own, receiver)) {
      return 'the IDENT names another receiver '
          '("${utf8.decode(receiver, allowMalformed: true)}")';
    }
    return null;
  }

  /// The status of the GOAWAY sent for an `IDENT` that fails verification.
  static final Status _unauthenticated = Status.of(
    StatusCode.unauthenticated,
    'identification failed',
  );

  void _signalIdentity() {
    final event = _identityEvent;
    _identityEvent = null;
    event?.complete();
  }

  void _completePing(Uint8List payload) {
    for (var i = 0; i < _pings.length; i++) {
      final pending = _pings[i];
      if (_bytesEqual(pending.payload, payload)) {
        _pings.removeAt(i);
        pending.completer.complete(pending.stopwatch.elapsed);
        return;
      }
    }
    // Unsolicited PONGs (including answers to keep-alive PINGs) are
    // ignored.
  }

  void _onTransportError(Object error, StackTrace stackTrace) {
    if (_closing) {
      return;
    }
    if (error is SwitchboardException) {
      switch (error.code) {
        case StatusCode.protocolError ||
            StatusCode.frameTooLarge ||
            StatusCode.unsupported:
          _fail(error.status);
          return;
        default:
          break;
      }
    }
    _log.fine('$this: transport failed: $error');
    unawaited(_shutdown(_lostStatus(), null));
  }

  void _onTransportDone() {
    if (_closing) {
      return;
    }
    _log.fine('$this: transport closed by peer');
    _writable = false;
    unawaited(_shutdown(_lostStatus(), null));
  }

  // Incoming channel delivery --------------------------------------------

  void _scheduleIncomingDrain() {
    if (_incomingDrainScheduled) {
      return;
    }
    _incomingDrainScheduled = true;
    scheduleMicrotask(_drainIncoming);
  }

  void _drainIncoming() {
    _incomingDrainScheduled = false;
    while (_undelivered.isNotEmpty &&
        _incoming.hasListener &&
        !_incoming.isPaused) {
      final link = _undelivered.removeFirst()..incomingPending = false;
      if (link.channel.state == MuxChannelState.closed) {
        _releaseOpenPayload(link);
      }
      _incoming.add(link.channel);
    }
    if (_incomingEndRequested && _undelivered.isEmpty && !_incoming.isClosed) {
      unawaited(_incoming.close());
    }
  }

  void _onIncomingCancel() {
    _incomingCancelled = true;
    if (_undelivered.isEmpty) {
      return;
    }
    final links = List.of(_undelivered);
    _undelivered.clear();
    _log.fine(
      '$this: incoming cancelled, closing ${links.length} undelivered '
      'channels',
    );
    final status = Status.of(StatusCode.unavailable, 'not accepting channels');
    for (final link in links) {
      link.incomingPending = false;
      if (link.channel.state == MuxChannelState.closed) {
        _releaseOpenPayload(link);
      }
      link.closeUndelivered(status);
    }
  }

  // Channel bookkeeping --------------------------------------------------

  void _release(MuxChannelLink link) {
    if (!identical(_links[link.id], link)) {
      return;
    }
    _links.remove(link.id);
    _openCount--;
    _releaseOpenPayload(link);
    if (_isOwnShortId(link.id)) {
      _shortIdsInUse--;
    }
    // Deferred so that the channel finishes sending its confirming CLOSE
    // before an idle connection is closed.
    scheduleMicrotask(_checkIdle);
  }

  void _abandon(MuxChannelLink link) {
    if (_closing || !identical(_links[link.id], link)) {
      return;
    }
    _log.fine(
      '$this: channel ${link.id}: no CLOSE confirmation within '
      '${options.closeConfirmTimeout}',
    );
    _links.remove(link.id);
    _openCount--;
    _releaseOpenPayload(link);
    _awaitingClose.add(link.id);
    link.abandoned();
    scheduleMicrotask(_checkIdle);
    final cap = options.maxPendingRejections;
    if (cap > 0 && _awaitingClose.length > cap) {
      _fail(
        Status.of(
          StatusCode.resourceExhausted,
          'peer left more than $cap CLOSEs unconfirmed',
        ),
      );
    }
  }

  void _checkIdle() {
    if (_closing || _openCount > 0) {
      return;
    }
    final idle = _idle;
    _idle = null;
    if (idle != null && !idle.isCompleted) {
      idle.complete();
    }
    if (_peerGoAway != null) {
      _log.fine('$this: idle after peer GOAWAY, closing');
      unawaited(close());
    }
  }

  /// Tracks bytes buffered in channel queues; pauses reading the transport
  /// above the high-water mark and resumes at half of it.
  void _noteBuffered(int delta) {
    _bufferedBytes += delta;
    final mark = options.receiveHighWaterMarkBytes;
    if (mark <= 0 || _closing) {
      return;
    }
    if (!_receivePaused) {
      if (_bufferedBytes > mark) {
        _receivePaused = true;
        _log.fine('$this: $_bufferedBytes bytes buffered, pausing input');
        _subscription.pause();
      }
    } else if (_bufferedBytes <= mark ~/ 2) {
      _receivePaused = false;
      _log.fine('$this: buffers drained, resuming input');
      // The silence while paused was our own doing.
      _sinceReceive.reset();
      _subscription.resume();
    }
  }

  // Keep-alive ----------------------------------------------------------

  void _startKeepAlive() {
    final interval = options.keepAliveInterval;
    if (interval == null) {
      return;
    }
    _keepAliveTimer = Timer(interval, _onKeepAliveTimer);
  }

  void _noteReceive() {
    _sinceReceive.reset();
    if (_keepAliveProbing) {
      _keepAliveProbing = false;
      _keepAliveTimer?.cancel();
      _startKeepAlive();
    }
  }

  void _onKeepAliveTimer() {
    final interval = options.keepAliveInterval;
    if (_closing || interval == null) {
      return;
    }
    if (_receivePaused || _verifyingIdent || _outputProgressed()) {
      // We are not reading, so silence says nothing about the peer; or the
      // transport stopped reading because of our output, which the peer
      // is still consuming.
      _sinceReceive.reset();
      _keepAliveProbing = false;
      _keepAliveTimer = Timer(interval, _onKeepAliveTimer);
      return;
    }
    if (_keepAliveProbing) {
      _log.info('$this: no answer to keep-alive PING, closing');
      unawaited(_shutdown(_lostStatus('keep-alive timeout'), null));
      return;
    }
    final silence = _sinceReceive.elapsed;
    if (silence < interval) {
      _keepAliveTimer = Timer(interval - silence, _onKeepAliveTimer);
      return;
    }
    _keepAliveProbing = true;
    _sendFrame(MuxControlMessage.ping(_nextPingPayload()).toFrame());
    _keepAliveTimer = Timer(options.keepAliveTimeout, _onKeepAliveTimer);
  }

  /// Whether the transport is throttled by its output and the peer has
  /// read some of it since the last check.
  bool _outputProgressed() {
    final transport = _transport;
    if (transport is! OutputBufferedTransport) {
      return false;
    }
    final output = transport as OutputBufferedTransport;
    final accepted = output.acceptedOutputBytes;
    final progressed =
        output.isInputThrottled && accepted != _lastAcceptedOutput;
    _lastAcceptedOutput = accepted;
    return progressed;
  }

  // Shutdown ------------------------------------------------------------

  /// The status we sent in our own graceful GOAWAY, if any.
  Status? _ownGoAway;

  /// Status for channels (and the connection) when the transport ends
  /// without us killing it for a protocol error: the peer's GOAWAY status,
  /// else our own graceful GOAWAY status, else `CONNECTION_LOST`.
  Status _lostStatus([String reason = '']) =>
      _peerGoAway ?? _ownGoAway ?? Status.of(StatusCode.connectionLost, reason);

  /// Ends the connection because the peer broke the protocol: GOAWAY with
  /// [status], then close.
  void _fail(Status status) {
    if (_closing) {
      return;
    }
    _log.warning('$this: closing with $status');
    _sendGoAway(status);
    unawaited(_shutdown(status, _lostStatus()));
  }

  /// Ends the connection with [status]; channels end with [channelStatus]
  /// (default [status]). Idempotent; never throws.
  Future<void> _shutdown(Status status, Status? channelStatus) {
    _closeStatus ??= status;
    return _closeFuture ??= _doShutdown(status, channelStatus ?? status);
  }

  /// The status the connection ended (or is ending) with.
  Status? _closeStatus;

  Future<void> _doShutdown(Status status, Status channelStatus) async {
    _closing = true;
    _finish(status, channelStatus);
    _writable = false;
    try {
      await Future.wait<void>([
        _subscription.cancel(),
        _transport.sink.close().then<void>((_) {}),
      ]).timeout(options.keepAliveTimeout);
    } on TimeoutException {
      final transport = _transport;
      if (transport is AbortableTransport) {
        _log.fine('$this: transport not closed in time, aborting it');
        (transport as AbortableTransport).abort();
      } else {
        _log.fine('$this: transport not closed in time');
      }
    } on Object catch (e) {
      _log.fine('$this: transport close: $e');
    }
  }

  void _finish(Status status, Status channelStatus) {
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;
    final links = _links.values.toList();
    _links.clear();
    _awaitingClose.clear();
    _shortIdsInUse = 0;
    _bufferedBytes -= _openPayloadBytes;
    _openPayloadBytes = 0;
    _openCount = 0;
    for (final link in links) {
      try {
        link.connectionLost(channelStatus);
      } on Object catch (e, st) {
        _log.warning('$this: error ending channel ${link.id}', e, st);
      }
    }
    final pings = List.of(_pings);
    _pings.clear();
    for (final pending in pings) {
      pending.completer.completeError(SwitchboardException(status));
    }
    _heldFrames.clear();
    final nonceWaiter = _peerNonceWaiter;
    _peerNonceWaiter = null;
    nonceWaiter?.completeError(SwitchboardException(status));
    _signalIdentity();
    final idle = _idle;
    _idle = null;
    if (idle != null && !idle.isCompleted) {
      idle.complete();
    }
    _incomingEndRequested = true;
    _scheduleIncomingDrain();
    if (!_done.isCompleted) {
      _done.complete(status);
    }
  }
}

class _Host implements MuxChannelHost {
  _Host(this._connection);

  final MuxConnection _connection;

  @override
  MuxOptions get options => _connection.options;

  @override
  void sendFrame(MuxFrame frame) => _connection._sendFrame(frame);

  @override
  void release(MuxChannelLink link) => _connection._release(link);

  @override
  void abandon(MuxChannelLink link) => _connection._abandon(link);

  @override
  void noteBuffered(int delta) => _connection._noteBuffered(delta);

  @override
  int get peerMaxFrameSize => _connection._peerMaxFrameSize;
}

class _PendingPing {
  _PendingPing(this.payload);

  final Uint8List payload;
  final Completer<Duration> completer = Completer<Duration>();
  final Stopwatch stopwatch = Stopwatch()..start();
}

int _clampU32(int value) => value < 0
    ? 0
    : value > 0xFFFFFFFF
    ? 0xFFFFFFFF
    : value;

bool _bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) {
    return false;
  }
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) {
      return false;
    }
  }
  return true;
}
