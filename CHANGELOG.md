# Polyverse Switchboard changelog

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
  messages (size and fragment count) before buffering them, buffers a
  fragmented message at about its size, and never negotiates compression; an
  in-memory pair; the optional capabilities `FrameLimited`,
  `AbortableTransport`, `OutputBufferedTransport` and
  `OutputReadyTransport`.
- Mux: channels opened by either side, short and long ids reused after
  mutual close, reserved ids, a control channel with PING, PONG, GOAWAY and
  LIMITS (at most `MuxConnection.maxPendingPings` pings awaiting a PONG,
  the oldest failing beyond it), status payloads in CLOSE, keep-alive,
  graceful shutdown, the peer's GOAWAY status and byte counters for
  clients.
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
  host hint relays, routing by shard slot with a one-shot retry on `MOVED`
  (what the client sends meanwhile is held, its credit returned only once
  the new owner's channel takes it), an asynchronous `authorize` hook that may rewrite
  the address, and refusal of slot-less channels to sharded types unless
  `allowNoSlot` admits the type. The slot tables are read once the
  resolver has answered, so a proxy whose naming client has not synced
  yet neither lets a client-named instance past them nor skips the
  `LOCATE` budget.
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
- Protocol change, mux: per-channel credit flow control. `LIMITS` carries a
  third field, the initial window (`MuxLimits.initialWindow`; 12 bytes, a
  shorter payload or a zero window is a protocol error), which
  `MuxOptions.initialWindow` (64 KiB) announces; the new control message
  `CREDIT` (0x07, `MuxCredit`: `u48` channel id, `u32` bytes, exactly
  10 bytes) returns or grants credit. A DATA frame costs its length plus
  16 bytes of its channel's window; a peer sending beyond the window it was
  granted ends the connection with GOAWAY `PROTOCOL_ERROR`. This replaces
  the per-channel receive cap: `MuxOptions.maxChannelBufferBytes` and its
  close with `RESOURCE_EXHAUSTED` are gone, and the receive high-water mark
  stays as the backstop, buffers now counted at the flow-control cost.
  `MuxChannel.send` returns a future that waits for credit (`sendWindow`; a
  subframe costing more than half the initial window is refused,
  `maxSubframeLength`), and `sink.addStream` waits for each subframe; a
  CLOSE goes behind what still waits, and a close whose confirmation times
  out first drops it and ends `DEADLINE_EXCEEDED` instead of `OK`. Credit
  goes back once half the window is consumed: by default when the stream's
  listener takes a subframe, or, with `MuxChannel.manualCredit`, when the
  layer reading for the application calls `consumed` (what it holds
  meanwhile, `heldBytes`, is bounded by the window and left out of the
  mark); `MuxChannel.grant` raises a window at once. A channel opened
  before the peer's first frame holds its DATA until the peer's LIMITS
  arrives (`MuxOptions.awaitPeerLimits`, bounded by the keep-alive
  timeout), so that a peer announcing a small window is held to it from the
  first channel on. An output scheduler holds DATA while a transport
  implementing `OutputReadyTransport` (the stream binding,
  `WebSocketServerChannel`) is not ready (`MuxConnection.heldOutputBytes`),
  and writes control messages first, then ordinary channels in turn, then
  bulk channels (`MuxChannel.priority`, `MuxPriority.bulk`) with a turn
  after `MuxOptions.bulkZipper` (4) ordinary frames; `send` cuts a payload
  on a bulk channel into chunks of `MuxOptions.bulkChunkSize` (64 KiB).
  `MuxChannel.openAfter` opens a channel whose OPEN keeps its place among
  another channel's frames. Talk returns credit when the application takes
  a message (`messages` and `TalkStream.items` hand it over, an ordered
  answer is delivered), and at once for what it consumes itself (final
  responses, aborts, `EXTEND`, cancels, frames it drops). A `messages` or
  `items` subscription that is paused, or never made, now stalls its
  channel once the window is spent (responses on it included), instead of
  buffering without bound; listen, or cancel the subscription.
  `pipeChannels` (the proxy, the relay, the slot gate's forwarding) and
  `forwardMessage` pass credit through hop by hop: the credit of what they
  relay (for `forwardMessage`, of the message it forwards too, when the
  listener calls it) goes back once the frame forwarded for it went out on
  the other channel; `SlotChannel.send` returns a future too.
- Protocol change, Talk: bulk payloads. Flag `0x40` of the Talk header is
  `BULK`: the payload field is a 10-byte reference (`TalkBulkReference`:
  `u32` bulk number, `u48` length, `0xFFFFFFFFFFFF` unknown) to a bulk
  channel of the same connection whose open payload is the reserved type
  `_bulk` naming the parent channel and the number (`TalkBulkOpen`,
  `Services.bulk`). A message whose frame would exceed
  `MuxChannel.maxSubframeLength` (or `TalkOptions.bulkThreshold`) goes this
  way transparently; `send`, `request`, `startRequest` and `streamRequest`
  take `bulk:` (a byte stream, sent in chunks of
  `TalkOptions.bulkChunkSize`, 64 KiB, and paused by the bulk channel's
  credit) and `bulkLength:`, and `TalkMessage.replyBulk` and
  `replyItemBulk` answer with one. A received bulk payload is reassembled
  before its message is delivered (up to `TalkOptions.maxInlinePayload`,
  16 MiB; beyond, `RESOURCE_EXHAUSTED` to both sides), so `payload` reads
  it like an inline one; messages `TalkOptions.streamBulk` selects are
  delivered at once and read as a stream (`TalkMessage.bulk`,
  `payloadBytes`, `isBulk`, `bulkLength`). Messages keep their order either
  way. Receiving is bounded: what waits behind a listener (reassembled
  payloads, streamed ones not delivered yet) shares a budget of
  `maxInlinePayload` per channel; a bulk channel being read is granted its
  declared length as window, at most `TalkOptions.bulkWindow` (1 MiB); at
  most `TalkOptions.maxUnclaimedBulk` (16) bulk channels may wait for their
  messages, and as many messages for their bulk channels, at most
  `TalkOptions.bulkOpenTimeout` (10 s); a bulk channel on which nothing
  arrives for `TalkOptions.bulkIdleTimeout` (30 s) while this side waits is
  closed `DEADLINE_EXCEEDED`, its payload failing with it. A graceful close
  of a channel waits for the bulk payloads it sends or forwards, at most
  the close confirmation timeout, then cuts them with `DEADLINE_EXCEEDED`.
  The Switchboard routes `_bulk` channels to their parent's Talk layer
  before any policy (`TalkChannel.adoptBulk` for raw mux users);
  `pipeChannels`, `proxyHandler`, the relay and `forwardMessage` forward
  bulk payloads without reassembling them.
- Naming and sharding fixes: the `RESUME` of a rolled-back migration is
  sent again until the old owner answers it (the `ASSIGN` backoff
  intervals); after `NamingService.resumeAttempts` (5) failures in a row
  the slot is set free with its holder kept and placed elsewhere first. A
  migration interrupted by the service's `close` sets its slot back. The
  channel's request limit (`TalkOptions.maxOutgoingRequests`) no longer
  loses or stalls work in `NamingClient`: the slot state restored after a
  reconnect, and the `WATCH`, are sent after `reconnectDelay` when the
  channel refuses them, in order and once, and `claim`, `release` and
  `locate` calls past the limit wait for their turn instead of failing
  with `RESOURCE_EXHAUSTED`. `declareHolding` for a type the client
  registers no instance of is sent and refused by the naming service
  instead of never completing. `MeshNode.leave()` keeps at most 64
  `RELEASE`s and 64 hand-over migrations in flight.
- Security and resource limits: listener policies, with ready-made ones
  that refuse the reserved types, generic rejection reasons, frame limits checked before
  allocation, per-connection receive buffers, a budget for
  held OPEN payloads, a cap on unconfirmed CLOSEs, output high-water marks,
  a per-client limit on proxied channels, and host hint relaying only on
  request.
- Identity (stage A): signed credentials (`Credential`, scopes with
  `register`, `open`, `watch`, `claim`, `migrate`, `broker` and `admin`
  rights over name patterns), `CredentialIssuer` (HMAC-SHA256 bearer
  credentials, or Ed25519 with holder keys), `CredentialVerifier` (keys by
  id for rotation, a cache by credential bytes), `HolderKey`; connection
  identity with the `NONCE` and `IDENT` control messages
  (`MuxConnection.identify`, `peerIdentity`, `MuxOptions.identityVerifier`;
  a refused `IDENT` ends the connection with GOAWAY `UNAUTHENTICATED`, so
  an unidentified peer gets one credential check per connection; a
  malformed `IDENT` is a protocol error with or without a verifier);
  `Switchboard(credential:, holderKey:, verifier:, identifyOutgoing:,
  identifyFor:, identityTimeout:)`, which identifies on the connections it
  initiates before using them, `identifyOn`, `ChannelPolicies.scoped`,
  `requireIdentity` and `all`, channels held until their peer identifies,
  `IncomingChannel.peerIdentity`. New dependency: `cryptography` (its pure
  Dart Ed25519, the same on the VM and the web).
- Identity (stage B): `IDENT` names the receiver it is meant for, and the
  proof covers it with the field lengths, so a peer cannot relay a live
  handshake to a third node (`MuxConnection.localIdentity`,
  `MuxOptions.requireNamedIdent`, `PeerIdentity.receiver`,
  `Switchboard(expectedIdentityFor:)`, `dial(intent:, receiver:, record:)`,
  `identifyOn(receiver:)`); credentials are at most 637 bytes. The naming
  service enforces scopes per `_ns` channel, from the connection's identity
  or else a bearer credential in the open payload
  (`NamingService(verifier:, requireCredential:)`; `SLOTS` needs `claim` or
  `register` for the type, so that instances define their spaces again
  after a naming service restart), ends a channel whose
  credential expires, renews credentials (`RENEW`,
  `NamingService(issuer:, renewable:)`, `NamingClient.renew`, renewal at
  two thirds of the lifetime by `MeshNode` with
  `Switchboard.updateCredential`), and brokers connections to instances
  registered without endpoints (`CONNECT`: `NamingClient.connectTo` and
  `connectHandler`, `BrokeringResolver`, `Switchboard.broker` and
  `brokerEndpoint`, brokered records in `openChannel` and `PeerSet`,
  `MeshNode` dialling back). `NamingClient(watch: false)` and
  `MeshNode.join(watch: false)` for nodes that may only register.
- Relay (use case 5c): the reserved type `_relay` (`Services.relay`) for
  instances that listen nowhere reached by consumers that listen nowhere
  either. `RelayService` checks the consumer's identity and its `open`
  scope for the inner type, refuses malformed or reserved inner addresses
  and host hints, bounds the channels per consumer connection, brokers one
  pooled connection per instance through `CONNECT` for every consumer, and
  pipes with statuses relayed unchanged; `MeshNode.publishRelay` registers
  it with the node's identity as the record metadata. A node that cannot
  broker (`Switchboard.canBroker`) reaches such instances through
  `Switchboard(relay: RelayConfig(...))`: `openChannel`, `openTalk`, the
  slot opens and `PeerSet` (`Peer.viaRelay`) open `_relay` channels
  carrying the destination's open payload, through a relay resolved round
  robin with failover (`resolveRelays`) or explicit endpoints, named from
  its record when identifying. `ChannelPolicies.scoped` admits `_relay`
  like `_ns`. The proxy and the relay share their forwarding code.
- Tests: over 1200 tests, including the wiki test vectors (the codec tests also
  run on Node.js with `dart test -P node`) and integration tests over TCP
  and WebSocket.
- Documentation: README with quick start programs (`example/`), and the
  wiki page "Polyverse Switchboard Dart Reference Implementation".

- Fixed: native (`dart compile exe`) binaries of the naming service crashed with SIGSEGV on the first `WATCH` without a type filter, which every joining node sends: the Dart 3.13.5 AOT compiler hoisted a field load of the inlined `Name.==` above its null check. `Name.==` is no longer inlined and the handler compares a non-null filter. `tool/aot_smoke.sh` checks a native build.
- Review round (GPT-6 Astra reviewing and fixing six areas, each branch re-reviewed and extended by Claude Opus 5.5): about fifty confirmed defects fixed with regression tests. Among them: an integer overflow in the hardened WebSocket server's fragment size check that let a crafted continuation header bypass the message bound and hang the parser; closed channels and held OPEN payloads escaping the mux resource accounting; a peer echoing our NONCE being taken for ourselves; RENEW on a bearer-identified channel adopting a holder-key credential; naming sessions outliving an expired connection credential; a replacement IDENT now re-checked against standing subscriptions and registrations; `_relay` records bound to the registering identity; a throwing `expectedIdentityFor` failing the connection with INTERNAL instead of identifying unnamed; brokered connections not reused under an expired identity; dial-backs leaked when CONNECT failed; credentials crossing destinations during a reconnect; the slot gate serving queued work after revocation or a cancelled ASSIGN, old lifecycle cleanup erasing a newer assignment, forwarding work escaping the queue bounds, and a DRAIN that waited out its timeout always failing; Talk ordered answers lost at channel end, double finals under synchronous cancel, unhandled stream-reply cleanup errors, forwarded requests leaked when a synchronous reply could not be delivered, long deadlines overflowing JavaScript timers, and a throwing handler leaving its request running. `CredentialVerifier.cached`, `connect(record:)` and `NamingService.waitingRequestCount` added. Every Dart file header lists the models whose commits touched it.

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
