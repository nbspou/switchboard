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

import 'package:switchboard/src/switchboard/memory_endpoints.dart';
import 'package:switchboard/switchboard.dart';
import 'package:test/test.dart';

const mux = MuxOptions(
  goAwayGrace: Duration(milliseconds: 100),
  keepAliveInterval: null,
);

/// Service and naming channels.
const talkOptions = TalkOptions(
  requestTimeout: Duration(seconds: 2),
  replyTimeout: Duration(seconds: 1),
);
const reconnectDelay = Duration(milliseconds: 20);

/// Upper bound for anything a test waits on; only reached on failure.
const limit = Duration(seconds: 5);

final npc = Name('npc');
final chat = Name('chat');

Uint8List bytes(String text) => Uint8List.fromList(utf8.encode(text));

String text(TalkMessage message) => utf8.decode(message.payload);

Matcher isCode(Iterable<StatusCode> codes) =>
    isA<SwitchboardException>().having((e) => e.code, 'code', isIn(codes));

Matcher throwsCode(StatusCode code) => throwsA(isCode([code]));

/// Polls [condition] every few milliseconds; fails after [limit].
Future<void> until(bool Function() condition, [String? what]) async {
  final deadline = DateTime.now().add(limit);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('${what ?? 'condition'} not met within $limit');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// Listens on 127.0.0.1 with the stream binding (`tcp`) or WebSocket
/// (`ws`), or in this isolate (`mem`). With [previous], where that
/// listener was (its port, or its mem id); otherwise on a free port or a
/// new id.
Future<Uri> listen(Switchboard node, String scheme, [Uri? previous]) =>
    switch (scheme) {
      'tcp' => node.listenTcp(
        InternetAddress.loopbackIPv4,
        previous?.port ?? 0,
      ),
      'ws' => node.listenWebSocket(
        InternetAddress.loopbackIPv4,
        previous?.port ?? 0,
        path: '/mesh',
      ),
      _ => node.listenMemory(name: previous?.host),
    };

/// Joins [node] to the mesh with short test timeouts.
MeshNode join(Switchboard node, Uri naming) => MeshNode.join(
  node,
  naming,
  reconnectDelay: reconnectDelay,
  resolveTimeout: limit,
  talkOptions: talkOptions,
);

/// A new node, closed after the test.
Switchboard newNode({Resolver? resolver, Uint8List? defaultPayload}) {
  final node = Switchboard(
    resolver: resolver,
    defaultPayload: defaultPayload,
    muxOptions: mux,
    talkOptions: talkOptions,
  );
  addTearDown(node.close);
  return node;
}

bool sameTable(
  Map<ServiceAddress, ServiceRecord> a,
  Map<ServiceAddress, ServiceRecord> b,
) => a.length == b.length && a.keys.every((k) => a[k] == b[k]);

/// The node hosting the naming service as `_ns/1`.
class NamingNode {
  NamingNode._(this.node, this.service, this.uri);

  final Switchboard node;
  final NamingService service;
  final Uri uri;

  /// Starts where [previous] was (null: anywhere), retrying the bind for
  /// a while (a port just released by a previous naming node). [taken] ids
  /// are registered locally as `squat/<id>` before anyone can connect. No
  /// assignment hold unless asked for.
  static Future<NamingNode> start(
    String scheme, {
    Uri? previous,
    List<int> taken = const [],
    Duration assignmentHold = Duration.zero,
  }) async {
    final node = newNode();
    final service = NamingService(assignmentHold: assignmentHold);
    addTearDown(service.close);
    node.registerService(Services.naming, service.handler, instance: 1);
    for (final id in taken) {
      service.registerLocal(Name('squat'), const [], instance: id);
    }
    Uri? uri;
    for (var attempt = 0; uri == null; attempt++) {
      try {
        uri = await listen(node, scheme, previous);
      } on SocketException {
        if (attempt >= 100) {
          rethrow;
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }
    service.registerLocal(
      Services.naming,
      node.listeningEndpoints,
      instance: 1,
    );
    return NamingNode._(node, service, uri);
  }

  Future<void> stop() async {
    await service.close();
    await node.close();
  }
}

/// A backend node publishing services. Every service answers:
///
/// * `WHO`: JSON with the node name, the service type, the instance, shard
///   and application payload of the channel's address header;
/// * `COUNT` (stream): items `0`, `1`, `2`, then the final response `end`;
/// * `TICK` (stream): an item every 5 ms until the request goes away.
class Backend {
  Backend._(this.name, this.node, this.uri, this.mesh);

  final String name;
  final Switchboard node;
  final Uri uri;
  final MeshNode mesh;

  /// Instance id of each published type.
  final Map<Name, int> ids = {};

  static Future<Backend> start(
    String name,
    String scheme,
    Uri naming,
    List<Name> types,
  ) async {
    final node = newNode();
    final uri = await listen(node, scheme);
    final mesh = join(node, naming);
    addTearDown(mesh.leave);
    final backend = Backend._(name, node, uri, mesh);
    for (final type in types) {
      backend.ids[type] = await mesh
          .publish(type, backend._serve)
          .timeout(limit);
    }
    return backend;
  }

  void _serve(IncomingChannel incoming) {
    final address = incoming.address;
    incoming.talk().messages.listen(
      (m) {
        switch (m.procedureName) {
          case 'WHO':
            m.reply(
              bytes(
                jsonEncode({
                  'node': name,
                  'type': '${address.type}',
                  'instance': address.instance,
                  'shard': address.shard,
                  'payload': utf8.decode(address.payload),
                }),
              ),
            );
          case 'COUNT':
            for (var i = 0; i < 3; i++) {
              m.replyItem(bytes('$i'));
            }
            m.reply(bytes('end'));
          case 'TICK':
            var n = 0;
            Timer.periodic(const Duration(milliseconds: 5), (timer) {
              if (!m.canReply) {
                timer.cancel();
                return;
              }
              m.replyItem(bytes('${n++}'));
            });
          default:
            m.replyAbort(Status.of(StatusCode.unimplemented));
        }
      },
      onError: (Object _) {
        // The peer aborted the channel; nothing to clean up.
      },
    );
  }

  /// Leaves the mesh, then closes the node.
  Future<void> stop() async {
    await mesh.leave();
    await node.close();
  }
}

/// A TCP relay to a `tcp://` endpoint. [freeze] makes the connections
/// open at that moment go dead, as a hung host or a network partition
/// does: nothing is forwarded either way and nothing is closed, until one
/// side closes its own socket, which the relay passes on. Connections made
/// afterwards are relayed normally.
class Relay {
  Relay._(this._server, this._target);

  static Future<Relay> start(Uri target) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final relay = Relay._(server, target);
    server.listen(relay._accept);
    return relay;
  }

  final ServerSocket _server;
  final Uri _target;
  final List<_Pipe> _pipes = [];

  Uri get uri => Uri.parse('tcp://127.0.0.1:${_server.port}');

  /// Connections relayed so far.
  int get connections => _pipes.length;

  Future<void> _accept(Socket client) async {
    // Handed to the pipe, which destroys it.
    // ignore: close_sinks
    final Socket upstream;
    try {
      upstream = await Socket.connect(_target.host, _target.port);
    } on SocketException {
      client.destroy();
      return;
    }
    _pipes.add(_Pipe(client, upstream));
  }

  void freeze() {
    for (final pipe in _pipes) {
      pipe.frozen = true;
    }
  }

  Future<void> close() async {
    await _server.close();
    for (final pipe in _pipes) {
      pipe.close();
    }
  }
}

class _Pipe {
  _Pipe(this.a, this.b) {
    a.listen((data) => _pass(b, data), onDone: close, onError: (_) => close());
    b.listen((data) => _pass(a, data), onDone: close, onError: (_) => close());
  }

  final Socket a;
  final Socket b;
  bool frozen = false;
  bool _closed = false;

  void _pass(Socket to, Uint8List data) {
    if (!frozen && !_closed) {
      to.add(data);
    }
  }

  void close() {
    if (_closed) {
      return;
    }
    _closed = true;
    a.destroy();
    b.destroy();
  }
}

/// One `WHO` request on a fresh channel from [from] to [to].
Future<Map<String, Object?>> who(
  Switchboard from,
  ServiceAddress to, {
  int? shard,
}) async {
  final channel = await from.openTalk(to, shard: shard).timeout(limit);
  try {
    final reply = await channel.request('WHO', Uint8List(0));
    return jsonDecode(text(reply)) as Map<String, Object?>;
  } finally {
    await channel.close();
  }
}

Future<String> nodeOf(
  Switchboard from,
  ServiceAddress to, {
  int? shard,
}) async => (await who(from, to, shard: shard))['node']! as String;

/// A mesh run by a naming service, over TCP, over WebSocket and over
/// in-process `mem://` endpoints (every node in this isolate): a naming
/// node hosting `_ns/1`, backend nodes `b1` (`npc`, `chat`) and `b2`
/// (`npc`) joined with [MeshNode], consumer nodes resolving through the
/// mirrored table, a frontend endpoint proxying `chat` for clients that
/// only know the endpoint, and a raw mux peer without a Switchboard.
void main() {
  // Every node is closed by its test's tear-down, which releases its ids.
  tearDownAll(() {
    expect(MemoryEndpoints.ids, isEmpty, reason: 'a memory listener leaked');
  });

  for (final scheme in ['tcp', 'ws', 'mem']) {
    group('over $scheme', () {
      late NamingNode naming;
      late Backend b1;
      late Backend b2;

      /// Naming node, `b1` with `npc` and `chat`, `b2` with `npc`.
      setUp(() async {
        naming = await NamingNode.start(scheme);
        b1 = await Backend.start('b1', scheme, naming.uri, [npc, chat]);
        b2 = await Backend.start('b2', scheme, naming.uri, [npc]);
      });

      /// A node that only consumes services, synced with the whole table.
      Future<(Switchboard, MeshNode)> client() async {
        final node = newNode();
        final mesh = join(node, naming.uri);
        addTearDown(mesh.leave);
        await mesh.synced.timeout(limit);
        // `_ns/1`, `npc` twice, `chat`.
        await until(() => mesh.client.table.length == 4, 'full table');
        return (node, mesh);
      }

      test('naming service is registered as _ns/1 and ids are global', () {
        expect(
          naming.service.table[ServiceAddress(Services.naming, 1)]?.endpoints,
          [naming.uri],
        );
        final ids = {...b1.ids.values, ...b2.ids.values};
        expect(ids, hasLength(3));
        expect(ids, isNot(contains(1)));
        expect(
          b1.mesh.published,
          unorderedEquals(<ServiceAddress>[
            ServiceAddress(npc, b1.ids[npc]!),
            ServiceAddress(chat, b1.ids[chat]!),
          ]),
        );
        expect(
          naming.service.table[ServiceAddress(npc, b2.ids[npc]!)]?.endpoints,
          [b2.uri],
        );
      });

      test(
        'resolution: round robin, exact instance, shards, leave, notFound',
        () async {
          final (node, mesh) = await client();

          final reply = await who(node, ServiceAddress(chat));
          expect(reply['node'], 'b1');
          expect(reply['type'], 'chat');
          expect(reply['instance'], b1.ids[chat]);

          // Round robin over the two npc instances.
          final rotation = [
            for (var i = 0; i < 6; i++) await nodeOf(node, ServiceAddress(npc)),
          ];
          expect(rotation.where((n) => n == 'b1'), hasLength(3));
          expect(rotation.where((n) => n == 'b2'), hasLength(3));
          for (var i = 1; i < rotation.length; i++) {
            expect(rotation[i], isNot(rotation[i - 1]), reason: '$rotation');
          }

          // An exact instance always reaches that instance, which sees its
          // own id in the header.
          for (var i = 0; i < 3; i++) {
            final exact = await who(node, ServiceAddress(npc, b2.ids[npc]!));
            expect(exact['node'], 'b2');
            expect(exact['instance'], b2.ids[npc]);
          }

          // Shard s selects instance s mod 2 of the instances sorted by id.
          final sorted = [b1, b2]
            ..sort((a, b) => a.ids[npc]!.compareTo(b.ids[npc]!));
          for (var round = 0; round < 2; round++) {
            for (var shard = 0; shard < 5; shard++) {
              final reply = await who(node, ServiceAddress(npc), shard: shard);
              expect(reply['node'], sorted[shard % 2].name);
              expect(reply['shard'], shard);
              expect(reply['instance'], sorted[shard % 2].ids[npc]);
            }
          }

          // Unknown types and instances fail locally.
          await expectLater(
            node.openTalk(ServiceAddress(Name('nope'))),
            throwsCode(StatusCode.notFound),
          );
          await expectLater(
            node.openTalk(ServiceAddress(npc, 0xdead)),
            throwsCode(StatusCode.notFound),
          );

          // b2 leaves: the client's resolver reports DOWN, and npc is only
          // served by b1 from then on.
          final gone = ServiceAddress(npc, b2.ids[npc]!);
          final down = mesh.resolver.events.firstWhere(
            (e) => !e.up && e.record.address == gone,
          );
          await b2.stop();
          await down.timeout(limit);
          expect(mesh.client.table.containsKey(gone), isFalse);
          for (var i = 0; i < 4; i++) {
            expect(await nodeOf(node, ServiceAddress(npc)), 'b1');
          }
          await expectLater(
            node.openTalk(gone),
            throwsCode(StatusCode.notFound),
          );
        },
      );

      test('unpublish removes a service from the mesh and the node', () async {
        final (node, mesh) = await client();
        final address = ServiceAddress(chat, b1.ids[chat]!);
        final down = mesh.resolver.events.firstWhere(
          (e) => !e.up && e.record.address == address,
        );
        await b1.mesh.unpublish(chat, b1.ids[chat]!);
        await down.timeout(limit);
        expect(b1.mesh.published, [ServiceAddress(npc, b1.ids[npc]!)]);
        await expectLater(
          node.openTalk(ServiceAddress(chat)),
          throwsCode(StatusCode.notFound),
        );
        // A stale peer reaching the node directly is turned away too.
        final stale = await node.openTalkAt(
          b1.uri,
          ChannelAddress(type: chat, instance: address.instance),
        );
        await expectLater(
          stale.request('WHO', Uint8List(0)),
          throwsCode(StatusCode.notFound),
        );
        await stale.close();
        await expectLater(
          b1.mesh.unpublish(chat, address.instance),
          throwsCode(StatusCode.notFound),
        );
      });

      test('naming service restart: stale table, same ids, resync', () async {
        final (node, mesh) = await client();
        final before = Map.of(mesh.client.table);
        expect(await nodeOf(node, ServiceAddress(chat)), 'b1');
        final previous = naming.uri;

        await naming.stop();
        await until(
          () =>
              !mesh.client.isSynced &&
              !b1.mesh.client.isSynced &&
              !b2.mesh.client.isSynced,
          'naming service loss noticed',
        );
        expect(mesh.client.isConnected, isFalse);

        // The mesh keeps working from the stale table.
        expect(sameTable(mesh.client.table, before), isTrue);
        expect(await nodeOf(node, ServiceAddress(chat)), 'b1');
        final rotation = {
          for (var i = 0; i < 4; i++) await nodeOf(node, ServiceAddress(npc)),
        };
        expect(rotation, {'b1', 'b2'});
        expect(await nodeOf(node, ServiceAddress(npc, b2.ids[npc]!)), 'b2');

        // A new naming service at the same endpoint. The backends register
        // their old ids again; every node resyncs.
        naming = await NamingNode.start(scheme, previous: previous);
        expect(
          naming.uri,
          before[ServiceAddress(Services.naming, 1)]!.endpoints.single,
        );
        await mesh.synced.timeout(limit);
        await b1.mesh.synced.timeout(limit);
        await b2.mesh.synced.timeout(limit);
        await until(
          () => sameTable(naming.service.table, before),
          'backends re-registered',
        );
        await until(
          () => sameTable(mesh.client.table, before),
          'client table rebuilt',
        );
        expect(mesh.client.isSynced, isTrue);
        expect(
          b1.mesh.published,
          unorderedEquals(<ServiceAddress>[
            ServiceAddress(npc, b1.ids[npc]!),
            ServiceAddress(chat, b1.ids[chat]!),
          ]),
        );

        // Business as usual, including a new registration.
        expect(await nodeOf(node, ServiceAddress(chat)), 'b1');
        final extra = Name('extra');
        final id = await b2.mesh.publish(extra, b2._serve).timeout(limit);
        expect(before.keys.map((a) => a.instance), isNot(contains(id)));
        await until(
          () => mesh.client.table.containsKey(ServiceAddress(extra, id)),
          'new registration mirrored',
        );
        final reply = await who(node, ServiceAddress(extra));
        expect(reply['node'], 'b2');
        expect(reply['instance'], id);
      });

      test('an id taken during an outage moves to a new id', () async {
        final (node, mesh) = await client();
        final old = b2.ids[npc]!;
        final previous = naming.uri;
        await naming.stop();
        await until(() => !b2.mesh.client.isSynced, 'loss noticed');
        naming = await NamingNode.start(
          scheme,
          previous: previous,
          taken: [old],
        );
        // b2 asks for its old id, gets ALREADY_EXISTS, takes a new one, and
        // its local dispatch follows.
        await until(
          () => b2.mesh.published.any((a) => a.type == npc),
          'npc published again',
        );
        await until(
          () => b2.mesh.published.single.instance != old,
          'npc moved',
        );
        final moved = b2.mesh.published.single;
        expect(naming.service.table[moved]?.endpoints, [b2.uri]);
        await until(
          () => mesh.client.table.containsKey(moved),
          'client sees the new id',
        );
        final reply = await who(node, moved);
        expect(reply['node'], 'b2');
        expect(reply['instance'], moved.instance);
        // The old id is no longer dispatched on b2.
        final stale = await node.openTalkAt(
          b2.uri,
          ChannelAddress(type: npc, instance: old),
        );
        await expectLater(
          stale.request('WHO', Uint8List(0)),
          throwsCode(StatusCode.notFound),
        );
        await stale.close();
      });

      test('after a restart, newcomers do not get surviving ids', () async {
        final survivors = {...b1.ids.values, ...b2.ids.values};
        final previous = naming.uri;
        await naming.stop();
        await until(
          () => !b1.mesh.client.isSynced && !b2.mesh.client.isSynced,
          'loss noticed',
        );
        // Ids are assigned from 1 again, but only after the hold: the
        // survivors reconnect within it and reclaim theirs.
        naming = await NamingNode.start(
          scheme,
          previous: previous,
          assignmentHold: const Duration(milliseconds: 500),
        );
        final b3 = await Backend.start('b3', scheme, naming.uri, [npc, chat]);
        expect(b3.ids.values.toSet().intersection(survivors), isEmpty);
        expect(naming.service.isHoldingAssignments, isFalse);
        await until(
          () => naming.service.table.length == 6,
          'everyone registered',
        );
        for (final backend in [b1, b2]) {
          expect(
            backend.mesh.published.map((a) => a.instance).toSet(),
            backend.ids.values.toSet(),
          );
        }
        for (final b in [b1, b2, b3]) {
          for (final MapEntry(key: type, value: id) in b.ids.entries) {
            expect(naming.service.table[ServiceAddress(type, id)]?.endpoints, [
              b.uri,
            ]);
          }
        }
      });

      test('an unreachable naming service fails opens, bounded', () async {
        // A port nobody listens on any more.
        final probe = newNode();
        final dead = await listen(probe, scheme);
        await probe.close();
        final node = newNode();
        final mesh = MeshNode.join(
          node,
          dead,
          reconnectDelay: reconnectDelay,
          resolveTimeout: const Duration(milliseconds: 100),
          talkOptions: talkOptions,
        );
        addTearDown(mesh.leave);
        final watch = Stopwatch()..start();
        await expectLater(
          node.openTalk(ServiceAddress(chat)).timeout(limit),
          throwsCode(StatusCode.unavailable),
        );
        expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
        // A publish waits for the naming service; leaving cancels it.
        final pending = expectLater(
          mesh.publish(npc, (incoming) {}),
          throwsCode(StatusCode.cancelled),
        );
        await mesh.leave();
        await pending;
        expect(node.resolver, isNull);
        await expectLater(
          mesh.publish(npc, (incoming) {}),
          throwsCode(StatusCode.failedPrecondition),
        );
      });

      group('frontend endpoint', () {
        late Switchboard endpoint;
        late MeshNode endpointMesh;
        late Uri endpointUri;
        late Switchboard frontend;

        setUp(() async {
          endpoint = newNode();
          endpointUri = await listen(endpoint, scheme);
          final mesh = endpointMesh = join(endpoint, naming.uri);
          addTearDown(mesh.leave);
          endpoint.catchAll = proxyHandler(
            endpoint,
            allow: (address) => address.type == chat,
          );
          await mesh.synced.timeout(limit);
          frontend = newNode(
            resolver: EndpointResolver(endpointUri),
            defaultPayload: bytes('session-42'),
          );
        });

        test('talk and stream requests through the proxy', () async {
          final talk = await frontend
              .openTalk(ServiceAddress(chat))
              .timeout(limit);
          final reply = jsonDecode(
            text(await talk.request('WHO', Uint8List(0))),
          ) as Map<String, Object?>;
          // The backend sees the frontend client's credential and its own
          // instance, filled in by the proxy.
          expect(reply['node'], 'b1');
          expect(reply['payload'], 'session-42');
          expect(reply['instance'], b1.ids[chat]);

          final stream = talk.streamRequest('COUNT', Uint8List(0));
          expect(await stream.items.map(text).toList(), ['0', '1', '2']);
          expect(text(await stream.done), 'end');
          await talk.close();

          // An explicit instance passes through the endpoint resolver and
          // the proxy unchanged.
          final exact = await who(
            frontend,
            ServiceAddress(chat, b1.ids[chat]!),
          );
          expect(exact['instance'], b1.ids[chat]);
          expect(exact['payload'], 'session-42');
        });

        test('types outside the allowlist are refused', () async {
          final talk = await frontend.openTalk(ServiceAddress(npc));
          await expectLater(
            talk.request('WHO', Uint8List(0)),
            throwsCode(StatusCode.permissionDenied),
          );
          expect(
            (await talk.done.timeout(limit)).known,
            StatusCode.permissionDenied,
          );
        });

        test(
          'a backend shutting down ends a proxied stream promptly',
          () async {
            final talk = await frontend.openTalk(ServiceAddress(chat));
            final stream = talk.streamRequest('TICK', Uint8List(0));
            stream.done.ignore();
            final items = <String>[];
            final ended = Completer<Object>();
            final first = Completer<void>();
            stream.items.listen(
              (m) {
                items.add(text(m));
                if (items.length == 3 && !first.isCompleted) {
                  first.complete();
                }
              },
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
            await first.future.timeout(limit);

            final watch = Stopwatch()..start();
            await b1.stop().timeout(limit);
            final error = await ended.future.timeout(limit);
            expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
            expect(
              error,
              isCode([StatusCode.goingAway, StatusCode.unavailable]),
            );
            expect(items, containsAllInOrder(['0', '1', '2']));
            expect(
              (await talk.done.timeout(limit)).known,
              isIn([StatusCode.goingAway, StatusCode.unavailable]),
            );

            // chat is gone from the mesh: once the endpoint has seen the
            // DOWN, its proxy refuses with NOT_FOUND.
            await until(
              () => !endpointMesh.client.table.keys.any((a) => a.type == chat),
              'chat gone at the endpoint',
            );
            final again = await frontend.openTalk(ServiceAddress(chat));
            await expectLater(
              again.request('WHO', Uint8List(0)),
              throwsCode(StatusCode.notFound),
            );
            await again.close();
          },
        );

        // A raw peer brings its own transport; a mem endpoint is reached
        // only through a Switchboard of this isolate.
        if (scheme != 'mem') {
          test('a raw mux peer without a Switchboard', () async {
            // What an embedded device does: its own transport and mux, and a
            // hand-built OPEN payload: HAS_SERVICE, `chat` padded to 8 bytes,
            // then the application payload.
            final open = Uint8List.fromList([
              0x01,
              ...ascii.encode('chat'),
              0,
              0,
              0,
              0,
              ...ascii.encode('device-7'),
            ]);
            expect(
              open,
              ChannelAddress(type: chat, payload: bytes('device-7')).encode(),
            );
            final transport = scheme == 'tcp'
                ? await StreamTransport.connectTcp(
                    endpointUri.host,
                    endpointUri.port,
                  )
                : await WebSocketTransport.connect(endpointUri);
            final connection = MuxConnection(
              transport,
              isInitiator: true,
              options: const MuxOptions(
                keepAliveInterval: null,
                shortIdsOnly: true,
              ),
            );
            addTearDown(connection.close);
            final talk = TalkChannel(
              connection.open(open),
              options: talkOptions,
            );
            final reply = jsonDecode(
              text(await talk.request('WHO', Uint8List(0)).timeout(limit)),
            ) as Map<String, Object?>;
            expect(reply['node'], 'b1');
            expect(reply['payload'], 'device-7');
            expect(reply['instance'], b1.ids[chat]);
            await talk.close();
            await connection.close();
          });
        }
      });
    });
  }

  group('liveness', () {
    test('a naming service that stops answering is detected by the mux '
        'keep-alive; the client reconnects and resyncs', () async {
      final naming = await NamingNode.start('tcp');
      final relay = await Relay.start(naming.uri);
      addTearDown(relay.close);
      // A node that probes a silent connection after 100 ms and gives it
      // up 100 ms later.
      final node = Switchboard(
        muxOptions: const MuxOptions(
          goAwayGrace: Duration(milliseconds: 100),
          keepAliveInterval: Duration(milliseconds: 100),
          keepAliveTimeout: Duration(milliseconds: 100),
        ),
        talkOptions: talkOptions,
      );
      addTearDown(node.close);
      final mesh = join(node, relay.uri);
      addTearDown(mesh.leave);
      final endpoint = Uri.parse('tcp://10.0.0.1:7000');
      await mesh.client.register(npc, [endpoint]).timeout(limit);
      await mesh.synced.timeout(limit);
      final firstSynced = mesh.synced;

      // Idle for many keep-alive rounds: the PINGs are answered, the
      // subscription needs nothing else.
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(mesh.client.isSynced, isTrue);
      expect(relay.connections, 1);

      // The naming service's host hangs.
      relay.freeze();
      await until(() => !mesh.client.isSynced, 'loss noticed');
      expect(identical(mesh.synced, firstSynced), isFalse);
      // The stale table is kept meanwhile.
      expect(
        mesh.client.table.values.where((r) => r.endpoints.contains(endpoint)),
        hasLength(1),
      );

      // New connections get through: reconnected, registered again,
      // resynced, with nothing left of the dead channel.
      await mesh.synced.timeout(limit);
      expect(relay.connections, greaterThanOrEqualTo(2));
      await until(
        () =>
            naming.service.table.values
                    .where((r) => r.endpoints.contains(endpoint))
                    .length ==
                1 &&
            sameTable(mesh.client.table, naming.service.table),
        'registered again and mirrored',
      );
      expect(naming.service.channelCount, 1);
      expect(naming.service.watchCount, 1);
    });
  });
}
