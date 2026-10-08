/*
Polyverse Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Authors:
  Jan Boon <jan.boon@kaetemi.be>
  Claude Opus 5.5 <noreply@anthropic.com>
*/

import '../address/channel_address.dart';
import '../identity/credential.dart';
import '../mux/mux_connection.dart';
import '../name.dart';
import '../naming/naming_protocol.dart';
import '../status.dart';

/// The policy of a connection: decides whether the peer may address
/// [address] at all.
///
/// A listener's policy applies to every connection it accepts; an outgoing
/// policy (`Switchboard.outgoingPolicy`, `Switchboard.endpointPolicy`, or
/// the `policy` of `Switchboard.connect` and `Switchboard.dial`) to a
/// connection this node initiates. Evaluated for every channel the peer
/// opens on the connection, after the address header is parsed and before
/// any handler is chosen (local services, the default service and the
/// catch-all alike). A channel the policy refuses is closed with
/// `PERMISSION_DENIED` and a generic reason. [connection] is the
/// connection the channel arrived on.
///
/// A policy that throws refuses the channel: with the status code of a
/// [SwitchboardException] it throws (`UNAUTHENTICATED` for a peer that has
/// not identified, as [ChannelPolicies.requireIdentity] does; the reason
/// sent is generic), with `PERMISSION_DENIED` for anything else (logged).
/// A refusal with `UNAUTHENTICATED` on a connection whose peer has no
/// [MuxConnection.peerIdentity] yet holds the channel until the peer
/// identifies, for at most the node's `identityTimeout`, and evaluates the
/// policy again then.
///
/// A policy never sees bulk channels (the reserved type `_bulk`): they
/// carry the payload of a message of a channel the policy admitted
/// already, and are routed to that channel's Talk layer before any policy
/// (`TalkChannel.adoptBulk`), or refused `FAILED_PRECONDITION` without one.
///
/// The peer's identity is [MuxConnection.peerIdentity] of [connection].
/// See the wiki pages "Switchboard Addressing and Dispatch", sections
/// "Dispatch of incoming channels" and "Connections and identity", and
/// "Switchboard Identity and Credentials".
typedef ChannelPolicy = bool Function(
  ChannelAddress address,
  MuxConnection connection,
);

/// Ready-made [ChannelPolicy] values.
///
/// A listener facing untrusted peers must refuse the reserved types
/// (`_ns` and the rest of the `_` namespace) unless deliberately opened;
/// otherwise a peer could register services in the naming service and
/// receive other peers' channels and credentials.
abstract final class ChannelPolicies {
  /// Allows everything: the behaviour of a listener without a policy. For
  /// internal listeners only.
  static bool allowAll(ChannelAddress address, MuxConnection connection) =>
      true;

  /// Refuses every channel. For connections to untrusted peers that have
  /// no business opening channels towards this node, such as the
  /// connections a consumer initiates to workers it does not trust (see
  /// `Switchboard.outgoingPolicy`).
  static bool denyAll(ChannelAddress address, MuxConnection connection) =>
      false;

  /// Refuses channels to reserved types (names starting with `_`, such as
  /// the naming service `_ns`); allows everything else, including channels
  /// without a service type.
  static bool denyReserved(ChannelAddress address, MuxConnection connection) =>
      !(address.type?.isReserved ?? false);

  /// Allows only channels to the service types in [types] (any instance).
  /// Channels without a service type (for the default service) are allowed
  /// only with [untyped]. A reserved type is allowed only if it is listed.
  ///
  /// Returns a new closure on every call, and closures are equal only to
  /// themselves: create one and reuse it when passing it to
  /// `Switchboard.connect(policy:)`, which pools connections per policy
  /// object, or every call gets a connection of its own.
  static ChannelPolicy allowTypes(Set<Name> types, {bool untyped = false}) {
    final allowed = Set<Name>.of(types);
    return (address, connection) {
      final type = address.type;
      return type == null ? untyped : allowed.contains(type);
    };
  }

  /// Admits a channel only if the peer's credential has an [Right.open]
  /// scope for its type (wiki page "Polyverse Switchboard Identity and
  /// Credentials", section "Where credentials are checked"); refuses the
  /// others with `PERMISSION_DENIED`. A channel without a service type is
  /// checked as the empty name, which only a `*` pattern matches. The
  /// naming service `_ns` ([Services.naming]) is admitted for every
  /// identified peer: it checks the credential's naming rights
  /// (`register`, `watch`, ...) itself, and a worker that may open nothing
  /// must still register. So is the relay `_relay` ([Services.relay]):
  /// it checks the consumer's `open` scope for the type of every channel
  /// it relays itself (`RelayService`), since the channel it opens on
  /// arrives as a `_relay` channel.
  ///
  /// A peer that has not identified (or whose credential expired) is
  /// refused with `UNAUTHENTICATED` when [requireIdentity] (the default),
  /// which makes the node hold its channels until it identifies (see
  /// [ChannelPolicy]); without [requireIdentity] it passes unchecked, for
  /// a mesh moving to identities (combine with another policy, see [all],
  /// to restrict it).
  ///
  /// Returns one of two fixed functions, so that the results of calls with
  /// the same argument are equal (pooling in `Switchboard.connect` compares
  /// policies).
  static ChannelPolicy scoped({bool requireIdentity = true}) =>
      requireIdentity ? _scopedStrict : _scopedLenient;

  static bool _scopedStrict(ChannelAddress address, MuxConnection connection) =>
      _scoped(address, connection, requireIdentity: true);

  static bool _scopedLenient(
    ChannelAddress address,
    MuxConnection connection,
  ) => _scoped(address, connection, requireIdentity: false);

  static bool _scoped(
    ChannelAddress address,
    MuxConnection connection, {
    required bool requireIdentity,
  }) {
    final identity = connection.peerIdentity;
    if (identity == null) {
      if (requireIdentity) {
        throw _unidentified();
      }
      return true;
    }
    final type = address.type ?? Name.empty;
    return type == Services.naming ||
        type == Services.relay ||
        identity.allows(Right.open, type);
  }

  /// Admits every channel of an identified peer, and refuses a peer that
  /// has not identified (or whose credential expired) with
  /// `UNAUTHENTICATED`, holding its channels until it identifies (see
  /// [ChannelPolicy]). Always returns the same function.
  static ChannelPolicy requireIdentity() => _requireIdentity;

  static bool _requireIdentity(
    ChannelAddress address,
    MuxConnection connection,
  ) {
    if (connection.peerIdentity == null) {
      throw _unidentified();
    }
    return true;
  }

  static SwitchboardException _unidentified() => SwitchboardException.of(
    StatusCode.unauthenticated,
    'the peer has not identified',
  );

  /// Admits a channel only if every policy of [policies] admits it,
  /// evaluated in order; the first refusal (false or a throw) decides. An
  /// empty list admits everything. Returns a new closure on every call (see
  /// [allowTypes] about reusing it).
  static ChannelPolicy all(List<ChannelPolicy> policies) {
    final list = List<ChannelPolicy>.of(policies);
    return (address, connection) {
      for (final policy in list) {
        if (!policy(address, connection)) {
          return false;
        }
      }
      return true;
    };
  }
}
