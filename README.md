# Switchboard

A protocol for a mesh of services, and its reference implementation in Dart.

Services in a mesh often need one particular instance of another service: the server that runs a game zone, the shard that holds a chat room, the process that owns a session. Browsers, apps and devices need to reach those same instances through a public endpoint. Common RPC stacks address hosts or load-balanced pools, and the frontend speaks a second protocol.

Switchboard is built in layers. A transport (WebSocket, or a length-prefixed byte stream such as TCP) carries frames. The mux layer splits one connection into channels that either side can open. Talk carries message chains on a channel: requests, stream responses, replies that are themselves requests, cancellation and timeouts. The Switchboard layer puts a service address in each channel's OPEN, dispatches incoming channels to local services, pools connections and resolves addresses.

Channels are opened to a service address `(type, instance)`, and each channel carries its own credential. A naming service, spoken over the same protocol, assigns instance ids and pushes the service table to every node. The wire format is the same for a browser, a backend service and an embedded device, so a frontend endpoint forwards a channel without parsing it. Headers are byte aligned, little endian and fixed size where possible, and the specification has an embedded profile, so a peer can be written in C without a heap.

## Status

Version 3.0.0-dev: a rewrite on Dart 3.13 with a new wire format, not compatible with 2.x. It is not deployed yet. The protocol is specified in the project wiki (see [Specification](#specification)). This package implements all of it, sharding included. The wire format may still change before 3.0.0.

## Install

Version 3 is not published on pub.dev yet. Depend on it by git or by path:

```yaml
dependencies:
  switchboard:
    git:
      url: https://github.com/kaetemi/switchboard
      ref: master
    # or: path: ../switchboard
```

Import `package:switchboard/switchboard.dart` for everything, or `package:switchboard/core.dart` for the parts that do not need `dart:io` (see [Platforms](#platforms)).

## Quick start

The programs below are the files in `example/`. Each one binds port 0 on the loopback interface, prints what it does and exits. Run one with `dart run example/echo_tcp.dart`. With `-v`, `echo_tcp.dart` also prints the library's log through `package:logging`.

### Server and client over TCP

A node registers a Talk service and listens on TCP. A second node finds the service in a static table, sends a request and a stream request, and both nodes shut down.

```dart
// Server and client over TCP in one process: a request and a stream request.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:switchboard/switchboard.dart';

Future<void> main(List<String> args) async {
  // `-v` shows the library's own log.
  if (args.contains('-v')) {
    Logger.root.level = Level.FINE;
    Logger.root.onRecord.listen(
      (r) => print('  ${r.loggerName}: ${r.message}'),
    );
  }
  final echo = Name('echo');

  // The server runs instance 1 of `echo` and listens on a free port.
  final server = Switchboard();
  server.registerService(echo, (incoming) {
    incoming.talk().messages.listen((message) {
      if (!message.expectsReply) {
        return; // A plain message; nothing to answer.
      }
      switch (message.procedureName) {
        case 'UPPER':
          final text = utf8.decode(message.payload);
          message.reply(utf8.encode(text.toUpperCase()));
        case 'COUNT':
          for (var i = 1; i <= 3; i++) {
            message.replyItem(utf8.encode('$i'));
          }
          message.reply(utf8.encode('done'));
        default:
          message.replyAbort(Status.of(StatusCode.unimplemented));
      }
    });
  }, instance: 1);
  final uri = await server.listenTcp(
    InternetAddress.loopbackIPv4,
    0,
    policy: ChannelPolicies.allowTypes({echo}),
  );
  print('server: listening on $uri');

  // The client finds `echo` in a static table.
  final resolver = StaticResolver([
    ServiceRecord(ServiceAddress(echo, 1), endpoints: [uri]),
  ]);
  final client = Switchboard(resolver: resolver);
  final talk = await client.openTalk(ServiceAddress(echo));

  final reply = await talk.request('UPPER', utf8.encode('hello'));
  print('client: UPPER hello -> ${utf8.decode(reply.payload)}');

  final stream = talk.streamRequest('COUNT', Uint8List(0));
  await for (final item in stream.items) {
    print('client: COUNT item ${utf8.decode(item.payload)}');
  }
  print('client: COUNT final ${utf8.decode((await stream.done).payload)}');

  // Close the channel, then the nodes. The resolver belongs to the caller.
  await talk.close();
  await client.close();
  await server.close();
  await resolver.close();
}
```

### A mesh with a naming service

A naming node hosts the naming service. A backend joins the mesh with `MeshNode` and publishes a service, and the naming service assigns its instance id. A client joins, waits for the mirrored table and calls the service by type.

```dart
// A small mesh: a naming node, a backend publishing a service, a client.
import 'dart:convert';
import 'dart:io';

import 'package:switchboard/switchboard.dart';

Future<void> main() async {
  final greet = Name('greet');
  final loopback = InternetAddress.loopbackIPv4;

  // The naming node hosts the naming service as `_ns/1`. The hold delays
  // assignments after a restart so that surviving services get their ids
  // back; this mesh is new, so it is turned off.
  final namingNode = Switchboard();
  final naming = NamingService(assignmentHold: Duration.zero);
  namingNode.registerService(Services.naming, naming.handler, instance: 1);
  final namingUri = await namingNode.listenTcp(loopback, 0);
  naming.registerLocal(
    Services.naming,
    namingNode.listeningEndpoints,
    instance: 1,
  );
  print('naming: listening on $namingUri');

  // The backend listens first: publish() registers its listening endpoints.
  final backend = Switchboard();
  await backend.listenTcp(loopback, 0);
  final backendMesh = MeshNode.join(backend, namingUri);
  final id = await backendMesh.publish(greet, (incoming) {
    final self = incoming.address.address;
    incoming.talk().messages.listen((message) {
      if (message.expectsReply) {
        final name = utf8.decode(message.payload);
        message.reply(utf8.encode('hello $name, this is $self'));
      }
    });
  });
  print('backend: published ${ServiceAddress(greet, id)}');

  // The client joins the mesh and resolves through the mirrored table.
  final client = Switchboard();
  final clientMesh = MeshNode.join(client, namingUri);
  await clientMesh.synced;
  print('client: table ${clientMesh.client.table.keys.join(', ')}');
  final talk = await client.openTalk(ServiceAddress(greet));
  final reply = await talk.request('HELLO', utf8.encode('client'));
  print('client: ${utf8.decode(reply.payload)}');
  await talk.close();

  // Leave the mesh before closing a node; the naming node goes last.
  await clientMesh.leave();
  await client.close();
  await backendMesh.leave();
  await backend.close();
  await naming.close();
  await namingNode.close();
}
```

### A frontend endpoint

An endpoint faces clients on a WebSocket listener with a listener policy, and proxies `chat` channels to a backend with `proxyHandler`. The client only knows the endpoint (`EndpointResolver`) and sends its session token as its default application payload. The backend receives the token unchanged.

```dart
// A frontend endpoint proxying `chat` channels from clients to a backend.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:switchboard/switchboard.dart';

Future<void> main() async {
  final chat = Name('chat');
  final loopback = InternetAddress.loopbackIPv4;

  // A backend runs `chat/7` behind the endpoint. It sees the client's own
  // credential in the application payload.
  final backend = Switchboard();
  backend.registerService(chat, (incoming) {
    final address = incoming.address;
    final credential = utf8.decode(address.payload);
    incoming.talk().messages.listen((message) {
      if (message.expectsReply) {
        message.reply(utf8.encode('${address.address} got "$credential"'));
      }
    });
  }, instance: 7);
  final backendUri = await backend.listenTcp(loopback, 0);

  // The endpoint resolves backends itself (a static table here, a MeshNode
  // in a mesh) and proxies every channel that no local service claims.
  final table = StaticResolver([
    ServiceRecord(ServiceAddress(chat, 7), endpoints: [backendUri]),
  ]);
  final endpoint = Switchboard(resolver: table);
  endpoint.catchAll = proxyHandler(
    endpoint,
    // Checked for every channel: `chat` only, with a credential.
    allow: (address) => address.type == chat && address.payload.isNotEmpty,
    // `authorize:` could also verify it asynchronously and rewrite the address.
  );
  // Internet facing, so the listener has a policy. It refuses every type
  // but `chat`, including the reserved ones such as `_ns`.
  final endpointUri = await endpoint.listenWebSocket(
    loopback,
    0,
    path: '/sb',
    policy: ChannelPolicies.allowTypes({chat}),
  );
  print('endpoint: listening on $endpointUri');

  // A client only knows the endpoint. Its default payload is its session.
  final client = Switchboard(
    resolver: EndpointResolver(endpointUri),
    defaultPayload: utf8.encode('session-42'),
  );
  final talk = await client.openTalk(ServiceAddress(chat));
  final reply = await talk.request('WHO', Uint8List(0));
  print('client: ${utf8.decode(reply.payload)}');
  await talk.close();

  // Refused channels end with PERMISSION_DENIED and a generic reason.
  for (final type in [Services.naming, Name('admin')]) {
    final refused = await client.openChannel(ServiceAddress(type));
    print('client: $type -> ${await refused.done}');
  }
  final anonymous = await client.openChannel(
    ServiceAddress(chat),
    payload: Uint8List(0),
  );
  print('client: chat without a session -> ${await anonymous.done}');

  await client.close();
  await endpoint.close();
  await backend.close();
  await table.close();
}
```

It prints (the port varies):

```
endpoint: listening on ws://127.0.0.1:46363/sb
client: chat/7 got "session-42"
client: _ns -> permissionDenied: permission denied
client: admin -> permissionDenied: permission denied
client: chat without a session -> permissionDenied: permission denied
```

To serve other routes on the same port (OAuth returns, `.well-known` files), give `listenWebSocket` an `onOtherRequest` callback, or hand the node an upgrade from your own `HttpServer` with `acceptWebSocket`.

### The lower layers alone

`MuxConnection` and `TalkChannel` work over any `StreamChannel<Uint8List>` that carries one frame per event. Use them directly in a browser client (over `WebSocketTransport.connect`) or in a peer that does its own addressing. Only `core.dart` is needed.

```dart
// The lower layers alone: mux and Talk over an in-memory transport.
import 'dart:convert';
import 'dart:typed_data';

import 'package:switchboard/core.dart';

Future<void> main() async {
  // Two connected transports. Any StreamChannel<Uint8List> carrying one
  // mux frame per event works the same way.
  final (left, right) = MemoryTransport.pair();
  final initiator = MuxConnection(left, isInitiator: true);
  final acceptor = MuxConnection(right, isInitiator: false);

  // The acceptor answers Talk requests on every channel the peer opens.
  acceptor.incoming.listen((channel) {
    final address = ChannelAddress.decode(channel.openPayload);
    print('acceptor: channel ${channel.id} opened for ${address.address}');
    TalkChannel(channel).messages.listen((message) {
      if (message.expectsReply) {
        message.reply(utf8.encode('pong'));
      }
    });
  });

  // The mux does not interpret the OPEN payload; this one is an address
  // header, as a Switchboard node would send.
  final channel = initiator.open(ChannelAddress(type: Name('demo')).encode());
  final talk = TalkChannel(channel);
  final reply = await talk.request('PING', Uint8List(0));
  print('initiator: PING -> ${utf8.decode(reply.payload)}');
  print('initiator: mux round trip ${await initiator.ping()}');

  await talk.close();
  await initiator.goAway();
  print('acceptor: connection ended with ${await acceptor.done}');
}
```

## Security defaults and resource limits

* **Listener policy.** `listenTcp` and `listenWebSocket` (and `accept` and `acceptWebSocket`) take a `policy` that decides which service types a peer on that listener may address. Without one everything is allowed, which is only safe on internal listeners. A listener reachable by untrusted peers must set a policy that refuses the reserved types: `ChannelPolicies.denyReserved`, or `ChannelPolicies.allowTypes` with an explicit list. Otherwise a peer can reach the naming service `_ns`, register services and receive other peers' channels and credentials.
* **Outgoing connections.** A connection a node initiates is trusted by default: the peer may open channels to its local services. A node that dials peers it does not trust (workers on rented machines) sets `Switchboard(outgoingPolicy: ChannelPolicies.denyAll)`, or chooses per endpoint with `endpointPolicy`, and chooses the credential per destination with `credentialFor`, so that its own `defaultPayload` never reaches them. A per-instance key can come from the record's metadata, which every watcher of the naming table sees: such a key authenticates the mesh to the worker, not the worker to the mesh. `PeerSet.watch` keeps a connection to every instance of such a type.
* **Proxy.** `proxyHandler` refuses reserved types unless its `allow` filter admits them, forwards at most 256 channels at a time per client connection by default, refuses channels without a shard slot to sharded types (the state transfer path) unless `allowNoSlot` admits the type, and never forwards to the node's own listeners. It acts on host hints only with `Switchboard(allowHostHint: true)`, which makes the node an open relay.
* **Identity.** A node can prove who it is on its connections: `Switchboard(credential: ..., holderKey: ...)` identifies with a signed credential (`CredentialIssuer`, HMAC-SHA256 or Ed25519) on every connection it initiates, and a node with a `verifier` checks the credentials its peers present, so that its policies can read `connection.peerIdentity`. `ChannelPolicies.scoped()` admits only the service types the peer's credential has an `open` scope for, so a worker whose credential opens nothing can open nothing, whichever side dialled. Present a credential only to peers in the mesh's trust domain (`identifyFor`): a bearer credential is reusable by whoever receives it, and a peer can relay a handshake. Without credentials nothing changes; the naming service does not check scopes yet.
* **Rejections.** Statuses sent to peers carry a generic reason such as `permission denied`. Instance ids, endpoints and resolver state go to the local log only.
* **Frame size.** Frames are limited to 1 MiB by default (`MuxOptions.maxFrameSize`, which a `Switchboard` also applies to its transports). The WebSocket listener uses `WebSocketServerTransport`, which checks the size of a message, all fragments counted, before buffering it, and never negotiates compression.
* **Buffers.** Unread data is buffered up to 4 MiB per channel; beyond that the channel is closed with `RESOURCE_EXHAUSTED`. Above 16 MiB over all channels, the connection stops reading the transport until half has drained. The number of channels, the OPEN payloads they hold and the unconfirmed CLOSEs are bounded too.
* **Backpressure.** A transport whose peer does not read queues at most 16 MiB of output, then stops reading its input. A close that cannot drain in time destroys the connection.
* **Liveness and timeouts.** The mux sends PING after 10 s of silence and drops the connection if nothing arrives within 10 s more. A Talk request fails after 15 s without a response, `EXTEND` or stream item, and a responder has 10 s to reply before the request is aborted for it, unless the responder declares a longer deadline with `TalkMessage.extend`.

Every limit is an option. The wiki page "Switchboard Dart Reference Implementation" has the full table.

## Platforms

* `package:switchboard/core.dart` does not import `dart:io` and compiles for the web. It has the status codes, names, the in-memory and WebSocket client transports, the stream binding wire format, the mux and Talk layers, credentials and connection identity, addressing, the naming service and client, and the resolvers.
* `package:switchboard/switchboard.dart` adds the `dart:io` parts: the TCP transport, the WebSocket server transports, `Switchboard`, `MeshNode`, `PeerSet`, `proxyHandler`, `namingClientFor`, and the instance side of sharding (`SlotGate`, `SlotLifecycle`).
* `dart test` runs the whole suite on the VM. `dart test -P node` runs the codec, test vector and identity tests compiled to JavaScript on Node.js, which checks the 32 and 48-bit arithmetic of the wire codecs and the pure Dart Ed25519.
* `Switchboard.listenMemory` gives a node an in-process `mem://` endpoint, so a whole mesh (naming service included) can run in one isolate, for tests or a single-process mode; `mem://` URIs mean nothing outside that isolate, so publish them to a naming service only when every node is in it.

## Specification

The protocol is specified in the project wiki, section "Switchboard". Where this package and the wiki disagree, the wiki is the reference. The pages:

* Switchboard: overview, design goals and layer model
* Switchboard Status and Analysis: what existed before the rewrite and what changed
* Switchboard Status Codes
* Switchboard Transport: WebSocket and stream bindings
* Switchboard Mux
* Switchboard Talk
* Switchboard Addressing and Dispatch
* Switchboard Naming Service
* Switchboard Sharding: slot spaces, ownership and migration
* Switchboard Proxying
* Switchboard Embedded Profile: the subset a minimal C peer implements
* Switchboard Test Vectors
* Switchboard Dart Reference Implementation: the API guide for this package

`doc/dart-design.md` is the design record kept while the package was built.

## Sharding

A sharded type splits its work over its instances by slot: a key hashes to a slot, the naming service gives every slot one owner, and moves slots between instances (when one joins, or on request) without losing or reordering the requests in flight. Each instance publishes the type with a `SlotLifecycle`: `load` a slot when it is assigned (from local storage, from the instance that holds it, or from shared storage), `drain` it when it moves away, `unload` it, and `serve` the channels addressed to it. The `SlotGate` that `publishSharded` installs queues a slot's channels while it is loaded or locked for a move, pipes them to the new owner afterwards, and answers `MOVED` for slots served elsewhere. Any node reaches a slot's owner through its table:

```dart
final kv = Name('kv');
const slots = 1024;

/// A key-value store: one map per slot. A real store loads a moved slot
/// from its holder (`holder`), here it starts empty.
class Store extends SlotLifecycle {
  final Map<int, Map<String, String>> data = {};

  @override
  Future<AssignResult> load(int slot,
      {required int epoch, required int holder, required bool shared}) async {
    data.putIfAbsent(slot, () => {});
    return AssignResult.holding;
  }

  @override
  Future<void> unload(int slot) async => data.remove(slot);

  @override
  void serve(IncomingChannel channel, int slot) {
    channel.talk().messages.listen((m) {
      final [verb, key, ...value] = utf8.decode(m.payload).split(' ');
      if (verb == 'PUT') data[slot]![key] = value.join(' ');
      m.reply(utf8.encode(data[slot]![key] ?? ''));
    });
  }
}

// Each store node, with a stable instance id so that it gets its slots
// back after a reboot:
await mesh.publishSharded(kv, Store(), count: slots, instance: 0x11);

// Any node in the mesh:
final key = 'user:42';
final talk = await node.openTalkToSlot(kv, slotForText(key, slots));
await talk.request('PUT', utf8.encode('PUT $key hello'));
```

The wiki page "Switchboard Sharding" has the protocol and six worked use cases, each an integration test in `test/integration/sharding/`.

## License

BSD 3-Clause. See `LICENSE`.
