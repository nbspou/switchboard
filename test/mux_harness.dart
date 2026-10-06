// Shared helpers for the mux tests.

import 'dart:typed_data';

import 'package:async/async.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:switchboard/src/bytes.dart';
import 'package:switchboard/src/mux/mux_connection.dart';
import 'package:switchboard/src/mux/mux_frame.dart';
import 'package:switchboard/src/status.dart';
import 'package:switchboard/src/transport/memory_transport.dart';
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
