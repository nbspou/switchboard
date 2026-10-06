/*
Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Author: Jan Boon <jan.boon@kaetemi.be>
*/

/// Switchboard: microservice mesh protocol.
///
/// Everything in `package:switchboard/core.dart` plus the `dart:io` parts:
/// the TCP stream transport, the server side WebSocket transports, the
/// `Switchboard` mesh node, `MeshNode` (a node joined to a naming service)
/// and `namingClientFor`.
///
/// See the wiki section "Switchboard" for the protocol specification.
library;

export 'core.dart';
export 'src/naming/naming_client_io.dart';
export 'src/switchboard/mesh.dart';
export 'src/switchboard/proxy.dart';
export 'src/switchboard/switchboard.dart';
export 'src/transport/stream_transport.dart';
export 'src/transport/web_socket_server.dart';
export 'src/transport/web_socket_transport_io.dart';
