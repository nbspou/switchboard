# Dart reference implementation: design and API contract

This file is the contract between the layers of the Dart package while it is
being built. The protocol itself is specified in the wiki
(`sway/wiki/switchboard/*.md`); when this file and the wiki disagree, the wiki
wins and this file is wrong.

## Package layout

```
lib/core.dart                  platform independent exports (no dart:io)
lib/switchboard.dart           everything, including dart:io transports and Switchboard
lib/src/status.dart            StatusCode, Status, SwitchboardException, ProtocolException   (done)
lib/src/name.dart              Name                                                           (done)
lib/src/bytes.dart             ByteReader, ByteWriter, hexBytes, hexString                    (done)
lib/src/transport/transport_capabilities.dart  FrameLimited, AbortableTransport, OutputBufferedTransport (optional transport capabilities)
lib/src/transport/memory_transport.dart     in-memory StreamChannel<Uint8List> pair
lib/src/transport/stream_framing.dart       stream binding wire format: StreamFraming, StreamFrameDecoder (no dart:io)
lib/src/transport/stream_transport.dart     StreamTransport, StreamTransportChannel over byte streams; TCP helpers (dart:io)
lib/src/transport/web_socket_transport.dart wraps package:web_socket_channel (binary only)
lib/src/transport/web_socket_transport_io.dart  IOWebSocketTransport: server upgrade and connect on dart:io (exported from switchboard.dart only)
lib/src/mux/mux_frame.dart     MuxFrame codec, MuxCommand, control message codecs
lib/src/mux/mux_connection.dart MuxConnection, MuxOptions, MuxLimits
lib/src/mux/mux_channel.dart   MuxChannel, MuxChannelState
lib/src/talk/talk_frame.dart   TalkFrame codec, TalkKind
lib/src/talk/talk_channel.dart TalkChannel, TalkOptions
lib/src/talk/talk_message.dart TalkMessage (incoming message with reply API)
lib/src/talk/talk_stream.dart  TalkStream (handle for an outgoing stream request)
lib/src/address/service_address.dart   ServiceAddress
lib/src/address/channel_address.dart   ChannelAddress (open payload codec)
lib/src/naming/naming_protocol.dart    ServiceRecord, codecs for REGISTER/UNREGSTR/WATCH/LOOKUP/UP/DOWN/SYNCED
lib/src/naming/naming_service.dart     NamingService (server side handler)
lib/src/naming/naming_client.dart      NamingClient (register, watch, mirrored table)
lib/src/switchboard/resolver.dart      Resolver, StaticResolver, EndpointResolver, NamingResolver
lib/src/switchboard/switchboard.dart   Switchboard (dart:io), IncomingChannel, handlers
lib/src/switchboard/proxy.dart         pipeChannels, ProxyHandler
```

Rules:

* `dart:io` only in `stream_transport.dart`, `web_socket_transport_io.dart`, `switchboard.dart`, and the TCP/WebSocket connect helpers. Everything else must compile for the web.
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
  static StreamTransportChannel fromSocket(Socket socket, {int maxFrameSize, int outputHighWaterMark, Duration closeTimeout});   // abort = socket.destroy
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
  /// compressed message can inflate far beyond its wire size.
  static Future<StreamChannel<Uint8List>> upgrade(HttpRequest request, {int maxFrameSize, bool compression = false});
  static Future<StreamChannel<Uint8List>> connect(Uri uri, {int maxFrameSize, bool compression = false});
}
```

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
  int get bufferedBytes;                    // bytes in all channel receive buffers
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

* Receiving OPEN: create the channel, add to `incoming`. If `openChannelCount >= options.maxChannels`, after our GOAWAY, or once `incoming` was cancelled, reply CLOSE (`resourceExhausted`, `goingAway`, `unavailable`) instead; the channel never surfaces and only its id is kept until the peer confirms. A second OPEN on such an id before the confirmation is a protocol error, as is OPEN on any id that is open or half closed.
* Protocol errors: send GOAWAY `protocolError` with reason, close transport, `done` completes with `protocolError`. A stream binding preamble with another version gives GOAWAY `unsupported`; a frame over the transport limit gives GOAWAY `frameTooLarge`.
* Ids: allocate incrementally from 2 or 3, step 2, skipping reserved ids, ids in use and ids awaiting a CLOSE confirmation, wrapping at 0xFFFFFFFFFFFF (or 0xFFFF if `shortIdsOnly`).
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
> * **Rejected OPENs.** A rejected OPEN (over the channel cap, after GOAWAY, or when no longer accepting channels) costs only its id until the peer's confirming CLOSE arrives; no channel state or open payload is kept. If more than a cap of such ids (default 1024) are unconfirmed, the connection ends with GOAWAY `RESOURCE_EXHAUSTED`. A second OPEN on a rejected id before its confirmation is a protocol error.
> * **Reason truncation.** Reasons in CLOSE and GOAWAY are shortened at a UTF-8 character boundary so that the status payload is at most 1024 bytes and the frame fits the limit the peer announced with LIMITS (GOAWAY must anyway, as a control payload over 1024 bytes is a protocol error).
> * **Close confirmation timeout.** If the peer does not confirm a CLOSE within a timeout (default 30 s), the channel is reported closed locally with its first status. Nothing is sent; the id stays reserved until the peer's CLOSE arrives after all or the connection ends, because the peer may still consider the channel open and its late frames must not land on a new channel with the same id. Such ids count toward the rejected-OPEN cap.
> * **Output.** A transport queues output the connection has not accepted (a peer that does not read). Above a high-water mark (default 16 MiB) it stops reading input, so a peer that sends PINGs without reading cannot make it produce unbounded PONGs; reading resumes once half has drained. While throttled this way, the peer reading our output counts as liveness for keep-alive. A close that cannot drain within the keep-alive timeout destroys the connection.

## Talk

```dart
enum TalkKind { message, streamItem, abort, extend }

class TalkFrame {
  final TalkKind kind; final Name? procedure; final int requestId; final int responseId; final bool stream; final Uint8List payload;
  Uint8List encode();
  static TalkFrame decode(Uint8List);   // throws ProtocolException for every negative vector in the wiki
}

class TalkOptions {
  final Duration requestTimeout;       // requester side, default 15 s
  final Duration replyTimeout;         // responder side, default 10 s
  final int maxIncomingRequests;       // default 1024; beyond: ABORT resourceExhausted
  final int maxOutgoingRequests;       // default 1024; beyond: throws resourceExhausted locally
}

class TalkChannel {
  TalkChannel(StreamChannel<Uint8List> channel, {TalkOptions options});   // works over MuxChannel or any StreamChannel
  StreamChannel<Uint8List> get raw;
  Stream<TalkMessage> get messages;    // incoming plain messages and requests (not responses); a channel abort from the peer is delivered as an error event (SwitchboardException with its status) and then the stream ends
  void send(String procedure, Uint8List payload);                               // plain message
  Future<TalkMessage> request(String procedure, Uint8List payload, {Duration? timeout});
  TalkStream streamRequest(String procedure, Uint8List payload, {Duration? timeout});
  void abort(Status status);           // channel abort, then close
  Future<void> close([Status status = Status.ok]);
  Future<Status> get done;
  bool get isOpen;
}

class TalkStream {
  Stream<TalkMessage> get items;       // STREAM_ITEMs; errors with SwitchboardException on abort/timeout
  Future<TalkMessage> get done;        // the final response (may carry payload and may itself be a request)
  void cancel([Status status]);        // sends cancel; items ends with cancelled error
}

class TalkMessage {
  TalkChannel get channel; TalkKind get kind;
  Name get procedure; String get procedureName;
  Uint8List get payload;
  int get requestId;                   // 0 if the peer expects no reply
  int get responseId;                  // 0 if not a response
  bool get expectsReply;               // requestId != 0
  bool get expectsStream;              // STREAM flag
  bool get isCancelled;                // peer sent cancel for requestId
  Future<void> get onCancel;           // completes when cancelled (never for non-requests)

  // Reply API; all throw SwitchboardException(failedPrecondition) if !expectsReply or already finally replied
  void reply(Uint8List payload, {String? procedure});
  Future<TalkMessage> replyRequest(Uint8List payload, {String? procedure, Duration? timeout});   // chained
  TalkStream replyStreamRequest(Uint8List payload, {String? procedure, Duration? timeout});
  void replyItem(Uint8List payload, {String? procedure});       // throws if !expectsStream
  Future<TalkMessage> replyItemRequest(Uint8List payload, {String? procedure, Duration? timeout});   // item that expects a reply
  void replyAbort(Status status);
  void extend();
}
```

Behaviour notes:

* Responses (including chained ones and stream items) are routed to the requester's `Future`/`TalkStream`, never to `messages`.
* A response for an unknown response id is ignored unless it has `HAS_REQUEST`; then reply ABORT `notFound`.
* Unknown procedure is the application's concern: the application calls `replyAbort(Status.of(StatusCode.unimplemented))`. The channel itself does not know the procedure table.
* Responder timeout: if the application has not called any reply method within `replyTimeout`, send ABORT `deadlineExceeded`, mark replied. `extend()` and `replyItem()` restart it.
* Requester timeout: restarted by items and extends; on expiry fail locally with `deadlineExceeded`, send cancel.
* `request()` returns a Future that errors with `SwitchboardException` carrying the abort status.
* Any ProtocolException while decoding or on kind rule violation: close the channel with CLOSE `protocolError` (via `raw.sink` if it is a MuxChannel, else just close) and fail outstanding requests with `protocolError`.
* When `raw.stream` ends: fail outstanding requests with `connectionLost` (or the MuxChannel's done status if available), close `messages`.
* Chaining: a reply method on a `TalkMessage` that is a stream item or a final response (received through `TalkStream`/`request`) works the same way, since those carry a requestId when the peer asked for a reply.

## Addressing

```dart
class ServiceAddress {
  const ServiceAddress(this.type, [this.instance = 0]);
  final Name type; final int instance;   // instance u48, 0 = any
  bool get isAny;
  String toString();                     // 'npc/1a2b', 'npc' when any
  static ServiceAddress parse(String);
  ==, hashCode
}

class ChannelAddress {
  const ChannelAddress({this.type, this.instance = 0, this.shard, this.host, this.payload});
  final Name? type; final int instance; final int? shard; final String? host; final Uint8List payload;
  ServiceAddress? get address;          // null when type is null
  Uint8List encode();
  static ChannelAddress decode(Uint8List openPayload);   // empty payload => default; throws ProtocolException on reserved bits or truncation
  ChannelAddress copyWith({...});
}
```

## Naming protocol codecs

```dart
class ServiceRecord { final ServiceAddress address; final List<Uri> endpoints; encode(); decode(); }
class RegisterRequest { Name type; int requestedInstance; List<Uri> endpoints; encode/decode }
class RegisterResponse { int instance; encode/decode }
class UnregisterRequest { Name type; int instance; encode/decode }   // same layout as DownEvent
class WatchRequest { Name? type; encode/decode }                      // empty payload or all-zero name = all
class ServiceEvent { final bool up; final ServiceRecord record; }    // UP carries full record, DOWN only address
Procedure names: Procedures.register ('REGISTER'), unregister ('UNREGSTR'), watch ('WATCH'), lookup ('LOOKUP'), up ('UP'), down ('DOWN'), synced ('SYNCED'). Service type: Services.naming (Name('_ns')).
```

## Switchboard (dart:io)

```dart
typedef ChannelHandler = void Function(IncomingChannel channel);

class IncomingChannel {
  MuxChannel get channel; ChannelAddress get address; MuxConnection get connection;
  TalkChannel talk({TalkOptions? options});       // wrap once; cached
  Future<void> reject(Status status);
}

abstract class Resolver {
  Future<List<ServiceRecord>> resolve(Name type);  // all known live instances of type
  Stream<ServiceEvent> get events;
  Future<void> get ready;                          // completes when the table is usable (immediately for static)
}
class StaticResolver implements Resolver { StaticResolver(List<ServiceRecord>); add/remove }
class EndpointResolver implements Resolver { EndpointResolver(Uri endpoint); }   // every type resolves to [ServiceRecord(type/0, [endpoint])]
class NamingResolver implements Resolver { NamingResolver(NamingClient); }

class Switchboard {
  Switchboard({Resolver? resolver, Uint8List? defaultPayload, MuxOptions? muxOptions, TalkOptions? talkOptions});
  Resolver? resolver; Uint8List defaultPayload;

  Future<Uri> listenWebSocket(dynamic address, int port, {String path = '/'});   // returns the bound ws:// uri (port resolved)
  Future<Uri> listenTcp(dynamic address, int port);                              // returns tcp:// uri
  List<Uri> get listeningEndpoints;

  void registerService(Name type, ChannelHandler handler, {int instance = 0});
  void unregisterService(Name type, {int instance = 0});
  set defaultService(ChannelHandler? handler);
  set catchAll(ChannelHandler? handler);

  Future<MuxChannel> openChannel(ServiceAddress address, {int? shard, Uint8List? payload});    // resolve + pool + OPEN
  Future<TalkChannel> openTalk(ServiceAddress address, {int? shard, Uint8List? payload, TalkOptions? options});
  Future<MuxChannel> openChannelAt(Uri endpoint, ChannelAddress address);                       // explicit endpoint
  Future<TalkChannel> openTalkAt(Uri endpoint, ChannelAddress address, {TalkOptions? options});
  Future<MuxConnection> connect(Uri endpoint);        // pooled; ws, wss, tcp
  Stream<MuxConnection> get connections;              // every accepted or initiated connection
  Future<void> close();                               // goAway on all connections, stop listening
}

/// Forwards every subframe and the close between two channels. Completes when both are done.
Future<void> pipeChannels(MuxChannel a, MuxChannel b);

/// A catch-all handler that resolves through [switchboard.resolver], rewrites the header
/// (strips host, fills instance) and pipes. [allow] filters by address; null allows all.
ChannelHandler proxyHandler(Switchboard switchboard, {bool Function(ChannelAddress)? allow});
```

Dispatch order is as in the wiki "Addressing" page. Resolution: `resolver.resolve(type)`, filter by instance if non-zero, pick by shard (`sorted[s % n]`) or round robin, connect to `endpoints.first` (try next on failure), OPEN with header `{type, selectedInstance, shard, payload}`.

## Naming service

```dart
class NamingService {
  NamingService();
  ChannelHandler get handler;                       // register with switchboard.registerService(Services.naming, ns.handler, instance: 1)
  Map<ServiceAddress, ServiceRecord> get table;
  Stream<ServiceEvent> get events;
  Duration heartbeat;                               // EXTEND interval on idle watches, default 5 s
}

class NamingClient {
  NamingClient(Switchboard switchboard, Uri namingEndpoint, {Duration? reconnectDelay});
  Future<int> register(Name type, List<Uri> endpoints, {int instance = 0});   // remembered for re-registration on reconnect
  Future<void> unregister(Name type, int instance);
  Future<void> get synced;                          // first SYNCED after (re)connect
  Map<ServiceAddress, ServiceRecord> get table;
  Stream<ServiceEvent> get events;
  bool get isConnected;
  Future<void> close();
}
```

## Tests

* `test/vectors/*_vectors_test.dart`: every vector in the wiki, positive and negative, through the codecs. These files must not import `dart:io`: `dart test -P node` (equivalently `dart test -p node test/vectors/`) runs them compiled to JavaScript on Node.js, together with `test/bytes_test.dart`.
* `test/<layer>_test.dart`: unit tests over `MemoryTransport`.
* `test/integration/*_test.dart`: real TCP and WebSocket on `127.0.0.1` port 0; end-to-end mesh scenarios (naming service with several services, frontend endpoint proxying a client channel to a backend instance, reconnection after the naming service restarts, graceful GOAWAY).
