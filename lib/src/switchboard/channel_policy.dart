/*
Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Author: Jan Boon <jan.boon@kaetemi.be>
*/

import '../address/channel_address.dart';
import '../mux/mux_connection.dart';
import '../name.dart';

/// The listener policy: decides whether a peer that connected to a
/// listener may address [address] at all.
///
/// Evaluated for every channel arriving on a connection accepted by the
/// listener, after the address header is parsed and before any handler is
/// chosen (local services, the default service and the catch-all alike).
/// A channel the policy refuses is closed with `PERMISSION_DENIED` and a
/// generic reason. [connection] is the connection the channel arrived on.
///
/// A policy that throws refuses the channel. See the wiki page
/// "Switchboard Addressing and Dispatch", section "Dispatch of incoming
/// channels".
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

  /// Refuses channels to reserved types (names starting with `_`, such as
  /// the naming service `_ns`); allows everything else, including channels
  /// without a service type.
  static bool denyReserved(ChannelAddress address, MuxConnection connection) =>
      !(address.type?.isReserved ?? false);

  /// Allows only channels to the service types in [types] (any instance).
  /// Channels without a service type (for the default service) are allowed
  /// only with [untyped]. A reserved type is allowed only if it is listed.
  static ChannelPolicy allowTypes(Set<Name> types, {bool untyped = false}) {
    final allowed = Set<Name>.of(types);
    return (address, connection) {
      final type = address.type;
      return type == null ? untyped : allowed.contains(type);
    };
  }
}
