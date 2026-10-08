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
import 'dart:math';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:switchboard/src/address/service_address.dart';
import 'package:switchboard/src/bytes.dart';
import 'package:switchboard/src/identity/peer_identity.dart';
import 'package:switchboard/src/mux/mux_connection.dart';
import 'package:switchboard/src/name.dart';
import 'package:switchboard/src/naming/naming_client.dart';
import 'package:switchboard/src/naming/naming_protocol.dart';
import 'package:switchboard/src/naming/naming_service.dart';
import 'package:switchboard/src/status.dart';
import 'package:switchboard/src/talk/talk_channel.dart';
import 'package:switchboard/src/talk/talk_frame.dart';
import 'package:switchboard/src/talk/talk_message.dart';
import 'package:test/test.dart';

import 'naming_harness.dart';

void main() {
  group('NamingService', () {
    late Harness h;

    setUp(() => h = Harness());
    tearDown(() => h.close());

    test('assigns increasing ids across types, starting at 1', () async {
      final (c, _) = h.link();
      expect(await register(c, 'npc'), 1);
      expect(await register(c, 'api'), 2);
      expect(await register(c, 'npc'), 3);
      expect(h.service.table.keys.map((a) => '$a'), [
        'npc/1',
        'api/2',
        'npc/3',
      ]);
    });

    test('honours a requested id and skips it when assigning', () async {
      final (c, _) = h.link();
      expect(await register(c, 'npc', instance: 3), 3);
      expect(await register(c, 'npc'), 1);
      expect(await register(c, 'npc'), 2);
      expect(await register(c, 'npc'), 4);
      expect(await register(c, 'big', instance: maxInstance), maxInstance);
    });

    test('wraps at the u48 limit and skips ids in use', () async {
      final (c, _) = h.link();
      expect(await register(c, 'npc'), 1);
      h.service.nextInstance = maxInstance;
      expect(await register(c, 'npc'), maxInstance);
      expect(await register(c, 'npc'), 2);
    });

    test('a requested id in use is ALREADY_EXISTS', () async {
      final (a, _) = h.link();
      final (b, _) = h.link();
      expect(await register(a, 'npc', instance: 5), 5);
      // Another channel, same type.
      await expectLater(
        register(b, 'npc', instance: 5),
        throwsStatus(StatusCode.alreadyExists),
      );
      // Ids are unique across types, even on the owning channel.
      await expectLater(
        register(a, 'api', instance: 5),
        throwsStatus(StatusCode.alreadyExists),
      );
      expect(h.service.table.length, 1);
    });

    test('re-registering from the owner replaces the endpoints', () async {
      final (a, _) = h.link();
      final events = <String>[];
      final sub = h.service.events.listen((e) => events.add(describeEvent(e)));
      expect(await register(a, 'npc', endpoints: [uriA]), 1);
      expect(await register(a, 'npc', instance: 1, endpoints: [uriB]), 1);
      // Unchanged: no event.
      expect(await register(a, 'npc', instance: 1, endpoints: [uriB]), 1);
      await pump();
      expect(h.service.table.values.single.endpoints, [uriB]);
      expect(events, ['UP npc/1 $uriA', 'UP npc/1 $uriB']);
      await sub.cancel();
    });

    test('re-registering with different metadata publishes UP', () async {
      final (a, _) = h.link();
      final watcher = Watcher(a);
      expect(await watcher.next, 'WATCHED');
      expect(
        await register(a, 'gpu', endpoints: [uriA], metadata: text('m1')),
        1,
      );
      expect(await watcher.next, 'UP gpu/1 $uriA meta m1');
      // Same endpoints, other metadata: UP.
      await register(
        a,
        'gpu',
        instance: 1,
        endpoints: [uriA],
        metadata: text('m2'),
      );
      expect(await watcher.next, 'UP gpu/1 $uriA meta m2');
      // Nothing changed: silent. Then metadata removed: UP.
      await register(
        a,
        'gpu',
        instance: 1,
        endpoints: [uriA],
        metadata: text('m2'),
      );
      await register(a, 'gpu', instance: 1, endpoints: [uriA]);
      expect(await watcher.next, 'UP gpu/1 $uriA');
      expect(h.service.table.values.single.metadata, isEmpty);
      // Local registrations too.
      expect(
        h.service.registerLocal(
          Name('x'),
          [uriB],
          instance: 9,
          metadata: text('l'),
        ),
        9,
      );
      expect(await watcher.next, 'UP x/9 $uriB meta l');
      h.service.registerLocal(
        Name('x'),
        [uriB],
        instance: 9,
        metadata: text('l'),
      );
      h.service.registerLocal(Name('x'), [uriB], instance: 9);
      expect(await watcher.next, 'UP x/9 $uriB');
    });

    test('metadata larger than 4096 bytes is INVALID_ARGUMENT', () async {
      final (c, _) = h.link();
      final w = ByteWriter()
        ..name(Name('gpu'))
        ..u48(0)
        ..u8(0)
        ..u16(maxMetadataLength + 1)
        ..bytes(Uint8List(maxMetadataLength + 1));
      await expectLater(
        c.request('REGISTER', w.toBytes()),
        throwsStatus(StatusCode.invalidArgument),
      );
      expect(
        () => h.service.registerLocal(
          Name('gpu'),
          const [],
          metadata: Uint8List(maxMetadataLength + 1),
        ),
        throwsStatus(StatusCode.invalidArgument),
      );
      expect(h.service.table, isEmpty);
      expect(
        await register(c, 'gpu', metadata: Uint8List(maxMetadataLength)),
        1,
      );
      expect(h.service.table.values.single.metadata, hasLength(4096));
    });

    test('follows the IDENTs of a connection with one listener, however '
        'many channels it carried', () async {
      final connection = _IdentityEvents();
      for (var i = 0; i < 20; i++) {
        final link = StreamChannelController<Uint8List>();
        h.service.serve(
          TalkChannel(link.local, options: serverOptions),
          connection: connection,
        );
        final client = TalkChannel(link.foreign, options: clientOptions);
        await register(client, 'npc');
        await client.close();
      }
      await until(() => h.service.channelCount == 0);
      expect(connection.waiting, 1);
      // An IDENT once no channel is left: the service stops listening.
      connection.changeIdentity();
      await pump();
      expect(connection.waiting, 0);
    });

    test('a REGISTER without the metadata field has empty metadata', () async {
      final (c, _) = h.link();
      final watcher = Watcher(c);
      expect(await watcher.next, 'WATCHED');
      final old = ByteWriter()
        ..name(Name('npc'))
        ..u48(0)
        ..u8(1)
        ..string8(uriA.toString());
      await c.request('REGISTER', old.toBytes());
      expect(await watcher.next, 'UP npc/1 $uriA');
      expect(h.service.table.values.single.metadata, isEmpty);
    });

    test('a registrar registers records on behalf of others; they live as '
        'long as its channel', () async {
      final (registrar, _) = h.link();
      final (consumer, _) = h.link();
      final watcher = Watcher(consumer, type: 'gpu');
      expect(await watcher.next, 'WATCHED');
      // Three workers that never talk to the naming service, each at its
      // own endpoint with its own capabilities, under ids the registrar
      // chose.
      final workers = {
        0x101: (Uri.parse('tcp://10.1.0.1:7000'), '{"models":["a"]}'),
        0x102: (Uri.parse('tcp://10.1.0.2:7000'), '{"models":["a","b"]}'),
        0x103: (Uri.parse('ws://10.1.0.3:7000/ws'), '{"models":["c"]}'),
      };
      for (final MapEntry(key: id, value: (uri, meta)) in workers.entries) {
        expect(
          await register(
            registrar,
            'gpu',
            instance: id,
            endpoints: [uri],
            metadata: text(meta),
          ),
          id,
        );
      }
      expect(await watcher.take(3), [
        for (final MapEntry(key: id, value: (uri, meta)) in workers.entries)
          'UP gpu/${id.toRadixString(16)} $uri meta $meta',
      ]);
      // A late watcher gets the same records in its snapshot.
      final late = Watcher(h.link().$1, type: 'gpu');
      expect(await late.take(4), [
        for (final MapEntry(key: id, value: (uri, meta)) in workers.entries)
          'UP gpu/${id.toRadixString(16)} $uri meta $meta',
        'WATCHED',
      ]);
      // Retiring one worker.
      await unregister(registrar, 'gpu', 0x102);
      expect(await watcher.next, 'DOWN gpu/102');
      // The registrar's channel goes: every record it made goes with it.
      await registrar.close();
      expect(await watcher.take(2), ['DOWN gpu/101', 'DOWN gpu/103']);
      expect(h.service.table, isEmpty);
    });

    test('rejects invalid requests', () async {
      final (c, _) = h.link();
      await expectLater(
        register(c, ''),
        throwsStatus(StatusCode.invalidArgument),
      );
      await expectLater(
        c.request('REGISTER', bytes([0x6E, 0x70])),
        throwsStatus(StatusCode.invalidArgument),
      );
      await expectLater(
        c.request('UNREGSTR', Uint8List(3)),
        throwsStatus(StatusCode.invalidArgument),
      );
      // A name with a byte after its terminating zero, a short name.
      for (final procedure in ['WATCH', 'UNWATCH']) {
        for (final payload in [
          bytes([0x61, 0, 0x62, 0, 0, 0, 0, 0]),
          bytes([0x61]),
        ]) {
          await expectLater(
            c.request(procedure, payload),
            throwsStatus(StatusCode.invalidArgument),
            reason: '$procedure $payload',
          );
        }
        // Not stream requests.
        await expectLater(
          c.streamRequest(procedure, Uint8List(0)).done,
          throwsStatus(StatusCode.invalidArgument),
          reason: procedure,
        );
      }
      // Nothing to give back.
      await expectLater(
        c.request('UNWATCH', Uint8List(0)),
        throwsStatus(StatusCode.notFound),
      );
      expect(h.service.watchCount, 0);
      await expectLater(
        c.request('LOOKUP', Name('npc').bytes),
        throwsStatus(StatusCode.invalidArgument),
      );
      await expectLater(
        c.request('FROB', Uint8List(0)),
        throwsStatus(StatusCode.unimplemented),
      );
      // Decodes, but re-encodes longer than 255 bytes: refused, and the
      // table stays encodable.
      final long = 'tcp://h/${'a b' * 80}';
      final raw = Uint8List.fromList([
        ...Name('npc').bytes,
        ...Uint8List(6),
        1,
        long.length,
        ...long.codeUnits,
      ]);
      await expectLater(
        c.request('REGISTER', raw),
        throwsStatus(StatusCode.invalidArgument),
      );
      expect(
        () => h.service.registerLocal(Name('npc'), [Uri.parse(long)]),
        throwsStatus(StatusCode.invalidArgument),
      );
      expect(h.service.table, isEmpty);
      // Plain messages are ignored, the channel stays usable.
      c.send('REGISTER', RegisterRequest(Name('npc')).encode());
      c.send('FROB', Uint8List(0));
      expect(await register(c, 'npc'), 1);
      expect(h.service.table.length, 1);
    });

    test('unregister: NOT_FOUND, PERMISSION_DENIED, then DOWN', () async {
      final (a, _) = h.link();
      final (b, _) = h.link();
      final watcher = Watcher(b);
      expect(await watcher.next, 'WATCHED');
      final id = await register(a, 'npc');
      expect(await watcher.next, 'UP npc/1');
      await expectLater(
        unregister(a, 'npc', 9),
        throwsStatus(StatusCode.notFound),
      );
      // Right id, wrong type.
      await expectLater(
        unregister(a, 'api', id),
        throwsStatus(StatusCode.notFound),
      );
      await expectLater(
        unregister(b, 'npc', id),
        throwsStatus(StatusCode.permissionDenied),
      );
      await unregister(a, 'npc', id);
      expect(await watcher.next, 'DOWN npc/1');
      expect(h.service.table, isEmpty);
      await expectLater(
        unregister(a, 'npc', id),
        throwsStatus(StatusCode.notFound),
      );
    });

    test('watch: snapshot events, the reply, then live UP and DOWN', () async {
      final (a, _) = h.link();
      final (b, _) = h.link();
      await register(a, 'npc', endpoints: [uriA]);
      await register(a, 'api');
      final watcher = Watcher(b);
      expect(await watcher.take(3), ['UP npc/1 $uriA', 'UP api/2', 'WATCHED']);
      final id = await register(a, 'npc', endpoints: [uriB]);
      expect(await watcher.next, 'UP npc/3 $uriB');
      await register(a, 'npc', instance: id, endpoints: [uriA]);
      expect(await watcher.next, 'UP npc/3 $uriA');
      await unregister(a, 'api', 2);
      expect(await watcher.next, 'DOWN api/2');
      expect(h.service.watchCount, 1);
    });

    test(
      'a watch on the registering channel has the UP before the reply',
      () async {
        final (a, _) = h.link(sync: true);
        final watcher = Watcher(a);
        expect(await watcher.next, 'WATCHED');
        final id = await register(a, 'npc');
        // Sent before the reply, and the reply is read in order.
        expect(watcher.log, ['WATCHED', 'UP npc/$id']);
      },
    );

    test('the reply follows the whole snapshot, even when it arrives in '
        'one burst', () async {
      final (a, _) = h.link();
      for (var i = 0; i < 20; i++) {
        await register(a, 'npc');
      }
      final watcher = Watcher(h.link(sync: true).$1);
      expect(await watcher.take(21), [
        for (var id = 1; id <= 20; id++) 'UP npc/${id.toRadixString(16)}',
        'WATCHED',
      ]);
      await register(a, 'api');
      expect(await watcher.next, 'UP api/15');
    });

    test('watch filtered by type', () async {
      final (a, _) = h.link();
      final (b, _) = h.link();
      await register(a, 'npc');
      await register(a, 'api');
      final watcher = Watcher(b, type: 'api');
      expect(await watcher.take(2), ['UP api/2', 'WATCHED']);
      await register(a, 'npc');
      await register(a, 'api');
      await unregister(a, 'npc', 1);
      await unregister(a, 'api', 2);
      expect(await watcher.take(2), ['UP api/4', 'DOWN api/2']);
      // An all-zero name watches everything: a second subscription on the
      // same channel, with its own snapshot.
      await watcher.watch(payload: Uint8List(8));
      expect(await watcher.take(3), ['UP npc/3', 'UP api/4', 'WATCHED']);
      expect(h.service.watchCount, 2);
    });

    test('subscriptions of one channel: each change is sent once', () async {
      final (a, _) = h.link();
      final (b, _) = h.link();
      final watcher = Watcher(b, type: 'npc');
      await watcher.watch(type: 'api');
      await watcher.watch();
      expect(await watcher.take(3), ['WATCHED', 'WATCHED', 'WATCHED']);
      expect(h.service.watchCount, 3);
      await register(a, 'npc');
      await register(a, 'api');
      await register(a, 'gpu');
      await unregister(a, 'npc', 1);
      await watcher.unwatch();
      // Once each, though npc and api match two subscriptions.
      expect(await watcher.take(5), [
        'UP npc/1',
        'UP api/2',
        'UP gpu/3',
        'DOWN npc/1',
        'UNWATCHED',
      ]);
      expect(h.service.watchCount, 2);
      // Without the subscription to every type, gpu is not covered.
      await register(a, 'gpu');
      await register(a, 'api');
      await watcher.unwatch(type: 'api');
      await register(a, 'api');
      await register(a, 'npc');
      await watcher.unwatch(type: 'npc');
      expect(await watcher.take(4), [
        'UP api/5',
        'UNWATCHED',
        'UP npc/7',
        'UNWATCHED',
      ]);
      expect(h.service.watchCount, 0);
      // Closing the channel ends every subscription it holds.
      await watcher.watch(type: 'npc');
      await watcher.watch(type: 'api');
      expect(h.service.watchCount, 2);
      await b.close();
      await until(() => h.service.watchCount == 0);
      expect(h.service.channelCount, 1);
    });

    test(
      'a channel holds at most maxWatchesPerChannel subscriptions',
      () async {
        final (a, _) = h.link();
        const max = NamingService.maxWatchesPerChannel;
        await Future.wait([
          for (var i = 0; i < max; i++)
            a.request('WATCH', WatchRequest(Name('t$i')).encode()),
        ]);
        expect(h.service.watchCount, max);
        await expectLater(
          a.request('WATCH', Uint8List(0)),
          throwsStatus(StatusCode.resourceExhausted),
        );
        // One it holds can be taken again; once given back, another fits.
        await a.request('WATCH', WatchRequest(Name('t0')).encode());
        await a.request('UNWATCH', WatchRequest(Name('t1')).encode());
        await a.request('WATCH', Uint8List(0));
        expect(h.service.watchCount, max);
      },
    );

    test('LOOKUP streams the records of a type, then ends', () async {
      final (a, _) = h.link();
      await register(a, 'npc', endpoints: [uriA, uriB]);
      await register(a, 'api');
      await register(a, 'npc');
      final lookup = a.streamRequest('LOOKUP', Name('npc').bytes);
      final items = await lookup.items.map(describe).toList();
      expect(items, ['UP npc/1 $uriA,$uriB', 'UP npc/3']);
      expect((await lookup.done).payload, isEmpty);
      final none = a.streamRequest('LOOKUP', Name('none').bytes);
      expect(await none.items.toList(), isEmpty);
      await expectLater(
        a.streamRequest('LOOKUP', Uint8List(0)).done,
        throwsStatus(StatusCode.invalidArgument),
      );
      // An all-zero name is "every type" for WATCH, but LOOKUP needs one.
      await expectLater(
        a.streamRequest('LOOKUP', Uint8List(8)).done,
        throwsStatus(StatusCode.invalidArgument),
      );
      expect(h.service.watchCount, 0);
    });

    test('WATCH and UNWATCH of one filter are counted', () async {
      final (a, _) = h.link();
      final (b, server) = h.link();
      final watcher = Watcher(b);
      expect(await watcher.next, 'WATCHED');
      expect(h.service.watchCount, 1);
      await register(a, 'npc');
      expect(await watcher.next, 'UP npc/1');
      // The same filter again: a fresh snapshot, one subscription held
      // twice.
      await watcher.watch();
      expect(await watcher.take(2), ['UP npc/1', 'WATCHED']);
      expect(h.service.watchCount, 1);
      // Given back once: still subscribed.
      await watcher.unwatch();
      expect(await watcher.next, 'UNWATCHED');
      await register(a, 'npc');
      expect(await watcher.next, 'UP npc/2');
      expect(h.service.watchCount, 1);
      // Given back again: nothing after the reply.
      await watcher.unwatch();
      expect(await watcher.next, 'UNWATCHED');
      expect(h.service.watchCount, 0);
      await register(a, 'npc');
      await unregister(a, 'npc', 1);
      // A third time: nothing to give back.
      await expectLater(watcher.unwatch(), throwsStatus(StatusCode.notFound));
      expect(await watcher.next, 'UNWATCH notFound');
      // Nothing arrived meanwhile: next is the snapshot of a new WATCH.
      await watcher.watch();
      expect(await watcher.take(3), ['UP npc/2', 'UP npc/3', 'WATCHED']);
      // Nothing is left outstanding on either side.
      expect(b.outgoingRequestCount, 0);
      expect(server.incomingRequestCount, 0);
    });

    test('channel close removes its records; watchers see DOWN', () async {
      final (a, _) = h.link();
      final (b, _) = h.link();
      final (c, _) = h.link();
      await register(a, 'npc');
      await register(b, 'api');
      await register(a, 'npc');
      final watcherA = Watcher(a);
      final watcherC = Watcher(c);
      expect(await watcherC.take(4), [
        'UP npc/1',
        'UP api/2',
        'UP npc/3',
        'WATCHED',
      ]);
      expect(await watcherA.take(4), hasLength(4));
      expect(h.service.watchCount, 2);
      await a.close();
      expect(await watcherC.take(2), ['DOWN npc/1', 'DOWN npc/3']);
      expect(h.service.table.keys.map((a) => '$a'), ['api/2']);
      await until(() => h.service.watchCount == 1);
      expect(h.service.channelCount, 2);
      // The server side closing has the same effect.
      await h.servers[1].close();
      expect(await watcherC.next, 'DOWN api/2');
      expect(h.service.table, isEmpty);
    });

    test('local registrations', () async {
      final (a, _) = h.link();
      final watcher = Watcher(a);
      expect(await watcher.next, 'WATCHED');
      expect(h.service.registerLocal(Services.naming, [uriA], instance: 1), 1);
      expect(await watcher.next, 'UP _ns/1 $uriA');
      expect(await register(a, 'npc'), 2);
      expect(await watcher.next, 'UP npc/2');
      await expectLater(
        register(a, '_ns', instance: 1),
        throwsStatus(StatusCode.alreadyExists),
      );
      await expectLater(
        unregister(a, '_ns', 1),
        throwsStatus(StatusCode.permissionDenied),
      );
      expect(
        () => h.service.unregisterLocal(ServiceAddress(Name('npc'), 2)),
        throwsStatus(StatusCode.permissionDenied),
      );
      expect(
        () => h.service.registerLocal(Name('x'), const [], instance: 2),
        throwsStatus(StatusCode.alreadyExists),
      );
      h.service.unregisterLocal(ServiceAddress(Services.naming, 1));
      expect(await watcher.next, 'DOWN _ns/1');
    });

    test('refuses endpoints a watcher could not decode', () async {
      final (c, _) = h.link();
      final watcher = Watcher(c);
      expect(await watcher.next, 'WATCHED');
      for (final text in [
        './>:x', // `%3E:x` once normalized: no scheme, does not parse
        '//10.0.0.5:9101/ws', // no scheme
        r'tcp:/.\\{:', // `tcp://%7B:` reparses without the empty port
        'tcp:/../..//', // `tcp://` reparses with an authority
      ]) {
        final w = ByteWriter()
          ..name(Name('npc'))
          ..u48(0)
          ..u8(1)
          ..string8(text);
        await expectLater(
          c.request('REGISTER', w.toBytes()),
          throwsStatus(StatusCode.invalidArgument),
          reason: text,
        );
        expect(
          () => h.service.registerLocal(Name('npc'), [Uri.parse(text)]),
          throwsStatus(StatusCode.invalidArgument),
          reason: text,
        );
      }
      expect(h.service.table, isEmpty);
      // The watch saw nothing, and still works.
      expect(await register(c, 'npc', endpoints: [uriA]), 1);
      expect(await watcher.next, 'UP npc/1 $uriA');
    });

    test('fuzz: every record the service accepts, a watcher decodes', () async {
      final client = NamingClient(
        Connector(h).call,
        reconnectDelay: reconnectDelay,
      );
      await client.start();
      await client.synced.timeout(timeout);
      final (raw, _) = h.link();
      final random = Random(1);
      var accepted = 0;
      for (var batch = 0; batch < 4; batch++) {
        final results = await Future.wait([
          for (var i = 0; i < 500; i++)
            raw
                .request('REGISTER', fuzzInput(random, i | random.nextInt(2)))
                .then(
                  (_) => true,
                  onError: (Object e) {
                    expect(
                      e,
                      isA<SwitchboardException>().having(
                        (e) => e.code,
                        'code',
                        isIn([
                          StatusCode.invalidArgument,
                          StatusCode.alreadyExists,
                        ]),
                      ),
                    );
                    return false;
                  },
                ),
        ]);
        accepted += results.where((ok) => ok).length;
      }
      expect(accepted, greaterThan(50));
      expect(h.service.table, hasLength(accepted));
      // Every UP decoded on the watching side: the mirror is complete.
      await until(() => client.table.length == accepted);
      expect(client.table, equals(h.service.table));
      for (final record in h.service.table.values) {
        expect(ServiceRecord.decode(record.encode()), record);
      }
      await client.close();
    });

    test('serve() of a channel already listened to keeps nothing', () async {
      final link = StreamChannelController<Uint8List>();
      final channel = TalkChannel(link.local, options: serverOptions);
      final taken = channel.messages.listen((_) {});
      expect(() => h.service.serve(channel), throwsStateError);
      expect(h.service.channelCount, 0);
      await taken.cancel();
      await channel.close();
      await pump();
      expect(h.service.channelCount, 0);
    });

    test('REGISTER racing a WATCH snapshot: exactly one UP', () async {
      // The snapshot, the reply and the subscription happen in one step,
      // so a registration lands either in the snapshot or after the reply.
      for (var round = 0; round < 50; round++) {
        final h = Harness();
        final (a, _) = h.link();
        final (b, _) = h.link(sync: round.isEven);
        final ups = <String>[];
        var replied = false;
        b.messages.listen((m) {
          if (m.procedureName == 'UP') {
            ups.add(replied ? 'live' : 'snapshot');
          }
        });
        final registered = register(a, 'npc');
        final watched = b
            .request('WATCH', Uint8List(0), ordered: true)
            .then((_) => replied = true);
        if (round % 4 >= 2) {
          await pump();
        }
        await registered;
        await watched;
        await until(() => ups.isNotEmpty);
        await pump();
        expect(ups, hasLength(1), reason: 'round $round');
        await h.close();
      }
    });

    test(
      'close ends subscriptions and closes channels with GOING_AWAY',
      () async {
        final (a, _) = h.link();
        final (b, _) = h.link();
        await register(a, 'npc');
        final watcher = Watcher(b);
        expect(await watcher.take(2), ['UP npc/1', 'WATCHED']);
        final eventsDone = h.service.events.toList();
        await h.service.close();
        await a.done;
        await b.done;
        expect(a.isOpen, isFalse);
        expect((await h.servers[0].done).known, StatusCode.goingAway);
        expect(h.service.watchCount, 0);
        expect(h.service.table, isEmpty);
        expect((await eventsDone).map(describeEvent), ['DOWN npc/1']);
        // The subscriptions ended first: no DOWN went to the channels.
        expect(watcher.log, ['UP npc/1', 'WATCHED']);
        // Channels served after close are closed at once.
        final (c, cServer) = h.link();
        await c.done;
        expect(c.isOpen, isFalse);
        expect((await cServer.done).known, StatusCode.goingAway);
      },
    );
  });

  group('idle subscriptions', () {
    test('an idle subscription costs no traffic and lives on', () {
      fakeAsync((async) {
        // Default options everywhere.
        final ns = NamingService();
        final link = StreamChannelController<Uint8List>();
        ns.serve(TalkChannel(link.local));
        final frames = <TalkFrame>[];
        link.foreign.stream.listen((f) => frames.add(TalkFrame.decode(f)));
        link.foreign.sink.add(
          TalkFrame(
            kind: TalkKind.message,
            procedure: Name('WATCH'),
            requestId: 1,
            payload: Uint8List(0),
          ).encode(),
        );
        async.elapse(const Duration(seconds: 1));
        // The reply to an empty snapshot, and nothing else: no EXTEND.
        expect(frames.single.kind, TalkKind.message);
        expect(frames.single.responseId, 1);
        expect(frames.single.payload, isEmpty);
        async.elapse(const Duration(minutes: 5));
        expect(frames, hasLength(1));
        expect(ns.watchCount, 1);
        // Still live: a change arrives as a one-way message.
        ns.registerLocal(Name('npc'), const []);
        async.flushMicrotasks();
        expect(frames, hasLength(2));
        expect(frames.last.procedure, Procedures.up);
        expect(frames.last.requestId, 0);
        expect(frames.last.responseId, 0);
        unawaited(ns.close());
        async.flushMicrotasks();
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('outlives every request and reply timeout', () {
      fakeAsync((async) {
        final h = Harness();
        final (a, _) = h.link();
        final lines = <String>[];
        a.messages.listen((m) => lines.add(describe(m)));
        a
            .request('WATCH', Uint8List(0), ordered: true)
            .then((_) => lines.add('WATCHED'))
            .ignore();
        // 10 times the watcher's request timeout, 15 times the service's
        // reply timeout.
        async.elapse(clientOptions.requestTimeout * 10);
        expect(lines, ['WATCHED']);
        expect(h.service.watchCount, 1);
        final (b, _) = h.link();
        unawaited(register(b, 'npc'));
        async.elapse(ms10);
        expect(lines, ['WATCHED', 'UP npc/1']);
        async.elapse(clientOptions.requestTimeout * 10);
        expect(h.service.watchCount, 1);
        expect(a.isOpen, isTrue);
        unawaited(h.close());
        async.flushMicrotasks();
        expect(async.pendingTimers, isEmpty);
      });
    });
  });

  group('assignment hold', () {
    const hold = Duration(seconds: 2);

    test('holds REGISTER for any id, not for a given id', () {
      fakeAsync((async) {
        final h = Harness(assignmentHold: hold);
        expect(h.service.isHoldingAssignments, isTrue);
        final (a, _) = h.link();
        final (b, _) = h.link();
        int? any;
        Object? error;
        register(a, 'npc').then(
          (id) => any = id,
          onError: (Object e) {
            error = e;
          },
        );
        int? given;
        register(b, 'api', instance: 1).then((id) => given = id);
        // Invalid requests are refused at once.
        Object? invalid;
        register(a, '').then(
          (_) {},
          onError: (Object e) {
            invalid = e;
          },
        );
        async.elapse(ms10);
        expect(given, 1);
        expect(invalid, isStatus(StatusCode.invalidArgument));
        expect(any, isNull);
        // Kept alive well past the request and reply timeouts.
        async.elapse(hold - ms50);
        expect(any, isNull);
        expect(error, isNull);
        expect(h.service.isHoldingAssignments, isTrue);
        async.elapse(ms50 * 2);
        expect(h.service.isHoldingAssignments, isFalse);
        expect(any, 2);
        // Over: assigned at once.
        int? later;
        register(b, 'npc').then((id) => later = id);
        async.elapse(ms10);
        expect(later, 3);
        unawaited(h.close());
        async.flushMicrotasks();
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('a held REGISTER gets one EXTEND, declaring the time left in the '
        'hold', () {
      fakeAsync((async) {
        final h = Harness(assignmentHold: hold);
        async.elapse(const Duration(milliseconds: 500));
        final (a, _) = h.link();
        final declared = <(Duration?, Duration?)>[];
        int? id;
        a
            .startRequest(
              'REGISTER',
              RegisterRequest(Name('npc')).encode(),
              onExtend: (deadline, renew) => declared.add((deadline, renew)),
            )
            .response
            .then((m) => id = RegisterResponse.decode(m.payload).instance);
        async.elapse(ms10);
        // 1.5 s were left at receipt; the wire carries the service node's
        // buffer on top.
        expect(declared, [
          (
            const Duration(milliseconds: 1500) + serverOptions.extendBuffer,
            null,
          ),
        ]);
        // Well past the request and reply timeouts: nothing more is sent.
        async.elapse(const Duration(milliseconds: 1480));
        expect(id, isNull);
        expect(declared, hasLength(1));
        async.elapse(ms10 * 2);
        expect(id, 1);
        expect(declared, hasLength(1));
        unawaited(h.close());
        async.flushMicrotasks();
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('a service surviving a restart keeps its id', () {
      fakeAsync((async) {
        var h = Harness();
        final connector = Connector(h);
        final survivor = NamingClient(
          connector.call,
          reconnectDelay: const Duration(milliseconds: 300),
        );
        final assigned = <int>[];
        unawaited(survivor.start());
        unawaited(
          survivor.register(Name('npc'), [uriA], onAssigned: assigned.add),
        );
        async.elapse(ms10);
        expect(assigned, [1]);

        // The naming service restarts; a newcomer connects before the
        // survivor's reconnect delay is over.
        final old = h;
        h = Harness(assignmentHold: hold);
        connector.harness = h;
        unawaited(old.close());
        final newcomer = NamingClient(
          Connector(h).call,
          reconnectDelay: reconnectDelay,
        );
        unawaited(newcomer.start());
        int? fresh;
        newcomer.register(Name('api'), [uriB]).then((id) => fresh = id);
        async.elapse(ms10);
        // The newcomer is synced, its registration held.
        expect(newcomer.isSynced, isTrue);
        expect(fresh, isNull);
        async.elapse(const Duration(milliseconds: 500));
        expect(survivor.isSynced, isTrue);
        expect(h.service.table.keys.map((a) => '$a'), ['npc/1']);
        async.elapse(hold);
        expect(fresh, 2);
        expect(assigned, [1]);
        expect(h.service.table.keys.map((a) => '$a'), ['npc/1', 'api/2']);

        unawaited(survivor.close());
        unawaited(newcomer.close());
        unawaited(h.close());
        async.flushMicrotasks();
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('dropped and closed: held requests go, no timers stay', () {
      fakeAsync((async) {
        final h = Harness(assignmentHold: hold);
        final (a, _) = h.link();
        final (b, _) = h.link();
        Object? aError;
        Object? bError;
        register(a, 'npc').then(
          (_) {},
          onError: (Object e) {
            aError = e;
          },
        );
        register(b, 'npc').then(
          (_) {},
          onError: (Object e) {
            bError = e;
          },
        );
        async.elapse(ms10);
        unawaited(a.close());
        async.elapse(ms10);
        expect(aError, isStatus(StatusCode.cancelled));
        unawaited(h.service.close());
        async.flushMicrotasks();
        expect(bError, isStatus(StatusCode.goingAway));
        expect(h.service.table, isEmpty);
        unawaited(h.close());
        async.flushMicrotasks();
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('a held REGISTER the requester cancels is never registered', () {
      fakeAsync((async) {
        final h = Harness(assignmentHold: hold);
        final (a, server) = h.link();
        Object? error;
        a
            .request(
              'REGISTER',
              RegisterRequest(Name('npc')).encode(),
              timeout: Duration.zero,
            )
            .then(
              (_) {},
              onError: (Object e) {
                error = e;
              },
            );
        async.elapse(ms10);
        // A stream request is the way to cancel a request explicitly.
        final stream = a.streamRequest(
          'REGISTER',
          RegisterRequest(Name('api')).encode(),
        );
        Object? streamError;
        stream.done.then(
          (_) {},
          onError: (Object e) {
            streamError = e;
          },
        );
        async.elapse(ms10);
        stream.cancel();
        async.elapse(ms10);
        expect(streamError, isStatus(StatusCode.cancelled));
        expect(server.incomingRequestCount, 1);
        async.elapse(hold);
        expect(error, isNull);
        expect(h.service.table.keys.map((a) => '$a'), ['npc/1']);
        expect(server.incomingRequestCount, 0);
        unawaited(h.close());
        async.flushMicrotasks();
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('rejects a negative hold', () {
      expect(
        () => NamingService(assignmentHold: const Duration(seconds: -1)),
        throwsArgumentError,
      );
    });
  });

  group('NamingClient', () {
    late Harness h;
    late Connector connector;
    final clients = <NamingClient>[];

    NamingClient newClient(Connector connector) {
      final client = NamingClient(
        connector.call,
        reconnectDelay: reconnectDelay,
      );
      clients.add(client);
      return client;
    }

    setUp(() {
      h = Harness();
      connector = Connector(h);
    });

    tearDown(() async {
      for (final client in clients) {
        await client.close();
      }
      clients.clear();
      await h.close();
    });

    test('registers, syncs and mirrors the table', () async {
      final raw = h.link().$1;
      await register(raw, 'api', endpoints: [uriB]);
      final client = newClient(connector);
      final events = <String>[];
      client.events.listen((e) => events.add(describeEvent(e)));
      final registered = client.register(Name('npc'), [uriA]);
      expect(client.isConnected, isFalse);
      await client.start();
      expect(client.isConnected, isTrue);
      expect(await registered.timeout(timeout), 2);
      await client.synced.timeout(timeout);
      expect(client.isSynced, isTrue);
      expect(client.table.keys.map((a) => '$a'), ['api/1', 'npc/2']);
      expect(client.table[ServiceAddress(Name('npc'), 2)]!.endpoints, [uriA]);
      await register(raw, 'api');
      await until(() => client.table.length == 3);
      await unregister(raw, 'api', 1);
      await until(() => client.table.length == 2);
      // Snapshot in table order.
      expect(events, [
        'UP api/1 $uriB',
        'UP npc/2 $uriA',
        'UP api/3',
        'DOWN api/1',
      ]);
    });

    test('synced means complete, even over a link that delivers in '
        'bursts', () async {
      final raw = h.link().$1;
      for (var i = 0; i < 20; i++) {
        await register(raw, 'npc');
      }
      final client = newClient(Connector(h, sync: true));
      int? atSync;
      client.synced.then((_) => atSync = client.table.length).ignore();
      await client.start();
      await client.synced.timeout(timeout);
      expect(atSync, 20);
      // The events after the reply are live.
      final id = await register(raw, 'api');
      await until(() => client.table.length == 21);
      expect(client.table.keys.last, ServiceAddress(Name('api'), id));
      // A registration through the client is in its table once done.
      final own = await client.register(Name('own'), []);
      expect(client.table.keys, contains(ServiceAddress(Name('own'), own)));
    });

    test('register after sync is mirrored when it completes', () async {
      final client = newClient(connector);
      await client.start();
      await client.synced.timeout(timeout);
      final id = await client.register(Name('npc'), [uriA]);
      // The UP item precedes the response on the same channel.
      expect(client.table[ServiceAddress(Name('npc'), id)]?.endpoints, [uriA]);
      expect(await client.register(Name('npc'), [], instance: 7), 7);
      await expectLater(
        client.register(Name('api'), [], instance: 7),
        throwsStatus(StatusCode.alreadyExists),
      );
      await expectLater(
        client.register(Name(''), []),
        throwsStatus(StatusCode.invalidArgument),
      );
      expect(h.service.table.length, 2);
    });

    test('unregister', () async {
      final client = newClient(connector);
      await client.start();
      final id = await client.register(Name('npc'), [uriA]);
      await client.synced.timeout(timeout);
      await expectLater(
        client.unregister(Name('npc'), id + 1),
        throwsStatus(StatusCode.notFound),
      );
      await client.unregister(Name('npc'), id);
      expect(h.service.table, isEmpty);
      await until(() => client.table.isEmpty);
      // Not re-registered after a reconnect.
      await connector.servers.last.close();
      await until(() => connector.calls == 2 && client.isSynced);
      expect(h.service.table, isEmpty);
    });

    test('two clients see each other', () async {
      final a = newClient(connector);
      final b = newClient(connector);
      final idA = await a.start().then((_) => a.register(Name('npc'), [uriA]));
      final idB = await b.start().then((_) => b.register(Name('api'), [uriB]));
      await until(() => a.table.length == 2 && b.table.length == 2);
      expect(a.table.keys, unorderedEquals(b.table.keys));
      expect(a.table[ServiceAddress(Name('api'), idB)]!.endpoints, [uriB]);
      expect(b.table[ServiceAddress(Name('npc'), idA)]!.endpoints, [uriA]);
      final downs = <String>[];
      b.events.where((e) => !e.up).listen((e) => downs.add(describeEvent(e)));
      await a.close();
      await until(() => downs.isNotEmpty);
      expect(downs, ['DOWN npc/$idA']);
      expect(b.table.keys.map((a) => '$a'), ['api/$idB']);
    });

    test('reconnects, re-registers the same ids, resyncs with DOWN', () async {
      final client = newClient(connector);
      final other = newClient(Connector(h));
      await client.start();
      final id = await client.register(Name('npc'), [uriA]);
      await other.start();
      final otherId = await other.register(Name('api'), [uriB]);
      await until(() => client.table.length == 2);
      final firstSynced = client.synced;

      final events = <String>[];
      client.events.listen((e) => events.add(describeEvent(e)));
      connector.down = true;
      await connector.servers.last.close();
      await until(() => !client.isConnected);
      expect(client.isSynced, isFalse);
      // The stale table is kept.
      expect(client.table.length, 2);
      expect(identical(client.synced, firstSynced), isFalse);
      // Meanwhile the service lost our record and the other one went away.
      expect(h.service.table.keys.map((a) => '$a'), ['api/$otherId']);
      await other.close();
      expect(h.service.table, isEmpty);
      await until(() => connector.calls >= 3);

      connector.down = false;
      await client.synced.timeout(timeout);
      expect(client.isConnected, isTrue);
      expect(h.service.table.keys.map((a) => '$a'), ['npc/$id']);
      expect(client.table.keys.map((a) => '$a'), ['npc/$id']);
      expect(events, ['DOWN api/$otherId']);
    });

    test('a taken id is replaced by a new one on reconnect', () async {
      final client = newClient(connector);
      await client.start();
      final id = await client.register(Name('npc'), [uriA]);
      await client.synced.timeout(timeout);
      connector.down = true;
      await connector.servers.last.close();
      await until(() => h.service.table.isEmpty);
      final thief = h.link().$1;
      expect(await register(thief, 'api', instance: id), id);
      connector.down = false;
      await until(() => client.isSynced && client.table.length == 2);
      final mine = h.service.table.keys.singleWhere(
        (a) => a.type == Name('npc'),
      );
      expect(mine.instance, isNot(id));
      // The new id is the one remembered from now on.
      await client.unregister(Name('npc'), mine.instance);
      expect(h.service.table.keys.map((a) => '$a'), ['api/$id']);
    });

    test('register while disconnected completes after reconnect', () async {
      final client = newClient(connector);
      connector.down = true;
      unawaited(client.start());
      await until(() => connector.calls >= 2);
      final registered = client.register(Name('npc'), [uriA], instance: 4);
      var done = false;
      unawaited(registered.then((_) => done = true));
      await Future<void>.delayed(reconnectDelay * 3);
      expect(done, isFalse);
      expect(client.isConnected, isFalse);
      connector.down = false;
      expect(await registered.timeout(timeout), 4);
      expect(h.service.table.keys.map((a) => '$a'), ['npc/4']);
      await client.synced.timeout(timeout);
    });

    test('service close: GOING_AWAY, reconnect to a new service', () async {
      final client = newClient(connector);
      await client.start();
      final id = await client.register(Name('npc'), [uriA]);
      await client.synced.timeout(timeout);
      final calls = connector.calls;
      await h.service.close();
      await until(() => !client.isConnected);
      // Keeps trying against the closed service.
      await until(() => connector.calls >= calls + 2);
      expect(client.isSynced, isFalse);
      final old = h;
      h = Harness();
      connector.harness = h;
      await old.close();
      await client.synced.timeout(timeout);
      expect(h.service.table.keys.map((a) => '$a'), ['npc/$id']);
      expect(client.table.keys.map((a) => '$a'), ['npc/$id']);
    });

    test('a WATCH without a reply is a loss of the service', () async {
      // The service never answers.
      final silent = <StreamChannelController<Uint8List>>[];
      var calls = 0;
      final client = NamingClient(() async {
        calls++;
        final link = StreamChannelController<Uint8List>();
        silent.add(link);
        link.local.stream.listen((_) {});
        return TalkChannel(
          link.foreign,
          options: const TalkOptions(requestTimeout: ms50),
        );
      }, reconnectDelay: reconnectDelay);
      clients.add(client);
      await client.start();
      await until(() => calls >= 3);
      expect(client.isSynced, isFalse);
      await client.close();
      for (final link in silent) {
        await link.local.sink.close();
      }
    });

    test('connect errors are retried', () async {
      final client = newClient(connector);
      connector.down = true;
      var started = false;
      unawaited(client.start().then((_) => started = true));
      await until(() => connector.calls >= 3);
      expect(started, isFalse);
      connector.down = false;
      await client.synced.timeout(timeout);
      expect(started, isTrue);
    });

    test('close fails pending futures and stops', () async {
      final client = newClient(connector);
      connector.down = true;
      final started = client.start();
      final registered = client.register(Name('npc'), []);
      final synced = client.synced;
      await until(() => connector.calls >= 2);
      await client.close();
      await started;
      await expectLater(registered, throwsStatus(StatusCode.cancelled));
      await expectLater(synced, throwsStatus(StatusCode.cancelled));
      final calls = connector.calls;
      await Future<void>.delayed(reconnectDelay * 3);
      expect(connector.calls, calls);
      await expectLater(
        client.register(Name('npc'), []),
        throwsStatus(StatusCode.failedPrecondition),
      );
      expect(await client.events.toList(), isEmpty);
    });

    test('hasSynced and firstSynced outlive a loss', () async {
      final client = newClient(connector);
      expect(client.hasSynced, isFalse);
      var first = false;
      unawaited(client.firstSynced.then((_) => first = true));
      await client.start();
      await client.synced.timeout(timeout);
      await pump();
      expect(first, isTrue);
      expect(client.hasSynced, isTrue);
      final firstSynced = client.firstSynced;
      connector.down = true;
      await connector.servers.last.close();
      await until(() => !client.isConnected);
      expect(client.isSynced, isFalse);
      expect(client.hasSynced, isTrue);
      expect(identical(client.firstSynced, firstSynced), isTrue);
      await client.firstSynced;
      var resynced = false;
      // Fails with CANCELLED when the client is closed after the test.
      client.synced.then((_) => resynced = true).ignore();
      await pump();
      expect(resynced, isFalse);
    });

    test(
      'firstSynced fails with CANCELLED if closed before any sync',
      () async {
        connector.down = true;
        final client = newClient(connector);
        unawaited(client.start());
        final firstSynced = client.firstSynced;
        await until(() => connector.calls >= 2);
        await client.close();
        await expectLater(firstSynced, throwsStatus(StatusCode.cancelled));
        expect(client.hasSynced, isFalse);
      },
    );

    test('metadata is published, mirrored and re-registered', () async {
      final client = newClient(connector);
      final watcher = newClient(Connector(h));
      await watcher.start();
      await client.start();
      final meta = text('{"models":["a"]}');
      final id = await client.register(Name('gpu'), [uriA], metadata: meta);
      // The caller's buffer is copied.
      meta.fillRange(0, meta.length, 0);
      final address = ServiceAddress(Name('gpu'), id);
      await until(() => watcher.table[address] != null);
      expect(utf8.decode(watcher.table[address]!.metadata), '{"models":["a"]}');
      // A new registration of the same id replaces the metadata.
      final events = <String>[];
      watcher.events.listen((e) => events.add(describeEvent(e)));
      await client.register(
        Name('gpu'),
        [uriA],
        instance: id,
        metadata: text('{"models":["b"]}'),
      );
      await until(() => events.isNotEmpty);
      expect(events, ['UP gpu/$id $uriA meta {"models":["b"]}']);
      // After a reconnect the remembered registration carries it again.
      await connector.servers.last.close();
      await until(() => connector.calls == 2 && client.isSynced);
      await until(() => h.service.table.isNotEmpty);
      expect(
        utf8.decode(h.service.table[address]!.metadata),
        '{"models":["b"]}',
      );
      await expectLater(
        client.register(Name('gpu'), [
          uriA,
        ], metadata: Uint8List(maxMetadataLength + 1)),
        throwsArgumentError,
      );
    });

    test('register refuses endpoints a watcher could not decode', () async {
      final client = newClient(connector);
      for (final text in ['./>:x', '//10.0.0.5:9101/ws', r'tcp:/.\\{:']) {
        await expectLater(
          client.register(Name('npc'), [uriA, Uri.parse(text)]),
          throwsArgumentError,
          reason: text,
        );
      }
      await client.start();
      await client.synced.timeout(timeout);
      expect(h.service.table, isEmpty);
    });

    test('a re-registration refused on a live channel is retried', () async {
      // Refuses the second REGISTER once.
      var registers = 0;
      final scripted = ScriptedConnector((m) {
        if (m.procedureName != 'REGISTER') {
          return;
        }
        registers++;
        if (registers == 2) {
          m.replyAbort(Status.of(StatusCode.internal, 'try again'));
        } else {
          final id = RegisterRequest.decode(m.payload).requestedInstance;
          m.reply(RegisterResponse(id == 0 ? 1 : id).encode());
        }
      });
      addTearDown(scripted.close);
      final client = NamingClient(
        scripted.call,
        reconnectDelay: reconnectDelay,
      );
      clients.add(client);
      final assigned = <int>[];
      await client.start();
      expect(
        await client.register(Name('npc'), [uriA], onAssigned: assigned.add),
        1,
      );
      await client.synced.timeout(timeout);
      await scripted.servers.first.close();
      // Reconnected; the re-registration is refused, then retried on the
      // same channel after the reconnect delay.
      await until(() => registers == 3);
      await Future<void>.delayed(reconnectDelay * 2);
      expect(registers, 3);
      expect(scripted.servers, hasLength(2));
      expect(client.isConnected, isTrue);
      expect(client.isSynced, isTrue);
      expect(assigned, [1]);
    });

    test('a refused UNREGSTR drops the channel', () async {
      final registered = <String>[];
      final scripted = ScriptedConnector((m) {
        switch (m.procedureName) {
          case 'REGISTER':
            final request = RegisterRequest.decode(m.payload);
            registered.add('${request.type}');
            final id = request.requestedInstance;
            m.reply(
              RegisterResponse(id == 0 ? registered.length : id).encode(),
            );
          case 'UNREGSTR':
            m.replyAbort(Status.of(StatusCode.internal, 'cannot'));
        }
      });
      addTearDown(scripted.close);
      final client = NamingClient(
        scripted.call,
        reconnectDelay: reconnectDelay,
      );
      clients.add(client);
      await client.start();
      await client.register(Name('api'), [uriB]);
      final id = await client.register(Name('npc'), [uriA]);
      await client.synced.timeout(timeout);
      // The record may still be registered: the channel goes, and the
      // record with it.
      await expectLater(
        client.unregister(Name('npc'), id),
        throwsStatus(StatusCode.internal),
      );
      await until(() => scripted.servers.length == 2 && client.isSynced);
      expect(scripted.servers.first.isOpen, isFalse);
      // Only the remembered registration is made again.
      expect(registered, ['api', 'npc', 'api']);
    });

    test(
      'a REGISTER without an answer drops the channel: no phantom',
      () async {
        final lossy = LossyConnector(h);
        final client = NamingClient(lossy.call, reconnectDelay: reconnectDelay);
        clients.add(client);
        final published = <String>[];
        h.service.events.listen((e) => published.add(describeEvent(e)));
        await client.start();
        final kept = await client.register(Name('api'), [uriB]);
        await client.synced.timeout(timeout);
        // The naming service registers it; the answer is lost.
        lossy.dropToClient = isFinalResponse;
        await expectLater(
          client.register(Name('npc'), [uriA]),
          throwsStatus(StatusCode.deadlineExceeded),
        );
        lossy.dropToClient = (_) => false;
        await until(() => lossy.calls == 2 && client.isSynced);
        expect(published, [
          'UP api/$kept $uriB',
          'UP npc/2 $uriA',
          // Dropped with the channel, and the remembered one restored.
          'DOWN api/$kept',
          'DOWN npc/2',
          'UP api/$kept $uriB',
        ]);
        expect(h.service.table.keys.map((a) => '$a'), ['api/$kept']);
        expect(client.table.keys.map((a) => '$a'), ['api/$kept']);
        // Not remembered.
        await expectLater(
          client.unregister(Name('npc'), 2),
          throwsStatus(StatusCode.notFound),
        );
      },
    );

    test('an UNREGSTR without an answer drops the channel', () async {
      final lossy = LossyConnector(h);
      final client = NamingClient(lossy.call, reconnectDelay: reconnectDelay);
      clients.add(client);
      await client.start();
      final kept = await client.register(Name('api'), [uriB]);
      final gone = await client.register(Name('npc'), [uriA]);
      await client.synced.timeout(timeout);
      // The request never reaches the naming service.
      lossy.dropToService = isRequestFor('UNREGSTR');
      await expectLater(
        client.unregister(Name('npc'), gone),
        throwsStatus(StatusCode.deadlineExceeded),
      );
      lossy.dropToService = (_) => false;
      await until(() => lossy.calls == 2 && client.isSynced);
      // The record went away with the channel and is not registered again.
      expect(h.service.table.keys.map((a) => '$a'), ['api/$kept']);
      expect(client.table.keys.map((a) => '$a'), ['api/$kept']);
    });

    test(
      'the same id registered twice in flight: the later one wins',
      () async {
        final client = newClient(connector);
        await client.start();
        await client.synced.timeout(timeout);
        final first = client.register(Name('npc'), [uriA], instance: 7);
        final second = client.register(Name('npc'), [uriB], instance: 7);
        expect(await first, 7);
        expect(await second, 7);
        expect(h.service.table.values.single.endpoints, [uriB]);
        await client.unregister(Name('npc'), 7);
        expect(h.service.table, isEmpty);
        await expectLater(
          client.unregister(Name('npc'), 7),
          throwsStatus(StatusCode.notFound),
        );
        // Nothing comes back after a reconnect.
        await connector.servers.last.close();
        await until(() => connector.calls == 2 && client.isSynced);
        expect(h.service.table, isEmpty);
      },
    );

    test('registering a registered id again replaces it', () async {
      final client = newClient(connector);
      await client.start();
      final id = await client.register(Name('npc'), [uriA]);
      final assigned = <int>[];
      expect(
        await client.register(
          Name('npc'),
          [uriB],
          instance: id,
          onAssigned: assigned.add,
        ),
        id,
      );
      expect(assigned, [id]);
      expect(h.service.table.values.single.endpoints, [uriB]);
      // Only the newer registration is remembered.
      await connector.servers.last.close();
      await until(() => connector.calls == 2 && client.isSynced);
      expect(h.service.table.values.single.endpoints, [uriB]);
      await client.unregister(Name('npc'), id);
      expect(h.service.table, isEmpty);
    });

    test('a replacement refused before sending drops the old record', () async {
      final limited = Connector(
        h,
        options: const TalkOptions(maxOutgoingRequests: 1),
      );
      final client = newClient(limited);
      await client.start();
      await client.synced.timeout(timeout);
      final type = Name('npc');
      await client.register(type, [uriA], instance: 1);
      // This request holds the only outgoing request slot while a
      // replacement of the already registered record is attempted.
      final other = client.register(type, [uriA], instance: 2);
      await expectLater(
        client.register(type, [uriB], instance: 1),
        throwsStatus(StatusCode.resourceExhausted),
      );
      await other.timeout(timeout);
      await until(() => !h.service.table.containsKey(ServiceAddress(type, 1)));
      await until(() => limited.calls == 2 && client.isSynced);
      expect(h.service.table.keys, [ServiceAddress(type, 2)]);
    });

    test('a refused replacement also retires an in-flight REGISTER', () async {
      final limited = Connector(
        h,
        options: const TalkOptions(maxOutgoingRequests: 1),
      );
      final client = newClient(limited);
      await client.start();
      await client.synced.timeout(timeout);
      final type = Name('npc');
      final first = client.register(type, [uriA], instance: 1);
      final failed = expectLater(
        first,
        throwsStatus(StatusCode.resourceExhausted),
      );
      await expectLater(
        client.register(type, [uriB], instance: 1),
        throwsStatus(StatusCode.resourceExhausted),
      );
      await failed;
      await until(() => limited.calls == 2 && client.isSynced);
      expect(h.service.table, isEmpty);
    });

    test('a refused replacement of a registration never made keeps the '
        'channel', () async {
      final other = h.link().$1;
      expect(await register(other, 'npc', instance: 5), 5);
      final client = newClient(connector);
      connector.down = true;
      unawaited(client.start());
      await until(() => connector.calls >= 2);
      // Neither is sent before the next connect.
      final first = client.register(Name('npc'), [uriA], instance: 5);
      final firstFailed = expectLater(
        first,
        throwsStatus(StatusCode.alreadyExists),
      );
      final replacement = client.register(Name('npc'), [uriB], instance: 5);
      final failedCalls = connector.calls;
      connector.down = false;
      await expectLater(replacement, throwsStatus(StatusCode.alreadyExists));
      await firstFailed;
      await client.synced.timeout(timeout);
      // Nothing of this client's was published: the channel stays.
      await Future<void>.delayed(reconnectDelay * 5);
      expect(connector.calls, failedCalls + 1);
      expect(client.isSynced, isTrue);
    });

    test('a replacement unregistered in flight, then refused, drops the '
        'old record', () async {
      final h = Harness(assignmentHold: const Duration(seconds: 1));
      addTearDown(h.close);
      // On the first channel, the naming service takes one request at a
      // time from this client.
      var calls = 0;
      final client = NamingClient(() async {
        calls++;
        final link = StreamChannelController<Uint8List>();
        h.service.serve(
          TalkChannel(
            link.local,
            options: calls == 1
                ? const TalkOptions(
                    replyTimeout: Duration(milliseconds: 200),
                    maxIncomingRequests: 1,
                  )
                : serverOptions,
          ),
        );
        return TalkChannel(link.foreign, options: clientOptions);
      }, reconnectDelay: reconnectDelay);
      clients.add(client);
      await client.start();
      await client.synced.timeout(timeout);
      final type = Name('npc');
      await client.register(type, [uriA], instance: 1);
      // Held until the assignment hold ends: the service refuses what
      // follows on the channel meanwhile.
      final held = client.register(Name('api'), [uriA]);
      await pump();
      final replacement = client.register(type, [uriB], instance: 1);
      await client.unregister(type, 1);
      await expectLater(replacement, throwsStatus(StatusCode.cancelled));
      await until(() => !h.service.table.containsKey(ServiceAddress(type, 1)));
      // The held registration is made again on the next channel.
      await held.timeout(const Duration(seconds: 3));
      expect(calls, 2);
      expect(h.service.table.keys.map((a) => a.type), [Name('api')]);
    });

    test('register, unregister and register again of one id while the '
        'first REGISTER is in flight keeps the second record', () async {
      final client = newClient(connector);
      await client.start();
      await client.synced.timeout(timeout);
      final published = <String>[];
      h.service.events.listen((e) => published.add(describeEvent(e)));
      final type = Name('npc');
      final first = client.register(type, [uriA], instance: 7);
      final cancelled = expectLater(first, throwsStatus(StatusCode.cancelled));
      await client.unregister(type, 7);
      expect(await client.register(type, [uriB], instance: 7), 7);
      await cancelled;
      await Future<void>.delayed(ms50);
      // The first REGISTER's late answer sends no UNREGSTR: the second
      // REGISTER, after it on the channel, replaced its record.
      expect(published, ['UP npc/7 $uriA', 'UP npc/7 $uriB']);
      expect(h.service.table.values.single.endpoints, [uriB]);
      expect(connector.calls, 1);
      await client.unregister(type, 7);
      expect(h.service.table, isEmpty);
    });

    test('a superseded registration given a new id does not stay '
        'published', () async {
      final client = newClient(connector);
      await client.start();
      await client.synced.timeout(timeout);
      final type = Name('npc');
      final assigned = <int>[];
      expect(
        await client.register(
          type,
          [uriA],
          instance: 5,
          onAssigned: assigned.add,
        ),
        5,
      );
      // The naming service restarts; meanwhile another channel takes 5.
      connector.down = true;
      final h2 = Harness(assignmentHold: const Duration(milliseconds: 300));
      addTearDown(h2.close);
      connector.harness = h2;
      await h.service.close();
      await until(() => !client.isConnected);
      final other = h2.link().$1;
      expect(await register(other, 'npc', instance: 5), 5);
      connector.down = false;
      // REGISTER 5 is refused, the REGISTER for any id that follows is held.
      await until(() => client.isConnected);
      await Future<void>.delayed(ms50);
      // 5 is free again and the application registers it again: the held
      // registration is superseded, and its answer comes with another id.
      await unregister(other, 'npc', 5);
      expect(await client.register(type, [uriB], instance: 5), 5);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(h2.service.table.keys, [ServiceAddress(type, 5)]);
      expect(h2.service.table.values.single.endpoints, [uriB]);
      expect(assigned, [5]);
    });

    test('unregister while the REGISTER is in flight', () async {
      final client = newClient(connector);
      await client.start();
      await client.synced.timeout(timeout);
      final published = <String>[];
      h.service.events.listen((e) => published.add(describeEvent(e)));
      final registered = client.register(Name('npc'), [uriA], instance: 7);
      // Completes at once: nothing is registered on the channel yet.
      await client.unregister(Name('npc'), 7);
      await expectLater(registered, throwsStatus(StatusCode.cancelled));
      // The naming service registered it anyway; the late answer is
      // followed by an UNREGSTR.
      await until(() => published.length == 2);
      expect(published, ['UP npc/7 $uriA', 'DOWN npc/7']);
      expect(h.service.table, isEmpty);
      await connector.servers.last.close();
      await until(() => connector.calls == 2 && client.isSynced);
      expect(h.service.table, isEmpty);
    });

    test('resync: a record whose endpoints changed meanwhile is UP', () async {
      final raw = h.link().$1;
      final id = await register(raw, 'api', endpoints: [uriA]);
      final client = newClient(connector);
      await client.start();
      await client.synced.timeout(timeout);
      final events = <String>[];
      client.events.listen((e) => events.add(describeEvent(e)));
      connector.down = true;
      await connector.servers.last.close();
      await until(() => !client.isConnected);
      await register(raw, 'api', instance: id, endpoints: [uriB]);
      connector.down = false;
      await client.synced.timeout(timeout);
      expect(events, ['UP api/$id $uriB']);
      expect(client.table.values.single.endpoints, [uriB]);
    });

    test('close leaves no timers, connected or reconnecting', () {
      fakeAsync((async) {
        final h = Harness();
        final connector = Connector(h);
        final client = NamingClient(
          connector.call,
          reconnectDelay: reconnectDelay,
        );
        unawaited(client.start());
        unawaited(client.register(Name('npc'), [uriA]));
        async.elapse(ms10);
        expect(client.isSynced, isTrue);
        async.elapse(const Duration(seconds: 1));
        expect(client.isSynced, isTrue);
        // Lose the service and close during the reconnect delay.
        connector.down = true;
        unawaited(connector.servers.last.close());
        async.elapse(reconnectDelay * 3);
        expect(client.isConnected, isFalse);
        unawaited(client.close());
        async.flushMicrotasks();
        expect(async.pendingTimers, isEmpty);

        // Connected.
        final second = NamingClient(
          Connector(h).call,
          reconnectDelay: reconnectDelay,
        );
        unawaited(second.start());
        async.elapse(ms10);
        expect(second.isSynced, isTrue);
        expect(h.service.watchCount, 1);
        unawaited(second.close());
        async.flushMicrotasks();
        expect(h.service.watchCount, 0);
        expect(async.pendingTimers, isEmpty);
        unawaited(h.close());
        async.flushMicrotasks();
        expect(async.pendingTimers, isEmpty);
      });
    });
  });
}

/// A [TalkConnector] to a scripted naming service: `WATCH` is answered at
/// once (an empty snapshot); every other request goes to [handle].
class ScriptedConnector {
  ScriptedConnector(this.handle);

  final void Function(TalkMessage request) handle;

  /// Server sides of the links handed out.
  final List<TalkChannel> servers = [];

  Future<TalkChannel> call() async {
    final link = StreamChannelController<Uint8List>();
    final server = TalkChannel(link.local, options: serverOptions);
    servers.add(server);
    server.messages.listen((m) {
      if (m.procedureName == 'WATCH') {
        m.reply(Uint8List(0));
      } else {
        handle(m);
      }
    }, onError: (Object _) {});
    return TalkChannel(link.foreign, options: clientOptions);
  }

  Future<void> close() =>
      Future.wait([for (final server in servers) server.close()]);
}

/// [value] as UTF-8 bytes.
Uint8List text(String value) => Uint8List.fromList(utf8.encode(value));

/// A connection that never identifies until [changeIdentity], and counts the
/// listeners waiting for its next `IDENT`.
class _IdentityEvents implements MuxConnection {
  Completer<void> _event = Completer<void>();

  /// Listeners on the current [identityChanged].
  int waiting = 0;

  /// A valid `IDENT` (of nobody, as far as [peerIdentity] goes).
  void changeIdentity() {
    final event = _event;
    _event = Completer<void>();
    waiting = 0;
    event.complete();
  }

  @override
  bool get isOpen => true;

  @override
  PeerIdentity? get peerIdentity => null;

  @override
  Future<void> get identityChanged => _Counted(_event.future, () => waiting++);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// [inner], calling [onListen] for every listener.
class _Counted implements Future<void> {
  _Counted(this.inner, this.onListen);

  final Future<void> inner;
  final void Function() onListen;

  @override
  Future<R> then<R>(
    FutureOr<R> Function(void value) onValue, {
    Function? onError,
  }) {
    onListen();
    return inner.then(onValue, onError: onError);
  }

  @override
  Stream<void> asStream() => Stream.fromFuture(this);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
