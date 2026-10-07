/*
Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Author: Jan Boon <jan.boon@kaetemi.be>
*/

import 'dart:async';
import 'dart:typed_data';

import '../naming/naming_protocol.dart';
import 'channel_policy.dart';

/// Chooses the policy of a connection a node initiates to [endpoint]: the
/// `endpointPolicy` hook of `Switchboard`, consulted once per connection,
/// when it is established.
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
/// Null sends an empty application payload: once this hook is set, the
/// node's `defaultPayload` is never attached implicitly, so a credential
/// meant for the mesh does not reach a destination the hook does not
/// recognise. Return the node's `defaultPayload` for the destinations
/// that should see it.
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
