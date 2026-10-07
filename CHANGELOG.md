## 3.0.0-dev.1

Rewrite from scratch on Dart 3.13 with a completed protocol design. The
wire format is new and not compatible with 2.x, which was never deployed.
The protocol specification lives in the project wiki (section
"Switchboard").

- Libraries: `core.dart` without `dart:io` (compiles for the web) and
  `switchboard.dart` with the `dart:io` parts.
- Transport: the `StreamChannel<Uint8List>` frame contract; the stream
  binding (preamble, `u32` length prefix) over TCP or any byte stream, with
  output backpressure, close timeout and linger; the WebSocket binding
  (subprotocol `switchboard`) for clients on every platform, with a
  connect timeout, and on `dart:io`; `WebSocketServerTransport`, a server side that bounds whole
  messages before buffering them and never negotiates compression; an
  in-memory pair; the optional capabilities `FrameLimited`,
  `AbortableTransport` and `OutputBufferedTransport`.
- Mux: channels opened by either side, short and long ids reused after
  mutual close, reserved ids, a control channel with PING, PONG, GOAWAY and
  LIMITS, status payloads in CLOSE, keep-alive, graceful shutdown, the
  peer's GOAWAY status and byte counters for clients.
- Talk: plain messages, requests, stream requests, chained responses and
  item requests to any depth, aborts with status codes, channel aborts,
  `EXTEND`, cancellation, requester and responder timeouts, request limits,
  and `forwardMessage` for message chain proxying; for generated stubs, a
  `Name` parameter beside every procedure string and
  `TalkMessage.replyStream`.
- Addressing: `ServiceAddress` and `ChannelAddress` (the OPEN payload with
  service type, instance, shard slot, host hint and application payload).
- `Switchboard` node: TCP and WebSocket listeners, in-process `mem://`
  listeners (`listenMemory`) for running a whole mesh in one isolate,
  connections accepted by an application's own HTTP server (`accept`,
  `acceptWebSocket`, and `onOtherRequest` of `listenWebSocket` for the
  other paths of its port), pooled outgoing connections, dispatch by
  `(type, instance)` with a default service and a catch-all, dispatch on
  initiated connections too, static, endpoint and naming resolvers, round
  robin and shard slot selection, a default application payload per node.
- Naming service: `NamingService` (`REGISTER`, `UNREGSTR`, `WATCH` and
  `UNWATCH` subscriptions, `LOOKUP`, assignment hold after a restart),
  `NamingClient`
  (re-registration on reconnect, mirrored table served while stale),
  `NamingResolver`, and `MeshNode` to join a node to a mesh.
- `ReconnectingClient` (core, web-capable) for frontend apps: backoff
  reconnect, a client state stream, persistent channels re-opened after
  every reconnect, server-pushed channels across reconnects, an immediate
  move to a new connection on the endpoint's GOAWAY, `reconnectNow` (also
  forced) and `ClientState.nextAttemptAt` for app resume and connectivity
  changes.
- Proxying: `proxyHandler` and `pipeChannels` for frontend endpoints and
  host hint relays, routing by shard slot with a one-shot retry on `MOVED`,
  an asynchronous `authorize` hook that may rewrite the address, and
  refusal of slot-less channels to sharded types unless `allowNoSlot`
  admits the type.
- Sharding: slot spaces per service type in the naming service (`SLOTS`,
  `HOLDING`, `CLAIM`, `RELEASE`, `LOCATE`, `MIGRATE`, `SLOTSPC` and `SLOT`
  table items), managed and static modes, lazy and shared-recovery flags,
  holder tracking for reboot, the allocator, and the `DRAIN`, `ASSIGN`,
  `FORWARD`, `RESUME` hand-over; on the node, slot-aware routing,
  `openChannelToSlot`, `SlotGate` and `SlotLifecycle`, and
  `MeshNode.publishSharded`; the `MOVED` status with the owner and epoch
  as fixed fields (nothing was processed); statuses relay byte for byte;
  use case integration tests
  (key-value store, Discord frontends, per-user workers, zone servers, chat
  rooms, job partitions).
- Sharding: status code 38 `RELOCATED` (`StatusCode.relocated`, same
  fields as `MOVED`) for work the slot moved away from after it started,
  replacing `ABORTED`, never retried; `MeshNode.leave()` hands each slot
  of a holder-only managed space over to another instance while the node
  is still up, releases the rest, and returns a `LeaveReport`; requests a
  `SlotGate` forwards during a hand-over carry the credential of the
  channel they arrived on (or `serveRequest`'s `payload`), one forwarding
  channel per credential, never the node's default payload.
- Sharding: `SlotLifecycle.serve` and `discard` return `FutureOr<void>`
  (existing `void` overrides stay valid), and a `SlotGate` watches the
  returned future: an asynchronous `serve` that fails closes its channel
  with `INTERNAL`, a failed `discard` is logged, and neither escapes as an
  unhandled error. A `SlotGate` never forwards to its own node: forwarded
  channels and requests skip this node's own listeners
  (`excludeOwnEndpoints`, `UNAVAILABLE`), and a `DRAIN` or `FORWARD` naming
  no instance or this one is refused with `FAILED_PRECONDITION` (the
  `FORWARD` then stops the slot as a revocation does).
- Worker fleet support (wiki use case 5): an opaque metadata blob in
  service records (`ServiceRecord.metadata`, a `u16` length and up to 4096
  bytes after the endpoints, in `UP` items and `REGISTER`; a record without
  it decodes as empty), registered with `NamingClient.register(metadata:)`
  or `NamingService.registerLocal(metadata:)` and published again as `UP`
  when it changes; a `where` filter over the records on `openChannel`,
  `openTalk`, `openChannelToSlot`, `openTalkToSlot` and `selectAndConnect`
  (`NOT_FOUND` when nothing matches); a selection policy per node
  (`Switchboard(selection: SelectionPolicy.random, random:)`, round robin
  by default); `registerService(acceptAnyInstance: true)` for a service
  registered under an id it was never told; the registrar pattern (one
  client registering records for endpoints that never talk to the naming
  service, alive as long as its channel). On the consumer side: a policy
  on the connections a node initiates (`Switchboard(outgoingPolicy:)`, an
  `endpointPolicy` hook per endpoint, `connect(policy:)`, and
  `ChannelPolicies.denyAll`), so that a peer the node dialled cannot push
  channels into it, evaluated on the endpoint as the pool keys it so every
  spelling of an endpoint gets the same policy; the credential chosen per
  destination (`Switchboard(credentialFor:)`, given the endpoint and the
  selected record, so a per-worker key can come from its metadata, which
  every watcher of the naming table sees: it authenticates the mesh to the
  worker, not the reverse), after which the node's default payload is
  never attached implicitly; `Switchboard.dial` for an un-pooled
  connection and `payloadFor`; a `MOVED` retry whose new owner the `where`
  filter refuses ends with `NOT_FOUND`; and `PeerSet.watch(type)`, a
  connection kept to every instance of a type with backoff per peer,
  `added`, `online`, `offline`, `updated`, `held` and `removed` events,
  an `onConnect` hook, and a per-peer channel re-opened on every
  connection with an `onOpen` hook for the capability exchange. A peer is
  online only once usable: a hook that throws, fails or times out, or a
  per-peer channel the worker refuses, fails the attempt (GOAWAY, backoff),
  and a re-open goes through the same PING and bounded `onOpen`, the peer
  offline meanwhile. The endpoints of a record share the connect timeout,
  so one that never answers leaves time for the next. A record that
  leaves is held for `removalHoldDown` (15 s) with its connection kept and
  adopted again if it comes back, so that a naming service or registrar
  restart does not cut the jobs in flight. Events that arrive while the
  initial records are read are folded into them; resolver errors are
  logged; `watch` warns when no policy applies to its connections or the
  node's default payload would reach every peer.
- Protocol change, naming service: `WATCH` is a subscription instead of a
  stream request that never completes and was kept alive by `EXTEND`
  heartbeats. It is a plain request: the snapshot follows as one-way
  `UP`, `SLOTSPC` and `SLOT` messages, then the reply, which marks the
  end of the snapshot (`SYNCED` is gone), then the live `UP`, `DOWN`,
  `SLOTSPC` and `SLOT` messages, sent once per channel per change.
  Subscriptions are per channel and type filter, counted per `WATCH`,
  given back with the new `UNWATCH` request (`NOT_FOUND` without one),
  and end with the channel; at most
  `NamingService.maxWatchesPerChannel` (1024) filters per channel.
  Liveness is the connection's (mux keep-alive). `NamingService`'s
  `heartbeat` option is replaced by `heldExtendInterval` (the `EXTEND`
  interval of held requests, 4 s), and `NamingClient`, `namingClientFor`
  and `MeshNode.join` lose `watchTimeout` (the channel's request timeout
  bounds `WATCH`). Talk requests take `ordered: true` to have their answer
  delivered in wire order with `TalkChannel.messages`; the naming client
  uses it for `WATCH`, `REGISTER` and `UNREGSTR`.
- Protocol change, Talk: `EXTEND` declares a deadline instead of being a
  heartbeat. Its payload is empty (restart the requester's default
  timeout, as before) or `u32 deadline ms, u32 renew ms` (0: unchanged;
  any other length is a channel protocol error). After a declaration the
  request times out at the later of the deadline and the last reply plus
  the renewal, on both sides; the responder puts
  `TalkOptions.extendBuffer` (5 s) on the wire and not on its own timer,
  so it gives up first; the requester raises the values to
  `TalkOptions.minExtension` (1 s) and lowers them to
  `TalkOptions.maxExtension` (1 h); a declaration beyond the `u32` field
  (about 49.7 days, buffer included) is lowered on both sides, the buffer
  kept. `TalkMessage.extend({deadline, renew, buffer})`; `onExtend`
  callbacks receive `(deadline, renew)`;
  `TalkRequest.deadline` and `TalkStream.deadline` show the expiry;
  `forwardMessage` passes `EXTEND` payloads through unchanged. Nothing in
  the library sends `EXTEND` from a timer any more: `SlotHandler` methods
  and `SlotLifecycle.load` and `drain` receive a `SlotRequestContext`
  (`type`, `slot`, `epoch`, `extend`, `isCancelled`, `onCancel`) to declare
  their estimates, `NamingClient` loses `slotExtendInterval` (the handler
  call is still bounded by `slotHandlerMaxDuration`), `SlotGate` declares
  its `drainTimeout` when a `DRAIN` waits for work in flight, and
  `NamingService` loses `heldExtendInterval`: a request it holds is sent
  one `EXTEND` declaring the wait (the time left in the assignment hold,
  the hand-over timeout of the `ASSIGN` it waits for, the time left of a
  `LOCATE` backoff wait), and the deadlines instances declare for `ASSIGN`
  and `DRAIN` are passed on to the requests waiting for them, the
  `MIGRATE` requester included. Adds a dependency on `package:clock`.
- Security and resource limits: listener policies, with ready-made ones
  that refuse the reserved types, generic rejection reasons, frame limits checked before
  allocation, per-channel and per-connection receive buffers, a budget for
  held OPEN payloads, a cap on unconfirmed CLOSEs, output high-water marks,
  a per-client limit on proxied channels, and host hint relaying only on
  request.
- Tests: over 1000 tests, including the wiki test vectors (the codec tests also
  run on Node.js with `dart test -P node`) and integration tests over TCP
  and WebSocket.
- Documentation: README with quick start programs (`example/`), and the
  wiki page "Switchboard Dart Reference Implementation".

## 2.1.7

- Use `WebSocketChannel` and `StreamChannel` interfaces.

## 2.0.6

- Don't reset payload if identical.

## 2.0.5

- Fix issue reconnecting after previous error.

## 2.0.4

- Rebranding
- Rewrite from scratch with simplified interface.
- Support channels for allowing virtual services or protocols on the same host (virtual hosts, etc.)

## 1.3.3

- Can now request for streams. Stream responses can recursively be requests as well.

## 1.2.1

- Request messages can be replied to with an exception using `sendException`.
- Request message timeout can be extended through the `sendExtend` function.
- Formatted source.
- Fixed some minor issues.

## 0.9.3

- Initial version.
