/*
Polyverse Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Authors:
  Jan Boon <jan.boon@kaetemi.be>
  Claude Opus 5.5 <noreply@anthropic.com>
*/

// Shared helpers for the mux tests.

import 'dart:async';
import 'dart:typed_data';

import 'package:async/async.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:switchboard/src/bytes.dart';
import 'package:switchboard/src/mux/mux_connection.dart';
import 'package:switchboard/src/mux/mux_frame.dart';
import 'package:switchboard/src/status.dart';
import 'package:switchboard/src/transport/memory_transport.dart';
import 'package:switchboard/src/transport/transport_capabilities.dart';
import 'package:test/test.dart';

/// Keep-alive off so that tests only see the frames they cause.
const quiet = MuxOptions(
  keepAliveInterval: null,
  goAwayGrace: Duration(seconds: 2),
);

/// Additionally no LIMITS, for byte exact raw peer tests.
const rawOptions = MuxOptions(keepAliveInterval: null, announceLimits: false);

final empty = Uint8List(0);

Matcher throwsStatus(StatusCode code) =>
    throwsA(isA<SwitchboardException>().having((e) => e.code, 'code', code));

Matcher hasCode(StatusCode code) =>
    isA<Status>().having((s) => s.known, 'known', code);

(MuxConnection, MuxConnection) muxPair({
  MuxOptions initiator = quiet,
  MuxOptions acceptor = quiet,
}) {
  final (a, b) = MemoryTransport.pair();
  return (
    MuxConnection(a, isInitiator: true, options: initiator),
    MuxConnection(b, isInitiator: false, options: acceptor),
  );
}

/// The far side of a transport, driven with raw frames.
class RawPeer {
  RawPeer(this.transport) : frames = StreamQueue(transport.stream);

  final StreamChannel<Uint8List> transport;
  final StreamQueue<Uint8List> frames;

  void send(String hex) => transport.sink.add(hexBytes(hex));

  Future<String> nextHex() async => hexString(await frames.next);

  Future<MuxFrame> next() async => MuxFrame.decode(await frames.next);

  /// Skips frames until a control message of [type] and returns it.
  Future<MuxControlMessage> nextControl(MuxControlType type) async {
    while (true) {
      final frame = await next();
      if (frame.channelId == 0) {
        final message = MuxControlMessage.decode(frame.payload);
        if (message.knownType == type) {
          return message;
        }
      }
    }
  }

  /// Every frame until the transport closes.
  Future<List<MuxFrame>> rest() async => [
    for (final bytes in await frames.rest.toList()) MuxFrame.decode(bytes),
  ];
}

(MuxConnection, RawPeer) rawPair({
  bool muxIsInitiator = true,
  MuxOptions options = rawOptions,
}) {
  final (a, b) = MemoryTransport.pair();
  return (
    MuxConnection(a, isInitiator: muxIsInitiator, options: options),
    RawPeer(b),
  );
}

bool isControl(MuxFrame frame, MuxControlType type) =>
    frame.channelId == 0 &&
    MuxControlMessage.decode(frame.payload).knownType == type;

/// A transport that takes output only as the test allows: an
/// [OutputReadyTransport] over [inner], for tests of the output scheduler.
///
/// It is ready while [allow] has granted frames; each frame written then
/// uses one. Frames written while it is not ready (control messages, which
/// the mux never holds) go through all the same. [written] records every
/// frame in order.
class GatedTransport
    with StreamChannelMixin<Uint8List>
    implements OutputReadyTransport {
  GatedTransport(this.inner) {
    _sink = _GatedSink(this);
  }

  final StreamChannel<Uint8List> inner;
  final List<MuxFrame> written = [];
  int _allowance = 0;
  Completer<void>? _waiter;
  // Closed through the inner transport.
  // ignore: close_sinks
  late final _GatedSink _sink;

  @override
  Stream<Uint8List> get stream => inner.stream;

  @override
  StreamSink<Uint8List> get sink => _sink;

  @override
  bool get isOutputReady => _allowance > 0;

  @override
  Future<void> get outputReady {
    if (isOutputReady) {
      return Future<void>.value();
    }
    return (_waiter ??= Completer<void>()).future;
  }

  /// Takes [frames] more frames; the mux writes them on its next turn.
  void allow(int frames) {
    _allowance += frames;
    final waiter = _waiter;
    if (waiter != null && isOutputReady) {
      _waiter = null;
      waiter.complete();
    }
  }

  /// Written frames on [channelId], or every frame but control messages.
  List<MuxFrame> on([int? channelId]) => [
    for (final frame in written)
      if (channelId == null
          ? frame.channelId != 0
          : frame.channelId == channelId)
        frame,
  ];
}

class _GatedSink implements StreamSink<Uint8List> {
  _GatedSink(this._transport);

  final GatedTransport _transport;

  @override
  void add(Uint8List event) {
    if (_transport._allowance > 0) {
      _transport._allowance--;
    }
    _transport.written.add(MuxFrame.decode(event));
    _transport.inner.sink.add(event);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _transport.inner.sink.addError(error, stackTrace);

  @override
  Future<void> addStream(Stream<Uint8List> stream) async {
    await for (final event in stream) {
      add(event);
    }
  }

  @override
  Future<void> close() => _transport.inner.sink.close();

  @override
  Future<void> get done => _transport.inner.sink.done;
}

/// Two mux connections over a memory pair whose initiator side is gated
/// ([GatedTransport], not ready until the test allows frames).
(MuxConnection, MuxConnection, GatedTransport) gatedPair({
  MuxOptions initiator = quiet,
  MuxOptions acceptor = quiet,
}) {
  final (a, b) = MemoryTransport.pair();
  final gate = GatedTransport(a);
  return (
    MuxConnection(gate, isInitiator: true, options: initiator),
    MuxConnection(b, isInitiator: false, options: acceptor),
    gate,
  );
}
