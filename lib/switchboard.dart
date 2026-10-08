/*
Polyverse Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Authors:
  Jan Boon <jan.boon@kaetemi.be>
  Claude Fable 5.1 <noreply@anthropic.com>
  Claude Opus 5.5 <noreply@anthropic.com>
*/

/// Switchboard: microservice mesh protocol.
///
/// Everything in `package:switchboard/core.dart` plus the `dart:io` parts:
/// the TCP stream transport, the server side WebSocket transports, the
/// `Switchboard` mesh node, `MeshNode` (a node joined to a naming service),
/// `namingClientFor`, `PeerSet` (a connected set of the instances of a
/// type), the `_relay` service (`RelayService`, `RelayConfig`), and the
/// instance side of sharding (`SlotGate`, `SlotLifecycle`, `SlotGates`,
/// `SlotChannel`).
///
/// See the wiki section "Switchboard" for the protocol specification.
library;

export 'core.dart';
export 'src/naming/naming_client_io.dart';
export 'src/switchboard/mesh.dart';
export 'src/switchboard/outgoing_policy.dart';
export 'src/switchboard/peer_set.dart';
export 'src/switchboard/proxy.dart' hide pipeChannelsWithin;
export 'src/switchboard/relay.dart';
export 'src/switchboard/relay_config.dart';
export 'src/switchboard/slot_channel.dart';
export 'src/switchboard/slot_gate.dart';
export 'src/switchboard/switchboard.dart';
export 'src/transport/stream_transport.dart';
export 'src/transport/web_socket_server.dart';
export 'src/transport/web_socket_transport_io.dart';
