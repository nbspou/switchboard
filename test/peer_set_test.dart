// PeerSet: a consumer kept connected to every instance of a type, over
// mem:// workers and a StaticResolver (no naming service): membership,
// online and offline events, a worker's reboot, the per-peer channel and
// its hook, the backoff schedule (fake_async), the outgoing policy and the
// per-worker credential, and close. The consumer side of the untrusted
// worker fleet (wiki page "Switchboard Use Cases", entry 5).

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:switchboard/switchboard.dart';
import 'package:test/test.dart';

const fast = MuxOptions(
  goAwayGrace: Duration(milliseconds: 100),
  keepAliveInterval: null,
  keepAliveTimeout: Duration(milliseconds: 100),
);
const limit = Duration(seconds: 5);

Duration ms(int n) => Duration(milliseconds: n);

final gpu = Name('gpu');
final back = Name('back');
final meshSecret = bytes('mesh-secret');

Uint8List bytes(String text) => Uint8List.fromList(utf8.encode(text));

String text(Uint8List data) => utf8.decode(data);

Matcher throwsCode(StatusCode code) =>
    throwsA(isA<SwitchboardException>().having((e) => e.code, 'code', code));

Matcher hasCode(StatusCode code) =>
    isA<Status>().having((s) => s.known, 'code', code);

bool containsBytes(Uint8List haystack, Uint8List needle) {
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    var j = 0;
    while (j < needle.length && haystack[i + j] == needle[j]) {
      j++;
    }
    if (j == needle.length) {
      return true;
    }
  }
  return false;
}

/// Polls [condition] every few milliseconds; fails after [limit].
Future<void> until(bool Function() condition, [String? what]) async {
  final deadline = DateTime.now().add(limit);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('${what ?? 'condition'} not met within $limit');
    }
    await Future<void>.delayed(ms(2));
  }
}

var _names = 0;

/// A worker: a node listening at a fixed mem:// name, serving `gpu` under
/// whatever instance it is addressed as (a registrar registered it), with
/// a Talk echo `<id>:<payload>`. It records every OPEN payload as received.
class Worker {
  Worker(this.id)
    : name = 'worker-$id-${_names++}-${Random().nextInt(1 << 30)}';

  final int id;
  final String name;
  Switchboard? sb;
  final List<Uint8List> raw = [];
  final List<MuxConnection> accepted = [];

  /// Rejects the channels it receives with this status instead of serving.
  Status? reject;

  Uri get uri => Uri.parse('mem://$name');

  /// The application payloads received, as text.
  List<String> get payloads => [
    for (final open in raw) text(ChannelAddress.decode(open).payload),
  ];

  ServiceRecord record({Uint8List? metadata, List<Uri>? endpoints}) =>
      ServiceRecord(
        ServiceAddress(gpu, id),
        endpoints: endpoints ?? [uri],
        metadata: metadata,
      );

  Future<void> start() async {
    final node = sb = Switchboard(muxOptions: fast);
    node.registerService(gpu, _serve, acceptAnyInstance: true);
    node.connections.listen(accepted.add);
    await node.listenMemory(
      name: name,
      policy: ChannelPolicies.allowTypes({gpu}),
    );
  }

  Future<void> stop() async {
    await sb?.close();
    sb = null;
  }

  void _serve(IncomingChannel incoming) {
    raw.add(incoming.channel.openPayload);
    final status = reject;
    if (status != null) {
      unawaited(incoming.reject(status));
      return;
    }
    incoming.talk().messages.listen((message) {
      if (message.expectsReply) {
        message.reply(bytes('$id:${text(message.payload)}'));
      }
    });
  }

  /// Pushes a channel to [back] into the consumer on the last connection
  /// accepted, and returns how it ended.
  Future<Status> push() =>
      sb!.openChannelOn(accepted.last, ChannelAddress(type: back)).done;
}

void main() {
  late List<Worker> workers;
  late StaticResolver resolver;
  late Switchboard consumer;
  late List<String> log;

  Future<Worker> worker(int id) async {
    final w = Worker(id);
    await w.start();
    addTearDown(w.stop);
    workers.add(w);
    return w;
  }

  /// The consumer: its default payload is the mesh credential, and each
  /// worker's key is in its record's metadata.
  Switchboard consumerNode({ChannelPolicy? outgoingPolicy}) {
    final node = Switchboard(
      muxOptions: fast,
      defaultPayload: meshSecret,
      outgoingPolicy: outgoingPolicy,
      credentialFor: (endpoint, record) =>
          record != null && record.metadata.isNotEmpty ? record.metadata : null,
    );
    addTearDown(node.close);
    node.registerService(back, (incoming) {
      incoming.channel.send(bytes('consumer'));
      unawaited(incoming.channel.close());
    });
    return node;
  }

  ServiceRecord keyed(Worker w) => w.record(metadata: bytes('key-${w.id}'));

  PeerSet watch({
    FutureOr<void> Function(Peer peer)? onConnect,
    ChannelAddress? channel,
    FutureOr<void> Function(Peer peer, MuxChannel channel)? onOpen,
    ChannelPolicy? policy,
    Duration connectTimeout = const Duration(seconds: 1),
  }) {
    final set = PeerSet.watch(
      consumer,
      gpu,
      resolver: resolver,
      onConnect: onConnect,
      channel: channel,
      onOpen: onOpen,
      initialBackoff: ms(10),
      maxBackoff: ms(80),
      jitter: 0,
      connectTimeout: connectTimeout,
      policy: policy,
    );
    addTearDown(set.close);
    set.events.listen(
      (event) => log.add('${event.type.name} ${event.peer.address.instance}'),
    );
    return set;
  }

  setUp(() {
    workers = [];
    resolver = StaticResolver();
    addTearDown(resolver.close);
    consumer = consumerNode();
    log = [];
  });

  test('added, online, offline, online after a reboot, removed', () async {
    final w = await worker(1);
    resolver.add(keyed(w));
    final set = watch();
    await set.ready;
    final peer = set.peers[1]!;
    expect(peer.address, ServiceAddress(gpu, 1));
    await until(() => peer.isOnline, 'online');
    expect(peer.endpoint, w.uri);
    expect(peer.connection, isNotNull);
    expect(set.online, [peer]);
    // The worker reboots: it goes away, and is back at the same address.
    await w.stop();
    await until(() => peer.state == PeerState.offline, 'offline');
    expect(peer.connection, isNull);
    expect(peer.lastStatus, isNotNull);
    expect(peer.nextAttemptAt, isNotNull);
    expect(set.online, isEmpty);
    await w.start();
    await until(() => peer.isOnline, 'online again');
    resolver.remove(ServiceAddress(gpu, 1));
    await until(() => peer.state == PeerState.removed, 'removed');
    expect(set.peers, isEmpty);
    await until(() => log.length == 5);
    expect(log, ['added 1', 'online 1', 'offline 1', 'online 1', 'removed 1']);
    // Removed: the worker's side of the connection ends (GOAWAY).
    await w.accepted.last.done.timeout(limit);
  });

  test(
    'the initial records and later ones; one connection each, its own',
    () async {
      final a = await worker(1);
      final b = await worker(2);
      resolver.add(keyed(a));
      final set = watch();
      await set.ready;
      expect(set.peers.keys, [1]);
      resolver.add(keyed(b));
      await until(() => set.online.length == 2, 'both online');
      expect(set.peers.keys, [1, 2]);
      expect(a.accepted, hasLength(1));
      expect(b.accepted, hasLength(1));
      // Not the node's pooled connections: a reboot disturbs nobody else.
      final pooled = await consumer.connect(a.uri);
      expect(pooled, isNot(same(set.peers[1]!.connection)));
      expect(log, containsAllInOrder(['added 1', 'added 2']));
    },
  );

  test(
    'onConnect, the per-peer channel and onOpen, on every connection',
    () async {
      final w = await worker(1);
      resolver.add(keyed(w));
      final hooks = <String>[];
      late final PeerSet set;
      set = watch(
        onConnect: (peer) async {
          hooks.add('connect ${peer.state.name} ${peer.connection != null}');
          // The connection is usable for a handshake already.
          final talk = await set.openTalk(peer.address.instance);
          hooks.add(text((await talk.request('HELLO', bytes('hi'))).payload));
          await talk.close();
        },
        channel: ChannelAddress(type: gpu),
        onOpen: (peer, channel) async {
          final talk = TalkChannel(channel);
          hooks.add(
            'open ${text((await talk.request('CAPS', bytes('caps'))).payload)}',
          );
        },
      );
      await until(() => set.peers[1]?.isOnline ?? false, 'online');
      expect(hooks, ['connect connecting true', '1:hi', 'open 1:caps']);
      // Online only once the hooks are done.
      await until(() => log.contains('online 1'));
      final channel = set.peers[1]!.channel!;
      expect(ChannelAddress.decode(channel.openPayload).instance, 1);
      // A reboot: everything again, on the new connection.
      hooks.clear();
      await w.stop();
      await until(() => !set.peers[1]!.isOnline);
      await w.start();
      await until(() => set.peers[1]!.isOnline, 'online again');
      expect(hooks, ['connect connecting true', '1:hi', 'open 1:caps']);
      expect(set.peers[1]!.channel, isNot(same(channel)));
      expect(log, ['added 1', 'online 1', 'offline 1', 'online 1']);
    },
  );

  test('the per-peer channel is opened again when it ends on a live '
      'connection; onOpen runs again', () async {
    final w = await worker(1);
    resolver.add(keyed(w));
    final opened = <MuxChannel>[];
    final set = watch(
      channel: ChannelAddress(type: gpu),
      onOpen: (peer, channel) => opened.add(channel),
    );
    await until(() => set.peers[1]?.isOnline ?? false, 'online');
    final connection = set.peers[1]!.connection;
    // The worker closes it (not a refusal): opened again, still online.
    await until(() => w.accepted.isNotEmpty);
    final served = w.accepted.single.channels.single;
    await served.close(Status.of(StatusCode.unavailable, 'restarting'));
    await until(() => opened.length == 2, 'opened again');
    expect(set.peers[1]!.isOnline, isTrue);
    expect(set.peers[1]!.connection, same(connection));
    expect(set.peers[1]!.channel, same(opened.last));
    expect(log, ['added 1', 'online 1']);
  });

  test('a refused per-peer channel takes the peer offline and is retried '
      'after the backoff', () async {
    final w = await worker(1);
    w.reject = Status.of(StatusCode.permissionDenied, 'bad key');
    resolver.add(keyed(w));
    final set = watch(channel: ChannelAddress(type: gpu));
    await until(() => w.raw.length >= 3, 'retried');
    final peer = set.peers[1]!;
    expect(peer.isOnline, isFalse);
    expect(peer.lastStatus, hasCode(StatusCode.permissionDenied));
    expect(log, ['added 1', 'offline 1']);
    // Each attempt was a new connection, left with GOAWAY.
    expect(w.accepted.length, greaterThanOrEqualTo(3));
    w.reject = null;
    await until(() => peer.isOnline, 'online once accepted');
    expect(log, ['added 1', 'offline 1', 'online 1']);
  });

  test('openChannel and openTalk on a peer', () async {
    final w = await worker(1);
    resolver.add(keyed(w));
    final set = watch();
    await until(() => set.peers[1]?.isOnline ?? false, 'online');
    final talk = await set.openTalk(1);
    expect(text((await talk.request('ECHO', bytes('x'))).payload), '1:x');
    await talk.close();
    final explicit = await set.openTalk(1, payload: bytes('given'));
    await explicit.request('ECHO', Uint8List(0));
    await explicit.close();
    expect(w.payloads, ['key-1', 'given']);
    final header = ChannelAddress.decode(w.raw.first);
    expect(header.address, ServiceAddress(gpu, 1));
    await expectLater(set.openChannel(9), throwsCode(StatusCode.notFound));
    await w.stop();
    await until(() => !set.peers[1]!.isOnline);
    await expectLater(
      set.openChannel(1),
      throwsCode(StatusCode.failedPrecondition),
    );
  });

  test('credentials: each worker sees its own key, never the mesh '
      'credential', () async {
    final ws = [for (var id = 1; id <= 4; id++) await worker(id)];
    for (final w in ws) {
      resolver.add(keyed(w));
    }
    final set = watch(channel: ChannelAddress(type: gpu));
    await until(() => set.online.length == 4, 'all online');
    for (final w in ws) {
      final talk = await set.openTalk(w.id);
      await talk.request('ECHO', Uint8List(0));
      await talk.close();
    }
    for (final w in ws) {
      expect(w.payloads, ['key-${w.id}', 'key-${w.id}'], reason: w.name);
      for (final open in w.raw) {
        expect(containsBytes(open, meshSecret), isFalse);
      }
    }
  });

  test(
    'outgoing policy: a worker may not push channels into the consumer',
    () async {
      final w = await worker(1);
      resolver.add(keyed(w));
      // No policy anywhere: the push is dispatched.
      final open = watch();
      await until(() => open.peers[1]?.isOnline ?? false, 'online');
      expect(await w.push(), Status.ok);
      await open.close();
      // The set's policy.
      final strict = watch(policy: ChannelPolicies.denyAll);
      await until(() => strict.peers[1]?.isOnline ?? false, 'online');
      final refused = await w.push();
      expect(refused, hasCode(StatusCode.permissionDenied));
      expect(refused.reason, 'permission denied');
      await strict.close();
      // The node's outgoing policy.
      consumer = consumerNode(outgoingPolicy: ChannelPolicies.denyAll);
      final byNode = watch();
      await until(() => byNode.peers[1]?.isOnline ?? false, 'online');
      expect(await w.push(), hasCode(StatusCode.permissionDenied));
    },
  );

  test(
    'a record that changes: updated; other endpoints move the peer',
    () async {
      final w = await worker(1);
      resolver.add(keyed(w));
      final set = watch();
      await until(() => set.peers[1]?.isOnline ?? false, 'online');
      final peer = set.peers[1]!;
      final first = peer.connection;
      // Other metadata, same endpoints: the connection stays.
      resolver.add(w.record(metadata: bytes('key-1b')));
      await until(() => log.contains('updated 1'));
      expect(peer.connection, same(first));
      expect(peer.record.metadata, bytes('key-1b'));
      // The worker moves to another address.
      final moved = Worker(1);
      await moved.start();
      addTearDown(moved.stop);
      resolver.add(moved.record(metadata: bytes('key-1b')));
      await until(
        () => peer.isOnline && peer.endpoint == moved.uri,
        'moved and online',
      );
      expect(peer.connection, isNot(same(first)));
      await first!.done.timeout(limit);
      expect(log, [
        'added 1',
        'online 1',
        'updated 1',
        'updated 1',
        'offline 1',
        'online 1',
      ]);
    },
  );

  test('endpoints are tried in order; the first that answers', () async {
    final w = await worker(1);
    resolver.add(
      w.record(endpoints: [Uri.parse('mem://nobody-${_names++}'), w.uri]),
    );
    final set = watch();
    await until(() => set.peers[1]?.isOnline ?? false, 'online');
    expect(set.peers[1]!.endpoint, w.uri);
    expect(set.peers[1]!.attempt, 1);
  });

  test('hooks that throw or hang do not keep a peer offline', () async {
    final w = await worker(1);
    resolver.add(keyed(w));
    var calls = 0;
    final set = watch(
      connectTimeout: ms(50),
      onConnect: (peer) {
        calls++;
        throw StateError('broken hook');
      },
      channel: ChannelAddress(type: gpu),
      // Never completes: given up after the connect timeout.
      onOpen: (peer, channel) => Completer<void>().future,
    );
    await until(() => set.peers[1]?.isOnline ?? false, 'online');
    expect(calls, 1);
    expect(set.peers[1]!.channel, isNotNull);
  });

  test(
    'close: every peer removed, its connection closed, events end',
    () async {
      final a = await worker(1);
      final b = await worker(2);
      resolver
        ..add(keyed(a))
        ..add(keyed(b))
        ..add(
          ServiceRecord(
            ServiceAddress(gpu, 3),
            endpoints: [Uri.parse('mem://nobody-${_names++}')],
          ),
        );
      final set = watch(channel: ChannelAddress(type: gpu));
      final ended = Completer<void>();
      set.events.listen(null, onDone: ended.complete);
      await until(() => set.online.length == 2, 'online');
      await until(() => set.peers[3]!.state == PeerState.offline);
      final peers = set.peers.values.toList();
      await set.close();
      await ended.future.timeout(limit);
      expect(set.isClosed, isTrue);
      expect(set.peers, isEmpty);
      expect(peers.map((p) => p.state), everyElement(PeerState.removed));
      expect(log.where((e) => e.startsWith('removed')), hasLength(3));
      for (final w in [a, b]) {
        await w.accepted.single.done.timeout(limit);
      }
      await expectLater(
        set.openChannel(1),
        throwsCode(StatusCode.failedPrecondition),
      );
      // Membership no longer followed.
      resolver.add(ServiceRecord(ServiceAddress(gpu, 4)));
      await Future<void>.delayed(ms(10));
      expect(set.peers, isEmpty);
    },
  );

  test('ready fails with CANCELLED if closed first; argument checks', () async {
    final slow = _NeverReady();
    final set = PeerSet.watch(consumer, gpu, resolver: slow);
    await set.close();
    await expectLater(set.ready, throwsCode(StatusCode.cancelled));
    final bare = Switchboard();
    addTearDown(bare.close);
    expect(() => PeerSet.watch(bare, gpu), throwsArgumentError);
    expect(
      () => PeerSet.watch(consumer, gpu, resolver: resolver, onOpen: (_, _) {}),
      throwsArgumentError,
    );
    expect(
      () =>
          PeerSet.watch(consumer, gpu, resolver: resolver, backoffFactor: 0.5),
      throwsArgumentError,
    );
  });

  group('timing (fake_async)', () {
    test('the backoff schedule, a lasting connection resets it, close '
        'leaves no timer', () {
      fakeAsync((async) {
        final resolver = StaticResolver();
        final consumer = Switchboard(muxOptions: fast);
        final w = Worker(1);
        resolver.add(w.record());
        final set = PeerSet.watch(
          consumer,
          gpu,
          resolver: resolver,
          initialBackoff: ms(500),
          maxBackoff: const Duration(seconds: 4),
          jitter: 0,
        );
        final events = <String>[];
        set.events.listen((e) => events.add('${e.type.name} ${async.elapsed}'));
        final peer = set.peers.isEmpty ? null : set.peers[1];
        expect(peer, isNull);
        async.flushMicrotasks();
        // Attempt times: the attempt counter, sampled every 10 ms.
        final attempts = <int>[];
        var seen = 0;
        for (var t = 0; t <= 12000; t += 10) {
          final current = set.peers[1]!.attempt;
          if (current > seen) {
            attempts.add(t);
            seen = current;
          }
          async.elapse(ms(10));
        }
        expect(attempts, [0, 500, 1500, 3500, 7500, 11500]);
        expect(events, ['added 0:00:00.000000', 'offline 0:00:00.000000']);
        // The worker comes up: the next attempt (4 s later) connects.
        unawaited(w.start());
        async.elapse(const Duration(seconds: 4));
        expect(set.peers[1]!.isOnline, isTrue);
        expect(events.last, 'online 0:00:15.500000');
        // A connection that lasts beyond maxBackoff resets the schedule:
        // after the worker goes away, an attempt at once (it fails, the
        // worker is down), then the first delay again, 500 ms.
        async.elapse(const Duration(seconds: 5));
        unawaited(w.stop());
        async.elapse(ms(200));
        expect(set.peers[1]!.state, PeerState.offline);
        expect(set.peers[1]!.attempt, 1);
        final lost = events.last;
        expect(lost, 'offline 0:00:21.010000');
        unawaited(w.start());
        async.elapse(ms(299));
        expect(set.peers[1]!.isOnline, isFalse);
        async.elapse(ms(2));
        expect(set.peers[1]!.isOnline, isTrue);
        expect(events.last, 'online 0:00:21.510000');
        // Close: nothing left running.
        unawaited(set.close());
        unawaited(w.stop());
        unawaited(consumer.close());
        unawaited(resolver.close());
        async.elapse(const Duration(seconds: 1));
        expect(async.pendingTimers, isEmpty);
        expect(events.last, startsWith('removed'));
      });
    });

    test('a GOAWAY: reconnected at once, not after the backoff', () {
      fakeAsync((async) {
        final resolver = StaticResolver();
        final consumer = Switchboard(muxOptions: fast);
        final a = Worker(1);
        final b = Worker(1);
        unawaited(a.start());
        unawaited(b.start());
        async.flushMicrotasks();
        // Two endpoints: the first goes away, the second answers at once.
        resolver.add(a.record(endpoints: [a.uri, b.uri]));
        final set = PeerSet.watch(
          consumer,
          gpu,
          resolver: resolver,
          initialBackoff: ms(500),
          jitter: 0,
        );
        async.elapse(ms(10));
        expect(set.peers[1]!.endpoint, a.uri);
        unawaited(a.stop());
        async.elapse(ms(10));
        expect(set.peers[1]!.isOnline, isTrue);
        expect(set.peers[1]!.endpoint, b.uri);
        unawaited(set.close());
        unawaited(b.stop());
        unawaited(consumer.close());
        unawaited(resolver.close());
        async.elapse(const Duration(seconds: 1));
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('a hanging hook is waited for at most connectTimeout', () {
      fakeAsync((async) {
        final resolver = StaticResolver();
        final consumer = Switchboard(muxOptions: fast);
        final w = Worker(1);
        unawaited(w.start());
        async.flushMicrotasks();
        resolver.add(w.record());
        final set = PeerSet.watch(
          consumer,
          gpu,
          resolver: resolver,
          connectTimeout: ms(300),
          onConnect: (_) => Completer<void>().future,
        );
        async.elapse(ms(299));
        expect(set.peers[1]!.state, PeerState.connecting);
        async.elapse(ms(2));
        expect(set.peers[1]!.isOnline, isTrue);
        unawaited(set.close());
        unawaited(w.stop());
        unawaited(consumer.close());
        unawaited(resolver.close());
        async.elapse(const Duration(seconds: 1));
        expect(async.pendingTimers, isEmpty);
      });
    });
  });
}

/// A resolver that never becomes ready.
class _NeverReady implements Resolver {
  @override
  Future<void> get ready => Completer<void>().future;

  @override
  Stream<ServiceEvent> get events => const Stream.empty();

  @override
  Future<List<ServiceRecord>> resolve(Name type) async => const [];

  @override
  Future<void> close() async {}
}
