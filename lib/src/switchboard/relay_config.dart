/*
Polyverse Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Authors:
  Jan Boon <jan.boon@kaetemi.be>
  Claude Opus 5.5 <noreply@anthropic.com>
*/

import 'dart:convert';

import '../mux/mux_frame.dart';
import '../name.dart';
import '../naming/naming_protocol.dart';

/// How a node that listens nowhere reaches the instances registered
/// without endpoints: through a relay (`RelayService`), the `relay` of a
/// `Switchboard` (wiki page "Polyverse Switchboard Identity and Credentials",
/// section "Relay").
///
/// The relays are the records of [type] in the node's resolver (round
/// robin with failover, like any type; each record's metadata is the
/// relay's identity string, which the node names as the receiver of its
/// `IDENT` there), or the explicit [endpoints] instead, in which case
/// [identity] is what the node names (null: nobody, unless the node's
/// `expectedIdentityFor` names it). The node keeps its connection to a
/// relay pooled like any endpoint connection.
class RelayConfig {
  /// Relays of [type] (default [Services.relay], `_relay`) found through
  /// the resolver, or at [endpoints] (tried in round robin, with failover)
  /// presenting [identity].
  ///
  /// Throws [ArgumentError] for a [type] that is not reserved (its name
  /// does not start with `_`), an empty [endpoints] list, an endpoint
  /// without a scheme, and an [identity] that is empty or longer than an
  /// `IDENT` receiver may be (255 bytes of UTF-8).
  RelayConfig({Name? type, List<Uri>? endpoints, this.identity})
    : type = type ?? Services.relay,
      endpoints = endpoints == null ? null : List.unmodifiable(endpoints) {
    if (!this.type.isReserved) {
      // A relay refuses inner channels of reserved types, which keeps
      // relays from chaining only if the relays run under a reserved type.
      throw ArgumentError.value(
        type,
        'type',
        'must be a reserved name (starting with "_")',
      );
    }
    final list = this.endpoints;
    if (list != null) {
      if (list.isEmpty) {
        throw ArgumentError.value(
          endpoints,
          'endpoints',
          'must not be empty; pass null to resolve the relays',
        );
      }
      for (final endpoint in list) {
        if (!endpoint.hasScheme) {
          throw ArgumentError.value(endpoint, 'endpoints', 'needs a scheme');
        }
      }
    }
    final name = identity;
    if (name != null &&
        (name.isEmpty ||
            utf8.encode(name).length > MuxIdent.maxReceiverLength)) {
      throw ArgumentError.value(
        name,
        'identity',
        'must be 1 to ${MuxIdent.maxReceiverLength} bytes of UTF-8',
      );
    }
  }

  /// The service type of the relays, `_relay` unless the mesh runs its
  /// relays under another type, which must be reserved (start with `_`):
  /// a relay refuses to relay channels of reserved types, which keeps
  /// relays from forming chains.
  final Name type;

  /// Explicit relay endpoints, used instead of resolving [type]; null to
  /// resolve. Unmodifiable.
  final List<Uri>? endpoints;

  /// The identity the relays at [endpoints] present, named as the receiver
  /// of this node's `IDENT` to them; null names nobody (a relay whose host
  /// requires named identification then refuses the node). Ignored when
  /// the relays are resolved: their records carry their identities.
  final String? identity;

  @override
  String toString() =>
      'RelayConfig($type'
      '${endpoints == null ? '' : ' at ${endpoints!.join(', ')}'})';
}
