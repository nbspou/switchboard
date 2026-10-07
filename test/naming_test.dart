import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:async/async.dart';
import 'package:fake_async/fake_async.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:switchboard/src/address/service_address.dart';
import 'package:switchboard/src/bytes.dart';
import 'package:switchboard/src/name.dart';
import 'package:switchboard/src/naming/naming_client.dart';
import 'package:switchboard/src/naming/naming_protocol.dart';
import 'package:switchboard/src/naming/naming_service.dart';
import 'package:switchboard/src/status.dart';
import 'package:switchboard/src/talk/talk_channel.dart';
import 'package:switchboard/src/talk/talk_frame.dart';
import 'package:switchboard/src/talk/talk_message.dart';
import 'package:switchboard/src/talk/talk_stream.dart';
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
      expect(await watcher.next, 'SYNCED');
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

    test('a REGISTER without the metadata field has empty metadata', () async {
      final (c, _) = h.link();
      final watcher = Watcher(c);
      expect(await watcher.next, 'SYNCED');
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
      expect(await watcher.next, 'SYNCED');
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
        'SYNCED',
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
      // A name with a byte after its terminating zero.
      await expectLater(
        c.streamRequest('WATCH', bytes([0x61, 0, 0x62, 0, 0, 0, 0, 0])).done,
        throwsStatus(StatusCode.invalidArgument),
      );
      await expectLater(
        c.request('WATCH', Uint8List(0)),
        throwsStatus(StatusCode.invalidArgument),
      );
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
      expect(await watcher.next, 'SYNCED');
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

    test('watch: snapshot, SYNCED, then live UP and DOWN', () async {
      final (a, _) = h.link();
      final (b, _) = h.link();
      await register(a, 'npc', endpoints: [uriA]);
      await register(a, 'api');
      final watcher = Watcher(b);
      expect(await watcher.take(3), ['UP npc/1 $uriA', 'UP api/2', 'SYNCED']);
      final id = await register(a, 'npc', endpoints: [uriB]);
      expect(await watcher.next, 'UP npc/3 $uriB');
      await register(a, 'npc', instance: id, endpoints: [uriA]);
      expect(await watcher.next, 'UP npc/3 $uriA');
      await unregister(a, 'api', 2);
      expect(await watcher.next, 'DOWN api/2');
      expect(h.service.watchCount, 1);
    });

    test(
      'a watch on the registering channel sees UP before the reply',
      () async {
        final (a, _) = h.link();
        final watcher = Watcher(a);
        expect(await watcher.next, 'SYNCED');
        final seen = <String>[];
        final registered = register(a, 'npc').then((_) => seen.add('reply'));
        seen.add(await watcher.next);
        await registered;
        expect(seen, ['UP npc/1', 'reply']);
      },
    );

    test('watch filtered by type', () async {
      final (a, _) = h.link();
      final (b, _) = h.link();
      await register(a, 'npc');
      await register(a, 'api');
      final watcher = Watcher(b, type: 'api');
      expect(await watcher.take(2), ['UP api/2', 'SYNCED']);
      await register(a, 'npc');
      await register(a, 'api');
      await unregister(a, 'npc', 1);
      await unregister(a, 'api', 2);
      expect(await watcher.take(2), ['UP api/4', 'DOWN api/2']);
      // An all-zero name watches everything.
      final all = Watcher(b, payload: Uint8List(8));
      expect(await all.take(3), ['UP npc/3', 'UP api/4', 'SYNCED']);
    });

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

    test('cancelling a watch ends it with CANCELLED', () async {
      final (a, server) = h.link();
      final watcher = Watcher(a);
      expect(await watcher.next, 'SYNCED');
      expect(h.service.watchCount, 1);
      watcher.stream.cancel();
      await until(() => h.service.watchCount == 0);
      // The cancelled request id is released by the final CANCELLED.
      await until(() => a.outgoingRequestCount == 0);
      expect(server.incomingRequestCount, 0);
      expect(await register(a, 'npc'), 1);
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
        'SYNCED',
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
      expect(await watcher.next, 'SYNCED');
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
      expect(await watcher.next, 'SYNCED');
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
        watchTimeout: clientOptions.requestTimeout,
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
      // The snapshot, SYNCED and the watch's registration happen in one
      // step, so a registration lands either in the snapshot or after it.
      for (var round = 0; round < 50; round++) {
        final h = Harness();
        final (a, _) = h.link();
        final (b, _) = h.link();
        final ups = <String>[];
        var synced = false;
        final registered = register(a, 'npc');
        final watch = b.streamRequest('WATCH', Uint8List(0));
        final items = watch.items.listen((m) {
          if (m.procedureName == 'SYNCED') {
            synced = true;
          } else if (m.procedureName == 'UP') {
            ups.add(synced ? 'live' : 'snapshot');
          }
        });
        if (round.isOdd) {
          await pump();
        }
        await registered;
        await until(() => synced && ups.isNotEmpty);
        await pump();
        expect(ups, hasLength(1), reason: 'round $round');
        await items.cancel();
        await h.close();
      }
    });

    test('close aborts watches with GOING_AWAY and closes channels', () async {
      final (a, _) = h.link();
      await register(a, 'npc');
      final watcher = Watcher(a);
      expect(await watcher.take(2), ['UP npc/1', 'SYNCED']);
      final eventsDone = h.service.events.toList();
      await h.service.close();
      await expectLater(
        watcher.stream.done,
        throwsStatus(StatusCode.goingAway),
      );
      await a.done;
      expect(a.isOpen, isFalse);
      expect((await h.servers[0].done).known, StatusCode.goingAway);
      expect(h.service.watchCount, 0);
      expect(h.service.table, isEmpty);
      expect((await eventsDone).map(describeEvent), ['DOWN npc/1']);
      // Channels served after close are closed at once.
      final (b, bServer) = h.link();
      await b.done;
      expect(b.isOpen, isFalse);
      expect((await bServer.done).known, StatusCode.goingAway);
    });
  });

  group('heartbeat', () {
    test('keeps an idle watch alive well past every timeout', () {
      fakeAsync((async) {
        final h = Harness();
        final (a, _) = h.link();
        final items = <String>[];
        Object? error;
        final watch = a.streamRequest('WATCH', Uint8List(0));
        watch.items.listen(
          (m) => items.add(describe(m)),
          onError: (Object e) => error = e,
        );
        // 10 times the watcher's request timeout, 15 times the service's
        // reply timeout.
        async.elapse(clientOptions.requestTimeout * 10);
        expect(error, isNull);
        expect(items, ['SYNCED']);
        expect(h.service.watchCount, 1);
        // Still live.
        final (b, _) = h.link();
        unawaited(register(b, 'npc'));
        async.elapse(ms10);
        expect(items, ['SYNCED', 'UP npc/1']);
        async.elapse(clientOptions.requestTimeout * 10);
        expect(error, isNull);
        watch.cancel();
        async.elapse(ms10);
        expect(h.service.watchCount, 0);
        unawaited(h.close());
        async.flushMicrotasks();
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('a heartbeat slower than the reply timeout loses the watch', () {
      fakeAsync((async) {
        final h = Harness(heartbeat: const Duration(seconds: 1));
        final (a, _) = h.link();
        final watch = a.streamRequest('WATCH', Uint8List(0));
        Object? error;
        watch.items.listen((_) {}, onError: (Object e) => error = e);
        async.elapse(clientOptions.requestTimeout * 2);
        expect(error, isStatus(StatusCode.deadlineExceeded));
        expect(h.service.watchCount, 0);
        unawaited(h.close());
        async.flushMicrotasks();
        expect(async.pendingTimers, isEmpty);
      });
    });
  });

  group('heartbeat default', () {
    test('stays below the 5 s the wiki allows', () {
      expect(
        NamingService(assignmentHold: Duration.zero).heartbeat,
        lessThan(const Duration(seconds: 5)),
      );
      fakeAsync((async) {
        // Default options everywhere.
        final ns = NamingService();
        final link = StreamChannelController<Uint8List>();
        ns.serve(TalkChannel(link.local));
        final times = <Duration>[];
        link.foreign.stream.listen((_) => times.add(async.elapsed));
        link.foreign.sink.add(
          TalkFrame(
            kind: TalkKind.message,
            procedure: Name('WATCH'),
            requestId: 1,
            stream: true,
            payload: Uint8List(0),
          ).encode(),
        );
        async.elapse(const Duration(seconds: 60));
        expect(ns.watchCount, 1);
        expect(times.length, greaterThan(10));
        for (var i = 1; i < times.length; i++) {
          expect(times[i] - times[i - 1], lessThan(const Duration(seconds: 5)));
        }
        unawaited(ns.close());
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

    test('a service surviving a restart keeps its id', () {
      fakeAsync((async) {
        var h = Harness();
        final connector = Connector(h);
        final survivor = NamingClient(
          connector.call,
          reconnectDelay: const Duration(milliseconds: 300),
          watchTimeout: clientOptions.requestTimeout,
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
          watchTimeout: clientOptions.requestTimeout,
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
        watchTimeout: clientOptions.requestTimeout,
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

    test('a watch timeout is a loss of the service', () async {
      // The service never answers: no SYNCED, no heartbeat.
      final silent = <StreamChannelController<Uint8List>>[];
      var calls = 0;
      final client = NamingClient(
        () async {
          calls++;
          final link = StreamChannelController<Uint8List>();
          silent.add(link);
          link.local.stream.listen((_) {});
          return TalkChannel(link.foreign, options: clientOptions);
        },
        reconnectDelay: reconnectDelay,
        watchTimeout: ms50,
      );
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
        watchTimeout: clientOptions.requestTimeout,
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
        watchTimeout: clientOptions.requestTimeout,
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
        final client = NamingClient(
          lossy.call,
          reconnectDelay: reconnectDelay,
          watchTimeout: clientOptions.requestTimeout,
        );
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
      final client = NamingClient(
        lossy.call,
        reconnectDelay: reconnectDelay,
        watchTimeout: clientOptions.requestTimeout,
      );
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
          watchTimeout: clientOptions.requestTimeout,
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
          watchTimeout: clientOptions.requestTimeout,
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

/// Unregisters over a raw Talk channel.
Future<void> unregister(TalkChannel channel, String type, int instance) =>
    channel.request(
      'UNREGSTR',
      UnregisterRequest(Name(type), instance).encode(),
    );

/// A raw `WATCH` whose items are read one by one, as strings.
class Watcher {
  Watcher(TalkChannel channel, {String? type, Uint8List? payload})
    : stream = channel.streamRequest(
        'WATCH',
        payload ?? WatchRequest(type == null ? null : Name(type)).encode(),
      ) {
    _queue = StreamQueue(stream.items.map(describe));
  }

  final TalkStream stream;
  late final StreamQueue<String> _queue;

  Future<String> get next => _queue.next.timeout(timeout);

  Future<List<String>> take(int count) => _queue.take(count).timeout(timeout);
}

/// A [TalkConnector] to a scripted naming service: `WATCH` gets `SYNCED`
/// and a heartbeat; every other request goes to [handle].
class ScriptedConnector {
  ScriptedConnector(this.handle);

  final void Function(TalkMessage request) handle;

  /// Server sides of the links handed out.
  final List<TalkChannel> servers = [];
  final List<Timer> _heartbeats = [];

  Future<TalkChannel> call() async {
    final link = StreamChannelController<Uint8List>();
    final server = TalkChannel(link.local, options: serverOptions);
    servers.add(server);
    server.messages.listen((m) {
      if (m.procedureName != 'WATCH') {
        handle(m);
        return;
      }
      m.replyItem(Uint8List(0), procedure: 'SYNCED');
      _heartbeats.add(
        Timer.periodic(ms10, (timer) {
          if (m.canReply) {
            m.extend();
          } else {
            timer.cancel();
          }
        }),
      );
    }, onError: (Object _) {});
    return TalkChannel(link.foreign, options: clientOptions);
  }

  Future<void> close() async {
    for (final timer in _heartbeats) {
      timer.cancel();
    }
    await Future.wait([for (final server in servers) server.close()]);
  }
}

/// [value] as UTF-8 bytes.
Uint8List text(String value) => Uint8List.fromList(utf8.encode(value));
