/*
Polyverse Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Authors:
  Jan Boon <jan.boon@kaetemi.be>
  Claude Opus 5.5 <noreply@anthropic.com>
*/

// PeerSet: a consumer kept connected to every instance of a type, over
// mem:// workers and a StaticResolver (no naming service): membership (the
// initial records, the events around them, the removal hold-down), online
// and offline events, a worker's reboot, the per-peer channel and its hooks
// (a peer is online only once both succeeded, on every connection and on
// every re-open), endpoint fallback within the connect timeout, the backoff
// schedule (fake_async), the outgoing policy and the per-worker credential,
// resolver errors, and close. The consumer side of the untrusted worker
// fleet (wiki page "Polyverse Switchboard Use Cases", entry 5).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:logging/logging.dart';
import 'package:switchboard/switchboard.dart';
import 'package:test/test.dart';

const fast = MuxOptions(
  goAwayGrace: Duration(milliseconds: 100),
  keepAliveInterval: null,
  keepAliveTimeout: Duration(milliseconds: 100),
);

/// Waits up to 10 s for the channels on a connection it leaves.
const patient = MuxOptions(
  goAwayGrace: Duration(seconds: 10),
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
  Worker(this.id, {this.options = fast})
    : name = 'worker-$id-${_names++}-${Random().nextInt(1 << 30)}';

  final int id;
  final String name;
  final MuxOptions options;
  Switchboard? sb;
  final List<Uint8List> raw = [];
  final List<MuxConnection> accepted = [];

  /// Rejects the channels it receives with this status instead of serving.
  Status? reject;

  /// Handles the channels it receives instead of serving them, if set.
  void Function(IncomingChannel incoming)? handler;

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
    final node = sb = Switchboard(muxOptions: options);
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
    final handle = handler;
    if (handle != null) {
      handle(incoming);
      return;
    }
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

  /// Sends GOAWAY `GOING_AWAY` on the last connection accepted, which stays
  /// up for the channels on it (at most the grace of [options]); completes
  /// once it has closed.
  Future<void> goAway() =>
      accepted.last.goAway(Status.of(StatusCode.goingAway, 'worker rebooting'));

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
  Switchboard consumerNode({
    ChannelPolicy? outgoingPolicy,
    Duration connectTimeout = const Duration(seconds: 10),
  }) {
    final node = Switchboard(
      muxOptions: fast,
      defaultPayload: meshSecret,
      connectTimeout: connectTimeout,
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
    Duration removalHoldDown = Duration.zero,
    Resolver? from,
  }) {
    final set = PeerSet.watch(
      consumer,
      gpu,
      resolver: from ?? resolver,
      onConnect: onConnect,
      channel: channel,
      onOpen: onOpen,
      initialBackoff: ms(10),
      maxBackoff: ms(80),
      jitter: 0,
      connectTimeout: connectTimeout,
      removalHoldDown: removalHoldDown,
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
    // The worker closes it (not a refusal): offline while it is closed,
    // opened again on the same connection, online again.
    await until(() => w.accepted.isNotEmpty);
    final served = w.accepted.single.channels.single;
    await served.close(Status.of(StatusCode.unavailable, 'restarting'));
    await until(() => opened.length == 2, 'opened again');
    await until(() => set.peers[1]!.isOnline, 'online again');
    expect(set.peers[1]!.connection, same(connection));
    expect(set.peers[1]!.channel, same(opened.last));
    expect(w.accepted, hasLength(1));
    expect(log, ['added 1', 'online 1', 'offline 1', 'online 1']);
  });

  test('a re-open the worker refuses: offline on the same connection, no '
      'onOpen, opened again after the backoff', () async {
    final w = await worker(1);
    resolver.add(keyed(w));
    final opened = <MuxChannel>[];
    final set = watch(
      channel: ChannelAddress(type: gpu),
      onOpen: (peer, channel) => opened.add(channel),
    );
    await until(() => set.peers[1]?.isOnline ?? false, 'online');
    final peer = set.peers[1]!;
    final connection = peer.connection;
    // The worker closes the channel and refuses the next ones on arrival.
    w.reject = Status.of(StatusCode.unavailable, 'busy');
    await w.accepted.single.channels.single.close(
      Status.of(StatusCode.unavailable, 'restarting'),
    );
    await until(() => w.raw.length >= 4, 'opened again and refused');
    expect(peer.isOnline, isFalse);
    expect(set.online, isEmpty);
    expect(peer.lastStatus, hasCode(StatusCode.unavailable));
    expect(peer.connection, same(connection));
    // onOpen never ran on a refused channel.
    expect(opened, hasLength(1));
    w.reject = null;
    await until(() => peer.isOnline, 'online once accepted');
    expect(opened, hasLength(2));
    expect(peer.channel, same(opened.last));
    expect(peer.connection, same(connection));
    expect(w.accepted, hasLength(1));
    expect(log, ['added 1', 'online 1', 'offline 1', 'online 1']);
  });

  test('onOpen on a re-open is bounded by connectTimeout', () async {
    final w = await worker(1);
    resolver.add(keyed(w));
    var calls = 0;
    final set = watch(
      connectTimeout: ms(100),
      channel: ChannelAddress(type: gpu),
      // The second never completes.
      onOpen: (peer, channel) => ++calls == 2 ? Completer<void>().future : null,
    );
    await until(() => set.peers[1]?.isOnline ?? false, 'online');
    final peer = set.peers[1]!;
    final connection = peer.connection;
    await w.accepted.single.channels.single.close(
      Status.of(StatusCode.unavailable, 'restarting'),
    );
    await until(() => calls == 3 && peer.isOnline, 'online after the third');
    expect(w.raw, hasLength(3));
    expect(peer.connection, same(connection));
    expect(log, ['added 1', 'online 1', 'offline 1', 'online 1']);
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

  test('an endpoint that never answers leaves time for the next', () async {
    // Accepts TCP connections and never answers the WebSocket upgrade: a
    // dial to it hangs until the node's connect timeout, like a dial to an
    // unroutable address.
    final hole = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final held = <Socket>[];
    hole.listen(held.add);
    addTearDown(() async {
      for (final socket in held) {
        socket.destroy();
      }
      await hole.close();
    });
    final w = await worker(1);
    resolver.add(
      w.record(
        metadata: bytes('key-1'),
        endpoints: [Uri.parse('ws://127.0.0.1:${hole.port}/'), w.uri],
      ),
    );
    // Equal bounds for the node and the set: the first endpoint must not
    // take all of it.
    consumer = consumerNode(connectTimeout: ms(400));
    final set = watch(connectTimeout: ms(400));
    await until(() => set.peers[1]?.isOnline ?? false, 'online');
    final peer = set.peers[1]!;
    expect(peer.endpoint, w.uri);
    expect(peer.attempt, 1);
    expect(log, ['added 1', 'online 1']);
  });

  test('a hook that throws, fails or hangs fails the attempt: GOAWAY, '
      'offline, retried after the backoff', () async {
    final w = await worker(1);
    resolver.add(keyed(w));
    final outcomes = <FutureOr<void> Function()>[
      () => throw StateError('broken hook'),
      () => Future<void>.error(StateError('broken hook')),
      () => Completer<void>().future,
    ];
    var calls = 0;
    final statuses = <String>[];
    final set = watch(
      connectTimeout: ms(100),
      onConnect: (peer) {
        if (peer.lastStatus case final status?) {
          statuses.add(status.reason);
        }
        return calls < outcomes.length ? outcomes[calls++]() : null;
      },
    );
    await until(() => set.peers[1]?.isOnline ?? false, 'online');
    expect(calls, 3);
    expect(statuses, [
      'onConnect failed',
      'onConnect failed',
      'onConnect timed out',
    ]);
    expect(log, ['added 1', 'offline 1', 'online 1']);
    // Each failed attempt was a connection of its own, left with GOAWAY.
    expect(w.accepted, hasLength(4));
    for (final connection in w.accepted.take(3)) {
      await connection.done.timeout(limit);
    }
  });

  group('not online until the per-peer channel and onOpen succeeded', () {
    /// A worker (instance 7) whose gpu channels [handler] handles, watched
    /// with [onOpen]: the peer must stay offline with [code], retried, and
    /// onOpen must never run on a channel the worker refused.
    Future<void> staysOffline(
      StatusCode code, {
      void Function(IncomingChannel incoming)? handler,
      Status? reject,
      FutureOr<void> Function(Peer peer, MuxChannel channel)? onOpen,
    }) async {
      final w = await worker(7);
      w
        ..handler = handler
        ..reject = reject;
      resolver.add(keyed(w));
      var onOpenCalls = 0;
      final set = watch(
        channel: ChannelAddress(type: gpu),
        onOpen: (peer, channel) {
          onOpenCalls++;
          return onOpen?.call(peer, channel);
        },
      );
      await until(() => w.accepted.length >= 3, 'retried');
      final peer = set.peers[7]!;
      expect(peer.isOnline, isFalse);
      expect(set.online, isEmpty);
      expect(peer.lastStatus, hasCode(code));
      expect(log, ['added 7', 'offline 7']);
      // Each attempt was a connection of its own, left with GOAWAY.
      for (final connection in w.accepted.take(2)) {
        await connection.done.timeout(limit);
      }
      if (onOpen == null) {
        expect(onOpenCalls, 0);
      } else {
        expect(onOpenCalls, greaterThanOrEqualTo(2));
      }
    }

    test('the worker\'s handler throws', () async {
      await staysOffline(
        StatusCode.internal,
        handler: (incoming) => throw StateError('boom'),
      );
    });

    test('the worker rejects the channel with UNAVAILABLE', () async {
      await staysOffline(
        StatusCode.unavailable,
        reject: Status.of(StatusCode.unavailable, 'not yet'),
      );
    });

    test('onOpen throws', () async {
      await staysOffline(
        StatusCode.internal,
        onOpen: (peer, channel) => throw StateError('caps failed'),
      );
    });

    test('onOpen\'s future fails', () async {
      await staysOffline(
        StatusCode.internal,
        onOpen: (peer, channel) async => throw StateError('caps failed'),
      );
    });
  });

  test('events before resolve are dropped; those while it answers are '
      'folded into its answer', () async {
    final late = _ControlledResolver();
    addTearDown(late.close);
    final set = watch(from: late);
    final seen = <String>[];
    set.events.listen((event) {
      if (event.type != PeerEventType.online &&
          event.type != PeerEventType.offline) {
        seen.add(
          '${event.type.name} ${event.peer.address.instance} '
          '${event.peer.record.endpoints.join(',')}',
        );
      }
    });
    final a = Uri.parse('mem://nobody-a');
    final b = Uri.parse('mem://nobody-b');
    final c = Uri.parse('mem://nobody-c');
    final d = Uri.parse('mem://nobody-d');
    ServiceRecord at(int id, Uri endpoint) =>
        ServiceRecord(ServiceAddress(gpu, id), endpoints: [endpoint]);
    ServiceEvent up(int id, Uri endpoint) =>
        ServiceEvent(up: true, record: at(id, endpoint));
    ServiceEvent down(int id) =>
        ServiceEvent(up: false, record: ServiceRecord(ServiceAddress(gpu, id)));
    // Before resolve is called: its answer has them, they are dropped.
    late.events$
      ..add(up(5, a))
      ..add(down(5))
      ..add(up(6, a))
      ..add(up(6, b));
    late.readyNow.complete();
    await late.called.future;
    // While it answers: folded into the answer.
    late.events$
      ..add(up(7, c))
      ..add(up(6, b))
      ..add(up(9, c))
      ..add(down(9))
      ..add(down(8));
    late.answer.complete([at(6, b), at(8, d)]);
    await set.ready;
    expect(set.peers.keys, [6, 7]);
    // Events are delivered one per microtask: let them all arrive.
    await Future<void>.delayed(ms(20));
    expect(seen, ['added 6 $b', 'added 7 $c']);
    expect(set.peers.keys, [6, 7]);
    // From then on, as they come.
    late.events$.add(down(7));
    await until(() => !set.peers.containsKey(7), 'removed');
    expect(seen.last, 'removed 7 $c');
  });

  test(
    'an error on the resolver\'s events is logged; the set goes on',
    () async {
      final records = <LogRecord>[];
      final logs = Logger.root.onRecord.listen(records.add);
      addTearDown(logs.cancel);
      final source = _ControlledResolver();
      addTearDown(source.close);
      source.readyNow.complete();
      source.answer.complete(const []);
      final set = watch(from: source);
      await set.ready;
      source.events$.addError(StateError('naming hiccup'));
      final w = await worker(1);
      source.events$.add(ServiceEvent(up: true, record: keyed(w)));
      await until(() => set.peers[1]?.isOnline ?? false, 'online');
      expect(
        records.where(
          (r) =>
              r.level == Level.WARNING &&
              r.message.contains('resolver event error') &&
              r.error is StateError,
        ),
        hasLength(1),
      );
      expect(set.isClosed, isFalse);
    },
  );

  test('warnings: no policy for the connections; the default payload to '
      'every peer', () async {
    final records = <String>[];
    final logs = Logger.root.onRecord.listen((r) {
      if (r.level == Level.WARNING && r.message.startsWith('peer set')) {
        records.add(r.message);
      }
    });
    addTearDown(logs.cancel);
    final plain = Switchboard(muxOptions: fast, defaultPayload: meshSecret);
    addTearDown(plain.close);
    final careless = PeerSet.watch(plain, gpu, resolver: resolver);
    addTearDown(careless.close);
    expect(records, hasLength(2));
    expect(records[0], contains('no policy'));
    expect(records[1], contains('credentialFor'));
    records.clear();
    // A policy, and a credential per peer: nothing to say.
    watch(policy: ChannelPolicies.denyAll);
    expect(records, isEmpty);
  });

  group('removal hold-down', () {
    test('a record back within the hold-down: adopted again, connection '
        'and channel kept', () async {
      final w = await worker(1);
      resolver.add(keyed(w));
      final opened = <MuxChannel>[];
      final set = watch(
        channel: ChannelAddress(type: gpu),
        onOpen: (peer, channel) => opened.add(channel),
        removalHoldDown: const Duration(seconds: 5),
      );
      await until(() => set.peers[1]?.isOnline ?? false, 'online');
      final peer = set.peers[1]!;
      final connection = peer.connection;
      final channel = peer.channel;
      resolver.remove(ServiceAddress(gpu, 1));
      await until(() => log.contains('held 1'), 'held');
      expect(peer.state, PeerState.held);
      expect(peer.isOnline, isFalse);
      expect(set.online, isEmpty);
      expect(set.peers[1], same(peer));
      // Still usable for the jobs in flight, and for new ones.
      final talk = await set.openTalk(1);
      expect(text((await talk.request('ECHO', bytes('x'))).payload), '1:x');
      await talk.close();
      resolver.add(keyed(w));
      await until(() => peer.isOnline, 'online again');
      expect(peer.connection, same(connection));
      expect(peer.channel, same(channel));
      expect(opened, hasLength(1));
      // No GOAWAY, no reconnect.
      expect(w.accepted, hasLength(1));
      expect(w.accepted.single.peerGoingAway, isFalse);
      expect(log, ['added 1', 'online 1', 'held 1', 'online 1']);
    });

    test('a record back after the hold-down: removed, then added', () async {
      final w = await worker(1);
      resolver.add(keyed(w));
      final set = watch(removalHoldDown: ms(50));
      await until(() => set.peers[1]?.isOnline ?? false, 'online');
      final peer = set.peers[1]!;
      resolver.remove(ServiceAddress(gpu, 1));
      await until(() => peer.state == PeerState.removed, 'removed');
      expect(set.peers, isEmpty);
      await w.accepted.single.done.timeout(limit);
      resolver.add(keyed(w));
      await until(() => set.peers[1]?.isOnline ?? false, 'online again');
      expect(set.peers[1], isNot(same(peer)));
      expect(w.accepted, hasLength(2));
      expect(log, [
        'added 1',
        'online 1',
        'held 1',
        'removed 1',
        'added 1',
        'online 1',
      ]);
    });

    test('a record back elsewhere: the held peer is removed, a new one '
        'added', () async {
      final w = await worker(1);
      resolver.add(keyed(w));
      final set = watch(removalHoldDown: const Duration(seconds: 5));
      await until(() => set.peers[1]?.isOnline ?? false, 'online');
      final peer = set.peers[1]!;
      resolver.remove(ServiceAddress(gpu, 1));
      await until(() => log.contains('held 1'), 'held');
      final moved = Worker(1);
      await moved.start();
      addTearDown(moved.stop);
      resolver.add(moved.record(metadata: bytes('key-1')));
      await until(() => set.peers[1]?.isOnline ?? false, 'online');
      expect(peer.state, PeerState.removed);
      expect(set.peers[1]!.endpoint, moved.uri);
      await w.accepted.single.done.timeout(limit);
      expect(log, [
        'added 1',
        'online 1',
        'held 1',
        'removed 1',
        'added 1',
        'online 1',
      ]);
    });
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

    test('a hanging hook fails the attempt after connectTimeout', () {
      fakeAsync((async) {
        final resolver = StaticResolver();
        final consumer = Switchboard(muxOptions: fast);
        final w = Worker(1);
        unawaited(w.start());
        async.flushMicrotasks();
        resolver.add(w.record());
        var calls = 0;
        final set = PeerSet.watch(
          consumer,
          gpu,
          resolver: resolver,
          connectTimeout: ms(300),
          initialBackoff: ms(500),
          jitter: 0,
          onConnect: (_) {
            calls++;
            return Completer<void>().future;
          },
        );
        async.elapse(ms(299));
        final peer = set.peers[1]!;
        expect(peer.state, PeerState.connecting);
        expect(peer.connection, isNotNull);
        async.elapse(ms(2));
        expect(peer.state, PeerState.offline);
        expect(peer.lastStatus, hasCode(StatusCode.internal));
        expect(peer.lastStatus!.reason, 'onConnect timed out');
        expect(peer.connection, isNull);
        expect(peer.attempt, 1);
        // Left with GOAWAY; the next attempt after the backoff.
        async.elapse(ms(200));
        expect(w.accepted.single.isOpen, isFalse);
        expect(calls, 1);
        async.elapse(ms(300));
        expect(peer.state, PeerState.connecting);
        expect(peer.attempt, 2);
        expect(calls, 2);
        unawaited(set.close());
        unawaited(w.stop());
        unawaited(consumer.close());
        unawaited(resolver.close());
        async.elapse(const Duration(seconds: 1));
        expect(async.pendingTimers, isEmpty);
      });
    });
  });

  group('a worker\'s GOAWAY on a live connection (fake_async)', () {
    String describe(PeerEvent e) =>
        '${e.type.name}${e.status == null ? '' : ' ${e.status!.known?.name}'}';

    test('offline with its status, online at once on a new connection with '
        'the per-peer channel opened there; the old one drains', () {
      fakeAsync((async) {
        final resolver = StaticResolver();
        final consumer = Switchboard(muxOptions: fast);
        // It waits for the channels on the connection it leaves.
        final w = Worker(1, options: patient);
        unawaited(w.start());
        async.flushMicrotasks();
        resolver.add(w.record());
        final opened = <MuxChannel>[];
        final set = PeerSet.watch(
          consumer,
          gpu,
          resolver: resolver,
          channel: ChannelAddress(type: gpu),
          onOpen: (peer, channel) => opened.add(channel),
          initialBackoff: ms(500),
          maxBackoff: const Duration(seconds: 4),
          jitter: 0,
        );
        final events = <String>[];
        set.events.listen((e) => events.add(describe(e)));
        async.elapse(ms(10));
        final peer = set.peers[1]!;
        expect(peer.isOnline, isTrue);
        final first = peer.connection!;
        var firstClosed = false;
        first.done.then((_) => firstClosed = true).ignore();
        Status? firstChannelEnd;
        peer.channel!.done.then((s) => firstChannelEnd = s).ignore();
        // An application channel on the first connection.
        TalkChannel? talk;
        set.openTalk(1).then((t) => talk = t).ignore();
        async.elapse(ms(10));
        final answers = <String>[];
        void ask(String question) => talk!
            .request('Q', bytes(question))
            .then((m) => answers.add(text(m.payload)))
            .ignore();
        ask('before');
        async.elapse(ms(10));
        expect(answers, ['1:before']);
        // The worker goes away, its connection staying up meanwhile.
        var workerLeft = false;
        w.accepted.single.done.then((_) => workerLeft = true).ignore();
        unawaited(w.goAway());
        async.elapse(ms(10));
        // At once (the backoff is 500 ms), on a new connection.
        expect(peer.isOnline, isTrue);
        expect(peer.connection, isNot(same(first)));
        expect(peer.lastStatus, hasCode(StatusCode.goingAway));
        expect(peer.lastStatus!.reason, 'worker rebooting');
        expect(w.accepted, hasLength(2));
        expect(events, ['added', 'online', 'offline goingAway', 'online']);
        // The per-peer channel was closed GOING_AWAY and opened again on
        // the new connection, onOpen with it.
        expect(firstChannelEnd, hasCode(StatusCode.goingAway));
        expect(opened, hasLength(2));
        expect(peer.channel, same(opened.last));
        expect(w.accepted.last.channels, hasLength(1));
        // The old connection is left to the application's channel.
        expect(w.accepted.first.channels, hasLength(1));
        ask('during');
        async.elapse(ms(10));
        expect(answers, ['1:before', '1:during']);
        expect(firstClosed, isFalse);
        expect(workerLeft, isFalse);
        // Once that channel is closed, it closes.
        unawaited(talk!.close());
        async.elapse(ms(10));
        expect(firstClosed, isTrue);
        expect(workerLeft, isTrue);
        expect(peer.isOnline, isTrue);
        expect(events, hasLength(4));
        unawaited(set.close());
        unawaited(w.stop());
        unawaited(consumer.close());
        unawaited(resolver.close());
        async.elapse(const Duration(seconds: 1));
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('a second GOAWAY before the connection lasted maxBackoff: offline, '
        'the next attempt after the backoff; after a connection that '
        'lasted, at once again', () {
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
          channel: ChannelAddress(type: gpu),
          initialBackoff: ms(500),
          maxBackoff: const Duration(seconds: 4),
          jitter: 0,
        );
        final events = <String>[];
        set.events.listen((e) => events.add(describe(e)));
        async.elapse(ms(10));
        final peer = set.peers[1]!;
        expect(peer.isOnline, isTrue);
        // The first GOAWAY: online again at once.
        unawaited(w.goAway());
        async.elapse(ms(10));
        expect(peer.isOnline, isTrue);
        expect(w.accepted, hasLength(2));
        // The second, 100 ms into that connection: the backoff applies.
        async.elapse(ms(100));
        unawaited(w.goAway());
        async.elapse(ms(10));
        expect(peer.state, PeerState.offline);
        expect(peer.lastStatus, hasCode(StatusCode.goingAway));
        expect(peer.connection, isNull);
        expect(peer.nextAttemptAt, isNotNull);
        async.elapse(ms(480));
        expect(peer.state, PeerState.offline);
        expect(w.accepted, hasLength(2));
        async.elapse(ms(20));
        expect(peer.isOnline, isTrue);
        expect(w.accepted, hasLength(3));
        // That connection lasts beyond maxBackoff: a GOAWAY on it
        // reconnects at once again.
        async.elapse(const Duration(seconds: 5));
        unawaited(w.goAway());
        async.elapse(ms(10));
        expect(peer.isOnline, isTrue);
        expect(w.accepted, hasLength(4));
        expect(events, [
          'added',
          'online',
          'offline goingAway',
          'online',
          'offline goingAway',
          'online',
          'offline goingAway',
          'online',
        ]);
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

/// A resolver the test drives: ready when [readyNow] completes, answering
/// [resolve] with [answer] ([called] completes when it is asked), and its
/// events from [events$].
class _ControlledResolver implements Resolver {
  final Completer<void> readyNow = Completer<void>();
  final Completer<List<ServiceRecord>> answer = Completer();
  final Completer<void> called = Completer<void>();
  final StreamController<ServiceEvent> events$ =
      StreamController<ServiceEvent>.broadcast(sync: true);

  @override
  Future<void> get ready => readyNow.future;

  @override
  Stream<ServiceEvent> get events => events$.stream;

  @override
  Future<List<ServiceRecord>> resolve(Name type) {
    if (!called.isCompleted) {
      called.complete();
    }
    return answer.future;
  }

  @override
  Future<void> close() => events$.close();
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
