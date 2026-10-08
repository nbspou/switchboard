/*
Polyverse Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Authors:
  Jan Boon <jan.boon@kaetemi.be>
  Claude Opus 5.5 <noreply@anthropic.com>
*/

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:async/async.dart';
import 'package:switchboard/switchboard.dart';
import 'package:test/test.dart';

/// The minimal round trip of the wiki page "Polyverse Switchboard Embedded Profile",
/// byte for byte, from a raw TCP socket to a listening Switchboard.
void main() {
  const preamble = '53 57 42 44 01 00 00 00';
  // transport length 12, mux OPEN ch 2: 01 'd' 'e' 'v' 00 00 00 00 00
  const open = '0C 00 00 00  12 02 00  01 64 65 76 00 00 00 00 00';
  // transport length 15, mux DATA ch 2, talk request 1 "PING"
  const request = '0F 00 00 00  02 02 00  03 50 49 4E 47 00 00 00 00 01 00 00';
  // transport length 7, mux DATA ch 2, talk final response to 1
  const reply = '07 00 00 00 02 02 00 04 01 00 00';
  // transport length 3, mux CLOSE ch 2 (status absent: OK)
  const close = '03 00 00 00 22 02 00';

  late Switchboard endpoint;
  late Uri uri;
  late Socket socket;
  late StreamQueue<int> input;

  Future<void> start(MuxOptions options) async {
    endpoint = Switchboard(muxOptions: options);
    addTearDown(endpoint.close);
    endpoint.registerService(Name('dev'), (incoming) {
      incoming.talk().messages.listen((message) {
        if (message.expectsReply) {
          message.reply(Uint8List(0));
        }
      });
    });
    uri = await endpoint.listenTcp(InternetAddress.loopbackIPv4, 0);
    socket = await Socket.connect(uri.host, uri.port);
    addTearDown(socket.destroy);
    input = StreamQueue(socket.expand((chunk) => chunk));
    addTearDown(() => input.cancel(immediate: true));
  }

  Future<String> read(int count) async => hexString(await input.take(count));

  /// Reads one transport frame (length prefix and body), as hex.
  Future<String> readFrame() async {
    final prefix = await input.take(4);
    final length =
        prefix[0] | (prefix[1] << 8) | (prefix[2] << 16) | (prefix[3] << 24);
    return hexString([...prefix, ...await input.take(length)]);
  }

  test('exact bytes, endpoint announcing no limits', () async {
    await start(
      const MuxOptions(announceLimits: false, keepAliveInterval: null),
    );
    socket.add(hexBytes('$preamble $open $request'));
    expect(await read(8), preamble);
    expect(await read(11), reply);
    // The device closes the channel; the endpoint confirms.
    socket.add(hexBytes(close));
    expect(await read(7), close);
    // Then the device hangs up.
    await socket.close();
    expect(await input.hasNext, isFalse);
  });

  test('a device announcing a 256 byte window is held to it from the first '
      'channel on', () async {
    // The device listens; the node connects and talks at once, before the
    // device's LIMITS can have arrived.
    final device = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(device.close);
    final node = Switchboard(
      muxOptions: const MuxOptions(keepAliveInterval: null),
    );
    addTearDown(node.close);
    final accepted = device.first;
    final connection = await node.connect(
      Uri.parse('tcp://127.0.0.1:${device.port}'),
    );
    final talk = TalkChannel(
      connection.open(hexBytes('01 64 65 76 00 00 00 00 00')),
    );
    for (var i = 0; i < 3; i++) {
      unawaited(talk.send('PUT', Uint8List(100)));
    }
    final peer = await accepted;
    addTearDown(peer.destroy);
    final bytes = StreamQueue(peer.expand((chunk) => chunk));
    addTearDown(() => bytes.cancel(immediate: true));
    Future<List<int>> frame() async {
      final prefix = await bytes.take(4);
      final length =
          prefix[0] | (prefix[1] << 8) | (prefix[2] << 16) | (prefix[3] << 24);
      return bytes.take(length);
    }

    expect(hexString(await bytes.take(8)), preamble);
    // The node's LIMITS, then the OPEN; no DATA yet.
    expect(hexString(await frame()), startsWith('02 00 00 04'));
    expect(hexString(await frame()), startsWith('12 02 00'));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    // The device announces: no frame limit, 4 channels, a 256 byte window.
    peer.add(
      hexBytes(
        '$preamble 10 00 00 00 02 00 00 04 00 00 00 00 04 00 00 00 '
        '00 01 00 00',
      ),
    );
    // Each message costs 109 + 16 bytes: two fit the window, the third
    // waits for the device's credit.
    var used = 0;
    for (var i = 0; i < 2; i++) {
      final data = await frame();
      expect(data.sublist(0, 3), [0x02, 0x02, 0x00]);
      used += data.length - 3 + 16;
    }
    expect(used, lessThanOrEqualTo(256));
    final third = bytes.hasNext.timeout(const Duration(milliseconds: 100));
    await expectLater(third, throwsA(isA<TimeoutException>()));
    // CREDIT for channel 2: the third message goes.
    peer.add(
      hexBytes(
        '0E 00 00 00 02 00 00 07 02 00 00 00 00 00 '
        '${hexString([used & 0xFF, used >> 8, 0, 0])}',
      ),
    );
    final last = await frame();
    expect(last.sublist(0, 3), [0x02, 0x02, 0x00]);
    expect(last.length - 3, 109);
  });

  test('a device skipping the LIMITS control frame', () async {
    await start(const MuxOptions(keepAliveInterval: null));
    // Bytes may arrive split anywhere.
    for (final byte in hexBytes('$preamble $open $request')) {
      socket.add([byte]);
    }
    expect(await read(8), preamble);
    var frame = await readFrame();
    // LIMITS on the control channel: 02 00 00 | 04 | u32 | u32 | u32.
    expect(frame, startsWith('10 00 00 00 02 00 00 04'));
    frame = await readFrame();
    expect(frame, reply);
    await socket.close();
    expect(await input.hasNext, isFalse);
  });
}
