/*
Polyverse Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Authors:
  Jan Boon <jan.boon@kaetemi.be>
  Claude Opus 5.5 <noreply@anthropic.com>
*/

// The reconnecting client against an in-memory endpoint, driven with
// fake_async so that the backoff schedule is exact and the tests are fast.
// No `dart:io`: this file also runs on Node.js (`dart test -P node`).

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:switchboard/core.dart';
import 'package:test/test.dart';

/// Keep-alive off so that the fake clock only sees the timers under test.
///
/// `keepAliveTimeout` also bounds how long `MuxConnection.close` waits for
/// the transport. Under fake_async that wait always runs out: cancelling
/// the subscription of a finished stream returns a future of the root zone,
/// whose microtasks the fake clock does not run. Keep it short.
const quiet = MuxOptions(
  keepAliveInterval: null,
  keepAliveTimeout: Duration(milliseconds: 100),
  goAwayGrace: Duration(seconds: 2),
);

Duration ms(int n) => Duration(milliseconds: n);

Uint8List bytes(List<int> values) => Uint8List.fromList(values);

final events = ChannelAddress(type: Name('events'));
final feed = ChannelAddress(type: Name('feed'));

/// The endpoint side: every transport the connector creates is accepted by
/// a mux connection here, unless the endpoint is told to refuse.
class FakeEndpoint {
  FakeEndpoint(this.async, {this.options = quiet});

  final FakeAsync async;

  /// Mux configuration of the endpoint's connections.
  final MuxOptions options;
  final List<MuxConnection> connections = [];
  final List<IncomingChannel> channels = [];

  /// Fake time of every connector call.
  final List<Duration> attempts = [];

  /// The next this many connector calls fail.
  int failures = 0;

  /// Every connector call fails.
  bool refuseAll = false;

  /// Called with each channel the client opens.
  void Function(IncomingChannel channel)? onChannel;

  Future<StreamChannel<Uint8List>> connect() async {
    attempts.add(async.elapsed);
    if (refuseAll || failures > 0) {
      if (failures > 0) {
        failures--;
      }
      throw SwitchboardException.of(StatusCode.unavailable, 'refused');
    }
    return accept();
  }

  StreamChannel<Uint8List> accept() {
    final (client, server) = MemoryTransport.pair();
    final connection = MuxConnection(
      server,
      isInitiator: false,
      options: options,
    );
    connections.add(connection);
    connection.incoming.listen((channel) {
      final incoming = IncomingChannel(channel);
      channels.add(incoming);
      onChannel?.call(incoming);
    });
    return client;
  }

  MuxConnection get last => connections.last;

  /// The channels the client opened on [connection].
  List<IncomingChannel> on(MuxConnection connection) => [
    for (final channel in channels)
      if (identical(channel.connection, connection)) channel,
  ];

  /// Seconds since the start of every connector call, for readable
  /// expectations.
  List<double> get attemptSeconds => [
    for (final t in attempts) t.inMicroseconds / 1e6,
  ];
}

ReconnectingClient clientFor(
  FakeEndpoint endpoint, {
  Duration initialBackoff = const Duration(milliseconds: 500),
  Duration maxBackoff = const Duration(seconds: 30),
  double jitter = 0,
  Duration connectTimeout = const Duration(seconds: 10),
  Uint8List? defaultPayload,
  bool autoStart = true,
  Random? random,
  TransportConnector? connect,
}) => ReconnectingClient(
  connect ?? endpoint.connect,
  muxOptions: quiet,
  initialBackoff: initialBackoff,
  maxBackoff: maxBackoff,
  jitter: jitter,
  connectTimeout: connectTimeout,
  defaultPayload: defaultPayload,
  autoStart: autoStart,
  random: random,
);

/// Synchronously observable outcome of a future.
class Outcome<T> {
  Outcome(Future<T> future) {
    future.then(
      (v) {
        value = v;
        isDone = true;
      },
      onError: (Object e) {
        error = e;
        isDone = true;
      },
    );
  }

  T? value;
  Object? error;
  bool isDone = false;
}

Matcher isStatus(StatusCode code) =>
    isA<Status>().having((s) => s.known, 'known', code);

Matcher isSwitchboardError(StatusCode code) =>
    isA<SwitchboardException>().having((e) => e.code, 'code', code);

/// Closes [client] and checks that it leaves nothing behind. The channels
/// the application opened delay it by up to the GOAWAY grace.
void closeAndCheck(
  FakeAsync async,
  ReconnectingClient client, {
  bool appChannels = false,
}) {
  final closed = Outcome(client.close());
  async.elapse(
    appChannels ? quiet.goAwayGrace + quiet.keepAliveTimeout : ms(100),
  );
  expect(closed.isDone, isTrue, reason: 'close() completed');
  expect(async.pendingTimers, isEmpty, reason: 'no timers after close()');
}

void main() {
  group('connecting', () {
    test('connects and reports its states', () {
      fakeAsync((async) {
        final endpoint = FakeEndpoint(async);
        final client = clientFor(endpoint);
        expect(client.state.phase, ClientPhase.connecting);
        expect(client.state.attempt, 1);
        expect(client.isRunning, isTrue);
        final states = <ClientState>[];
        client.states.listen(states.add);
        final connected = Outcome(client.connected);
        async.flushMicrotasks();
        expect(states.map((s) => s.phase), [
          ClientPhase.connecting,
          ClientPhase.connected,
        ]);
        expect(states.last.attempt, 1);
        expect(states.last.lastStatus, isNull);
        expect(states.last.since, isNotNull);
        expect(client.state.isConnected, isTrue);
        expect(client.connection, isNotNull);
        expect(connected.value, same(client.connection));
        expect(endpoint.connections, hasLength(1));
        expect(client.connection!.isInitiator, isTrue);

        // A later listener first receives the current state.
        final late = <ClientPhase>[];
        client.states.listen((s) => late.add(s.phase));
        async.flushMicrotasks();
        expect(late, [ClientPhase.connected]);

        unawaited(endpoint.last.close());
        async.flushMicrotasks();
        expect(client.state.phase, ClientPhase.disconnected);
        expect(client.state.lastStatus, isStatus(StatusCode.connectionLost));
        expect(client.state.attempt, 0);
        expect(client.connection, isNull);
        // A new future for the next connection.
        final next = Outcome(client.connected);
        async.flushMicrotasks();
        expect(next.isDone, isFalse);
        async.elapse(ms(500));
        expect(next.value, same(client.connection));
        expect(next.value, isNot(same(connected.value)));
        expect(states.map((s) => s.phase), [
          ClientPhase.connecting,
          ClientPhase.connected,
          ClientPhase.disconnected,
          ClientPhase.connecting,
          ClientPhase.connected,
        ]);
        // The status of the previous loss is kept while connected.
        expect(states.last.lastStatus, isStatus(StatusCode.connectionLost));

        final ended = Outcome(client.states.toList());
        closeAndCheck(async, client);
        expect(ended.isDone, isTrue, reason: 'states ends after close()');
        expect(client.state.phase, ClientPhase.disconnected);
        expect(client.state.lastStatus, isStatus(StatusCode.cancelled));
      });
    });

    test('autoStart false waits for start()', () {
      fakeAsync((async) {
        final endpoint = FakeEndpoint(async);
        final client = clientFor(endpoint, autoStart: false);
        async.elapse(const Duration(seconds: 5));
        expect(endpoint.attempts, isEmpty);
        expect(client.state.phase, ClientPhase.disconnected);
        expect(client.isRunning, isFalse);
        client.start();
        async.flushMicrotasks();
        expect(endpoint.connections, hasLength(1));
        expect(client.state.phase, ClientPhase.connected);
        closeAndCheck(async, client);
      });
    });

    test('rejects invalid backoff settings', () {
      var calls = 0;
      Future<StreamChannel<Uint8List>> connect() {
        calls++;
        return Future.error(StateError('not called'));
      }

      expect(
        () => ReconnectingClient(connect, initialBackoff: ms(-1)),
        throwsArgumentError,
      );
      expect(
        () => ReconnectingClient(
          connect,
          initialBackoff: ms(10),
          maxBackoff: ms(5),
        ),
        throwsArgumentError,
      );
      expect(
        () => ReconnectingClient(connect, backoffFactor: 0.5),
        throwsArgumentError,
      );
      expect(
        () => ReconnectingClient(connect, jitter: 1.5),
        throwsArgumentError,
      );
      expect(calls, 0);
    });
  });

  group('backoff', () {
    test('doubles from the initial delay up to the cap', () {
      fakeAsync((async) {
        final endpoint = FakeEndpoint(async)..refuseAll = true;
        final client = clientFor(endpoint, maxBackoff: ms(4000));
        final states = <ClientState>[];
        client.states.listen(states.add);
        async.elapse(const Duration(seconds: 20));
        expect(endpoint.attemptSeconds, [
          0,
          0.5,
          1.5,
          3.5,
          7.5,
          11.5,
          15.5,
          19.5,
        ]);
        final failed = [
          for (final s in states)
            if (s.phase == ClientPhase.disconnected) s,
        ];
        expect(failed.map((s) => s.attempt), [1, 2, 3, 4, 5, 6, 7, 8]);
        expect(
          failed.map((s) => s.lastStatus?.known),
          everyElement(StatusCode.unavailable),
        );
        expect(
          [
            for (final s in states)
              if (s.phase == ClientPhase.connecting) s.attempt,
          ],
          [1, 2, 3, 4, 5, 6, 7, 8],
        );
        closeAndCheck(async, client);
      });
    });

    test('jitter stays within its bounds', () {
      fakeAsync((async) {
        final endpoint = FakeEndpoint(async)..refuseAll = true;
        final client = clientFor(
          endpoint,
          maxBackoff: ms(4000),
          jitter: 0.2,
          random: Random(7),
        );
        async.elapse(const Duration(seconds: 120));
        final times = endpoint.attempts;
        expect(times.length, greaterThan(20));
        var exact = 0;
        for (var i = 1; i < times.length; i++) {
          final gap = (times[i] - times[i - 1]).inMicroseconds;
          final base = min(500000 * pow(2, i - 1), 4000000);
          expect(gap, greaterThanOrEqualTo((base * 0.8).floor()));
          expect(gap, lessThanOrEqualTo((base * 1.2).ceil()));
          if (gap == base) {
            exact++;
          }
        }
        expect(exact, lessThan(times.length ~/ 2), reason: 'jitter applied');
        closeAndCheck(async, client);
      });
    });

    test('resets after a connection that outlived the cap', () {
      fakeAsync((async) {
        final endpoint = FakeEndpoint(async)..failures = 3;
        final client = clientFor(endpoint, maxBackoff: ms(8000));
        // Fails at 0, 0.5 and 1.5 s; connects at 3.5 s.
        async.elapse(ms(3500));
        expect(endpoint.connections, hasLength(1));
        // A short-lived connection keeps the sequence going: 4 s.
        async.elapse(ms(1000));
        unawaited(endpoint.last.close());
        async.elapse(ms(3999));
        expect(endpoint.connections, hasLength(1));
        async.elapse(ms(1));
        expect(endpoint.connections, hasLength(2));
        // A connection older than maxBackoff resets it: 0.5 s.
        async.elapse(ms(10000));
        unawaited(endpoint.last.close());
        async.elapse(ms(500));
        expect(endpoint.attemptSeconds, [0, 0.5, 1.5, 3.5, 8.5, 19.0]);
        expect(endpoint.connections, hasLength(3));
        closeAndCheck(async, client);
      });
    });

    test('a throwing, failing or hanging connector is retried', () {
      fakeAsync((async) {
        final endpoint = FakeEndpoint(async);
        final late = Completer<StreamChannel<Uint8List>>();
        var calls = 0;
        Future<StreamChannel<Uint8List>> connect() {
          calls++;
          switch (calls) {
            case 1:
              throw StateError('synchronous failure');
            case 2:
              return Future.error(const FormatException('asynchronous'));
            case 3:
              return late.future;
            default:
              return Future.value(endpoint.accept());
          }
        }

        final client = clientFor(
          endpoint,
          connect: connect,
          connectTimeout: ms(2000),
        );
        final statuses = <Status?>[];
        client.states
            .where((s) => s.phase == ClientPhase.disconnected)
            .listen((s) => statuses.add(s.lastStatus));
        async.flushMicrotasks();
        expect(calls, 1);
        expect(client.state.phase, ClientPhase.disconnected);
        async.elapse(ms(500));
        expect(calls, 2);
        async.elapse(ms(1000));
        expect(calls, 3);
        expect(client.state.phase, ClientPhase.connecting);
        // The third attempt times out after 2 s; the fourth comes 2 s later.
        async.elapse(ms(2000));
        expect(client.state.phase, ClientPhase.disconnected);
        expect(client.state.attempt, 3);
        expect(
          statuses.map((s) => s?.known),
          everyElement(StatusCode.unavailable),
        );
        expect(statuses, hasLength(3));
        // The transport of the timed out attempt arrives late: closed.
        final stray = endpoint.accept();
        late.complete(stray);
        async.flushMicrotasks();
        final strayDone = Outcome(endpoint.last.done);
        async.flushMicrotasks();
        expect(strayDone.isDone, isTrue);
        async.elapse(ms(2000));
        expect(calls, 4);
        expect(client.state.phase, ClientPhase.connected);
        expect(client.state.attempt, 4);
        closeAndCheck(async, client);
      });
    });
  });

  group('openChannel', () {
    test('waits for the connection, with defaultPayload attached', () {
      fakeAsync((async) {
        final endpoint = FakeEndpoint(async);
        final client = clientFor(
          endpoint,
          autoStart: false,
          defaultPayload: bytes([0xC0, 0xDE]),
        );
        final first = Outcome(client.openChannel(events));
        final own = Outcome(
          client.openChannel(feed.copyWith(payload: bytes([1]))),
        );
        async.elapse(const Duration(seconds: 5));
        expect(first.isDone, isFalse);
        client.start();
        async.flushMicrotasks();
        expect(first.value, isA<MuxChannel>());
        expect(own.value, isA<MuxChannel>());
        expect(endpoint.channels, hasLength(2));
        expect(endpoint.channels[0].address.type, Name('events'));
        expect(endpoint.channels[0].address.payload, [0xC0, 0xDE]);
        expect(endpoint.channels[1].address.type, Name('feed'));
        expect(endpoint.channels[1].address.payload, [1]);
        // Connected: opens at once, with the current default payload.
        client.defaultPayload = bytes([9]);
        final now = Outcome(client.openChannel(events));
        async.flushMicrotasks();
        expect(now.value, isA<MuxChannel>());
        expect(endpoint.channels.last.address.payload, [9]);
        closeAndCheck(async, client, appChannels: true);
      });
    });

    test('fails with UNAVAILABLE after openTimeout, CANCELLED on close', () {
      fakeAsync((async) {
        final endpoint = FakeEndpoint(async)..refuseAll = true;
        final client = clientFor(endpoint);
        final timed = Outcome(
          client.openChannel(events, openTimeout: ms(3000)),
        );
        final immediate = Outcome(
          client.openChannel(events, openTimeout: Duration.zero),
        );
        final waiting = Outcome(client.openChannel(events));
        final connected = Outcome(client.connected);
        async.flushMicrotasks();
        expect(immediate.error, isSwitchboardError(StatusCode.unavailable));
        async.elapse(ms(2999));
        expect(timed.isDone, isFalse);
        async.elapse(ms(1));
        expect(timed.error, isSwitchboardError(StatusCode.unavailable));
        expect(waiting.isDone, isFalse);
        closeAndCheck(async, client);
        expect(waiting.error, isSwitchboardError(StatusCode.cancelled));
        expect(connected.error, isSwitchboardError(StatusCode.cancelled));
        final after = Outcome(client.openChannel(events));
        async.flushMicrotasks();
        expect(after.error, isSwitchboardError(StatusCode.failedPrecondition));
        expect(
          () => client.openPersistent(events, (_) {}),
          throwsA(isSwitchboardError(StatusCode.failedPrecondition)),
        );
      });
    });

    test('a Talk request through openTalk', () {
      fakeAsync((async) {
        final endpoint = FakeEndpoint(async)
          ..onChannel = (incoming) {
            incoming.talk().messages.listen((message) {
              message.reply(bytes([...message.payload, 2]), procedure: 'PONG');
            });
          };
        final client = clientFor(endpoint);
        final reply = Outcome(
          client
              .openTalk(events)
              .then((talk) => talk.request('PING', bytes([1]))),
        );
        async.flushMicrotasks();
        expect(reply.value?.procedureName, 'PONG');
        expect(reply.value?.payload, [1, 2]);
        closeAndCheck(async, client, appChannels: true);
      });
    });
  });

  group('persistent channels', () {
    test('re-opened after the endpoint drops the connection', () {
      fakeAsync((async) {
        final endpoint = FakeEndpoint(async);
        final client = clientFor(endpoint);
        final opened = <MuxChannel>[];
        final closed = <Status>[];
        final phaseAtClose = <ClientPhase>[];
        final persistent = client.openPersistent(
          events,
          opened.add,
          onClosed: (status) {
            closed.add(status);
            phaseAtClose.add(client.state.phase);
          },
        );
        // Never opened synchronously.
        expect(opened, isEmpty);
        final announced = <MuxChannel>[];
        persistent.opened.listen(announced.add);
        async.flushMicrotasks();
        expect(opened, hasLength(1));
        expect(persistent.current, same(opened.single));
        expect(announced, opened);
        expect(endpoint.channels.single.address.type, Name('events'));

        unawaited(endpoint.last.close());
        async.flushMicrotasks();
        expect(closed, [isStatus(StatusCode.connectionLost)]);
        // The disconnect is reported before the channels end.
        expect(phaseAtClose, [ClientPhase.disconnected]);
        expect(persistent.current, isNull);
        expect(persistent.isClosed, isFalse);

        async.elapse(ms(500));
        expect(endpoint.connections, hasLength(2));
        expect(opened, hasLength(2));
        expect(persistent.current, same(opened.last));
        expect(opened.last.connection, same(client.connection));
        expect(endpoint.on(endpoint.last), hasLength(1));
        expect(announced, opened);

        // Data flows on the new channel.
        final received = <List<int>>[];
        opened.last.stream.listen(received.add);
        endpoint.on(endpoint.last).single.channel.send(bytes([5]));
        async.flushMicrotasks();
        expect(received, [
          [5],
        ]);

        final done = Outcome(persistent.close());
        async.flushMicrotasks();
        expect(done.isDone, isTrue);
        expect(closed, hasLength(2));
        expect(closed.last, isStatus(StatusCode.ok));
        expect(persistent.isClosed, isTrue);
        expect(
          endpoint.on(endpoint.last).single.channel.state,
          MuxChannelState.closed,
        );
        closeAndCheck(async, client);
        expect(opened, hasLength(2));
      });
    });

    test('closed by the endpoint: re-opened after the backoff', () {
      fakeAsync((async) {
        final endpoint = FakeEndpoint(async);
        final client = clientFor(endpoint, maxBackoff: ms(4000));
        final opened = <MuxChannel>[];
        final closed = <Status>[];
        final persistent = client.openPersistent(
          events,
          opened.add,
          onClosed: closed.add,
        );
        async.flushMicrotasks();
        expect(opened, hasLength(1));

        Future<void> endpointCloses(StatusCode code) =>
            endpoint.channels.last.reject(Status.of(code, 'test'));

        unawaited(endpointCloses(StatusCode.unavailable));
        async.flushMicrotasks();
        expect(closed, [isStatus(StatusCode.unavailable)]);
        expect(persistent.current, isNull);
        async.elapse(ms(499));
        expect(opened, hasLength(1));
        async.elapse(ms(1));
        expect(opened, hasLength(2));
        // Same connection; the next delay doubles.
        expect(endpoint.connections, hasLength(1));
        unawaited(endpointCloses(StatusCode.internal));
        async.elapse(ms(999));
        expect(opened, hasLength(2));
        async.elapse(ms(1));
        expect(opened, hasLength(3));
        // A channel that outlived maxBackoff resets the sequence.
        async.elapse(ms(5000));
        unawaited(endpointCloses(StatusCode.resourceExhausted));
        async.elapse(ms(500));
        expect(opened, hasLength(4));
        // The application closing the channel itself also re-opens it.
        unawaited(opened.last.close());
        async.elapse(ms(1000));
        expect(opened, hasLength(5));
        expect(closed, hasLength(4));
        expect(closed.last, isStatus(StatusCode.ok));
        expect(endpoint.connections, hasLength(1));
        closeAndCheck(async, client);
      });
    });

    for (final code in [
      StatusCode.permissionDenied,
      StatusCode.unauthenticated,
      StatusCode.unimplemented,
      StatusCode.notFound,
    ]) {
      test('closed by the endpoint with ${code.name}: stays closed', () {
        fakeAsync((async) {
          final endpoint = FakeEndpoint(async);
          final client = clientFor(endpoint);
          final opened = <MuxChannel>[];
          final closed = <Status>[];
          final closedFlag = <bool>[];
          late final PersistentChannel persistent;
          persistent = client.openPersistent(
            events,
            opened.add,
            onClosed: (status) {
              closed.add(status);
              closedFlag.add(persistent.isClosed);
            },
          );
          final done = Outcome(persistent.done);
          final announced = Outcome(persistent.opened.toList());
          async.flushMicrotasks();
          unawaited(endpoint.channels.single.reject(Status.of(code)));
          async.elapse(const Duration(seconds: 60));
          expect(opened, hasLength(1));
          expect(closed, [isStatus(code)]);
          expect(closedFlag, [isTrue]);
          expect(persistent.isClosed, isTrue);
          expect(done.value, isStatus(code));
          expect(announced.value, hasLength(1));
          // Not re-opened on a new connection either.
          unawaited(endpoint.last.close());
          async.elapse(const Duration(seconds: 2));
          expect(endpoint.connections, hasLength(2));
          expect(opened, hasLength(1));
          expect(endpoint.channels, hasLength(1));
          closeAndCheck(async, client);
        });
      });
    }

    test('onOpen exceptions are logged and do not affect others', () {
      fakeAsync((async) {
        final endpoint = FakeEndpoint(async);
        final client = clientFor(endpoint);
        final opened = <String>[];
        client.openPersistent(events, (_) {
          opened.add('throws');
          throw StateError('boom');
        });
        client.openPersistent(events, (_) async {
          opened.add('fails');
          throw StateError('boom');
        });
        client.openPersistent(feed, (_) => opened.add('fine'));
        async.flushMicrotasks();
        expect(opened, ['throws', 'fails', 'fine']);
        unawaited(endpoint.last.close());
        async.elapse(ms(500));
        expect(opened, ['throws', 'fails', 'fine', 'throws', 'fails', 'fine']);
        expect(endpoint.on(endpoint.last), hasLength(3));
        closeAndCheck(async, client);
      });
    });

    test('PersistentTalk re-sends its subscription on every connection', () {
      fakeAsync((async) {
        final endpoint = FakeEndpoint(async);
        var subscriptions = 0;
        endpoint.onChannel = (incoming) {
          final talk = incoming.talk();
          talk.messages.listen((message) {
            if (message.procedureName == 'SUB') {
              subscriptions++;
              message.reply(Uint8List(0));
              talk.send('EVENT', bytes([subscriptions]));
            }
          });
        };
        final client = clientFor(endpoint);
        final received = <int>[];
        final replies = <String>[];
        final closed = <Status>[];
        final persistent = client.openPersistentTalk(feed, (talk) async {
          talk.messages.listen((m) => received.add(m.payload.single));
          final reply = await talk.request('SUB', bytes([1]));
          replies.add('subscribed ${reply.payload.length}');
        }, onClosed: closed.add);
        async.flushMicrotasks();
        expect(subscriptions, 1);
        expect(replies, ['subscribed 0']);
        expect(received, [1]);
        expect(persistent.current, isA<TalkChannel>());

        unawaited(endpoint.last.close());
        async.flushMicrotasks();
        expect(closed, [isStatus(StatusCode.connectionLost)]);
        async.elapse(ms(500));
        expect(subscriptions, 2);
        expect(replies, ['subscribed 0', 'subscribed 0']);
        expect(received, [1, 2]);

        // A channel abort with a terminal status ends it.
        endpoint.channels.last.talk().abort(
          Status.of(StatusCode.permissionDenied),
        );
        async.elapse(const Duration(seconds: 10));
        expect(persistent.isClosed, isTrue);
        expect(closed.last, isStatus(StatusCode.permissionDenied));
        expect(subscriptions, 2);
        closeAndCheck(async, client);
      });
    });

    test('opened while connected, and on the next connection', () {
      fakeAsync((async) {
        final endpoint = FakeEndpoint(async)..failures = 1;
        final client = clientFor(endpoint, defaultPayload: bytes([7]));
        final opened = <MuxChannel>[];
        client.openPersistent(events, opened.add);
        async.flushMicrotasks();
        expect(opened, isEmpty);
        async.elapse(ms(500));
        expect(opened, hasLength(1));
        expect(endpoint.channels.single.address.payload, [7]);
        // Created while connected: opened in a microtask.
        client.defaultPayload = bytes([8]);
        client.openPersistent(feed, opened.add);
        expect(opened, hasLength(1));
        async.flushMicrotasks();
        expect(opened, hasLength(2));
        expect(endpoint.channels.last.address.payload, [8]);
        // Re-opened with the payload current at the time.
        unawaited(endpoint.last.close());
        async.elapse(ms(1000));
        expect(opened, hasLength(4));
        expect(
          endpoint.on(endpoint.last).map((c) => c.address.payload.single),
          [8, 8],
        );
        closeAndCheck(async, client);
      });
    });
  });

  group('stop and close', () {
    test('stop() sends GOAWAY and stops reconnecting; start() resumes', () {
      fakeAsync((async) {
        final endpoint = FakeEndpoint(async);
        final client = clientFor(endpoint);
        final opened = <MuxChannel>[];
        final closed = <Status>[];
        final persistent = client.openPersistent(
          events,
          opened.add,
          onClosed: closed.add,
        );
        async.flushMicrotasks();
        final server = endpoint.last;
        final serverDone = Outcome(server.done);
        client.stop();
        client.stop();
        expect(client.isRunning, isFalse);
        expect(client.state.phase, ClientPhase.disconnected);
        expect(client.state.lastStatus, isStatus(StatusCode.cancelled));
        expect(client.connection, isNull);
        async.flushMicrotasks();
        expect(server.peerGoingAway, isTrue);
        // The persistent channel closed with GOING_AWAY, so the connection
        // went idle and closed without waiting for the grace period.
        expect(closed, [isStatus(StatusCode.goingAway)]);
        expect(endpoint.channels.single.channel.state, MuxChannelState.closed);
        expect(serverDone.value, isStatus(StatusCode.goingAway));
        expect(persistent.isClosed, isFalse);
        async.elapse(const Duration(minutes: 5));
        expect(endpoint.attempts, hasLength(1));
        expect(async.pendingTimers, isEmpty);

        client.start();
        async.flushMicrotasks();
        expect(endpoint.connections, hasLength(2));
        expect(opened, hasLength(2));
        closeAndCheck(async, client);
        expect(closed, hasLength(2));
        expect(persistent.isClosed, isTrue);
      });
    });

    test('stop() during a connection attempt discards its transport', () {
      fakeAsync((async) {
        final endpoint = FakeEndpoint(async);
        final pending = Completer<StreamChannel<Uint8List>>();
        final client = clientFor(endpoint, connect: () => pending.future);
        client.stop();
        expect(async.pendingTimers, isEmpty);
        pending.complete(endpoint.accept());
        final serverDone = Outcome(endpoint.last.done);
        async.flushMicrotasks();
        expect(serverDone.isDone, isTrue);
        expect(client.connection, isNull);
        closeAndCheck(async, client);
      });
    });

    test('close() waits for the application channels within the grace', () {
      fakeAsync((async) {
        final endpoint = FakeEndpoint(async);
        final client = clientFor(endpoint);
        final own = Outcome(client.openChannel(events));
        async.flushMicrotasks();
        expect(own.value, isA<MuxChannel>());
        final closed = Outcome(client.close());
        async.elapse(ms(1000));
        expect(closed.isDone, isFalse);
        // The grace (2 s here) bounds it.
        async.elapse(ms(1200));
        expect(closed.isDone, isTrue);
        final ownDone = Outcome(own.value!.done);
        async.flushMicrotasks();
        expect(ownDone.value, isStatus(StatusCode.goingAway));
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('close() while waiting for the next attempt', () {
      fakeAsync((async) {
        final endpoint = FakeEndpoint(async)..refuseAll = true;
        final client = clientFor(endpoint);
        final persistent = client.openPersistent(events, (_) {});
        async.elapse(ms(700));
        expect(endpoint.attempts, hasLength(2));
        closeAndCheck(async, client);
        expect(persistent.isClosed, isTrue);
        expect(client.isClosed, isTrue);
        client.start();
        async.elapse(const Duration(seconds: 5));
        expect(endpoint.attempts, hasLength(2));
      });
    });
  });

  group('GOAWAY from the endpoint', () {
    test('persistent channels move to a new connection at once', () {
      fakeAsync((async) {
        final endpoint = FakeEndpoint(async);
        var subscriptions = 0;
        endpoint.onChannel = (incoming) {
          if (incoming.address.type != Name('feed')) {
            return;
          }
          final talk = incoming.talk();
          talk.messages.listen((message) {
            subscriptions++;
            message.reply(Uint8List(0));
          });
        };
        final client = clientFor(endpoint);
        final opened = <MuxChannel>[];
        final closed = <Status>[];
        final persistent = client.openPersistent(
          events,
          opened.add,
          onClosed: closed.add,
        );
        final talkClosed = <Status>[];
        final talk = client.openPersistentTalk(
          feed,
          (talk) => talk.request('SUB', Uint8List(0)),
          onClosed: talkClosed.add,
        );
        async.elapse(ms(1000));
        expect(subscriptions, 1);
        final first = client.connection!;
        final server = endpoint.last;
        final states = <ClientState>[];
        client.states.skip(1).listen(states.add);
        // What the client is doing when the old connection ends.
        ClientState? stateAtOldEnd;
        MuxConnection? connectionAtOldEnd;
        final firstDone = Outcome(
          first.done.then((status) {
            stateAtOldEnd = client.state;
            connectionAtOldEnd = client.connection;
            return status;
          }),
        );
        final serverDone = Outcome(server.done);
        unawaited(server.goAway());
        async.flushMicrotasks();

        // A new attempt at once, reported with the GOAWAY status.
        expect(endpoint.attemptSeconds, [0, 1]);
        expect(states.map((s) => s.phase), [
          ClientPhase.connecting,
          ClientPhase.connected,
        ]);
        expect(
          states.map((s) => s.lastStatus?.known),
          everyElement(StatusCode.goingAway),
        );
        expect(states.map((s) => s.attempt), [1, 1]);
        final second = client.connection!;
        expect(second, isNot(same(first)));
        // The persistent channels were closed with GOING_AWAY, so the old
        // connection went idle and ended, after the new one was up.
        expect(closed, [isStatus(StatusCode.goingAway)]);
        expect(talkClosed, [isStatus(StatusCode.goingAway)]);
        expect(
          endpoint.on(server).map((c) => c.channel.state),
          everyElement(MuxChannelState.closed),
        );
        expect(firstDone.value, isStatus(StatusCode.goingAway));
        expect(stateAtOldEnd?.phase, ClientPhase.connected);
        expect(connectionAtOldEnd, same(second));
        expect(
          serverDone.value,
          isStatus(StatusCode.goingAway),
          reason: 'the endpoint did not wait for its grace',
        );
        // Opened again on the new connection.
        expect(opened, hasLength(2));
        expect(opened.last.connection, same(second));
        expect(persistent.current, same(opened.last));
        expect(talk.current?.isOpen, isTrue);
        expect(subscriptions, 2);
        expect(
          endpoint.on(endpoint.last).map((c) => c.address.type?.toString()),
          unorderedEquals(['events', 'feed']),
        );

        // The end of the old connection causes no second reconnect.
        async.elapse(const Duration(minutes: 5));
        expect(endpoint.attempts, hasLength(2));
        expect(client.connection, same(second));
        expect(states, hasLength(2));
        expect(opened, hasLength(2));
        closeAndCheck(async, client);
      });
    });

    test('on an idle connection: reconnects at once', () {
      fakeAsync((async) {
        final endpoint = FakeEndpoint(async);
        final client = clientFor(endpoint);
        async.flushMicrotasks();
        final first = client.connection!;
        final firstConnected = client.connected;
        final states = <ClientState>[];
        client.states.skip(1).listen(states.add);
        final firstDone = Outcome(first.done);
        unawaited(endpoint.last.goAway());
        async.flushMicrotasks();
        expect(endpoint.attemptSeconds, [0, 0]);
        expect(states.map((s) => s.phase), [
          ClientPhase.connecting,
          ClientPhase.connected,
        ]);
        expect(states.first.lastStatus, isStatus(StatusCode.goingAway));
        expect(client.connection, isNot(same(first)));
        expect(client.connected, isNot(same(firstConnected)));
        expect(firstDone.value, isStatus(StatusCode.goingAway));
        async.elapse(const Duration(minutes: 5));
        expect(endpoint.attempts, hasLength(2));
        expect(client.state.phase, ClientPhase.connected);
        closeAndCheck(async, client);
      });
    });

    test('an application channel carries on over the old connection', () {
      fakeAsync((async) {
        final endpoint = FakeEndpoint(async);
        final client = clientFor(endpoint);
        final own = Outcome(client.openChannel(feed));
        async.flushMicrotasks();
        final first = client.connection!;
        final server = endpoint.last;
        final mine = own.value!;
        final theirs = endpoint.on(server).single.channel;
        final firstDone = Outcome(first.done);
        final serverDone = Outcome(server.done);
        unawaited(server.goAway());
        async.flushMicrotasks();
        // Connected again at once; the old connection stays up for it.
        expect(endpoint.attempts, hasLength(2));
        expect(client.state.phase, ClientPhase.connected);
        expect(client.connection, isNot(same(first)));
        expect(firstDone.isDone, isFalse);
        expect(mine.state, MuxChannelState.open);

        final received = <List<int>>[];
        final sent = <List<int>>[];
        mine.stream.listen(received.add);
        theirs.stream.listen(sent.add);
        async.elapse(ms(1000));
        theirs.send(bytes([1]));
        mine.send(bytes([2]));
        async.flushMicrotasks();
        expect(received, [
          [1],
        ]);
        expect(sent, [
          [2],
        ]);
        // New channels go to the new connection.
        final next = Outcome(client.openChannel(events));
        async.flushMicrotasks();
        expect(next.value?.connection, same(client.connection));

        // Once the application is done, the old connection closes, before
        // the endpoint's grace expires, and nothing reconnects.
        unawaited(mine.close());
        async.flushMicrotasks();
        expect(firstDone.value, isStatus(StatusCode.goingAway));
        expect(serverDone.value, isStatus(StatusCode.goingAway));
        async.elapse(const Duration(minutes: 5));
        expect(endpoint.attempts, hasLength(2));
        expect(client.state.phase, ClientPhase.connected);
        expect(next.value?.state, MuxChannelState.open);
        closeAndCheck(async, client, appChannels: true);
      });
    });

    test('close() bounds an old connection held by the application', () {
      fakeAsync((async) {
        // The endpoint would wait long; close() waits the client's grace.
        final endpoint = FakeEndpoint(
          async,
          options: quiet.copyWith(goAwayGrace: const Duration(minutes: 10)),
        );
        final client = clientFor(endpoint);
        final own = Outcome(client.openChannel(feed));
        async.flushMicrotasks();
        final first = client.connection!;
        unawaited(endpoint.last.goAway());
        async.flushMicrotasks();
        expect(client.connection, isNot(same(first)));
        final firstDone = Outcome(first.done);
        closeAndCheck(async, client, appChannels: true);
        expect(firstDone.value, isStatus(StatusCode.goingAway));
        expect(own.value?.state, MuxChannelState.closed);
      });
    });

    for (final how in ['stop', 'close']) {
      test('arriving during $how(): no reconnect', () {
        fakeAsync((async) {
          final endpoint = FakeEndpoint(async);
          final client = clientFor(endpoint);
          final closed = <Status>[];
          client.openPersistent(events, (_) {}, onClosed: closed.add);
          async.flushMicrotasks();
          final server = endpoint.last;
          final serverDone = Outcome(server.done);
          // Both sides send GOAWAY in the same turn.
          unawaited(server.goAway());
          final Outcome<void>? closing;
          if (how == 'stop') {
            client.stop();
            closing = null;
          } else {
            closing = Outcome(client.close());
          }
          async.flushMicrotasks();
          expect(client.connection, isNull);
          expect(client.state.phase, ClientPhase.disconnected);
          expect(client.state.lastStatus, isStatus(StatusCode.cancelled));
          expect(closed, [isStatus(StatusCode.goingAway)]);
          expect(serverDone.value, isStatus(StatusCode.goingAway));
          async.elapse(const Duration(minutes: 5));
          expect(endpoint.attempts, hasLength(1));
          expect(async.pendingTimers, isEmpty);
          if (closing != null) {
            expect(closing.isDone, isTrue);
            return;
          }
          client.start();
          async.flushMicrotasks();
          expect(endpoint.attempts, hasLength(2));
          expect(client.state.phase, ClientPhase.connected);
          closeAndCheck(async, client);
        });
      });
    }

    test('stop() during the attempt that follows it', () {
      fakeAsync((async) {
        final endpoint = FakeEndpoint(async);
        final pending = Completer<StreamChannel<Uint8List>>();
        var calls = 0;
        final client = clientFor(
          endpoint,
          connect: () {
            calls++;
            return calls == 1 ? endpoint.connect() : pending.future;
          },
        );
        async.flushMicrotasks();
        unawaited(endpoint.last.goAway());
        async.flushMicrotasks();
        expect(calls, 2);
        expect(client.state.phase, ClientPhase.connecting);
        client.stop();
        expect(client.state.phase, ClientPhase.disconnected);
        pending.complete(endpoint.accept());
        final strayDone = Outcome(endpoint.last.done);
        async.elapse(const Duration(minutes: 5));
        expect(strayDone.isDone, isTrue, reason: 'late transport closed');
        expect(calls, 2);
        expect(client.connection, isNull);
        expect(async.pendingTimers, isEmpty);
        closeAndCheck(async, client);
      });
    });

    test('a failed attempt after it backs off as usual', () {
      fakeAsync((async) {
        final endpoint = FakeEndpoint(async);
        final client = clientFor(endpoint);
        final opened = <MuxChannel>[];
        client.openPersistent(events, opened.add);
        async.elapse(ms(1000));
        endpoint.failures = 2;
        unawaited(endpoint.last.goAway());
        async.flushMicrotasks();
        expect(endpoint.attemptSeconds, [0, 1]);
        expect(client.state.phase, ClientPhase.disconnected);
        expect(client.state.lastStatus, isStatus(StatusCode.unavailable));
        expect(client.state.attempt, 1);
        // Waits for the next connection.
        final waiting = Outcome(client.openChannel(feed));
        async.elapse(ms(499));
        expect(endpoint.attempts, hasLength(2));
        async.elapse(ms(1));
        expect(endpoint.attemptSeconds, [0, 1, 1.5]);
        expect(waiting.isDone, isFalse);
        async.elapse(ms(1000));
        expect(endpoint.attemptSeconds, [0, 1, 1.5, 2.5]);
        expect(client.state.phase, ClientPhase.connected);
        expect(client.state.attempt, 3);
        expect(waiting.value?.connection, same(client.connection));
        expect(opened, hasLength(2));
        expect(opened.last.connection, same(client.connection));
        closeAndCheck(async, client, appChannels: true);
      });
    });

    test('again soon after reconnecting at once: backs off', () {
      fakeAsync((async) {
        final endpoint = FakeEndpoint(async);
        final client = clientFor(endpoint, maxBackoff: ms(8000));
        async.elapse(ms(1000));
        unawaited(endpoint.last.goAway());
        async.flushMicrotasks();
        expect(endpoint.attemptSeconds, [0, 1]);
        // The new connection goes away too before lasting maxBackoff.
        async.elapse(ms(1000));
        unawaited(endpoint.last.goAway());
        async.flushMicrotasks();
        expect(client.state.phase, ClientPhase.disconnected);
        expect(client.state.lastStatus, isStatus(StatusCode.goingAway));
        async.elapse(ms(499));
        expect(endpoint.attempts, hasLength(2));
        async.elapse(ms(1));
        expect(endpoint.attemptSeconds, [0, 1, 2.5]);
        expect(client.state.phase, ClientPhase.connected);
        // A connection that lasted maxBackoff makes the next GOAWAY a
        // planned restart again.
        async.elapse(ms(10000));
        unawaited(endpoint.last.goAway());
        async.flushMicrotasks();
        expect(endpoint.attemptSeconds, [0, 1, 2.5, 12.5]);
        expect(client.state.phase, ClientPhase.connected);
        closeAndCheck(async, client);
      });
    });
  });

  group('next attempt', () {
    test('nextAttemptAt matches the backoff schedule', () {
      fakeAsync((async) {
        final endpoint = FakeEndpoint(async)..refuseAll = true;
        final client = clientFor(
          endpoint,
          maxBackoff: ms(4000),
          jitter: 0.2,
          random: Random(3),
        );
        final states = <ClientState>[];
        client.states.listen(states.add);
        async.elapse(const Duration(seconds: 20));
        final waits = [
          for (final s in states)
            if (s.phase == ClientPhase.disconnected) s,
        ];
        final times = endpoint.attempts;
        expect(times.length, greaterThan(5));
        expect(waits, hasLength(times.length));
        for (var i = 0; i + 1 < times.length; i++) {
          final at = waits[i].nextAttemptAt;
          expect(at, isNotNull);
          // The wall clock is not faked: compare the delays. On the web a
          // DateTime holds milliseconds.
          final scheduled = at!.difference(waits[i].since!);
          final gap = times[i + 1] - times[i];
          expect((scheduled - gap).inMicroseconds.abs(), lessThan(1000));
        }
        expect(client.nextAttemptAt, same(client.state.nextAttemptAt));
        expect(client.nextAttemptAt, isNotNull);
        expect([
          for (final s in states)
            if (s.phase != ClientPhase.disconnected) s.nextAttemptAt,
        ], everyElement(isNull));
        closeAndCheck(async, client);
        expect(client.nextAttemptAt, isNull);
      });
    });

    test('null while connecting, connected or stopped', () {
      fakeAsync((async) {
        final endpoint = FakeEndpoint(async);
        final client = clientFor(endpoint);
        expect(client.state.phase, ClientPhase.connecting);
        expect(client.nextAttemptAt, isNull);
        expect(client.state.retryIn, isNull);
        async.flushMicrotasks();
        expect(client.state.phase, ClientPhase.connected);
        expect(client.nextAttemptAt, isNull);

        // After a loss: the next attempt after the backoff.
        final states = <ClientState>[];
        client.states.skip(1).listen(states.add);
        unawaited(endpoint.last.close());
        async.flushMicrotasks();
        final waiting = client.state;
        expect(waiting.phase, ClientPhase.disconnected);
        expect(waiting.nextAttemptAt, isNotNull);
        expect(waiting.nextAttemptAt!.difference(waiting.since!), ms(500));
        expect(
          waiting.retryIn,
          allOf(
            greaterThanOrEqualTo(Duration.zero),
            lessThanOrEqualTo(ms(500)),
          ),
        );
        async.elapse(ms(500));
        expect(client.state.phase, ClientPhase.connected);
        expect(states.map((s) => s.phase), [
          ClientPhase.disconnected,
          ClientPhase.connecting,
          ClientPhase.connected,
        ]);
        expect(states.map((s) => s.nextAttemptAt != null), [
          isTrue,
          isFalse,
          isFalse,
        ]);

        client.stop();
        expect(client.state.phase, ClientPhase.disconnected);
        expect(client.nextAttemptAt, isNull);
        expect(client.state.retryIn, isNull);
        closeAndCheck(async, client);
      });
    });

    test('retryIn counts down to zero, never below', () {
      final now = DateTime.now();
      expect(const ClientState(ClientPhase.disconnected).retryIn, isNull);
      final due = ClientState(
        ClientPhase.disconnected,
        since: now,
        nextAttemptAt: now.add(const Duration(minutes: 1)),
      );
      expect(
        due.retryIn,
        allOf(
          greaterThan(const Duration(seconds: 50)),
          lessThanOrEqualTo(const Duration(minutes: 1)),
        ),
      );
      final past = ClientState(
        ClientPhase.disconnected,
        since: now.subtract(const Duration(minutes: 1)),
        nextAttemptAt: now.subtract(const Duration(seconds: 1)),
      );
      expect(past.retryIn, Duration.zero);
      expect(past.toString(), contains('next attempt at'));
    });
  });

  group('reconnectNow', () {
    test('during the backoff: attempts at once', () {
      fakeAsync((async) {
        final endpoint = FakeEndpoint(async)..refuseAll = true;
        final client = clientFor(endpoint);
        final states = <ClientState>[];
        client.states.listen(states.add);
        async.flushMicrotasks();
        expect(client.state.phase, ClientPhase.disconnected);
        expect(client.nextAttemptAt, isNotNull);

        async.elapse(ms(100));
        client.reconnectNow();
        expect(endpoint.attemptSeconds, [0, 0.1]);
        expect(client.state.phase, ClientPhase.connecting);
        expect(client.state.attempt, 2);
        expect(client.nextAttemptAt, isNull);
        async.flushMicrotasks();
        // Failed again: the backoff carries on, 1 s rather than 500 ms.
        expect(client.state.phase, ClientPhase.disconnected);
        expect(client.nextAttemptAt!.difference(client.state.since!), ms(1000));
        async.elapse(ms(999));
        expect(endpoint.attempts, hasLength(2));
        async.elapse(ms(1));
        expect(endpoint.attemptSeconds, [0, 0.1, 1.1]);

        // Waiting 2 s now; the endpoint is back.
        endpoint.refuseAll = false;
        async.elapse(ms(100));
        expect(client.state.phase, ClientPhase.disconnected);
        client.reconnectNow();
        async.flushMicrotasks();
        expect(endpoint.attemptSeconds, [0, 0.1, 1.1, 1.2]);
        expect(client.state.phase, ClientPhase.connected);
        expect(client.state.attempt, 4);
        expect(states.map((s) => s.phase), [
          ClientPhase.connecting,
          ClientPhase.disconnected,
          ClientPhase.connecting,
          ClientPhase.disconnected,
          ClientPhase.connecting,
          ClientPhase.disconnected,
          ClientPhase.connecting,
          ClientPhase.connected,
        ]);
        expect(
          states.map((s) => s.nextAttemptAt != null),
          states.map((s) => s.phase == ClientPhase.disconnected),
        );
        // The cancelled wait does not fire.
        async.elapse(const Duration(minutes: 5));
        expect(endpoint.attempts, hasLength(4));
        expect(client.state.phase, ClientPhase.connected);
        expect(endpoint.connections, hasLength(1));
        closeAndCheck(async, client);
      });
    });

    test('while connecting or connected: does nothing', () {
      fakeAsync((async) {
        final endpoint = FakeEndpoint(async);
        final pending = Completer<StreamChannel<Uint8List>>();
        var calls = 0;
        final client = clientFor(
          endpoint,
          connect: () {
            calls++;
            return pending.future;
          },
        );
        final states = <ClientState>[];
        client.states.skip(1).listen(states.add);
        async.elapse(ms(100));
        client.reconnectNow();
        client.reconnectNow(force: true);
        async.flushMicrotasks();
        expect(calls, 1);
        expect(client.state.phase, ClientPhase.connecting);
        expect(client.state.attempt, 1);
        expect(states, isEmpty);

        pending.complete(endpoint.accept());
        async.flushMicrotasks();
        expect(client.state.phase, ClientPhase.connected);
        final connection = client.connection;
        client.reconnectNow();
        async.elapse(const Duration(minutes: 1));
        expect(calls, 1);
        expect(client.connection, same(connection));
        expect(endpoint.last.peerGoingAway, isFalse);
        expect(states.map((s) => s.phase), [ClientPhase.connected]);
        closeAndCheck(async, client);
      });
    });

    test('force while connected: moves to a new connection', () {
      fakeAsync((async) {
        final endpoint = FakeEndpoint(async);
        var subscriptions = 0;
        endpoint.onChannel = (incoming) {
          if (incoming.address.type != Name('feed')) {
            return;
          }
          final talk = incoming.talk();
          talk.messages.listen((message) {
            subscriptions++;
            message.reply(Uint8List(0));
          });
        };
        final client = clientFor(endpoint);
        final opened = <MuxChannel>[];
        final closed = <Status>[];
        final persistent = client.openPersistent(
          events,
          opened.add,
          onClosed: closed.add,
        );
        final talkClosed = <Status>[];
        final talk = client.openPersistentTalk(
          feed,
          (talk) => talk.request('SUB', Uint8List(0)),
          onClosed: talkClosed.add,
        );
        final own = Outcome(client.openChannel(events));
        async.elapse(ms(1000));
        expect(subscriptions, 1);
        final first = client.connection!;
        final firstConnected = client.connected;
        final server = endpoint.last;
        final mine = own.value!;
        final theirs = endpoint.on(server).last.channel;
        final states = <ClientState>[];
        client.states.skip(1).listen(states.add);
        final firstDone = Outcome(first.done);
        final serverDone = Outcome(server.done);

        client.reconnectNow(force: true);
        expect(client.state.phase, ClientPhase.connecting);
        expect(client.connection, isNull);
        async.flushMicrotasks();

        expect(endpoint.attemptSeconds, [0, 1]);
        expect(states.map((s) => s.phase), [
          ClientPhase.connecting,
          ClientPhase.connected,
        ]);
        expect(
          states.map((s) => s.lastStatus?.known),
          everyElement(StatusCode.goingAway),
        );
        expect(states.map((s) => s.attempt), [1, 1]);
        final second = client.connection!;
        expect(second, isNot(same(first)));
        expect(client.connected, isNot(same(firstConnected)));
        // The old connection got GOAWAY; the persistent channels on it
        // were closed with GOING_AWAY and opened again on the new one.
        expect(server.peerGoingAway, isTrue);
        expect(closed, [isStatus(StatusCode.goingAway)]);
        expect(talkClosed, [isStatus(StatusCode.goingAway)]);
        expect(opened, hasLength(2));
        expect(opened.last.connection, same(second));
        expect(persistent.current, same(opened.last));
        expect(talk.current?.isOpen, isTrue);
        expect(subscriptions, 2);
        expect(
          endpoint.on(endpoint.last).map((c) => c.address.type?.toString()),
          unorderedEquals(['events', 'feed']),
        );

        // The application channel carries on over the old connection.
        expect(firstDone.isDone, isFalse);
        expect(mine.state, MuxChannelState.open);
        final received = <List<int>>[];
        mine.stream.listen(received.add);
        theirs.send(bytes([1]));
        async.flushMicrotasks();
        expect(received, [
          [1],
        ]);
        // Once it is done, the old connection closes, and nothing
        // reconnects.
        unawaited(mine.close());
        async.flushMicrotasks();
        expect(firstDone.value, isStatus(StatusCode.goingAway));
        expect(serverDone.value, isStatus(StatusCode.goingAway));
        async.elapse(const Duration(minutes: 5));
        expect(endpoint.attempts, hasLength(2));
        expect(client.connection, same(second));
        expect(states, hasLength(2));
        expect(opened, hasLength(2));
        closeAndCheck(async, client);
      });
    });

    test('force: a failed attempt backs off as usual', () {
      fakeAsync((async) {
        final endpoint = FakeEndpoint(async);
        final client = clientFor(endpoint);
        final opened = <MuxChannel>[];
        client.openPersistent(events, opened.add);
        async.elapse(ms(1000));
        endpoint.failures = 1;
        client.reconnectNow(force: true);
        async.flushMicrotasks();
        expect(endpoint.attemptSeconds, [0, 1]);
        expect(client.state.phase, ClientPhase.disconnected);
        expect(client.state.lastStatus, isStatus(StatusCode.unavailable));
        expect(client.nextAttemptAt!.difference(client.state.since!), ms(500));
        async.elapse(ms(500));
        expect(endpoint.attemptSeconds, [0, 1, 1.5]);
        expect(client.state.phase, ClientPhase.connected);
        expect(opened, hasLength(2));
        expect(opened.last.connection, same(client.connection));
        closeAndCheck(async, client);
      });
    });

    test('not started, stopped or closed: does nothing', () {
      fakeAsync((async) {
        final endpoint = FakeEndpoint(async);
        final client = clientFor(endpoint, autoStart: false);
        client.reconnectNow();
        client.reconnectNow(force: true);
        async.elapse(const Duration(seconds: 5));
        expect(endpoint.attempts, isEmpty);
        expect(client.isRunning, isFalse);

        client.start();
        async.flushMicrotasks();
        expect(client.state.phase, ClientPhase.connected);
        client.stop();
        client.reconnectNow();
        client.reconnectNow(force: true);
        async.elapse(const Duration(seconds: 5));
        expect(endpoint.attempts, hasLength(1));
        expect(client.state.phase, ClientPhase.disconnected);
        expect(async.pendingTimers, isEmpty);

        // Closed while waiting for the next attempt.
        endpoint.refuseAll = true;
        client.start();
        async.flushMicrotasks();
        expect(client.nextAttemptAt, isNotNull);
        closeAndCheck(async, client);
        final states = <ClientState>[];
        client.states.listen(states.add);
        client.reconnectNow();
        client.reconnectNow(force: true);
        async.elapse(const Duration(seconds: 5));
        expect(endpoint.attempts, hasLength(2));
        expect(client.state.phase, ClientPhase.disconnected);
        expect(client.state.lastStatus, isStatus(StatusCode.cancelled));
        expect(client.nextAttemptAt, isNull);
        expect(states.map((s) => s.phase), [ClientPhase.disconnected]);
        expect(async.pendingTimers, isEmpty);
      });
    });
  });

  group('the endpoint', () {
    test('pushed channels arrive on incoming across reconnects', () {
      fakeAsync((async) {
        final endpoint = FakeEndpoint(async);
        final client = clientFor(endpoint);
        final pushed = <IncomingChannel>[];
        client.incoming.listen((incoming) {
          pushed.add(incoming);
          if (incoming.address.type == null) {
            incoming.talk().messages.listen((m) => m.reply(bytes([3])));
          }
        });
        async.flushMicrotasks();
        final push = ChannelAddress(type: Name('notify'), payload: bytes([1]));
        endpoint.last.open(push.encode()).send(bytes([42]));
        async.flushMicrotasks();
        expect(pushed, hasLength(1));
        expect(pushed.single.address.type, Name('notify'));
        expect(pushed.single.address.payload, [1]);
        expect(pushed.single.connection, same(client.connection));
        final data = <List<int>>[];
        pushed.single.channel.stream.listen(data.add);
        async.flushMicrotasks();
        expect(data, [
          [42],
        ]);

        // A malformed OPEN payload is refused, not delivered.
        final bad = endpoint.last.open(bytes([0xF0]));
        final badDone = Outcome(bad.done);
        async.flushMicrotasks();
        expect(badDone.value, isStatus(StatusCode.protocolError));
        expect(pushed, hasLength(1));

        unawaited(endpoint.last.close());
        async.elapse(ms(500));
        endpoint.last.open(push.encode());
        async.flushMicrotasks();
        expect(pushed, hasLength(2));
        expect(pushed.last.connection, same(client.connection));

        // A Talk exchange the endpoint starts, on the default address.
        final talk = TalkChannel(endpoint.last.open(Uint8List(0)));
        final reply = Outcome(talk.request('ASK', Uint8List(0)));
        async.flushMicrotasks();
        expect(pushed, hasLength(3));
        expect(reply.value?.payload, [3]);
        closeAndCheck(async, client, appChannels: true);
      });
    });

    test('pushed channels are refused once incoming is cancelled', () {
      fakeAsync((async) {
        final endpoint = FakeEndpoint(async);
        final client = clientFor(endpoint);
        final pushed = <IncomingChannel>[];
        final subscription = client.incoming.listen(pushed.add);
        async.flushMicrotasks();
        endpoint.last.open(Uint8List(0));
        async.flushMicrotasks();
        expect(pushed, hasLength(1));
        unawaited(subscription.cancel());
        final refused = Outcome(endpoint.last.open(Uint8List(0)).done);
        async.flushMicrotasks();
        expect(refused.value, isStatus(StatusCode.unavailable));
        expect(pushed, hasLength(1));
        unawaited(pushed.single.reject(Status.ok));
        closeAndCheck(async, client);
      });
    });
  });
}
