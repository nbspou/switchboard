/*
Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Author: Jan Boon <jan.boon@kaetemi.be>
*/

/// Switchboard: microservice mesh protocol.
///
/// Everything in `package:switchboard/core.dart` plus the `dart:io` parts:
/// the TCP stream transport and the `Switchboard` mesh node.
///
/// See the wiki section "Switchboard" for the protocol specification.
library;

export 'core.dart';
export 'src/transport/stream_transport.dart';
