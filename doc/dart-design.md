# Dart reference implementation: design and API contract

> This is the design record used while building the package: the contract between the layers, kept for the reasoning behind them. It is not the user guide. For using the package, read the README and the wiki page "Switchboard Dart Reference Implementation". Where this file and the code disagree, the code (and its doc comments) wins.

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
lib/src/naming/naming_protocol.dart    ServiceRecord, codecs for REGISTER/UNREGSTR/WATCH/LOOKUP/UP/DOWN/SYNCED and the sharding payloads, MovedStatus
lib/src/naming/naming_service.dart     NamingService (server side handler)
lib/src/naming/naming_service_slots.dart  part of naming_service.dart: slot tables, slot procedures, hand-over, allocator
lib/src/naming/naming_client.dart      NamingClient (register, watch, mirrored table)
lib/src/naming/naming_client_slots.dart   part of naming_client.dart: SlotHandler, AssignResult, instance side of sharding, slot mirror
lib/src/naming/slot_table.dart         SlotTable (read-only slot table view), SlotEvent
lib/src/naming/naming_client_io.dart   namingClientFor: a NamingClient connecting through a Switchboard (dart:io)
lib/src/naming/naming_resolver.dart    NamingResolver (resolves through a NamingClient's mirrored table)
lib/src/switchboard/resolver.dart      Resolver, SlotResolver, StaticResolver (with a configurable slot map), EndpointResolver
lib/src/switchboard/slot_key.dart      fnv1a32, slotForKey, slotForText: the reference key-to-slot function (core)
lib/src/switchboard/channel_policy.dart  ChannelPolicy, ChannelPolicies (listener policies)
lib/src/switchboard/generic_status.dart  genericStatus: rejection statuses for peers (internal, not exported)
lib/src/switchboard/incoming_channel.dart  IncomingChannel, ChannelHandler (core)
lib/src/switchboard/switchboard.dart   Switchboard (dart:io)
lib/src/switchboard/proxy.dart         pipeChannels, proxyHandler
lib/src/switchboard/slot_channel.dart  SlotChannel: a channel to a slot's owner with the MOVED retry (no dart:io; exported from switchboard.dart)
lib/src/switchboard/slot_reopen.dart   reopenAtSlotOwner: the re-resolution after MOVED shared by openChannelToSlot and proxyHandler (internal, not exported)
lib/src/switchboard/slot_gate.dart     SlotGate, SlotLifecycle, SlotGates, SlotGateState: the instance side of sharding
lib/src/switchboard/mesh.dart          MeshNode: a Switchboard joined to a naming service (dart:io)
```

Rules:

* `dart:io` only in `stream_transport.dart`, `web_socket_transport_io.dart`, `web_socket_server.dart`, `switchboard.dart`, and the TCP/WebSocket connect helpers. `proxy.dart`, `mesh.dart`, `slot_gate.dart`, `slot_channel.dart` and `naming_client_io.dart` build on `Switchboard` and are exported from `switchboard.dart` only. Everything else must compile for the web.
* The wire codecs must be correct when compiled to JavaScript, where bitwise operations are 32-bit: use `ByteReader`/`ByteWriter` (or the same split arithmetic) for `u32` and `u48`. `dart test -P node` runs the codec tests on Node.js (see `dart_test.yaml`).
* All wire codecs are pure functions over `Uint8List` and are unit tested against the wiki test vectors.
* Logging through `package:logging`, logger names `Switchboard.Mux`, `Switchboard.Talk`, `Switchboard.Router`, `Switchboard.Naming`, `Switchboard.Transport`.
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
  static Future<StreamChannel<Uint8List>> connect(Uri uri, {int maxFrameSize});   // offers subprotocol 'switchboard'
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
  /// Own handshake (RFC 6455 4.2) and frame reader on the detached socket.
  /// Not an upgrade (GET, HTTP/1.1, Upgrade: websocket, Connection: Upgrade): 426 + Upgrade: websocket;
  /// version != 13: 426 + Sec-WebSocket-Version: 13; missing or malformed key, or only other
  /// subprotocols offered: 400 (each: response sent, future fails with WebSocketException).
  /// Selects 'switchboard' when offered; never negotiates extensions (no permessage-deflate).
  /// Reader: masking required, RSV bits, reserved opcodes, fragmented or > 125 byte control frames,
  /// stray continuations: ProtocolException + close 1002; text: ProtocolException + close 1003;
  /// the sum of a message's fragments is checked against maxFrameSize (0 = none) on each fragment
  /// header, before buffering it: SwitchboardException(frameTooLarge) + close 1009; ping -> pong;
  /// client close echoed with its code, stream ends. Writer: unmasked frames; closing the sink
  /// sends close 1000. Output queue, throttling, closeTimeout and linger as for fromSocket.
  /// pingInterval: ping after a silent interval, abort after two more silent intervals.
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
}

class MuxConnection {
  MuxConnection(StreamChannel<Uint8List> transport, {required bool isInitiator, MuxOptions options});
  bool get isInitiator;
  Stream<MuxChannel> get incoming;     // channels opened by the peer, single subscription, buffered until listened; cancelling closes undelivered ones with UNAVAILABLE
  MuxChannel open(Uint8List openPayload);   // throws SwitchboardException(resourceExhausted) if no id free or peer limit hit; (failedPrecondition) if closed or peer sent GOAWAY
  Future<Duration> ping([Uint8List? payload]);
  Future<void> goAway([Status status]);     // send GOAWAY, wait for open channels up to grace, then close()
  Future<void> close();                     // close transport now; all channels end with connectionLost
  Future<Status> get done;                  // completes when the transport is closed; status: goingAway if a GOAWAY was received, the GOAWAY status we sent if we killed it (protocolError, frameTooLarge, unsupported, resourceExhausted), connectionLost otherwise
  bool get isOpen;                          // transport open and no local close started
  bool get peerGoingAway;
  MuxLimits? get peerLimits;
  int get openChannelCount;
  Iterable<MuxChannel> get channels;
  int get bufferedBytes;                    // bytes in all channel receive buffers, plus the OPEN payloads held for the peer's open channels
  int get openPayloadBytes;                 // OPEN payloads held for the peer's open channels
  bool get isReceivePaused;                 // transport reading paused by receiveHighWaterMarkBytes
  int get unconfirmedCloseCount;            // ids awaiting the peer's CLOSE without a channel
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
* Reasons sent in CLOSE and GOAWAY are shortened on a UTF-8 boundary so the status payload is at most 1024 bytes and the frame fits the peer's announced frame limit; `done` reports the status as given.
* Channel streams and `incoming` are fed from queues the mux owns and only while the listener is active and not paused, so every buffered byte and channel is accounted for.

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
> * **WebSocket messages.** The server side WebSocket transport checks the size of a message, all its fragments counted, on each fragment's header, before buffering the fragment, so a message of many fragments that are each within the limit is refused as early as a single oversized frame (close 1009, GOAWAY `FRAME_TOO_LARGE`). It never negotiates permessage-deflate.
> * **Output.** A transport queues output the connection has not accepted (a peer that does not read). Above a high-water mark (default 16 MiB) it stops reading input, so a peer that sends PINGs without reading cannot make it produce unbounded PONGs; reading resumes once half has drained. While throttled this way, the peer reading our output counts as liveness for keep-alive. A close that cannot drain within the keep-alive timeout destroys the connection.

## Talk

```dart
enum TalkKind { message, streamItem, abort, extend }

class TalkFrame {
  final TalkKind kind; final Name? procedure; final int requestId; final int responseId; final bool stream; final Uint8List payload;
  Status get status;                    // abort frames only; an empty payload is UNKNOWN
  Uint8List encode();
  static TalkFrame decode(Uint8List);   // throws ProtocolException for every negative vector in the wiki
}

class TalkOptions {
  final Duration requestTimeout;       // requester side, default 15 s
  final Duration replyTimeout;         // responder side, default 10 s
  final int maxIncomingRequests;       // default 1024; beyond: ABORT resourceExhausted
  final int maxOutgoingRequests;       // default 1024; beyond: throws resourceExhausted locally
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
  void send(String procedure, Uint8List payload);                               // plain message
  Future<TalkMessage> request(String procedure, Uint8List payload, {Duration? timeout});   // = startRequest(...).response
  TalkRequest startRequest(String procedure, Uint8List payload, {Duration? timeout, void Function()? onExtend});
  TalkStream streamRequest(String procedure, Uint8List payload, {Duration? timeout, void Function()? onExtend});
  void abort(Status status);           // channel abort, then close; ArgumentError for OK
  Future<void> close([Status status = Status.ok]);
  Future<Status> get done;
  bool get isOpen;
  int get outgoingRequestCount; int get incomingRequestCount;
}

class TalkRequest {                    // handle for a request with a single final response
  int get requestId;
  Future<TalkMessage> get response;    // never reports an unhandled error
  void cancel([Status status]);
}

class TalkStream {
  int get requestId;
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

  // Reply API; all throw SwitchboardException(failedPrecondition) if !expectsReply or already finally replied
  void reply(Uint8List payload, {String? procedure});
  Future<TalkMessage> replyRequest(Uint8List payload, {String? procedure, Duration? timeout});   // chained; = startReplyRequest(...).response
  TalkRequest startReplyRequest(Uint8List payload, {String? procedure, Duration? timeout, void Function()? onExtend});
  TalkStream replyStreamRequest(Uint8List payload, {String? procedure, Duration? timeout, void Function()? onExtend});
  void replyItem(Uint8List payload, {String? procedure});       // throws if !expectsStream
  Future<TalkMessage> replyItemRequest(Uint8List payload, {String? procedure, Duration? timeout});   // item that expects a reply
  TalkRequest startReplyItemRequest(Uint8List payload, {String? procedure, Duration? timeout, void Function()? onExtend});
  TalkStream replyItemStreamRequest(Uint8List payload, {String? procedure, Duration? timeout, void Function()? onExtend});   // item that is a stream request
  void replyAbort(Status status);      // ArgumentError for OK
  void extend();
  void setReplyTimeout(Duration? timeout);   // per-request responder timeout: null = channel default, zero = none
}

/// Message chain proxying (wiki "Switchboard Proxying"). Completes when the exchange,
/// including requests forwarded on its behalf, has ended; never fails.
Future<void> forwardMessage(TalkMessage incoming, TalkChannel target);
```

Behaviour notes:

* Responses (including chained ones and stream items) are routed to the requester's `Future`/`TalkRequest`/`TalkStream`, never to `messages`.
* A response for an unknown response id is ignored unless it has `HAS_REQUEST`; then reply ABORT `notFound`.
* Unknown procedure is the application's concern: the application calls `replyAbort(Status.of(StatusCode.unimplemented))`. The channel itself does not know the procedure table.
* Responder timeout: if the application has not called any reply method within `replyTimeout` (or the per-request `setReplyTimeout` value), send ABORT `deadlineExceeded`, mark replied and cancelled. `extend()` and `replyItem()` restart it.
* Requester timeout: restarted by items and extends; on expiry fail locally with `deadlineExceeded`, send cancel. `onExtend` is called synchronously for every EXTEND.
* Failures carry a `TalkAbortException` when the peer sent ABORT (abort response or channel abort), a plain `SwitchboardException` for local causes (own timeout, own cancel, channel lost or closed, protocol error, local limit). An empty or OK abort status reads as `unknown`.
* Error events on `messages` and `TalkStream.items` without an `onError` handler are logged at FINE, never reported as unhandled; futures from `request`, `replyRequest`, `replyItemRequest` and `TalkRequest.response` are pre-ignored.
* Peer cancel: the channel sends ABORT `cancelled` at once, the request is finished (later reply calls throw `failedPrecondition`), then `isCancelled`/`onCancel` fire.
* Our cancel: the id stays reserved until the peer's final arrives or the requester timeout expires (the channel default if the request has none). Cancelling the `items` subscription of an outstanding `TalkStream` cancels the request.
* Requests buffered in `messages` and never delivered when its subscription is cancelled are answered ABORT `unimplemented`; item requests buffered in `items` are answered ABORT `cancelled`.
* Outgoing requests are registered (and their timer armed) before the frame is sent, and rolled back if the send throws, so a synchronous transport cannot lose a synchronous response.
* `connectionLost` is never sent: aborts, cancels and the close of a `StatusClosable` raw channel carry `unavailable` instead.
* Any ProtocolException while decoding or on kind rule violation: close the channel with CLOSE `protocolError` (via `raw.sink` if it is a MuxChannel, else just close) and fail outstanding requests with `protocolError`.
* When `raw.stream` ends: fail outstanding requests with `connectionLost` (or the MuxChannel's done status if available), close `messages`. A `close()` racing the end waits for that status.
* Chaining: a reply method on a `TalkMessage` that is a stream item or a final response (received through `TalkStream`/`request`) works the same way, since those carry a requestId when the peer asked for a reply.
* Forwarding: `forwardMessage` sends a plain message as a plain message and a request as a new request on `target` (same procedure, payload, STREAM flag), then relays items, EXTEND, the final, and aborts back. Items or finals that are themselves requests are forwarded the other way and their answers relayed back, recursively. A remote abort passes through with its status; any local failure of the forwarded request (including a channel abort) is answered `unavailable`. A cancel of the incoming request, or loss of its channel, cancels the forwarded one. Procedure names pass through as `Name`s (lossless); the proxy disables its responder timeout for forwarded requests and sets no requester timeout, so the real peers' timeouts apply end to end.

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

## Naming protocol codecs

```dart
class ServiceRecord { final ServiceAddress address; final List<Uri> endpoints; encode(); decode();
  static void checkEndpoint(Uri endpoint); }                          // ArgumentError unless it has a scheme, fits 255 bytes, and reparses to an equal Uri
class RegisterRequest { Name type; int requestedInstance; List<Uri> endpoints; encode/decode }
class RegisterResponse { int instance; encode/decode }
class UnregisterRequest { Name type; int instance; encode/decode }   // same layout as DownEvent
class WatchRequest { Name? type; encode/decode }                      // empty payload or all-zero name = all
class ServiceEvent { final bool up; final ServiceRecord record; }    // UP carries full record, DOWN only address
Procedure names: Procedures.register ('REGISTER'), unregister ('UNREGSTR'), watch ('WATCH'), lookup ('LOOKUP'), up ('UP'), down ('DOWN'), synced ('SYNCED'). Service type: Services.naming (Name('_ns')).

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
class MovedStatus { ServiceAddress? owner; int? epoch; String reason; Status toStatus();
  static String format(ServiceAddress? owner, [int? epoch]);          // 'userq/1a2b 7', '' when unknown
  static MovedStatus parse(String reason); static MovedStatus fromStatus(Status); }   // never throws; malformed = unknown
```

Sharding decoders throw `ProtocolException` on truncation, an unknown mode, state or phase, and a slot list longer than the payload; trailing bytes are ignored. Encoders throw `RangeError` for values outside `u32`/`u48`. Vectors: `doc/sharding-vectors.md`, `test/vectors/sharding_vectors_test.dart`.

## Switchboard (dart:io)

```dart
typedef ChannelHandler = FutureOr<void> Function(IncomingChannel channel);   // a throw or a failed future closes the channel with INTERNAL

/// Listener policy (channel_policy.dart, core): evaluated for every channel on a connection
/// accepted by the listener, after the header is parsed and before any handler (local service,
/// default service, catch-all). Refused or throwing: CLOSE PERMISSION_DENIED 'permission denied'.
typedef ChannelPolicy = bool Function(ChannelAddress address, MuxConnection connection);
abstract final class ChannelPolicies {
  static bool allowAll(ChannelAddress, MuxConnection);
  static bool denyReserved(ChannelAddress, MuxConnection);           // refuses `_` types, allows the rest and untyped
  static ChannelPolicy allowTypes(Set<Name> types, {bool untyped = false});   // only these types (a listed reserved type is allowed)
}

class IncomingChannel {
  MuxChannel get channel; ChannelAddress get address; MuxConnection get connection;
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
class NamingResolver implements SlotResolver { NamingResolver(NamingClient client, {Duration resolveTimeout = 5 s}); }   // naming_resolver.dart; locateSlot = client.locate

int fnv1a32(List<int> bytes); int slotForKey(List<int> key, int count); int slotForText(String key, int count);   // slot_key.dart (core)

class Switchboard {
  Switchboard({Resolver? resolver, Uint8List? defaultPayload, MuxOptions? muxOptions, TalkOptions? talkOptions,
      Duration connectTimeout = 10 s, bool allowHostHint = false, int maxConnectionsPerEndpoint = 4,
      Duration slotRefreshTimeout = 5 s});
  Resolver? resolver; Uint8List defaultPayload;

  // WebSocket listeners use WebSocketServerTransport, and dials IOWebSocketTransport.connect (no
  // compression offered), both with maxFrameSize = muxOptions.maxFrameSize (0: the 1 MiB transport default).
  // policy: null allows everything (internal listeners only); internet-facing listeners MUST set one
  // that refuses reserved types. Connections this node initiates (connect) have no policy.
  Future<Uri> listenWebSocket(Object address, int port, {String path = '/', ChannelPolicy? policy});   // returns the bound ws:// uri (port resolved)
  Future<Uri> listenTcp(Object address, int port, {ChannelPolicy? policy});                              // returns tcp:// uri
  List<Uri> get listeningEndpoints;
  bool isOwnEndpoint(Uri endpoint);   // scheme, port, ws path; host = bound address, localhost, and for wildcard binds the loopback addresses, host name and interface addresses

  void registerService(Name type, ChannelHandler handler, {int instance = 0});
  void unregisterService(Name type, {int instance = 0});
  set defaultService(ChannelHandler? handler);
  set catchAll(ChannelHandler? handler);

  Future<MuxChannel> openChannel(ServiceAddress address, {int? shard, Uint8List? payload});    // resolve + pool + OPEN
  Future<TalkChannel> openTalk(ServiceAddress address, {int? shard, Uint8List? payload, TalkOptions? options});
  Future<MuxChannel> openChannelAt(Uri endpoint, ChannelAddress address);                       // explicit endpoint
  Future<TalkChannel> openTalkAt(Uri endpoint, ChannelAddress address, {TalkOptions? options});
  Future<(ServiceRecord, MuxConnection)> selectAndConnect(ServiceAddress address, {int? shard, Resolver? resolver, bool excludeOwnEndpoints = false});   // slot routing: see "Sharding"
  Future<SlotChannel> openChannelToSlot(Name type, int slot, {Uint8List? payload});            // openChannel(type/0, shard: slot) + one MOVED retry
  Future<TalkChannel> openTalkToSlot(Name type, int slot, {Uint8List? payload, TalkOptions? options});
  Future<ServiceAddress> resolveSlotOwner(Name type, int slot, {bool refresh = false});          // for callers handling MOVED themselves
  Future<MuxConnection> connect(Uri endpoint);        // pooled; ws, wss, tcp; a further connection to the endpoint only when every pooled one is at its peer's announced maxChannels, up to maxConnectionsPerEndpoint
  Stream<MuxConnection> get connections;              // every accepted or initiated connection
  Future<void> close();                               // stop listening, goAway on all connections; connections established meanwhile (upgrades and dials in progress, at most connectTimeout) get GOAWAY at once and are waited for too
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
/// at the new owner, unseen by the client (the retry counts as the same channel).
ChannelHandler proxyHandler(Switchboard switchboard, {bool Function(ChannelAddress)? allow, Resolver? resolver, int maxChannelsPerConnection = 256});

/// slot_channel.dart: a StreamChannel<Uint8List> and StatusClosable forwarding to the current MuxChannel.
class SlotChannel { Name type; int slot; MuxChannel get channel; bool get retried; bool get canSend;
  Stream<Uint8List> stream; StreamSink<Uint8List> sink; Future<Status> done; void send(Uint8List); Future<void> close([Status]); }
```

Rejections sent to peers by the node and the proxy (policy refusals, no handler, resolution and connection failures, per-client limit) carry the status code and a generic reason only (`'permission denied'`, `'not found'`, `'unavailable'`, ...); the details (instance ids, endpoints, resolver state) are logged locally at FINE or INFO. Statuses a backend sends pass through the proxy unchanged; a lost connection on one side reaches the other as `UNAVAILABLE` `'connection lost'`.

Dispatch order is as in the wiki "Addressing" page, after the listener policy. Resolution: `resolver.resolve(type)`, filter by instance if non-zero, pick by shard (the slot's owner for a type with a slot table, see "Sharding"; otherwise `sorted[s % n]`) or round robin, connect to `endpoints.first` (try next on failure), OPEN with header `{type, selectedInstance, shard, payload}`.

## Naming service

```dart
class NamingService {
  NamingService({Duration heartbeat, Duration assignmentHold, Duration holderGrace, Duration handoverTimeout, int maxSlotCount,
      Duration assignBackoff, Duration assignBackoffMax, Duration holdingSettle});
  ChannelHandler get handler;                       // register with switchboard.registerService(Services.naming, ns.handler, instance: 1)
  void serve(TalkChannel channel);                  // StateError (and nothing kept) if its messages are already listened to
  Map<ServiceAddress, ServiceRecord> get table;
  Stream<ServiceEvent> get events;
  Duration heartbeat;                               // EXTEND interval on idle watches, default 4 s (see below)
  Duration assignmentHold;                          // REGISTER for any id held this long after construction, default 2 s; slot assignment waits too
  Duration holderGrace;                             // holder-only slot waits this long for its holder, default 5 min
  Duration handoverTimeout;                         // requester timeout of ASSIGN/DRAIN/FORWARD/RESUME, EXTEND restarts it, default 60 s
  int maxSlotCount;                                 // larger SLOTS refused with OUT_OF_RANGE, default 65536
  Duration assignBackoff;                           // an instance that failed ASSIGN of a slot is not offered it again for this long, default 200 ms, doubling
  Duration assignBackoffMax;                        // ... up to this, default 10 s; reset when it accepts the slot
  Duration holdingSettle;                           // after SLOTS with capacity, free slots without holder wait until SLOTS/HOLDING/CLAIM are quiet this long, default 1 s (0: off)
  bool get isHoldingAssignments;
  Map<Name, SlotTable> get slotTables;              // read-only, live
  SlotTable? slotTable(Name type);
  Stream<SlotItem> get slotEvents;                  // every SLOT item published, in order
}

class SlotTable { SlotSpace space; Map<int, SlotEntry> entries; Name type; int count;
  SlotEntry operator [](int slot); Set<int> get owners; List<int> slotsOf(int instance); }
class SlotEvent { Name type; int slot; SlotEntry entry; SlotEntry previous; }

class NamingClient {
  NamingClient(TalkConnector connect, {Duration reconnectDelay, Duration? watchTimeout});   // transport independent
  Future<void> start();
  Future<int> register(Name type, List<Uri> endpoints, {int instance = 0, void Function(int)? onAssigned});   // remembered for re-registration on reconnect; onAssigned on every new id
  Future<void> unregister(Name type, int instance);
  Future<void> get synced;                          // SYNCED of the current session; replaced after a loss
  bool get isSynced;                                // SYNCED on the current session
  bool get hasSynced;                               // SYNCED on any session so far; never reset
  Future<void> get firstSynced;                     // one-shot: the first SYNCED ever; fails with CANCELLED on close
  Map<ServiceAddress, ServiceRecord> get table;
  Stream<ServiceEvent> get events;
  bool get isConnected;
  Future<void> close();

  // Sharding (constructor also takes Duration slotExtendInterval, default 4 s)
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
abstract class SlotHandler {
  Future<AssignResult> onAssign(AssignRequest request);
  Future<void> onDrain(DrainRequest request);
  Future<void> onForward(ForwardRequest request);
  Future<void> onResume(ResumeRequest request);
  Future<void> onRevoke(Name type, int slot) async {}   // stop serving: re-claim refused, or ASSIGN not confirmed
}
// NamingResolver: SlotTable? slotTable(type); SlotEntry? slotOwner(type, slot); Set<int> slotOwners(type); Stream<SlotEvent> slotEvents

// dart:io glue
NamingClient namingClientFor(Switchboard switchboard, Uri namingEndpoint, {Duration reconnectDelay, Duration? watchTimeout, TalkOptions? talkOptions});   // openTalkAt(endpoint, _ns)

class MeshNode {
  factory MeshNode.join(Switchboard switchboard, Uri namingEndpoint, {Duration reconnectDelay, Duration? watchTimeout, Duration resolveTimeout, TalkOptions? talkOptions});   // sets switchboard.resolver = NamingResolver(client), starts the client
  Switchboard switchboard; NamingClient client; NamingResolver resolver;
  Future<void> get synced;
  Iterable<ServiceAddress> get published;
  Future<int> publish(Name type, ChannelHandler handler, {int instance = 0, List<Uri>? endpoints});   // register, then registerService(type, handler, instance: assigned); follows id changes
  Future<void> unpublish(Name type, int instance);
  Future<void> leave();                             // give up slots (below), close resolver and client, unregister local handlers; call before switchboard.close()

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

// slot_gate.dart
abstract class SlotLifecycle {                      // extend it; the gate attaches itself
  SlotGate get gate;
  Future<AssignResult> load(int slot, {required int epoch, required int holder, required bool shared});
  Future<void> drain(int slot, {required int epoch, required int to}) async {}
  Future<void> unload(int slot) async {}
  void serve(IncomingChannel channel, int slot);
  void discard(List<int> slots) {}                  // HOLDING answered "no longer yours"
}
enum SlotGateState { loading, serving, locked, forwarding }
class SlotGate implements SlotHandler {
  SlotGate(Switchboard switchboard, NamingClient client, Name type, {required SlotLifecycle lifecycle,
      Duration forwardGrace = 30 s, Duration drainTimeout = 30 s, int maxQueuedChannels = 1024,
      int maxQueuedRequests = 1024, bool trackChannels = true, ChannelHandler? noSlotHandler, int instance = 0});
  ChannelHandler get handler; ChannelHandler? noSlotHandler; int instance;
  Map<int, int> get servedSlots; SlotGateState? stateOf(int slot); bool serves(int slot);
  Status movedStatus(int slot); void detach(IncomingChannel channel);
  Future<void> serveRequest(TalkMessage message, int slot, FutureOr<void> Function(TalkMessage) handler);
  Future<int> claim(int slot, {bool holding = false}); Future<void> release(int slot, {bool keepStorage = false});
  Future<void> close();
}
class SlotGates extends SlotHandler { Map<Name, SlotGate> gates; SlotGate? operator [](Name); void add(SlotGate); SlotGate? remove(Name); }
```

Behaviour notes:

* What the service accepts, every watcher can decode. Endpoints are checked with `ServiceRecord.checkEndpoint` by the decoders (`ProtocolException`), by the service for `REGISTER` and `registerLocal` (`INVALID_ARGUMENT`) and by `NamingClient.register` (`ArgumentError`): a scheme, at most 255 bytes once normalised, and the normalised text parses back to an equal `Uri` (checked both ways: `Uri ==` compares text or components depending on the representation, so it is not symmetric).
* Heartbeat: the wiki asks for `EXTEND` at least every 5 s. Timers fire late, never early, so the default is 4 s, not 5 s.
* Resolution (`NamingResolver`) depends on `client.hasSynced` only: before the first `SYNCED` ever, `resolve` waits for `firstSynced`, bounded by `resolveTimeout`, then fails `UNAVAILABLE`; after it, the table is served even while stale, whether or not anything was resolved before the loss and whenever the resolver was created. `ready` is `client.firstSynced`: it completes once the table has been synced at least once, does not reset on a loss, and fails with `CANCELLED` if the client is closed first. `Switchboard.selectAndConnect` calls `resolve` only, never `ready`, because `ready` has no bound.
* Indeterminate outcomes: a `REGISTER` or `UNREGSTR` that times out (`DEADLINE_EXCEEDED`) or gets an unreadable answer may or may not have taken effect. The client fails the caller's future and drops the channel, so the naming service discards everything owned by it, and the reconnect registers the remembered set again. A refused `UNREGSTR` (other than `NOT_FOUND`) drops the channel too. A channel lost while a request is in flight is not indeterminate: the record died with the channel, and the registration is made again after the reconnect (its future completes then).
* A re-registration refused on a healthy channel (anything but `ALREADY_EXISTS`, which moves to a new id) is retried on the same channel every `reconnectDelay`, without disturbing the client's other registrations.
* At most one remembered registration per `type/instance`: registering an explicit id again supersedes the earlier registration whether or not it completed (its future completes like the new one's; its late answer is ignored), and `unregister` removes every match.
* Ids after a naming service restart: the new service starts assigning at 1 again and knows nothing of the old ids. Surviving clients reconnect and ask for the ids they had (those first, before fresh registrations), but a fresh registration that reaches the new service first can be assigned one of them; the survivor then gets `ALREADY_EXISTS`, takes a new id and reports it through `onAssigned` (`MeshNode` moves its local dispatch), while addresses other services kept for the old id now resolve to the newcomer (same type) or to nothing. Mitigation: for `assignmentHold` after construction (default 2 s) the service answers `REGISTER` with instance 0 only once the hold is over (in arrival order, kept alive with `EXTEND` every `heartbeat`; one the requester cancels meanwhile is answered `CANCELLED` and never registered); requests for a given id, `registerLocal` and everything else are served at once. The client does not wait for held registrations before starting its `WATCH`. Survivors that take longer than the hold to come back can still lose their ids.

## Sharding

Behaviour notes (wiki "Switchboard Sharding"):

* Identity: the instance serving the slots of a type on a channel is that channel's registration of the type. A channel with several registrations of a sharded type gets `FAILED_PRECONDITION` for the slot procedures (the requests to instances carry no instance id). `SLOTS` without any registration of the type defines or confirms the space only (a router or operator tool).
* Capacity: `null` until the instance sends `SLOTS`, 0 takes no slots, 1 or more makes it a candidate of the allocator and of `LOCATE`. `CLAIM` works whatever the capacity, in both modes. Slots owned by instances without capacity are left out of rebalancing.
* Epochs increase only when an owner is assigned (`ASSIGN`, by claim, locate, allocator or migration), wrapping to 1. Release and loss keep the epoch; the next owner gets epoch + 1. `RESUME` carries the unchanged epoch.
* Holder of an assigned slot: the new owner, unless it answers "not holding", which keeps the previous holder. A claim with the holding flag on a free slot with holder 0 makes the claimant the holder; a known holder wins over the flag.
* `RELEASE` of a slot being assigned to the caller waits for that `ASSIGN`; a migrating slot is `FAILED_PRECONDITION`. `PERMISSION_DENIED` otherwise unless the caller owns it.
* Allocator (managed spaces), run in a microtask after every change: (1) free slots whose holder is a candidate go back to it; (2) eager spaces assign the other free slots to the candidate with the most spare share (`capacity * (assigned + 1) - load * totalCapacity`, ties to the lower id), at most 16 `ASSIGN`s in flight per space; a holder that is registered with capacity 0 has its slots assigned elsewhere with `holder` set to it; a holder that is down (or registered but has not sent `SLOTS`) makes a holder-only slot wait for `holderGrace`, then the holder is cleared; shared spaces reassign at once with `holder` and the shared flag; (3) when nothing is in flight, one rebalancing migration from the most over-share candidate to the most under-share one, if that one is short by a full slot, lowest slot first. Lazy spaces assign only on `LOCATE` (and give slots back to their holders), but still rebalance.
* `ASSIGN` backoff, per (type, slot, instance): an instance that fails an `ASSIGN` (refuses it, typically `UNAVAILABLE` until it is ready, or times out) is not offered that slot again by the allocator, `LOCATE` or a rebalancing migration for `assignBackoff` (200 ms), doubled at each further failure up to `assignBackoffMax` (10 s), and from `assignBackoff` again once it accepts the slot; an instance that goes down loses its backoffs. Meanwhile the slot goes to the best candidate not in its backoff (a holder in its backoff is passed over too, the new owner fetching from it); with none, it stays free and the end of the first backoff (its own timer) runs the allocator again. Rebalancing gives no owned slot to an instance in its backoff for any slot of the space (a failed hand-over costs the old owner a `DRAIN` and a `RESUME`). `LOCATE` tries the candidates in turn; once all are in their backoff it waits (kept alive with `EXTEND`) for one to end or the slot to change, at most `handoverTimeout` from then (unbounded if 0), then fails `UNAVAILABLE` with the last refusal. `CLAIM` and `MIGRATE` to a given instance are not held back, but their failures and successes count. Not covered: a `DRAIN` refused by the old owner of a rebalancing migration (retried at once).
* Settle window after `SLOTS` (eager managed spaces; restart recovery): holders are only re-learned from `HOLDING`, which follows `SLOTS`. A `SLOTS` that gives an instance capacity opens a window in which the allocator assigns no free slot with holder 0 of that space; every `SLOTS`, `HOLDING` or `CLAIM` of the type extends it to `holdingSettle` (1 s) after that arrival, at most `max(holdingSettle, 5 * assignmentHold)` after it opened. Slots with a known holder still go back to it, `CLAIM` is served, and `LOCATE` assigns (an explicit demand), holder first as always.
* Hand-over: as in the wiki step by step; DRAIN and FORWARD go to `from`, ASSIGN to `to` with `holder` = the slot's holder (normally `from`). Requests to an instance fail at once when its registration goes away. One migration per space at a time; the allocator's go through the same queue. A queued `MIGRATE` is validated again when it starts; one whose requester cancelled is dropped; a running one completes regardless. `MIGRATE` has no responder timeout; it is kept alive with `EXTEND` every heartbeat, like every request waiting on an `ASSIGN` or the hold.
* Assignment hold: `CLAIM`s are collected and resolved when it ends, in order of claimed epoch (descending) then arrival: the first claim of a slot proceeds, the others then see it owned (`ALREADY_EXISTS`) unless its `ASSIGN` failed. `HOLDING` is answered after the claims; `LOCATE` of a free managed slot, the allocator and migrations wait.
* Client: `ASSIGN`/`DRAIN`/`FORWARD`/`RESUME` handler calls run with the responder timeout off and `EXTEND` every `slotExtendInterval`. A served slot is recorded before the `ASSIGN` reply; if the reply cannot be sent, `onRevoke` (unless it was already served). After a reconnect, per type once its registration is back: `SLOTS`, `HOLDING` (declared slots plus served slots it holds), then `CLAIM` of every served slot with the holding flag and last epoch, at most 256 in flight, all sent in the same turn; `HOLDING` goes before `SLOTS` when the mirror is synced on that channel and shows the space defined (a registration completing on a synced channel), since a restarted naming service that does not know the space yet would refuse it. A refused re-claim on a live channel calls `onRevoke`. When the channel is lost, every slot locked by `DRAIN` gets `onResume` once its `onDrain` is done.

Routing and the instance side (stage B):

* Slot routing in `selectAndConnect`: only when the address names any instance, a shard is given and the resolver is a `SlotResolver` with a table for the type. Owner from the table (`from` while migrating); no owner: managed space `locateSlot`, static space `UNAVAILABLE`; a slot outside the space `OUT_OF_RANGE`; the owner missing from the service table or unreachable `UNAVAILABLE`, never another instance. The header carries the owner's id. `proxyHandler` gets slot routing through `selectAndConnect`. For a channel routed by a slot table it pipes the client to a `SlotChannel` (below), so a backend's CLOSE `MOVED` before any subframe was piped either way is retried once at the new owner without the client noticing, the re-resolution being the same as `openChannelToSlot`'s (`reopenAtSlotOwner`, with the proxy's resolver, never towards the node's own listeners); after the first subframe the `MOVED` is forwarded to the client, which retries itself. The retry counts as the same channel for `maxChannelsPerConnection`.
* `openChannelToSlot` / `openTalkToSlot`: a mux OPEN has no acknowledgement, so the retry is decided on the channel's end. A `SlotChannel` forwards to the current `MuxChannel`; when it ends with `MOVED` and nothing was sent on it or received from it, it is replaced once: to the owner the reason names, unless the table has an entry with a higher epoch; with no owner named, through `locateSlot` (bounded by `slotRefreshTimeout`), in either mode; through a resolver without tables, the same address again. Nowhere else to go: the channel ends with the `MOVED`. Subframes sent while the replacement opens are held and sent on it. After the first subframe either way, `MOVED` is surfaced: an instance that loses a slot closes the channels it was serving with `MOVED`, possibly after acting on what they carried, so a replay could apply it twice. Server-first protocols (greeting, snapshot) therefore always get the retry; a Talk client sending at once retries at its level.
* `SlotGate`, per sharded type per node, is the client's `SlotHandler` (through `SlotGates` when a client serves several types) and the type's `ChannelHandler`. Per slot: `loading` (ASSIGN running; channels queue), `serving`, `locked` (DRAIN; channels queue), `forwarding` (after FORWARD for `forwardGrace`; channels piped to the new owner, requests forwarded). Not held: `MOVED` naming the mirror's owner (the new owner while forwarding; empty when the mirror names this instance or nobody). No shard: `noSlotHandler` (state transfer between instances), else `INVALID_ARGUMENT`; outside the space: `OUT_OF_RANGE`. Queued channels are never read (the mux buffers them), at most `maxQueuedChannels` over all slots (`UNAVAILABLE` beyond).
* Work in flight: with `trackChannels` (default) a served channel counts until it ends, unless `detach`ed (a long-lived channel); requests run through `serveRequest` count until their handler completes. DRAIN locks, waits until the slot has no work in flight (at most `drainTimeout`, then logs and goes on), then calls `lifecycle.drain`. A DRAIN for a slot not served is `FAILED_PRECONDITION`.
* FORWARD: queued channels are piped to the new owner in arrival order (each OPEN sent after the previous one, later arrivals too), with the open payload unchanged except the instance (set to the new owner, so its dispatch is exact; host hint stripped); queued requests are forwarded with `forwardMessage` over one channel per slot that the gate opens to `(type, to, shard)` with the node's default payload. The reply to FORWARD is sent once the queued channels are opened. After `forwardGrace`: `lifecycle.unload`, the forwarding channel closed once its requests are answered, tracked channels still open closed with `MOVED`; detached channels are left to the application (their requests get `ABORT MOVED` through `serveRequest`). An ASSIGN of the same slot during the grace period (it comes back) ends the forwarding, unloads, then loads.
* RESUME (or the loss of the naming service while locked): the queue is served here. Revocation, `release` and `close`: the queue is refused with `MOVED`, tracked channels are closed with `MOVED`, `unload`. An ASSIGN for a slot already served (a re-claim after a naming service restart) changes the epoch only and answers as the first time.
* `MeshNode.publishSharded`: installs `gates` as the client's slot handler (fails if another handler is set), creates the gate before registering (an ASSIGN may follow `SLOTS` at once), registers with the gate's handler, sends `SLOTS`, then `HOLDING` if given and passes the discard list to `lifecycle.discard`; on failure unregisters. `leave`: while connected, per sharded type `SLOTS` with capacity 0 (managed spaces, so that the allocator does not hand the slots back) and `RELEASE` keeping storage of every served slot, bounded by `leaveTimeout`; then every gate is closed. A node that will come back with its storage should not leave (its holder-only slots would be reassigned with a fetch from it).

### Deviations from the wiki and proposed amendments

The first four were adopted by the wiki since.

* `CLAIM` carries `u32 epoch` after the flags (the claimant's last known epoch, 0 if none), so that a restarted naming service can resolve conflicting claims "in favour of the higher epoch".
* A `HOLDING` slot outside the space is listed as to discard; `HOLDING` in a static space records holders but assigns nothing (static spaces are claimed).
* `maxSlotCount` defaults to 65536, the `userq` use case, although the wiki asks to keep `N` at or below 16384.
* Lazy shared spaces do not reassign slots of a down instance at once: lazy spaces assign only on `LOCATE`.
* FORWARD: the wiki says the open payload of a queued channel is re-sent unchanged; the gate sets the instance to the new owner's (as a proxy does, per "Proxying"), since the router had filled in the old owner's id and the new owner dispatches exactly. The application payload is unchanged.
* A router that sees `MOVED` retries once (wiki "Routing"): `openChannelToSlot` at the end client and `proxyHandler` at a frontend, both only before the first subframe (see above); after it the `MOVED` reaches the caller (or the proxy's client).
* DRAIN waits for the work in flight at most `drainTimeout` (the wiki has no bound), then drains anyway.

## Tests

* `test/vectors/*_vectors_test.dart`: every vector in the wiki, positive and negative, through the codecs. These files must not import `dart:io`: `dart test -P node` (equivalently `dart test -p node test/vectors/`) runs them compiled to JavaScript on Node.js, together with `test/bytes_test.dart`.
* `test/<layer>_test.dart`: unit tests over `MemoryTransport`.
* `test/integration/*_test.dart`: real TCP and WebSocket on `127.0.0.1` port 0; end-to-end mesh scenarios (naming service with several services, frontend endpoint proxying a client channel to a backend instance, reconnection after the naming service restarts, graceful GOAWAY).
* `test/integration/sharding/*_test.dart`: the six use cases of the wiki page "Switchboard Sharding", one file each, built on the public API (`cluster.dart` is their shared setup). Slot counts are smaller than the wiki's where noted (kv 64, chat rooms 16) to keep them fast. `test/slot_gate_test.dart` and `test/slot_routing_test.dart` cover the gate state machine and slot routing.
