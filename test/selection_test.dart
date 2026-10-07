/*
Polyverse Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Authors:
  Jan Boon <jan.boon@kaetemi.be>
  Claude Opus 5.5 <noreply@anthropic.com>
*/

// Instance selection on the consumer side (a `where` filter over the
// records, also on the MOVED retry; the node's selection policy) and the
// dispatch of a registration
// that accepts any instance: the naming side of the untrusted worker fleet
// (wiki page "Polyverse Switchboard Use Cases", entry 5).

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:switchboard/switchboard.dart';
import 'package:test/test.dart';

const fast = MuxOptions(
  goAwayGrace: Duration(milliseconds: 100),
  keepAliveInterval: null,
);

final gpu = Name('gpu');

Uint8List bytes(String text) => Uint8List.fromList(utf8.encode(text));

Matcher throwsCode(StatusCode code) =>
    throwsA(isA<SwitchboardException>().having((e) => e.code, 'code', code));

/// A node closed after the test.
Switchboard node({
  Resolver? resolver,
  SelectionPolicy selection = SelectionPolicy.roundRobin,
  Random? random,
}) {
  final s = Switchboard(
    resolver: resolver,
    muxOptions: fast,
    selection: selection,
    random: random,
  );
  addTearDown(s.close);
  return s;
}

/// A handler that sends `<tag> <instance in the header>` and closes.
ChannelHandler answering(String tag) => (incoming) {
  incoming.channel.send(bytes('$tag ${incoming.address.instance}'));
  unawaited(incoming.channel.close());
};

/// Reads what an [answering] handler sent, or the close status.
Future<String> answerOf(MuxChannel channel) async {
  final frames = await channel.stream.toList();
  final status = await channel.done;
  if (frames.isEmpty) {
    return 'closed ${status.known?.name ?? status.code}';
  }
  return utf8.decode(frames.single);
}

/// Worker metadata: the models it offers, as JSON.
Uint8List offering(List<String> models) =>
    bytes(jsonEncode({'models': models}));

/// A filter for the workers whose metadata offers [model].
bool Function(ServiceRecord) offers(String model) => (record) {
  if (record.metadata.isEmpty) {
    return false;
  }
  final decoded = jsonDecode(utf8.decode(record.metadata)) as Map;
  return (decoded['models'] as List).contains(model);
};

void main() {
  group('selection', () {
    late Switchboard workers;
    late Uri uri;
    late StaticResolver resolver;

    setUp(() async {
      // Four workers behind one node, each under its own id.
      workers = node();
      for (var id = 1; id <= 4; id++) {
        workers.registerService(gpu, answering('w'), instance: id);
      }
      uri = await workers.listenMemory();
      ServiceRecord worker(int id, [Uint8List? metadata]) => ServiceRecord(
        ServiceAddress(gpu, id),
        endpoints: [uri],
        metadata: metadata,
      );
      resolver = StaticResolver([
        // Out of order: selection sorts by instance.
        worker(3, offering(['b'])),
        worker(1, offering(['a'])),
        worker(4),
        worker(2, offering(['a', 'b'])),
      ]);
    });

    Future<List<int>> instancesOf(
      Switchboard client,
      int count, {
      bool Function(ServiceRecord)? where,
      int? shard,
    }) async => [
      for (var i = 0; i < count; i++)
        int.parse(
          (await answerOf(
            await client.openChannel(
              ServiceAddress(gpu),
              where: where,
              shard: shard,
            ),
          )).split(' ').last,
        ),
    ];

    test('round robin is the default and unchanged', () async {
      final client = node(resolver: resolver);
      expect(client.selection, SelectionPolicy.roundRobin);
      expect(await instancesOf(client, 8), [1, 2, 3, 4, 1, 2, 3, 4]);
    });

    test('where filters on metadata', () async {
      final client = node(resolver: resolver);
      // One round-robin counter per type, over the matching records.
      expect(await instancesOf(client, 4, where: offers('b')), [2, 3, 2, 3]);
      expect(await instancesOf(client, 2, where: offers('a')), [1, 2]);
      final (record, _) = await client.selectAndConnect(
        ServiceAddress(gpu),
        where: (r) => r.metadata.isEmpty,
      );
      expect(record.address.instance, 4);
    });

    test('with a shard slot: sorted[slot mod n] of the matching', () async {
      final client = node(resolver: resolver);
      expect(await instancesOf(client, 2, where: offers('b'), shard: 0), [
        2,
        2,
      ]);
      expect(await instancesOf(client, 1, where: offers('b'), shard: 5), [3]);
      expect(await instancesOf(client, 1, shard: 5), [2]);
    });

    test('none left is NOT_FOUND', () async {
      final client = node(resolver: resolver);
      await expectLater(
        client.openChannel(ServiceAddress(gpu), where: (_) => false),
        throwsCode(StatusCode.notFound),
      );
      await expectLater(
        client.openTalk(ServiceAddress(gpu), where: offers('z')),
        throwsCode(StatusCode.notFound),
      );
      await expectLater(
        client.openChannel(ServiceAddress(gpu), shard: 3, where: offers('z')),
        throwsCode(StatusCode.notFound),
      );
      // An explicit instance the filter refuses.
      await expectLater(
        client.openChannel(ServiceAddress(gpu, 1), where: offers('b')),
        throwsCode(StatusCode.notFound),
      );
      expect(
        await answerOf(
          await client.openChannel(ServiceAddress(gpu, 2), where: offers('b')),
        ),
        'w 2',
      );
    });

    test('a throwing filter fails the open', () async {
      final client = node(resolver: resolver);
      await expectLater(
        client.openChannel(
          ServiceAddress(gpu),
          where: (_) => throw StateError('bad filter'),
        ),
        throwsStateError,
      );
    });

    test('random selection reaches every instance', () async {
      final client = node(
        resolver: resolver,
        selection: SelectionPolicy.random,
        random: Random(7),
      );
      final counts = <int, int>{};
      final sequence = <int>[];
      for (var i = 0; i < 400; i++) {
        final (record, _) = await client.selectAndConnect(ServiceAddress(gpu));
        sequence.add(record.address.instance);
        counts.update(record.address.instance, (n) => n + 1, ifAbsent: () => 1);
      }
      expect(counts.keys, unorderedEquals([1, 2, 3, 4]));
      for (final n in counts.values) {
        expect(n, inInclusiveRange(60, 140), reason: '$counts');
      }
      // Not a rotation.
      expect(sequence.take(8), isNot([1, 2, 3, 4, 1, 2, 3, 4]));
      // The injected Random decides: the same seed, the same choices.
      final again = node(
        resolver: resolver,
        selection: SelectionPolicy.random,
        random: Random(7),
      );
      expect([
        for (var i = 0; i < 40; i++)
          (await again.selectAndConnect(ServiceAddress(gpu)))
              .$1
              .address
              .instance,
      ], sequence.take(40));
      // Over the matching records only.
      final filtered = <int>{};
      for (var i = 0; i < 100; i++) {
        final (record, _) = await client.selectAndConnect(
          ServiceAddress(gpu),
          where: offers('a'),
        );
        filtered.add(record.address.instance);
      }
      expect(filtered, {1, 2});
    });

    test('random selection keeps shard selection', () async {
      final client = node(
        resolver: resolver,
        selection: SelectionPolicy.random,
        random: Random(1),
      );
      expect(await instancesOf(client, 4, shard: 6), [3, 3, 3, 3]);
    });

    test('slot routing: an owner the filter refuses is NOT_FOUND', () async {
      resolver
        ..defineSlots(SlotSpace(gpu, count: 8, mode: SlotMode.static))
        ..setSlot(gpu, 1, const SlotEntry.owned(3, epoch: 1));
      final client = node(resolver: resolver);
      final channel = await client.openChannelToSlot(
        gpu,
        1,
        where: offers('b'),
      );
      final frames = await channel.stream.toList();
      expect(utf8.decode(frames.single), 'w 3');
      await expectLater(
        client.openChannelToSlot(gpu, 1, where: offers('a')),
        throwsCode(StatusCode.notFound),
      );
      await expectLater(
        client.openTalkToSlot(gpu, 1, where: offers('a')),
        throwsCode(StatusCode.notFound),
      );
    });
  });

  group('where on the MOVED retry', () {
    late StaticResolver resolver;
    late List<String> seen;

    setUp(() async {
      // Instance 1 rejects every channel with MOVED to 2; 2 answers.
      final one = node();
      final two = node();
      seen = [];
      one.registerService(gpu, (incoming) {
        seen.add('1');
        unawaited(incoming.reject(MovedStatus(owner: 2, epoch: 2).toStatus()));
      }, instance: 1);
      two.registerService(gpu, (incoming) {
        seen.add('2');
        answering('w')(incoming);
      }, instance: 2);
      resolver = StaticResolver([
        ServiceRecord(
          ServiceAddress(gpu, 1),
          endpoints: [await one.listenMemory()],
          metadata: offering(['a']),
        ),
        ServiceRecord(
          ServiceAddress(gpu, 2),
          endpoints: [await two.listenMemory()],
          metadata: offering(['b']),
        ),
      ]);
      resolver
        ..defineSlots(SlotSpace(gpu, count: 4, mode: SlotMode.static))
        ..setSlot(gpu, 1, const SlotEntry.owned(1, epoch: 1));
    });

    test('a new owner the filter accepts is retried', () async {
      final client = node(resolver: resolver);
      final channel = await client.openChannelToSlot(
        gpu,
        1,
        where: (_) => true,
      );
      expect(utf8.decode((await channel.stream.toList()).single), 'w 2');
      expect(channel.retried, isTrue);
      expect(seen, ['1', '2']);
    });

    test('a new owner the filter refuses: the channel ends with NOT_FOUND, '
        'the owner is never reached', () async {
      final client = node(resolver: resolver);
      final channel = await client.openChannelToSlot(
        gpu,
        1,
        where: offers('a'),
      );
      expect(await channel.stream.toList(), isEmpty);
      final status = await channel.done;
      expect(status.known, StatusCode.notFound);
      expect(channel.retried, isTrue);
      expect(seen, ['1']);
    });

    test('a new owner the resolver does not know: MOVED, as before', () async {
      resolver.remove(ServiceAddress(gpu, 2));
      final client = node(resolver: resolver);
      final channel = await client.openChannelToSlot(
        gpu,
        1,
        where: offers('a'),
      );
      expect((await channel.done).known, StatusCode.moved);
      expect(seen, ['1']);
    });
  });

  group('acceptAnyInstance', () {
    late Switchboard server;
    late Switchboard client;
    late Uri uri;

    setUp(() async {
      server = node();
      uri = await server.listenMemory();
      client = node();
    });

    Future<String> open(int instance) async => answerOf(
      await client.openChannelAt(
        uri,
        ChannelAddress(type: gpu, instance: instance),
      ),
    );

    test('serves a channel addressed to any instance', () async {
      server.registerService(gpu, answering('any'), acceptAnyInstance: true);
      expect(await open(0x1234), 'any 4660');
      expect(await open(maxInstance), 'any $maxInstance');
      expect(await open(0), 'any 0');
      // Other types are not affected.
      expect(
        await answerOf(
          await client.openChannelAt(uri, ChannelAddress(type: Name('cpu'))),
        ),
        'closed notFound',
      );
    });

    test('an exact registration still wins', () async {
      server
        ..registerService(gpu, answering('any'), acceptAnyInstance: true)
        ..registerService(gpu, answering('exact'), instance: 0x1234);
      expect(await open(0x1234), 'exact 4660');
      expect(await open(0x1235), 'any 4661');
    });

    test('comes before the first registered for instance 0', () async {
      server
        ..registerService(gpu, answering('five'), instance: 5)
        ..registerService(
          gpu,
          answering('seven'),
          instance: 7,
          acceptAnyInstance: true,
        );
      expect(await open(0), 'seven 0');
      expect(await open(5), 'five 5');
      expect(await open(9), 'seven 9');
    });

    test('registering again without it, or unregistering, ends it', () async {
      server.registerService(gpu, answering('any'), acceptAnyInstance: true);
      expect(await open(0x1234), 'any 4660');
      server.registerService(gpu, answering('zero'));
      expect(await open(0x1234), 'closed notFound');
      expect(await open(0), 'zero 0');
      server.registerService(gpu, answering('any'), acceptAnyInstance: true);
      server.unregisterService(gpu);
      server.registerService(gpu, answering('seven'), instance: 7);
      expect(await open(0x1234), 'closed notFound');
    });

    test('a worker registered by a registrar under an id it was never told '
        'is reached through that id', () async {
      server.registerService(gpu, answering('worker'), acceptAnyInstance: true);
      final consumer = node(
        resolver: StaticResolver([
          ServiceRecord(
            ServiceAddress(gpu, 0x1234),
            endpoints: [uri],
            metadata: offering(['a']),
          ),
        ]),
      );
      expect(
        await answerOf(
          await consumer.openChannel(ServiceAddress(gpu), where: offers('a')),
        ),
        'worker 4660',
      );
    });
  });
}
