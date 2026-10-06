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
lib/src/status_closable.dart   StatusClosable (channels closable with a status; MuxChannel)
lib/src/name.dart              Name                                                           (done)
lib/src/bytes.dart             ByteReader, ByteWriter, hexBytes, hexString                    (done)
lib/src/transport/memory_transport.dart     in-memory StreamChannel<Uint8List> pair
lib/src/transport/stream_transport.dart     preamble + u32 length framing over byte streams; TCP helpers (dart:io)
lib/src/transport/web_socket_transport.dart wraps package:web_socket_channel (binary only)
lib/src/mux/mux_frame.dart     MuxFrame codec, MuxCommand, control message codecs
lib/src/mux/mux_connection.dart MuxConnection, MuxOptions, MuxLimits
lib/src/mux/mux_channel.dart   MuxChannel, MuxChannelState
lib/src/talk/talk_frame.dart   TalkFrame codec, TalkKind
lib/src/talk/talk_channel.dart TalkChannel, TalkOptions, TalkAbortException
lib/src/talk/talk_forward.dart forwardMessage (message chain proxying; part of talk_channel.dart)
lib/src/talk/talk_message.dart TalkMessage (incoming message with reply API)
lib/src/talk/talk_request.dart TalkRequest (handle for an outgoing single-response request)
lib/src/talk/talk_stream.dart  TalkStream (handle for an outgoing stream request)
lib/src/address/service_address.dart   ServiceAddress
lib/src/address/channel_address.dart   ChannelAddress (open payload codec)
lib/src/naming/naming_protocol.dart    ServiceRecord, codecs for REGISTER/UNREGSTR/WATCH/LOOKUP/UP/DOWN/SYNCED
lib/src/naming/naming_service.dart     NamingService (server side handler)
lib/src/naming/naming_client.dart      NamingClient (register, watch, mirrored table)
lib/src/naming/naming_client_io.dart   namingClientFor: a NamingClient connecting through a Switchboard (dart:io)
lib/src/switchboard/resolver.dart      Resolver, StaticResolver, EndpointResolver, NamingResolver
lib/src/switchboard/switchboard.dart   Switchboard (dart:io), IncomingChannel, handlers
lib/src/switchboard/proxy.dart         pipeChannels, ProxyHandler
lib/src/switchboard/mesh.dart          MeshNode: a Switchboard joined to a naming service (dart:io)
```

Rules:

* `dart:io` only in `stream_transport.dart`, `switchboard.dart`, and the TCP/WebSocket connect helpers. Everything else must compile for the web.
* All wire codecs are pure functions over `Uint8List` and are unit tested against the wiki test vectors.
* Logging through `package:logging`, logger names `Switchboard.Mux`, `Switchboard.Talk`, `Switchboard.Router`, `Switchboard.Naming`, `Switchboard.Transport`.
* No `print`. No fixed ports in tests (bind to port 0). No multi-second sleeps in tests; timeouts under test are configured in tens of milliseconds through options.
* Every public member has a doc comment. `dart analyze` is clean with the repo `analysis_options.yaml`. `dart format` applied.
* File header comment block as in `status.dart`.

## Transports

A transport is a `StreamChannel<Uint8List>` whose stream yields one mux frame per event and whose sink takes one mux frame per `add`. Closing the sink closes the transport. The stream ends when the transport is closed by either side; errors on the stream mean the transport failed.

```dart
class MemoryTransport {
  /// Two connected transports. Frames added to one appear on the other.
  /// Optional [delay] and [maxFrameSize] for tests. Closing one side
  /// ends the other side's stream.
  static (StreamChannel<Uint8List>, StreamChannel<Uint8List>) pair({Duration? delay});
}

class StreamTransport {
  /// Wraps a byte stream pair: writes the preamble, frames outgoing frames
  /// with the u32 length prefix, parses incoming bytes into frames.
  /// Enforces [maxFrameSize] (default 1 MiB): a larger length fails the
  /// stream with ProtocolException(frameTooLarge) and closes.
  static StreamChannel<Uint8List> wrap(Stream<List<int>> input, StreamSink<List<int>> output, {int maxFrameSize});
  static Future<StreamChannel<Uint8List>> connectTcp(dynamic host, int port, {int maxFrameSize});   // dart:io
  static StreamChannel<Uint8List> fromSocket(Socket socket, {int maxFrameSize});                    // dart:io
}

class WebSocketTransport {
  static StreamChannel<Uint8List> wrap(WebSocketChannel channel);  // binary frames only; text is a protocol error
  static Future<StreamChannel<Uint8List>> connect(Uri uri);        // offers subprotocol 'switchboard'
}
```

## Mux

```dart
enum MuxCommand { data, open, close }

class MuxFrame {
  final MuxCommand command; final int channelId; final Uint8List payload;
  Uint8List encode();                 // short form whenever channelId < 0x10000
  static MuxFrame decode(Uint8List);  // throws ProtocolException on reserved bits, command 3, truncation
}

enum MuxControlType { ping(1), pong(2), goAway(3), limits(4) }
class MuxLimits { final int maxFrameSize; final int maxChannels; encode/decode }

class MuxOptions {
  final int maxFrameSize;          // what we accept, announced with LIMITS; default 1 MiB
  final int maxChannels;           // what we accept; default 65536 (0 = unlimited)
  final bool shortIdsOnly;         // embedded style peer: refuse long ids; default false
  final Duration? keepAliveInterval;   // PING after this much silence; default 10 s; null disables
  final Duration keepAliveTimeout;     // close if nothing arrives after PING; default 10 s
  final Duration goAwayGrace;          // how long goAway() waits for channels; default 10 s
  final bool announceLimits;           // send LIMITS on start; default true
}

class MuxConnection {
  MuxConnection(StreamChannel<Uint8List> transport, {required bool isInitiator, MuxOptions options});
  bool get isInitiator;
  Stream<MuxChannel> get incoming;     // channels opened by the peer, single subscription, buffered until listened
  MuxChannel open(Uint8List openPayload);   // throws SwitchboardException(resourceExhausted) if no id free or peer limit hit; (failedPrecondition) if closed or peer sent GOAWAY
  Future<Duration> ping([Uint8List? payload]);
  Future<void> goAway([Status status]);     // send GOAWAY, wait for open channels up to grace, then close()
  Future<void> close();                     // close transport now; all channels end with connectionLost
  Future<Status> get done;                  // completes when the transport is closed; status: goingAway if a GOAWAY was received, protocolError if we killed it, connectionLost otherwise
  bool get isOpen;                          // transport open and no local close started
  bool get peerGoingAway;
  MuxLimits? get peerLimits;
  int get openChannelCount;
  Iterable<MuxChannel> get channels;
}

enum MuxChannelState { open, halfClosedLocal, closed }

class MuxChannel implements StreamChannel<Uint8List> {
  int get id; bool get isLocallyOpened; Uint8List get openPayload; MuxConnection get connection;
  MuxChannelState get state;
  bool get canSend;                         // state == open
  Stream<Uint8List> get stream;             // incoming DATA subframes; ends when the peer's CLOSE arrives or the connection drops
  StreamSink<Uint8List> get sink;           // add = DATA; close() = close(Status.ok)
  void send(Uint8List subframe);            // throws SwitchboardException(failedPrecondition) if !canSend
  Future<void> close([Status status = Status.ok]);  // send CLOSE; completes when mutually closed or connection lost
  Future<Status> get done;                  // end status: first non-OK status sent or received, else OK; connectionLost/goingAway if connection dropped
}
```

Behaviour notes:

* Receiving OPEN: create the channel, add to `incoming`. If `openChannelCount >= options.maxChannels`, reply CLOSE `resourceExhausted` instead (channel never surfaces).
* Protocol errors: send GOAWAY `protocolError` with reason, close transport, `done` completes with `protocolError`.
* Ids: allocate incrementally from 2 or 3, step 2, skipping reserved ids and ids in use, wrapping at 0xFFFFFFFFFFFF (or 0xFFFF if `shortIdsOnly`).
* Keep-alive: timer restarted on any incoming frame; on expiry send PING; if nothing arrives within `keepAliveTimeout`, close with `connectionLost`.
* Incoming frames for channel 0 are control messages; unknown types ignored; PING answered immediately.

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
  TalkChannel(StreamChannel<Uint8List> channel, {TalkOptions options});   // works over MuxChannel or any StreamChannel
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
  NamingClient(TalkConnector connect, {Duration reconnectDelay, Duration? watchTimeout});   // transport independent
  Future<void> start();
  Future<int> register(Name type, List<Uri> endpoints, {int instance = 0, void Function(int)? onAssigned});   // remembered for re-registration on reconnect; onAssigned on every new id
  Future<void> unregister(Name type, int instance);
  Future<void> get synced;                          // first SYNCED after (re)connect
  Map<ServiceAddress, ServiceRecord> get table;
  Stream<ServiceEvent> get events;
  bool get isConnected;
  Future<void> close();
}

// dart:io glue
NamingClient namingClientFor(Switchboard switchboard, Uri namingEndpoint, {Duration reconnectDelay, Duration? watchTimeout, TalkOptions? talkOptions});   // openTalkAt(endpoint, _ns)

class MeshNode {
  factory MeshNode.join(Switchboard switchboard, Uri namingEndpoint, {Duration reconnectDelay, Duration? watchTimeout, Duration resolveTimeout, TalkOptions? talkOptions});   // sets switchboard.resolver = NamingResolver(client), starts the client
  Switchboard switchboard; NamingClient client; NamingResolver resolver;
  Future<void> get synced;
  Iterable<ServiceAddress> get published;
  Future<int> publish(Name type, ChannelHandler handler, {int instance = 0, List<Uri>? endpoints});   // register, then registerService(type, handler, instance: assigned); follows id changes
  Future<void> unpublish(Name type, int instance);
  Future<void> leave();                             // close resolver and client, unregister local handlers; call before switchboard.close()
}
```

## Tests

* `test/vectors_test.dart`: every vector in the wiki, positive and negative, through the codecs.
* `test/<layer>_test.dart`: unit tests over `MemoryTransport`.
* `test/integration/*_test.dart`: real TCP and WebSocket on `127.0.0.1` port 0; end-to-end mesh scenarios (naming service with several services, frontend endpoint proxying a client channel to a backend instance, reconnection after the naming service restarts, graceful GOAWAY).
