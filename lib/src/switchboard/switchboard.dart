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

import '../address/channel_address.dart';
import '../address/service_address.dart';
import '../mux/mux_channel.dart';
import '../mux/mux_connection.dart';
import '../name.dart';
import '../naming/naming_protocol.dart';
import '../naming/slot_table.dart';
import '../status.dart';
import '../talk/talk_channel.dart';
import '../transport/stream_transport.dart';
import '../transport/web_socket_server.dart';
import '../transport/web_socket_transport_io.dart';
import 'channel_policy.dart';
import 'generic_status.dart';
import 'incoming_channel.dart';
import 'resolver.dart';
import 'slot_channel.dart';
import 'slot_reopen.dart';

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
  ///
  /// [maxConnectionsPerEndpoint] bounds the pooled connections to one
  /// endpoint; see [connect].
  ///
  /// [slotRefreshTimeout] bounds the refresh of a slot's owner after a
  /// `MOVED` rejection that names no owner; see [openChannelToSlot].
  Switchboard({
    this.resolver,
    Uint8List? defaultPayload,
    MuxOptions? muxOptions,
    TalkOptions? talkOptions,
    this.connectTimeout = const Duration(seconds: 10),
    this.allowHostHint = false,
    this.maxConnectionsPerEndpoint = 4,
    this.slotRefreshTimeout = const Duration(seconds: 5),
  }) : defaultPayload = defaultPayload ?? Uint8List(0),
       muxOptions = muxOptions ?? const MuxOptions(),
       talkOptions = talkOptions ?? const TalkOptions() {
    RangeError.checkValueInInterval(
      maxConnectionsPerEndpoint,
      1,
      1 << 16,
      'maxConnectionsPerEndpoint',
    );
  }

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

  /// Largest number of pooled connections to one endpoint. A further
  /// connection is only opened when every pooled one has as many channels
  /// open as its peer announced it accepts. Default 4.
  final int maxConnectionsPerEndpoint;

  /// Longest wait for the slot owner a `MOVED` rejection sends the
  /// [openChannelToSlot] retry to, when the rejection names none and the
  /// resolver has to ask (`LOCATE`).
  final Duration slotRefreshTimeout;

  final Map<Name, Map<int, ChannelHandler>> _services = {};

  final List<HttpServer> _httpServers = [];
  final List<ServerSocket> _tcpServers = [];
  final List<Uri> _endpoints = [];
  final List<_OwnEndpoint> _ownEndpoints = [];

  final Set<MuxConnection> _live = {};
  final List<Future<void>> _lateShutdowns = [];
  // Upgrades and dials in progress; [close] waits for them.
  final Set<Future<void>> _inFlight = {};
  final Expando<String> _remotes = Expando<String>('remote');
  final Expando<ChannelPolicy> _policies = Expando<ChannelPolicy>('policy');
  final Map<String, List<MuxConnection>> _pool = {};
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
  /// Requests for [path], with or without a trailing slash, are upgraded
  /// with [WebSocketServerTransport.upgrade], which bounds every incoming
  /// message, fragments included, by [MuxOptions.maxFrameSize] before
  /// buffering it and negotiates no compression. The `switchboard`
  /// subprotocol is selected when the client offers it. A client that
  /// offers only other subprotocols, or sends no valid key, gets 400, a
  /// plain HTTP request for [path] (or another WebSocket version) gets
  /// 426, and any other path gets 403.
  ///
  /// [policy] is the listener policy applied to every channel arriving on
  /// a connection accepted here; null allows everything. **A listener
  /// reachable by untrusted peers must have a policy**, and that policy
  /// must refuse the reserved types (see [ChannelPolicies.denyReserved]),
  /// or a peer can reach the local naming service and every other local
  /// service and the catch-all.
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
    ChannelPolicy? policy,
  }) async {
    _checkOpen();
    final base = _normalizePath(path);
    return _listen(await HttpServer.bind(address, port), (server) {
      _httpServers.add(server);
      server.listen(
        (request) => _track(_onHttpRequest(request, base, policy)),
        onError: (Object e) => _log.warning('HTTP listener failed: $e'),
      );
      return (
        Uri(
          scheme: 'ws',
          host: server.address.address,
          port: server.port,
          path: base,
        ),
        server.address,
      );
    }, (server) => server.close(force: true));
  }

  /// Starts accepting TCP connections (stream binding) on [address] (a
  /// `String` or an `InternetAddress`) and [port] (0 picks a free port).
  ///
  /// [policy] is the listener policy, as for [listenWebSocket]; null
  /// allows everything, which is only safe for internal listeners.
  ///
  /// Returns the bound `tcp://host:port` URI with the actual port; see
  /// [listenWebSocket] about wildcard addresses. Throws like
  /// [listenWebSocket].
  Future<Uri> listenTcp(
    Object address,
    int port, {
    ChannelPolicy? policy,
  }) async {
    _checkOpen();
    return _listen(await ServerSocket.bind(address, port), (server) {
      _tcpServers.add(server);
      server.listen(
        (socket) => _onSocket(socket, policy),
        onError: (Object e) => _log.warning('TCP listener failed: $e'),
      );
      return (
        Uri(scheme: 'tcp', host: server.address.address, port: server.port),
        server.address,
      );
    }, (server) => server.close());
  }

  Future<Uri> _listen<T>(
    T server,
    (Uri, InternetAddress) Function(T server) start,
    Future<Object?> Function(T server) stop,
  ) async {
    if (_closing) {
      await stop(server);
      throw _closedException();
    }
    final (uri, bound) = start(server);
    _endpoints.add(uri);
    final own = _OwnEndpoint(uri, _hostsOf(bound));
    _ownEndpoints.add(own);
    _log.info('listening on $uri');
    if (bound.address == InternetAddress.anyIPv4.address ||
        bound.address == InternetAddress.anyIPv6.address) {
      // Any address of this host reaches a wildcard listener.
      try {
        for (final interface in await NetworkInterface.list(
          includeLoopback: true,
          includeLinkLocal: true,
        )) {
          for (final a in interface.addresses) {
            if (bound.type == InternetAddressType.IPv6 ||
                a.type == InternetAddressType.IPv4) {
              own.hosts.add(_canonicalHost(a.address));
            }
          }
        }
      } on Object catch (e) {
        _log.fine('cannot list network interfaces: $e');
      }
    }
    return uri;
  }

  /// Host names that designate a listener bound to [bound]: the address
  /// itself and, for loopback and wildcard binds, the loopback names.
  static Set<String> _hostsOf(InternetAddress bound) {
    final hosts = {_canonicalHost(bound.address)};
    final any4 = bound.address == InternetAddress.anyIPv4.address;
    final any6 = bound.address == InternetAddress.anyIPv6.address;
    if (bound.isLoopback || any4 || any6) {
      hosts.add('localhost');
    }
    if (any4 || any6) {
      hosts.add(InternetAddress.loopbackIPv4.address);
      try {
        hosts.add(Platform.localHostname.toLowerCase());
      } on Object {
        // Not available on every platform.
      }
    }
    if (any6) {
      hosts
        ..add(InternetAddress.loopbackIPv6.address)
        ..add(InternetAddress.anyIPv4.address);
    }
    return hosts;
  }

  static String _canonicalHost(String host) {
    final lower = host.toLowerCase();
    final bare = lower.startsWith('[') && lower.endsWith(']')
        ? lower.substring(1, lower.length - 1)
        : lower;
    return InternetAddress.tryParse(bare)?.address ?? bare;
  }

  /// Whether [endpoint] designates one of this node's own listeners, so
  /// that connecting to it would reach this node.
  ///
  /// Compares scheme, port (defaults filled in) and, for WebSocket URIs,
  /// the path (with or without a trailing slash; the query is ignored, as
  /// the listener ignores it). The host matches the bound address, its
  /// loopback names (`localhost`) and, for a wildcard bind, the loopback
  /// addresses, the host name and the addresses of the local network
  /// interfaces. Host names that resolve to this host by other means are
  /// not recognised.
  bool isOwnEndpoint(Uri endpoint) {
    final scheme = endpoint.scheme.toLowerCase();
    final port = _portOf(endpoint);
    final host = _canonicalHost(endpoint.host);
    final isWs = scheme == 'ws' || scheme == 'wss';
    final path = isWs ? _normalizePath(endpoint.path) : '';
    for (final own in _ownEndpoints) {
      if (own.uri.scheme == scheme &&
          own.uri.port == port &&
          (!isWs || own.uri.path == path) &&
          own.hosts.contains(host)) {
        return true;
      }
    }
    return false;
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

  Future<void> _onHttpRequest(
    HttpRequest request,
    String base,
    ChannelPolicy? policy,
  ) async {
    final response = request.response;
    try {
      final path = request.uri.path;
      // Refusals are not awaited: dart:io sends a response only once the
      // request body has arrived, which a client may withhold.
      if (path != base && path != '$base/') {
        response.statusCode = HttpStatus.forbidden;
        _closeQuietly(response);
        return;
      }
      if (_closing) {
        response
          ..statusCode = HttpStatus.serviceUnavailable
          ..persistentConnection = false;
        _closeQuietly(response);
        return;
      }
      final info = request.connectionInfo;
      final remote = info == null
          ? null
          : '${info.remoteAddress.address}:${info.remotePort}';
      final transport = await WebSocketServerTransport.upgrade(
        request,
        maxFrameSize: _webSocketFrameLimit,
      );
      _adopt(transport, isInitiator: false, remote: remote, policy: policy);
    } on Object catch (e) {
      _log.fine('WebSocket request for ${request.uri} failed: $e');
    }
  }

  static void _closeQuietly(HttpResponse response) => response.close().then(
    (_) {},
    onError: (Object e) => _log.fine('HTTP response failed: $e'),
  );

  void _onSocket(Socket socket, ChannelPolicy? policy) {
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
      policy: policy,
    );
  }

  /// The stream binding enforces the mux frame limit; 0 (no limit) maps to
  /// the largest `u32` length.
  int get _transportFrameLimit =>
      muxOptions.maxFrameSize > 0 ? muxOptions.maxFrameSize : 0xFFFFFFFF;

  /// The WebSocket binding enforces the mux frame limit on whole messages;
  /// 0 (no limit at the mux layer) keeps the transport's default, since a
  /// WebSocket message has no length bound of its own.
  int get _webSocketFrameLimit => muxOptions.maxFrameSize > 0
      ? muxOptions.maxFrameSize
      : WebSocketServerTransport.defaultMaxFrameSize;

  /// Runs [operation] (which never fails) as work [close] waits for.
  void _track(Future<void> operation) {
    _inFlight.add(operation);
    operation.whenComplete(() => _inFlight.remove(operation)).ignore();
  }

  // Connections ---------------------------------------------------------

  /// Every connection this node accepts or initiates, as it is
  /// established. Broadcast; ends after [close].
  Stream<MuxConnection> get connections => _connections.stream;

  MuxConnection _adopt(
    StreamChannel<Uint8List> transport, {
    required bool isInitiator,
    String? remote,
    ChannelPolicy? policy,
  }) {
    final connection = MuxConnection(
      transport,
      isInitiator: isInitiator,
      options: muxOptions,
    );
    if (remote != null) {
      _remotes[connection] = remote;
    }
    if (policy != null) {
      _policies[connection] = policy;
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
  /// The first pooled connection with room for another channel is
  /// returned. A connection has room unless its peer announced a channel
  /// limit with LIMITS and [MuxConnection.openChannelCount] has reached
  /// it. When no pooled connection has room, another one is established,
  /// up to [maxConnectionsPerEndpoint]; beyond that the least loaded one
  /// is returned (opening on it then fails with
  /// [StatusCode.resourceExhausted]).
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
      pooled.removeWhere((c) => !c.isOpen || c.peerGoingAway);
      MuxConnection? leastLoaded;
      for (final connection in pooled) {
        if (_hasRoom(connection)) {
          return Future.value(connection);
        }
        if (leastLoaded == null ||
            connection.openChannelCount < leastLoaded.openChannelCount) {
          leastLoaded = connection;
        }
      }
      if (pooled.isEmpty) {
        _pool.remove(key);
      } else if (pooled.length >= maxConnectionsPerEndpoint) {
        return Future.value(leastLoaded);
      }
    }
    final existing = _dialing[key];
    if (existing != null) {
      return existing;
    }
    final dial = _dialing[key] = _dialPooled(endpoint, key);
    _track(dial.then<void>((_) {}, onError: (_) {}));
    return dial;
  }

  /// Whether [connection] can take another channel within the limit its
  /// peer announced.
  static bool _hasRoom(MuxConnection connection) {
    final max = connection.peerLimits?.maxChannels ?? 0;
    return max == 0 || connection.openChannelCount < max;
  }

  static int _portOf(Uri endpoint) => endpoint.hasPort
      ? endpoint.port
      : switch (endpoint.scheme.toLowerCase()) {
          'ws' => 80,
          'wss' => 443,
          _ => 0,
        };

  static String _poolKey(Uri endpoint) {
    final scheme = endpoint.scheme.toLowerCase();
    final host = endpoint.host.toLowerCase();
    final port = _portOf(endpoint);
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
      final pooled = _pool[key] ??= [];
      pooled.add(connection);
      unawaited(
        connection.done.then((_) {
          final list = _pool[key];
          if (list != null && list.remove(connection) && list.isEmpty) {
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
    final connection = _adopt(
      transport,
      isInitiator: true,
      remote: endpoint.toString(),
    );
    if (_closing) {
      // Adopted while closing: it goes away at once and close() waits for
      // it.
      throw _closedException();
    }
    return connection;
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
    // Compression off: a compressed message could inflate far beyond the
    // frame limit before it is checked.
    final attempt = IOWebSocketTransport.connect(
      endpoint.removeFragment(),
      maxFrameSize: _webSocketFrameLimit,
    );
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
    final policy = _policies[connection];
    if (policy != null && !_permitted(policy, address, connection)) {
      _log.info(
        'channel ${channel.id} from $remote: $address refused by the '
        'listener policy',
      );
      unawaited(channel.close(genericStatus(StatusCode.permissionDenied)));
      return;
    }
    final handler = _select(address);
    if (handler == null) {
      _log.fine('channel ${channel.id} from $remote: no handler for $address');
      unawaited(channel.close(genericStatus(StatusCode.notFound)));
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

  static bool _permitted(
    ChannelPolicy policy,
    ChannelAddress address,
    MuxConnection connection,
  ) {
    try {
      return policy(address, connection);
    } on Object catch (e, st) {
      _log.warning('listener policy failed for $address', e, st);
      return false;
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
  /// Slot routing (wiki page "Switchboard Sharding", section "Routing"):
  /// when [address] names any instance, a [shard] is given and the
  /// resolver is a [SlotResolver] with a slot table for the type, the
  /// channel goes to the slot's owner and nowhere else: the owner from the
  /// table ([SlotResolver.slotOwner], the old owner while the slot
  /// migrates); if the table has none, in a managed space the owner the
  /// resolver locates ([SlotResolver.locateSlot], which assigns a free
  /// slot), and in a static space the open fails with
  /// [StatusCode.unavailable]. A slot outside the space fails with
  /// [StatusCode.outOfRange]; an owner that cannot be connected, or is
  /// missing from the service table, with [StatusCode.unavailable]. An
  /// explicit instance bypasses slot routing (the shard is still carried
  /// in the header).
  ///
  /// The returned record's instance is the one to put in the address
  /// header: the selected record's instance, or the requested instance
  /// when the record's is 0.
  ///
  /// With [excludeOwnEndpoints], endpoints for which [isOwnEndpoint] holds
  /// are skipped as unreachable, so that a proxy never forwards a channel
  /// to itself.
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
    bool excludeOwnEndpoints = false,
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
    if (shard != null && address.isAny && r is SlotResolver) {
      final table = r.slotTable(address.type);
      if (table != null) {
        final owner = await _slotOwner(r, table, shard, refresh: false);
        _checkOpen();
        final records = [
          for (final record in known)
            if (record.address.type == address.type &&
                record.address.instance == owner)
              record,
        ];
        if (records.isEmpty) {
          throw SwitchboardException.of(
            StatusCode.unavailable,
            'owner ${ServiceAddress(address.type, owner)} of slot $shard is '
            'not in the service table',
          );
        }
        return _connectFirst(
          ServiceAddress(address.type, owner),
          records,
          0,
          excludeOwnEndpoints,
        );
      }
    }
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
    final start = (shard ?? _nextRoundRobin(address.type)) % candidates.length;
    return _connectFirst(address, candidates, start, excludeOwnEndpoints);
  }

  /// Connects to the first reachable of [candidates], starting at [start]
  /// and going round.
  Future<(ServiceRecord, MuxConnection)> _connectFirst(
    ServiceAddress address,
    List<ServiceRecord> candidates,
    int start,
    bool excludeOwnEndpoints,
  ) async {
    final n = candidates.length;
    final failures = <String>[];
    for (var i = 0; i < n; i++) {
      final record = candidates[(start + i) % n];
      for (final endpoint in record.endpoints) {
        if (excludeOwnEndpoints && isOwnEndpoint(endpoint)) {
          _log.warning(
            '$address: ${record.address} at $endpoint is this node itself; '
            'not connecting',
          );
          failures.add('$endpoint: this node');
          continue;
        }
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

  /// The owner of [slot] in [table], as routing finds it: from the table,
  /// else (managed space, or [refresh]) through [SlotResolver.locateSlot].
  Future<int> _slotOwner(
    SlotResolver r,
    SlotTable table,
    int slot, {
    required bool refresh,
  }) async {
    final type = table.type;
    if (slot >= table.count) {
      throw SwitchboardException.of(
        StatusCode.outOfRange,
        'slot $slot outside the ${table.count} slots of $type',
      );
    }
    var entry = refresh ? null : r.slotOwner(type, slot);
    if (entry == null && (refresh || table.space.mode == SlotMode.managed)) {
      entry = await r.locateSlot(type, slot);
    }
    if (entry == null || entry.owner == 0) {
      throw SwitchboardException.of(
        StatusCode.unavailable,
        'slot $type/$slot has no owner',
      );
    }
    return entry.owner;
  }

  /// The owner of [slot] of [type] by slot routing (see
  /// [selectAndConnect]): from the resolver's table, or located when the
  /// table has none in a managed space. With [refresh] the resolver always
  /// asks ([SlotResolver.locateSlot]), in either mode; this is how a
  /// caller handling `MOVED` itself refreshes the slot.
  ///
  /// Throws [SwitchboardException] with [StatusCode.failedPrecondition] if
  /// the resolver is not a [SlotResolver] (or there is none, or the node is
  /// closed), [StatusCode.notFound] if it has no slot table for [type],
  /// [StatusCode.outOfRange] for a slot outside the space and
  /// [StatusCode.unavailable] when the slot has no owner; also whatever
  /// [Resolver.resolve] and [SlotResolver.locateSlot] throw.
  Future<ServiceAddress> resolveSlotOwner(
    Name type,
    int slot, {
    bool refresh = false,
  }) async {
    _checkOpen();
    RangeError.checkValueInInterval(slot, 0, 0xFFFFFFFF, 'slot');
    final r = resolver;
    if (r is! SlotResolver) {
      throw SwitchboardException.of(
        StatusCode.failedPrecondition,
        'the resolver has no slot tables',
      );
    }
    // The table is complete once the resolver is synced.
    await r.resolve(type);
    final table = r.slotTable(type);
    if (table == null) {
      throw SwitchboardException.of(
        StatusCode.notFound,
        'no slot space for $type',
      );
    }
    return ServiceAddress(
      type,
      await _slotOwner(r, table, slot, refresh: refresh),
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

  /// Opens a channel to the owner of [slot] of [type], with the `MOVED`
  /// retry of the wiki page "Switchboard Sharding", section "Routing".
  ///
  /// The first channel is opened as [openChannel] with `shard: slot` does
  /// (slot routing through a [SlotResolver]; through any other resolver,
  /// such as the [EndpointResolver] of a frontend client, the endpoint
  /// routes). If the owner rejects it with CLOSE `MOVED` before anything
  /// was sent or received, it is retried once, with the same [payload]
  /// (default: [defaultPayload]): to the owner the rejection names, unless
  /// the resolver's table has a more recent one; when it names none, to
  /// the owner the resolver finds by asking ([SlotResolver.locateSlot],
  /// bounded by [slotRefreshTimeout]); through a resolver without slot
  /// tables, the same address again. When the refresh finds no owner
  /// other than the instance that rejected, or the retry fails, the
  /// returned channel ends with the `MOVED` status. See [SlotChannel] for
  /// why a `MOVED` after the first subframe is not retried.
  ///
  /// Throws like [openChannel].
  Future<SlotChannel> openChannelToSlot(
    Name type,
    int slot, {
    Uint8List? payload,
  }) async {
    final application = payload ?? defaultPayload;
    final first = await openChannel(
      ServiceAddress(type),
      shard: slot,
      payload: application,
    );
    final rejectedBy = ChannelAddress.decode(first.openPayload).instance;
    return SlotChannel(
      type,
      slot,
      first,
      (moved) => reopenAtSlotOwner(
        this,
        ChannelAddress(type: type, shard: slot, payload: application),
        rejectedBy,
        moved,
      ),
    );
  }

  /// [openChannelToSlot] wrapped in a [TalkChannel] with [options]
  /// (default: [talkOptions]). The retry applies until the first request
  /// or message is sent; see [SlotChannel].
  Future<TalkChannel> openTalkToSlot(
    Name type,
    int slot, {
    Uint8List? payload,
    TalkOptions? options,
  }) async => TalkChannel(
    await openChannelToSlot(type, slot, payload: payload),
    options: options ?? talkOptions,
  );

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

  /// A pooled connection may receive GOAWAY, or fill up to its peer's
  /// channel limit, between [connect] and the OPEN; one retry replaces it.
  bool _retryOpen(SwitchboardException e, int attempt) =>
      attempt == 0 &&
      (e.code == StatusCode.failedPrecondition ||
          e.code == StatusCode.resourceExhausted) &&
      !_closing;

  // Shutdown ------------------------------------------------------------

  /// Shuts the node down: stops listening, sends GOAWAY on every
  /// connection and waits for each to finish its channels (up to
  /// [MuxOptions.goAwayGrace]) and close. Further calls to [connect] and
  /// the open methods fail with [StatusCode.failedPrecondition].
  ///
  /// Connections that are established while closing (a WebSocket upgrade
  /// or a dial that was in progress, a TCP connection accepted before the
  /// listener closed) receive GOAWAY at once, and the returned future
  /// waits for them too (for upgrades and dials in progress, at most
  /// [connectTimeout]). An HTTP request in progress when closing starts is
  /// still answered; its connection is closed afterwards, and at the latest
  /// when the node has closed.
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
    _ownEndpoints.clear();
    // Stop listening. HTTP connections busy with a request are kept until
    // it is answered (dart:io then closes them) or the end; idle ones are
    // closed now.
    await Future.wait<void>([
      for (final server in http) _quietly(server.close()),
      for (final server in tcp) _quietly(server.close()),
    ]);
    _pool.clear();
    await Future.wait<void>([
      for (final connection in List.of(_live)) connection.goAway(),
    ]);
    // Upgrades and dials in progress may still produce connections, which
    // are adopted and sent GOAWAY at once: wait until none is left, for the
    // upgrades and dials at most connectTimeout.
    final watch = Stopwatch()..start();
    while (true) {
      final late = List.of(_lateShutdowns);
      _lateShutdowns.clear();
      final left = connectTimeout - watch.elapsed;
      final waiting = left > Duration.zero
          ? List.of(_inFlight)
          : const <Future<void>>[];
      if (late.isEmpty && waiting.isEmpty) {
        if (_inFlight.isNotEmpty) {
          _log.fine(
            'closed with ${_inFlight.length} upgrades or dials pending',
          );
        }
        break;
      }
      await Future.wait<void>([
        ...late,
        if (waiting.isNotEmpty)
          Future.wait<void>(waiting)
              .then<void>((_) {})
              .timeout(left, onTimeout: () {}),
      ]);
    }
    await Future.wait<void>([
      for (final server in http) _quietly(server.close(force: true)),
    ]);
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

/// A listening endpoint and the host names that designate it.
class _OwnEndpoint {
  _OwnEndpoint(this.uri, this.hosts);

  final Uri uri;
  final Set<String> hosts;
}
