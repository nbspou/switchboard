/*
Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Author: Jan Boon <jan.boon@kaetemi.be>
*/

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/io.dart';

import '../address/channel_address.dart';
import '../address/service_address.dart';
import '../mux/mux_channel.dart';
import '../mux/mux_connection.dart';
import '../name.dart';
import '../naming/naming_protocol.dart';
import '../status.dart';
import '../talk/talk_channel.dart';
import '../transport/stream_transport.dart';
import '../transport/web_socket_transport.dart';
import 'incoming_channel.dart';
import 'resolver.dart';

final Logger _log = Logger('Switchboard.Router');

/// A mesh node: listens for connections, pools outgoing connections,
/// dispatches incoming channels to local services and opens channels to
/// services anywhere in the mesh through a [Resolver].
///
/// Dispatch and resolution follow the wiki page "Switchboard Addressing
/// and Dispatch". Dispatch is symmetric: channels the peer opens on a
/// connection this node initiated are dispatched exactly like channels on
/// accepted connections.
///
/// Supported endpoint URIs: `ws://host:port/path`, `wss://host:port/path`
/// and `tcp://host:port`. A URI fragment (the text form of a service
/// address, as in `ws://host/path#npc/1a2b`) is ignored for connecting.
class Switchboard {
  /// Creates a node.
  ///
  /// [resolver] is used by [openChannel]; the caller owns it and closes it
  /// after [close]. [defaultPayload] is the application payload attached to
  /// every channel this node opens unless the caller gives one (the node's
  /// credential). [muxOptions] apply to every connection, accepted or
  /// initiated, and [talkOptions] are the defaults for [openTalk],
  /// [openTalkAt] and [IncomingChannel.talk]. [connectTimeout] bounds the
  /// establishment of an outgoing transport connection.
  ///
  /// [allowHostHint] makes `proxyHandler` act on the host hint of incoming
  /// channels by connecting to that host directly. **This turns the node
  /// into an open relay** for anyone who can reach it: enable it only on
  /// nodes that are not reachable from untrusted networks, or together
  /// with an `allow` filter on the proxy handler that checks the host.
  Switchboard({
    this.resolver,
    Uint8List? defaultPayload,
    MuxOptions? muxOptions,
    TalkOptions? talkOptions,
    this.connectTimeout = const Duration(seconds: 10),
    this.allowHostHint = false,
  }) : defaultPayload = defaultPayload ?? Uint8List(0),
       muxOptions = muxOptions ?? const MuxOptions(),
       talkOptions = talkOptions ?? const TalkOptions();

  /// Resolves service types for [openChannel] and [openTalk]. May be
  /// replaced at any time; channels already open are unaffected.
  Resolver? resolver;

  /// Application payload attached to every channel this node opens unless
  /// the caller supplies one. Empty by default.
  Uint8List defaultPayload;

  /// Mux configuration of every connection.
  final MuxOptions muxOptions;

  /// Default Talk configuration of channels opened or accepted here.
  final TalkOptions talkOptions;

  /// Longest time to wait for an outgoing transport connection.
  final Duration connectTimeout;

  /// Whether `proxyHandler` honours host hints. See the constructor.
  final bool allowHostHint;

  final Map<Name, Map<int, ChannelHandler>> _services = {};

  final List<HttpServer> _httpServers = [];
  final List<ServerSocket> _tcpServers = [];
  final List<Uri> _endpoints = [];

  final Set<MuxConnection> _live = {};
  final List<Future<void>> _lateShutdowns = [];
  final Expando<String> _remotes = Expando<String>('remote');
  final Map<String, MuxConnection> _pool = {};
  final Map<String, Future<MuxConnection>> _dialing = {};
  final Map<Name, int> _roundRobin = {};
  final StreamController<MuxConnection> _connections =
      StreamController<MuxConnection>.broadcast();

  bool _closing = false;
  Future<void>? _closeFuture;

  // Listening -----------------------------------------------------------

  /// Starts accepting WebSocket connections on [address] (a `String` or an
  /// `InternetAddress`) and [port] (0 picks a free port), at [path].
  ///
  /// Requests for [path], with or without a trailing slash, are upgraded,
  /// selecting the `switchboard` subprotocol when the client offers it.
  /// A client that offers only other subprotocols gets 400, a plain HTTP
  /// request for [path] gets 426, and any other path gets 403.
  ///
  /// Returns the bound `ws://host:port/path` URI with the actual port. The
  /// host is the bound address; when binding a wildcard address, advertise
  /// a reachable host name instead. Throws [SwitchboardException] with
  /// [StatusCode.failedPrecondition] after [close], and whatever
  /// `HttpServer.bind` throws.
  Future<Uri> listenWebSocket(
    Object address,
    int port, {
    String path = '/',
  }) async {
    _checkOpen();
    final base = _normalizePath(path);
    return _listen(await HttpServer.bind(address, port), (server) {
      _httpServers.add(server);
      server.listen(
        (request) => unawaited(_onHttpRequest(request, base)),
        onError: (Object e) => _log.warning('HTTP listener failed: $e'),
      );
      return Uri(
        scheme: 'ws',
        host: server.address.address,
        port: server.port,
        path: base,
      );
    }, (server) => server.close(force: true));
  }

  /// Starts accepting TCP connections (stream binding) on [address] (a
  /// `String` or an `InternetAddress`) and [port] (0 picks a free port).
  ///
  /// Returns the bound `tcp://host:port` URI with the actual port; see
  /// [listenWebSocket] about wildcard addresses. Throws like
  /// [listenWebSocket].
  Future<Uri> listenTcp(Object address, int port) async {
    _checkOpen();
    return _listen(await ServerSocket.bind(address, port), (server) {
      _tcpServers.add(server);
      server.listen(
        _onSocket,
        onError: (Object e) => _log.warning('TCP listener failed: $e'),
      );
      return Uri(
        scheme: 'tcp',
        host: server.address.address,
        port: server.port,
      );
    }, (server) => server.close());
  }

  Future<Uri> _listen<T>(
    T server,
    Uri Function(T server) start,
    Future<Object?> Function(T server) stop,
  ) async {
    if (_closing) {
      await stop(server);
      throw _closedException();
    }
    final uri = start(server);
    _endpoints.add(uri);
    _log.info('listening on $uri');
    return uri;
  }

  /// The URIs returned by [listenWebSocket] and [listenTcp], until
  /// [close].
  List<Uri> get listeningEndpoints => List.unmodifiable(_endpoints);

  static String _normalizePath(String path) {
    var p = path.startsWith('/') ? path : '/$path';
    while (p.length > 1 && p.endsWith('/')) {
      p = p.substring(0, p.length - 1);
    }
    return p;
  }

  Future<void> _onHttpRequest(HttpRequest request, String base) async {
    final response = request.response;
    try {
      final path = request.uri.path;
      if (path != base && path != '$base/') {
        response.statusCode = HttpStatus.forbidden;
        await response.close();
        return;
      }
      if (_closing) {
        response.statusCode = HttpStatus.serviceUnavailable;
        await response.close();
        return;
      }
      if (!WebSocketTransformer.isUpgradeRequest(request)) {
        response.statusCode = HttpStatus.upgradeRequired;
        response.headers.set(HttpHeaders.upgradeHeader, 'websocket');
        await response.close();
        return;
      }
      final offered = _offeredProtocols(request);
      if (offered.isNotEmpty &&
          !offered.contains(WebSocketTransport.subprotocol)) {
        response.statusCode = HttpStatus.badRequest;
        response.write(
          'the ${WebSocketTransport.subprotocol} subprotocol is required',
        );
        await response.close();
        return;
      }
      final info = request.connectionInfo;
      final remote = info == null
          ? null
          : '${info.remoteAddress.address}:${info.remotePort}';
      // Closed through the transport.
      // ignore: close_sinks
      final ws = await WebSocketTransformer.upgrade(
        request,
        // Only called when the client offers subprotocols, which then
        // include ours (checked above).
        protocolSelector: (_) => WebSocketTransport.subprotocol,
      );
      _adopt(
        WebSocketTransport.wrap(IOWebSocketChannel(ws)),
        isInitiator: false,
        remote: remote,
      );
    } on Object catch (e) {
      _log.fine('WebSocket request for ${request.uri} failed: $e');
    }
  }

  static Set<String> _offeredProtocols(HttpRequest request) => {
    for (final value
        in request.headers['Sec-WebSocket-Protocol'] ?? const <String>[])
      for (final part in value.split(','))
        if (part.trim().isNotEmpty) part.trim(),
  };

  void _onSocket(Socket socket) {
    String? remote;
    try {
      remote = '${socket.remoteAddress.address}:${socket.remotePort}';
    } on Object {
      // The socket may already be closed; the transport will notice.
    }
    _adopt(
      StreamTransport.fromSocket(socket, maxFrameSize: _transportFrameLimit),
      isInitiator: false,
      remote: remote,
    );
  }

  /// The stream binding enforces the mux frame limit; 0 (no limit) maps to
  /// the largest `u32` length.
  int get _transportFrameLimit =>
      muxOptions.maxFrameSize > 0 ? muxOptions.maxFrameSize : 0xFFFFFFFF;

  // Connections ---------------------------------------------------------

  /// Every connection this node accepts or initiates, as it is
  /// established. Broadcast; ends after [close].
  Stream<MuxConnection> get connections => _connections.stream;

  MuxConnection _adopt(
    StreamChannel<Uint8List> transport, {
    required bool isInitiator,
    String? remote,
  }) {
    final connection = MuxConnection(
      transport,
      isInitiator: isInitiator,
      options: muxOptions,
    );
    if (remote != null) {
      _remotes[connection] = remote;
    }
    if (_closing) {
      _log.fine('closing, refusing connection from $remote');
      _lateShutdowns.add(connection.goAway());
      return connection;
    }
    _live.add(connection);
    _log.fine(
      '${isInitiator ? 'connected to' : 'accepted connection from'} $remote',
    );
    connection.incoming.listen((channel) => _dispatch(connection, channel));
    unawaited(
      connection.done.then((status) {
        _live.remove(connection);
        _log.fine('connection with $remote ended: $status');
      }),
    );
    if (!_connections.isClosed) {
      _connections.add(connection);
    }
    return connection;
  }

  /// A pooled connection to [endpoint], established if needed.
  ///
  /// Connections are pooled per endpoint (scheme, host and port compared
  /// case-insensitively with default ports filled in, plus the path and
  /// query for WebSocket URIs; the fragment is ignored). A pooled
  /// connection that is closing or whose peer sent GOAWAY is dropped from
  /// the pool and replaced (it keeps serving its open channels).
  /// Concurrent calls for the same endpoint share one attempt. Failures
  /// are not cached.
  ///
  /// Throws [SwitchboardException] with [StatusCode.unavailable] if the
  /// connection cannot be established within [connectTimeout], with
  /// [StatusCode.unimplemented] for an unsupported scheme, with
  /// [StatusCode.invalidArgument] for a `tcp` URI without host or port,
  /// and with [StatusCode.failedPrecondition] after [close].
  Future<MuxConnection> connect(Uri endpoint) {
    if (_closing) {
      return Future.error(_closedException());
    }
    final key = _poolKey(endpoint);
    final pooled = _pool[key];
    if (pooled != null) {
      if (pooled.isOpen && !pooled.peerGoingAway) {
        return Future.value(pooled);
      }
      _pool.remove(key);
    }
    return _dialing[key] ??= _dialPooled(endpoint, key);
  }

  static String _poolKey(Uri endpoint) {
    final scheme = endpoint.scheme.toLowerCase();
    final host = endpoint.host.toLowerCase();
    final port = endpoint.hasPort
        ? endpoint.port
        : switch (scheme) {
            'ws' => 80,
            'wss' => 443,
            _ => 0,
          };
    if (scheme != 'ws' && scheme != 'wss') {
      return '$scheme://$host:$port';
    }
    final path = endpoint.path.isEmpty ? '/' : endpoint.path;
    final query = endpoint.hasQuery ? '?${endpoint.query}' : '';
    return '$scheme://$host:$port$path$query';
  }

  Future<MuxConnection> _dialPooled(Uri endpoint, String key) async {
    try {
      final connection = await _dial(endpoint);
      _pool[key] = connection;
      unawaited(
        connection.done.then((_) {
          if (identical(_pool[key], connection)) {
            _pool.remove(key);
          }
        }),
      );
      return connection;
    } finally {
      // The attempt is over (its callers hold the future); the next
      // connect() starts a new one if needed.
      unawaited(_dialing.remove(key));
    }
  }

  Future<MuxConnection> _dial(Uri endpoint) async {
    final StreamChannel<Uint8List> transport;
    switch (endpoint.scheme.toLowerCase()) {
      case 'ws' || 'wss':
        transport = await _connectWebSocket(endpoint);
      case 'tcp':
        transport = await _connectTcp(endpoint);
      default:
        throw SwitchboardException.of(
          StatusCode.unimplemented,
          'unsupported endpoint scheme: $endpoint',
        );
    }
    if (_closing) {
      transport.sink.close().ignore();
      throw _closedException();
    }
    return _adopt(transport, isInitiator: true, remote: endpoint.toString());
  }

  Future<StreamChannel<Uint8List>> _connectTcp(Uri endpoint) async {
    if (endpoint.host.isEmpty || !endpoint.hasPort) {
      throw SwitchboardException.of(
        StatusCode.invalidArgument,
        'tcp endpoint needs a host and a port: $endpoint',
      );
    }
    try {
      final socket = await Socket.connect(
        endpoint.host,
        endpoint.port,
        timeout: connectTimeout,
      );
      return StreamTransport.fromSocket(
        socket,
        maxFrameSize: _transportFrameLimit,
      );
    } on Object catch (e) {
      throw SwitchboardException.of(
        StatusCode.unavailable,
        'cannot connect to $endpoint: $e',
      );
    }
  }

  Future<StreamChannel<Uint8List>> _connectWebSocket(Uri endpoint) async {
    final attempt = WebSocketTransport.connect(endpoint.removeFragment());
    try {
      return await attempt.timeout(connectTimeout);
    } on TimeoutException {
      // Close the connection if it completes after we gave up on it.
      attempt.then((transport) => transport.sink.close()).ignore();
      throw SwitchboardException.of(
        StatusCode.unavailable,
        'cannot connect to $endpoint: timed out after $connectTimeout',
      );
    } on Object catch (e) {
      throw SwitchboardException.of(
        StatusCode.unavailable,
        'cannot connect to $endpoint: $e',
      );
    }
  }

  // Dispatch ------------------------------------------------------------

  /// Registers [handler] for channels addressed to `(type, instance)`.
  ///
  /// A channel for `(type, i)` goes to the handler registered for exactly
  /// that pair. A channel for `(type, 0)` (any instance) goes to the
  /// handler registered for `(type, 0)` if there is one, else to the first
  /// registered instance of [type]. A registration with instance 0 does
  /// *not* receive channels addressed to a specific non-zero instance:
  /// register the instance id the service was assigned for that.
  ///
  /// Registering an existing pair replaces its handler and keeps its
  /// position. Throws [RangeError] if [instance] is outside `u48`.
  void registerService(Name type, ChannelHandler handler, {int instance = 0}) {
    RangeError.checkValueInInterval(instance, 0, maxInstance, 'instance');
    (_services[type] ??= {})[instance] = handler;
  }

  /// Removes the handler registered for `(type, instance)`, if any.
  /// Channels already dispatched to it are unaffected.
  void unregisterService(Name type, {int instance = 0}) {
    final handlers = _services[type];
    if (handlers == null) {
      return;
    }
    handlers.remove(instance);
    if (handlers.isEmpty) {
      _services.remove(type);
    }
  }

  /// Receives channels that carry no service type (`HAS_SERVICE` absent),
  /// such as the minimal `00` open payload. Null for none.
  ChannelHandler? defaultService;

  /// Receives channels no local service claims, typically a
  /// `proxyHandler`. Null for none; unclaimed channels are then rejected
  /// with `NOT_FOUND`.
  ChannelHandler? catchAll;

  void _dispatch(MuxConnection connection, MuxChannel channel) {
    final remote = _remotes[connection];
    final ChannelAddress address;
    try {
      address = ChannelAddress.decode(channel.openPayload);
    } on ProtocolException catch (e) {
      _log.warning('channel ${channel.id} from $remote: ${e.status}');
      unawaited(channel.close(e.status));
      return;
    }
    final handler = _select(address);
    if (handler == null) {
      _log.fine('channel ${channel.id} from $remote: no handler for $address');
      unawaited(
        channel.close(
          Status.of(
            StatusCode.notFound,
            'no service ${address.address ?? '(default)'}',
          ),
        ),
      );
      return;
    }
    final incoming = IncomingChannel(
      channel,
      address: address,
      talkOptions: talkOptions,
      remote: remote,
    );
    try {
      final result = handler(incoming);
      if (result is Future<void>) {
        unawaited(
          result.then<void>(
            (_) {},
            onError: (Object e, StackTrace st) =>
                _handlerFailed(incoming, e, st),
          ),
        );
      }
    } on Object catch (e, st) {
      _handlerFailed(incoming, e, st);
    }
  }

  ChannelHandler? _select(ChannelAddress address) {
    final type = address.type;
    if (type == null) {
      return defaultService ?? catchAll;
    }
    final handlers = _services[type];
    if (handlers != null) {
      final exact = handlers[address.instance];
      if (exact != null) {
        return exact;
      }
      if (address.instance == 0 && handlers.isNotEmpty) {
        return handlers.values.first;
      }
    }
    return catchAll;
  }

  void _handlerFailed(IncomingChannel incoming, Object error, StackTrace st) {
    _log.severe('handler for $incoming failed', error, st);
    unawaited(
      incoming.reject(Status.of(StatusCode.internal, 'handler failed')),
    );
  }

  // Opening channels ----------------------------------------------------

  /// Resolves [address] through [resolver] (default: the node's own
  /// resolver), selects an instance and returns it with a connection to it.
  ///
  /// Records whose instance differs from a non-zero requested instance are
  /// skipped; records with instance 0 (as an [EndpointResolver] returns)
  /// match any requested instance. The candidates are sorted by instance;
  /// with a [shard] slot `s` the first choice is `candidates[s mod n]`,
  /// otherwise a per-type round-robin counter picks it. Endpoints of the
  /// chosen instance are tried in order; if none can be connected, the
  /// following instances are tried in turn.
  ///
  /// The returned record's instance is the one to put in the address
  /// header: the selected record's instance, or the requested instance
  /// when the record's is 0.
  ///
  /// Throws [SwitchboardException] with [StatusCode.notFound] if no
  /// instance is known, [StatusCode.unavailable] if none is reachable, and
  /// [StatusCode.failedPrecondition] if there is no resolver or the node
  /// is closed; also whatever [Resolver.resolve] throws (a naming resolver
  /// that was never synced: [StatusCode.unavailable] after its resolve
  /// timeout). Throws [RangeError] if [shard] is outside `u32`.
  Future<(ServiceRecord, MuxConnection)> selectAndConnect(
    ServiceAddress address, {
    int? shard,
    Resolver? resolver,
  }) async {
    _checkOpen();
    final r = resolver ?? this.resolver;
    if (r == null) {
      throw SwitchboardException.of(
        StatusCode.failedPrecondition,
        'no resolver to find $address',
      );
    }
    if (shard != null) {
      RangeError.checkValueInInterval(shard, 0, 0xFFFFFFFF, 'shard');
    }
    // Not `await r.ready`: resolve() waits for the table itself, bounded
    // (a naming resolver fails with UNAVAILABLE after its resolve timeout
    // if it was never synced), whereas `ready` has no bound.
    final known = await r.resolve(address.type);
    final candidates = [
      for (final record in known)
        if (record.address.type == address.type &&
            (address.isAny ||
                record.address.isAny ||
                record.address.instance == address.instance))
          record,
    ];
    if (candidates.isEmpty) {
      throw SwitchboardException.of(
        StatusCode.notFound,
        'no known instance of $address',
      );
    }
    candidates.sort((a, b) => a.address.instance.compareTo(b.address.instance));
    final n = candidates.length;
    final start = (shard ?? _nextRoundRobin(address.type)) % n;
    final failures = <String>[];
    for (var i = 0; i < n; i++) {
      final record = candidates[(start + i) % n];
      for (final endpoint in record.endpoints) {
        try {
          final connection = await connect(endpoint);
          final selected = record.address.isAny && !address.isAny
              ? ServiceRecord(address, endpoints: record.endpoints)
              : record;
          return (selected, connection);
        } on SwitchboardException catch (e) {
          if (_closing) {
            rethrow;
          }
          _log.fine('$address: ${record.address} at $endpoint: ${e.status}');
          failures.add('$endpoint: ${e.status}');
        }
      }
      if (record.endpoints.isEmpty) {
        failures.add('${record.address}: no endpoints');
      }
    }
    throw SwitchboardException.of(
      StatusCode.unavailable,
      'no reachable instance of $address (${failures.join('; ')})',
    );
  }

  int _nextRoundRobin(Name type) {
    final next = _roundRobin[type] ?? 0;
    _roundRobin[type] = (next + 1) & 0x3FFFFFFF;
    return next;
  }

  /// Opens a channel to a service anywhere in the mesh: resolves and
  /// connects with [selectAndConnect], then sends OPEN with the header
  /// `{type, selected instance, shard}` and [payload] (default:
  /// [defaultPayload]) as the application payload.
  ///
  /// The channel is returned at once; a rejection by the peer arrives as
  /// its close status ([MuxChannel.done]). Throws like [selectAndConnect],
  /// and like [MuxConnection.open] (for example
  /// [StatusCode.resourceExhausted]).
  Future<MuxChannel> openChannel(
    ServiceAddress address, {
    int? shard,
    Uint8List? payload,
  }) async {
    final application = payload ?? defaultPayload;
    for (var attempt = 0; ; attempt++) {
      final (record, connection) = await selectAndConnect(
        address,
        shard: shard,
      );
      final header = ChannelAddress(
        type: address.type,
        instance: record.address.instance,
        shard: shard,
        payload: application,
      );
      try {
        return connection.open(header.encode());
      } on SwitchboardException catch (e) {
        if (!_retryOpen(e, attempt)) {
          rethrow;
        }
      }
    }
  }

  /// [openChannel] wrapped in a [TalkChannel] with [options] (default:
  /// [talkOptions]).
  Future<TalkChannel> openTalk(
    ServiceAddress address, {
    int? shard,
    Uint8List? payload,
    TalkOptions? options,
  }) async => TalkChannel(
    await openChannel(address, shard: shard, payload: payload),
    options: options ?? talkOptions,
  );

  /// Opens a channel to an explicit [endpoint] with [address] as the OPEN
  /// payload, bypassing resolution. This is how a frontend client reaches
  /// its endpoint and how a service reaches the naming service.
  ///
  /// The header (including a host hint, for relays) is sent as given. If
  /// [ChannelAddress.payload] is empty, [defaultPayload] is sent instead;
  /// to send an empty application payload from a node that has a default
  /// payload, use [connect] and [MuxConnection.open]. Throws like [connect]
  /// and [MuxConnection.open].
  Future<MuxChannel> openChannelAt(Uri endpoint, ChannelAddress address) async {
    final bytes = _withDefaultPayload(address).encode();
    for (var attempt = 0; ; attempt++) {
      final connection = await connect(endpoint);
      try {
        return connection.open(bytes);
      } on SwitchboardException catch (e) {
        if (!_retryOpen(e, attempt)) {
          rethrow;
        }
      }
    }
  }

  /// [openChannelAt] wrapped in a [TalkChannel] with [options] (default:
  /// [talkOptions]).
  Future<TalkChannel> openTalkAt(
    Uri endpoint,
    ChannelAddress address, {
    TalkOptions? options,
  }) async => TalkChannel(
    await openChannelAt(endpoint, address),
    options: options ?? talkOptions,
  );

  /// Opens a channel on an existing [connection], for example one an
  /// incoming channel arrived on, to reach a service the peer registered
  /// locally (symmetric dispatch). [defaultPayload] is applied as in
  /// [openChannelAt]. Throws like [MuxConnection.open].
  MuxChannel openChannelOn(MuxConnection connection, ChannelAddress address) =>
      connection.open(_withDefaultPayload(address).encode());

  ChannelAddress _withDefaultPayload(ChannelAddress address) =>
      address.payload.isEmpty && defaultPayload.isNotEmpty
      ? address.copyWith(payload: defaultPayload)
      : address;

  /// A pooled connection may receive GOAWAY between [connect] and the
  /// OPEN; one retry replaces it.
  bool _retryOpen(SwitchboardException e, int attempt) =>
      attempt == 0 && e.code == StatusCode.failedPrecondition && !_closing;

  // Shutdown ------------------------------------------------------------

  /// Shuts the node down: stops listening, sends GOAWAY on every
  /// connection and waits for each to finish its channels (up to
  /// [MuxOptions.goAwayGrace]) and close. Further calls to [connect] and
  /// the open methods fail with [StatusCode.failedPrecondition].
  ///
  /// The [resolver] is owned by the caller and is not closed. Calling
  /// again returns the same future. Never throws.
  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    _closing = true;
    _log.info('closing');
    final http = List.of(_httpServers);
    final tcp = List.of(_tcpServers);
    _httpServers.clear();
    _tcpServers.clear();
    _endpoints.clear();
    await Future.wait<void>([
      for (final server in http) _quietly(server.close(force: true)),
      for (final server in tcp) _quietly(server.close()),
    ]);
    _pool.clear();
    await Future.wait<void>([
      for (final connection in List.of(_live)) connection.goAway(),
    ]);
    await Future.wait<void>(List.of(_lateShutdowns));
    await _connections.close();
    _log.info('closed');
  }

  static Future<void> _quietly(Future<Object?> future) => future.then<void>(
    (_) {},
    onError: (Object e) => _log.fine('listener close failed: $e'),
  );

  void _checkOpen() {
    if (_closing) {
      throw _closedException();
    }
  }

  static SwitchboardException _closedException() => SwitchboardException.of(
    StatusCode.failedPrecondition,
    'switchboard is closed',
  );
}
