// Shared setup of the sharding use case tests: a naming service and mesh
// nodes on 127.0.0.1 (TCP or WebSocket, port 0) or in this isolate (mem),
// with short timeouts, torn down in a fixed order.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:switchboard/switchboard.dart';
import 'package:test/test.dart';

const mux = MuxOptions(
  goAwayGrace: Duration(milliseconds: 100),
  keepAliveInterval: null,
);

/// The reply timeout must exceed the naming heartbeat, the watch timeout
/// too.
const talkOptions = TalkOptions(
  requestTimeout: Duration(seconds: 2),
  replyTimeout: Duration(seconds: 1),
);
const heartbeat = Duration(milliseconds: 50);
const watchTimeout = Duration(milliseconds: 500);
const reconnectDelay = Duration(milliseconds: 20);

/// Upper bound for anything a test waits on; only reached on failure.
const limit = Duration(seconds: 10);

Uint8List bytes(String text) => Uint8List.fromList(utf8.encode(text));

String text(Uint8List data) => utf8.decode(data);

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

/// Whether [error] is a failure a client retries after: the slot moved,
/// its owner is not there (yet), or the channel to it went away.
bool retryable(Object error) =>
    error is SwitchboardException &&
    const {
      StatusCode.moved,
      StatusCode.unavailable,
      StatusCode.connectionLost,
      StatusCode.goingAway,
      StatusCode.cancelled,
    }.contains(error.code);

/// A naming service and the nodes of one test.
///
/// [close] (registered as a tear-down by [start]) stops the naming service
/// first, so that leaving nodes do not hand their slots around, then
/// leaves every mesh, then closes every node.
class Cluster {
  Cluster(this.scheme);

  /// `tcp`, `ws` or `mem`.
  final String scheme;

  late final Switchboard namingNode;
  late final NamingService naming;
  late final Uri namingUri;

  final List<MeshNode> _meshes = [];
  final List<Switchboard> _nodes = [];
  final Map<Switchboard, List<MuxConnection>> _connections = {};

  Future<void> start({
    Duration holderGrace = const Duration(minutes: 1),
  }) async {
    addTearDown(close);
    naming = NamingService(
      heartbeat: heartbeat,
      assignmentHold: Duration.zero,
      holderGrace: holderGrace,
      handoverTimeout: const Duration(seconds: 5),
    );
    namingNode = await node();
    namingNode.registerService(Services.naming, naming.handler, instance: 1);
    namingUri = namingNode.listeningEndpoints.single;
    naming.registerLocal(Services.naming, [namingUri], instance: 1);
  }

  /// A new node listening on 127.0.0.1, or in this isolate for `mem`.
  Future<Switchboard> node({Resolver? resolver, bool listen = true}) async {
    final node = Switchboard(
      resolver: resolver,
      muxOptions: mux,
      talkOptions: talkOptions,
    );
    _nodes.add(node);
    final connections = _connections[node] = [];
    node.connections.listen(connections.add);
    if (listen) {
      switch (scheme) {
        case 'tcp':
          await node.listenTcp(InternetAddress.loopbackIPv4, 0);
        case 'ws':
          await node.listenWebSocket(
            InternetAddress.loopbackIPv4,
            0,
            path: '/mesh',
          );
        default:
          await node.listenMemory();
      }
    }
    return node;
  }

  /// Joins [node] to the mesh.
  MeshNode join(Switchboard node) {
    final mesh = MeshNode.join(
      node,
      namingUri,
      reconnectDelay: reconnectDelay,
      watchTimeout: watchTimeout,
      resolveTimeout: limit,
      talkOptions: talkOptions,
      leaveTimeout: const Duration(seconds: 2),
    );
    _meshes.add(mesh);
    return mesh;
  }

  /// A new node joined to the mesh, synced.
  Future<MeshNode> member({bool listen = true}) async {
    final mesh = join(await node(listen: listen));
    await mesh.synced.timeout(limit);
    return mesh;
  }

  /// Stops [mesh]'s node the way a crash does: every connection is cut
  /// at once, without GOAWAY and without leaving the mesh (the naming
  /// service sees the registration channel drop). Its naming client is
  /// closed afterwards, while nothing is reachable any more.
  Future<void> crash(MeshNode mesh) async {
    final node = mesh.switchboard;
    final cut = [
      for (final connection in _connections[node] ?? <MuxConnection>[])
        connection.close(),
    ];
    final closed = node.close();
    await Future.wait(cut);
    await closed;
    await mesh.leave();
  }

  Future<void> close() async {
    await naming.close();
    await namingNode.close();
    for (final mesh in _meshes) {
      await mesh.leave();
    }
    await Future.wait([for (final node in _nodes) node.close()]);
  }
}

/// Watches a mirror for migrations: how many slots migrate at once (at
/// most), and every slot that changed owner, in order.
class MigrationWatch {
  MigrationWatch(NamingClient client, this.type) {
    _subscription = client.slotEvents.listen((event) {
      if (event.type != type) {
        return;
      }
      if (event.entry.state == SlotState.migrating) {
        _migrating.add(event.slot);
        if (_migrating.length > maxConcurrent) {
          maxConcurrent = _migrating.length;
        }
      } else {
        _migrating.remove(event.slot);
      }
      if (event.previous.state == SlotState.migrating &&
          event.entry.state == SlotState.owned &&
          event.entry.owner != event.previous.owner) {
        moves.add((event.slot, event.previous.owner, event.entry.owner));
      }
    });
    addTearDown(() => _subscription.cancel());
  }

  final Name type;
  late final StreamSubscription<SlotEvent> _subscription;
  final Set<int> _migrating = {};

  /// The most slots seen migrating at the same time.
  int maxConcurrent = 0;

  /// Completed migrations: (slot, from, to).
  final List<(int, int, int)> moves = [];

  bool get idle => _migrating.isEmpty;
}
