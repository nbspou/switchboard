/*
Polyverse Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Authors:
  Jan Boon <jan.boon@kaetemi.be>
  Claude Opus 5.5 <noreply@anthropic.com>
  GPT-6 Astra <noreply@anthropic.com>
*/

// The slot gate state machine: queueing, forwarding, resuming and
// revoking slots, MOVED and RELOCATED fields, bounds, request gating. Incoming
// channels arrive over in-memory mux links; forwarding goes to a node on
// loopback TCP.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:async/async.dart';
import 'package:logging/logging.dart';
import 'package:switchboard/switchboard.dart';
import 'package:test/test.dart';

import 'naming_harness.dart' show Connector, Harness;

const fast = MuxOptions(
  goAwayGrace: Duration(milliseconds: 100),
  keepAliveInterval: null,
);
const quiet = MuxOptions(keepAliveInterval: null);
const limit = Duration(seconds: 5);

final kv = Name('kv');

Uint8List bytes(String text) => Uint8List.fromList(utf8.encode(text));

String text(Uint8List data) => utf8.decode(data);

Matcher hasCode(StatusCode code) =>
    isA<Status>().having((s) => s.known, 'code', code);

Matcher throwsCode(StatusCode code) =>
    throwsA(isA<SwitchboardException>().having((e) => e.code, 'code', code));

/// The messages the gate logs at [level] or above from now on, until the
/// test ends.
List<String> gateLogs(Level level) {
  final records = <String>[];
  final logs = Logger.root.onRecord.listen((r) {
    if (r.loggerName == 'Switchboard.Router' && r.level >= level) {
      records.add(r.message);
    }
  });
  addTearDown(logs.cancel);
  return records;
}

/// A MOVED status naming [owner] at [epoch] (0: unknown).
Matcher isMoved([int owner = 0, int epoch = 0]) => isA<Status>()
    .having((s) => s.known, 'code', StatusCode.moved)
    .having(MovedStatus.fromStatus, 'fields', fields(owner, epoch));

/// A RELOCATED status naming [owner] at [epoch].
Matcher isRelocated([int owner = 0, int epoch = 0]) => isA<Status>()
    .having((s) => s.known, 'code', StatusCode.relocated)
    .having(MovedStatus.fromStatus, 'fields', fields(owner, epoch));

Matcher fields(int owner, int epoch) => isA<MovedStatus>()
    .having((m) => m.owner, 'owner', owner)
    .having((m) => m.epoch, 'epoch', epoch);

Future<void> until(bool Function() condition) async {
  final deadline = DateTime.now().add(limit);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition not met within $limit');
    }
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

/// Lets pending microtasks and short timers run.
Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 5));

/// A scriptable lifecycle that records every call.
class TestLifecycle extends SlotLifecycle {
  final List<String> log = [];
  Completer<void>? loadGate;
  Completer<void>? drainGate;
  Completer<void>? unloadGate;
  Object? loadError;
  AssignResult result = AssignResult.holding;

  /// Served channels, by slot, in arrival order.
  final Map<int, List<IncomingChannel>> served = {};

  /// Called for every served channel, its result returned by [serve]; the
  /// default echoes `slot:data`.
  FutureOr<void> Function(IncomingChannel channel, int slot)? onServe;

  /// The contexts of the latest load and drain.
  SlotRequestContext? loadContext;
  SlotRequestContext? drainContext;

  @override
  Future<AssignResult> load(
    int slot, {
    required int epoch,
    required int holder,
    required bool shared,
    SlotRequestContext? context,
  }) async {
    log.add('load $slot e$epoch h$holder${shared ? ' shared' : ''}');
    loadContext = context;
    await loadGate?.future;
    final error = loadError;
    if (error != null) {
      throw error;
    }
    return result;
  }

  @override
  Future<void> drain(
    int slot, {
    required int epoch,
    required int to,
    SlotRequestContext? context,
  }) async {
    log.add('drain $slot e$epoch to$to');
    drainContext = context;
    await drainGate?.future;
  }

  @override
  Future<void> unload(int slot) async {
    log.add('unload $slot');
    await unloadGate?.future;
  }

  @override
  FutureOr<void> serve(IncomingChannel channel, int slot) {
    log.add('serve $slot ${text(channel.address.payload)}');
    (served[slot] ??= []).add(channel);
    final hook = onServe;
    if (hook != null) {
      return hook(channel, slot);
    }
    channel.channel.stream.listen(
      (data) => channel.channel.send(bytes('$slot:${text(data)}')),
    );
  }
}

/// A request context that records what is declared through it.
class RecordingContext implements SlotRequestContext {
  RecordingContext(this.type, this.slot, this.epoch);

  @override
  final Name type;

  @override
  final int slot;

  @override
  final int epoch;

  final List<(Duration?, Duration?)> declared = [];
  final Completer<void> cancelled = Completer<void>();

  @override
  bool get isCancelled => cancelled.isCompleted;

  @override
  Future<void> get onCancel => cancelled.future;

  @override
  void extend({Duration? deadline, Duration? renew}) =>
      declared.add((deadline, renew));
}

/// Holds forwarding opens so their queue and cancellation can be inspected,
/// or fails them before returning a future.
class DelayedResolver extends StaticResolver {
  DelayedResolver(super.records);

  final Completer<void> proceed = Completer<void>();

  /// [resolve] throws at once instead of returning a future.
  bool throwAtOnce = false;

  @override
  Future<List<ServiceRecord>> resolve(Name type) {
    if (throwAtOnce) {
      throw SwitchboardException.of(StatusCode.unavailable, 'resolver down');
    }
    return proceed.future.then((_) => super.resolve(type));
  }
}

/// A peer linked to the gate's dispatch over memory; bulk channels go to
/// their parent's Talk layer, as a Switchboard routes them.
class Peer {
  Peer(this.gate) {
    final (a, b) = MemoryTransport.pair();
    client = MuxConnection(a, isInitiator: true, options: quiet);
    server = MuxConnection(b, isInitiator: false, options: quiet);
    server.incoming.listen((channel) {
      if (_isBulk(channel)) {
        TalkChannel.adoptBulk(channel);
        return;
      }
      final result = gate.handler(IncomingChannel(channel));
      if (result is Future<void>) {
        result.ignore();
      }
    });
    client.incoming.listen((channel) {
      if (_isBulk(channel)) {
        TalkChannel.adoptBulk(channel);
      } else {
        unawaited(channel.close(Status.of(StatusCode.notFound)));
      }
    });
  }

  static bool _isBulk(MuxChannel channel) =>
      TalkBulkOpen.isBulk(ChannelAddress.decode(channel.openPayload));

  final SlotGate gate;
  late final MuxConnection client;
  late final MuxConnection server;

  MuxChannel open({int? shard, String payload = 'cred', int instance = 1}) =>
      client.open(
        ChannelAddress(
          type: kv,
          instance: instance,
          shard: shard,
          payload: bytes(payload),
        ).encode(),
      );

  Future<void> close() async {
    await client.close();
    await server.close();
  }
}

/// Sends [message] and returns the first answer.
Future<String> ask(MuxChannel channel, String message) async {
  final answer = channel.stream.first;
  unawaited(channel.send(bytes(message)));
  return text(await answer.timeout(limit));
}

AssignRequest assign(int slot, {int epoch = 1, int holder = 0}) =>
    AssignRequest(kv, slot, epoch: epoch, holder: holder, shared: false);

void main() {
  late NamingClient client;
  late Switchboard node;
  late Switchboard target;
  late Uri targetUri;
  late TestLifecycle lifecycle;
  late SlotGate gate;
  late Peer peer;

  /// Channels the target node (`kv/2`) received.
  late List<IncomingChannel> arrived;

  SlotGate newGate({
    Duration forwardGrace = const Duration(seconds: 5),
    Duration drainTimeout = limit,
    int maxQueuedChannels = 1024,
    int maxQueuedRequests = 1024,
    bool trackChannels = true,
    ChannelHandler? noSlotHandler,
  }) {
    lifecycle = TestLifecycle();
    gate = SlotGate(
      node,
      client,
      kv,
      lifecycle: lifecycle,
      forwardGrace: forwardGrace,
      drainTimeout: drainTimeout,
      maxQueuedChannels: maxQueuedChannels,
      maxQueuedRequests: maxQueuedRequests,
      trackChannels: trackChannels,
      noSlotHandler: noSlotHandler,
      instance: 1,
    );
    peer = Peer(gate);
    addTearDown(peer.close);
    // Closing cancels the timers of forwarding slots (forwardGrace).
    addTearDown(gate.close);
    return gate;
  }

  setUp(() async {
    client = NamingClient(() async => throw StateError('not connected'));
    target = Switchboard(muxOptions: fast);
    arrived = [];
    target.registerService(kv, (incoming) {
      arrived.add(incoming);
      incoming.channel.stream.listen(
        (data) => incoming.channel.send(bytes('to:${text(data)}')),
      );
    }, instance: 2);
    targetUri = await target.listenTcp(InternetAddress.loopbackIPv4, 0);
    node = Switchboard(
      muxOptions: fast,
      resolver: StaticResolver([
        ServiceRecord(ServiceAddress(kv, 2), endpoints: [targetUri]),
      ]),
    );
  });

  tearDown(() async {
    await client.close();
    await node.close();
    await target.close();
  });

  group('dispatch', () {
    test('no shard: noSlotHandler, else INVALID_ARGUMENT', () async {
      newGate();
      final refused = peer.open();
      expect(await refused.done, hasCode(StatusCode.invalidArgument));
      final seen = <String>[];
      gate.noSlotHandler = (incoming) {
        seen.add(text(incoming.address.payload));
        unawaited(incoming.channel.close());
      };
      expect(await peer.open(payload: 'xfer').done, Status.ok);
      expect(seen, ['xfer']);
    });

    test('a slot not served here: MOVED, no owner without a mirror', () {
      newGate();
      expect(peer.open(shard: 3).done, completion(isMoved()));
      expect(gate.stateOf(3), isNull);
    });

    test('ASSIGN loads, then channels are served', () async {
      newGate();
      expect(
        await gate.onAssign(assign(3, epoch: 4, holder: 7)),
        AssignResult.holding,
      );
      expect(gate.serves(3), isTrue);
      expect(gate.servedSlots, {3: 4});
      expect(await ask(peer.open(shard: 3), 'hi'), '3:hi');
      expect(lifecycle.log, ['load 3 e4 h7', 'serve 3 cred']);
    });

    test('channels wait while loading, in order', () async {
      newGate();
      lifecycle.loadGate = Completer<void>();
      final assigned = gate.onAssign(assign(1));
      await settle();
      expect(gate.stateOf(1), SlotGateState.loading);
      final a = peer.open(shard: 1, payload: 'a');
      final b = peer.open(shard: 1, payload: 'b');
      unawaited(a.send(bytes('x')));
      await settle();
      expect(lifecycle.served, isEmpty);
      lifecycle.loadGate!.complete();
      await assigned;
      expect(text(await a.stream.first.timeout(limit)), '1:x');
      expect(await ask(b, 'y'), '1:y');
      expect(lifecycle.log, ['load 1 e1 h0', 'serve 1 a', 'serve 1 b']);
    });

    test(
      'revocation from serve refuses the rest of the released queue',
      () async {
        newGate();
        lifecycle.loadGate = Completer<void>();
        final assigned = gate.onAssign(assign(1));
        final a = peer.open(shard: 1, payload: 'a');
        final b = peer.open(shard: 1, payload: 'b');
        await settle();
        lifecycle.onServe = (_, slot) => gate.onRevoke(kv, slot);
        lifecycle.loadGate!.complete();
        await assigned;
        expect(lifecycle.served[1], hasLength(1));
        expect(await a.done.timeout(limit), isRelocated());
        expect(await b.done.timeout(limit), isMoved());
      },
    );

    test('a revoked load must finish cleanup before another ASSIGN', () async {
      newGate();
      final hold = lifecycle.loadGate = Completer<void>();
      addTearDown(() {
        if (!hold.isCompleted) hold.complete();
      });
      final loading = gate.onAssign(assign(1));
      loading.ignore();
      await gate.onRevoke(kv, 1);
      lifecycle.loadGate = null;
      await expectLater(
        gate.onAssign(assign(1, epoch: 2)),
        throwsCode(StatusCode.unavailable),
      );
      hold.complete();
      await expectLater(loading, throwsCode(StatusCode.unavailable));
      await gate.onAssign(assign(1, epoch: 2));
      expect(lifecycle.log, ['load 1 e1 h0', 'unload 1', 'load 1 e2 h0']);
      expect(await ask(peer.open(shard: 1), 'x'), '1:x');
    });

    test('a new gate on the lifecycle refuses the slots its closed gate is '
        'still loading, and only those', () async {
      newGate();
      final hold = lifecycle.loadGate = Completer<void>();
      addTearDown(() {
        if (!hold.isCompleted) hold.complete();
      });
      final loading = gate.onAssign(assign(1));
      loading.ignore();
      await gate.close();
      // A failed publishSharded can be repeated with the same lifecycle.
      final next = SlotGate(node, client, kv, lifecycle: lifecycle);
      addTearDown(next.close);
      expect(lifecycle.gate, same(next));
      lifecycle.loadGate = null;
      await expectLater(
        next.onAssign(assign(1, epoch: 2)),
        throwsCode(StatusCode.unavailable),
      );
      await next.onAssign(assign(2));
      expect(next.serves(2), isTrue);
      hold.complete();
      await expectLater(loading, throwsCode(StatusCode.unavailable));
      await next.onAssign(assign(1, epoch: 2));
      expect(next.serves(1), isTrue);
      expect(lifecycle.log, [
        'load 1 e1 h0',
        'load 2 e1 h0',
        'unload 1',
        'load 1 e2 h0',
      ]);
    });

    test('an unload must finish before another ASSIGN', () async {
      newGate();
      await gate.onAssign(assign(1));
      final hold = lifecycle.unloadGate = Completer<void>();
      addTearDown(() {
        if (!hold.isCompleted) hold.complete();
      });
      final revoking = gate.onRevoke(kv, 1);
      await expectLater(
        gate.onAssign(assign(1, epoch: 2)),
        throwsCode(StatusCode.unavailable),
      );
      hold.complete();
      await revoking;
      await gate.onAssign(assign(1, epoch: 2));
      expect(gate.serves(1), isTrue);
    });

    test('closing during reassignment unload prevents the new load', () async {
      newGate();
      await gate.onAssign(assign(1));
      await gate.onForward(ForwardRequest(kv, 1, epoch: 2, to: 2));
      final hold = lifecycle.unloadGate = Completer<void>();
      addTearDown(() {
        if (!hold.isCompleted) hold.complete();
      });
      final loading = gate.onAssign(assign(1, epoch: 3));
      loading.ignore();
      await gate.close();
      hold.complete();
      await expectLater(loading, throwsCode(StatusCode.unavailable));
      expect(lifecycle.log, ['load 1 e1 h0', 'unload 1']);
    });

    test(
      'a cancelled ASSIGN cannot serve its queue when load completes',
      () async {
        newGate();
        final context = RecordingContext(kv, 1, 1);
        final hold = lifecycle.loadGate = Completer<void>();
        final loading = gate.onAssign(assign(1), context);
        loading.ignore();
        final queued = peer.open(shard: 1);
        await settle();
        context.cancelled.complete();
        hold.complete();
        await expectLater(loading, throwsCode(StatusCode.cancelled));
        expect(await queued.done.timeout(limit), isMoved());
        expect(lifecycle.served, isEmpty);
        expect(gate.serves(1), isFalse);
        expect(lifecycle.log, ['load 1 e1 h0', 'unload 1']);
      },
    );

    test('a failed load refuses the queue and fails ASSIGN', () async {
      newGate();
      lifecycle
        ..loadGate = Completer<void>()
        ..loadError = SwitchboardException.of(StatusCode.unavailable, 'no');
      final assigned = gate.onAssign(assign(1));
      await settle();
      final queued = peer.open(shard: 1);
      await settle();
      lifecycle.loadGate!.complete();
      await expectLater(
        assigned,
        throwsA(
          isA<SwitchboardException>().having(
            (e) => e.code,
            'code',
            StatusCode.unavailable,
          ),
        ),
      );
      expect(await queued.done, isMoved());
      expect(gate.stateOf(1), isNull);
    });

    test('a slot outside the mirrored space: OUT_OF_RANGE', () async {
      final h = Harness();
      addTearDown(h.close);
      client = NamingClient(Connector(h).call);
      await client.start();
      await client.synced.timeout(limit);
      await client.defineSlots(
        kv,
        count: 4,
        mode: SlotMode.static,
        capacity: 0,
      );
      await until(() => client.slotTable(kv) != null);
      newGate();
      expect(await peer.open(shard: 4).done, hasCode(StatusCode.outOfRange));
      expect(await peer.open(shard: 3).done, isMoved());
    });

    test('channels beyond maxQueuedChannels: UNAVAILABLE', () async {
      newGate(maxQueuedChannels: 2);
      lifecycle.loadGate = Completer<void>();
      final assigned = gate.onAssign(assign(1));
      await settle();
      final a = peer.open(shard: 1, payload: 'a');
      final b = peer.open(shard: 1, payload: 'b');
      final c = peer.open(shard: 1, payload: 'c');
      expect(await c.done, hasCode(StatusCode.unavailable));
      // A queued channel its peer closes leaves the queue.
      await a.close();
      await settle();
      final d = peer.open(shard: 1, payload: 'd');
      lifecycle.loadGate!.complete();
      await assigned;
      expect(await ask(b, 'x'), '1:x');
      expect(await ask(d, 'y'), '1:y');
      expect(lifecycle.log, ['load 1 e1 h0', 'serve 1 b', 'serve 1 d']);
    });

    test('a throwing serve closes the channel with INTERNAL', () async {
      newGate();
      lifecycle.onServe = (_, _) => throw StateError('boom');
      await gate.onAssign(assign(1));
      expect(await peer.open(shard: 1).done, hasCode(StatusCode.internal));
    });

    test('an async serve that fails after an await closes the channel with '
        'INTERNAL; the error does not escape', () async {
      final severe = gateLogs(Level.SEVERE);
      final escaped = <Object>[];
      // Channels are dispatched in a guarded zone: an error the gate let
      // escape would land there.
      runZonedGuarded(newGate, (e, _) => escaped.add(e));
      var calls = 0;
      lifecycle.onServe = (channel, slot) async {
        calls++;
        await settle();
        throw StateError('async boom');
      };
      await gate.onAssign(assign(1));
      expect(
        await peer.open(shard: 1).done.timeout(limit),
        hasCode(StatusCode.internal),
      );
      // A queued channel, served by RESUME rather than by the dispatch.
      await gate.onDrain(DrainRequest(kv, 1, epoch: 2, to: 2));
      final queued = peer.open(shard: 1);
      await settle();
      await gate.onResume(ResumeRequest(kv, 1, epoch: 1));
      expect(await queued.done.timeout(limit), hasCode(StatusCode.internal));
      expect(calls, 2);
      await settle();
      expect(escaped, isEmpty);
      expect(severe, hasLength(2));
      expect(severe, everyElement(contains('failed')));
      // The gate goes on serving.
      lifecycle.onServe = null;
      expect(await ask(peer.open(shard: 1), 'x'), '1:x');
      expect(gate.serves(1), isTrue);
    });
  });

  group('hand-over', () {
    test('DRAIN waits for tracked channels, then drains', () async {
      newGate();
      await gate.onAssign(assign(1));
      final busy = peer.open(shard: 1, payload: 'busy');
      expect(await ask(busy, 'x'), '1:x');
      final drained = gate.onDrain(DrainRequest(kv, 1, epoch: 2, to: 2));
      await settle();
      expect(gate.stateOf(1), SlotGateState.locked);
      expect(lifecycle.log, isNot(contains('drain 1 e2 to2')));
      // New channels are queued meanwhile, unread.
      final late = peer.open(shard: 1, payload: 'late');
      unawaited(late.send(bytes('queued')));
      await settle();
      expect(lifecycle.served[1], hasLength(1));
      await busy.close();
      await drained.timeout(limit);
      expect(lifecycle.log.last, 'drain 1 e2 to2');
      // RESUME serves the queue here, with what it sent meanwhile.
      await gate.onResume(ResumeRequest(kv, 1, epoch: 1));
      expect(gate.serves(1), isTrue);
      expect(text(await late.stream.first.timeout(limit)), '1:queued');
      expect(lifecycle.log.last, 'serve 1 late');
    });

    test('DRAIN declares its wait for work in flight, a second longer, '
        'then restarts the default timeout; load and drain get the '
        'context', () async {
      newGate();
      final loading = RecordingContext(kv, 1, 1);
      await gate.onAssign(assign(1), loading);
      expect(lifecycle.loadContext, same(loading));
      expect(loading.declared, isEmpty);
      final busy = peer.open(shard: 1, payload: 'busy');
      expect(await ask(busy, 'x'), '1:x');
      final draining = RecordingContext(kv, 1, 2);
      final drained = gate.onDrain(
        DrainRequest(kv, 1, epoch: 2, to: 2),
        draining,
      );
      await settle();
      final declared = limit + const Duration(seconds: 1);
      expect(draining.declared, [(declared, null)]);
      await busy.close();
      await drained.timeout(limit);
      expect(lifecycle.drainContext, same(draining));
      // The drain gets the naming service's default timeout again.
      expect(draining.declared, [(declared, null), (null, null)]);
      // Nothing in flight: nothing to declare.
      await gate.onResume(ResumeRequest(kv, 1, epoch: 1));
      final idle = RecordingContext(kv, 1, 3);
      await gate
          .onDrain(DrainRequest(kv, 1, epoch: 3, to: 2), idle)
          .timeout(limit);
      expect(idle.declared, isEmpty);
      expect(lifecycle.drainContext, same(idle));
    });

    test('a DRAIN cancelled while it waits for work in flight stops '
        'waiting, closes nothing and does not drain', () async {
      newGate();
      await gate.onAssign(assign(1));
      final busy = peer.open(shard: 1, payload: 'busy');
      final answers = StreamQueue(busy.stream.map(text));
      unawaited(busy.send(bytes('x')));
      expect(await answers.next.timeout(limit), '1:x');
      final draining = RecordingContext(kv, 1, 2);
      final drained = expectLater(
        gate.onDrain(DrainRequest(kv, 1, epoch: 2, to: 2), draining),
        throwsCode(StatusCode.cancelled),
      );
      await settle();
      draining.cancelled.complete();
      // Well before drainTimeout (5 s).
      await drained.timeout(const Duration(seconds: 2));
      expect(lifecycle.log, isNot(contains('drain 1 e2 to2')));
      expect(busy.canSend, isTrue);
      expect(gate.stateOf(1), SlotGateState.locked);
      await gate.onResume(ResumeRequest(kv, 1, epoch: 1));
      unawaited(busy.send(bytes('y')));
      expect(await answers.next.timeout(limit), '1:y');
      await answers.cancel(immediate: true);
    });

    test('detached channels do not hold DRAIN', () async {
      newGate();
      lifecycle.onServe = (channel, slot) => gate.detach(channel);
      await gate.onAssign(assign(1));
      final long = peer.open(shard: 1, payload: 'long');
      await until(() => lifecycle.served[1]?.length == 1);
      // Held, it would wait for drainTimeout (5 s).
      await gate
          .onDrain(DrainRequest(kv, 1, epoch: 2, to: 2))
          .timeout(const Duration(seconds: 2));
      expect(lifecycle.log.last, 'drain 1 e2 to2');
      expect(long.canSend, isTrue);
    });

    test('a tracked channel holds DRAIN at most drainTimeout, then is '
        'closed with RELOCATED before the drain', () async {
      newGate(drainTimeout: const Duration(milliseconds: 30));
      lifecycle.onServe = (_, _) {};
      await gate.onAssign(assign(1));
      final stuck = peer.open(shard: 1, payload: 'stuck');
      await until(() => lifecycle.served[1]?.length == 1);
      final watch = Stopwatch()..start();
      lifecycle.drainGate = Completer<void>();
      final drained = gate.onDrain(DrainRequest(kv, 1, epoch: 2, to: 2));
      await until(() => lifecycle.log.last == 'drain 1 e2 to2');
      expect(watch.elapsed, greaterThanOrEqualTo(Duration(milliseconds: 25)));
      // Closed while drain still runs, naming the new owner and epoch.
      expect(await stuck.done.timeout(limit), isRelocated(2, 2));
      lifecycle.drainGate!.complete();
      await drained;
      expect(gate.stateOf(1), SlotGateState.locked);
    });

    test('after DRAIN gave up waiting, the old owner serves nothing more on '
        'the channel', () async {
      // The channel outlives drainTimeout; it must not be served on state
      // that is handed over (wiki: "The hand-over, step by step").
      newGate(
        drainTimeout: const Duration(milliseconds: 30),
        forwardGrace: const Duration(seconds: 2),
      );
      await gate.onAssign(assign(1));
      final stuck = peer.open(shard: 1, payload: 'stuck');
      final answers = StreamQueue(stuck.stream.map(text));
      unawaited(stuck.send(bytes('before')));
      expect(await answers.next.timeout(limit), '1:before');
      await gate.onDrain(DrainRequest(kv, 1, epoch: 2, to: 2));
      await gate.onForward(ForwardRequest(kv, 1, epoch: 2, to: 2));
      expect(gate.stateOf(1), SlotGateState.forwarding);
      expect(await stuck.done.timeout(limit), isRelocated(2, 2));
      if (stuck.canSend) {
        unawaited(stuck.send(bytes('after-forward')));
      }
      expect(await answers.hasNext.timeout(limit), isFalse);
      await settle();
      expect(lifecycle.served[1], hasLength(1));
      expect(arrived, isEmpty);
    });

    test('FORWARD pipes the queue to the new owner in order, and late '
        'arrivals too', () async {
      newGate();
      await gate.onAssign(assign(1));
      await gate.onDrain(DrainRequest(kv, 1, epoch: 2, to: 2));
      final first = peer.open(shard: 1, payload: 'first');
      final second = peer.open(shard: 1, payload: 'second');
      unawaited(first.send(bytes('a')));
      unawaited(second.send(bytes('b')));
      await settle();
      await gate.onForward(ForwardRequest(kv, 1, epoch: 2, to: 2));
      expect(gate.stateOf(1), SlotGateState.forwarding);
      expect(text(await first.stream.first.timeout(limit)), 'to:a');
      final answers = StreamQueue(second.stream.map(text));
      unawaited(second.send(bytes('c')));
      expect(await answers.take(2).timeout(limit), ['to:b', 'to:c']);
      // In arrival order, with the open payload except the instance.
      expect(
        [for (final c in arrived) text(c.address.payload)],
        ['first', 'second'],
      );
      expect(arrived.first.address.instance, 2);
      expect(arrived.first.address.shard, 1);
      // Late arrivals are forwarded during the grace period.
      expect(await ask(peer.open(shard: 1, payload: 'late'), 'd'), 'to:d');
      expect(gate.movedStatus(1), isMoved(2, 2));
      expect(gate.servedSlots, isEmpty);
      expect(lifecycle.log, isNot(contains('unload 1')));
    });

    test(
      'forwarding opens remain bounded while resolution is stalled',
      () async {
        final resolver = DelayedResolver([
          ServiceRecord(ServiceAddress(kv, 2), endpoints: [targetUri]),
        ]);
        node.resolver = resolver;
        addTearDown(resolver.close);
        addTearDown(() {
          if (!resolver.proceed.isCompleted) resolver.proceed.complete();
        });
        newGate(maxQueuedChannels: 1);
        await gate.onAssign(assign(1));
        await gate.onForward(ForwardRequest(kv, 1, epoch: 2, to: 2));
        final first = peer.open(shard: 1);
        await settle();
        await first.close();
        // Closing and opening again cannot accumulate unbounded pending
        // resolver calls or continuations outside the mux channel limit.
        final excess = peer.open(shard: 1);
        expect(
          await excess.done.timeout(limit),
          hasCode(StatusCode.unavailable),
        );
        resolver.proceed.complete();
        await node.connect(targetUri);
        await settle();
        expect(await ask(peer.open(shard: 1), 'new'), 'to:new');
      },
    );

    test('a forwarding open that fails at once gives its place back', () async {
      final resolver = DelayedResolver([
        ServiceRecord(ServiceAddress(kv, 2), endpoints: [targetUri]),
      ])..throwAtOnce = true;
      resolver.proceed.complete();
      node.resolver = resolver;
      addTearDown(resolver.close);
      newGate(maxQueuedChannels: 1);
      await gate.onAssign(assign(1));
      await gate.onForward(ForwardRequest(kv, 1, epoch: 2, to: 2));
      for (var i = 0; i < 3; i++) {
        expect(
          await peer.open(shard: 1).done.timeout(limit),
          hasCode(StatusCode.unavailable),
        );
      }
      // Refused by the bound if a failed open had kept its place.
      resolver.throwAtOnce = false;
      expect(await ask(peer.open(shard: 1), 'new'), 'to:new');
    });

    test('after the grace period: unload, then MOVED', () async {
      newGate(forwardGrace: const Duration(milliseconds: 30));
      await gate.onAssign(assign(1));
      await gate.onDrain(DrainRequest(kv, 1, epoch: 2, to: 2));
      final queued = peer.open(shard: 1);
      final answers = StreamQueue(queued.stream.map(text));
      unawaited(queued.send(bytes('a')));
      await settle();
      await gate.onForward(ForwardRequest(kv, 1, epoch: 2, to: 2));
      await until(() => gate.stateOf(1) == null);
      expect(lifecycle.log.last, 'unload 1');
      // The mirror knows nothing here: MOVED with an empty reason.
      expect(await peer.open(shard: 1).done, isMoved());
      // A forwarded channel keeps working after the grace period.
      expect(await answers.next.timeout(limit), 'to:a');
      unawaited(queued.send(bytes('b')));
      expect(await answers.next.timeout(limit), 'to:b');
    });

    test('the RELOCATED status names the new owner while forwarding', () async {
      newGate();
      await gate.onAssign(assign(1));
      expect(gate.relocatedStatus(1), isRelocated());
      await gate.onDrain(DrainRequest(kv, 1, epoch: 2, to: 2));
      await gate.onForward(ForwardRequest(kv, 1, epoch: 2, to: 2));
      expect(gate.movedTo(1), MovedStatus(owner: 2, epoch: 2));
      expect(gate.relocatedStatus(1), isRelocated(2, 2));
      expect(gate.movedStatus(1), isMoved(2, 2));
    });

    test('a slot coming back during the grace period: forwarding stops, it '
        'is unloaded, then loaded and served here', () async {
      newGate(forwardGrace: const Duration(milliseconds: 50));
      await gate.onAssign(assign(1));
      await gate.onDrain(DrainRequest(kv, 1, epoch: 2, to: 2));
      await gate.onForward(ForwardRequest(kv, 1, epoch: 2, to: 2));
      expect(await ask(peer.open(shard: 1, payload: 'late'), 'a'), 'to:a');
      await gate.onAssign(assign(1, epoch: 3, holder: 2));
      expect(gate.serves(1), isTrue);
      expect(gate.servedSlots, {1: 3});
      expect(lifecycle.log.skip(2), ['unload 1', 'load 1 e3 h2']);
      expect(await ask(peer.open(shard: 1), 'x'), '1:x');
      // Past the grace period it was handed over with: still served here,
      // nothing more forwarded or unloaded.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(await ask(peer.open(shard: 1, payload: 'after'), 'y'), '1:y');
      expect(gate.servedSlots, {1: 3});
      expect(arrived, hasLength(1));
      expect(lifecycle.log.where((l) => l == 'unload 1'), hasLength(1));
    });

    test('ASSIGN of a slot served already only updates the epoch', () async {
      newGate();
      lifecycle.result = AssignResult.notHolding;
      await gate.onAssign(assign(1));
      expect(await gate.onAssign(assign(1, epoch: 9)), AssignResult.notHolding);
      expect(gate.servedSlots, {1: 9});
      expect(lifecycle.log, ['load 1 e1 h0']);
    });

    test('ASSIGN of a slot still locked after a lost RESUME unlocks it with '
        'the new epoch and serves its queue here', () async {
      final infos = gateLogs(Level.INFO);
      newGate();
      await gate.onAssign(assign(1, holder: 1));
      await gate.onDrain(DrainRequest(kv, 1, epoch: 2, to: 2));
      final queued = peer.open(shard: 1, payload: 'queued');
      unawaited(queued.send(bytes('a')));
      await settle();
      expect(lifecycle.served, isEmpty);
      // The migration to 2 failed, its RESUME (epoch 1) never arrived, and
      // the slot, free at epoch 1, is assigned back here at epoch 2.
      expect(
        await gate.onAssign(assign(1, epoch: 2, holder: 1)),
        AssignResult.holding,
      );
      expect(gate.stateOf(1), SlotGateState.serving);
      expect(gate.servedSlots, {1: 2});
      expect(text(await queued.stream.first.timeout(limit)), '1:a');
      expect(await ask(peer.open(shard: 1, payload: 'new'), 'b'), '1:b');
      // Served on the state it has: not unloaded nor loaded again, nothing
      // forwarded.
      expect(lifecycle.log, [
        'load 1 e1 h1',
        'drain 1 e2 to2',
        'serve 1 queued',
        'serve 1 new',
      ]);
      expect(arrived, isEmpty);
      expect(infos, [contains('RESUME lost')]);
      // A RESUME arriving late changes nothing.
      await gate.onResume(ResumeRequest(kv, 1, epoch: 1));
      expect(gate.servedSlots, {1: 2});
    });

    test('ASSIGN of a slot locked while another instance owned it since '
        'refuses its queue with MOVED, unloads, then loads', () async {
      newGate();
      await gate.onAssign(assign(1, holder: 1));
      await gate.onDrain(DrainRequest(kv, 1, epoch: 2, to: 2));
      final queued = peer.open(shard: 1, payload: 'queued');
      await settle();
      // Owned by 2 at epoch 2, handed back at epoch 3: the state is there.
      await gate.onAssign(assign(1, epoch: 3, holder: 2));
      expect(await queued.done.timeout(limit), isMoved());
      expect(gate.servedSlots, {1: 3});
      expect(lifecycle.log.skip(2), ['unload 1', 'load 1 e3 h2']);
      expect(await ask(peer.open(shard: 1), 'x'), '1:x');
    });

    test('revocation refuses the queue with MOVED and closes served channels '
        'with RELOCATED', () async {
      newGate();
      await gate.onAssign(assign(1));
      final served = peer.open(shard: 1);
      expect(await ask(served, 'x'), '1:x');
      // DRAIN waits for the served channel; the revocation ends it.
      final drained = expectLater(
        gate.onDrain(DrainRequest(kv, 1, epoch: 2, to: 2)),
        throwsA(
          isA<SwitchboardException>().having(
            (e) => e.code,
            'code',
            StatusCode.unavailable,
          ),
        ),
      );
      final queued = peer.open(shard: 1);
      await settle();
      await gate.onRevoke(kv, 1);
      expect(await queued.done, isMoved());
      expect(await served.done, isRelocated());
      expect(lifecycle.log.last, 'unload 1');
      expect(gate.stateOf(1), isNull);
      await drained;
      expect(lifecycle.log, isNot(contains('drain 1 e2 to2')));
    });

    test('DRAIN of a slot not served: FAILED_PRECONDITION', () {
      newGate();
      expect(
        gate.onDrain(DrainRequest(kv, 1, epoch: 2, to: 2)),
        throwsA(
          isA<SwitchboardException>().having(
            (e) => e.code,
            'code',
            StatusCode.failedPrecondition,
          ),
        ),
      );
    });

    test('DRAIN naming no instance or this one: FAILED_PRECONDITION, the '
        'slot goes on being served', () async {
      final warnings = gateLogs(Level.WARNING);
      newGate();
      await gate.onAssign(assign(1));
      final served = peer.open(shard: 1);
      final answers = StreamQueue(served.stream.map(text));
      unawaited(served.send(bytes('x')));
      expect(await answers.next.timeout(limit), '1:x');
      for (final to in [0, 1]) {
        await expectLater(
          gate.onDrain(DrainRequest(kv, 1, epoch: 2, to: to)),
          throwsCode(StatusCode.failedPrecondition),
        );
      }
      expect(gate.serves(1), isTrue);
      unawaited(served.send(bytes('y')));
      expect(await answers.next.timeout(limit), '1:y');
      expect(lifecycle.log, isNot(contains(startsWith('drain'))));
      expect(warnings, [contains('DRAIN'), contains('DRAIN')]);
    });

    test('FORWARD naming this instance: FAILED_PRECONDITION, nothing piped '
        'back into this node, the queue refused with MOVED', () async {
      final warnings = gateLogs(Level.WARNING);
      newGate();
      // The new owner named is this instance, whose record is this node's
      // own listener, where the gate is registered: forwarding there would
      // dispatch the queued channel into this gate again, a loop.
      final self = await node.listenMemory();
      final resolver = StaticResolver([
        ServiceRecord(ServiceAddress(kv, 1), endpoints: [self]),
      ]);
      addTearDown(resolver.close);
      node.resolver = resolver;
      var arrivals = 0;
      node.registerService(kv, (incoming) {
        arrivals++;
        return gate.handler(incoming);
      }, instance: 1);
      await gate.onAssign(assign(1));
      await gate.onDrain(DrainRequest(kv, 1, epoch: 2, to: 2));
      final queued = peer.open(shard: 1);
      await settle();
      await expectLater(
        gate.onForward(ForwardRequest(kv, 1, epoch: 2, to: 1)),
        throwsCode(StatusCode.failedPrecondition),
      );
      // Never read here: MOVED. The naming client dropped the slot on
      // FORWARD, so the gate stops serving it.
      expect(await queued.done.timeout(limit), isMoved());
      expect(gate.stateOf(1), isNull);
      expect(lifecycle.log.last, 'unload 1');
      expect(await peer.open(shard: 1).done.timeout(limit), isMoved());
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(arrivals, 0);
      expect(lifecycle.served, isEmpty);
      // No instance: refused as well, even for a slot not here.
      await expectLater(
        gate.onForward(ForwardRequest(kv, 2, epoch: 2, to: 0)),
        throwsCode(StatusCode.failedPrecondition),
      );
      expect(warnings, [contains('FORWARD'), contains('FORWARD')]);
    });

    test(
      'a new owner whose record is this node\'s own listener: nothing '
      'is forwarded there, the queue and late arrivals get UNAVAILABLE',
      () async {
        newGate();
        final self = await node.listenMemory();
        final resolver = StaticResolver([
          ServiceRecord(ServiceAddress(kv, 2), endpoints: [self]),
        ]);
        addTearDown(resolver.close);
        node.resolver = resolver;
        // This node takes every instance of the type: a channel piped back
        // to it would reach the forwarding gate again.
        var arrivals = 0;
        node.registerService(
          kv,
          (incoming) {
            arrivals++;
            return gate.handler(incoming);
          },
          instance: 1,
          acceptAnyInstance: true,
        );
        await gate.onAssign(assign(1));
        await gate.onDrain(DrainRequest(kv, 1, epoch: 2, to: 2));
        final queued = peer.open(shard: 1);
        await settle();
        await gate.onForward(ForwardRequest(kv, 1, epoch: 2, to: 2));
        expect(
          await queued.done.timeout(limit),
          hasCode(StatusCode.unavailable),
        );
        expect(
          await peer.open(shard: 1).done.timeout(limit),
          hasCode(StatusCode.unavailable),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(arrivals, 0);
        expect(gate.stateOf(1), SlotGateState.forwarding);
      },
    );

    test('RESUME and FORWARD of unknown slots do nothing', () async {
      newGate();
      await gate.onResume(ResumeRequest(kv, 1, epoch: 1));
      await gate.onForward(ForwardRequest(kv, 1, epoch: 2, to: 2));
      expect(gate.stateOf(1), isNull);
      expect(lifecycle.log, isEmpty);
    });

    test('close stops every slot and refuses later ASSIGNs', () async {
      newGate();
      await gate.onAssign(assign(1));
      await gate.onAssign(assign(2));
      await gate.close();
      expect(lifecycle.log.skip(2), unorderedEquals(['unload 1', 'unload 2']));
      expect(gate.onAssign(assign(3)), throwsA(isA<SwitchboardException>()));
      expect(await peer.open(shard: 1).done, isMoved());
    });
  });

  group('requests', () {
    late List<String> answered;

    test(
      'revocation from a request refuses the rest of the released queue',
      () async {
        newGate(trackChannels: false);
        final handled = <String>[];
        lifecycle.onServe = (channel, slot) {
          channel.talk().messages.listen((message) {
            unawaited(
              gate.serveRequest(message, slot, (m) {
                handled.add(text(m.payload));
                m.reply(m.payload);
                unawaited(gate.onRevoke(kv, slot));
              }),
            );
          });
        };
        await gate.onAssign(assign(1));
        final talk = TalkChannel(peer.open(shard: 1));
        await settle();
        await gate.onDrain(DrainRequest(kv, 1, epoch: 2, to: 2));
        final first = talk.request('GET', bytes('a'));
        final second = expectLater(
          talk.request('GET', bytes('b')),
          throwsCode(StatusCode.moved),
        );
        await settle();
        await gate.onResume(ResumeRequest(kv, 1, epoch: 1));
        expect(text((await first).payload), 'a');
        await second;
        expect(handled, ['a']);
        await talk.close();
      },
    );

    /// Serves Talk on every channel; requests go through [serveRequest]
    /// and are answered `slot:payload` after [hold] completes.
    void talkLifecycle({Completer<void>? hold}) {
      answered = [];
      lifecycle.onServe = (channel, slot) {
        gate.detach(channel);
        channel.talk().messages.listen(
          (m) => gate.serveRequest(m, slot, (m) async {
            await hold?.future;
            answered.add(text(m.payload));
            unawaited(m.reply(bytes('$slot:${text(m.payload)}')));
          }),
        );
      };
    }

    test(
      'forwarded requests remain bounded while resolution is stalled',
      () async {
        final resolver = DelayedResolver([
          ServiceRecord(ServiceAddress(kv, 2), endpoints: [targetUri]),
        ]);
        node.resolver = resolver;
        addTearDown(resolver.close);
        addTearDown(() {
          if (!resolver.proceed.isCompleted) resolver.proceed.complete();
        });
        newGate(maxQueuedRequests: 1, trackChannels: false);
        talkLifecycle();
        await gate.onAssign(assign(1));
        final talk = TalkChannel(peer.open(shard: 1));
        await settle();
        await gate.onForward(ForwardRequest(kv, 1, epoch: 2, to: 2));
        target.registerService(kv, (incoming) {
          incoming.talk().messages.listen((m) => m.reply(m.payload));
        }, instance: 2);
        final first = talk.startRequest('GET', bytes('first'));
        final cancelled = expectLater(
          first.response,
          throwsCode(StatusCode.cancelled),
        );
        await settle();
        first.cancel();
        await cancelled;
        await expectLater(
          talk.request('GET', bytes('excess'), timeout: limit),
          throwsCode(StatusCode.unavailable),
        );
        resolver.proceed.complete();
        await node.connect(targetUri);
        await settle();
        expect(text((await talk.request('GET', bytes('new'))).payload), 'new');
        await talk.close();
      },
    );

    test('a forwarding channel that fails at once gives the request\'s '
        'place back', () async {
      final resolver = DelayedResolver([
        ServiceRecord(ServiceAddress(kv, 2), endpoints: [targetUri]),
      ])..throwAtOnce = true;
      resolver.proceed.complete();
      node.resolver = resolver;
      addTearDown(resolver.close);
      newGate(maxQueuedRequests: 1, trackChannels: false);
      talkLifecycle();
      await gate.onAssign(assign(1));
      final talk = TalkChannel(peer.open(shard: 1));
      await settle();
      await gate.onForward(ForwardRequest(kv, 1, epoch: 2, to: 2));
      target.registerService(kv, (incoming) {
        incoming.talk().messages.listen((m) => m.reply(m.payload));
      }, instance: 2);
      for (var i = 0; i < 3; i++) {
        await expectLater(
          talk.request('GET', bytes('x$i'), timeout: limit),
          throwsCode(StatusCode.unavailable),
        );
      }
      // Refused by the bound if a failed open had kept its place.
      resolver.throwAtOnce = false;
      expect(text((await talk.request('GET', bytes('new'))).payload), 'new');
      await talk.close();
    });

    test('served, queued while locked, forwarded after FORWARD', () async {
      newGate(trackChannels: false);
      talkLifecycle();
      await gate.onAssign(assign(1));
      final talk = TalkChannel(peer.open(shard: 1));
      expect(text((await talk.request('GET', bytes('a'))).payload), '1:a');
      await gate.onDrain(DrainRequest(kv, 1, epoch: 2, to: 2));
      final queued = talk.request('GET', bytes('b'));
      await settle();
      expect(answered, ['a']);
      // The target node echoes raw subframes; serve Talk there instead.
      target.registerService(kv, (incoming) {
        arrived.add(incoming);
        incoming.talk().messages.listen(
          (m) => m.reply(bytes('to:${text(m.payload)}')),
        );
      }, instance: 2);
      await gate.onForward(ForwardRequest(kv, 1, epoch: 2, to: 2));
      expect(text((await queued.timeout(limit)).payload), 'to:b');
      expect(text((await talk.request('GET', bytes('c'))).payload), 'to:c');
      // One forwarding channel, addressed to the slot, for both.
      expect(arrived, hasLength(1));
      expect(arrived.single.address.shard, 1);
      expect(arrived.single.address.instance, 2);
      await talk.close();
    });

    test('a forwarded request and its answer carry bulk payloads', () async {
      newGate(trackChannels: false);
      talkLifecycle();
      await gate.onAssign(assign(1));
      final talk = TalkChannel(peer.open(shard: 1));
      await gate.onDrain(DrainRequest(kv, 1, epoch: 2, to: 2));
      target.registerService(kv, (incoming) {
        incoming.talk().messages.listen((m) {
          expect(m.isBulk, isTrue);
          m.reply(Uint8List.fromList([...m.payload, ...m.payload]));
        });
      }, instance: 2);
      await gate.onForward(ForwardRequest(kv, 1, epoch: 2, to: 2));
      final big = Uint8List.fromList(List.generate(100000, (i) => i % 251));
      final answer = await talk.request('PUT', big).timeout(limit);
      expect(answer.isBulk, isTrue);
      expect(answer.payload, [...big, ...big]);
      await talk.close();
    });

    test('in-flight requests hold DRAIN; RESUME runs the queue here', () async {
      newGate(trackChannels: false);
      final hold = Completer<void>();
      talkLifecycle(hold: hold);
      await gate.onAssign(assign(1));
      final talk = TalkChannel(peer.open(shard: 1));
      final first = talk.request('GET', bytes('a'));
      await settle();
      final drained = gate.onDrain(DrainRequest(kv, 1, epoch: 2, to: 2));
      final second = talk.request('GET', bytes('b'));
      await settle();
      expect(lifecycle.log.last, 'serve 1 cred');
      hold.complete();
      await drained.timeout(limit);
      expect(lifecycle.log.last, 'drain 1 e2 to2');
      expect(answered, ['a']);
      await gate.onResume(ResumeRequest(kv, 1, epoch: 1));
      expect(text((await first).payload), '1:a');
      expect(text((await second.timeout(limit)).payload), '1:b');
      expect(answered, ['a', 'b']);
      await talk.close();
    });

    test('an ASSIGN of the locked slot after a lost RESUME runs the queue '
        'here and answers as its load did', () async {
      newGate(trackChannels: false);
      talkLifecycle();
      lifecycle.result = AssignResult.notHolding;
      await gate.onAssign(assign(1));
      final talk = TalkChannel(peer.open(shard: 1));
      expect(text((await talk.request('GET', bytes('a'))).payload), '1:a');
      await gate.onDrain(DrainRequest(kv, 1, epoch: 2, to: 2));
      final queued = talk.request('GET', bytes('b'));
      await settle();
      expect(answered, ['a']);
      expect(await gate.onAssign(assign(1, epoch: 2)), AssignResult.notHolding);
      expect(text((await queued.timeout(limit)).payload), '1:b');
      expect(answered, ['a', 'b']);
      expect(arrived, isEmpty);
      await talk.close();
    });

    test('a slot not served: ABORT MOVED; bounded queue', () async {
      newGate(trackChannels: false, maxQueuedRequests: 1);
      // Requests name their slot, which need not be the channel's.
      lifecycle.onServe = (channel, _) {
        gate.detach(channel);
        channel.talk().messages.listen(
          (m) => gate.serveRequest(m, int.parse(text(m.payload)), (m) {
            m.reply(m.payload);
          }),
        );
      };
      await gate.onAssign(assign(1));
      final talk = TalkChannel(peer.open(shard: 1));
      Future<Object> outcome(Future<TalkMessage> r) => r.then<Object>(
        (m) => text(m.payload),
        onError: (Object e) => (e as SwitchboardException).code!,
      );
      expect(await outcome(talk.request('GET', bytes('1'))), '1');
      expect(await outcome(talk.request('GET', bytes('5'))), StatusCode.moved);
      await gate.onDrain(DrainRequest(kv, 1, epoch: 2, to: 2));
      final parked = outcome(talk.request('GET', bytes('1')));
      expect(
        await outcome(talk.request('GET', bytes('1'))),
        StatusCode.unavailable,
      );
      await gate.onResume(ResumeRequest(kv, 1, epoch: 1));
      expect(await parked.timeout(limit), '1');
      await talk.close();
    });

    test('a slot outside the mirrored space: ABORT OUT_OF_RANGE', () async {
      final h = Harness();
      addTearDown(h.close);
      client = NamingClient(Connector(h).call);
      await client.start();
      await client.synced.timeout(limit);
      await client.defineSlots(
        kv,
        count: 4,
        mode: SlotMode.static,
        capacity: 0,
      );
      await until(() => client.slotTable(kv) != null);
      newGate(trackChannels: false);
      lifecycle.onServe = (channel, _) {
        gate.detach(channel);
        channel.talk().messages.listen(
          (m) => gate.serveRequest(m, int.parse(text(m.payload)), (m) {
            m.reply(m.payload);
          }),
        );
      };
      await gate.onAssign(assign(1));
      final talk = TalkChannel(peer.open(shard: 1));
      Future<Object> outcome(String slot) => talk
          .request('GET', bytes(slot))
          .then<Object>(
            (m) => text(m.payload),
            onError: (Object e) => (e as SwitchboardException).code!,
          );
      expect(await outcome('1'), '1');
      expect(await outcome('3'), StatusCode.moved);
      expect(await outcome('4'), StatusCode.outOfRange);
      await talk.close();
    });

    test('a queued request whose channel closed leaves the queue', () async {
      newGate(trackChannels: false, maxQueuedRequests: 1);
      talkLifecycle();
      await gate.onAssign(assign(1));
      final first = TalkChannel(peer.open(shard: 1));
      final second = TalkChannel(peer.open(shard: 1));
      expect(text((await first.request('GET', bytes('a'))).payload), '1:a');
      await until(() => lifecycle.served[1]?.length == 2);
      await gate.onDrain(DrainRequest(kv, 1, epoch: 2, to: 2));
      final gone = first.request('GET', bytes('gone'));
      gone.ignore();
      await settle();
      expect(
        second.request('GET', bytes('refused')),
        throwsA(isA<SwitchboardException>()),
      );
      await settle();
      await first.close();
      await settle();
      // Its place in the queue is free again.
      final queued = second.request('GET', bytes('b'));
      await settle();
      await gate.onResume(ResumeRequest(kv, 1, epoch: 1));
      expect(text((await queued.timeout(limit)).payload), '1:b');
      expect(answered, ['a', 'b']);
      await second.close();
    });

    test('the forwarding channel is closed once idle, and opened again for '
        'a late request', () async {
      newGate(trackChannels: false);
      talkLifecycle();
      target.registerService(kv, (incoming) {
        arrived.add(incoming);
        incoming.talk().messages.listen(
          (m) => m.reply(bytes('to:${text(m.payload)}')),
        );
      }, instance: 2);
      await gate.onAssign(assign(1));
      final talk = TalkChannel(peer.open(shard: 1));
      await settle();
      await gate.onDrain(DrainRequest(kv, 1, epoch: 2, to: 2));
      await gate.onForward(ForwardRequest(kv, 1, epoch: 2, to: 2));
      expect(text((await talk.request('GET', bytes('a'))).payload), 'to:a');
      expect(text((await talk.request('GET', bytes('b'))).payload), 'to:b');
      expect(arrived, hasLength(1));
      // About a second without a request: closed.
      final closed = await arrived.single.channel.done.timeout(limit);
      expect(closed, Status.ok);
      expect(text((await talk.request('GET', bytes('c'))).payload), 'to:c');
      expect(arrived, hasLength(2));
      await talk.close();
    });
  });

  test('MOVED fields follow the naming client mirror', () async {
    final h = Harness();
    addTearDown(h.close);
    // Instance 5 owns slot 2 of a static space.
    final owner = NamingClient(Connector(h).call);
    addTearDown(owner.close);
    final ownerLifecycle = TestLifecycle();
    final ownerGate = SlotGate(
      node,
      owner,
      kv,
      lifecycle: ownerLifecycle,
      instance: 5,
    );
    owner.slotHandler = ownerGate;
    await owner.start();
    await owner.register(kv, [targetUri], instance: 5);
    await owner.defineSlots(kv, count: 4, mode: SlotMode.static);
    expect(await ownerGate.claim(2), 1);
    expect(ownerGate.serves(2), isTrue);
    expect(ownerLifecycle.log, ['load 2 e1 h0']);
    client = NamingClient(Connector(h).call);
    await client.start();
    await client.synced.timeout(limit);
    newGate();
    await until(() => client.slotOwner(kv, 2) != null);
    expect(await peer.open(shard: 2).done, isMoved(5, 1));
    expect(gate.movedStatus(1), isMoved());
    // Release stops serving locally after the naming service.
    await ownerGate.release(2);
    expect(ownerGate.stateOf(2), isNull);
    expect(ownerLifecycle.log.last, 'unload 2');
    await until(() => client.slotOwner(kv, 2) == null);
    expect(gate.movedStatus(2), isMoved());
  });

  test('SlotGates dispatches by type', () async {
    final gates = SlotGates();
    newGate();
    gates.add(gate);
    expect(() => gates.add(gate), throwsStateError);
    expect(gates[kv], same(gate));
    await gates.onAssign(assign(1));
    expect(gate.serves(1), isTrue);
    final other = AssignRequest(
      Name('zz'),
      1,
      epoch: 1,
      holder: 0,
      shared: false,
    );
    await expectLater(
      gates.onAssign(other),
      throwsA(
        isA<SwitchboardException>().having(
          (e) => e.code,
          'code',
          StatusCode.unavailable,
        ),
      ),
    );
    await expectLater(
      gates.onDrain(DrainRequest(Name('zz'), 1, epoch: 2, to: 2)),
      throwsA(isA<SwitchboardException>()),
    );
    await gates.onForward(ForwardRequest(Name('zz'), 1, epoch: 2, to: 2));
    await gates.onResume(ResumeRequest(Name('zz'), 1, epoch: 1));
    await gates.onRevoke(Name('zz'), 1);
    await gates.onRevoke(kv, 1);
    expect(gate.stateOf(1), isNull);
    expect(gates.remove(kv), same(gate));
    expect(gates.gates, isEmpty);
  });

  test(
    'a lifecycle serves one gate, and another once that is closed',
    () async {
      newGate();
      expect(
        () => SlotGate(node, client, kv, lifecycle: lifecycle),
        throwsStateError,
      );
      expect(() => TestLifecycle().gate, throwsStateError);
      expect(lifecycle.gate, same(gate));
      await gate.close();
      // Still answers for the closed gate until attached again.
      expect(lifecycle.gate, same(gate));
      final again = SlotGate(node, client, kv, lifecycle: lifecycle);
      expect(lifecycle.gate, same(again));
      await again.onAssign(assign(1));
      expect(again.serves(1), isTrue);
      await again.close();
    },
  );

  test('HOLDING discards reach the lifecycle through SlotGates', () {
    final discarded = <List<int>>[];
    final gates = SlotGates();
    lifecycle = _DiscardLog(discarded);
    gates.add(SlotGate(node, client, kv, lifecycle: lifecycle));
    gates.onDiscard(kv, [3, 5]);
    gates.onDiscard(Name('zz'), [1]);
    expect(discarded, [
      [3, 5],
    ]);
  });

  test('a discard that fails, at once or after an await, is logged; the '
      'error does not escape', () async {
    final warnings = gateLogs(Level.WARNING);
    final escaped = <Object>[];
    final discarded = <List<int>>[];
    final failing = _FailingDiscard(discarded);
    lifecycle = failing;
    final gates = SlotGates()
      ..add(SlotGate(node, client, kv, lifecycle: lifecycle));
    // Called in a guarded zone: an error the gate let escape would land
    // there.
    runZonedGuarded(() {
      gates.onDiscard(kv, [3, 5]);
      failing.atOnce = true;
      gates.onDiscard(kv, [7]);
    }, (e, _) => escaped.add(e));
    await until(() => warnings.length == 2);
    await settle();
    expect(discarded, [
      [3, 5],
      [7],
    ]);
    expect(escaped, isEmpty);
    expect(warnings, everyElement(contains('discard')));
  });
}

/// Records [SlotLifecycle.discard] calls.
class _DiscardLog extends TestLifecycle {
  _DiscardLog(this.discarded);

  final List<List<int>> discarded;

  @override
  void discard(List<int> slots) => discarded.add(slots);
}

/// Records [SlotLifecycle.discard] calls, then fails: after an await, or
/// at once when [atOnce] is set.
class _FailingDiscard extends TestLifecycle {
  _FailingDiscard(this.discarded);

  final List<List<int>> discarded;
  bool atOnce = false;

  @override
  FutureOr<void> discard(List<int> slots) {
    discarded.add(slots);
    if (atOnce) {
      throw StateError('discard failed at once');
    }
    return _failLater();
  }

  static Future<void> _failLater() async {
    await settle();
    throw StateError('discard failed after an await');
  }
}
