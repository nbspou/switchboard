/*
Polyverse Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Authors:
  Jan Boon <jan.boon@kaetemi.be>
  Claude Fable 5.1 <noreply@anthropic.com>
  Claude Opus 5.5 <noreply@anthropic.com>
*/

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show Random;
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:stream_channel/stream_channel.dart';

import '../address/channel_address.dart';
import '../address/service_address.dart';
import '../bytes.dart';
import '../identity/credential.dart';
import '../identity/credential_verifier.dart';
import '../identity/holder_key.dart';
import '../identity/peer_identity.dart';
import '../identity/secure_random.dart';
import '../mux/mux_channel.dart';
import '../mux/mux_connection.dart';
import '../mux/mux_frame.dart';
import '../name.dart';
import '../naming/naming_protocol.dart';
import '../naming/slot_table.dart';
import '../status.dart';
import '../talk/talk_channel.dart';
import '../transport/memory_transport.dart';
import '../transport/stream_transport.dart';
import '../transport/web_socket_server.dart';
import '../transport/web_socket_transport_io.dart';
import 'channel_policy.dart';
import 'generic_status.dart';
import 'identity_wait.dart';
import 'incoming_channel.dart';
import 'memory_endpoints.dart';
import 'outgoing_policy.dart';
import 'relay_config.dart';
import 'resolver.dart';
import 'slot_channel.dart';
import 'slot_reopen.dart';

final Logger _log = Logger('Switchboard.Router');

/// A mesh node: listens for connections, pools outgoing connections,
/// dispatches incoming channels to local services and opens channels to
/// services anywhere in the mesh through a [Resolver].
///
/// Dispatch and resolution follow the wiki page "Polyverse Switchboard Addressing
/// and Dispatch". Dispatch is symmetric: channels the peer opens on a
/// connection this node initiated are dispatched exactly like channels on
/// accepted connections, under that connection's policy
/// ([outgoingPolicy]).
///
/// Supported endpoint URIs: `ws://host:port/path`, `wss://host:port/path`,
/// `tcp://host:port` and, within one isolate, `mem://id` (see
/// [listenMemory]). A URI fragment (the text form of a service address, as
/// in `ws://host/path#npc/1a2b`) is ignored for connecting.
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
  /// [slotRefreshTimeout] bounds every `LOCATE` slot routing sends: the
  /// lookup of a slot the table has no owner for (see [selectAndConnect])
  /// and the refresh of a slot's owner after a `MOVED` rejection that
  /// names none (see [openChannelToSlot]).
  ///
  /// [selection] is how [selectAndConnect] picks an instance when no shard
  /// slot is given; [random] is the source of [SelectionPolicy.random]
  /// (default: a new [Random]), to be seeded in tests.
  ///
  /// [outgoingPolicy], [endpointPolicy] and [credentialFor] govern the
  /// connections this node initiates, for meshes that reach peers they do
  /// not trust (workers on rented machines, say): the policy of the
  /// channels such a peer opens back towards this node, and the
  /// credential this node presents to it. All null (the default), an
  /// initiated connection is trusted like an internal listener's and every
  /// channel carries [defaultPayload].
  ///
  /// Identity (wiki page "Polyverse Switchboard Identity and Credentials"): with a
  /// [credential] (and the [holderKey] it names, if it names one), the
  /// node identifies with `NONCE`/`IDENT` on every connection it initiates
  /// ([connect], [dial], and through them the open methods, `PeerSet` and
  /// the proxy), before the connection is used, unless [identifyOutgoing]
  /// is false or [identifyFor] says otherwise for the endpoint; on other
  /// connections when the application asks ([identifyOn]). [verifier]
  /// checks the credentials peers present on any connection of the node,
  /// accepted or initiated, which sets [MuxConnection.peerIdentity] for
  /// the policies (see [ChannelPolicies.scoped]); it becomes the
  /// [MuxOptions.identityVerifier] of [muxOptions]. [identityTimeout]
  /// bounds each identification and how long a channel that its policy
  /// refused with `UNAUTHENTICATED` is held for the peer to identify
  /// (zero: no bound on identification, and no holding).
  /// [expectedIdentityFor] names the peer each identification on an
  /// initiated connection is meant for (the receiver field of `IDENT`).
  /// The credential's identity is the [MuxConnection.localIdentity] of
  /// every connection, which peers' identifications must name, if they
  /// name anyone. Instances registered without endpoints are reached by
  /// having them dial this node ([broker], [brokerEndpoint]), or, by a
  /// node that listens nowhere, through a [relay].
  ///
  /// Throws [ArgumentError] when [credential] names a holder key and
  /// [holderKey] is missing or another, and for a negative
  /// [identityTimeout].
  Switchboard({
    this.resolver,
    Uint8List? defaultPayload,
    MuxOptions? muxOptions,
    TalkOptions? talkOptions,
    this.connectTimeout = const Duration(seconds: 10),
    this.allowHostHint = false,
    this.maxConnectionsPerEndpoint = 4,
    this.slotRefreshTimeout = const Duration(seconds: 5),
    this.selection = SelectionPolicy.roundRobin,
    Random? random,
    this.outgoingPolicy,
    this.endpointPolicy,
    this.credentialFor,
    Credential? credential,
    this.holderKey,
    CredentialVerifier? verifier,
    this.identifyOutgoing = true,
    this.identifyFor,
    this.identityTimeout = const Duration(seconds: 10),
    this.expectedIdentityFor,
    this.relay,
  }) : defaultPayload = defaultPayload ?? Uint8List(0),
       _identity = credential,
       muxOptions = verifier == null
           ? muxOptions ?? const MuxOptions()
           : (muxOptions ?? const MuxOptions()).copyWith(
               identityVerifier: verifier,
             ),
       talkOptions = talkOptions ?? const TalkOptions(),
       _random = random ?? Random() {
    RangeError.checkValueInInterval(
      maxConnectionsPerEndpoint,
      1,
      1 << 16,
      'maxConnectionsPerEndpoint',
    );
    if (identityTimeout < Duration.zero) {
      throw ArgumentError.value(
        identityTimeout,
        'identityTimeout',
        'must not be negative',
      );
    }
    if (credential != null) {
      _checkHolderKey(credential);
    }
  }

  /// The credential this node identifies with (wiki page "Switchboard
  /// Identity and Credentials"), or null for none. May be replaced, for
  /// example by a renewed credential: connections established afterwards
  /// use the new one; [identifyOn] presents it on a live connection, and
  /// [updateCredential] on every connection the node identified on. Its
  /// identity becomes the [MuxConnection.localIdentity] of every
  /// connection. Throws [ArgumentError] when the new credential names a
  /// holder key other than [holderKey]'s.
  Credential? get credential => _identity;

  set credential(Credential? value) {
    if (value != null) {
      _checkHolderKey(value);
    }
    _identity = value;
    for (final connection in _live) {
      connection.localIdentity = value?.identity;
    }
  }

  /// Replaces [credential] with [credential] (a renewed one, typically)
  /// and presents it again, with `IDENT`, on every open connection this
  /// node has identified on, with the intent and receiver of the last
  /// identification there; the peers replace the identity they had.
  /// Completes once every such identification has completed or failed
  /// (failures are logged: a peer that refuses the credential ends its
  /// connection). Throws [ArgumentError] like the [credential] setter.
  Future<void> updateCredential(Credential credential) async {
    this.credential = credential;
    await Future.wait([
      for (final connection in List.of(_live))
        if (connection.isOpen && _identified[connection] != null)
          _reidentify(connection, credential),
    ]);
  }

  Future<void> _reidentify(
    MuxConnection connection,
    Credential credential,
  ) async {
    final last = _identified[connection]!;
    try {
      await connection.identify(
        credential,
        holderKey: holderKey,
        intent: last.intent,
        receiver: last.receiver,
        timeout: identityTimeout,
      );
    } on Object catch (e) {
      _log.info('identifying again on ${_remotes[connection]} failed: $e');
    }
  }

  Credential? _identity;

  void _checkHolderKey(Credential credential) {
    final holder = credential.holderKey;
    if (holder == null) {
      return;
    }
    final key = holderKey?.publicKey;
    var same = key != null && key.length == holder.length;
    for (var i = 0; same && i < holder.length; i++) {
      same = key![i] == holder[i];
    }
    if (!same) {
      throw ArgumentError.value(
        holderKey,
        'holderKey',
        'the credential names a holder key; pass its key pair',
      );
    }
  }

  /// The key pair of the holder key [credential] names; null for a bearer
  /// credential.
  final HolderKey? holderKey;

  /// Checks the credentials peers present with `IDENT` on the node's
  /// connections; null when the node does not check identity (an `IDENT`
  /// is then ignored). [MuxOptions.identityVerifier] of [muxOptions].
  CredentialVerifier? get verifier => muxOptions.identityVerifier;

  /// Whether the node identifies with [credential] on the connections it
  /// initiates, for endpoints [identifyFor] does not decide. Default true.
  ///
  /// The node presents its credential to every such peer: a bearer
  /// credential can be replayed by whoever receives it, and a holder-key
  /// credential whose `IDENT` names nobody lets a peer that relays the
  /// handshake pass as this node at a third node that accepts unnamed
  /// identifications ([expectedIdentityFor] names the peer, which binds
  /// the proof to it). A node that dials peers outside its trust domain
  /// identifies only to its own mesh, through [identifyFor].
  final bool identifyOutgoing;

  /// Whether the node identifies on a connection it initiates to
  /// `endpoint`, asked when the connection is established, about the
  /// endpoint as the pool keys it (as [endpointPolicy] is). Null (the
  /// default): [identifyOutgoing]. A hook that throws means no (logged).
  final bool Function(Uri endpoint)? identifyFor;

  /// Bound on each identification of the node ([MuxConnection.identify]),
  /// and on how long a channel refused with `UNAUTHENTICATED` by its
  /// connection's policy is held for the peer to identify. Default 10 s.
  final Duration identityTimeout;

  /// The identity the node expects the peer of a connection it initiates
  /// to have, named in the receiver field of its `IDENT` there, so that
  /// the peer cannot relay the identification to a third node; consulted
  /// on every identification on an initiated connection that is not given
  /// a receiver. Null (the default), or a null answer, names nobody,
  /// except on a connection to a relay, which is named by the identity
  /// its record carries (see [relay]). See [ExpectedIdentity].
  final ExpectedIdentity? expectedIdentityFor;

  /// Resolves service types for [openChannel] and [openTalk]. May be
  /// replaced at any time; channels already open are unaffected.
  Resolver? resolver;

  /// Application payload attached to every channel this node opens unless
  /// the caller supplies one. Empty by default. Not used implicitly once
  /// [credentialFor] is set.
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

  /// Longest wait for a `LOCATE` of slot routing
  /// ([SlotResolver.locateSlot]): for a slot the table has no owner for,
  /// and for the owner a `MOVED` rejection sends the [openChannelToSlot]
  /// retry to when the rejection names none. Then the open fails with
  /// `UNAVAILABLE`. Default 5 s.
  final Duration slotRefreshTimeout;

  /// How [selectAndConnect] picks among the candidates when no shard slot
  /// is given. Default [SelectionPolicy.roundRobin].
  final SelectionPolicy selection;

  final Random _random;

  /// The policy of the connections this node initiates ([connect], [dial],
  /// and through them the open methods), applied to every channel the peer
  /// opens on such a connection exactly like a listener policy: a refused
  /// channel is closed with `PERMISSION_DENIED` and a generic reason. Null
  /// (the default) allows everything, as on an internal listener.
  ///
  /// The policy of a connection is chosen once, when it is established:
  /// the `policy` passed to [connect] or [dial] if any, else what
  /// [endpointPolicy] returns for the endpoint if it returns one, else
  /// this. A node that dials peers it does not trust, which have no
  /// business opening channels towards it, sets
  /// [ChannelPolicies.denyAll], here or for those endpoints.
  final ChannelPolicy? outgoingPolicy;

  /// Chooses the policy of each connection this node initiates by its
  /// endpoint, consulted when the connection is established: a non-null
  /// result overrides [outgoingPolicy] (an explicit `policy` of [connect]
  /// or [dial] overrides both). Lets an application trust its own mesh
  /// (`mem://`, the private network) and refuse everything from other
  /// endpoints. The hook is asked about the endpoint as the pool tells
  /// endpoints apart, not as the caller spelled it: scheme and host
  /// lower-cased, the default port filled in, the path (`/` when empty)
  /// and query kept for WebSocket URIs only, no fragment, and a `mem` URI
  /// by its id alone; so two spellings of one endpoint, which share pooled
  /// connections, always get the same policy. A hook that throws gives
  /// the connection [ChannelPolicies.denyAll]. See [EndpointPolicy].
  final EndpointPolicy? endpointPolicy;

  /// Chooses the application payload of every channel this node opens
  /// without one from the caller, per destination: the open methods
  /// attach its result (null: an empty payload) instead of
  /// [defaultPayload], which is then never attached implicitly. The hook
  /// receives the endpoint the channel goes to and, for [openChannel] and
  /// the other opens that resolve, the resolver's record of the selected
  /// instance, whose [ServiceRecord.metadata] may carry a per-instance key
  /// published by a trusted registrar. A channel
  /// opened on a connection this node accepted ([openChannelOn]) has no
  /// destination endpoint and carries an empty payload. A channel through
  /// a [relay] is asked about with the relay's endpoint and the
  /// destination's record. Null (the default): [defaultPayload]
  /// everywhere.
  ///
  /// A payload the caller passes always wins: the `payload` of
  /// [openChannel], a non-empty [ChannelAddress.payload] for
  /// [openChannelAt] and [openChannelOn]. The proxy (`proxyHandler`) and
  /// the slot gate forward their client's payload and never consult this.
  /// A hook that throws, or whose future fails, fails the open. See
  /// [EndpointCredential].
  final EndpointCredential? credentialFor;

  /// Where an instance that registered without endpoints dials this node
  /// when the node brokers a connection to it ([broker]): the `endpoint`
  /// of the naming service's `CONNECT`. Null (the default): the first of
  /// [listeningEndpoints]. It must be reachable from the instances, and
  /// its listener's policy is the policy of the brokered connections.
  Uri? brokerEndpoint;

  /// Whether instances registered without endpoints can dial this node
  /// ([broker]): it has a [brokerEndpoint] or listens somewhere. A node
  /// that cannot broker reaches such instances through its [relay], if it
  /// has one.
  bool get canBroker => brokerEndpoint != null || _endpoints.isNotEmpty;

  /// The relays through which this node reaches the instances registered
  /// without endpoints when it cannot broker them itself ([canBroker] is
  /// false: no [brokerEndpoint], no listener), wiki page "Switchboard
  /// Identity and Credentials", section "Relay". Null (the default): no
  /// relay; opening a channel to such an instance fails as brokering does
  /// (`UNAVAILABLE`, naming the missing listener). May be replaced at any
  /// time; channels already open are unaffected.
  ///
  /// When [openChannel] (and [openTalk], [openChannelToSlot],
  /// [openTalkToSlot], and `PeerSet`) selects a record without endpoints
  /// on a node that cannot broker, the channel goes through a relay: the
  /// node finds the relays ([resolveRelays]: the records of
  /// [RelayConfig.type] in the resolver, round robin with failover, or
  /// [RelayConfig.endpoints]), connects to the first that answers through
  /// the pool, like [connect] (identifying there as on any connection it
  /// initiates, naming the relay's identity from its record's metadata
  /// unless [expectedIdentityFor] names another), and opens a channel of
  /// type [RelayConfig.type] (instance 0, no shard) whose application
  /// payload is the open payload the channel would have had to the
  /// destination: the header with the type, the selected instance and the
  /// shard slot, then the application payload, chosen as for a direct
  /// channel (the caller's, else what [credentialFor] gives for the
  /// relay's endpoint and the destination's record, else
  /// [defaultPayload]). The relay forwards that payload unchanged, so the
  /// destination sees the node's credential; the relay sees it too. The
  /// returned channel is the `_relay` channel: a refusal by the relay or
  /// by the destination arrives as its close status. A node that can
  /// broker never uses a relay, and [selectAndConnect], [broker] and the
  /// proxy never do.
  RelayConfig? relay;

  final Map<Name, Map<int, ChannelHandler>> _services = {};

  /// Per type, the instances whose registration also serves channels
  /// addressed to any other instance ([registerService]'s
  /// `acceptAnyInstance`).
  final Map<Name, Set<int>> _anyInstance = {};

  final List<HttpServer> _httpServers = [];
  final List<ServerSocket> _tcpServers = [];
  final List<String> _memoryIds = [];
  final List<Uri> _endpoints = [];
  final List<_OwnEndpoint> _ownEndpoints = [];

  final Set<MuxConnection> _live = {};
  final List<Future<void>> _lateShutdowns = [];
  // Upgrades and dials in progress; [close] waits for them.
  final Set<Future<void>> _inFlight = {};
  final Expando<String> _remotes = Expando<String>('remote');
  final Expando<ChannelPolicy> _policies = Expando<ChannelPolicy>('policy');
  // The endpoint each initiated connection was established to.
  final Expando<Uri> _dialled = Expando<Uri>('endpoint');
  // The intent and receiver of the node's last identification on a
  // connection, for presenting a renewed credential there.
  final Expando<_Identification> _identified = Expando<_Identification>(
    'identification',
  );
  // Keyed by the endpoint's pool key, or by the pool key and the policy
  // for a connect() with an explicit policy.
  final Map<Object, List<MuxConnection>> _pool = {};
  final Map<Object, Future<MuxConnection>> _dialing = {};
  // Brokered connections (CONNECT): the pooled one per instance, the
  // attempts in progress, the opens waiting for their instance to dial
  // back (by intent), and the intents given up on lately.
  final Map<ServiceAddress, MuxConnection> _brokeredPool = {};
  final Map<ServiceAddress, Future<MuxConnection>> _brokering = {};
  final Map<String, Completer<MuxConnection>> _brokerWaits = {};
  final LinkedHashSet<String> _abandoned = LinkedHashSet<String>();
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
  /// With [onOtherRequest], requests for any other path are handed to it
  /// instead of being answered 403, so that the port can also serve, for
  /// example, OAuth return routes or `.well-known` files. The callback owns
  /// the response: it must answer and close it (or detach its socket).
  /// If it throws or its future fails, the error is logged and the
  /// request is answered 500, unless the callback had already started the
  /// response, which is then left as it is. [close] waits for callbacks in
  /// progress as for upgrades (at most [connectTimeout]). An application
  /// that needs its own `HttpServer` uses [acceptWebSocket] instead.
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
    FutureOr<void> Function(HttpRequest request)? onOtherRequest,
  }) async {
    _checkOpen();
    final base = _normalizePath(path);
    return _listen(await HttpServer.bind(address, port), (server) {
      _httpServers.add(server);
      server.listen(
        (request) =>
            _track(_onHttpRequest(request, base, policy, onOtherRequest)),
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

  /// Starts accepting in-process connections at a `mem://` endpoint, for
  /// running every node of a mesh in one isolate (tests, a single-process
  /// mode of a deployment).
  ///
  /// [name] is the endpoint id: ASCII letters, digits, `.`, `_`, `~` and
  /// `-`, compared in lower case (the URI carries it in lower case). Null
  /// generates an id unique in this isolate. The id is registered
  /// isolate-wide until [close]: [connect] on any [Switchboard] of the
  /// isolate reaches this node at the returned URI over a
  /// [MemoryTransport] pair, and the connection is accepted exactly like a
  /// TCP connection (listener [policy], dispatch, [connections], GOAWAY on
  /// [close]). The port, path and query of a `mem` URI are ignored. Frames
  /// are delivered through the event queue, as from a socket, so that
  /// timers still run while nodes of the isolate exchange requests.
  ///
  /// [policy] is the listener policy, as for [listenWebSocket]; null
  /// allows everything.
  ///
  /// A `mem://` URI means nothing outside this isolate: publish it to a
  /// naming service (as [listeningEndpoints] does through
  /// `MeshNode.publish`) only when every node of the mesh runs in the same
  /// isolate. A node also listening on TCP or WebSocket for nodes elsewhere
  /// should publish only those endpoints.
  ///
  /// Returns the `mem://id` URI. Throws [ArgumentError] for an invalid
  /// [name], and [SwitchboardException] with [StatusCode.alreadyExists] if
  /// a listener of this isolate already has that id, or with
  /// [StatusCode.failedPrecondition] after [close].
  Future<Uri> listenMemory({ChannelPolicy? policy, String? name}) async {
    _checkOpen();
    final uri = MemoryEndpoints.register(
      (transport, remote) =>
          _adopt(transport, isInitiator: false, remote: remote, policy: policy),
      name: name,
    );
    _memoryIds.add(uri.host);
    _endpoints.add(uri);
    _ownEndpoints.add(_OwnEndpoint(uri, {_canonicalHost(uri.host)}));
    _log.info('listening on $uri');
    return uri;
  }

  /// Adopts [transport], a connection accepted outside this node, exactly
  /// like a connection a listener accepts: the node is the acceptor side
  /// of the mux ([MuxConnection.isInitiator] false, with [muxOptions]),
  /// [policy] is the listener policy of every channel arriving on it,
  /// those channels are dispatched to the local services, the connection
  /// appears on [connections], and [close] sends it GOAWAY and waits for
  /// it. For a WebSocket upgrade from an application's own `HttpServer`,
  /// [acceptWebSocket] does the upgrade too.
  ///
  /// [policy] null allows everything; a connection from untrusted peers
  /// must have a policy that refuses the reserved types, as a listener
  /// must (see [listenWebSocket]). [remote] describes the peer in logs and
  /// in [IncomingChannel.remote]; default `'external'`. The transport
  /// carries one mux frame per event and should bound incoming frames by
  /// [MuxOptions.maxFrameSize], as the node's own transports do.
  ///
  /// Throws [SwitchboardException] with [StatusCode.failedPrecondition]
  /// once [close] has started. The transport is then adopted all the same
  /// and sent GOAWAY at once, so that the peer is told and the transport
  /// closed, and a [close] in progress waits for it.
  Future<MuxConnection> accept(
    StreamChannel<Uint8List> transport, {
    ChannelPolicy? policy,
    String? remote,
  }) async {
    final connection = _adopt(
      transport,
      isInitiator: false,
      remote: remote ?? 'external',
      policy: policy,
    );
    if (_closing) {
      // Adopted while closing: it goes away at once and close() waits for
      // it.
      throw _closedException();
    }
    return connection;
  }

  /// Upgrades [request], received by an application's own `HttpServer`,
  /// to a WebSocket and [accept]s it: the one-call form for an application
  /// that routes its own server, for example to serve OAuth return routes
  /// or `.well-known` files on the same port, instead of [listenWebSocket].
  /// The path is not checked; routing is the caller's.
  ///
  /// The upgrade is the one [listenWebSocket] performs:
  /// [WebSocketServerTransport.upgrade] with no compression, selecting the
  /// `switchboard` subprotocol when the client offers it, and bounding
  /// every incoming message, fragments included, by [maxFrameSize]
  /// (default: [MuxOptions.maxFrameSize], or the transport's 1 MiB default
  /// when that is 0; 0 for no limit). [policy] is the connection's listener
  /// policy, as for [accept]: **a connection from untrusted peers must have
  /// one**. The peer's address is its remote description.
  ///
  /// A request that is not a valid upgrade is answered 400 (no valid key,
  /// or only other subprotocols offered) or 426 (a plain HTTP request,
  /// another WebSocket version), and the call fails with
  /// [SwitchboardException] [StatusCode.invalidArgument]. Once [close] has
  /// started, the request is answered 503 and the call fails with
  /// [StatusCode.failedPrecondition]; an upgrade in progress when [close]
  /// starts is completed and fails the same way, its connection sent
  /// GOAWAY at once, and [close] waits for it (for the upgrade, at most
  /// [connectTimeout]). In these cases the request has been answered.
  /// Throws [RangeError] for a negative [maxFrameSize], before touching
  /// the request; other errors of the upgrade, such as a [StateError] for
  /// a response already started, propagate.
  Future<MuxConnection> acceptWebSocket(
    HttpRequest request, {
    ChannelPolicy? policy,
    int? maxFrameSize,
  }) {
    final accepted = _acceptWebSocket(
      request,
      policy,
      maxFrameSize ?? _webSocketFrameLimit,
    );
    _track(accepted.then<void>((_) {}, onError: (Object _) {}));
    return accepted;
  }

  Future<MuxConnection> _acceptWebSocket(
    HttpRequest request,
    ChannelPolicy? policy,
    int maxFrameSize,
  ) async {
    RangeError.checkNotNegative(maxFrameSize, 'maxFrameSize');
    final (transport, remote) = await _upgrade(request, maxFrameSize);
    return accept(transport, policy: policy, remote: remote);
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
  /// not recognised. A `mem` URI matches by its id alone
  /// ([listenMemory]).
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

  /// The URIs returned by [listenWebSocket], [listenTcp] and
  /// [listenMemory], until [close].
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
    FutureOr<void> Function(HttpRequest request)? onOtherRequest,
  ) async {
    try {
      final path = request.uri.path;
      if (path != base && path != '$base/') {
        if (onOtherRequest != null) {
          await _handOver(request, onOtherRequest);
          return;
        }
        // Refusals are not awaited: dart:io sends a response only once the
        // request body has arrived, which a client may withhold.
        request.response.statusCode = HttpStatus.forbidden;
        _closeQuietly(request.response);
        return;
      }
      final (transport, remote) = await _upgrade(request, _webSocketFrameLimit);
      _adopt(transport, isInitiator: false, remote: remote, policy: policy);
    } on Object catch (e) {
      _log.fine('WebSocket request for ${request.uri} failed: $e');
    }
  }

  /// Answers 503 once closing, else upgrades [request] and returns the
  /// transport with the peer's address. Throws [SwitchboardException]:
  /// [StatusCode.failedPrecondition] when closing, and
  /// [StatusCode.invalidArgument] for a refused upgrade, both after
  /// answering the request.
  Future<(WebSocketServerChannel, String?)> _upgrade(
    HttpRequest request,
    int maxFrameSize,
  ) async {
    if (_closing) {
      final response = request.response
        ..statusCode = HttpStatus.serviceUnavailable
        ..persistentConnection = false;
      // Not awaited, as for the refusals.
      _closeQuietly(response);
      throw _closedException();
    }
    final info = request.connectionInfo;
    final remote = info == null
        ? null
        : '${info.remoteAddress.address}:${info.remotePort}';
    try {
      final transport = await WebSocketServerTransport.upgrade(
        request,
        maxFrameSize: maxFrameSize,
      );
      return (transport, remote);
    } on WebSocketException catch (e) {
      throw SwitchboardException.of(StatusCode.invalidArgument, e.message);
    }
  }

  /// Runs an application's handler for a request the listener does not
  /// serve. The handler owns the response; if it fails before starting
  /// it, the request is answered 500.
  static Future<void> _handOver(
    HttpRequest request,
    FutureOr<void> Function(HttpRequest request) handler,
  ) async {
    try {
      await handler(request);
    } on Object catch (e, st) {
      _log.severe('handler for ${request.method} ${request.uri} failed', e, st);
      final response = request.response;
      try {
        // Throws if the handler already started (or closed) the response.
        response.statusCode = HttpStatus.internalServerError;
      } on StateError {
        return;
      }
      _closeQuietly(response);
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
    )..localIdentity = _identity?.identity;
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
    if (!isInitiator) {
      connection.peerIdentified
          .then((identity) => _onAcceptedIdentified(connection, identity))
          .ignore();
    }
    if (!_connections.isClosed) {
      _connections.add(connection);
    }
    return connection;
  }

  /// A pooled connection to [endpoint], established if needed.
  ///
  /// Connections are pooled per endpoint (scheme, host and port compared
  /// case-insensitively with default ports filled in, plus the path and
  /// query for WebSocket URIs; the fragment is ignored; a `mem` URI by its
  /// id alone). A pooled connection that is closing or whose peer sent
  /// GOAWAY is dropped from the pool and replaced (it keeps serving its
  /// open channels). Concurrent calls for the same endpoint share one
  /// attempt. Failures are not cached.
  ///
  /// The first pooled connection with room for another channel is
  /// returned. A connection has room unless its peer announced a channel
  /// limit with LIMITS and [MuxConnection.openChannelCount] has reached
  /// it. When no pooled connection has room, another one is established,
  /// up to [maxConnectionsPerEndpoint]; beyond that the least loaded one
  /// is returned (opening on it then fails with
  /// [StatusCode.resourceExhausted]).
  ///
  /// A `mem://id` endpoint ([listenMemory]) is reached in this isolate
  /// over a [MemoryTransport] pair, at once.
  ///
  /// Channels the peer opens on the connection are dispatched to the local
  /// services under the connection's policy: [policy] if given, else
  /// [endpointPolicy] for [endpoint], else [outgoingPolicy] (see
  /// [outgoingPolicy]). A call with a [policy] shares pooled connections
  /// only with calls passing the same policy (`==`, so the same function
  /// object), never with calls without one; pass one stable policy object
  /// per purpose rather than a new closure per call.
  ///
  /// Throws [SwitchboardException] with [StatusCode.unavailable] if the
  /// connection cannot be established within [connectTimeout] (for a `mem`
  /// URI: no listener of this isolate has that id, or it has closed), with
  /// [StatusCode.unimplemented] for an unsupported scheme, with
  /// [StatusCode.invalidArgument] for a `tcp` URI without host or port or
  /// a `mem` URI without id, and with [StatusCode.failedPrecondition]
  /// after [close].
  ///
  /// [record] is the resolver's record the connection is established for,
  /// if the caller has one: it reaches [expectedIdentityFor] (and names a
  /// relay from its metadata) when a new connection is dialled; a pooled
  /// connection that already exists is returned as is. The open methods
  /// pass the record whose endpoint they dial.
  Future<MuxConnection> connect(
    Uri endpoint, {
    ChannelPolicy? policy,
    ServiceRecord? record,
  }) => _connect(endpoint, policy, record);

  /// [connect]; a new connection is established for [record] (named as
  /// [dial] names it in the `IDENT`).
  Future<MuxConnection> _connect(
    Uri endpoint,
    ChannelPolicy? policy,
    ServiceRecord? record,
  ) {
    if (_closing) {
      return Future.error(_closedException());
    }
    final endpointKey = _poolKey(endpoint);
    final Object key = policy == null ? endpointKey : (endpointKey, policy);
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
    final dial = _dialing[key] = _dialPooled(endpoint, key, policy, record);
    _track(dial.then<void>((_) {}, onError: (_) {}));
    return dial;
  }

  /// A new connection to [endpoint] that is not pooled: established
  /// through the same path as [connect] (schemes, [connectTimeout], the
  /// connection's policy chosen from [policy], [endpointPolicy] and
  /// [outgoingPolicy], [credentialFor] for the channels opened on it with
  /// [openChannelOn]), adopted for dispatch, reported on [connections] and
  /// sent GOAWAY by [close], but never handed out by [connect] or used by
  /// the open methods.
  ///
  /// The caller owns it: it opens channels on it ([openChannelOn] applies
  /// the node's payload rules) and ends it with [MuxConnection.goAway]
  /// when done. For keeping one connection per peer with its own lifetime,
  /// such as `PeerSet` does, so that a peer that reboots does not disturb
  /// the pooled connections other parts of the application use.
  ///
  /// The node identifies on it as on any connection it initiates, naming
  /// the receiver [expectedIdentityFor] gives for [endpoint] and [record]
  /// (the resolver's record the connection is for, if any), or, when the
  /// hook names nobody and [record] is a relay's (of [Services.relay], or
  /// of the type of [relay]), the identity in the record's metadata. With an
  /// [intent] or a [receiver] it identifies whatever [identifyFor] and
  /// [identifyOutgoing] say, sending [intent] (at most 64 bytes) and
  /// naming [receiver] (at most 255 bytes of UTF-8; empty names nobody)
  /// instead of what [expectedIdentityFor] gives: this is how an instance
  /// dials back the consumer a naming service's `CONNECT` names, with
  /// one `IDENT`.
  ///
  /// Throws like [connect]. With an [intent] or a [receiver] and no
  /// [credential], fails with [StatusCode.failedPrecondition] before
  /// dialling. Throws [ArgumentError] for an [intent] or [receiver] too
  /// long for an `IDENT`.
  Future<MuxConnection> dial(
    Uri endpoint, {
    ChannelPolicy? policy,
    Uint8List? intent,
    String? receiver,
    ServiceRecord? record,
  }) {
    if (_closing) {
      return Future.error(_closedException());
    }
    if (intent != null && intent.length > MuxIdent.maxIntentLength) {
      throw ArgumentError.value(
        intent.length,
        'intent',
        'at most ${MuxIdent.maxIntentLength} bytes',
      );
    }
    if (receiver != null &&
        utf8.encode(receiver).length > MuxIdent.maxReceiverLength) {
      throw ArgumentError.value(
        receiver,
        'receiver',
        'at most ${MuxIdent.maxReceiverLength} bytes of UTF-8',
      );
    }
    if ((intent != null || receiver != null) && _identity == null) {
      return Future.error(
        SwitchboardException.of(
          StatusCode.failedPrecondition,
          'the node has no credential to identify with',
        ),
      );
    }
    final attempt = _dial(
      endpoint,
      policy,
      intent: intent,
      receiver: receiver,
      record: record,
    );
    _track(attempt.then<void>((_) {}, onError: (_) {}));
    return attempt;
  }

  /// Whether [connection] can take another channel within the limit its
  /// peer announced.
  static bool _hasRoom(MuxConnection connection) {
    final max = connection.peerLimits?.maxChannels ?? 0;
    return max == 0 || connection.openChannelCount < max;
  }

  static int _portOf(Uri endpoint) {
    final scheme = endpoint.scheme.toLowerCase();
    if (scheme == MemoryEndpoints.scheme) {
      // Ignored: a mem endpoint is its id.
      return 0;
    }
    return endpoint.hasPort
        ? endpoint.port
        : switch (scheme) {
            'ws' => 80,
            'wss' => 443,
            _ => 0,
          };
  }

  static String _poolKey(Uri endpoint) => _normalised(endpoint).toString();

  /// [endpoint] as the pool tells endpoints apart (see [connect]): scheme
  /// and host lower-cased, the default port filled in, the path (`/` when
  /// empty) and query kept for WebSocket URIs only, no fragment; a `mem`
  /// URI is its id alone. What [endpointPolicy] is asked about, so that
  /// every spelling of one endpoint gets the same policy.
  static Uri _normalised(Uri endpoint) {
    final scheme = endpoint.scheme.toLowerCase();
    final host = endpoint.host.toLowerCase();
    if (scheme == MemoryEndpoints.scheme) {
      return Uri(scheme: scheme, host: host);
    }
    final port = _portOf(endpoint);
    if (scheme != 'ws' && scheme != 'wss') {
      return Uri(scheme: scheme, host: host, port: port);
    }
    return Uri(
      scheme: scheme,
      host: host,
      port: port,
      path: endpoint.path.isEmpty ? '/' : endpoint.path,
      query: endpoint.hasQuery ? endpoint.query : null,
    );
  }

  Future<MuxConnection> _dialPooled(
    Uri endpoint,
    Object key,
    ChannelPolicy? policy,
    ServiceRecord? record,
  ) async {
    try {
      final connection = await _dial(endpoint, policy, record: record);
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

  /// Establishes and adopts a connection to [endpoint] and identifies on
  /// it (see [dial]).
  Future<MuxConnection> _dial(
    Uri endpoint,
    ChannelPolicy? policy, {
    Uint8List? intent,
    String? receiver,
    ServiceRecord? record,
  }) async {
    final StreamChannel<Uint8List> transport;
    switch (endpoint.scheme.toLowerCase()) {
      case 'ws' || 'wss':
        transport = await _connectWebSocket(endpoint);
      case 'tcp':
        transport = await _connectTcp(endpoint);
      case MemoryEndpoints.scheme:
        transport = _connectMemory(endpoint);
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
      policy:
          policy ?? _endpointPolicyOf(_normalised(endpoint)) ?? outgoingPolicy,
    );
    _dialled[connection] = endpoint;
    if (_closing) {
      // Adopted while closing: it goes away at once and close() waits for
      // it.
      throw _closedException();
    }
    final credential = _identity;
    final normalised = _normalised(endpoint);
    if (credential != null &&
        (intent != null || receiver != null || _identifiesTo(normalised))) {
      final named =
          receiver ??
          _expectedIdentity(normalised, record) ??
          _relayIdentity(record);
      try {
        await connection.identify(
          credential,
          holderKey: holderKey,
          intent: intent,
          receiver: named,
          timeout: identityTimeout,
        );
        _identified[connection] = _Identification(intent, named);
      } on Object catch (e) {
        _log.info('identification to $endpoint failed: $e');
        unawaited(connection.goAway());
        if (_closing) {
          throw _closedException();
        }
        throw SwitchboardException.of(
          StatusCode.unauthenticated,
          'identification to $endpoint failed: '
          '${e is SwitchboardException ? e.status : e}',
        );
      }
    }
    return connection;
  }

  /// Whether the node identifies on a connection to [endpoint] (normalised):
  /// [identifyFor], else [identifyOutgoing].
  bool _identifiesTo(Uri endpoint) {
    final hook = identifyFor;
    if (hook == null) {
      return identifyOutgoing;
    }
    try {
      return hook(endpoint);
    } on Object catch (e, st) {
      _log.warning('identifyFor failed for $endpoint', e, st);
      return false;
    }
  }

  /// The identity of the relay [record] describes, from its metadata (a
  /// record of [Services.relay], or of the type of [relay]): null for any
  /// other record, and for metadata that is empty, not UTF-8, or too long
  /// for the receiver field of an `IDENT`.
  String? _relayIdentity(ServiceRecord? record) {
    if (record == null ||
        record.metadata.isEmpty ||
        record.metadata.length > MuxIdent.maxReceiverLength) {
      return null;
    }
    final type = record.address.type;
    if (type != Services.relay && type != relay?.type) {
      return null;
    }
    try {
      return utf8.decode(record.metadata);
    } on FormatException {
      _log.fine('relay ${record.address}: metadata is not an identity');
      return null;
    }
  }

  /// What [expectedIdentityFor] says for [endpoint] (normalised) and
  /// [record]; a hook that throws names nobody.
  String? _expectedIdentity(Uri endpoint, ServiceRecord? record) {
    final hook = expectedIdentityFor;
    if (hook == null) {
      return null;
    }
    try {
      return hook(endpoint, record);
    } on Object catch (e, st) {
      _log.warning('expectedIdentityFor failed for $endpoint', e, st);
      return null;
    }
  }

  /// Identifies the node with [credential] on [connection], with [intent]
  /// (wiki page "Polyverse Switchboard Identity and Credentials"): for a connection
  /// this node accepted, whose peer wants it to identify
  /// ([MuxConnection.identityRequested]), or to present a renewed
  /// [credential] on a live connection. Bounded by [identityTimeout].
  ///
  /// The `IDENT` names [receiver] as the peer's identity; by default the
  /// receiver of the node's last identification on [connection], else,
  /// for a connection the node initiated, what [expectedIdentityFor] gives
  /// for its endpoint, else nobody.
  ///
  /// Fails like [MuxConnection.identify]. Throws [StateError] when the
  /// node has no credential.
  Future<void> identifyOn(
    MuxConnection connection, {
    Uint8List? intent,
    String? receiver,
  }) {
    final credential = _identity;
    if (credential == null) {
      throw StateError('the node has no credential');
    }
    final dialled = _dialled[connection];
    final named =
        receiver ??
        _identified[connection]?.receiver ??
        (dialled == null
            ? null
            : _expectedIdentity(_normalised(dialled), null));
    return connection
        .identify(
          credential,
          holderKey: holderKey,
          intent: intent,
          receiver: named,
          timeout: identityTimeout,
        )
        .then((_) => _identified[connection] = _Identification(intent, named));
  }

  /// What [endpointPolicy] says for [endpoint]; a hook that throws refuses
  /// everything.
  ChannelPolicy? _endpointPolicyOf(Uri endpoint) {
    final hook = endpointPolicy;
    if (hook == null) {
      return null;
    }
    try {
      return hook(endpoint);
    } on Object catch (e, st) {
      _log.warning('endpoint policy failed for $endpoint', e, st);
      return ChannelPolicies.denyAll;
    }
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

  /// Hands one side of a new [MemoryTransport] pair to the listener at
  /// [endpoint] and returns the other.
  StreamChannel<Uint8List> _connectMemory(Uri endpoint) {
    final id = endpoint.host;
    if (id.isEmpty) {
      throw SwitchboardException.of(
        StatusCode.invalidArgument,
        'mem endpoint needs an id: $endpoint',
      );
    }
    final acceptor = MemoryEndpoints.lookup(id);
    if (acceptor == null) {
      throw SwitchboardException.of(
        StatusCode.unavailable,
        'cannot connect to $endpoint: no memory listener with that id',
      );
    }
    // Every frame is delivered through the event queue, as from a socket,
    // not as a microtask: a request loop between nodes of the isolate
    // would otherwise never let a timer (timeouts, keep-alive, heartbeats)
    // run.
    final (local, remote) = MemoryTransport.pair(delay: Duration.zero);
    // The accepting node sees this node by its first mem endpoint, if any.
    acceptor(
      remote,
      _memoryIds.isEmpty
          ? 'memory peer'
          : '${MemoryEndpoints.scheme}://${_memoryIds.first}',
    );
    return local;
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

  // Brokered connections -------------------------------------------------

  /// Has the instance at [address], whose record has no endpoints, dial
  /// this node, and returns that connection: the naming service's
  /// `CONNECT` (wiki page "Polyverse Switchboard Identity and Credentials", section
  /// "Reverse connections"), through [resolver] (default: the node's),
  /// which must be a [BrokeringResolver].
  ///
  /// The node asks the instance to dial [brokerEndpoint] (by default its
  /// first listening endpoint) with a random intent, and waits, at most
  /// [connectTimeout] in all, for the answer (the identity the instance
  /// presents) and for an accepted connection whose peer identified with
  /// that identity and that intent. With a [credential], the node then
  /// identifies on it in turn, naming the instance as the receiver, so
  /// that the instance's policy can check this node's `open` scopes. The
  /// connection is accepted: the policy of the listener it arrived on
  /// applies to the channels the instance opens on it, and channels this
  /// node opens on it carry the payload of an accepted connection (see
  /// [payloadFor]). If brokering fails, a connection that already arrived
  /// is sent GOAWAY too, even if the naming service's answer failed before
  /// the connection could be checked.
  ///
  /// The connection is not pooled: the caller owns it and ends it with
  /// [MuxConnection.goAway], as with [dial]. [openChannel] and the other
  /// resolving opens broker their own pooled connection, one per instance,
  /// when they select an instance without endpoints.
  ///
  /// Fails with [SwitchboardException]: [StatusCode.failedPrecondition]
  /// when the resolver cannot broker, the node has no [verifier] (it could
  /// not tell who dialled), listens nowhere, or is closed; [StatusCode.invalidArgument] for an address without an
  /// instance; what the naming service answers ([StatusCode.notFound],
  /// [StatusCode.permissionDenied], [StatusCode.unavailable]);
  /// [StatusCode.unavailable] when the instance did not dial back within
  /// [connectTimeout]; [StatusCode.unauthenticated] when the connection
  /// that arrived is not the instance's, or identifying on it failed.
  Future<MuxConnection> broker(ServiceAddress address, {Resolver? resolver}) {
    if (_closing) {
      return Future.error(_closedException());
    }
    final attempt = _broker(address, resolver ?? this.resolver);
    _track(attempt.then<void>((_) {}, onError: (_) {}));
    return attempt;
  }

  /// A pooled brokered connection to [address], brokered through [r] if
  /// there is none; concurrent calls share one attempt.
  Future<MuxConnection> _brokeredPooled(ServiceAddress address, Resolver r) {
    final pooled = _brokeredPool[address];
    if (pooled != null && pooled.isOpen && !pooled.peerGoingAway) {
      return Future.value(pooled);
    }
    _brokeredPool.remove(address);
    final existing = _brokering[address];
    if (existing != null) {
      return existing;
    }
    Future<MuxConnection> attempt() async {
      try {
        final connection = await _broker(address, r);
        _brokeredPool[address] = connection;
        connection.done.then((_) {
          if (identical(_brokeredPool[address], connection)) {
            _brokeredPool.remove(address);
          }
        }).ignore();
        return connection;
      } finally {
        unawaited(_brokering.remove(address));
      }
    }

    final started = _brokering[address] = attempt();
    _track(started.then<void>((_) {}, onError: (_) {}));
    return started;
  }

  Future<MuxConnection> _broker(ServiceAddress address, Resolver? r) async {
    if (r is! BrokeringResolver) {
      throw SwitchboardException.of(
        StatusCode.failedPrecondition,
        'the resolver cannot broker connections to $address',
      );
    }
    if (address.isAny) {
      throw SwitchboardException.of(
        StatusCode.invalidArgument,
        'brokering needs an instance: $address',
      );
    }
    if (verifier == null) {
      throw SwitchboardException.of(
        StatusCode.failedPrecondition,
        'brokering needs a verifier to recognise $address',
      );
    }
    final endpoint =
        brokerEndpoint ?? (_endpoints.isEmpty ? null : _endpoints.first);
    if (endpoint == null) {
      throw SwitchboardException.of(
        StatusCode.failedPrecondition,
        'no listener for $address to dial back',
      );
    }
    final intent = secureRandomBytes(_brokerIntentLength);
    final key = hexString(intent);
    final arrived = Completer<MuxConnection>()..future.ignore();
    _brokerWaits[key] = arrived;
    final watch = Stopwatch()..start();
    Duration? left() {
      if (connectTimeout <= Duration.zero) {
        return null;
      }
      final rest = connectTimeout - watch.elapsed;
      return rest > Duration.zero ? rest : Duration.zero;
    }

    MuxConnection? connection;
    try {
      final identity = await r.connectTo(
        address,
        endpoint,
        intent,
        timeout: left(),
      );
      _checkOpen();
      final bound = left();
      connection = await (bound == null
          ? arrived.future
          : arrived.future.timeout(
              bound,
              onTimeout: () => throw SwitchboardException.of(
                StatusCode.unavailable,
                '$address did not dial back within $connectTimeout',
              ),
            ));
      _checkOpen();
      final peer = connection.peerIdentity;
      if (peer == null || peer.identity != identity) {
        throw SwitchboardException.of(
          StatusCode.unauthenticated,
          'the connection for $address is not "$identity"\'s',
        );
      }
      final credential = _identity;
      if (credential != null) {
        try {
          await connection.identify(
            credential,
            holderKey: holderKey,
            receiver: identity,
            timeout: identityTimeout,
          );
        } on Object catch (e) {
          throw SwitchboardException.of(
            StatusCode.unauthenticated,
            'identification to $address failed: '
            '${e is SwitchboardException ? e.status : e}',
          );
        }
        _identified[connection] = _Identification(null, identity);
      }
      _log.fine('$address dialled back from ${_remotes[connection]}');
      return connection;
    } catch (e) {
      if (_brokerWaits.remove(key) != null) {
        // A connection that lands later is sent GOAWAY.
        _abandoned.add(key);
        if (_abandoned.length > _maxAbandoned) {
          _abandoned.remove(_abandoned.first);
        }
      }
      // The dial-back may already have arrived while CONNECT was still
      // pending. Its failure must close that connection even when we
      // never reached the await of arrived.future above.
      arrived.future.then((connection) => connection.goAway()).ignore();
      _log.fine('brokering $address failed: $e');
      if (_closing) {
        throw _closedException();
      }
      rethrow;
    }
  }

  /// Length of the random intent of a brokered connection.
  static const int _brokerIntentLength = 16;

  /// How many given-up intents are remembered.
  static const int _maxAbandoned = 256;

  /// An accepted connection identified: if its intent is one this node is
  /// waiting for ([broker]), it is that connection; if it is one the node
  /// gave up on, it is sent GOAWAY.
  void _onAcceptedIdentified(MuxConnection connection, PeerIdentity identity) {
    if (identity.intent.isEmpty) {
      return;
    }
    final key = hexString(identity.intent);
    final waiting = _brokerWaits.remove(key);
    if (waiting != null) {
      waiting.complete(connection);
    } else if (_abandoned.remove(key)) {
      _log.fine(
        'a brokered connection from "${identity.identity}" arrived too '
        'late; leaving it',
      );
      unawaited(connection.goAway());
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
  /// With [acceptAnyInstance], the registration also serves channels
  /// addressed to any instance of [type] that no registration matches
  /// exactly (step 2b of the wiki's dispatch list, before the rule for
  /// instance 0 above; among several such registrations, the first
  /// registered). This is for a service that does not know the instance
  /// id it is known by: a worker that a registrar (a scaler) registered in
  /// the naming service under an id the worker was never told, so that the
  /// channels routed to that id arrive with it in the header. It accepts
  /// whatever instance a peer names, so a node hosting several instances
  /// of [type] has no use for it.
  ///
  /// Registering an existing pair replaces its handler and its
  /// [acceptAnyInstance] flag and keeps its position. Throws [RangeError]
  /// if [instance] is outside `u48`.
  void registerService(
    Name type,
    ChannelHandler handler, {
    int instance = 0,
    bool acceptAnyInstance = false,
  }) {
    RangeError.checkValueInInterval(instance, 0, maxInstance, 'instance');
    (_services[type] ??= {})[instance] = handler;
    if (acceptAnyInstance) {
      (_anyInstance[type] ??= {}).add(instance);
    } else {
      _removeAnyInstance(type, instance);
    }
  }

  /// Removes the handler registered for `(type, instance)`, if any.
  /// Channels already dispatched to it are unaffected.
  void unregisterService(Name type, {int instance = 0}) {
    _removeAnyInstance(type, instance);
    final handlers = _services[type];
    if (handlers == null) {
      return;
    }
    handlers.remove(instance);
    if (handlers.isEmpty) {
      _services.remove(type);
    }
  }

  void _removeAnyInstance(Name type, int instance) {
    final any = _anyInstance[type];
    if (any != null && any.remove(instance) && any.isEmpty) {
      _anyInstance.remove(type);
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
    if (policy != null) {
      final refusal = _refusal(policy, address, connection);
      if (refusal == StatusCode.unauthenticated &&
          connection.peerIdentity == null &&
          identityTimeout > Duration.zero) {
        unawaited(_holdForIdentity(connection, channel, address, policy));
        return;
      }
      if (refusal != null) {
        _refuse(channel, address, remote, refusal);
        return;
      }
    }
    _deliver(channel, address, remote);
  }

  void _refuse(
    MuxChannel channel,
    ChannelAddress address,
    String? remote,
    StatusCode code,
  ) {
    _log.info(
      'channel ${channel.id} from $remote: $address refused by the '
      'policy (${code.name})',
    );
    unawaited(channel.close(genericStatus(code)));
  }

  /// Holds [channel], which [policy] refused because the peer has not
  /// identified, until the peer identifies (then evaluates the policy
  /// again), the channel or the connection ends, or [identityTimeout]
  /// passes (then refuses it with `UNAUTHENTICATED`). A closed channel
  /// leaves no per-channel listener on the pending identity event. Never fails.
  Future<void> _holdForIdentity(
    MuxConnection connection,
    MuxChannel channel,
    ChannelAddress address,
    ChannelPolicy policy,
  ) async {
    final remote = _remotes[connection];
    _log.fine(
      'channel ${channel.id} from $remote: $address held until the peer '
      'identifies',
    );
    final watch = Stopwatch()..start();
    while (true) {
      final left = identityTimeout - watch.elapsed;
      if (left <= Duration.zero) {
        break;
      }
      await waitForIdentityChange(channel, left);
      if (channel.state != MuxChannelState.open) {
        // Closed by the peer, or the connection ended.
        return;
      }
      final refusal = _refusal(policy, address, connection);
      if (refusal == null) {
        _deliver(channel, address, remote);
        return;
      }
      if (refusal != StatusCode.unauthenticated ||
          connection.peerIdentity != null) {
        _refuse(channel, address, remote, refusal);
        return;
      }
    }
    _log.info(
      'channel ${channel.id} from $remote: $address refused, the peer did '
      'not identify within $identityTimeout',
    );
    unawaited(channel.close(genericStatus(StatusCode.unauthenticated)));
  }

  /// Hands [channel] to the handler [address] selects, or refuses it with
  /// `NOT_FOUND`.
  void _deliver(MuxChannel channel, ChannelAddress address, String? remote) {
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

  /// Null when [policy] admits [address], else the code to refuse it with:
  /// that of a [SwitchboardException] the policy throws (a code a CLOSE
  /// may carry), else `PERMISSION_DENIED`.
  static StatusCode? _refusal(
    ChannelPolicy policy,
    ChannelAddress address,
    MuxConnection connection,
  ) {
    try {
      return policy(address, connection) ? null : StatusCode.permissionDenied;
    } on SwitchboardException catch (e) {
      final code = e.code;
      if (code == null ||
          code == StatusCode.ok ||
          code == StatusCode.connectionLost) {
        _log.warning('policy failed for $address: ${e.status}');
        return StatusCode.permissionDenied;
      }
      return code;
    } on Object catch (e, st) {
      _log.warning('policy failed for $address', e, st);
      return StatusCode.permissionDenied;
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
      final any = _anyInstance[type];
      if (any != null) {
        for (final MapEntry(key: instance, value: handler)
            in handlers.entries) {
          if (any.contains(instance)) {
            return handler;
          }
        }
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
  /// match any requested instance. So are records for which [where] (an
  /// application filter, for example on [ServiceRecord.metadata]) returns
  /// false; an exception it throws reaches the caller. The candidates are
  /// sorted by instance; with a [shard] slot `s` the first choice is
  /// `candidates[s mod n]`, otherwise the node's [selection] policy picks
  /// it (a per-type round-robin counter, or at random). Endpoints of the
  /// chosen instance are tried in order; if none can be connected, the
  /// following instances are tried in turn.
  ///
  /// Slot routing (wiki page "Polyverse Switchboard Sharding", section "Routing"):
  /// when [address] names any instance, a [shard] is given and the
  /// resolver is a [SlotResolver] with a slot table for the type, the
  /// channel goes to the slot's owner and nowhere else: the owner from the
  /// table ([SlotResolver.slotOwner], the old owner while the slot
  /// migrates); if the table has none, in a managed space the owner the
  /// resolver locates ([SlotResolver.locateSlot], which assigns a free
  /// slot; at most [slotRefreshTimeout], then [StatusCode.unavailable]),
  /// and in a static space the open fails with [StatusCode.unavailable].
  /// A slot outside the space fails with [StatusCode.outOfRange]; an owner
  /// that cannot be connected, or is missing from the service table, with
  /// [StatusCode.unavailable] (the resolver is asked once more before,
  /// since an owner just located may have registered after the records
  /// were read). An explicit instance bypasses slot routing (the shard is
  /// still carried in the header). An owner that [where] refuses is not
  /// found ([StatusCode.notFound]); no other instance is tried.
  ///
  /// The returned record's instance is the one to put in the address
  /// header: the selected record's instance, or the requested instance
  /// when the record's is 0.
  ///
  /// With [excludeOwnEndpoints], endpoints for which [isOwnEndpoint] holds
  /// are skipped as unreachable, so that a proxy never forwards a channel
  /// to itself.
  ///
  /// An instance whose record has no endpoints is reached through the
  /// naming service's `CONNECT` when the resolver is a
  /// [BrokeringResolver]: the instance dials this node (see [broker]), and
  /// the connection is pooled for that instance until it ends. This never
  /// goes through a [relay]: the connection returned is always to the
  /// instance itself.
  ///
  /// Throws [SwitchboardException] with [StatusCode.notFound] if no
  /// instance is known, or none that [where] accepts,
  /// [StatusCode.unavailable] if none is reachable, and
  /// [StatusCode.failedPrecondition] if there is no resolver or the node
  /// is closed; also whatever [Resolver.resolve] throws (a naming resolver
  /// that was never synced: [StatusCode.unavailable] after its resolve
  /// timeout). Throws [RangeError] if [shard] is outside `u32`.
  Future<(ServiceRecord, MuxConnection)> selectAndConnect(
    ServiceAddress address, {
    int? shard,
    Resolver? resolver,
    bool excludeOwnEndpoints = false,
    bool Function(ServiceRecord record)? where,
  }) async {
    final route = await _selectRoute(
      address,
      shard: shard,
      resolver: resolver,
      excludeOwnEndpoints: excludeOwnEndpoints,
      where: where,
      mayRelay: false,
    );
    return (route.record, route.connection);
  }

  /// [selectAndConnect]; with [mayRelay], an instance without endpoints
  /// is reached through the [relay] when this node cannot broker.
  Future<_Route> _selectRoute(
    ServiceAddress address, {
    int? shard,
    Resolver? resolver,
    bool excludeOwnEndpoints = false,
    bool Function(ServiceRecord record)? where,
    required bool mayRelay,
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
        var records = _recordsOf(known, address.type, owner);
        if (records.isEmpty) {
          // An owner that registered while the slot was located is not in
          // the records read before.
          records = _recordsOf(
            await r.resolve(address.type),
            address.type,
            owner,
          );
          _checkOpen();
        }
        if (records.isEmpty) {
          throw SwitchboardException.of(
            StatusCode.unavailable,
            'owner ${ServiceAddress(address.type, owner)} of slot $shard is '
            'not in the service table',
          );
        }
        final accepted = _filtered(records, where);
        if (accepted.isEmpty) {
          throw SwitchboardException.of(
            StatusCode.notFound,
            'owner ${ServiceAddress(address.type, owner)} of slot $shard '
            'does not match the filter',
          );
        }
        return _connectFirst(
          ServiceAddress(address.type, owner),
          accepted,
          0,
          excludeOwnEndpoints,
          r,
          mayRelay,
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
    final accepted = _filtered(candidates, where);
    if (accepted.isEmpty) {
      throw SwitchboardException.of(
        StatusCode.notFound,
        'none of the ${candidates.length} known instances of $address '
        'matches the filter',
      );
    }
    accepted.sort((a, b) => a.address.instance.compareTo(b.address.instance));
    final start = shard != null
        ? shard % accepted.length
        : _selectStart(address.type, accepted.length);
    return _connectFirst(
      address,
      accepted,
      start,
      excludeOwnEndpoints,
      r,
      mayRelay,
    );
  }

  /// The records of instance [instance] of [type] among [records].
  static List<ServiceRecord> _recordsOf(
    List<ServiceRecord> records,
    Name type,
    int instance,
  ) => [
    for (final record in records)
      if (record.address.type == type && record.address.instance == instance)
        record,
  ];

  static List<ServiceRecord> _filtered(
    List<ServiceRecord> records,
    bool Function(ServiceRecord record)? where,
  ) => where == null ? records : records.where(where).toList();

  /// The index among [count] candidates of [type] that the [selection]
  /// policy picks first.
  int _selectStart(Name type, int count) => switch (selection) {
    SelectionPolicy.roundRobin => _nextRoundRobin(type) % count,
    SelectionPolicy.random => _random.nextInt(count),
  };

  /// Connects to the first reachable of [candidates], starting at [start]
  /// and going round; an instance without endpoints is brokered through
  /// [resolver] when it can, or, with [mayRelay] on a node that cannot
  /// broker, reached through the [relay].
  Future<_Route> _connectFirst(
    ServiceAddress address,
    List<ServiceRecord> candidates,
    int start,
    bool excludeOwnEndpoints,
    Resolver resolver,
    bool mayRelay,
  ) async {
    final n = candidates.length;
    final failures = <String>[];
    // One relay connection for every candidate that needs it.
    Future<(ServiceRecord, MuxConnection)>? relayed;
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
          final connection = await connect(endpoint, record: record);
          // A record for any instance (an endpoint resolver's) stands for
          // the instance asked for, metadata included (credentialFor reads
          // it).
          final selected = record.address.isAny && !address.isAny
              ? ServiceRecord(
                  address,
                  endpoints: record.endpoints,
                  metadata: record.metadata,
                )
              : record;
          return _Route(selected, connection);
        } on SwitchboardException catch (e) {
          if (_closing) {
            rethrow;
          }
          _log.fine('$address: ${record.address} at $endpoint: ${e.status}');
          failures.add('$endpoint: ${e.status}');
        }
      }
      if (record.endpoints.isEmpty) {
        final config = mayRelay && !canBroker ? relay : null;
        if (config != null && !record.address.isAny) {
          try {
            final (via, connection) = await (relayed ??= _connectRelay(
              config,
              resolver,
            ));
            _log.fine(
              '$address: ${record.address} through the relay ${via.address} '
              'at ${_dialled[connection] ?? _remotes[connection]}',
            );
            return _Route(record, connection, relayType: config.type);
          } on SwitchboardException catch (e) {
            if (_closing) {
              rethrow;
            }
            _log.fine('$address: relaying to ${record.address}: ${e.status}');
            failures.add('${record.address} (relayed): ${e.status}');
            continue;
          }
        }
        if (resolver is! BrokeringResolver || record.address.isAny) {
          failures.add('${record.address}: no endpoints');
          continue;
        }
        try {
          final connection = await _brokeredPooled(record.address, resolver);
          return _Route(record, connection);
        } on SwitchboardException catch (e) {
          if (_closing) {
            rethrow;
          }
          _log.fine('$address: brokering ${record.address}: ${e.status}');
          failures.add('${record.address} (brokered): ${e.status}');
        }
      }
    }
    throw SwitchboardException.of(
      StatusCode.unavailable,
      'no reachable instance of $address (${failures.join('; ')})',
    );
  }

  // Relays ----------------------------------------------------------------

  /// The relays this node would open a relayed channel through now (see
  /// [relay]), in the order it would try them: one record per explicit
  /// [RelayConfig.endpoints] entry (instance 0, the configured identity as
  /// metadata), or the records of [RelayConfig.type] that [resolver]
  /// (default: the node's) knows with endpoints, sorted by instance; the
  /// first is picked by the node's [selection] policy (each call moves the
  /// round robin on) and the others follow in turn, for failover. Each
  /// record's metadata is the relay's identity.
  ///
  /// For opening relayed channels on connections of the caller's own, as
  /// `PeerSet` does: [dial] a relay's endpoint with its record, which names
  /// the relay as the receiver of the node's `IDENT`.
  ///
  /// Fails with [SwitchboardException]: [StatusCode.failedPrecondition]
  /// without a [relay], without a resolver to find the relays in, or
  /// after [close]; [StatusCode.notFound] when no relay is known; and like
  /// [Resolver.resolve].
  Future<List<ServiceRecord>> resolveRelays({Resolver? resolver}) async {
    _checkOpen();
    final config = relay;
    if (config == null) {
      throw SwitchboardException.of(
        StatusCode.failedPrecondition,
        'no relay configured',
      );
    }
    return _relayCandidates(config, resolver ?? this.resolver);
  }

  Future<List<ServiceRecord>> _relayCandidates(
    RelayConfig config,
    Resolver? resolver,
  ) async {
    final explicit = config.endpoints;
    final List<ServiceRecord> records;
    if (explicit != null) {
      final identity = config.identity;
      final metadata = identity == null
          ? null
          : Uint8List.fromList(utf8.encode(identity));
      records = [
        for (final endpoint in explicit)
          ServiceRecord(
            ServiceAddress(config.type),
            endpoints: [endpoint],
            metadata: metadata,
          ),
      ];
    } else {
      if (resolver == null) {
        throw SwitchboardException.of(
          StatusCode.failedPrecondition,
          'no resolver to find the relays in',
        );
      }
      final known = await resolver.resolve(config.type);
      _checkOpen();
      records = [
        for (final record in known)
          if (record.address.type == config.type && record.endpoints.isNotEmpty)
            record,
      ]..sort((a, b) => a.address.instance.compareTo(b.address.instance));
    }
    if (records.isEmpty) {
      throw SwitchboardException.of(
        StatusCode.notFound,
        'no relay of ${config.type} known',
      );
    }
    final n = records.length;
    final start = _selectStart(config.type, n);
    return [for (var i = 0; i < n; i++) records[(start + i) % n]];
  }

  /// A pooled connection to the first relay that answers, with its record.
  Future<(ServiceRecord, MuxConnection)> _connectRelay(
    RelayConfig config,
    Resolver resolver,
  ) async {
    final failures = <String>[];
    for (final record in await _relayCandidates(config, resolver)) {
      for (final endpoint in record.endpoints) {
        try {
          return (record, await connect(endpoint, record: record));
        } on SwitchboardException catch (e) {
          if (_closing) {
            rethrow;
          }
          _log.fine('relay ${record.address} at $endpoint: ${e.status}');
          failures.add('$endpoint: ${e.status}');
        }
      }
    }
    throw SwitchboardException.of(
      StatusCode.unavailable,
      'no reachable relay (${failures.join('; ')})',
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
      entry = await r
          .locateSlot(type, slot)
          .timeout(
            slotRefreshTimeout,
            onTimeout: () => throw SwitchboardException.of(
              StatusCode.unavailable,
              'slot $type/$slot not located within $slotRefreshTimeout',
            ),
          );
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
  /// `{type, selected instance, shard}` and [payload] as the application
  /// payload (default: what [credentialFor] gives for the endpoint and the
  /// selected record, or [defaultPayload] without that hook).
  ///
  /// The channel is returned at once; a rejection by the peer arrives as
  /// its close status ([MuxChannel.done]). Only records [where] accepts
  /// are candidates (see [selectAndConnect]). Throws like
  /// [selectAndConnect], like [MuxConnection.open] (for example
  /// [StatusCode.resourceExhausted]), and like [credentialFor].
  ///
  /// An instance without endpoints is brokered (see [selectAndConnect]),
  /// or, on a node that cannot broker, reached through its [relay]: the
  /// channel returned is then the relay channel, whose open payload
  /// carries the destination's.
  Future<MuxChannel> openChannel(
    ServiceAddress address, {
    int? shard,
    Uint8List? payload,
    bool Function(ServiceRecord record)? where,
  }) async {
    final (channel, _) = await openSelected(
      address,
      ChannelAddress(type: address.type, shard: shard, payload: payload),
      where: where,
      implicitPayload: payload == null,
      mayRelay: true,
    );
    return channel;
  }

  /// Selects and connects like [selectAndConnect] (through the [relay]
  /// when [mayRelay] and the node cannot broker the instance selected)
  /// and opens a channel with [header] there, its instance set to the
  /// selected one and its host hint removed; with [implicitPayload], the
  /// application payload is the node's for the connection and the record
  /// selected (see [payloadFor]). A pooled connection that went away or
  /// filled up in the meantime is replaced once. Returns the channel and
  /// the header of the destination (inside the relay channel's payload
  /// when relayed). For [openChannel], [openChannelToSlot]'s `MOVED` retry
  /// and the proxy. Throws like [openChannel].
  @internal
  Future<(MuxChannel, ChannelAddress)> openSelected(
    ServiceAddress address,
    ChannelAddress header, {
    Resolver? resolver,
    bool excludeOwnEndpoints = false,
    bool Function(ServiceRecord record)? where,
    bool implicitPayload = false,
    bool mayRelay = false,
  }) async {
    for (var attempt = 0; ; attempt++) {
      final route = await _selectRoute(
        address,
        shard: header.shard,
        resolver: resolver,
        excludeOwnEndpoints: excludeOwnEndpoints,
        where: where,
        mayRelay: mayRelay,
      );
      var selected = header.copyWith(
        instance: route.record.address.instance,
        clearHost: true,
      );
      if (implicitPayload) {
        final implicit = _implicitPayload(route.connection, route.record);
        selected = selected.copyWith(
          payload: implicit is Future<Uint8List> ? await implicit : implicit,
        );
      }
      try {
        return (route.open(selected), selected);
      } on SwitchboardException catch (e) {
        if (!_retryOpen(e, attempt)) {
          rethrow;
        }
      }
    }
  }

  /// Opens a channel to the owner of [slot] of [type], with the `MOVED`
  /// retry of the wiki page "Polyverse Switchboard Sharding", section "Routing".
  ///
  /// The first channel is opened as [openChannel] with `shard: slot` does
  /// (slot routing through a [SlotResolver]; through any other resolver,
  /// such as the [EndpointResolver] of a frontend client, the endpoint
  /// routes). If the owner rejects it with CLOSE `MOVED` before anything
  /// was sent or received, it is retried once, with the same [payload]
  /// (default: the payload [openChannel] gives the new destination): to
  /// the owner the rejection names (`MovedStatus`), unless the resolver's
  /// table has a more recent one; when it names none, to the owner the
  /// resolver finds by asking ([SlotResolver.locateSlot], bounded by
  /// [slotRefreshTimeout]); through a resolver without slot tables, the
  /// same address again. When the
  /// refresh finds no owner other than the instance that rejected, or the
  /// retry fails, the returned channel ends with the `MOVED` status. See
  /// [SlotChannel] for why a `MOVED` after the first subframe is not
  /// retried (the caller may open again and resend: nothing was
  /// processed) and why a `RELOCATED` never is. Subframes sent while the
  /// replacement is being opened are held, at most
  /// [MuxOptions.maxChannelBufferBytes] of [muxOptions]
  /// ([SlotChannel.maxHeldBytes]); beyond, the channel is closed with
  /// `RESOURCE_EXHAUSTED`.
  ///
  /// [where] applies to the first channel and to the retry: an owner it
  /// refuses is not found (see [selectAndConnect]); on the retry, the
  /// returned channel then ends with that [StatusCode.notFound] status
  /// instead of `MOVED`.
  ///
  /// Without a [payload], each channel carries the payload [openChannel]
  /// would give its destination: the retry asks [credentialFor] again for
  /// the new owner, so a per-destination credential never reaches the
  /// other instance.
  ///
  /// Throws like [openChannel].
  Future<SlotChannel> openChannelToSlot(
    Name type,
    int slot, {
    Uint8List? payload,
    bool Function(ServiceRecord record)? where,
  }) async {
    final header = ChannelAddress(type: type, shard: slot, payload: payload);
    final (first, selected) = await openSelected(
      ServiceAddress(type),
      header,
      where: where,
      implicitPayload: payload == null,
      mayRelay: true,
    );
    final rejectedBy = selected.instance;
    return SlotChannel(
      type,
      slot,
      first,
      (moved) => reopenAtSlotOwner(
        this,
        header,
        rejectedBy,
        moved,
        where: where,
        implicitPayload: payload == null,
        mayRelay: true,
      ),
      maxHeldBytes: muxOptions.maxChannelBufferBytes,
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
    bool Function(ServiceRecord record)? where,
  }) async => TalkChannel(
    await openChannelToSlot(type, slot, payload: payload, where: where),
    options: options ?? talkOptions,
  );

  /// [openChannel] wrapped in a [TalkChannel] with [options] (default:
  /// [talkOptions]).
  Future<TalkChannel> openTalk(
    ServiceAddress address, {
    int? shard,
    Uint8List? payload,
    TalkOptions? options,
    bool Function(ServiceRecord record)? where,
  }) async => TalkChannel(
    await openChannel(address, shard: shard, payload: payload, where: where),
    options: options ?? talkOptions,
  );

  /// Opens a channel to an explicit [endpoint] with [address] as the OPEN
  /// payload, bypassing resolution. This is how a frontend client reaches
  /// its endpoint and how a service reaches the naming service.
  ///
  /// The header (including a host hint, for relays) is sent as given. If
  /// [ChannelAddress.payload] is empty, the payload [credentialFor] gives
  /// for [endpoint] (with no record) is sent instead, or [defaultPayload]
  /// without that hook; to send an empty application payload from a node
  /// that has a default payload, use [connect] and [MuxConnection.open].
  /// Throws like [connect], [MuxConnection.open] and [credentialFor].
  Future<MuxChannel> openChannelAt(Uri endpoint, ChannelAddress address) async {
    var bytes = address.payload.isEmpty ? null : address.encode();
    for (var attempt = 0; ; attempt++) {
      final connection = await connect(endpoint);
      if (bytes == null) {
        final implicit = _credential(endpoint, null);
        final application = implicit is Future<Uint8List>
            ? await implicit
            : implicit;
        bytes = address.copyWith(payload: application).encode();
      }
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
  /// locally (symmetric dispatch). An empty [ChannelAddress.payload] is
  /// replaced as for [openChannelAt]: by [defaultPayload], or with
  /// [credentialFor] set, by the hook's payload for the endpoint a
  /// connection this node initiated goes to, and by an empty payload on a
  /// connection this node accepted (it has no destination endpoint).
  ///
  /// Throws like [MuxConnection.open]. Throws [StateError] when the
  /// payload would come from [credentialFor] and the hook answers with a
  /// future: this call cannot wait, so pass the payload in [address] (see
  /// [payloadFor]).
  MuxChannel openChannelOn(MuxConnection connection, ChannelAddress address) {
    if (address.payload.isNotEmpty) {
      return connection.open(address.encode());
    }
    final implicit = _implicitPayload(connection, null);
    if (implicit is Future<Uint8List>) {
      implicit.ignore();
      throw StateError(
        'credentialFor answered asynchronously; openChannelOn needs the '
        'payload in the address',
      );
    }
    return connection.open(address.copyWith(payload: implicit).encode());
  }

  /// The application payload this node attaches to a channel it opens on
  /// [connection] when the caller supplies none: with [credentialFor], the
  /// hook's result for the endpoint [connection] was established to
  /// ([connect], [dial]) and [record] (null: an empty payload), or an
  /// empty payload for a connection this node accepted; without the hook,
  /// [defaultPayload].
  ///
  /// For opening channels on a connection directly (`PeerSet` does, and
  /// an application can before [openChannelOn] when the hook is
  /// asynchronous). Fails like [credentialFor].
  Future<Uint8List> payloadFor(
    MuxConnection connection, {
    ServiceRecord? record,
  }) async => _implicitPayload(connection, record);

  FutureOr<Uint8List> _implicitPayload(
    MuxConnection connection,
    ServiceRecord? record,
  ) {
    if (credentialFor == null) {
      return defaultPayload;
    }
    final endpoint = _dialled[connection];
    if (endpoint == null) {
      // Accepted: there is no destination endpoint to choose for.
      return Uint8List(0);
    }
    return _credential(endpoint, record);
  }

  /// The payload for [endpoint] by [credentialFor], or [defaultPayload]
  /// without the hook.
  FutureOr<Uint8List> _credential(Uri endpoint, ServiceRecord? record) {
    final hook = credentialFor;
    if (hook == null) {
      return defaultPayload;
    }
    final result = hook(endpoint, record);
    if (result is Future<Uint8List?>) {
      return result.then((payload) => payload ?? Uint8List(0));
    }
    return result ?? Uint8List(0);
  }

  /// A pooled connection may receive GOAWAY, or fill up to its peer's
  /// channel limit, between [connect] and the OPEN; one retry replaces it.
  bool _retryOpen(SwitchboardException e, int attempt) =>
      attempt == 0 &&
      (e.code == StatusCode.failedPrecondition ||
          e.code == StatusCode.resourceExhausted) &&
      !_closing;

  // Shutdown ------------------------------------------------------------

  /// Shuts the node down: stops listening (the ids of [listenMemory] are
  /// released at once, so connecting to them fails with
  /// [StatusCode.unavailable]), sends GOAWAY on every connection and waits
  /// for each to finish its channels (up to [MuxOptions.goAwayGrace]) and
  /// close. Further calls to [connect] and the open methods fail with
  /// [StatusCode.failedPrecondition].
  ///
  /// Connections that are established while closing (a WebSocket upgrade
  /// or a dial that was in progress, a TCP connection accepted before the
  /// listener closed, a transport given to [accept]) receive GOAWAY at
  /// once, and the returned future waits for them too (for upgrades and
  /// dials in progress, at most [connectTimeout]). An HTTP request in progress when closing starts is
  /// still answered; its connection is closed afterwards, and at the latest
  /// when the node has closed.
  ///
  /// The [resolver] is owned by the caller and is not closed. Calling
  /// again returns the same future. Never throws.
  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    _closing = true;
    _log.info('closing');
    final waits = List.of(_brokerWaits.values);
    _brokerWaits.clear();
    for (final wait in waits) {
      wait.completeError(_closedException());
    }
    _brokeredPool.clear();
    final http = List.of(_httpServers);
    final tcp = List.of(_tcpServers);
    _httpServers.clear();
    _tcpServers.clear();
    for (final id in _memoryIds) {
      MemoryEndpoints.unregister(id);
    }
    _memoryIds.clear();
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

/// Where an open goes: the destination's [record] (its instance the one
/// to put in the header) and the [connection] to send the OPEN on, to the
/// instance itself, or to a relay of [relayType].
class _Route {
  _Route(this.record, this.connection, {this.relayType});

  final ServiceRecord record;
  final MuxConnection connection;
  final Name? relayType;

  /// Opens the channel with [header], the destination's: inside a relay
  /// channel's payload when relayed.
  MuxChannel open(ChannelAddress header) {
    final relay = relayType;
    return connection.open(
      relay == null
          ? header.encode()
          : ChannelAddress(type: relay, payload: header.encode()).encode(),
    );
  }
}

/// The intent and receiver of an identification of the node.
class _Identification {
  _Identification(this.intent, this.receiver);

  final Uint8List? intent;
  final String? receiver;
}

/// A listening endpoint and the host names that designate it.
class _OwnEndpoint {
  _OwnEndpoint(this.uri, this.hosts);

  final Uri uri;
  final Set<String> hosts;
}
