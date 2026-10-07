/*
Polyverse Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Authors:
  Jan Boon <jan.boon@kaetemi.be>
  Claude Opus 5.5 <noreply@anthropic.com>
*/

// The untrusted worker fleet (wiki page "Polyverse Switchboard Use Cases", entry 5)
// in one isolate over mem:// endpoints: a naming service; a scaler that
// registers eight workers on its own `_ns` channel with requested ids, their
// endpoints and metadata (models and key); workers that only accept
// connections, behind a policy, checking their key; and a consumer joined
// to the mesh that keeps a PeerSet over them, exchanges capabilities on a
// per-worker channel, and load-balances over the online ones. Covered: all
// online, a worker reboot, an unregistered worker (held, then removed), a
// refused push from a worker, and credential isolation (each worker sees
// its own key, never the mesh credential; the naming service sees the mesh
// credential, and refuses channels without it).

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:switchboard/switchboard.dart';
import 'package:test/test.dart';

const mux = MuxOptions(
  goAwayGrace: Duration(milliseconds: 100),
  keepAliveInterval: null,
);
const talkOptions = TalkOptions(
  requestTimeout: Duration(seconds: 2),
  replyTimeout: Duration(seconds: 1),
);
const limit = Duration(seconds: 10);

final gpu = Name('gpu');
final back = Name('back');
final meshSecret = bytes('mesh-secret');

Uint8List bytes(String text) => Uint8List.fromList(utf8.encode(text));

String text(Uint8List data) => utf8.decode(data);

Future<void> until(bool Function() condition, [String? what]) async {
  final deadline = DateTime.now().add(limit);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('${what ?? 'condition'} not met within $limit');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

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

Switchboard newNode({
  Uint8List? defaultPayload,
  ChannelPolicy? outgoingPolicy,
  EndpointPolicy? endpointPolicy,
  EndpointCredential? credentialFor,
}) {
  final node = Switchboard(
    defaultPayload: defaultPayload,
    muxOptions: mux,
    talkOptions: talkOptions,
    outgoingPolicy: outgoingPolicy,
    endpointPolicy: endpointPolicy,
    credentialFor: credentialFor,
  );
  addTearDown(node.close);
  return node;
}

var _run = 0;

/// A rented GPU machine: listens only, behind a policy, at a fixed name
/// (kept across reboots); serves `gpu` under whatever id it was
/// registered with, for callers presenting its key.
class Worker {
  Worker(this.index, this.models)
    : name = 'fleet-$_run-worker-$index',
      key = 'worker-key-$index';

  final int index;
  final List<String> models;
  final String name;
  final String key;
  Switchboard? node;
  final List<Uint8List> raw = [];
  final List<MuxConnection> accepted = [];

  Uri get uri => Uri.parse('mem://$name');
  int get id => 0x100 + index;

  Uint8List get metadata => bytes(jsonEncode({'models': models, 'key': key}));

  Future<void> start() async {
    final n = node = newNode();
    n.registerService(gpu, _serve, acceptAnyInstance: true);
    n.connections.listen(accepted.add);
    await n.listenMemory(name: name, policy: ChannelPolicies.allowTypes({gpu}));
  }

  Future<void> stop() async {
    await node?.close();
    node = null;
  }

  void _serve(IncomingChannel incoming) {
    raw.add(incoming.channel.openPayload);
    if (text(incoming.address.payload) != key) {
      unawaited(incoming.reject(Status.of(StatusCode.unauthenticated)));
      return;
    }
    incoming.talk().messages.listen((message) {
      if (!message.expectsReply) {
        return;
      }
      switch (message.procedureName) {
        case 'CAPS':
          message.reply(bytes(jsonEncode(models)));
        case 'RUN':
          message.reply(bytes('$index ran ${text(message.payload)}'));
        default:
          message.replyAbort(Status.of(StatusCode.unimplemented));
      }
    });
  }

  /// Tries to push a channel into the consumer on its last connection.
  Future<Status> push() =>
      node!.openChannelOn(accepted.last, ChannelAddress(type: back)).done;
}

void main() {
  setUp(() => _run++);

  test('scaler, eight workers, consumer: online, reboot, unregister, '
      'refused push, credential isolation', () async {
    // Naming service: only for holders of the mesh credential.
    final namingNode = newNode();
    final naming = NamingService(assignmentHold: Duration.zero);
    addTearDown(naming.close);
    final namingPayloads = <String>[];
    namingNode.registerService(Services.naming, (incoming) {
      final payload = incoming.address.payload;
      namingPayloads.add(text(payload));
      if (text(payload) != text(meshSecret)) {
        return incoming.reject(Status.of(StatusCode.unauthenticated));
      }
      return naming.handler(incoming);
    }, instance: 1);
    final namingUri = await namingNode.listenMemory();
    naming.registerLocal(Services.naming, [namingUri], instance: 1);

    // Workers.
    final workers = [
      for (var i = 0; i < 8; i++)
        Worker(i, i.isEven ? ['llm'] : ['llm', 'tts']),
    ];
    for (final w in workers) {
      await w.start();
      addTearDown(w.stop);
    }

    // The scaler registers them on its own channel.
    final scalerNode = newNode(defaultPayload: meshSecret);
    final scaler = namingClientFor(
      scalerNode,
      namingUri,
      reconnectDelay: const Duration(milliseconds: 20),
      talkOptions: talkOptions,
    );
    addTearDown(scaler.close);
    unawaited(scaler.start());
    for (final w in workers) {
      expect(
        await scaler.register(
          gpu,
          [w.uri],
          instance: w.id,
          metadata: w.metadata,
        ),
        w.id,
      );
    }

    // The consumer: trusts the naming service, nothing else; presents each
    // worker its own key from the record, the mesh credential only to the
    // naming service.
    final consumer = newNode(
      defaultPayload: meshSecret,
      outgoingPolicy: ChannelPolicies.denyAll,
      endpointPolicy: (endpoint) =>
          endpoint == namingUri ? ChannelPolicies.allowAll : null,
      credentialFor: (endpoint, record) {
        if (endpoint == namingUri) {
          return meshSecret;
        }
        if (record == null || record.metadata.isEmpty) {
          return null;
        }
        final meta = jsonDecode(text(record.metadata)) as Map<String, Object?>;
        return bytes(meta['key']! as String);
      },
    );
    consumer.registerService(back, (incoming) => incoming.reject(Status.ok));
    final mesh = MeshNode.join(
      consumer,
      namingUri,
      reconnectDelay: const Duration(milliseconds: 20),
      resolveTimeout: limit,
      talkOptions: talkOptions,
    );
    addTearDown(mesh.leave);
    final capabilities = <int, List<String>>{};
    final fleet = PeerSet.watch(
      consumer,
      gpu,
      channel: ChannelAddress(type: gpu),
      onOpen: (peer, channel) async {
        final talk = TalkChannel(channel, options: talkOptions);
        final reply = await talk.request('CAPS', Uint8List(0));
        capabilities[peer.address.instance] =
            (jsonDecode(text(reply.payload)) as List<Object?>).cast<String>();
      },
      initialBackoff: const Duration(milliseconds: 20),
      maxBackoff: const Duration(milliseconds: 200),
      removalHoldDown: const Duration(milliseconds: 200),
    );
    addTearDown(fleet.close);
    final events = <String>[];
    fleet.events.listen(
      (e) => events.add('${e.type.name} ${e.peer.address.instance - 0x100}'),
    );
    await fleet.ready.timeout(limit);
    await until(() => fleet.online.length == 8, 'all eight online');
    expect(capabilities.keys.toSet(), {for (final w in workers) w.id});

    // Online means the capability exchange is done: every online worker
    // has its capabilities.
    List<String> capabilitiesOf(Peer peer) {
      final known = capabilities[peer.address.instance];
      if (known == null) {
        fail('${peer.address} is online without its capabilities');
      }
      return known;
    }

    // Load balancing by the application: the online workers with `tts`.
    final tts = [
      for (final peer in fleet.online)
        if (capabilitiesOf(peer).contains('tts')) peer,
    ];
    expect(tts, hasLength(4));
    for (final peer in tts) {
      final talk = await fleet.openTalk(peer.address.instance);
      final reply = await talk.request('RUN', bytes('speech'));
      expect(
        text(reply.payload),
        '${peer.address.instance - 0x100} ran speech',
      );
      await talk.close();
    }

    // A worker reboots: offline, and back online at the same address; it
    // stays registered meanwhile.
    final rebooted = workers[3];
    await rebooted.stop();
    await until(() => !fleet.peers[rebooted.id]!.isOnline, 'offline');
    expect(fleet.online, hasLength(7));
    expect(fleet.peers, hasLength(8));
    await rebooted.start();
    await until(() => fleet.peers[rebooted.id]!.isOnline, 'back online');
    expect(events.where((e) => e.endsWith(' 3')), [
      'added 3',
      'online 3',
      'offline 3',
      'online 3',
    ]);

    // The scaler retires a worker: held for the hold-down (no longer
    // online), then removed, and its connection goes.
    final retired = workers[5];
    await scaler.unregister(gpu, retired.id);
    await until(() => events.contains('held 5'), 'held');
    expect(fleet.online, hasLength(7));
    expect(fleet.peers[retired.id]!.state, PeerState.held);
    await until(() => !fleet.peers.containsKey(retired.id), 'removed');
    await retired.accepted.last.done.timeout(limit);
    expect(events.where((e) => e.endsWith(' 5')).skip(2), [
      'held 5',
      'removed 5',
    ]);
    expect(fleet.online, hasLength(7));

    // A worker may not push channels into the consumer.
    final pushed = await workers[0].push();
    expect(pushed.known, StatusCode.permissionDenied);
    expect(pushed.reason, 'permission denied');

    // Every worker saw its own key and nothing else.
    for (final w in workers) {
      expect(w.raw, isNotEmpty);
      for (final open in w.raw) {
        expect(text(ChannelAddress.decode(open).payload), w.key);
        expect(containsBytes(open, meshSecret), isFalse);
      }
    }
    // The naming service saw the mesh credential, from the scaler and the
    // consumer alike, and nothing else.
    expect(namingPayloads, hasLength(greaterThanOrEqualTo(2)));
    expect(namingPayloads, everyElement(text(meshSecret)));
    // Without it, the naming service is out of reach.
    final stranger = newNode();
    final refused = await stranger.openChannelAt(
      namingUri,
      ChannelAddress(type: Services.naming),
    );
    expect(
      (await refused.done.timeout(limit)).known,
      StatusCode.unauthenticated,
    );

    await fleet.close();
    expect(fleet.peers, isEmpty);
  });
}
