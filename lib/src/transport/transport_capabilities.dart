/*
Polyverse Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Authors:
  Jan Boon <jan.boon@kaetemi.be>
  Claude Opus 5.5 <noreply@anthropic.com>
*/

/// Optional capabilities of a transport, which the mux discovers with type
/// tests on the `StreamChannel` it is given.
library;

/// A transport that refuses incoming frames above a size limit of its own.
///
/// The limit should agree with `MuxOptions.maxFrameSize`: a `MuxConnection`
/// over a transport with a smaller limit logs a warning and announces the
/// smaller value with LIMITS, since that is what it can actually receive.
abstract interface class FrameLimited {
  /// Largest incoming frame in bytes, mux header included, that the
  /// transport accepts; 0 when it enforces no limit.
  int get maxFrameSize;
}

/// A transport that can be torn down at once, without a graceful close.
///
/// A `MuxConnection` calls [abort] when the transport has not closed within
/// `MuxOptions.keepAliveTimeout` of a local close, so that a peer that
/// stopped reading cannot keep the connection and its unsent output alive.
abstract interface class AbortableTransport {
  /// Destroys the underlying connection, discarding output not yet written.
  /// Ends the stream and completes the sink's `done`. Idempotent; never
  /// throws.
  void abort();
}

/// A transport that queues output its connection has not accepted yet and
/// stops reading while too much of it waits.
///
/// While [isInputThrottled], a `MuxConnection` receives nothing, so its
/// keep-alive counts progress of [acceptedOutputBytes] (the peer is
/// reading) as a sign of life instead of incoming frames. A peer that
/// neither reads nor sends is still timed out.
abstract interface class OutputBufferedTransport {
  /// Bytes written to the transport that the connection has not accepted
  /// yet.
  int get bufferedOutputBytes;

  /// Total bytes the connection has accepted so far. Grows while the peer
  /// reads.
  int get acceptedOutputBytes;

  /// Whether reading the input is paused because too much output waits.
  bool get isInputThrottled;
}

/// A transport that tells whether it takes more output at once, so that the
/// layer above keeps what it cannot take yet, where it can still choose the
/// order.
///
/// A `MuxConnection` over such a transport holds DATA frames in per-channel
/// queues while [isOutputReady] is false, and writes them in the order of
/// its output scheduler once [outputReady] completes: control messages
/// first, then ordinary channels, then bulk ones. A transport without this
/// capability takes every frame at once, in the order written.
abstract interface class OutputReadyTransport {
  /// Whether a frame written now goes to the connection without waiting
  /// behind earlier output. True once the transport is closing or closed
  /// (what is written is then dropped).
  bool get isOutputReady;

  /// Completes when [isOutputReady] becomes true, at once if it is. Never
  /// fails.
  Future<void> get outputReady;
}
