// Slot-aware routing in the Switchboard: (type, slot) to the owner, the
// old owner while migrating, LOCATE on a miss in a managed space,
// UNAVAILABLE in a static one, and the MOVED retry of openChannelToSlot
// (never on RELOCATED).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:async/async.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:switchboard/switchboard.dart';
import 'package:test/test.dart';

const fast = MuxOptions(
  goAwayGrace: Duration(milliseconds: 100),
  keepAliveInterval: null,
);
const limit = Duration(seconds: 5);

final svc = Name('svc');

Uint8List bytes(String text) => Uint8List.fromList(utf8.encode(text));

String text(Uint8List data) => utf8.decode(data);

Matcher throwsCode(StatusCode code) =>
    throwsA(isA<SwitchboardException>().having((e) => e.code, 'code', code));

Matcher hasCode(StatusCode code) =>
    isA<Status>().having((s) => s.known, 'code', code);

/// A static resolver whose LOCATE answers are scripted.
class LocatingResolver extends StaticResolver {
  LocatingResolver(super.records);

  final List<int> located = [];
  SlotEntry? Function(int slot) answer = (_) => null;

  @override
  Future<SlotEntry?> locateSlot(Name type, int slot) async {
    located.add(slot);
    return answer(slot);
  }
}

/// How a backend treats the channels it receives.
enum Mode {
  /// Sends `<name> <shard>` at once, then echoes `<name>:<data>`.
  greet,

  /// Rejects with MOVED carrying [Backend.moved] at once.
  moved,

  /// Closes with RELOCATED carrying [Backend.moved] at once.
  relocated,

  /// Rejects with MOVED once something arrived.
  movedAfterData,

  /// Sends a greeting, then closes with MOVED.
  greetThenMoved,

  /// Talk: sends a `HELLO` message, answers requests with `<name>:<data>`.
  talk,
}

class Backend {
  Backend(this.name, this.id);

  final String name;
  final int id;
  late final Switchboard node;
  late final Uri uri;
  Mode mode = Mode.greet;
  MovedStatus moved = MovedStatus.unknown;
  final List<ChannelAddress> opened = [];

  ServiceRecord get record =>
      ServiceRecord(ServiceAddress(svc, id), endpoints: [uri]);

  Future<void> start() async {
    node = Switchboard(muxOptions: fast);
    addTearDown(node.close);
    node.registerService(svc, _serve, instance: id);
    uri = await node.listenTcp(InternetAddress.loopbackIPv4, 0);
  }

  void _serve(IncomingChannel incoming) {
    opened.add(incoming.address);
    final channel = incoming.channel;
    final moved = this.moved.toStatus();
    switch (mode) {
      case Mode.greet:
        channel.send(bytes('$name ${incoming.address.shard}'));
        channel.stream.listen((d) => channel.send(bytes('$name:${text(d)}')));
      case Mode.moved:
        unawaited(incoming.reject(moved));
      case Mode.relocated:
        unawaited(incoming.reject(this.moved.toStatus(relocated: true)));
      case Mode.movedAfterData:
        channel.stream.first.then((_) => incoming.reject(moved)).ignore();
      case Mode.greetThenMoved:
        channel.send(bytes('$name ${incoming.address.shard}'));
        unawaited(incoming.reject(moved));
      case Mode.talk:
        final talk = incoming.talk();
        talk.send('HELLO', bytes(name));
        talk.messages.listen((m) => m.reply(bytes('$name:${text(m.payload)}')));
    }
  }
}

void main() {
  late Backend a;
  late Backend b;
  late LocatingResolver resolver;
  late Switchboard router;

  setUp(() async {
    a = Backend('A', 1);
    b = Backend('B', 2);
    await a.start();
    await b.start();
    resolver = LocatingResolver([a.record, b.record]);
    addTearDown(resolver.close);
    router = Switchboard(
      resolver: resolver,
      muxOptions: fast,
      slotRefreshTimeout: const Duration(milliseconds: 500),
    );
    addTearDown(router.close);
  });

  /// The greeting of a [Mode.greet] backend on [channel].
  Future<String> greeting(StreamChannel<Uint8List> channel) async =>
      text(await channel.stream.first.timeout(limit));

  Future<String> greetingOf(int slot, {int instance = 0}) async => greeting(
    await router.openChannel(ServiceAddress(svc, instance), shard: slot),
  );

  void define({SlotMode mode = SlotMode.managed, int count = 8}) =>
      resolver.defineSlots(SlotSpace(svc, count: count, mode: mode));

  group('routing', () {
    test('without a slot table: sorted[slot mod n]', () async {
      expect(await greetingOf(2), 'A 2');
      expect(await greetingOf(3), 'B 3');
    });

    test('to the owner, the old owner while migrating', () async {
      define();
      resolver
        ..setSlot(svc, 2, const SlotEntry.owned(2, epoch: 1))
        ..setSlot(svc, 3, const SlotEntry.migrating(1, 2, epoch: 4));
      expect(await greetingOf(2), 'B 2');
      expect(await greetingOf(3), 'A 3');
      // The header names the owner, so that its dispatch is exact.
      expect(b.opened.single.instance, 2);
      expect(b.opened.single.shard, 2);
      // An explicit instance is not rerouted.
      expect(await greetingOf(2, instance: 1), 'A 2');
      expect(resolver.located, isEmpty);
    });

    test('a free slot: LOCATE in a managed space', () async {
      define();
      resolver.answer = (slot) => const SlotEntry.owned(2, epoch: 1);
      expect(await greetingOf(5), 'B 5');
      expect(resolver.located, [5]);
      resolver.answer = (_) => null;
      await expectLater(greetingOf(6), throwsCode(StatusCode.unavailable));
    });

    test('a free slot: UNAVAILABLE in a static space, no LOCATE', () async {
      define(mode: SlotMode.static);
      await expectLater(greetingOf(5), throwsCode(StatusCode.unavailable));
      expect(resolver.located, isEmpty);
    });

    test('a slot outside the space: OUT_OF_RANGE', () async {
      define(count: 4);
      await expectLater(greetingOf(4), throwsCode(StatusCode.outOfRange));
    });

    test('an owner missing from the service table or unreachable: '
        'UNAVAILABLE, no other instance', () async {
      define();
      resolver.setSlot(svc, 1, const SlotEntry.owned(9, epoch: 1));
      await expectLater(greetingOf(1), throwsCode(StatusCode.unavailable));
      resolver.setSlot(svc, 1, const SlotEntry.owned(2, epoch: 1));
      await b.node.close();
      await expectLater(greetingOf(1), throwsCode(StatusCode.unavailable));
      expect(a.opened, isEmpty);
    });

    test('resolveSlotOwner', () async {
      define();
      resolver.setSlot(svc, 1, const SlotEntry.owned(2, epoch: 1));
      expect(await router.resolveSlotOwner(svc, 1), ServiceAddress(svc, 2));
      resolver.answer = (_) => const SlotEntry.owned(1, epoch: 2);
      expect(
        await router.resolveSlotOwner(svc, 1, refresh: true),
        ServiceAddress(svc, 1),
      );
      expect(resolver.located, [1]);
      await expectLater(
        router.resolveSlotOwner(Name('none'), 1),
        throwsCode(StatusCode.notFound),
      );
      router.resolver = EndpointResolver(a.uri);
      await expectLater(
        router.resolveSlotOwner(svc, 1),
        throwsCode(StatusCode.failedPrecondition),
      );
    });

    test('a proxy routes by slot', () async {
      define();
      resolver.setSlot(svc, 3, const SlotEntry.owned(2, epoch: 1));
      router.catchAll = proxyHandler(router);
      final endpoint = await router.listenTcp(InternetAddress.loopbackIPv4, 0);
      final client = Switchboard(
        resolver: EndpointResolver(endpoint),
        muxOptions: fast,
      );
      addTearDown(client.close);
      final channel = await client.openChannel(ServiceAddress(svc), shard: 3);
      expect(await greeting(channel), 'B 3');
      expect(b.opened.single.instance, 2);
    });
  });

  group('MOVED', () {
    setUp(() {
      define();
      resolver.setSlot(svc, 1, const SlotEntry.owned(1, epoch: 1));
    });

    test('retried once at the owner the reason names', () async {
      a
        ..mode = Mode.moved
        ..moved = MovedStatus(owner: 2, epoch: 2);
      final channel = await router.openChannelToSlot(svc, 1);
      final answers = StreamQueue(channel.stream.map(text));
      expect(await answers.next.timeout(limit), 'B 1');
      expect(channel.retried, isTrue);
      expect(channel.channel.connection.isOpen, isTrue);
      expect(b.opened.single.payload, isEmpty);
      // The replacement carries on as the channel.
      channel.sink.add(bytes('x'));
      expect(await answers.next.timeout(limit), 'B:x');
      await channel.close();
      expect(await channel.done, Status.ok);
      expect(resolver.located, isEmpty);
    });

    test('the open payload is sent again', () async {
      a
        ..mode = Mode.moved
        ..moved = MovedStatus(owner: 2, epoch: 2);
      final channel = await router.openChannelToSlot(
        svc,
        1,
        payload: bytes('token'),
      );
      expect(await greeting(channel), 'B 1');
      expect(text(a.opened.single.payload), 'token');
      expect(text(b.opened.single.payload), 'token');
    });

    test('a reason without an owner: the router asks', () async {
      a.mode = Mode.moved;
      resolver.answer = (_) => const SlotEntry.owned(2, epoch: 2);
      final channel = await router.openChannelToSlot(svc, 1);
      expect(await greeting(channel), 'B 1');
      expect(resolver.located, [1]);
    });

    test('a newer table entry wins over the reason', () async {
      a
        ..mode = Mode.moved
        ..moved = MovedStatus(owner: 9, epoch: 2);
      final channel = await router.openChannelToSlot(svc, 1);
      resolver.setSlot(svc, 1, const SlotEntry.owned(2, epoch: 3));
      expect(await greeting(channel), 'B 1');
    });

    test('nowhere else to go: MOVED is surfaced', () async {
      a.mode = Mode.moved;
      resolver.answer = (_) => const SlotEntry.owned(1, epoch: 1);
      final channel = await router.openChannelToSlot(svc, 1);
      expect(await channel.stream.toList(), isEmpty);
      expect(await channel.done, hasCode(StatusCode.moved));
      expect(channel.retried, isTrue);
      expect(b.opened, isEmpty);
    });

    test('only once', () async {
      a
        ..mode = Mode.moved
        ..moved = MovedStatus(owner: 2, epoch: 2);
      b
        ..mode = Mode.moved
        ..moved = MovedStatus(owner: 1, epoch: 3);
      final channel = await router.openChannelToSlot(svc, 1);
      expect(await channel.done, hasCode(StatusCode.moved));
      expect(a.opened, hasLength(1));
      expect(b.opened, hasLength(1));
    });

    test('never on RELOCATED: the slot moved after work started', () async {
      a
        ..mode = Mode.relocated
        ..moved = MovedStatus(owner: 2, epoch: 2);
      final channel = await router.openChannelToSlot(svc, 1);
      final status = await channel.done;
      expect(status, hasCode(StatusCode.relocated));
      expect(MovedStatus.fromStatus(status), MovedStatus(owner: 2, epoch: 2));
      expect(channel.retried, isFalse);
      expect(b.opened, isEmpty);
    });

    test('not after the first send; the fields still name the owner', () async {
      a
        ..mode = Mode.movedAfterData
        ..moved = MovedStatus(owner: 2, epoch: 2);
      final channel = await router.openChannelToSlot(svc, 1);
      channel.sink.add(bytes('x'));
      final status = await channel.done;
      expect(status, hasCode(StatusCode.moved));
      expect(MovedStatus.fromStatus(status), MovedStatus(owner: 2, epoch: 2));
      expect(channel.retried, isFalse);
      expect(b.opened, isEmpty);
    });

    test('not after the first subframe received', () async {
      a
        ..mode = Mode.greetThenMoved
        ..moved = MovedStatus(owner: 2, epoch: 2);
      final channel = await router.openChannelToSlot(svc, 1);
      expect(await channel.stream.toList(), hasLength(1));
      expect(await channel.done, hasCode(StatusCode.moved));
      expect(channel.retried, isFalse);
      expect(b.opened, isEmpty);
    });

    test('Talk: a server that speaks first gets the retry', () async {
      a
        ..mode = Mode.moved
        ..moved = MovedStatus(owner: 2, epoch: 2);
      b.mode = Mode.talk;
      final talk = await router.openTalkToSlot(svc, 1);
      final hello = await talk.messages.first.timeout(limit);
      expect(hello.procedureName, 'HELLO');
      expect(text(hello.payload), 'B');
      expect(text((await talk.request('GET', bytes('k'))).payload), 'B:k');
      await talk.close();
    });

    test(
      'through a resolver without slot tables: the same address once more',
      () async {
        // A proxy without slot tables forwards MOVED; its client retries.
        final proxyTable = StaticResolver([a.record]);
        addTearDown(proxyTable.close);
        final proxy = Switchboard(muxOptions: fast);
        addTearDown(proxy.close);
        proxy.catchAll = proxyHandler(proxy, resolver: proxyTable);
        final endpoint = await proxy.listenTcp(InternetAddress.loopbackIPv4, 0);
        final client = Switchboard(
          resolver: EndpointResolver(endpoint),
          muxOptions: fast,
        );
        addTearDown(client.close);
        // The slot moves while the first open is on its way.
        var opens = 0;
        a.node.registerService(svc, (incoming) {
          opens++;
          proxyTable
            ..remove(ServiceAddress(svc, 1))
            ..add(b.record);
          unawaited(incoming.reject(Status.of(StatusCode.moved)));
        }, instance: 1);
        final channel = await client.openChannelToSlot(svc, 1);
        expect(await greeting(channel), 'B 1');
        expect(opens, 1);
        expect(channel.retried, isTrue);
      },
    );
  });
}
