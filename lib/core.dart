/*
Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Author: Jan Boon <jan.boon@kaetemi.be>
*/

/// Platform independent core of Switchboard: status codes, names, byte
/// codecs, the mux and talk layers, addressing and naming service codecs.
///
/// Nothing in this library imports `dart:io`. Use `package:switchboard/switchboard.dart`
/// for the full library including TCP and WebSocket transports and the
/// [Switchboard] mesh node.
library;

export 'src/bytes.dart' show hexBytes, hexString;
export 'src/name.dart';
export 'src/status.dart';
