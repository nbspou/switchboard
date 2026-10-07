/*
Polyverse Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Authors:
  Jan Boon <jan.boon@kaetemi.be>
  Claude Opus 5.5 <noreply@anthropic.com>
*/

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:switchboard/switchboard.dart';
import 'package:test/test.dart';

const options = MuxOptions(
  goAwayGrace: Duration(milliseconds: 100),
  keepAliveInterval: null,
);

Uint8List bytes(String text) => Uint8List.fromList(utf8.encode(text));

String text(TalkMessage message) => utf8.decode(message.payload);

Matcher throwsCode(Iterable<StatusCode> codes) => throwsA(
  isA<SwitchboardException>().having((e) => e.code, 'code', isIn(codes)),
);

/// A small mesh without a naming service: node A runs `alpha/1` and
/// `beta/2` and listens on TCP and WebSocket, node B runs `gamma/3` and
/// listens on WebSocket. Every node, and a client node C, resolves through
/// the same static table. Calls cross between the nodes over both
/// transports.
void main() {
  final alpha = Name('alpha');
  final beta = Name('beta');
  final gamma = Name('gamma');
  late StaticResolver table;
  late Switchboard a;
  late Switchboard b;
  late Switchboard c;
  late Uri aTcp;
  late Uri aWs;
  late Uri bWs;

  /// Serves Talk requests on every channel of a service with [handle],
  /// which returns the reply payload.
  ChannelHandler serve(Future<String> Function(TalkMessage m) handle) =>
      (incoming) {
        incoming.talk().messages.listen((message) {
          handle(message).then(
            (reply) => message.reply(bytes(reply)),
            onError: (Object e) => message.replyAbort(
              e is SwitchboardException
                  ? e.status
                  : Status.of(StatusCode.internal, '$e'),
            ),
          );
        });
      };

  /// One request on a fresh channel from [from] to [to].
  Future<String> call(
    Switchboard from,
    ServiceAddress to,
    String procedure, [
    String payload = '',
  ]) async {
    final talk = await from.openTalk(to);
    try {
      return text(await talk.request(procedure, bytes(payload)));
    } finally {
      await talk.close();
    }
  }

  setUp(() async {
    table = StaticResolver();
    addTearDown(table.close);
    a = Switchboard(resolver: table, muxOptions: options);
    b = Switchboard(resolver: table, muxOptions: options);
    c = Switchboard(resolver: table, muxOptions: options);
    addTearDown(a.close);
    addTearDown(b.close);
    addTearDown(c.close);
    aTcp = await a.listenTcp(InternetAddress.loopbackIPv4, 0);
    aWs = await a.listenWebSocket(InternetAddress.loopbackIPv4, 0);
    bWs = await b.listenWebSocket('127.0.0.1', 0, path: '/mesh');
    table
      ..add(ServiceRecord(ServiceAddress(alpha, 1), endpoints: [aTcp]))
      ..add(ServiceRecord(ServiceAddress(beta, 2), endpoints: [aWs]))
      ..add(ServiceRecord(ServiceAddress(gamma, 3), endpoints: [bWs]));

    a.registerService(
      alpha,
      serve((m) async {
        switch (m.procedureName) {
          case 'UPPER':
            return text(m).toUpperCase();
          case 'CHAIN':
            return 'alpha>${await call(a, ServiceAddress(gamma), 'CHAIN')}';
        }
        throw SwitchboardException.of(StatusCode.unimplemented);
      }),
      instance: 1,
    );
    a.registerService(
      beta,
      serve((m) async => 'beta(${text(m)})'),
      instance: 2,
    );
    b.registerService(gamma, (incoming) {
      incoming.talk().messages.listen((m) {
        switch (m.procedureName) {
          case 'CHAIN':
            call(b, ServiceAddress(beta), 'NAME', 'from gamma').then(
              (r) => m.reply(bytes('gamma>$r')),
              onError: (Object e) =>
                  m.replyAbort(Status.of(StatusCode.internal, '$e')),
            );
          case 'ALPHA':
            call(b, ServiceAddress(alpha), 'UPPER', text(m)).then(
              (r) => m.reply(bytes(r)),
              onError: (Object e) =>
                  m.replyAbort(Status.of(StatusCode.internal, '$e')),
            );
          case 'TICK':
            // Items until cancelled or the channel goes away.
            var n = 0;
            final timer = Timer.periodic(const Duration(milliseconds: 5), (t) {
              if (!m.canReply) {
                t.cancel();
                return;
              }
              m.replyItem(bytes('${n++}'));
            });
            unawaited(m.onCancel.then((_) => timer.cancel()));
            unawaited(incoming.channel.done.then((_) => timer.cancel()));
          default:
            m.replyAbort(Status.of(StatusCode.unimplemented));
        }
      });
    }, instance: 3);
  });

  test('cross calls over TCP and WebSocket', () async {
    expect(await call(c, ServiceAddress(alpha), 'UPPER', 'hi'), 'HI');
    expect(await call(c, ServiceAddress(beta, 2), 'X', 'c'), 'beta(c)');
    expect(await call(a, ServiceAddress(beta), 'X', 'self'), 'beta(self)');
    // B reaches alpha on A over TCP, from inside a request from C.
    expect(await call(c, ServiceAddress(gamma), 'ALPHA', 'up'), 'UP');
    // Each node pooled one connection per endpoint it used.
    final again = await c.openTalk(ServiceAddress(alpha));
    expect(again.raw, isA<MuxChannel>());
    expect((again.raw as MuxChannel).connection, same(await c.connect(aTcp)));
    await again.close();
  });

  test('a request chained across nodes', () async {
    expect(
      await call(c, ServiceAddress(alpha), 'CHAIN'),
      'alpha>gamma>beta(from gamma)',
    );
    // Concurrent chains share the pooled connections.
    final results = await Future.wait([
      for (var i = 0; i < 20; i++) call(c, ServiceAddress(alpha), 'CHAIN'),
    ]);
    expect(results, everyElement('alpha>gamma>beta(from gamma)'));
  });

  test('graceful shutdown of a node during a stream', () async {
    final talk = await c.openTalk(ServiceAddress(gamma));
    final stream = talk.streamRequest('TICK', Uint8List(0));
    final items = <String>[];
    final ended = Completer<Object>();
    stream.items.listen(
      (m) => items.add(text(m)),
      onError: (Object e) {
        if (!ended.isCompleted) {
          ended.complete(e);
        }
      },
      onDone: () {
        if (!ended.isCompleted) {
          ended.complete('done without error');
        }
      },
    );
    stream.done.ignore();
    while (items.length < 3) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    final watch = Stopwatch()..start();
    await b.close().timeout(const Duration(seconds: 5));
    final error = await ended.future.timeout(const Duration(seconds: 5));
    expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
    expect(
      error,
      isA<SwitchboardException>().having(
        (e) => e.code,
        'code',
        isIn([StatusCode.goingAway, StatusCode.unavailable]),
      ),
    );
    expect(items, containsAllInOrder(['0', '1', '2']));
    expect(await talk.done.timeout(const Duration(seconds: 5)), isA<Status>());
    // gamma is gone; the rest of the mesh still works.
    await expectLater(
      c.openTalk(ServiceAddress(gamma)),
      throwsCode([StatusCode.unavailable]),
    );
    expect(await call(c, ServiceAddress(alpha), 'UPPER', 'still'), 'STILL');
  });
}
