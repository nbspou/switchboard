# Polyverse Switchboard Dart reference implementation: design and API contract

> This is the design record used while building the package: the contract between the layers, kept for the reasoning behind them. It is not the user guide. For using the package, read the README and the wiki page "Polyverse Switchboard Dart Reference Implementation". Where this file and the code disagree, the code (and its doc comments) wins.

This file is the contract between the layers of the Dart package while it is
being built. The protocol itself is specified in the wiki
(`sway/wiki/switchboard/*.md`); when this file and the wiki disagree, the wiki
wins and this file is wrong.

## Package layout

```
lib/core.dart                  platform independent exports (no dart:io)
lib/switchboard.dart           everything, including dart:io transports and Switchboard
lib/src/status.dart            StatusCode, Status, SwitchboardException, ProtocolException   (done)
lib/src/status_closable.dart   StatusClosable (channels closable with a status; MuxChannel)
lib/src/name.dart              Name                                                           (done)
lib/src/bytes.dart             ByteReader, ByteWriter, hexBytes, hexString                    (done)
lib/src/monotonic.dart         monotonicNow, wallTimeOf: the clock of Talk deadlines (a Stopwatch; package:clock's zone clock under fake_async) (internal)
lib/src/transport/transport_capabilities.dart  FrameLimited, AbortableTransport, OutputBufferedTransport (optional transport capabilities)
lib/src/transport/memory_transport.dart     in-memory StreamChannel<Uint8List> pair
lib/src/transport/stream_framing.dart       stream binding wire format: StreamFraming, StreamFrameDecoder (no dart:io)
lib/src/transport/framed_byte_transport.dart  FramedByteTransport, ByteFraming: output queue, throttling, close and linger shared by the byte stream transports (internal, not exported)
lib/src/transport/stream_transport.dart     StreamTransport, StreamTransportChannel over byte streams; TCP helpers (dart:io)
lib/src/transport/web_socket_transport.dart wraps package:web_socket_channel (binary only)
lib/src/transport/web_socket_transport_io.dart  IOWebSocketTransport: server upgrade and connect on dart:io (exported from switchboard.dart only)
lib/src/transport/web_socket_server.dart    WebSocketServerTransport, WebSocketServerChannel: own RFC 6455 server side (dart:io, exported from switchboard.dart only)
lib/src/mux/mux_frame.dart     MuxFrame codec, MuxCommand, control message codecs, MuxLimits
lib/src/mux/mux_connection.dart MuxConnection, MuxOptions
lib/src/mux/mux_channel.dart   MuxChannel, MuxChannelState
lib/src/talk/talk_frame.dart   TalkFrame codec, TalkKind
lib/src/talk/talk_channel.dart TalkChannel, TalkOptions, TalkAbortException
lib/src/talk/talk_forward.dart forwardMessage (message chain proxying; part of talk_channel.dart)
lib/src/talk/talk_message.dart TalkMessage (incoming message with reply API)
lib/src/talk/talk_request.dart TalkRequest (handle for an outgoing single-response request)
lib/src/talk/talk_stream.dart  TalkStream (handle for an outgoing stream request)
lib/src/address/service_address.dart   ServiceAddress
lib/src/address/channel_address.dart   ChannelAddress (open payload codec)
lib/src/identity/credential.dart       Credential (codec), CredentialKind, Right, SignatureKind, Scope (pattern matching)
lib/src/identity/credential_issuer.dart  CredentialIssuer (HMAC-SHA256 with package:crypto, Ed25519); hmacSha256, checkHmacKey (internal)
lib/src/identity/credential_verifier.dart  CredentialVerifier (keys by id, LRU cache by credential bytes)
lib/src/identity/holder_key.dart       HolderKey (the holder's Ed25519 key pair)
lib/src/identity/peer_identity.dart    PeerIdentity (MuxConnection.peerIdentity)
lib/src/identity/ed25519.dart          ed25519Sign/Verify/PublicKey over package:cryptography's DartEd25519 + DartSha512, constantTimeEquals (internal)
lib/src/identity/secure_random.dart    secureRandomBytes: Random.secure on the VM, globalThis.crypto.getRandomValues on the web (internal, conditional import)
lib/src/client/reconnecting_client.dart  ReconnectingClient, ClientState, ClientPhase, TransportConnector (frontend client, core)
lib/src/client/backoff.dart              Backoff: the reconnect schedule shared by ReconnectingClient and PeerSet (internal, not exported)
lib/src/client/persistent_channel.dart   PersistentChannel, PersistentTalk (part of reconnecting_client.dart)
lib/src/naming/naming_protocol.dart    ServiceRecord, codecs for REGISTER/UNREGSTR/WATCH/UNWATCH/LOOKUP/UP/DOWN, CONNECT, and the sharding payloads, MovedStatus
lib/src/naming/naming_service.dart     NamingService (server side handler)
lib/src/naming/naming_service_slots.dart  part of naming_service.dart: slot tables, slot procedures, hand-over, allocator
lib/src/naming/naming_client.dart      NamingClient (register, subscription to the table, mirrored table)
lib/src/naming/naming_client_slots.dart   part of naming_client.dart: SlotHandler, AssignResult, instance side of sharding, slot mirror
lib/src/naming/slot_table.dart         SlotTable (read-only slot table view), SlotEvent
lib/src/naming/naming_client_io.dart   namingClientFor: a NamingClient connecting through a Switchboard (dart:io)
lib/src/naming/naming_resolver.dart    NamingResolver (resolves through a NamingClient's mirrored table)
lib/src/switchboard/resolver.dart      Resolver, SlotResolver, StaticResolver (with a configurable slot map), EndpointResolver
lib/src/switchboard/slot_key.dart      fnv1a32, slotForKey, slotForText: the reference key-to-slot function (core)
lib/src/switchboard/channel_policy.dart  ChannelPolicy, ChannelPolicies (listener and outgoing policies)
lib/src/switchboard/outgoing_policy.dart EndpointPolicy, EndpointCredential: the hook types of Switchboard's endpointPolicy and credentialFor (no dart:io; exported from switchboard.dart)
lib/src/switchboard/generic_status.dart  genericStatus: rejection statuses for peers (internal, not exported)
lib/src/switchboard/incoming_channel.dart  IncomingChannel, ChannelHandler (core)
lib/src/switchboard/switchboard.dart   Switchboard (dart:io)
lib/src/switchboard/memory_endpoints.dart  MemoryEndpoints: the isolate-wide registry of mem:// listeners behind Switchboard.listenMemory (no dart:io; internal, not exported)
lib/src/switchboard/proxy.dart         pipeChannels, proxyHandler
lib/src/switchboard/forwarding.dart    ForwardingBound, openForwarded: the per-connection bound and the outgoing channel (never to the node itself) shared by proxyHandler and RelayService (internal, not exported)
lib/src/switchboard/relay.dart         RelayService: the `_relay` service (builds on Switchboard; no dart:io of its own)
lib/src/switchboard/relay_config.dart  RelayConfig: how a node that cannot broker finds its relays (no dart:io; exported from switchboard.dart)
lib/src/switchboard/slot_channel.dart  SlotChannel: a channel to a slot's owner with the MOVED retry (no dart:io; exported from switchboard.dart)
lib/src/switchboard/slot_reopen.dart   reopenAtSlotOwner: the re-resolution after MOVED shared by openChannelToSlot and proxyHandler (internal, not exported)
lib/src/switchboard/slot_gate.dart     SlotGate, SlotLifecycle, SlotGates, SlotGateState: the instance side of sharding
lib/src/switchboard/mesh.dart          MeshNode: a Switchboard joined to a naming service (dart:io)
lib/src/switchboard/peer_set.dart      PeerSet, Peer, PeerState, PeerEvent, PeerEventType: a connection kept to every instance of a type (builds on Switchboard)
```

Rules:

* `dart:io` only in `stream_transport.dart`, `web_socket_transport_io.dart`, `web_socket_server.dart`, `switchboard.dart`, and the TCP/WebSocket connect helpers. `proxy.dart`, `relay.dart`, `mesh.dart`, `slot_gate.dart`, `slot_channel.dart`, `peer_set.dart` and `naming_client_io.dart` build on `Switchboard` and are exported from `switchboard.dart` only, as are `outgoing_policy.dart` and `relay_config.dart` (their hooks and settings only mean something to a `Switchboard`). Everything else must compile for the web.
* The wire codecs must be correct when compiled to JavaScript, where bitwise operations are 32-bit: use `ByteReader`/`ByteWriter` (or the same split arithmetic) for `u32` and `u48`. `dart test -P node` runs the codec tests on Node.js (see `dart_test.yaml`).
* All wire codecs are pure functions over `Uint8List` and are unit tested against the wiki test vectors.
* Logging through `package:logging`, logger names `Switchboard.Mux`, `Switchboard.Talk`, `Switchboard.Router`, `Switchboard.Naming`, `Switchboard.Transport`, `Switchboard.Client`, `Switchboard.Relay`.
* No `print`. No fixed ports in tests (bind to port 0). No multi-second sleeps in tests; timeouts under test are configured in tens of milliseconds through options.
* Every public member has a doc comment. `dart analyze` is clean with the repo `analysis_options.yaml`. `dart format` applied.
* File header comment block as in `status.dart`.

## Transports

A transport is a `StreamChannel<Uint8List>` whose stream yields one mux frame per event and whose sink takes one mux frame per `add`. Closing the sink closes the transport. The stream ends when the transport is closed by either side; errors on the stream mean the transport failed. After a stream error the sink stays writable until the listener has seen the error and the end of the stream, so the mux can still send GOAWAY.

Optional capabilities, discovered by the mux with type tests (`transport_capabilities.dart`, exported from `core.dart`):

```dart
abstract interface class FrameLimited { int get maxFrameSize; }   // incoming limit, 0 = none; the mux warns and announces it if below MuxOptions.maxFrameSize
abstract interface class AbortableTransport { void abort(); }      // destroy now; the mux calls it when close() exceeds keepAliveTimeout
abstract interface class OutputBufferedTransport {
  int get bufferedOutputBytes;   // written, not yet accepted by the connection
  int get acceptedOutputBytes;   // total accepted; grows while the peer reads (keep-alive counts it as life while throttled)
  bool get isInputThrottled;     // input paused because too much output waits
}
```

```dart
class MemoryTransport {
  /// Two connected transports. Frames added to one appear on the other.
  /// Optional [delay] and [maxFrameSize] for tests. Closing one side
  /// ends the other side's stream. With maxFrameSize, an oversized frame
  /// fails only the receiving side's stream; that side stays writable
  /// until it closes (or its listener saw the end), so GOAWAY reaches the
  /// sender. Both ends implement FrameLimited.
  static (StreamChannel<Uint8List>, StreamChannel<Uint8List>) pair({Duration? delay, int? maxFrameSize});
}

/// Wire format of the stream binding, no dart:io (stream_framing.dart).
class StreamFraming { defaultMaxFrameSize; version; preambleLength; lengthPrefixSize; magic; encodePreamble(); encodeFrame(); }
class StreamFrameDecoder { StreamFrameDecoder({int maxFrameSize}); void add(List<int> chunk, void Function(Uint8List) onFrame); }
  // wrong magic, zero length: ProtocolException; preamble version != 1: SwitchboardException(unsupported);
  // length > maxFrameSize: SwitchboardException(frameTooLarge), without reading the body

class StreamTransport {   // dart:io; re-exports stream_framing.dart; the static codec members delegate to StreamFraming
  /// Writes the preamble, frames outgoing frames with the u32 length prefix,
  /// parses incoming bytes into frames. Output is fed to [output] with
  /// addStream, so a sink that cannot keep up pauses the transport instead
  /// of buffering inside dart:io; bytes not accepted yet wait in the
  /// transport, and above [outputHighWaterMark] (default 16 MiB, 0 = never)
  /// the transport stops reading [input] until they drain to half. A close
  /// that cannot write its buffered output within [closeTimeout] (default
  /// 10 s) calls [abort].
  static StreamTransportChannel wrap(Stream<List<int>> input, StreamSink<List<int>> output,
      {int maxFrameSize, int outputHighWaterMark, Duration closeTimeout, void Function()? abort});
  static Future<StreamTransportChannel> connectTcp(dynamic host, int port, {int maxFrameSize, int outputHighWaterMark, Duration closeTimeout});
  static StreamTransportChannel fromSocket(Socket socket, {int maxFrameSize, int outputHighWaterMark, Duration closeTimeout});   // abort = socket.destroy; lingers on close
}

final class StreamTransportChannel implements StreamChannel<Uint8List>, FrameLimited, AbortableTransport, OutputBufferedTransport {
  int get maxFrameSize; int get outputHighWaterMark; Duration get closeTimeout;
  int get bufferedOutputBytes; int get acceptedOutputBytes; bool get isInputThrottled;
  void abort();
}

class WebSocketTransport {   // core, no dart:io
  static const int defaultMaxFrameSize = 1 MiB;
  /// Binary frames only; a text message is a protocol error; a message
  /// over maxFrameSize (0 = none) fails the stream with frameTooLarge.
  /// The check runs on assembled messages, so it protects the mux but not
  /// the WebSocket implementation's own memory. Implements FrameLimited.
  static StreamChannel<Uint8List> wrap(WebSocketChannel channel, {int maxFrameSize});
  static Future<StreamChannel<Uint8List>> connect(Uri uri, {int maxFrameSize, Duration? timeout});   // offers subprotocol 'switchboard'
  // timeout: SwitchboardException(unavailable), a late connection is closed at once.
  // Not OutputBufferedTransport: package:web_socket_channel gives no acceptance signal.
}

class IOWebSocketTransport {   // dart:io, exported from switchboard.dart only
  /// Selects 'switchboard' when offered, accepts clients offering none,
  /// refuses clients offering only others. Compression off by default: a
  /// compressed message can inflate far beyond its wire size. dart:io still
  /// assembles fragmented messages without a bound before the check: the
  /// simple alternative to WebSocketServerTransport, not for untrusted peers.
  static Future<StreamChannel<Uint8List>> upgrade(HttpRequest request, {int maxFrameSize, bool compression = false});
  static Future<StreamChannel<Uint8List>> connect(Uri uri, {int maxFrameSize, bool compression = false});
}

class WebSocketServerTransport {   // dart:io, exported from switchboard.dart only
  static const int defaultMaxFrameSize = 1 MiB;
  static const int maxMessageFragments = 4096;   // frames per message, first and continuations
  /// Own handshake (RFC 6455 4.2) and frame reader on the detached socket.
  /// Not an upgrade (GET, HTTP/1.1, Upgrade: websocket, Connection: Upgrade): 426 + Upgrade: websocket;
  /// version != 13: 426 + Sec-WebSocket-Version: 13; missing or malformed key, or only other
  /// subprotocols offered: 400 (each: response sent, future fails with WebSocketException).
  /// Selects 'switchboard' when offered; never negotiates extensions (no permessage-deflate).
  /// Reader: masking required, RSV bits, reserved opcodes, fragmented or > 125 byte control frames,
  /// stray continuations: ProtocolException + close 1002; text: ProtocolException + close 1003;
  /// the sum of a message's fragments is checked against maxFrameSize (0 = none) on each fragment
  /// header, before buffering it, and so is the fragment count against maxMessageFragments:
  /// SwitchboardException(frameTooLarge) + close 1009; fragments are buffered together in pieces
  /// (at least 64 KiB while more follow, at most 1 MiB), so a message costs about its size however
  /// it is fragmented; ping -> pong; client close echoed with its code, stream ends. Writer: unmasked
  /// frames; closing the sink sends close 1000. Output queue, throttling, closeTimeout and linger as
  /// for fromSocket. pingInterval: ping after a silent interval, abort after two more silent
  /// intervals; intervals before the stream is listened to, or while reading is paused, count as alive.
  static Future<WebSocketServerChannel> upgrade(HttpRequest request,
      {int maxFrameSize, Duration? pingInterval, int outputHighWaterMark, Duration closeTimeout});
  static Set<String> offeredProtocols(HttpRequest request);
}

final class WebSocketServerChannel implements StreamChannel<Uint8List>, FrameLimited, AbortableTransport, OutputBufferedTransport {
  String? get protocol; int get maxFrameSize; Duration? get pingInterval;
  int? get closeCode; String? get closeReason;   // the client's close frame
  int get bufferedOutputBytes; int get acceptedOutputBytes; bool get isInputThrottled;
  void abort();
}
```

**Linger.** `StreamTransport.fromSocket` and `WebSocketServerChannel` do not drop their input when they close: after their last bytes (and, for WebSocket, the close frame) they close their side of the connection and keep reading and discarding until the peer closes its side, for at most `closeTimeout`, then destroy the socket. Closing a TCP socket with unread input makes the kernel reset the connection, and the reset can destroy frames still in flight to the peer (the GOAWAY sent just before the close), which made a peer see `connectionLost` instead of `goingAway`. Input paused because the peer does not read our output stays paused, so a close that times out still resets such a peer. The stream ends and the sink's `done` completes as before; only the socket lives on. `StreamTransport.wrap` over arbitrary streams does not linger.

`IOWebSocketTransport` is a separate class rather than a static `WebSocketTransport.upgrade` because Dart has no static extension members and `WebSocketTransport` must stay free of `dart:io`. The transport limits (`maxFrameSize` of the stream and WebSocket transports) and `MuxOptions.maxFrameSize` should agree; with the defaults they are all 1 MiB.

## Mux

```dart
enum MuxCommand { data, open, close }

class MuxFrame {
  final MuxCommand command; final int channelId; final Uint8List payload;
  Uint8List encode();                 // short form whenever channelId < 0x10000; u48 ids correct on the web
  static MuxFrame decode(Uint8List);  // throws ProtocolException on reserved bits, command 3, truncation
}

enum MuxControlType { ping(1), pong(2), goAway(3), limits(4) }
class MuxLimits { final int maxFrameSize; final int maxChannels; encode/decode }
// MuxControlMessage.goAway(status) shortens the reason (UTF-8 safe) so the payload stays within 1024 bytes.

class MuxOptions {
  final int maxFrameSize;          // what we accept, announced with LIMITS; default 1 MiB (a smaller FrameLimited transport limit is announced instead)
  final int maxChannels;           // what we accept; default 65536 (0 = unlimited)
  final bool shortIdsOnly;         // embedded style peer: refuse long ids; default false
  final Duration? keepAliveInterval;   // PING after this much silence; default 10 s; null disables
  final Duration keepAliveTimeout;     // close if nothing arrives after PING; default 10 s; also bounds close(), then the transport is aborted
  final Duration goAwayGrace;          // how long goAway() waits for channels; default 10 s
  final bool announceLimits;           // send LIMITS on start; default true
  final int maxPendingRejections;      // ids awaiting the peer's CLOSE without a channel; default 1024 (0 = unlimited); beyond: GOAWAY resourceExhausted
  final int maxChannelBufferBytes;     // per channel receive buffer while unread or paused; default 4 MiB (0 = unlimited); beyond: CLOSE resourceExhausted
  final int receiveHighWaterMarkBytes; // all channel buffers; default 16 MiB (0 = never); above: stop reading the transport until half
  final Duration closeConfirmTimeout;  // MuxChannel.close() wait for the peer's CLOSE; default 30 s (Duration.zero = forever)
  final int maxOpenPayloadBytes;       // OPEN payloads held for the peer's open channels; default 16 MiB, at most half of receiveHighWaterMarkBytes (so 8 MiB with the defaults); 0 = no budget of its own; beyond: CLOSE resourceExhausted
  final CredentialVerifier? identityVerifier;   // checks the peer's IDENT; null: IDENT ignored (NONCE still answered)
  final Duration identityTimeout;      // identify()'s default bound; default 10 s; zero = none
  final bool requireNamedIdent;        // refuse an IDENT that names no receiver (GOAWAY UNAUTHENTICATED); default false; a naming service's host sets it
}

class MuxConnection {
  MuxConnection(StreamChannel<Uint8List> transport, {required bool isInitiator, MuxOptions options});
  bool get isInitiator;
  Stream<MuxChannel> get incoming;     // channels opened by the peer, single subscription, buffered until listened; cancelling closes undelivered ones with UNAVAILABLE
  MuxChannel open(Uint8List openPayload);   // throws SwitchboardException(resourceExhausted) if no id free or peer limit hit; (failedPrecondition) if closed or peer sent GOAWAY
  Future<Duration> ping([Uint8List? payload]);   // at most maxPendingPings (1024) await their PONG: one more fails the oldest with deadlineExceeded
  Future<void> goAway([Status status]);     // send GOAWAY, wait for open channels up to grace, then close()
  Future<void> close();                     // close transport now; all channels end with connectionLost
  Future<Status> get done;                  // completes when the transport is closed; status: goingAway if a GOAWAY was received, the GOAWAY status we sent if we killed it (protocolError, frameTooLarge, unsupported, resourceExhausted), connectionLost otherwise
  bool get isOpen;                          // transport open and no local close started
  bool get peerGoingAway;
  Future<Status> get peerGoAwayStatus;      // the peer's GOAWAY status as sent (application codes as unknown); never completes without one, never fails
  int get sentBytes; int get receivedBytes; // mux frames handed to / received from the transport, headers included
  MuxLimits? get peerLimits;
  int get openChannelCount;
  Iterable<MuxChannel> get channels;
  int get bufferedBytes;                    // bytes in all channel receive buffers, plus the OPEN payloads held for the peer's open channels
  int get openPayloadBytes;                 // OPEN payloads held for the peer's open channels
  bool get isReceivePaused;                 // transport reading paused by receiveHighWaterMarkBytes
  int get unconfirmedCloseCount;            // ids awaiting the peer's CLOSE without a channel
  Future<void> identify(Credential credential, {HolderKey? holderKey, Uint8List? intent, String? receiver, Duration? timeout});   // see "Identity"
  String? localIdentity;                    // this side's identity, which a peer's IDENT must name if it names anyone; a Switchboard sets it from its credential
  PeerIdentity? get peerIdentity;           // last valid IDENT; null before, without a verifier, and once its credential expired
  Future<PeerIdentity> get peerIdentified;  // first valid IDENT; never completes without one, never fails
  Future<void> get identityRequested;       // the peer's NONCE arrived before ours; never fails
  @internal Future<void> get identityChanged;   // next valid IDENT or the end (Switchboard's holding)
}

enum MuxChannelState { open, halfClosedLocal, closed }

class MuxChannel implements StreamChannel<Uint8List> {
  int get id; bool get isLocallyOpened; Uint8List get openPayload; MuxConnection get connection;
  MuxChannelState get state;
  bool get canSend;                         // state == open
  Stream<Uint8List> get stream;             // incoming DATA subframes; ends when the peer's CLOSE arrives or the connection drops
  StreamSink<Uint8List> get sink;           // add = DATA; close() = close(Status.ok)
  void send(Uint8List subframe);            // throws SwitchboardException(failedPrecondition) if !canSend
  Future<void> close([Status status = Status.ok]);  // send CLOSE; completes when mutually closed, connection lost, or closeConfirmTimeout
  Future<Status> get done;                  // end status: first non-OK status sent or received, else OK; connectionLost/goingAway if connection dropped
  int get bufferedBytes;                    // received, not yet delivered to the stream's listener
}
```

Behaviour notes:

* Receiving OPEN: create the channel, add to `incoming`. If `openChannelCount >= options.maxChannels`, if its payload would take the held OPEN payloads beyond the budget (`maxOpenPayloadBytes`, at most half of `receiveHighWaterMarkBytes`), after our GOAWAY, or once `incoming` was cancelled, reply CLOSE (`resourceExhausted`, `resourceExhausted`, `goingAway`, `unavailable`) instead; the channel never surfaces and only its id is kept until the peer confirms. A second OPEN on such an id before the confirmation is a protocol error, as is OPEN on any id that is open or half closed.
* Protocol errors: send GOAWAY `protocolError` with reason, close transport, `done` completes with `protocolError`. A stream binding preamble with another version gives GOAWAY `unsupported`; a frame over the transport limit gives GOAWAY `frameTooLarge`.
* Ids: allocate incrementally from 2 or 3, step 2, skipping reserved ids, ids in use and ids awaiting a CLOSE confirmation, wrapping within the short range (below 0x10000) first. The long range (from 0x10000 or 0x10001, wrapping at 0xFFFFFFFFFFFF) is used only while every short id of our parity is in use; with `shortIdsOnly` that is `resourceExhausted` instead. A long-lived connection to a short-id-only peer therefore keeps working however many channels come and go. `nextChannelIdForTesting` sets the short cursor for ids below 0x10000, else the long one.
* Keep-alive: timer restarted on any incoming frame; on expiry send PING; if nothing arrives within `keepAliveTimeout`, close with `connectionLost`. No probing while the mux paused reading (`receiveHighWaterMarkBytes`); while the transport throttles its input because of our output, the peer reading that output counts as hearing from it.
* Incoming frames for channel 0 are control messages; unknown types ignored; PING answered immediately, whatever its size up to the 1024-byte control limit.
* Statuses received in CLOSE or GOAWAY with application codes (256 and above, not allowed there) are reported as `unknown` with the original code in the reason, so they can be relayed.
* Reasons sent in CLOSE and GOAWAY are shortened on a UTF-8 boundary so the status payload is at most 1024 bytes and the frame fits the peer's announced frame limit; `done` reports the status as given. The cut is made in the encoded bytes, so fixed fields before a reason (`MOVED`) survive.
* `Status.decode` keeps the bytes after the code as received (`reason` is their lossy UTF-8 decoding) and `encode` writes them back unchanged, so a status relayed by `pipeChannels` or `forwardMessage` (the `MOVED` and `RELOCATED` fields) reaches the far side byte for byte. `Status` itself does not interpret fields; `MovedStatus` does.
* Channel streams and `incoming` are fed from queues the mux owns and only while the listener is active and not paused, so every buffered byte and channel is accounted for.
* NONCE and IDENT: see "Identity". While an IDENT is verified (asynchronous: Ed25519 is), the transport subscription is paused and frames the transport still delivers are queued; they are handled in order once the IDENT has taken effect, so policies see the identity on an OPEN sent right after it. Keep-alive counts that pause as local.

## Resource limits

Text for the integrator, suitable for the "Switchboard Mux" wiki page:

> **Resource limits (reference implementation).** The protocol has no flow control of its own, so an implementation bounds what a peer can make it hold. The Dart reference implementation does the following; other implementations SHOULD do something equivalent.
>
> * **Per-channel receive buffer.** Data received on a channel that the application is not reading (no listener yet, or paused) is buffered up to a cap (default 4 MiB, each subframe counted as its length plus a small overhead so floods of empty subframes count too). Beyond it the channel is closed with CLOSE `RESOURCE_EXHAUSTED` and its buffer dropped. This is a channel error, not a connection error; DATA still in flight is dropped until the peer confirms.
> * **Connection receive high-water mark.** When the buffers of all channels together exceed a mark (default 16 MiB), the implementation stops reading the transport, which pushes back on the peer through TCP (or the WebSocket's) flow control, and resumes at half the mark. Keep-alive does not probe while reading is paused, since the silence is local.
> * **Held OPEN payloads.** A channel keeps its OPEN payload for its whole life, so the payloads of the channels a peer opened count toward the connection's buffered bytes until each channel is closed, and their total is capped (default 16 MiB, and never more than half of the receive high-water mark, so that held payloads alone cannot keep the reading paused: the CLOSE frames that release them must still be read). An OPEN beyond the cap receives CLOSE `RESOURCE_EXHAUSTED`.
> * **Rejected OPENs.** A rejected OPEN (over the channel cap, after GOAWAY, or when no longer accepting channels) costs only its id until the peer's confirming CLOSE arrives; no channel state or open payload is kept. If more than a cap of such ids (default 1024) are unconfirmed, the connection ends with GOAWAY `RESOURCE_EXHAUSTED`. A second OPEN on a rejected id before its confirmation is a protocol error.
> * **Reason truncation.** Reasons in CLOSE and GOAWAY are shortened at a UTF-8 character boundary so that the status payload is at most 1024 bytes and the frame fits the limit the peer announced with LIMITS (GOAWAY must anyway, as a control payload over 1024 bytes is a protocol error).
> * **Close confirmation timeout.** If the peer does not confirm a CLOSE within a timeout (default 30 s), the channel is reported closed locally with its first status. Nothing is sent; the id stays reserved until the peer's CLOSE arrives after all or the connection ends, because the peer may still consider the channel open and its late frames must not land on a new channel with the same id. Such ids count toward the rejected-OPEN cap.
> * **WebSocket messages.** The server side WebSocket transport checks the size of a message, all its fragments counted, on each fragment's header, before buffering the fragment, so a message of many fragments that are each within the limit is refused as early as a single oversized frame (close 1009, GOAWAY `FRAME_TOO_LARGE`). Fragments share buffers of at least 64 KiB, so a message costs about its size however finely it is cut, and a message in more than 4096 frames is refused the same way. It never negotiates permessage-deflate.
> * **Output.** A transport queues output the connection has not accepted (a peer that does not read). Above a high-water mark (default 16 MiB) it stops reading input, so a peer that sends PINGs without reading cannot make it produce unbounded PONGs; reading resumes once half has drained. While throttled this way, the peer reading our output counts as liveness for keep-alive. A close that cannot drain within the keep-alive timeout destroys the connection.

## Talk

```dart
enum TalkKind { message, streamItem, abort, extend }

class TalkFrame {
  final TalkKind kind; final Name? procedure; final int requestId; final int responseId; final bool stream; final Uint8List payload;
  Status get status;                    // abort frames only; an empty payload is UNKNOWN
  ({Duration? deadline, Duration? renew}) get extension;   // EXTEND frames only; a 0 field (unchanged) and an empty payload read as null
  static Uint8List extendPayload({Duration? deadline, Duration? renew});   // u32 ms each, rounded up, at least 1, capped at u32; empty when both null
  Uint8List encode();
  static TalkFrame decode(Uint8List);   // throws ProtocolException for every negative vector in the wiki
}

class TalkOptions {
  final Duration requestTimeout;       // requester side, default 15 s
  final Duration replyTimeout;         // responder side, default 10 s
  final int maxIncomingRequests;       // default 1024; beyond: ABORT resourceExhausted
  final int maxOutgoingRequests;       // default 1024; beyond: throws resourceExhausted locally
  final Duration minExtension;         // requester: declared values raised to it, default 1 s (zero: no floor)
  final Duration maxExtension;         // requester: declared values lowered to it, default 1 h (zero: no clamp)
  final Duration extendBuffer;         // responder: added on the wire by extend(), not to its own timeout, default 5 s
}

abstract interface class StatusClosable {   // lib/src/status_closable.dart; implemented by MuxChannel
  Future<void> close([Status status]); Future<Status> get done;
}

class TalkAbortException extends SwitchboardException {   // the peer sent ABORT
  final bool isChannelAbort;           // channel abort rather than an abort response
}

class TalkChannel {
  TalkChannel(StreamChannel<Uint8List> channel, {TalkOptions? options});   // works over MuxChannel or any StreamChannel
  StreamChannel<Uint8List> get raw;
  Stream<TalkMessage> get messages;    // incoming plain messages and requests (not responses); a channel abort from the peer is delivered as an error event (TalkAbortException) and then the stream ends
  // Every method taking a String procedure also takes {Name? name}, sent instead when given (lossless, for generated stubs).
  void send(String procedure, Uint8List payload, {Name? name});                 // plain message
  Future<TalkMessage> request(String procedure, Uint8List payload, {Duration? timeout, Name? name, bool ordered = false});   // = startRequest(...).response
  TalkRequest startRequest(String procedure, Uint8List payload, {Duration? timeout, void Function(Duration? deadline, Duration? renew)? onExtend, Name? name, bool ordered = false});   // ordered: the answer is delivered in wire order with messages (below)
  TalkStream streamRequest(String procedure, Uint8List payload, {Duration? timeout, void Function(Duration? deadline, Duration? renew)? onExtend, Name? name});
  void abort(Status status);           // channel abort, then close; ArgumentError for OK
  Future<void> close([Status status = Status.ok]);
  Future<Status> get done;
  bool get isOpen;
  int get outgoingRequestCount; int get incomingRequestCount;
}

class TalkRequest {                    // handle for a request with a single final response
  int get requestId;
  Future<TalkMessage> get response;    // never reports an unhandled error
  DateTime? get deadline;              // when the requester timeout expires (wall clock, for observation); null: none or ended
  void cancel([Status status]);
}

class TalkStream {
  int get requestId;
  DateTime? get deadline;              // as TalkRequest.deadline
  Stream<TalkMessage> get items;       // STREAM_ITEMs; errors on abort/timeout/cancel; cancelling the subscription cancels the request
  Future<TalkMessage> get done;        // the final response (may carry payload and may itself be a request)
  void cancel([Status status]);        // sends cancel; items ends with cancelled error
}

class TalkMessage {
  TalkChannel get channel; TalkFrame get frame; TalkKind get kind;
  Name get procedure; String get procedureName;   // procedureName is lossy for non-UTF-8 names
  Uint8List get payload;
  int get requestId;                   // 0 if the peer expects no reply
  int get responseId;                  // 0 if not a response
  bool get expectsReply;               // requestId != 0
  bool get expectsStream;              // STREAM flag
  bool get isCancelled;                // peer cancelled, responder timeout expired, channel closed, or id reused
  Future<void> get onCancel;           // completes when cancelled (never for non-requests)
  bool get canReply;

  // Reply API; all throw SwitchboardException(failedPrecondition) if !expectsReply or already finally replied.
  // Each one taking {String? procedure} also takes {Name? name}, sent instead when given.
  void reply(Uint8List payload, {String? procedure});
  Future<TalkMessage> replyRequest(Uint8List payload, {String? procedure, Duration? timeout});   // chained; = startReplyRequest(...).response
  TalkRequest startReplyRequest(Uint8List payload, {String? procedure, Duration? timeout, void Function(Duration? deadline, Duration? renew)? onExtend});
  TalkStream replyStreamRequest(Uint8List payload, {String? procedure, Duration? timeout, void Function(Duration? deadline, Duration? renew)? onExtend});
  void replyItem(Uint8List payload, {String? procedure});       // throws if !expectsStream
  Future<TalkMessage> replyItemRequest(Uint8List payload, {String? procedure, Duration? timeout});   // item that expects a reply
  TalkRequest startReplyItemRequest(Uint8List payload, {String? procedure, Duration? timeout, void Function(Duration? deadline, Duration? renew)? onExtend});
  TalkStream replyItemStreamRequest(Uint8List payload, {String? procedure, Duration? timeout, void Function(Duration? deadline, Duration? renew)? onExtend});   // item that is a stream request
  Future<void> replyStream(Stream<Uint8List> items, {Uint8List? trailer, String? procedure, Name? name});
    // replyItem per item, then reply(trailer ?? empty); a stream error: replyAbort(its status if SwitchboardException, else INTERNAL);
    // onCancel cancels the subscription; never fails; throws synchronously like replyItem
  void replyAbort(Status status);      // ArgumentError for OK
  void extend({Duration? deadline, Duration? renew, Duration? buffer});   // neither: empty EXTEND; values + (buffer ?? extendBuffer) on the wire
  void setReplyTimeout(Duration? timeout);   // per-request responder timeout: null = channel default, zero = none (declarations then set no local timer); back to the default regime
}

/// Message chain proxying (wiki "Switchboard Proxying"). Completes when the exchange,
/// including requests forwarded on its behalf, has ended; never fails.
Future<void> forwardMessage(TalkMessage incoming, TalkChannel target);
```

Behaviour notes:

* Responses (including chained ones and stream items) are routed to the requester's `Future`/`TalkRequest`/`TalkStream`, never to `messages`.
* Ordered answers (`ordered: true`): `messages` is an asynchronous stream that delivers one event per microtask, while an answer completes a future, so without the option an answer that arrived in the same batch as messages ahead of it (the mux drains a channel's buffered subframes in one go) is seen first. With it, the answer (final response or abort response) goes through `messages` as a marker the listener never sees: the future completes when the marker reaches the listener, so after every message that arrived before it, and the code waiting on it runs before the next message is delivered (the future's microtask is scheduled during the marker's delivery, the next delivery after it). At once when `messages` has no listener yet or its subscription was cancelled (markers it held are then delivered at once); a paused subscription holds the answer, so an `await for` body over `messages` must not wait for an ordered request. Local failures (timeout, cancel, channel end) are not ordered. Used by the naming client for `WATCH`, `REGISTER` and `UNREGSTR`, whose answers the naming service sends after the events they mark.
* A response for an unknown response id is ignored unless it has `HAS_REQUEST`; then reply ABORT `notFound`.
* Unknown procedure is the application's concern: the application calls `replyAbort(Status.of(StatusCode.unimplemented))`. The channel itself does not know the procedure table.
* Timeouts (wiki "Timeouts"): one timer per request on each side, computed from instants of a monotonic clock (`lib/src/monotonic.dart`: a process `Stopwatch`, or `package:clock`'s zone clock when a test installs one, as `fake_async` does). Default regime: a gap (`requestTimeout`, `replyTimeout` or the per-request values) restarted by every reply that does not end the request (stream item, EXTEND). After a non-empty EXTEND: the later of the declared deadline (from the EXTEND) and the last reply plus the declared renewal; a 0 field keeps the earlier value of that field, a later EXTEND replaces both and may shorten them, and the gap no longer applies; an empty EXTEND restarts the gap as one more term of the max, keeping the declaration. A non-empty EXTEND with both fields 0 counts as a plain reply. A timeout of zero disables everything on that side, declarations included.
* Requester: each received value is raised to `minExtension` and lowered to `maxExtension`; on expiry fail locally with `deadlineExceeded`, send cancel. `onExtend` is called synchronously for every EXTEND with the values as received (before floor and clamp), null for 0, both null for an empty EXTEND. `TalkRequest.deadline` and `TalkStream.deadline` show the expiry.
* Responder: if the application has not replied by the expiry, send ABORT `deadlineExceeded`, mark replied and cancelled. `extend(deadline:, renew:)` sets its own timer from the raw values (from the moment of sending) and puts each value plus `buffer ?? extendBuffer` on the wire, so the responder gives up first; a value whose wire form would pass the `u32` field (about 49.7 days, buffer included) is lowered on both sides to the field maximum less the buffer, so the two sides stay a buffer apart; `extend()` with neither sends the empty EXTEND and restarts the gap. `replyItem()` restarts the gap or renews by the declared renewal. `setReplyTimeout` returns to the default regime with the new gap. Nothing in the library sends EXTEND from a timer.
* Failures carry a `TalkAbortException` when the peer sent ABORT (abort response or channel abort), a plain `SwitchboardException` for local causes (own timeout, own cancel, channel lost or closed, protocol error, local limit). An empty or OK abort status reads as `unknown`.
* Error events on `messages` and `TalkStream.items` without an `onError` handler are logged at FINE, never reported as unhandled; futures from `request`, `replyRequest`, `replyItemRequest` and `TalkRequest.response` are pre-ignored.
* Peer cancel: the channel sends ABORT `cancelled` at once, the request is finished (later reply calls throw `failedPrecondition`), then `isCancelled`/`onCancel` fire. A cancel that a synchronous transport delivers while a reply to the request is still being sent waits until that send returns, then is handled as if it had arrived just after: ignored once the final reply is out (the request is answered), so a request never gets two finals; answered as usual after a stream item, an EXTEND, or a final reply whose send failed (which otherwise leaves the request answerable).
* Our cancel: the id stays reserved until the peer's final arrives or the requester timeout expires (the channel default if the request has none). Cancelling the `items` subscription of an outstanding `TalkStream` cancels the request.
* Requests buffered in `messages` and never delivered when its subscription is cancelled are answered ABORT `unimplemented`; item requests buffered in `items` are answered ABORT `cancelled`.
* Outgoing requests are registered (and their timer armed) before the frame is sent, and rolled back if the send throws, so a synchronous transport cannot lose a synchronous response.
* `connectionLost` is never sent: aborts, cancels and the close of a `StatusClosable` raw channel carry `unavailable` instead.
* Any ProtocolException while decoding or on kind rule violation: close the channel with CLOSE `protocolError` (via `raw.sink` if it is a MuxChannel, else just close) and fail outstanding requests with `protocolError`.
* When `raw.stream` ends: fail outstanding requests with `connectionLost` (or the MuxChannel's done status if available), close `messages`. A `close()` racing the end waits for that status.
* Chaining: a reply method on a `TalkMessage` that is a stream item or a final response (received through `TalkStream`/`request`) works the same way, since those carry a requestId when the peer asked for a reply.
* Forwarding: `forwardMessage` sends a plain message as a plain message and a request as a new request on `target` (same procedure, payload, STREAM flag), then relays items, EXTEND, the final, and aborts back. Items or finals that are themselves requests are forwarded the other way and their answers relayed back, recursively. A remote abort passes through with its status; any local failure of the forwarded request (including a channel abort) is answered `unavailable`. A cancel of the incoming request, or loss of its channel, cancels the forwarded one. Procedure names pass through as `Name`s (lossless); EXTEND payloads pass through byte for byte (the far responder's buffer covers the hops, no buffer is added); the proxy disables its responder timeout for forwarded requests and sets no requester timeout, so the real peers' timeouts apply end to end.

## Addressing

```dart
class ServiceAddress {
  ServiceAddress(this.type, [this.instance = 0]);   // RangeError outside u48
  final Name type; final int instance;   // instance u48, 0 = any
  bool get isAny;
  String toString();                     // 'npc/1a2b', 'npc' when any
  static ServiceAddress parse(String);
  ==, hashCode
}

class ChannelAddress {
  ChannelAddress({this.type, this.instance = 0, this.shard, this.host, Uint8List? payload});   // RangeError for instance or shard out of range, ArgumentError for a host over 255 bytes
  final Name? type; final int instance; final int? shard; final String? host; final Uint8List payload;
  ServiceAddress? get address;          // null when type is null
  Uint8List encode();
  static ChannelAddress decode(Uint8List openPayload);   // empty payload => default; throws ProtocolException on reserved bits or truncation
  ChannelAddress copyWith({...});
}
```

## Reconnecting client

A frontend (Flutter on the web or mobile) keeps one connection to its endpoint and needs its long-lived channels back after every reconnect. `ReconnectingClient` (core, no `dart:io`) does that over any transport; it does no resolution (the endpoint's proxy does, see the wiki "Endpoint" resolver).

```dart
typedef TransportConnector = Future<StreamChannel<Uint8List>> Function();   // e.g. () => WebSocketTransport.connect(uri)
enum ClientPhase { disconnected, connecting, connected }
class ClientState { ClientPhase phase; int attempt; Status? lastStatus; DateTime? since; DateTime? nextAttemptAt; Duration? get retryIn; bool get isConnected; }

class ReconnectingClient {
  ReconnectingClient(TransportConnector connect, {MuxOptions? muxOptions, TalkOptions? talkOptions,
      Duration initialBackoff = 500 ms, Duration maxBackoff = 30 s, double backoffFactor = 2, double jitter = 0.2,
      Duration connectTimeout = 10 s, Uint8List? defaultPayload, bool autoStart = true, Random? random});
  Uint8List defaultPayload;                        // mutable: re-opened channels carry the current value
  Stream<ClientState> get states;              // broadcast, replays the current state to each listener
  ClientState get state; DateTime? get nextAttemptAt; MuxConnection? get connection; Future<MuxConnection> get connected;
  bool get isRunning; bool get isClosed;
  void start(); void stop(); void reconnectNow({bool force = false}); Future<void> close();
  Future<MuxChannel> openChannel(ChannelAddress address, {Duration openTimeout = 30 s});
  Future<TalkChannel> openTalk(ChannelAddress address, {TalkOptions? options, Duration openTimeout = 30 s});
  PersistentChannel openPersistent(ChannelAddress address, FutureOr<void> Function(MuxChannel) onOpen, {void Function(Status)? onClosed});
  PersistentTalk openPersistentTalk(ChannelAddress address, FutureOr<void> Function(TalkChannel) onOpen, {TalkOptions? options, void Function(Status)? onClosed});
  Stream<IncomingChannel> get incoming;            // channels the endpoint pushes, across reconnects
}
class PersistentChannel { ChannelAddress address; MuxChannel? current; Stream<MuxChannel> opened; bool isClosed; Future<Status> done; Future<void> close(); }
class PersistentTalk    { ChannelAddress address; TalkChannel? current; Stream<TalkChannel> opened; bool isClosed; Future<Status> done; Future<void> close(); }
```

Behaviour notes:

* Backoff: first attempt immediate; after `n` consecutive failures the delay is `min(initial * factor^n, max)` times a uniform factor in `[1 - jitter, 1 + jitter]` (a delay may exceed `max` by the jitter); the schedule is `Backoff` in `lib/src/client/backoff.dart`, shared with `PeerSet`. A connection that ends is a failure unless it lived longer than `maxBackoff`, which resets the sequence. `start()` resets it too. Connect timeout and connector errors report `UNAVAILABLE` (a `SwitchboardException` from the connector keeps its own status).
* On connect: state `connected`, `connected` completes, every persistent channel is opened (all at once, in creation order; `onOpen` exceptions and failed futures are logged), then waiting `openChannel` calls proceed. Peer OPENs go to `incoming` as `IncomingChannel`; a malformed address is closed with `PROTOCOL_ERROR`, and after the listener cancels, OPENs are closed with `UNAVAILABLE`.
* On loss (any status): state `disconnected` with the status first, then each persistent channel's `onClosed` with its channel's end status, then the backoff. Nothing is opened on a connection that received GOAWAY; `openChannel` waits for the next one. A peer GOAWAY `GOING_AWAY` is not waited out: the client closes the persistent channels on that connection with `GOING_AWAY`, leaves it to the application's own channels (the mux closes it once idle), and connects again at once, state `connecting` with the GOAWAY status (the backoff applies only if that attempt fails, or if the connection was itself made after a GOAWAY and did not last `maxBackoff`), so persistent channels and waiting opens move to the new connection; a GOAWAY with an error status is left to end as a loss.
* Persistent channels: every `onOpen` is followed by exactly one `onClosed`. A channel that ends while the connection stays up (closed by the peer, or by the application through `current`) is opened again after a backoff kept per persistent channel (same schedule, reset by a channel that lived longer than `maxBackoff`), except after `PERMISSION_DENIED`, `UNAUTHENTICATED`, `UNIMPLEMENTED` or `NOT_FOUND`: the persistent channel then ends for good (`done` completes with that status) and the application decides. A refused OPEN: `FAILED_PRECONDITION` (GOAWAY) waits for the next connection, `RESOURCE_EXHAUSTED` backs off, anything else ends it. `onOpen` is never called synchronously from `openPersistent`.
* `stop()`: abandons an attempt in progress (a late transport is closed), closes the persistent channels with `GOING_AWAY` (re-opened after `start()`), sends GOAWAY; state `disconnected` with `CANCELLED`. `close()` also ends the persistent channels for good, fails waiting opens and `connected` with `CANCELLED`, ends `states` and `incoming`, and completes when every connection is gone (application channels get the GOAWAY grace); no client timer remains. Neither throws.
* `reconnectNow({force})`, for app resume or a connectivity change: while waiting for a retry it attempts at once (the backoff sequence carries on), while an attempt is in progress, when stopped or after `close()` it does nothing, and while connected it does nothing unless `force`, which leaves the connection as a peer GOAWAY `GOING_AWAY` does (state `connecting` with `GOING_AWAY`, persistent channels moved, GOAWAY sent on the old connection); the `disconnected` state emitted with a scheduled retry carries `nextAttemptAt` (null in every other state), and `retryIn` is the time left by the wall clock, clamped at zero.
* Lifetimes are measured with timers rather than `Stopwatch`, so fake_async drives them.

## Naming protocol codecs

```dart
const int maxMetadataLength = 4096;
class ServiceRecord { ServiceRecord(ServiceAddress address, {List<Uri> endpoints = const [], Uint8List? metadata});
  final ServiceAddress address; final List<Uri> endpoints; final Uint8List metadata; encode(); decode();   // == compares metadata bytes too
  static void checkEndpoint(Uri endpoint); }                          // ArgumentError unless it has a scheme, fits 255 bytes, and reparses to an equal Uri
class RegisterRequest { Name type; int requestedInstance; List<Uri> endpoints; Uint8List metadata; encode/decode }   // record layout
class RegisterResponse { int instance; encode/decode }
class UnregisterRequest { Name type; int instance; encode/decode }   // same layout as DownEvent
class WatchRequest { Name? type; encode/decode }                      // WATCH and UNWATCH (and LOOKUP); empty payload or all-zero name = all
class ServiceEvent { final bool up; final ServiceRecord record; }    // UP carries full record, DOWN only address
Procedure names: Procedures.register ('REGISTER'), unregister ('UNREGSTR'), watch ('WATCH'), unwatch ('UNWATCH'), lookup ('LOOKUP'), up ('UP'), down ('DOWN'), renew ('RENEW'), connect ('CONNECT'). Service type: Services.naming (Name('_ns')).

// Identity (wiki "Identity and Credentials"); RENEW carries no codec: an empty payload or the credential's bytes, answered with the renewed credential's bytes
const int maxConnectIntentLength = 64;
class ConnectRequest { ConnectRequest(Name type, int instance, Uri endpoint, {Uint8List? intent}); encode/decode }   // consumer -> NS: name type, u48 instance, len8 endpoint, len8 intent
class ConnectResponse { const ConnectResponse(String identity); encode/decode }   // NS -> consumer: len8 identity (UTF-8) of the instance's registration channel
class DialBackRequest { DialBackRequest(String requester, Uri endpoint, {Uint8List? intent}); encode/decode }   // NS -> instance: len8 requester identity, len8 endpoint, len8 intent

// Sharding (wiki "Switchboard Sharding"); every class has encode() and static decode(Uint8List)
Procedures.slots ('SLOTS'), holding ('HOLDING'), claim ('CLAIM'), release ('RELEASE'), locate ('LOCATE'), migrate ('MIGRATE'), phase ('PHASE'),
  assign ('ASSIGN'), drain ('DRAIN'), forward ('FORWARD'), resume ('RESUME'), slotSpace ('SLOTSPC'), slot ('SLOT')
const int maxU32;
enum SlotMode { managed(0), static(1) }  enum SlotState { free(0), owned(1), migrating(2) }
enum MigrationPhase { draining(1), assigning(2), forwarding(3), done(4), rolledBack(5) }
class SlotSpace { Name type; int count; SlotMode mode; bool lazy; bool shared; int get flags; }   // SLOTSPC item; unknown flag bits ignored
class SlotsRequest { SlotSpace space; int capacity; }                 // SLOTSPC layout + u32 capacity (0 = takes no slots)
class HoldingRequest { Name type; List<int> slots; }  class HoldingResponse { List<int> discard; }
class ClaimRequest { Name type; int slot; bool holding; int epoch; }   // u32 epoch after the flags: see "Deviations"
class ClaimResponse { int epoch; }  class ReleaseRequest { Name type; int slot; bool keepStorage; }
class LocateRequest { Name type; int slot; }  class LocateResponse { SlotState state; int owner; int epoch; }
class MigrateRequest { Name type; int slot; int to; }  class PhaseItem { MigrationPhase phase; }
class AssignRequest { Name type; int slot; int epoch; int holder; bool shared; }  class AssignResponse { bool notHolding; }   // empty = holding
class DrainRequest / ForwardRequest { Name type; int slot; int epoch; int to; }  class ResumeRequest { Name type; int slot; int epoch; }
class SlotEntry { SlotState state; int owner /* from while migrating */; int to; int holder; int epoch; bool isFree; bool isEmpty; static unassigned; .free/.owned/.migrating }
class SlotItem { Name type; int slot; SlotEntry entry; }               // SLOT item
class MovedStatus { MovedStatus({int owner = 0, int epoch = 0, String reason = ''}); static const unknown; static const fieldsLength = 10;
  int owner; int epoch; String reason; bool hasOwner; ServiceAddress? ownerOf(Name type);
  Uint8List encode({bool relocated = false}); Status toStatus({bool relocated = false});   // u16 MOVED 37 (or RELOCATED 38), u48 owner, u32 epoch, reason
  static bool carriesFields(Status);                                    // MOVED or RELOCATED
  static MovedStatus parse(Uint8List statusPayload); static MovedStatus fromStatus(Status); }   // never throw; other codes (ABORTED too) or short = unknown
```

Record metadata (wiki "Records"): `u16` length and the bytes after the endpoints, in records, `UP` items and `REGISTER`. A payload that ends right after its endpoints (the layout before the field) decodes with empty metadata; a partial length, a length over `maxMetadataLength` or missing bytes is a `ProtocolException`; encoders throw `ArgumentError` over the limit. Decoded metadata is a copy, not a view of the message.

Sharding decoders throw `ProtocolException` on truncation, an unknown mode, state or phase, and a slot list longer than the payload; trailing bytes are ignored. Encoders throw `RangeError` for values outside `u32`/`u48`. Vectors: `doc/sharding-vectors.md`, `test/vectors/sharding_vectors_test.dart`.

## Switchboard (dart:io)

```dart
typedef ChannelHandler = FutureOr<void> Function(IncomingChannel channel);   // a throw or a failed future closes the channel with INTERNAL

/// Connection policy (channel_policy.dart, core): a listener's applies to every connection it
/// accepts, an outgoing one (see Switchboard) to a connection the node initiates. Evaluated for
/// every channel the peer opens on the connection, after the header is parsed and before any
/// handler (local service, default service, catch-all). Refused: CLOSE PERMISSION_DENIED
/// 'permission denied'; throwing a SwitchboardException: its code (not OK or CONNECTION_LOST),
/// generic reason; any other throw: PERMISSION_DENIED (logged). UNAUTHENTICATED while the peer
/// has no identity: the channel is held (see "Identity").
typedef ChannelPolicy = bool Function(ChannelAddress address, MuxConnection connection);
abstract final class ChannelPolicies {
  static bool allowAll(ChannelAddress, MuxConnection);
  static bool denyAll(ChannelAddress, MuxConnection);                // for connections to peers that may not open channels back
  static bool denyReserved(ChannelAddress, MuxConnection);           // refuses `_` types, allows the rest and untyped
  static ChannelPolicy allowTypes(Set<Name> types, {bool untyped = false});   // only these types (a listed reserved type is allowed); a new closure per call: reuse one for connect(policy:)
  static ChannelPolicy scoped({bool requireIdentity = true});        // open scope for the type (untyped = empty name), _ns and _relay for any identified peer; unidentified: UNAUTHENTICATED (or pass); fixed functions
  static ChannelPolicy requireIdentity();                            // identified peers only; a fixed function
  static ChannelPolicy all(List<ChannelPolicy> policies);            // in order, first refusal wins; a new closure
}

class IncomingChannel {
  MuxChannel get channel; ChannelAddress get address; MuxConnection get connection;
  PeerIdentity? get peerIdentity;                 // connection.peerIdentity
  TalkChannel talk({TalkOptions? options});       // wrap once; cached
  Future<void> reject(Status status);
}

abstract interface class Resolver {
  Future<List<ServiceRecord>> resolve(Name type);  // all known live instances of type
  Stream<ServiceEvent> get events;
  Future<void> get ready;                          // completes once the table has been usable at least once (immediately for static); a later loss does not reset it
  Future<void> close();
}
/// A resolver that knows slot tables (wiki "Sharding", "Routing").
abstract interface class SlotResolver implements Resolver {
  SlotTable? slotTable(Name type); SlotEntry? slotOwner(Name type, int slot); Set<int> slotOwners(Name type);
  Stream<SlotEvent> get slotEvents;
  Future<SlotEntry?> locateSlot(Name type, int slot);   // LOCATE (assigns a free slot in a managed space); null = stays free
}
class StaticResolver implements SlotResolver { StaticResolver([Iterable<ServiceRecord> records]); add/remove;
  defineSlots(SlotSpace); removeSlots(Name); setSlot(Name type, int slot, SlotEntry); }   // locateSlot answers from the configured map
class EndpointResolver implements Resolver { EndpointResolver(Uri endpoint); }   // every type resolves to [ServiceRecord(type/0, [endpoint])]
enum SelectionPolicy { roundRobin, random }        // resolver.dart (core): selectAndConnect's pick when no shard is given
/// A resolver that can have an instance registered without endpoints dial the caller (CONNECT).
abstract interface class BrokeringResolver implements Resolver {
  Future<String> connectTo(ServiceAddress address, Uri endpoint, Uint8List intent, {Duration? timeout});   // the identity the instance presents
}
class NamingResolver implements SlotResolver, BrokeringResolver { NamingResolver(NamingClient client, {Duration resolveTimeout = 5 s}); }   // naming_resolver.dart; locateSlot = client.locate, connectTo = client.connectTo

int fnv1a32(List<int> bytes); int slotForKey(List<int> key, int count); int slotForText(String key, int count);   // slot_key.dart (core)

// outgoing_policy.dart
typedef EndpointPolicy = ChannelPolicy? Function(Uri endpoint);                     // null: leave it to outgoingPolicy; a throw: denyAll
typedef EndpointCredential = FutureOr<Uint8List?> Function(Uri endpoint, ServiceRecord? record);   // null: empty payload (never defaultPayload)
typedef ExpectedIdentity = String? Function(Uri endpoint, ServiceRecord? record);   // the receiver of IDENT on an initiated connection; null: nobody; a throw: nobody

class Switchboard {
  Switchboard({Resolver? resolver, Uint8List? defaultPayload, MuxOptions? muxOptions, TalkOptions? talkOptions,
      Duration connectTimeout = 10 s, bool allowHostHint = false, int maxConnectionsPerEndpoint = 4,
      Duration slotRefreshTimeout = 5 s, SelectionPolicy selection = roundRobin, Random? random,   // random: source of SelectionPolicy.random
      ChannelPolicy? outgoingPolicy, EndpointPolicy? endpointPolicy, EndpointCredential? credentialFor,
      Credential? credential, HolderKey? holderKey, CredentialVerifier? verifier, bool identifyOutgoing = true,
      bool Function(Uri endpoint)? identifyFor, Duration identityTimeout = 10 s,
      ExpectedIdentity? expectedIdentityFor, RelayConfig? relay});   // ArgumentError: holder key missing/other, negative timeout
  Resolver? resolver; Uint8List defaultPayload; SelectionPolicy selection;
  Credential? credential;   // settable (renewal; ArgumentError for another holder key); sets every connection's localIdentity; final HolderKey? holderKey;
  CredentialVerifier? get verifier;   // muxOptions.identityVerifier (the constructor's verifier is copied into muxOptions)
  final bool identifyOutgoing; final bool Function(Uri endpoint)? identifyFor; final Duration identityTimeout;
  final ExpectedIdentity? expectedIdentityFor;   // a throw fails the connection (GOAWAY, INTERNAL); null names nobody
  Future<void> identifyOn(MuxConnection connection, {Uint8List? intent, String? receiver});   // StateError without a credential; see "Identity"
  Future<void> updateCredential(Credential credential);   // set credential, IDENT again on every open connection the node identified on (same intent and receiver)
  Uri? brokerEndpoint;                                    // where brokered instances dial this node; null: listeningEndpoints.first
  Future<MuxConnection> broker(ServiceAddress address, {Resolver? resolver});   // CONNECT: the instance dials this node; not pooled; see "Identity"
  bool get canBroker;                                     // brokerEndpoint != null || listening somewhere
  RelayConfig? relay;                                     // how a node that cannot broker reaches endpoint-less records; see "Identity", "Relay"
  Future<List<ServiceRecord>> resolveRelays({Resolver? resolver});   // the relays in the order tried now (selection policy, then round); FAILED_PRECONDITION without relay/resolver, NOT_FOUND none known
  @internal Future<(MuxChannel, ChannelAddress)> openSelected(ServiceAddress address, ChannelAddress header,
      {Resolver? resolver, bool excludeOwnEndpoints = false, bool Function(ServiceRecord)? where,
      bool implicitPayload = false, bool mayRelay = false});   // select + OPEN (instance filled, host cleared, one retry); openChannel, the MOVED retry, the proxy
  // The policy of an initiated connection is chosen once, when it is established: connect's or
  // dial's policy, else endpointPolicy(endpoint) if non-null, else outgoingPolicy; null allows
  // everything (as before). Applied in dispatch exactly like a listener policy.
  final ChannelPolicy? outgoingPolicy; final EndpointPolicy? endpointPolicy;
  // The application payload of an open without one from the caller (openChannel's payload null,
  // openChannelAt/openChannelOn's address payload empty): credentialFor(endpoint, record) when set
  // (record: the selected record for the resolving opens, null for openChannelAt/openChannelOn;
  // endpoint: the one the connection was established to), else defaultPayload. With the hook set,
  // defaultPayload is never attached implicitly; on an accepted connection (no destination) the
  // payload is empty. openChannelToSlot's MOVED retry asks again for the new owner. proxyHandler and
  // SlotGate forward their client's payload and never consult it. A throw fails the open.
  final EndpointCredential? credentialFor;

  // WebSocket listeners use WebSocketServerTransport, and dials IOWebSocketTransport.connect (no
  // compression offered), both with maxFrameSize = muxOptions.maxFrameSize (0: the 1 MiB transport default).
  // policy: null allows everything (internal listeners only); internet-facing listeners MUST set one
  // that refuses reserved types. Connections this node initiates take their policy from
  // connect/dial, endpointPolicy and outgoingPolicy (see above).
  // Other paths get 403, or with onOtherRequest are handed to it: the callback owns the response; if it
  // throws before starting it, logged SEVERE and answered 500. close() waits for callbacks in progress
  // like upgrades (at most connectTimeout).
  Future<Uri> listenWebSocket(Object address, int port, {String path = '/', ChannelPolicy? policy,
      FutureOr<void> Function(HttpRequest request)? onOtherRequest});   // returns the bound ws:// uri (port resolved)
  Future<Uri> listenTcp(Object address, int port, {ChannelPolicy? policy});                              // returns tcp:// uri
  // In-process listener: mem://<name or generated id>, registered isolate-wide (static map in
  // memory_endpoints.dart) until close. connect(mem://id) hands one side of a MemoryTransport pair
  // (delay: zero, so frames go through the event queue like socket I/O and a request loop cannot
  // starve timers) to the listener, which adopts it like a TCP accept (policy, dispatch,
  // connections, GOAWAY on close); unknown or closed id: UNAVAILABLE. Pool key and isOwnEndpoint use
  // the id alone (port, path, query ignored). Names: [A-Za-z0-9._~-]+, lower-cased; taken:
  // ALREADY_EXISTS. Generated ids: counter + random suffix. mem:// URIs are meaningless outside the
  // isolate: publish them to a naming service only when every node runs in the same isolate.
  Future<Uri> listenMemory({ChannelPolicy? policy, String? name});
  // A transport accepted outside the node (an app's own HttpServer, another listener), adopted exactly
  // like a listener's connection: acceptor side with muxOptions, policy, dispatch, connections, GOAWAY on
  // close. remote defaults to 'external' (no transport exposes a peer description). Once close() has
  // started: adopted all the same as a late adoption (GOAWAY at once, close waits for it), and the call
  // fails with FAILED_PRECONDITION.
  Future<MuxConnection> accept(StreamChannel<Uint8List> transport, {ChannelPolicy? policy, String? remote});
  // For an app routing its own HttpServer: the upgrade of listenWebSocket (limit maxFrameSize, default
  // the node's WebSocket limit; path not checked; remote = the peer address), then accept. A bad upgrade
  // is answered 400/426 and fails with INVALID_ARGUMENT; once closing, 503 and FAILED_PRECONDITION. The
  // upgrade is tracked like a listener's, so close() waits for it (at most connectTimeout).
  Future<MuxConnection> acceptWebSocket(HttpRequest request, {ChannelPolicy? policy, int? maxFrameSize});
  List<Uri> get listeningEndpoints;
  bool isOwnEndpoint(Uri endpoint);   // scheme, port, ws path; host = bound address, localhost, and for wildcard binds the loopback addresses, host name and interface addresses; mem: the id

  // acceptAnyInstance: also serves channels to any instance of type that no registration matches exactly
  // (wiki dispatch step 2b, before the instance-0 rule; first registered such registration wins)
  void registerService(Name type, ChannelHandler handler, {int instance = 0, bool acceptAnyInstance = false});
  void unregisterService(Name type, {int instance = 0});
  set defaultService(ChannelHandler? handler);
  set catchAll(ChannelHandler? handler);

  // where (on every open method below that resolves): records it refuses are not candidates; none left: NOT_FOUND
  Future<MuxChannel> openChannel(ServiceAddress address, {int? shard, Uint8List? payload, bool Function(ServiceRecord)? where});    // resolve + pool + OPEN
  Future<TalkChannel> openTalk(ServiceAddress address, {int? shard, Uint8List? payload, TalkOptions? options, bool Function(ServiceRecord)? where});
  Future<MuxChannel> openChannelAt(Uri endpoint, ChannelAddress address);                       // explicit endpoint; empty payload: credentialFor(endpoint, null) or defaultPayload
  MuxChannel openChannelOn(MuxConnection connection, ChannelAddress address);                   // on a given connection; empty payload as above (accepted: empty with the hook); StateError if the hook answers with a future
  Future<Uint8List> payloadFor(MuxConnection connection, {ServiceRecord? record});             // the payload an open on connection gets without one (for PeerSet, and before openChannelOn with an asynchronous hook)
  Future<TalkChannel> openTalkAt(Uri endpoint, ChannelAddress address, {TalkOptions? options});
  Future<(ServiceRecord, MuxConnection)> selectAndConnect(ServiceAddress address, {int? shard, Resolver? resolver, bool excludeOwnEndpoints = false, bool Function(ServiceRecord)? where});   // slot routing: see "Sharding"
  Future<SlotChannel> openChannelToSlot(Name type, int slot, {Uint8List? payload, bool Function(ServiceRecord)? where});   // openChannel(type/0, shard: slot) + one MOVED retry (where applies to both; a new owner it refuses ends the channel with NOT_FOUND)
  Future<TalkChannel> openTalkToSlot(Name type, int slot, {Uint8List? payload, TalkOptions? options, bool Function(ServiceRecord)? where});
  Future<ServiceAddress> resolveSlotOwner(Name type, int slot, {bool refresh = false});          // for callers handling MOVED themselves
  Future<MuxConnection> connect(Uri endpoint, {ChannelPolicy? policy, ServiceRecord? record});   // record: to expectedIdentityFor when a connection is dialled; pooled; ws, wss, tcp, mem; a further connection to the endpoint only when every pooled one is at its peer's announced maxChannels, up to maxConnectionsPerEndpoint; pooled per explicit policy (==) too
  Future<MuxConnection> dial(Uri endpoint, {ChannelPolicy? policy, Uint8List? intent, String? receiver, ServiceRecord? record});   // same path, not pooled: adopted for dispatch, on connections, GOAWAY on close; the caller owns it; intent/receiver: identify with them whatever identifyFor says (FAILED_PRECONDITION without a credential); record: for expectedIdentityFor
  Stream<MuxConnection> get connections;              // every accepted or initiated connection
  Future<void> close();                               // stop listening (mem ids released at once), goAway on all connections; connections established meanwhile (upgrades and dials in progress, at most connectTimeout; accept calls) get GOAWAY at once and are waited for too
}

/// Forwards every subframe and the close between two channels. Completes when both are done.
Future<void> pipeChannels(MuxChannel a, MuxChannel b);

/// A catch-all handler that resolves through [switchboard.resolver], rewrites the header
/// (strips host, fills instance) and pipes. [allow] filters by address; the default refuses
/// reserved types (pass an explicit allow to proxy `_ns`). Never connects to the node's own
/// listeners (records or host hints pointing back: UNAVAILABLE, logged). No resolver or a
/// closing node is UNAVAILABLE to the client too. At most
/// [maxChannelsPerConnection] channels (0 = no limit) are forwarded at a time per client
/// connection; beyond: RESOURCE_EXHAUSTED. Slot routing as selectAndConnect; for a slot
/// routed by a table, a backend CLOSE MOVED before any subframe was piped is retried once
/// at the new owner, unseen by the client (the retry counts as the same channel; what the
/// client sends meanwhile is held up to the node's muxOptions.maxChannelBufferBytes, beyond:
/// RESOURCE_EXHAUSTED). For a
/// table-routed type an instance in the address is ignored (routed by the table, replaced by
/// the owner) unless allowExplicitInstance; a channel that needs a LOCATE takes a token from
/// its connection's bucket (maxLocatesPerConnection, 0 = no limit; one back per
/// locateRefillInterval, zero = never), else RESOURCE_EXHAUSTED. MOVED/RELOCATED reach the
/// client with owner and epoch 0 and no reason unless revealOwners. A channel without a shard
/// slot (after authorize) to a type with a slot table in the resolver is PERMISSION_DENIED unless
/// allowNoSlot(type) is true (null: never), since it would reach the instances' noSlotHandler
/// (state transfer). The tables are read once resolve(type) answered (a resolver still syncing
/// has none yet), for slot routing too, not for host-hint relays; an admitted one is routed by the no-shard rule (the named
/// instance, else round robin). allow or allowNoSlot throwing: PERMISSION_DENIED. authorize (after allow and the budget, before
/// resolution; the channel is not read meanwhile): the address to forward (rewritten shard,
/// payload, ...), null = UNAUTHENTICATED, throw = PERMISSION_DENIED, no answer within
/// authorizeTimeout (zero = none) = UNAUTHENTICATED; a channel the client closed meanwhile is dropped.
ChannelHandler proxyHandler(Switchboard switchboard, {bool Function(ChannelAddress)? allow,
    FutureOr<ChannelAddress?> Function(IncomingChannel)? authorize, Duration authorizeTimeout = 10 s,
    Resolver? resolver, int maxChannelsPerConnection = 256, bool allowExplicitInstance = false,
    bool revealOwners = false, int maxLocatesPerConnection = 32, Duration locateRefillInterval = 1 s,
    bool Function(Name type)? allowNoSlot});

/// relay_config.dart: the relays of a node that cannot broker (Switchboard.relay).
class RelayConfig { RelayConfig({Name? type /* _relay */, List<Uri>? endpoints /* explicit, instead of resolving */, String? identity /* of the explicit relays */});
  final Name type; final List<Uri>? endpoints; final String? identity; }   // ArgumentError: type not reserved (no leading _), empty endpoints, no scheme, identity empty or > 255 bytes

/// relay.dart: the `_relay` service (wiki "Identity", "Relay"). Rules in order, each a CLOSE of
/// the `_relay` channel with a generic reason (details at FINE/INFO on Switchboard.Relay):
/// no peer identity: held up to the node's identityTimeout (with requireIdentity, or whenever the
/// node has a verifier; a channel that ends meanwhile is dropped), then UNAUTHENTICATED while
/// requireIdentity, else admitted unchecked (at once on a node without a verifier);
/// inner payload malformed, untyped, with a host hint, or of a reserved type: INVALID_ARGUMENT;
/// identified consumer without `open` for the inner type: PERMISSION_DENIED (checked again when
/// the consumer identifies while the inner channel is being opened, which is then closed
/// CANCELLED); with requireIdentity, an identity that expires while opening likewise closes the
/// inner channel CANCELLED and refuses the consumer UNAUTHENTICATED;
/// maxChannelsPerConnection reached (0 = none): RESOURCE_EXHAUSTED; then
/// openForwarded (selection as selectAndConnect, never to own listeners; records with endpoints
/// filtered out unless allowEndpoints): no record NOT_FOUND, only records with endpoints
/// FAILED_PRECONDITION, brokering failed UNAVAILABLE;
/// then pipeChannels (statuses unchanged both ways, MOVED/RELOCATED byte for byte, a lost
/// connection UNAVAILABLE).
class RelayService {
  RelayService(Switchboard switchboard, {bool requireIdentity = true, bool allowEndpoints = false,
      int maxChannelsPerConnection = 1024, Resolver? resolver});   // RangeError: negative bound; warning: node without MuxOptions.requireNamedIdent
  final Switchboard switchboard; final bool requireIdentity, allowEndpoints; final int maxChannelsPerConnection; final Resolver? resolver;
  ChannelHandler get handler;
}

/// slot_channel.dart: a StreamChannel<Uint8List> and StatusClosable forwarding to the current MuxChannel.
class SlotChannel { Name type; int slot; int maxHeldBytes; MuxChannel get channel; bool get retried; bool get canSend;
  Stream<Uint8List> stream; StreamSink<Uint8List> sink; Future<Status> done; void send(Uint8List); Future<void> close([Status]); }

/// peer_set.dart: one connection kept to every instance of a type (wiki use case 5, the consumer).
enum PeerState { added, connecting, online, offline, held, removed }
enum PeerEventType { added, online, offline, updated, held, removed }
class PeerEvent { PeerEventType type; Peer peer; Status? status; }   // status: offline's cause; removed: CANCELLED on close
class Peer { ServiceAddress address; ServiceRecord record; PeerState state; Status? lastStatus; DateTime? since;
  DateTime? nextAttemptAt; int attempt; Uri? endpoint /* null: brokered; the relay's when viaRelay */; bool viaRelay;
  MuxConnection? connection; MuxChannel? channel; bool isOnline; }   // a live view
class PeerSet {
  factory PeerSet.watch(Switchboard switchboard, Name type, {Resolver? resolver /* default: the node's */,
      FutureOr<void> Function(Peer)? onConnect, ChannelAddress? channel, FutureOr<void> Function(Peer, MuxChannel)? onOpen,
      Duration initialBackoff = 500 ms, Duration maxBackoff = 30 s, double backoffFactor = 2, double jitter = 0.2,
      Duration connectTimeout = 10 s, Duration removalHoldDown = 15 s, ChannelPolicy? policy, Random? random});   // ArgumentError: no resolver, onOpen without channel, negative hold-down, bad schedule
  Map<int, Peer> get peers; Iterable<Peer> get online; Stream<PeerEvent> get events; Future<void> get ready; bool get isClosed;
  Future<MuxChannel> openChannel(int instance, {Uint8List? payload});    // NOT_FOUND unknown, FAILED_PRECONDITION without a usable connection (works while connecting, re-opening and held)
  Future<TalkChannel> openTalk(int instance, {Uint8List? payload, TalkOptions? options});
  Future<void> close();
}
```

Outgoing policies and credentials (wiki "Addressing", "Connections and identity"): a node that dials peers it does not trust (workers on rented machines) gives those connections a policy, so that the peer cannot push channels into it, and presents each destination its own credential, so that the mesh credential (`defaultPayload`) never reaches it. Pooled connections are keyed by endpoint and, for `connect(policy:)`, by the policy object too, so that an explicit policy never hands out a connection established under another one (`ChannelPolicies.allowTypes` returns a new closure per call: reuse one). `endpointPolicy` is evaluated per dial, which is why it must be a function of the endpoint alone, and on the endpoint normalised as the pool keys it (`_normalised`: scheme and host lower-cased, default port filled in, path `/` when empty and query for `ws`/`wss` only, no fragment, `mem` by its id), so the spellings of one endpoint, which share pooled connections, get the same policy. A record for any instance (an `EndpointResolver`'s) selected for a named instance stands for that instance with the record's endpoints and metadata, so `credentialFor` sees the metadata. Record metadata is visible to every watcher of the naming table: a key published there authenticates the mesh to the instance, not the instance to the mesh.

`PeerSet` (peer_set.dart): membership is the resolver's records of the type: after `ready`, `resolve(type)`; events that arrived before `resolve` was called are dropped (its answer has them), those that arrive while it answers are folded into the answer in order (UP replaces, DOWN removes, so the result is the resolver's current table and each record is added once; one that came and went is never added), then `events` as they come (`onError`: logged, the set goes on). A DOWN holds the peer for `removalHoldDown` (state `held`, event `held`, not `online`; connection, channel and retries kept, no GOAWAY, online/offline transitions not reported meanwhile); an UP for it within the hold-down at the endpoint it is connected to (or while it is not connected) adopts it again (`online` or `offline` reported as it stands, `updated` if the record differs), an UP elsewhere removes it and adds a new peer, and the end of the hold-down removes it. The reason: a naming service or registrar restart emits DOWN for every worker, and without the hold-down every job in flight would be cut after `goAwayGrace`. `Duration.zero` removes at once. One connection per peer through `Switchboard.dial` (never pooled: a worker that reboots disturbs nothing else, and each peer has its own backoff), to the first endpoint of the record that answers; each endpoint is given the time left of `connectTimeout` divided by the endpoints left (a dial given up on is sent GOAWAY if it lands later, and `close` waits for it), so one that never answers leaves time for the next. A record without endpoints is brokered instead (`Switchboard.broker` with the set's resolver, bounded by `connectTimeout`, a late connection sent GOAWAY): the connection is accepted, under the listener's policy, `Peer.endpoint` stays null, and a loss is brokered again after the backoff; a record that gains or loses its endpoints moves the peer as other endpoints do. On a node that cannot broker (`canBroker` false) and has a `relay`, such a record is reached through a relay instead: each attempt dials the records `resolveRelays(resolver: the set's)` gives, in that order and with the same split of `connectTimeout`, through `dial(endpoint, policy:, record: relayRecord)` (so the IDENT names the relay from its record), and keeps the first that answers as the peer's own connection (`endpoint` the relay's, `viaRelay` true); the per-peer channel and `openChannel` wrap the peer's open payload in a relay channel. Losses of the relay connection (lost, GOAWAY) are handled as for any connection, through whichever relay resolves next; a per-peer channel that ends while the peer is online is re-opened on the same relay connection after the per-channel backoff, and a re-open that fails (the relay cannot reach the peer) fails the connection (GOAWAY, retry after the backoff through the relays again), whatever its status. A held relayed peer is adopted again by a record that still has no endpoints. The PING of the set-up is answered by the relay before the peer has seen the channel, so for a relayed peer only `onOpen` confirms the channel reached it. A peer is online only once usable: after connecting, `onConnect`, then the per-peer channel (instance filled with the peer's id when 0; empty payload replaced by `payloadFor(connection, record)`), a mux PING round trip (a refusal the peer sends on arrival arrives before the PONG and is handled first), `onOpen`, then online; each step bounded by `connectTimeout`. A hook that throws, fails or times out (`INTERNAL` `'<hook> failed'` / `'<hook> timed out'`), a PING without answer (`UNAVAILABLE`), and a per-peer channel that the peer refuses or closes before the peer is online (its close status, any code), fail the attempt: GOAWAY, offline with that status, next attempt after the backoff; `attempt` counts on until the peer is online. Backoff and GOAWAY handling mirror `ReconnectingClient` (the schedule is the shared `Backoff`): a connection that ends counts as a failure unless the peer went online on it and it lasted `maxBackoff`; a peer GOAWAY `GOING_AWAY` leaves the connection to the application's channels and reconnects at once (backoff only if that fails or the connection itself followed a GOAWAY and did not last). The per-peer channel follows `PersistentChannel`: when it ends on a live connection on which the peer was online, the peer goes offline with its close status (`nextAttemptAt` the re-open) and the same set-up (open, PING, bounded `onOpen`) runs again after the per-channel backoff, as `connecting`; a re-open that fails with a non-terminal status (refused, `onOpen` failed or timed out) is retried after the backoff, while a terminal status (`PERMISSION_DENIED`, `UNAUTHENTICATED`, `UNIMPLEMENTED`, `NOT_FOUND`) fails the connection. Events: `added`; then `online` and `offline` alternating (`offline` also when the first attempt fails, reported once until online again); `updated` when the record changes (other endpoints move the peer: its connection is left with GOAWAY if its endpoint was withdrawn, a waiting retry is made at once, the failure count reset); `held`; `removed` last (record gone after the hold-down: GOAWAY on its connection; `close`: `CANCELLED`). `watch` logs a warning when no policy applies to the set's connections (no `policy`, `outgoingPolicy` or `endpointPolicy`) and when the node has a non-empty `defaultPayload` and no `credentialFor`. `close` waits for attempts in progress and for every connection of the set to close, so no timer is left.

Rejections sent to peers by the node and the proxy (policy refusals, no handler, resolution and connection failures, per-client limit) carry the status code and a generic reason only (`'permission denied'`, `'not found'`, `'unavailable'`, ...); the details (instance ids, endpoints, resolver state) are logged locally at FINE or INFO. Statuses a backend sends pass through the proxy unchanged, except `MOVED` and `RELOCATED`, whose owner and epoch are zeroed (and reason dropped) unless `revealOwners`; a lost connection on one side reaches the other as `UNAVAILABLE` `'connection lost'`.

Dispatch order is as in the wiki "Addressing" page, after the listener policy. Resolution: `resolver.resolve(type)`, filter by instance if non-zero, then by `where` (an exception it throws reaches the caller), pick by shard (the slot's owner for a type with a slot table, see "Sharding", NOT_FOUND if `where` refuses the owner; otherwise `sorted[s % n]` of the remaining) or by the node's `selection` (round robin: a per-type counter shared by all filters; random: `random.nextInt(n)`), connect to `endpoints.first` (try next on failure, then the following instances in sorted order), OPEN with header `{type, selectedInstance, shard, payload}`. `proxyHandler` gets the node's selection policy through `selectAndConnect` and passes no filter.

## Identity

The wiki page "Polyverse Switchboard Identity and Credentials". Stage A: credentials, connection identity, scoped policies. Stage B: the receiver binding of `IDENT`, scope enforcement at the naming service, `RENEW` and automatic renewal, `CONNECT` brokering, brokered peers in `PeerSet`. Then the relay: `RelayService`, `MeshNode.publishRelay`, `Switchboard.relay`, relayed peers in `PeerSet`.

```dart
enum CredentialKind { node(1), client(2), device(3) }
enum Right { register(1), open(2), watch(3), claim(4), migrate(5), broker(6), admin(7) }   // fromCode: null for unknown
enum SignatureKind { hmacSha256(1, 32), ed25519(2, 64) }   // code, signatureLength
class Scope { const Scope(Right right, Name pattern); Scope.of(Right right, String pattern);
  bool matches(Name name); static bool patternMatches(Name pattern, Name name); }   // trailing '*' (last non-zero byte) = any suffix, empty included; '*' alone = all
class Credential {
  Credential({required kind, required keyId, required identity, required issuedAt, required expiresAt,
      List<int>? holderKey, List<Scope> scopes = const [], required signatureKind, required List<int> signature});   // ArgumentError: field ranges, > maxLength
  static const currentVersion = 1, maxLength = 637, holderKeyLength = 32;   // 2 + 637 + 1 + 64 + 1 + 255 + 64 = 1024
  final int version; CredentialKind kind; Name keyId; String identity; int issuedAt; int expiresAt;   // unix seconds; expiresAt 0 = never
  final Uint8List? holderKey; List<Scope> scopes; SignatureKind signatureKind; Uint8List signature;
  bool get isBearer; DateTime get issuedAtTime; DateTime? get expiresAtTime;
  bool isExpired([DateTime? now]);          // now >= expiresAt (clock.now() by default)
  bool allows(Right right, Name name);      // admin allows everything
  Uint8List get signedBytes; Uint8List encode();   // a decoded credential re-encodes to its exact bytes
  static Credential decode(Uint8List bytes);       // ProtocolException; unknown rights dropped (bytes kept)
}
class CredentialIssuer {
  CredentialIssuer.hmac(Name keyId, List<int> key);              // key >= 16 bytes
  CredentialIssuer.ed25519(Name keyId, SimpleKeyPair keyPair);   // package:cryptography
  static Future<CredentialIssuer> ed25519FromSeed(Name keyId, List<int> seed);
  Future<Credential> issue({required CredentialKind kind, required String identity, List<Scope> scopes,
      List<int>? holderKey, DateTime? issuedAt, Duration? lifetime = 8 h});   // null lifetime: never expires; HMAC + holderKey: ArgumentError
  Future<Uint8List> publicKey();            // Ed25519; StateError for HMAC
}
class CredentialVerifier {
  CredentialVerifier({Map<Name, List<int>> hmacKeys, Map<Name, List<int>> ed25519Keys, int cacheSize = 1024});
  void addHmacKey(Name keyId, List<int> key); void addEd25519Key(Name keyId, List<int> publicKey);
  Future<void> addIssuer(CredentialIssuer issuer); bool removeKey(Name keyId); Set<Name> get keyIds; int get cachedCount;
  Future<Credential> verify(Uint8List bytes, {DateTime? now});   // SwitchboardException(unauthenticated, 'invalid credential'); cause at FINE on Switchboard.Identity
}
class HolderKey { static Future<HolderKey> generate(); static Future<HolderKey> fromSeed(List<int> seed);
  static Future<HolderKey> fromKeyPair(SimpleKeyPair keyPair); Uint8List get publicKey; Future<Uint8List> sign(List<int> message); }
class PeerIdentity { Credential credential; Uint8List intent; DateTime verifiedAt; String receiver /* this side's identity, or empty: none named */;
  String get identity; CredentialKind get kind; List<Scope> get scopes; bool get provedPossession; bool allows(Right, Name); bool isExpired([DateTime?]); }
class MuxIdent { MuxIdent({required Uint8List credential, Uint8List? intent, Uint8List? receiver, Uint8List? proof});   // the IDENT payload codec (mux_frame.dart)
  static const nonceLength = 32, maxIntentLength = 64, maxReceiverLength = 255, proofLength = 64; static final Uint8List proofLabel;   // 'SWBIDENT'
  static Uint8List proofMessage(senderNonce, receiverNonce, intent, receiver); Uint8List encode(); static MuxIdent decode(Uint8List); }   // label, nonces, len8 intent, intent, len8 receiver, receiver
// MuxControlType.nonce(5), ident(6); MuxControlMessage.nonce(Uint8List), MuxControlMessage.ident(MuxIdent)
```

Behaviour notes:

* Credentials: the layout and decoding rules of the wiki page (version 1 only, kinds 1 to 3, strict UTF-8 identity, valid names, holder key 0 or 32 bytes, signature kind 1 or 2 with its length, nothing after the signature, at most 637 bytes, so that any credential with the longest intent and receiver fits an `IDENT`). A scope with an unknown right is dropped from `scopes` (it could only grant more); the decoded credential keeps its bytes, so `encode` and `signedBytes` are exact. `issuedAt` is informational; only `expiresAt` is checked.
* Verifier: decode, key by id, kind must match the key's, HMAC credentials must be bearer, HMAC compared in constant time, Ed25519 verified with `DartEd25519(sha512: const DartSha512())` (pure Dart: the default `Ed25519()` and `Sha512()` reach `Cryptography.instance`, whose browser implementation throws on Node.js). Cache: verified credentials by bytes, least recently used, `cacheSize` entries; concurrent checks of the same bytes share one future (which never fails; null is invalid); key changes bump an epoch, clear the cache and re-check a check that started under other keys. Expiry against `now` on every call, cached or not.
* Random: nonces and generated holder seeds come from `secureRandomBytes`: `Random.secure()` on the VM; on the web `globalThis.crypto.getRandomValues` called directly, since `Random.secure()` reads `self.crypto`, which throws under the Node.js test runner (`self` is not the global object there and the global `crypto` accessor checks its receiver).
* `identify`: holder key checked against the credential (`ArgumentError`); the IDENT size checked before anything is sent; NONCE sent unless sent; waits for the peer's NONCE (`DEADLINE_EXCEEDED` after the timeout); signs the proof over `SWBIDENT ‖ our nonce ‖ the peer's nonce ‖ len8 intent ‖ intent ‖ len8 receiver ‖ receiver` (the lengths keep a relay from moving the receiver's bytes into the intent); sends IDENT, then `ping()` bounded by what is left of the timeout. The PONG confirms: the receiver handles frames after an IDENT only once it took effect. A connection that ends meanwhile fails it with `UNAUTHENTICATED` if the peer's GOAWAY said so, else the end status.
* Receiving NONCE: exactly 32 bytes, at most one (else protocol error); answered with ours if not sent (then `identityRequested` completes); completes `identify` waiting for it.
* Receiving IDENT: protocol error before both nonces or for a malformed envelope (`MuxIdent.decode`: truncated, intent over 64 bytes), with or without a verifier, so that a malformed IDENT does not reveal whether the node checks identity; then ignored without a verifier. Else the subscription is paused and verification runs: the receiver field, when not empty, must be the bytes of `localIdentity` (a side without one refuses every named IDENT), and when empty is refused under `requireNamedIdent`, before the credential is looked at; `verify` the credential; holder key: proof exactly 64 bytes verifying over `SWBIDENT ‖ the peer's nonce ‖ ours ‖ len8 intent ‖ intent ‖ len8 receiver ‖ receiver`; bearer: proof empty. Valid: `peerIdentity` replaced, `peerIdentified` completed once, `identityChanged` signalled, held frames handled in order, the subscription resumed. Invalid: GOAWAY `UNAUTHENTICATED` 'identification failed' and close (`done` is `UNAUTHENTICATED`); the cause is logged at INFO. The frames held meanwhile are dropped, IDENTs among them unverified, so an unidentified peer gets one credential check per connection (no counter is needed for that bound).
* `Switchboard`: with a `credential`, `_dial` (so `connect`, `dial`, the opens, `PeerSet`, the proxy) identifies after `_adopt` and before returning, when `dial` was given an intent or a receiver, or `identifyFor(normalised endpoint)` (a throw: no) or else `identifyOutgoing` says so, naming the receiver `dial` was given, else `expectedIdentityFor(normalised endpoint, record)` (the record whose endpoint the open dials, `dial`'s or `PeerSet`'s, or the relay's for a connection to a relay; `connect` and `openChannelAt` pass null: the pooled connection then serves every record at that endpoint, which is one node, so naming it from the first record is sound), else, for a relay's record (type `_relay` or `relay.type`), the identity in its metadata (UTF-8, at most 255 bytes, else nobody); the pool gets the connection only afterwards, so concurrent opens wait for it. A hook that throws fails closed (a null answer still names nobody; the wiki's "Dart reference" still says a throw names nobody, an amendment is proposed): the error is logged at WARNING, the connection gets GOAWAY and the caller `INTERNAL` 'expectedIdentityFor failed for <endpoint>' (never the error's text, which a proxy or relay could pass on), so that no `IDENT` naming nobody stands in for a receiver binding the hook could not give; the opens that resolve, the relay path and `PeerSet` count it as an endpoint that could not be connected to (the next endpoint or relay is tried, the peer retried after its backoff); `identifyOn` fails the same way without an `IDENT`, leaving the connection as it is. The intent and receiver of every identification are kept per connection: `updateCredential` sends IDENT again with them on every open connection the node identified on, and `identifyOn` names the last receiver by default. `localIdentity` is set on every connection at `_adopt` and when the credential changes. Failure: GOAWAY on the connection, `UNAUTHENTICATED` naming the cause to the caller (`FAILED_PRECONDITION` when the node is closing). Accepted connections never identify on their own (`identifyOn`). The constructor's `verifier` is copied into `muxOptions`, so every connection, accepted or initiated, verifies.
* Dispatch: policy refusal codes as in `ChannelPolicy`. `UNAUTHENTICATED` with no (unexpired) peer identity and `identityTimeout > 0`: the channel is held; on each `identityChanged` (or the channel ending, or the time left) the channel is checked: no longer open, dropped; the policy evaluated again: admitted, delivered; another refusal, or `UNAUTHENTICATED` although identified, refused with it; at the deadline CLOSE `UNAUTHENTICATED`. No GOAWAY for it (the wiki's SHOULD): a policy may require identity for some types only. Dispatch and the relay share `identity_wait.dart`: one listener per connection on the next identity event, with removable per-channel waiters and cancelled timers when a hold ends. Repeated closed or timed-out channels cannot accumulate callbacks on an unidentified connection.
* `ChannelPolicies.scoped` admits `_ns` and `_relay` for every identified peer, whatever its `open` scopes: the naming service checks the naming rights, and a worker must reach it to register; the relay checks the consumer's `open` scope for the inner type of each channel.
* `PeerSet.watch` warns when the node identifies with a bearer credential on every initiated connection.
* Brokering (`broker`, and `selectAndConnect` for a record without endpoints through a `BrokeringResolver`, pooled per `ServiceAddress`): needs a verifier and a listener (`brokerEndpoint`, else the first listening endpoint); a random 16-byte intent is registered as a wait, `resolver.connectTo(address, endpoint, intent, timeout:)` asks the naming service, and the first IDENT of every accepted connection (`peerIdentified`) whose intent is waited for completes the wait; the connection must carry the identity the answer names (else GOAWAY, `UNAUTHENTICATED`); the node then identifies on it naming that identity. `connectTimeout` bounds the request and the wait together. A failed CONNECT also sends GOAWAY to a dial-back that already arrived while the request was pending. An intent given up on is remembered (the last 256): a connection that arrives with it later is sent GOAWAY. `close` fails the waits.
* Relay, consumer side (`Switchboard.relay`, wiki "Identity", "Relay"): the opens that resolve (`openChannel`, `openTalk`, `openChannelToSlot`, `openTalkToSlot` and its `MOVED` retry, through the internal `openSelected(mayRelay: true)`) route a record without endpoints through a relay when the node cannot broker (`canBroker`: no `brokerEndpoint`, no listener) and `relay` is set; a node that can broker never relays, and `selectAndConnect`, `broker`, the proxy and the slot gate never do. The relays: one record per explicit endpoint (instance 0, metadata the configured identity), or the records of `relay.type` the resolver knows with endpoints, sorted by instance, started by the node's `selection` (the round robin counter of the relay type) and tried in turn; each endpoint through the pool (`connect` with the relay's record, so a new connection's IDENT names the relay's identity unless `expectedIdentityFor` names someone); one relay connection serves every candidate of the open (a relay failure is not retried per candidate). The OPEN on the relay connection is `ChannelAddress(type: relay.type, payload: <the destination's header and payload>)`: type, the selected instance, the shard slot, and the application payload (the caller's, else `credentialFor(the relay's endpoint as dialled, the destination's record)`, else `defaultPayload`). The returned channel is the relay channel; `openChannelToSlot` keeps the destination's instance for its retry. Failures are the destination's: `UNAVAILABLE` naming `(relayed)` and the relay's failure (`NOT_FOUND` no relay known, `UNAVAILABLE` none reachable, `UNAUTHENTICATED` a refused IDENT). Without `relay` nothing changes (brokering fails with `FAILED_PRECONDITION` 'no listener', reported as `UNAVAILABLE`).
* Relay, service side (`RelayService`, `MeshNode.publishRelay`): the handler holds a channel of an unidentified connection like the dispatcher holds one its policy refused (`identityChanged`, the channel's end, the node's `identityTimeout`), then refuses it `UNAUTHENTICATED`. With `requireIdentity` false the hold is the same whenever the node has a verifier (so an OPEN that overtakes the consumer's `IDENT` is checked under the identity it establishes, as the wiki's "an identified consumer is held to its scopes either way" requires), and only a consumer still unidentified after it passes unchecked; on a node without a verifier, which identifies nobody, it passes at once. A held channel that ends meanwhile is dropped without a refusal, before the bound is entered. The scope check runs again after `openForwarded` when the connection's `peerIdentity` is no longer the one checked (a valid `IDENT` arrived meanwhile): if the new identity lacks `open`, the inner channel is closed `CANCELLED` and the consumer's refused `PERMISSION_DENIED`; an identity arriving after the channels are piped does not affect them, as for any channel the dispatcher admitted. The inner payload is decoded with `ChannelAddress.decode` (`ProtocolException`: `INVALID_ARGUMENT`); no type (the receiver's default service means nothing through a relay), a host hint or a reserved type: `INVALID_ARGUMENT`. Scope: `PeerIdentity.allows(open, type)`. The bound is a `ForwardingBound` per relay (an `Expando` count per consumer connection, as the proxy's). Forwarding is `openForwarded` with a `where` that refuses records with endpoints unless `allowEndpoints` and notes it: a `NOT_FOUND` after such a refusal is `FAILED_PRECONDITION`. Selection is `selectAndConnect`'s with the inner instance and shard (an explicit instance is honoured, unlike the proxy's for table-routed types: consumers are identified mesh nodes that may address instances directly), never to the node's own listeners; a record without endpoints is brokered through `_brokeredPooled`, so one connection per instance serves every consumer. The inner OPEN is the inner header with the selected instance and the application payload unchanged; then `pipeChannels` with no rewrite (MOVED and RELOCATED fields byte for byte, unlike the proxy's `revealOwners: false`). The relay's host sets `MuxOptions.requireNamedIdent` itself (there is no `Switchboard`-level option; the `RelayService` constructor logs a warning without it); `publishRelay` registers `_relay` with the identity of the node's credential as metadata.
* What the reference resolver needs: a `NamingResolver` subscribes to every type (`WATCH` with an empty payload), which needs `watch *`; the consumers and relays of `test/integration/relayed_workers_test.dart` hold `watch *`, the rest of their credentials as strict as the wiki's (consumers `open worker-*`; relays `register _relay`, `open` and `broker` for `worker-*`; the worker `register worker-*`).

## Naming service

```dart
class NamingService {
  NamingService({Duration assignmentHold, Duration holderGrace, Duration handoverTimeout, int maxSlotCount,
      Duration assignBackoff, Duration assignBackoffMax, Duration holdingSettle, Duration handoverMaxDuration,
      int resumeAttempts, CredentialVerifier? verifier, bool requireCredential = false, CredentialIssuer? issuer,
      bool Function(Credential credential)? renewable, Duration brokerTimeout = 30 s});
  ChannelHandler get handler;                       // register with switchboard.registerService(Services.naming, ns.handler, instance: 1); passes the connection and the open payload to serve
  void serve(TalkChannel channel, {MuxConnection? connection, Uint8List? credential});   // StateError (and nothing kept) if its messages are already listened to
  final CredentialVerifier? verifier;               // payload credentials; IDENT is the connection's own verifier's
  final bool requireCredential;                     // no valid identity: every request UNAUTHENTICATED
  final CredentialIssuer? issuer;                   // RENEW; null: UNIMPLEMENTED
  final bool Function(Credential)? renewable;       // false: RENEW refused (revocation)
  final Duration brokerTimeout;                     // CONNECT: the instance dials back and answers within it (0: none)
  Map<ServiceAddress, ServiceRecord> get table;
  Stream<ServiceEvent> get events;
  int registerLocal(Name type, List<Uri> endpoints, {int instance = 0, Uint8List? metadata});   // owned by the service; again: replaces endpoints and metadata
  void unregisterLocal(ServiceAddress address);
  static const int maxWatchesPerChannel = 1024;     // distinct type filters per channel; one more: RESOURCE_EXHAUSTED
  int get watchCount;                               // subscriptions: one per channel and type filter, however many WATCHes hold it
  Duration assignmentHold;                          // REGISTER for any id held this long after construction, default 2 s; slot assignment waits too
  Duration holderGrace;                             // holder-only slot waits this long for its holder, default 5 min
  Duration handoverTimeout;                         // default requester timeout of ASSIGN/DRAIN/FORWARD/RESUME until the instance declares one, default 60 s
  Duration handoverMaxDuration;                     // an ASSIGN or DRAIN running longer, whatever was declared, is cancelled and fails; clamps relayed declarations; default 10 min (0: none)
  int maxSlotCount;                                 // larger SLOTS refused with OUT_OF_RANGE, default 65536
  Duration assignBackoff;                           // an instance that failed ASSIGN of a slot is not offered it again for this long, default 200 ms, doubling
  Duration assignBackoffMax;                        // ... up to this, default 10 s; reset when it accepts the slot (same intervals for a refused DRAIN, per slot and owner)
  Duration holdingSettle;                           // after SLOTS with capacity, free slots without holder wait until SLOTS/HOLDING/CLAIM are quiet this long, default 1 s (0: off)
  int resumeAttempts;                               // RESUME of a rolled-back migration sent again with the ASSIGN backoff intervals; after this many failures in a row the slot is free (holder kept), default 5
  bool get isHoldingAssignments;
  Map<Name, SlotTable> get slotTables;              // read-only, live
  SlotTable? slotTable(Name type);
  Stream<SlotItem> get slotEvents;                  // every SLOT item published, in order
}

class SlotTable { SlotSpace space; Map<int, SlotEntry> entries; Name type; int count;
  SlotEntry operator [](int slot); Set<int> get owners; List<int> slotsOf(int instance); }
class SlotEvent { Name type; int slot; SlotEntry entry; SlotEntry previous; }

class NamingClient {
  NamingClient(TalkConnector connect, {Duration reconnectDelay, bool watch = true});   // transport independent; the channel's requestTimeout bounds WATCH; watch false: register only
  Future<void> start();
  Future<int> register(Name type, List<Uri> endpoints, {int instance = 0, void Function(int)? onAssigned, Uint8List? metadata});   // remembered (metadata copied) for re-registration on reconnect; onAssigned on every new id
  Future<void> unregister(Name type, int instance);
  Future<void> get synced;                          // WATCH reply of the current session; replaced after a loss
  bool get isSynced;                                // WATCH answered on the current session
  bool get hasSynced;                               // synced on any session so far; never reset
  Future<void> get firstSynced;                     // one-shot: the first sync ever; fails with CANCELLED on close
  Map<ServiceAddress, ServiceRecord> get table;
  Stream<ServiceEvent> get events;
  bool get isConnected;
  Future<void> close();

  // Identity
  Future<Credential> renew({Credential? current});  // RENEW: current's bytes, or empty for the channel's own
  Future<String> connectTo(Name type, int instance, Uri endpoint, Uint8List intent, {Duration? timeout});   // CONNECT; the identity the instance presents; timeout cancels the request
  ConnectHandler? connectHandler;                   // serves the CONNECT the naming service relays; null: UNIMPLEMENTED
  // typedef ConnectHandler = Future<void> Function(DialBackRequest request);   // complete once the dial-back identified; a failure is the abort status (non-Switchboard: UNAVAILABLE)

  // Sharding (constructor also takes Duration slotHandlerMaxDuration, default 10 min:
  // then ABORT DEADLINE_EXCEEDED, 0 = none; declared deadlines are lowered to what is left of it)
  SlotHandler? slotHandler;
  Future<void> defineSlots(Name type, {required int count, SlotMode mode, bool lazy, bool shared, int capacity = 1});   // remembered
  Future<List<int>> declareHolding(Name type, List<int> slots);   // remembered; returns slots to discard
  Future<int> claim(Name type, int slot, {bool holding = false});
  Future<void> release(Name type, int slot, {bool keepStorage = false});
  Future<LocateResponse> locate(Name type, int slot);
  Stream<PhaseItem> migrate(Name type, int slot, {int to = 0});
  Map<Name, SlotTable> get slotTables; SlotTable? slotTable(Name type);
  SlotEntry? slotOwner(Name type, int slot);         // owned or migrating (route to entry.owner), else null
  Set<int> slotOwners(Name type);                   // distinct owners, `from` while migrating
  Stream<SlotEvent> get slotEvents;
  Map<int, int> servedSlots(Name type);             // slot -> epoch this instance serves
}

enum AssignResult { holding, notHolding }
abstract class SlotRequestContext {                 // one ASSIGN/DRAIN/FORWARD/RESUME as its handler sees it
  Name get type; int get slot; int get epoch;
  bool get isCancelled; Future<void> get onCancel;  // the naming service gave up, the declared deadline or the bound passed, the channel ended
  void extend({Duration? deadline, Duration? renew});   // one EXTEND; no-op (FINE) once unanswerable; ArgumentError if negative
}
abstract class SlotHandler {
  Future<AssignResult> onAssign(AssignRequest request, SlotRequestContext context);
  Future<void> onDrain(DrainRequest request, SlotRequestContext context);
  Future<void> onForward(ForwardRequest request, SlotRequestContext context);
  Future<void> onResume(ResumeRequest request, SlotRequestContext context);
  Future<void> onRevoke(Name type, int slot) async {}   // stop serving: re-claim refused, or ASSIGN not confirmed
  void onDiscard(Name type, List<int> slots) {}         // every HOLDING response's discards, after reconnects too
}
// NamingResolver: SlotTable? slotTable(type); SlotEntry? slotOwner(type, slot); Set<int> slotOwners(type); Stream<SlotEvent> slotEvents

// dart:io glue
NamingClient namingClientFor(Switchboard switchboard, Uri namingEndpoint, {Duration reconnectDelay, TalkOptions? talkOptions, bool watch = true});   // openTalkAt(endpoint, _ns): payload credentialFor(endpoint, null) with the hook (null: empty), else defaultPayload

class MeshNode {
  factory MeshNode.join(Switchboard switchboard, Uri namingEndpoint, {Duration reconnectDelay, Duration resolveTimeout, TalkOptions? talkOptions,
      ChannelPolicy? brokeredPolicy /* default ChannelPolicies.scoped() */, bool renewCredential = true, bool watch = true});   // sets switchboard.resolver = NamingResolver(client), starts the client, serves CONNECT
  Switchboard switchboard; NamingClient client; NamingResolver resolver;
  final ChannelPolicy brokeredPolicy; final bool renewCredential;
  Iterable<MuxConnection> get brokeredConnections;  // dialled for CONNECT, still open
  DateTime? get nextRenewalAt;                      // UTC, while a renewal is scheduled
  Future<void> get synced;
  Iterable<ServiceAddress> get published;
  Future<int> publish(Name type, ChannelHandler handler, {int instance = 0, List<Uri>? endpoints});   // register, then registerService(type, handler, instance: assigned); follows id changes
  Future<int> publishRelay(RelayService relay, {int instance = 0, List<Uri>? endpoints});   // publish(Services.relay, relay.handler) with the credential's identity (UTF-8) as metadata; none: empty + warning; ArgumentError: relay of another node
  Future<void> unpublish(Name type, int instance);
  Future<LeaveReport> leave();                      // stop renewing and serving CONNECT (GOAWAY on brokeredConnections), hand over / give up slots (below), close resolver and client, unregister local handlers; call before switchboard.close()

  // Sharding (join also takes Duration leaveTimeout = 5 s)
  SlotGates gates;                                  // the client's slot handler once a sharded type is published
  Future<SlotGate> publishSharded(Name type, SlotLifecycle lifecycle, {required int count, SlotMode mode = managed,
      bool lazy = false, bool shared = false, int capacity = 1, Iterable<int> holding = const [], int instance = 0,
      List<Uri>? endpoints, Duration forwardGrace = 30 s, Duration drainTimeout = 30 s, int maxQueuedChannels = 1024,
      int maxQueuedRequests = 1024, bool trackChannels = true, ChannelHandler? noSlotHandler});
  Future<int> claimSlot(Name type, int slot, {bool holding = false});
  Future<void> releaseSlot(Name type, int slot, {bool keepStorage = false});
  Stream<PhaseItem> migrateSlot(Name type, int slot, {int to = 0});
  Set<int> slotOwners(Name type);
}
class LeaveReport { Map<Name, List<int>> handedOver, released, dropped; bool get isComplete; }

// slot_gate.dart
abstract class SlotLifecycle {                      // extend it; the gate attaches itself
  SlotGate get gate;
  Future<AssignResult> load(int slot, {required int epoch, required int holder, required bool shared, SlotRequestContext? context});
  Future<void> drain(int slot, {required int epoch, required int to, SlotRequestContext? context}) async {}
  Future<void> unload(int slot) async {}
  FutureOr<void> serve(IncomingChannel channel, int slot);   // a throw or a failed future closes the channel with INTERNAL
  FutureOr<void> discard(List<int> slots) {}        // HOLDING answered "no longer yours" (through SlotGate.onDiscard); a failure is logged
}
enum SlotGateState { loading, serving, locked, forwarding }
class SlotGate implements SlotHandler {
  SlotGate(Switchboard switchboard, NamingClient client, Name type, {required SlotLifecycle lifecycle,
      Duration forwardGrace = 30 s, Duration drainTimeout = 30 s, int maxQueuedChannels = 1024,
      int maxQueuedRequests = 1024, bool trackChannels = true, ChannelHandler? noSlotHandler, int instance = 0});
  ChannelHandler get handler; ChannelHandler? noSlotHandler; int instance;
  Map<int, int> get servedSlots; SlotGateState? stateOf(int slot); bool serves(int slot);
  MovedStatus movedTo(int slot); Status movedStatus(int slot); Status relocatedStatus(int slot); void detach(IncomingChannel channel);
  Future<void> serveRequest(TalkMessage message, int slot, FutureOr<void> Function(TalkMessage) handler, {Uint8List? payload});
  Future<int> claim(int slot, {bool holding = false}); Future<void> release(int slot, {bool keepStorage = false});
  Future<void> close();
}
class SlotGates extends SlotHandler { Map<Name, SlotGate> gates; SlotGate? operator [](Name); void add(SlotGate); SlotGate? remove(Name); }
// SlotGate and SlotGates take the context as an optional positional parameter ([SlotRequestContext? context]), so tests can drive them without one.
```

Behaviour notes:

* What the service accepts, every watcher can decode. Endpoints are checked with `ServiceRecord.checkEndpoint` by the decoders (`ProtocolException`), by the service for `REGISTER` and `registerLocal` (`INVALID_ARGUMENT`) and by `NamingClient.register` (`ArgumentError`): a scheme, at most 255 bytes once normalised, and the normalised text parses back to an equal `Uri` (checked both ways: `Uri ==` compares text or components depending on the representation, so it is not symmetric).
* Metadata: `REGISTER` and `registerLocal` refuse more than `maxMetadataLength` (4096) bytes with `INVALID_ARGUMENT`, `NamingClient.register` with `ArgumentError`. Re-registering an id held by the same channel replaces endpoints and metadata and publishes `UP` if either changed (record equality), so watchers' `UP` events also mean "metadata changed"; the client and resolver mirror it unchanged.
* Registrars (wiki "Registering on behalf of others"): nothing ties a record to the registering process's endpoints. One `NamingClient` may register many records (explicit ids, each with its endpoints and metadata); they all live and die with its channel, are re-registered after its reconnects, and are retired with `unregister`. The worker behind such a record registers its handler with `acceptAnyInstance: true`, since it does not know its id.
* Subscriptions (wiki "Naming Service", `WATCH`): a `_Session` keeps `Map<Name?, int> watches`, the count of `WATCH`es per type filter (null: every type); the service keeps the set of sessions with any. `WATCH` sends the snapshot as plain messages, replies, then counts the filter, all in one synchronous step; `UNWATCH` decrements (removing the filter at zero) before it replies, so nothing for an ended subscription follows the reply; `NOT_FOUND` without the filter. A change goes to each subscribed session once, whatever the number of its matching filters. A `WATCH` or `UNWATCH` sent as a stream request is `INVALID_ARGUMENT` (an older client gets a clear refusal rather than a stream that ends at once). A session whose channel refuses an event loses its subscriptions (it is closing). `close()` ends every subscription before it removes the channels' records, so their `DOWN`s reach `events` only. No timer is tied to a subscription: liveness is the connection's (mux keep-alive), and the only `EXTEND`s the service sends are declarations for requests it holds (below).
* Client sync: the client sends `WATCH` (all types, `ordered: true`) once its known ids are registered again; events before the reply (`_Session.syncing`) are the snapshot (addresses, spaces and slots collected), the reply runs the resync (local `DOWN` for what the snapshot did not mention, slot spaces and slots likewise) and completes `synced`/`firstSynced`. A failed `WATCH` (refused, or no reply within the channel's `requestTimeout`) loses the session, as does the end of the channel. One-way messages other than `UP`, `DOWN`, `SLOTSPC`, `SLOT` are logged at FINE and ignored. The client never sends `UNWATCH`; per-type subscriptions would be redundant beside its subscription to every type on the same channel.
* Resolution (`NamingResolver`) depends on `client.hasSynced` only: before the first sync ever, `resolve` waits for `firstSynced`, bounded by `resolveTimeout`, then fails `UNAVAILABLE`; after it, the table is served even while stale, whether or not anything was resolved before the loss and whenever the resolver was created. `ready` is `client.firstSynced`: it completes once the table has been synced at least once, does not reset on a loss, and fails with `CANCELLED` if the client is closed first. `Switchboard.selectAndConnect` calls `resolve` only, never `ready`, because `ready` has no bound.
* Indeterminate outcomes: a `REGISTER` or `UNREGSTR` that times out (`DEADLINE_EXCEEDED`) or gets an unreadable answer may or may not have taken effect. The client fails the caller's future and drops the channel, so the naming service discards everything owned by it, and the reconnect registers the remembered set again. A refused `UNREGSTR` (other than `NOT_FOUND`) drops the channel too. A channel lost while a request is in flight is not indeterminate: the record died with the channel, and the registration is made again after the reconnect (its future completes then).
* A re-registration refused on a healthy channel (anything but `ALREADY_EXISTS`, which moves to a new id) is retried on the same channel every `reconnectDelay`, without disturbing the client's other registrations.
* At most one remembered registration per `type/instance`: registering an explicit id again supersedes the earlier registration whether or not it completed (its future completes like the new one's; its late answer is ignored), and `unregister` removes every match.
* Ids after a naming service restart: the new service starts assigning at 1 again and knows nothing of the old ids. Surviving clients reconnect and ask for the ids they had (those first, before fresh registrations), but a fresh registration that reaches the new service first can be assigned one of them; the survivor then gets `ALREADY_EXISTS`, takes a new id and reports it through `onAssigned` (`MeshNode` moves its local dispatch), while addresses other services kept for the old id now resolve to the newcomer (same type) or to nothing. Mitigation: for `assignmentHold` after construction (default 2 s) the service answers `REGISTER` with instance 0 only once the hold is over (in arrival order; each is sent one `EXTEND` at receipt declaring the time left in the hold; one the requester cancels meanwhile is answered `CANCELLED` and never registered); requests for a given id, `registerLocal` and everything else are served at once. The client does not wait for held registrations before starting its `WATCH`. Survivors that take longer than the hold to come back can still lose their ids.
* Identity (wiki "Identity and Credentials", "Where credentials are checked"): a session's identity is evaluated at every request: the connection's `peerIdentity` (unexpired), else the payload credential, else none. The payload is verified with `verifier` before the first request is handled (the message subscription is paused meanwhile; without a verifier it is not looked at); a holder-key credential there, or bytes that are not a valid credential, leave the channel unidentified. Rights: `REGISTER` `register`; `WATCH`, `UNWATCH`, `LOOKUP` and `LOCATE` `watch` (all types: a `watch` scope with the pattern `*`, or `admin`); `CLAIM`, `RELEASE`, `HOLDING` `claim`; `MIGRATE` `migrate`; `CONNECT` `broker`; `SLOTS` `claim` or `register` (defining a space, redefining a blank one, confirming it: instances define their spaces again after a restart of the naming service; a differing definition of a space that is not blank is `FAILED_PRECONDITION` after the check); `UNREGSTR` ownership only; `RENEW` none. The check follows the decoding (a malformed request is `INVALID_ARGUMENT`) and precedes every other check. Refusals: `PERMISSION_DENIED` `'permission denied'`, `UNAUTHENTICATED` `'unauthenticated'`; the identity, right and type go to the log. Without `requireCredential` an unidentified channel may do everything, but one that was identified and lost its identity is refused: an expiry timer per identified session (at `expiresAt`; on firing, a renewed identity reschedules it) ends the session: `_drop` (records `DOWN`), the channel closed `UNAUTHENTICATED` `'credential expired'`, and a GOAWAY with that status on the connection when the identity was the connection's.
* `RENEW`: `UNIMPLEMENTED` without an `issuer`. The credential renewed is the session's own (empty payload, or its exact bytes), else the payload's, verified with `verifier` and, on an identified session, of the same identity and kind (else `PERMISSION_DENIED`); none valid: `UNAUTHENTICATED`; `renewable` false (or throwing): `PERMISSION_DENIED`. The issuer issues the same kind, identity, scopes (the known rights: a scope with a right this implementation does not know is lost) and holder key, with the original lifetime (`expiresAt - issuedAt`, none for 0) from now; an issuer that cannot (HMAC with a holder key): `FAILED_PRECONDITION` `'cannot renew'`. A session identified by its payload adopts the renewal as its payload credential.
* `CONNECT`: decode (`INVALID_ARGUMENT`; also for an empty type or instance 0), `broker` right, then the record: missing, of another type, local, its channel gone, or with endpoints: `NOT_FOUND` `'not found'`; its registration channel without identity: `FAILED_PRECONDITION`. The relayed request (`DialBackRequest` with the consumer's identity, empty if none) goes over the registration channel with `brokerTimeout` as requester timeout and as a hard bound (a timer cancels it); the consumer's request is declared `brokerTimeout` with `EXTEND` and answered `GOING_AWAY` if the service closes. The relay is cancelled when the instance's registration goes away, when the consumer cancels or its channel ends, and at the bound; every failure reaches the consumer as `UNAVAILABLE` `'unavailable'` (the cause logged). Success: `ConnectResponse` with the registration channel's identity. The dial-back is per registration channel: a node that registered several records serves all of them on the one connection.
* Client side: `connectTo` cancels its request at `timeout` (the naming service's declared deadline would otherwise replace the client's timeout). `connectHandler` is called for every relayed `CONNECT`; the request's responder timeout is off (the naming service bounds it). `watch` false sends no `WATCH`; a `WATCH` refused with `PERMISSION_DENIED` keeps the session and its registrations (logged SEVERE, the table not mirrored) instead of dropping the channel, which would loop.
* `MeshNode`: `connectHandler` dials `request.endpoint` with `dial(policy: brokeredPolicy, intent: request.intent, receiver: request.requester)` (`FAILED_PRECONDITION` without a credential or after `leave`), keeps the connection in `brokeredConnections` until it ends. Renewal: at `issuedAt + 2/3 (expiresAt - issuedAt)` by `package:clock` (none for a credential that never expires, or without one at `join`), `client.renew(current: credential)`, then `switchboard.updateCredential`; a failure retries after a quarter of the time left (at least a second), until the credential expires (logged SEVERE).

## Sharding

Behaviour notes (wiki "Switchboard Sharding"):

* Identity: the instance serving the slots of a type on a channel is that channel's registration of the type. A channel with several registrations of a sharded type gets `FAILED_PRECONDITION` for the slot procedures (the requests to instances carry no instance id). `SLOTS` without any registration of the type defines or confirms the space only (a router or operator tool).
* Capacity: `null` until the instance sends `SLOTS`, 0 takes no slots, 1 or more makes it a candidate of the allocator and of `LOCATE`. `CLAIM` works whatever the capacity, in both modes. Slots owned by instances without capacity are left out of rebalancing.
* Epochs increase only when an owner is assigned (`ASSIGN`, by claim, locate, allocator or migration), wrapping to 1. Release and loss keep the epoch; the next owner gets epoch + 1. `RESUME` carries the unchanged epoch.
* Holder of an assigned slot: the new owner, unless it answers "not holding", which keeps the previous holder. A claim with the holding flag on a free slot with holder 0 makes the claimant the holder; a known holder wins over the flag.
* `RELEASE` of a slot being assigned to the caller waits for that `ASSIGN`; a migrating slot is `FAILED_PRECONDITION`. `PERMISSION_DENIED` otherwise unless the caller owns it.
* Allocator (managed spaces), run in a microtask after every change: (1) free slots whose holder is a candidate go back to it; (2) eager spaces assign the other free slots to the candidate with the most spare share (`capacity * (assigned + 1) - load * totalCapacity`, ties to the lower id), at most 16 `ASSIGN`s in flight per space; a holder that is registered with capacity 0 has its slots assigned elsewhere with `holder` set to it; a holder that is down (or registered but has not sent `SLOTS`) makes a holder-only slot wait for `holderGrace`, then the holder is cleared; shared spaces reassign at once with `holder` and the shared flag; (3) when nothing is in flight, one rebalancing migration from the most over-share candidate that has a slot it can move to the most under-share one, if that one is short by a full slot, lowest slot first. Lazy spaces assign only on `LOCATE` (and give slots back to their holders), but still rebalance.
* `ASSIGN` and `DRAIN` overall bound: `handoverMaxDuration` (10 min) from the request, whatever the instance declares (a handler that keeps re-declaring would otherwise keep the slot busy or locked for ever); it is the requester's clamp for hand-over requests. Then the request is cancelled (Talk cancel, `DEADLINE_EXCEEDED`) and handled as a failure: a migration rolls back with `RESUME`, an `ASSIGN` starts the instance's backoff. The client bounds a handler call at `slotHandlerMaxDuration` (10 min), lowers what the handler declares to what is left of it, and answers `ABORT DEADLINE_EXCEEDED`; an `ASSIGN` answered so is revoked when the handler eventually completes.
* Declared deadlines instead of keep-alive (wiki "Talk", `EXTEND`): no timer sends `EXTEND`. A request the service holds gets its responder timeout turned off (the service answers it when the wait ends) and one `EXTEND` whenever what it waits for, and so how long it may wait, changes; `_SlotManager.declare` sends it unless an earlier declaration lasts as long (a request waiting for several things is told the latest bound). The hold: the time left in it (`REGISTER`, `CLAIM`, `HOLDING`, `LOCATE`, `MIGRATE`). An operation on a slot (`_Busy`: an `ASSIGN`, or a migration) tells its waiters (`CLAIM`, `RELEASE`, `LOCATE`, a deferred `HOLDING`, the `MIGRATE`s queued behind the running one) the bound of each hand-over request when it is sent (`handoverTimeout`, else `handoverMaxDuration`, else nothing), and relays every `EXTEND` the instance sends for it (through the request's `onExtend`), clamped to `handoverMaxDuration`, as a deadline (the longer of the two values; an empty `EXTEND` as `handoverTimeout`). The `MIGRATE` the migration serves is told the same values, exactly, so a shorter step shortens it. A `LOCATE` waiting out a backoff is told the time left until it gives up (`handoverTimeout` from its first wait), or `assignBackoffMax` without that bound. An instance still sending empty `EXTEND`s from a timer (written before declared deadlines) keeps working: each restarts the service's gap, and is relayed as such.
* `ASSIGN` backoff, per (type, slot, instance): an instance that fails an `ASSIGN` (refuses it, typically `UNAVAILABLE` until it is ready, or times out) is not offered that slot again by the allocator, `LOCATE` or a rebalancing migration for `assignBackoff` (200 ms), doubled at each further failure up to `assignBackoffMax` (10 s), and from `assignBackoff` again once it accepts the slot; an instance that goes down loses its backoffs. Meanwhile the slot goes to the best candidate not in its backoff (a holder in its backoff is passed over too, the new owner fetching from it); with none, it stays free and the end of the first backoff (its own timer) runs the allocator again. Rebalancing gives no owned slot to an instance in its backoff for any slot of the space (a failed hand-over costs the old owner a `DRAIN` and a `RESUME`). `LOCATE` tries the candidates in turn; once all are in their backoff it waits (told how long, once) for one to end or the slot to change, at most `handoverTimeout` from then (unbounded if 0), then fails `UNAVAILABLE` with the last refusal. `CLAIM` and `MIGRATE` to a given instance are not held back, but their failures and successes count.
* `DRAIN` backoff, per (type, slot, owner): an owner that refuses or fails the `DRAIN` of a migration (any migration; only rebalancing consults it) keeps that slot, as far as rebalancing goes, for the same intervals (`assignBackoff` doubling up to `assignBackoffMax`), reset by a successful `DRAIN`. Rebalancing then moves another slot of that owner, or, when the most over-share candidate has no slot it can move (busy or in its `DRAIN` backoff), one of the next most over-share candidate (only candidates over their share, most over first, ties to the lower id).
* Settle window after `SLOTS` (eager managed spaces; restart recovery): holders are only re-learned from `HOLDING`, which follows `SLOTS`. A `SLOTS` that gives an instance capacity opens a window in which the allocator assigns no free slot with holder 0 of that space; every `SLOTS`, `HOLDING` or `CLAIM` of the type extends it to `holdingSettle` (1 s) after that arrival, at most `max(holdingSettle, 5 * assignmentHold)` after it opened. Slots with a known holder still go back to it, `CLAIM` is served, and `LOCATE` assigns (an explicit demand), holder first as always.
* Hand-over: as in the wiki step by step; DRAIN and FORWARD go to `from`, ASSIGN to `to` with `holder` = the slot's holder (normally `from`). Requests to an instance fail at once when its registration goes away. One migration per space at a time; the allocator's go through the same queue. A queued `MIGRATE` is validated again when it starts; one whose requester cancelled leaves the queue at once (the slot can be queued again); a running one completes regardless. `MIGRATE` has no responder timeout; the requester is told the bound of each wait (above). The `RESUME` of a rollback is the only thing that unlocks the old owner while its channel lives, and is idempotent there: one that fails (refused, or no answer within `handoverTimeout`) is sent again after a backoff per slot and owner with the `ASSIGN` backoff intervals (`_Space.resumes`), as long as the slot stays `owned(from)` with that epoch and nothing else runs on it (a new migration, the owner going down, a release end the retries); rebalancing leaves such a slot alone; after `resumeAttempts` (5) failures in a row the slot is set free with its holder kept and the old owner enters its `ASSIGN` backoff for it, so the allocator places it elsewhere first. A migration the service's `close` interrupts sets its slot back as a rollback does (free with the holder, the old owner's registration being gone by then), sending nothing: instances unlock on the loss of their channel.
* `HOLDING` of a free slot with holder 0 that is being assigned to another instance (a fresh `ASSIGN`): the response waits until that `ASSIGN` is decided (told the `ASSIGN`'s bound); a failure makes the declarer the holder, a success lists the slot to discard. Without the wait, the declarer would be told to discard its only copy of a slot that then stays free.
* Assignment hold: `CLAIM`s are collected and resolved when it ends, in order of claimed epoch (descending) then arrival: the first claim of a slot proceeds, the others then see it owned (`ALREADY_EXISTS`) unless its `ASSIGN` failed. `HOLDING` is answered after the claims; `LOCATE` of a free managed slot, the allocator and migrations wait.
* Client: `ASSIGN`/`DRAIN`/`FORWARD`/`RESUME` handler calls get a `SlotRequestContext` (`_SlotContext`, which decodes type, slot and epoch from the request; a resume the client makes itself after losing the naming service gets a local one, whose `extend` does nothing). The responder timeout's gap is `slotHandlerMaxDuration` (so it applies only once the handler declares something: its own deadline, the server giving up first), plus the overall bound timer. Nothing is sent while the handler runs unless it calls `extend`; the naming service waits `handoverTimeout` otherwise. `onCancel` completes on the naming service's cancel, the responder timeout, the bound, or the end of the channel. A served slot is recorded before the `ASSIGN` reply; if the reply cannot be sent, `onRevoke` (unless it was already served). After a reconnect, per type once its registration is back: `SLOTS`, `HOLDING` (declared slots plus served slots it holds), then `CLAIM` of every served slot with the holding flag and last epoch, at most 256 in flight, all sent in the same turn; `HOLDING` goes before `SLOTS` when the mirror is synced on that channel and shows the space defined (a registration completing on a synced channel), since a restarted naming service that does not know the space yet would refuse it. A refused re-claim on a live channel calls `onRevoke`. A request of the restoration that the channel refuses before sending it (`RESOURCE_EXHAUSTED`, its `maxOutgoingRequests`) stops it there, so nothing overtakes it: the type is not marked restored on that channel, and the rest goes out after `reconnectDelay` (`_retry`), without what already went out (`_Session.sentSlots`, which also records whether the type was registered then: a `SLOTS` sent without the registration carries no capacity and is sent again with it, `sentHolding`, `reclaimed`); a refused re-claim goes back to the head of the queue and the claims pause for `reconnectDelay`. A `WATCH` refused that way is sent after `reconnectDelay` instead of dropping the channel. `claim`, `release` and `locate` go through a per-channel queue (`_ClientSlots.call`): one the channel refuses for its limit waits, with the calls after it, until one of them completes, or `reconnectDelay` when none is in flight; waiting calls fail `UNAVAILABLE` when the channel is lost. `declareHolding` for a type the client registers no instance of is sent at once (after the next connect while disconnected) and the naming service refuses it (`FAILED_PRECONDITION`, or `NOT_FOUND` without a space). Every `HOLDING` response's discard list (a `declareHolding`, or the one sent again after a reconnect) goes to `onDiscard` before the `declareHolding` future completes. When the channel is lost, or the client is closed, every slot locked by `DRAIN` gets `onResume` once its `onDrain` is done.

Routing and the instance side (stage B):

* Slot routing in `selectAndConnect`: only when the address names any instance, a shard is given and the resolver is a `SlotResolver` with a table for the type. Owner from the table (`from` while migrating); no owner: managed space `locateSlot`, static space `UNAVAILABLE`; a slot outside the space `OUT_OF_RANGE`; the owner missing from the service table (read again before giving up, since an owner just located may have registered after the first read) or unreachable `UNAVAILABLE`, never another instance. The header carries the owner's id. `proxyHandler` gets slot routing through `selectAndConnect`. The `LOCATE` of slot routing (in `selectAndConnect` and in the retry) is bounded by `slotRefreshTimeout` (5 s, then `UNAVAILABLE`). For a channel routed by a slot table the proxy pipes the client to a `SlotChannel` (below), so a backend's CLOSE `MOVED` before any subframe was piped either way is retried once at the new owner without the client noticing, the re-resolution being the same as `openChannelToSlot`'s (`reopenAtSlotOwner`, with the proxy's resolver, never towards the node's own listeners); after the first subframe the `MOVED` is forwarded to the client, which retries itself; a `RELOCATED` is always forwarded. The retry counts as the same channel for `maxChannelsPerConnection`. Untrusted clients: for a table-routed type the proxy ignores an instance in the address (it would reach an instance loading the slot, or one forwarding it, and overtake the hand-over) unless `allowExplicitInstance`; it passes `MOVED` and `RELOCATED` on with owner and epoch 0 and no reason unless `revealOwners` (its clients reopen through it; a `SlotChannel` at the client then reopens at the same address); and a channel whose routing needs a `LOCATE` (a managed space, no owner in the table), or a retry that does, takes a token from its client connection's bucket (`maxLocatesPerConnection` 32, one back per `locateRefillInterval` 1 s), else `RESOURCE_EXHAUSTED` (a retry without a token forwards the `MOVED`), since a `LOCATE` assigns slots in a lazy space; and a channel without a shard slot to a table-routed type, which would reach the instances' `noSlotHandler` (state transfer), is refused with `PERMISSION_DENIED` unless `allowNoSlot` admits the type (checked on the address `authorize` returned, so a hook that sets the slot makes it moot). The proxy reads the tables for both checks only once its resolver's `resolve(type)` answered, so that during its start-up (before the naming client's first sync) neither check is skipped for want of a table. A client flooding during a retry is bounded: what it sends while the replacement opens is held by the `SlotChannel` up to `maxChannelBufferBytes` of the proxy's `muxOptions` (as below), else `RESOURCE_EXHAUSTED`.
* `openChannelToSlot` / `openTalkToSlot`: a mux OPEN has no acknowledgement, so the retry is decided on the channel's end. A `SlotChannel` forwards to the current `MuxChannel`; when it ends with `MOVED` and nothing was sent on it or received from it, it is replaced once: to the owner the status names (`MovedStatus`), unless the table has an entry with a higher epoch (also one naming the rejecting owner: the slot came back to it after the rejection); with no owner named, through `locateSlot` (bounded by `slotRefreshTimeout`), in either mode; through a resolver without tables, the same address again. Nowhere else to go (no other owner, or one the resolver does not know): the channel ends with the `MOVED`; a new owner the caller's `where` refuses ends it with `NOT_FOUND`. Subframes sent while the replacement opens are held and sent on it, at most `maxHeldBytes` (the node's `muxOptions.maxChannelBufferBytes`, counted as the mux counts its receive buffers: length plus 32 per subframe); one beyond is dropped and the channel ends at once with `RESOURCE_EXHAUSTED` (a replacement opened after that is closed with it, unused). After the first subframe either way, `MOVED` is surfaced, since the subframes already sent went with the old channel; `MOVED` means nothing was processed, so the application may open again and resend. A `RELOCATED` (the owner was serving the channel, its work may have taken effect) is never retried. Server-first protocols (greeting, snapshot) always get the retry; a Talk client sending at once retries at its level.
* `SlotGate`, per sharded type per node, is the client's `SlotHandler` (through `SlotGates` when a client serves several types, which routes `onDiscard` to `lifecycle.discard` too) and the type's `ChannelHandler`. A lifecycle serves one gate at a time; once its gate is closed it may be attached to a new one (`gate` returns the closed gate until then, so detached channels of a closed gate still get `ABORT MOVED` through `serveRequest`), so a failed `publishSharded` can be repeated with the same lifecycle. Per slot: `loading` (ASSIGN running; channels queue), `serving`, `locked` (DRAIN; channels queue), `forwarding` (after FORWARD for `forwardGrace`; channels piped to the new owner, requests forwarded). Not held: `MOVED` naming the mirror's owner and epoch (the new owner while forwarding; owner 0 when the mirror names this instance or nobody). No shard: `noSlotHandler` (state transfer between instances), else `INVALID_ARGUMENT`; outside the space: `OUT_OF_RANGE`. Queued channels are never read (the mux buffers them), at most `maxQueuedChannels` over all slots (`UNAVAILABLE` beyond). `lifecycle.serve` and `lifecycle.discard` may be asynchronous (`FutureOr<void>`, so `void` overrides stay valid): the gate watches a returned future as the node does a `ChannelHandler`'s, so a failure, at once or later, closes the channel with `INTERNAL` (`serve`) or is logged (`discard`) and never escapes as an unhandled error; a served channel counts as work in flight until it ends, not until the future completes.
* Work in flight: with `trackChannels` (default) a served channel counts until it ends, unless `detach`ed (a long-lived channel); requests run through `serveRequest` count until their handler completes. DRAIN locks, waits until the slot has no work in flight (declaring `drainTimeout` through the context, once, when there is any), then calls `lifecycle.drain` with the context. When the wait exceeds `drainTimeout`, the tracked channels still open are closed with `RELOCATED` naming `to` and the new epoch before `lifecycle.drain` (otherwise the old owner would keep serving them, through FORWARD and the whole grace period, on state already handed over), and the `serveRequest` handlers still running are logged at WARNING (they cannot be stopped). A DRAIN for a slot not served is `FAILED_PRECONDITION`. `serveRequest`: a slot outside the mirrored space is `ABORT OUT_OF_RANGE`; a queued request leaves the queue (and `maxQueuedRequests`) when it can no longer be answered (`onCancel`, or its channel's end for a plain message).
* FORWARD: queued channels are piped to the new owner in arrival order (each OPEN sent after the previous one, later arrivals too), with the open payload unchanged except the instance (set to the new owner, so its dispatch is exact; host hint stripped); queued requests (and those arriving during the grace period) are forwarded with `forwardMessage` over one channel per slot and credential that the gate opens to `(type, to, shard)` with the credential of the request's caller as the application payload: by default the application payload of the OPEN of the channel the request arrived on, copied unchanged (an empty one stays empty; never the node's default payload, which would present a client's request to the new owner as the service's own), or the `payload` given to `serveRequest` (an application relaying requests it received elsewhere, or whose callers authenticate in-band). A parked request keeps its message, so its own channel's credential (or its `payload`) picks the forwarding channel at FORWARD. Requests with the same credential share a channel, in order; each channel is closed after 1 s without a forwarded request in flight and opened again by the next. The reply to FORWARD is sent once the queued channels are opened. After `forwardGrace`: `lifecycle.unload`, each forwarding channel closed once its requests are answered; detached channels are left to the application (their requests get `ABORT MOVED` through `serveRequest`). An ASSIGN of the same slot during the grace period (it comes back) ends the forwarding, unloads, then loads.
* No self-forwarding (the proxy's defense, for the gate): channels and requests are forwarded through `selectAndConnect` with `excludeOwnEndpoints`, so a record of the new owner that points at this node's own listener fails with `UNAVAILABLE` instead of dispatching the channel into the same gate again, a loop. A DRAIN or FORWARD whose `to` is 0 or this gate's `instance` is refused with `FAILED_PRECONDITION` and logged at WARNING; the DRAIN leaves the slot served (the naming service rolls back with RESUME), the FORWARD stops the slot as a revocation does (queue `MOVED`, tracked channels `RELOCATED`, `unload`), since the naming client dropped it on FORWARD; a slot already forwarding goes on as it was.
* RESUME (or the loss of the naming service, or the close of the naming client, while locked): the queue is served here. Revocation, `release` and `close`: the queue is refused with `MOVED` (never read), tracked channels are closed with `RELOCATED` (served), `unload`. `MOVED` always means nothing was processed. An ASSIGN for a slot already served (a re-claim after a naming service restart) changes the epoch only and answers as the first time. An ASSIGN for a slot still locked (its RESUME was lost: the naming service set it free after `resumeAttempts` and assigned it back) unlocks it as RESUME does, with the new epoch, and answers as its load did, when that epoch is the next one after the epoch it was locked with (no other owner in between, since only an assignment increments it); with a later epoch another instance owned it since and the state here is stale, so it goes as for a slot still forwarding: queue `MOVED`, `unload`, then `load`.
* `MeshNode.publishSharded`: installs `gates` as the client's slot handler (fails if another handler is set), creates the gate before registering (an ASSIGN may follow `SLOTS` at once), registers with the gate's handler, sends `SLOTS`, then `HOLDING` if given (its discards reach `lifecycle.discard` through `onDiscard`), observing the `HOLDING` at once so that its failure cannot escape while `SLOTS` is pending; the space is recorded (for `leave`) once `SLOTS` succeeds; on failure unregisters and closes the gate. `leave` (wiki "Leaving the mesh"), while connected: per managed type `SLOTS` with capacity 0 (so that the allocator does not hand the slots back), then, in a holder-only managed space, every served slot handed over in turn with `MIGRATE` `to: 0` (the new owner fetches the drained state through the leaving node's `noSlotHandler`, still up), all of it bounded by `leaveTimeout`; then `RELEASE` keeping storage of every slot still served (not handed over in time, no candidate, static or `shared` spaces, where `RELEASE` is enough since the state is in shared storage), bounded by `leaveTimeout` again; then every gate is closed. At most 64 `RELEASE`s are in flight, refilled as answers arrive, and at most 64 hand-over migrations (one per type at a time), well under the naming channel's request limit; past it the client's call queue holds the rest. The `LeaveReport` lists the slots handed over, released, and dropped (served at the start, neither handed over nor released). A node that will come back with its storage should not leave (its holder-only slots would be handed away).

### Deviations from the wiki and proposed amendments

The first four were adopted by the wiki since.

* `CLAIM` carries `u32 epoch` after the flags (the claimant's last known epoch, 0 if none), so that a restarted naming service can resolve conflicting claims "in favour of the higher epoch".
* A `HOLDING` slot outside the space is listed as to discard; `HOLDING` in a static space records holders but assigns nothing (static spaces are claimed).
* `maxSlotCount` defaults to 65536, the `userq` use case, although the wiki asks to keep `N` at or below 16384.
* Lazy shared spaces do not reassign slots of a down instance at once: lazy spaces assign only on `LOCATE`.
* FORWARD: the wiki says the open payload of a queued channel is re-sent unchanged; the gate sets the instance to the new owner's (as a proxy does, per "Proxying"), since the router had filled in the old owner's id and the new owner dispatches exactly. The application payload is unchanged.
* A router that sees `MOVED` retries once (wiki "Routing"): `openChannelToSlot` at the end client and `proxyHandler` at a frontend, both only before the first subframe (see above); after it the `MOVED` reaches the caller (or the proxy's client), which may resend since nothing was processed.
* DRAIN waits for the work in flight at most `drainTimeout`, then closes the tracked channels with `RELOCATED` and drains anyway (adopted by the wiki).

## Tests

* `test/vectors/*_vectors_test.dart`: every vector in the wiki, positive and negative, through the codecs. These files must not import `dart:io`: `dart test -P node` (equivalently `dart test -p node test/vectors/`) runs them compiled to JavaScript on Node.js, together with `test/bytes_test.dart`, the name and status tests, and `test/reconnecting_client_test.dart` (fake_async over `MemoryTransport`).
* `test/<layer>_test.dart`: unit tests over `MemoryTransport`.
* `test/outgoing_test.dart` (over `mem://`, and `ws` for endpoint normalisation): the policy of initiated connections and its precedence, `endpointPolicy` on the normalised endpoint, pooling per explicit policy, `dial`, and `credentialFor` (per endpoint, per record and from its metadata, an instance-0 record standing for a named instance, synchronous and asynchronous, the explicit payload winning, `openChannelOn`, the `MOVED` retry, the proxy unaffected), sniffing the raw OPEN payloads for the mesh credential.
* `test/peer_set_test.dart` (over `mem://` and a `StaticResolver` or a resolver the test drives): `PeerSet` membership and events (events around the initial `resolve`, resolver errors, the removal hold-down), a worker's reboot, the per-peer channel and the hooks (online only once both succeeded: a handler that throws, a rejection, `onOpen` throwing or failing, hooks that throw, fail or hang; re-opens refused or with a hanging `onOpen`), refusals, moved endpoints, endpoint fallback past an endpoint that never answers, the outgoing policy and credentials, the warnings of `watch`, `close`; the backoff schedule, the GOAWAY reconnect, a worker's GOAWAY `GOING_AWAY` on a live connection (online again at once on a new connection with the per-peer channel there, the old connection kept until the application's channel on it closes, a second GOAWAY within `maxBackoff` backing off) and the hook bound under fake_async, which also checks that no timer is left. `test/integration/fleet_consumer_test.dart`: use case 5 end to end (naming service that requires the mesh credential, a registrar for eight workers, a consumer joined to the mesh, a retired worker held then removed).
* `test/vectors/identity_vectors_test.dart`: the credential vectors (C1 HMAC, C2 Ed25519 from the RFC 8032 seeds), the proof P, NONCE and IDENT frames, scope patterns, the malformed cases; on Node.js too. `test/identity_test.dart` (core, also on Node.js): issuer, verifier (cache, rotation, failures), and the handshake over `MemoryTransport` (both directions, holder-key proofs, ordering of frames after an IDENT, a replayed holder-key IDENT refused and a replayed bearer one accepted by design, one verification per connection for an unidentified peer, expired and unknown credentials, no verifier, timeouts, protocol errors with and without a verifier). `test/identity_node_test.dart` (over `mem://` and TCP): mutual identity, `scoped`, a worker refused in both directions, bearer credentials, a credential of another authority and a forged one, holding, `requireIdentity` and `all`, `identifyFor`, a peer that never answers NONCE, a renewed credential, `PeerSet`.
* `test/naming_identity_test.dart` (over `mem://`): the naming service's scope enforcement (a worker, a consumer, admin, slot spaces defined, redefined while blank and confirmed with `claim` or `register` and not with `watch`, a sharded `MeshNode` defining its space again after a naming service restart, the connection identity winning over a wider payload credential, no credential with and without `requireCredential`, a bearer credential in the payload, a holder-key one ignored there, a host requiring named IDENTs with `expectedIdentityFor`, a client whose `WATCH` is refused), `RENEW` (the channel's own, by bytes, another identity's, a forged one, no issuer, disconnected), a payload credential renewed and one that lapses (fake time), `MeshNode`'s renewal and a revoked credential ending the session at its expiry with GOAWAY (fake time, no timer left), and `CONNECT` (a brokered channel and pooled connection, the worker refused when it pushes, `NOT_FOUND`/`PERMISSION_DENIED`/`UNAVAILABLE`/`FAILED_PRECONDITION`, an instance that never answers, `broker`'s preconditions, a dial-back after the consumer or the naming service gave up sent GOAWAY and failing the instance's dial, `PeerSet` brokering again after a loss). `test/integration/brokered_workers_test.dart` (TCP): use case 5b end to end. The receiver binding is in `test/identity_test.dart` (a live relay to a third node, a renamed receiver, the receiver moved into the intent, a mismatched receiver, a receiver without identity, `requireNamedIdent`) and `test/identity_node_test.dart` (`expectedIdentityFor`, `dial` with intent and receiver, `updateCredential`, the record `PeerSet` passes).
* `test/relay_test.dart` (over `mem://`): the relay end to end (request and reply, the instance seeing the relay's identity and the consumer's payload, the `_relay` OPEN carrying the destination's header), the relay record's identity and the consumer naming it, explicit relay endpoints with and without an identity and `expectedIdentityFor` winning, one brokered connection for two consumers, a node that can broker never relaying, no relay configured, a lost connection on either side (`UNAVAILABLE`, brokered again), `MOVED` byte for byte, `openChannelToSlot` through the relay; the refusals (an unidentified consumer after the hold and one whose OPEN overtakes its IDENT, a channel that ends while held dropped without a refusal and not counted toward the bound, `requireIdentity: false` admitting an unidentified consumer only after the hold and holding an identified one to its scopes, also when its OPEN overtakes its IDENT, a consumer identifying again while its channel is being opened, `requireNamedIdent`, every `INVALID_ARGUMENT` case including a chained `_relay`, `PERMISSION_DENIED`, the per-connection bound and `maxChannelsPerConnection: 0`, `NOT_FOUND`, `FAILED_PRECONDITION` and `allowEndpoints`, a record pointing back at the relay's own listener, a relay without `broker`, a relay without `open` refused by the worker's brokered policy); `RelayConfig` refusing a relay type that is not reserved; the warning for a relay node without `requireNamedIdent`; `PeerSet` through a relay (failover to a second relay, the worker's connection lost) and without one. `test/integration/relayed_workers_test.dart` (TCP): use case 5c end to end (two relays, a worker and two consumers that listen nowhere, strict credentials, a consumer without `open`, the relay in use stopped, the worker restarted). The `_relay` open payload vectors are in `test/vectors/address_vectors_test.dart`.
* `test/selection_test.dart` (over `mem://`): `where` filters over record metadata (also on the `MOVED` retry: a new owner it refuses ends the channel with `NOT_FOUND`), `SelectionPolicy.random` with a seeded `Random`, and `acceptAnyInstance` dispatch; the registrar pattern and metadata re-registration are in `test/naming_test.dart`.
* `test/memory_endpoint_test.dart`: `listenMemory` and `mem://` connections (dispatch, policy, pooling, GOAWAY, `UNAVAILABLE`, own endpoints, timers not starved); the tests that use `mem` endpoints check that the registry is empty at the end.
* `test/integration/*_test.dart`: real TCP and WebSocket on `127.0.0.1` port 0, and `naming_mesh_test.dart` over `mem://` endpoints too; end-to-end mesh scenarios (naming service with several services, frontend endpoint proxying a client channel to a backend instance, reconnection after the naming service restarts, a naming service that stops answering detected by the mux keep-alive through a TCP relay that freezes its connections, graceful GOAWAY).
* `test/integration/sharding/*_test.dart`: the six use cases of the wiki page "Polyverse Switchboard Sharding", one file each, built on the public API (`cluster.dart` is their shared setup, over `tcp`, `ws` or `mem`; the kv store runs over `tcp` and `mem`). Slot counts are smaller than the wiki's where noted (kv 64, chat rooms 16) to keep them fast. `test/slot_gate_test.dart` and `test/slot_routing_test.dart` cover the gate state machine and slot routing, `test/slot_gate_credential_test.dart` (over `mem://`) the credential of forwarded requests.
