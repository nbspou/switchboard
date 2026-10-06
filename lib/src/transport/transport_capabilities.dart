/*
Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Author: Jan Boon <jan.boon@kaetemi.be>
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
