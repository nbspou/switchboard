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
- `Switchboard` node: TCP and WebSocket listeners, pooled outgoing
  connections, dispatch by `(type, instance)` with a default service and a
  catch-all, dispatch on initiated connections too, static, endpoint and
  naming resolvers, round robin and shard slot selection, a default
  application payload per node.
- Naming service: `NamingService` (`REGISTER`, `UNREGSTR`, `WATCH`,
  `LOOKUP`, heartbeat, assignment hold after a restart), `NamingClient`
  (re-registration on reconnect, mirrored table served while stale),
  `NamingResolver`, and `MeshNode` to join a node to a mesh.
- `ReconnectingClient` (core, web-capable) for frontend apps: backoff
  reconnect, a client state stream, persistent channels re-opened after
  every reconnect, server-pushed channels across reconnects.
- Proxying: `proxyHandler` and `pipeChannels` for frontend endpoints and
  host hint relays, routing by shard slot with a one-shot retry on `MOVED`,
  and an asynchronous `authorize` hook that may rewrite the address.
- Sharding: slot spaces per service type in the naming service (`SLOTS`,
  `HOLDING`, `CLAIM`, `RELEASE`, `LOCATE`, `MIGRATE`, `SLOTSPC` and `SLOT`
  table items), managed and static modes, lazy and shared-recovery flags,
  holder tracking for reboot, the allocator, and the `DRAIN`, `ASSIGN`,
  `FORWARD`, `RESUME` hand-over; on the node, slot-aware routing,
  `openChannelToSlot`, `SlotGate` and `SlotLifecycle`, and
  `MeshNode.publishSharded`; the `MOVED` status with the owner and epoch
  as fixed fields (nothing was processed), and `ABORTED` with the same
  fields for served channels; statuses relay byte for byte; use case
  integration tests
  (key-value store, Discord frontends, per-user workers, zone servers, chat
  rooms, job partitions).
- Security and resource limits: listener policies, with ready-made ones
  that refuse the reserved types, generic rejection reasons, frame limits checked before
  allocation, per-channel and per-connection receive buffers, a budget for
  held OPEN payloads, a cap on unconfirmed CLOSEs, output high-water marks,
  a per-client limit on proxied channels, and host hint relaying only on
  request.
- Tests: 667 tests, including the wiki test vectors (the codec tests also
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
