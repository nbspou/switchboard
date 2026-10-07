/*
Polyverse Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Authors:
  Jan Boon <jan.boon@kaetemi.be>
  Claude Opus 5.5 <noreply@anthropic.com>
*/

import 'dart:async';
import 'dart:typed_data';

import '../naming/naming_protocol.dart';
import 'channel_policy.dart';

/// Chooses the policy of a connection a node initiates to [endpoint]: the
/// `endpointPolicy` hook of `Switchboard`, consulted once per connection,
/// when it is established.
///
/// [endpoint] is normalised as the connection pool keys it (scheme and host
/// lower-cased, the default port filled in, the path and query kept for
/// WebSocket URIs only, no fragment, a `mem` URI by its id alone), so the
/// spellings of one endpoint get the same answer.
///
/// Returns the [ChannelPolicy] for channels the peer at [endpoint] opens
/// on that connection, or null to leave the choice to
/// `Switchboard.outgoingPolicy`. To mark an endpoint as trusted while the
/// node's outgoing policy is strict, return [ChannelPolicies.allowAll].
///
/// ```dart
/// final node = Switchboard(
///   // mem:// and the private network are the mesh; anything else is a
///   // worker that may not push channels into this node.
///   endpointPolicy: (endpoint) =>
///       endpoint.scheme == 'mem' || isPrivateNetwork(endpoint.host)
///       ? ChannelPolicies.allowAll
///       : null,
///   outgoingPolicy: ChannelPolicies.denyAll,
/// );
/// ```
///
/// A hook that throws gives the connection [ChannelPolicies.denyAll] (the
/// error is logged).
typedef EndpointPolicy = ChannelPolicy? Function(Uri endpoint);

/// Chooses the application payload (the credential) of a channel a node
/// opens to [endpoint] when the caller supplies none: the `credentialFor`
/// hook of `Switchboard`, consulted for every such channel.
///
/// [record] is the resolver's record of the destination when the channel
/// was opened through resolution (`Switchboard.openChannel` and the other
/// resolving opens, and `PeerSet`), or null for an explicit endpoint
/// (`Switchboard.openChannelAt`, `Switchboard.openChannelOn`). A key per
/// instance, kept by the application or carried in the
/// [ServiceRecord.metadata] a trusted registrar publishes, is looked up
/// here.
///
/// For a channel through a relay (`Switchboard.relay`), [endpoint] is the
/// relay's, which sees the payload as it forwards it, and [record] is the
/// destination's (a record without endpoints), whose instance receives
/// the payload unchanged: the hook decides for both.
///
/// Null sends an empty application payload: once this hook is set, the
/// node's `defaultPayload` is never attached implicitly, so a credential
/// meant for the mesh does not reach a destination the hook does not
/// recognise. Return the node's `defaultPayload` for the destinations
/// that should see it.
///
/// Record metadata is visible to every watcher of the naming table, so a
/// key placed there authenticates the mesh to the instance, not the
/// instance to the mesh.
///
/// ```dart
/// final node = Switchboard(
///   defaultPayload: meshCredential,
///   credentialFor: (endpoint, record) {
///     if (record != null && record.address.type == gpu) {
///       // The scaler registered each worker with its key as metadata.
///       return record.metadata;
///     }
///     return isMesh(endpoint) ? meshCredential : null;
///   },
/// );
/// ```
typedef EndpointCredential = FutureOr<Uint8List?> Function(
  Uri endpoint,
  ServiceRecord? record,
);

/// Names the identity a node expects the peer at [endpoint] to have, for
/// the receiver field of the `IDENT` it sends there: the
/// `expectedIdentityFor` hook of `Switchboard`, consulted every time the
/// node identifies on a connection it initiates (wiki page "Switchboard
/// Identity and Credentials", section "Connection identity").
///
/// [endpoint] is normalised as for [EndpointPolicy]. [record] is the
/// resolver's record the connection is established for: the record whose
/// endpoint an open method dials (the pooled connection then serves every
/// record at that endpoint, which is one node, so naming it from the first
/// record is sound), the record `PeerSet` or `Switchboard.dial` was given,
/// or the relay's record for a connection to a relay; null for
/// `Switchboard.connect` and `openChannelAt`, which dial an endpoint with
/// no record.
///
/// For a relay's record (`_relay`, or the type of `Switchboard.relay`), a
/// null answer names the identity the record's metadata carries.
///
/// Null (or empty) names nobody: any peer that verifies the credential
/// accepts the `IDENT`, so a peer that relays the handshake can pass as
/// this node to a third node that accepts an unnamed `IDENT`. A peer whose
/// identity is not the one named refuses the `IDENT`, which fails the
/// connection with `UNAUTHENTICATED`. A naming service whose host requires
/// named identification (`MuxOptions.requireNamedIdent`) refuses an
/// `IDENT` that names nobody.
///
/// ```dart
/// final node = Switchboard(
///   credential: credential,
///   holderKey: holderKey,
///   expectedIdentityFor: (endpoint, record) =>
///       endpoint == namingEndpoint ? 'ns' : identityOf(record),
/// );
/// ```
///
/// A hook that throws names nobody (the error is logged).
typedef ExpectedIdentity = String? Function(
  Uri endpoint,
  ServiceRecord? record,
);
