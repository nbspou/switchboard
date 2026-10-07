/*
Polyverse Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Authors:
  Jan Boon <jan.boon@kaetemi.be>
  Claude Opus 5.5 <noreply@anthropic.com>
*/

import 'dart:async';

import 'package:logging/logging.dart';

import '../address/channel_address.dart';
import '../identity/credential.dart';
import '../identity/peer_identity.dart';
import '../mux/mux_channel.dart';
import '../naming/naming_protocol.dart';
import '../status.dart';
import 'forwarding.dart';
import 'generic_status.dart';
import 'incoming_channel.dart';
import 'proxy.dart';
import 'resolver.dart';
import 'switchboard.dart';

final Logger _log = Logger('Switchboard.Relay');

/// The `_relay` service ([Services.relay]): forwards channels to instances
/// registered without endpoints, which listen nowhere, on behalf of
/// consumers that listen nowhere either (wiki page "Polyverse Switchboard Identity
/// and Credentials", section "Relay"; use case 5c).
///
/// A consumer opens a channel of type `_relay` whose application payload
/// is the complete open payload of the channel to relay: the address
/// header of the destination, then the application payload for it
/// (`Switchboard.relay` does this). For each such channel, [handler]:
///
/// 1. Reads the peer identity of the connection it arrived on. Without
///    one, the channel is held for the consumer to identify, at most the
///    node's [Switchboard.identityTimeout], so that a consumer whose OPEN
///    overtakes its `IDENT` is checked under the identity the `IDENT`
///    establishes; a channel that ends while held is dropped. A consumer
///    still unidentified after the hold is refused with `UNAUTHENTICATED`
///    when [requireIdentity] (the default), and admitted unchecked
///    otherwise. A node without a verifier ([Switchboard.verifier])
///    identifies nobody: there, without [requireIdentity], an
///    unidentified consumer is admitted at once, without the hold.
/// 2. Decodes the inner open payload: malformed, without a service type,
///    with a host hint, or addressing a reserved type (any name starting
///    with `_`: no chains of relays, no naming service through a relay):
///    `INVALID_ARGUMENT`.
/// 3. Checks that an identified consumer's credential has `open` for the
///    inner type: `PERMISSION_DENIED` otherwise. The instance sees only
///    the relay's identity, so the consumer's scopes are checked here.
///    An unidentified consumer (admitted without [requireIdentity]) is
///    not checked. A consumer that identifies (again) while the channel
///    to the instance is being opened (steps 4 to 7) is checked again
///    under its new identity: if that may not open the type, the channel
///    to the instance is closed (`CANCELLED`) and the consumer's refused
///    with `PERMISSION_DENIED`. An identity that arrives once the two
///    channels are piped does not affect them.
/// 4. Bounds the channels it relays per consumer connection to
///    [maxChannelsPerConnection] (0: no bound): `RESOURCE_EXHAUSTED`
///    beyond, since every consumer shares the relay's connection to each
///    instance.
/// 5. Resolves the inner address with [resolver] (default: the node's) as
///    `Switchboard.selectAndConnect` does: the instance it names, else the
///    owner of its shard slot through the slot table, else round robin.
///    No record: `NOT_FOUND`. A record with endpoints:
///    `FAILED_PRECONDITION` (the consumer can reach it directly), unless
///    [allowEndpoints], in which case the relay connects to its endpoints
///    as a proxy does, never to this node's own listeners.
/// 6. Brokers a connection to the instance through the naming service's
///    `CONNECT` with this node's listener and credential
///    (`Switchboard.broker`), pooled by instance and shared by every
///    consumer: one connection per instance however many consumers relay
///    to it. A brokering failure is `UNAVAILABLE`.
/// 7. Opens the channel to the instance over it with the inner open
///    payload (the selected instance filled in, the application payload
///    unchanged) and pipes the two channels ([pipeChannels]): data
///    unchanged both ways, the CLOSE status of either side forwarded to
///    the other (a refusal by the instance relayed unchanged, `MOVED` and
///    `RELOCATED` with their owner and epoch byte for byte), a lost
///    connection on either side reported to the other as `UNAVAILABLE`.
///
/// Refusals carry the status code and a generic reason; the details go to
/// the log (`Switchboard.Relay`, at FINE and INFO).
///
/// The relay node: a [Switchboard] that listens where consumers and
/// instances can reach it, joined to the mesh (`MeshNode.join`) with its
/// own credential, registered as `_relay` with its identity in the
/// record's metadata (`MeshNode.publishRelay`), and a verifier, so that it
/// can tell who connected. Its credential has `register _relay`, and
/// `broker`, `open` and `watch` for the types it relays: the instance
/// checks the relay's `open` scope, and the naming service its `broker`
/// right. Give its node `MuxOptions(requireNamedIdent: true)`, as the
/// naming service's host has, so that no identification a consumer meant
/// for another peer can be relayed to it (the constructor logs a warning
/// otherwise), and give its listener
/// [ChannelPolicies.scoped] (which admits `_relay` for every identified
/// peer and refuses everything else a consumer has no `open` scope for).
///
/// ```dart
/// final node = Switchboard(
///   muxOptions: const MuxOptions(requireNamedIdent: true),
///   credential: relayCredential,
///   holderKey: relayKey,
///   verifier: verifier,
///   expectedIdentityFor: (endpoint, record) =>
///       endpoint == namingEndpoint ? 'ns' : null,
/// );
/// await node.listenTcp('0.0.0.0', 9400, policy: ChannelPolicies.scoped());
/// final mesh = MeshNode.join(node, namingEndpoint);
/// await mesh.publishRelay(RelayService(node));
/// ```
class RelayService {
  /// A relay forwarding through [switchboard] (see the class
  /// documentation). Throws [RangeError] for a negative
  /// [maxChannelsPerConnection]. Logs a warning when [switchboard] does
  /// not require named identifications (`MuxOptions.requireNamedIdent`),
  /// which a relay's host should.
  RelayService(
    this.switchboard, {
    this.requireIdentity = true,
    this.allowEndpoints = false,
    this.maxChannelsPerConnection = 1024,
    this.resolver,
  }) : _bound = ForwardingBound(maxChannelsPerConnection) {
    RangeError.checkNotNegative(
      maxChannelsPerConnection,
      'maxChannelsPerConnection',
    );
    if (!switchboard.muxOptions.requireNamedIdent) {
      _log.warning(
        'relay: the node accepts identifications that name nobody, so an '
        'IDENT a consumer meant for another peer can be relayed to it; '
        'give the relay\'s node MuxOptions(requireNamedIdent: true)',
      );
    }
  }

  /// The node the relay forwards through: its resolver, listener and
  /// credential broker the connections to the instances.
  final Switchboard switchboard;

  /// Whether consumers must identify (`IDENT`) to have channels relayed.
  /// Default true.
  ///
  /// An identified consumer is held to its `open` scopes either way: a
  /// channel of a consumer that has not identified is held until it does,
  /// at most the node's [Switchboard.identityTimeout], whatever this
  /// says, so that an OPEN that overtakes the consumer's `IDENT` is
  /// checked under the identity the `IDENT` establishes, and a consumer
  /// that identifies while its channel is being opened is checked again.
  /// Only what happens after the hold differs: with [requireIdentity], a
  /// consumer still unidentified is refused with `UNAUTHENTICATED`;
  /// without, it is admitted unchecked (a mesh without identities, or
  /// moving to them), after waiting out the hold (none with a timeout of
  /// zero). A node without a verifier ([Switchboard.verifier]) identifies
  /// nobody, so there, without [requireIdentity], an unidentified consumer
  /// is admitted at once.
  final bool requireIdentity;

  /// Whether destinations whose records have endpoints are relayed too
  /// (connected to like a proxy does), for consumers whose network cannot
  /// reach the mesh's endpoints. Default false: such a channel is refused
  /// with `FAILED_PRECONDITION`.
  final bool allowEndpoints;

  /// Largest number of channels relayed at once for one consumer
  /// connection; 0 for no bound. Default 1024.
  final int maxChannelsPerConnection;

  /// The resolver of the destinations; null for the node's.
  final Resolver? resolver;

  final ForwardingBound _bound;

  /// Serves `_relay` channels; register it as the handler of
  /// [Services.relay] (`MeshNode.publishRelay` does).
  ChannelHandler get handler => _relay;

  Future<void> _relay(IncomingChannel incoming) async {
    final connection = incoming.connection;
    var identity = incoming.peerIdentity;
    if (identity == null && (requireIdentity || switchboard.verifier != null)) {
      // Held even when unidentified consumers may pass, so that an OPEN
      // that overtakes the IDENT is checked under the identity it
      // establishes.
      identity = await _identified(incoming);
      if (identity == null) {
        if (incoming.channel.state != MuxChannelState.open) {
          _log.fine(
            'relay: $incoming ended while held for the consumer to identify',
          );
          return;
        }
        if (requireIdentity) {
          _log.info(
            'relay: $incoming refused, the consumer has not identified',
          );
          await incoming.reject(genericStatus(StatusCode.unauthenticated));
          return;
        }
      }
    }
    final ChannelAddress inner;
    try {
      inner = ChannelAddress.decode(incoming.address.payload);
    } on ProtocolException catch (e) {
      _log.fine('relay: $incoming carries a malformed open payload: $e');
      await incoming.reject(genericStatus(StatusCode.invalidArgument));
      return;
    }
    final type = inner.type;
    if (type == null || inner.host != null || type.isReserved) {
      _log.fine(
        'relay: $incoming refused, it addresses $inner, which a relay does '
        'not forward to',
      );
      await incoming.reject(genericStatus(StatusCode.invalidArgument));
      return;
    }
    final who = identity == null
        ? 'an unidentified consumer'
        : '"${identity.identity}"';
    if (identity != null && !identity.allows(Right.open, type)) {
      _log.info('relay: $incoming refused, $who may not open $type');
      await incoming.reject(genericStatus(StatusCode.permissionDenied));
      return;
    }
    if (!_bound.enter(connection)) {
      _log.info(
        'relay: $incoming refused, ${_bound.countOf(connection)} channels '
        'of this connection are being relayed',
      );
      await incoming.reject(genericStatus(StatusCode.resourceExhausted));
      return;
    }
    try {
      var hasEndpoints = false;
      final ForwardTarget target;
      try {
        target = await openForwarded(
          switchboard,
          inner,
          type,
          resolver: resolver,
          where: allowEndpoints
              ? null
              : (record) {
                  if (record.endpoints.isEmpty) {
                    return true;
                  }
                  hasEndpoints = true;
                  return false;
                },
        );
      } on SwitchboardException catch (e) {
        var code = e.code ?? StatusCode.unavailable;
        if (code == StatusCode.notFound && hasEndpoints) {
          _log.fine(
            'relay: $incoming refused, ${inner.address} is reachable '
            'directly',
          );
          code = StatusCode.failedPrecondition;
        } else {
          _log.info('relay: $incoming for $who: ${e.status}');
        }
        await incoming.reject(genericStatus(code));
        return;
      }
      final channel = target.channel;
      // The consumer may have identified (again) while the channel to the
      // instance was being opened: the identity it has now is the one held
      // to its scopes.
      final now = connection.peerIdentity;
      if (now != null &&
          !identical(now, identity) &&
          !now.allows(Right.open, type)) {
        _log.info(
          'relay: $incoming refused, the consumer identified as '
          '"${now.identity}" while the channel to the instance was being '
          'opened, and may not open $type',
        );
        unawaited(channel.close(genericStatus(StatusCode.cancelled)));
        await incoming.reject(genericStatus(StatusCode.permissionDenied));
        return;
      }
      _log.fine(
        'relay: $incoming for $who piped to ${target.header.address} on '
        'channel ${channel.id} of ${channel.connection}',
      );
      await pipeChannels(incoming.channel, channel);
    } finally {
      _bound.exit(connection);
    }
  }

  /// The identity the consumer of [incoming] presents once it identifies,
  /// within the node's [Switchboard.identityTimeout] (zero: not waited
  /// for); null when it did not, or the channel ended meanwhile.
  Future<PeerIdentity?> _identified(IncomingChannel incoming) async {
    final connection = incoming.connection;
    final channel = incoming.channel;
    final timeout = switchboard.identityTimeout;
    if (timeout > Duration.zero) {
      _log.fine('relay: $incoming held until the consumer identifies');
    }
    final watch = Stopwatch()..start();
    while (connection.peerIdentity == null) {
      final left = timeout - watch.elapsed;
      if (left <= Duration.zero || channel.state != MuxChannelState.open) {
        return null;
      }
      await Future.any<void>([connection.identityChanged, channel.done])
          .timeout(left, onTimeout: () {});
    }
    return connection.peerIdentity;
  }
}
