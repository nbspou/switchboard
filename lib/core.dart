/*
Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Author: Jan Boon <jan.boon@kaetemi.be>
*/

/// Platform independent core of Switchboard: status codes, names, byte
/// helpers, the in-memory and WebSocket transports, the mux and talk layers,
/// addressing, the naming service and client, and resolvers.
///
/// Nothing in this library imports `dart:io`. Use
/// `package:switchboard/switchboard.dart` for the full library including the
/// TCP transport and the `Switchboard` mesh node.
library;

export 'src/address/channel_address.dart';
export 'src/address/service_address.dart';
export 'src/bytes.dart' show hexBytes, hexString;
export 'src/mux/mux_channel.dart' show MuxChannel, MuxChannelState;
export 'src/mux/mux_connection.dart';
export 'src/mux/mux_frame.dart'
    show MuxCommand, MuxControlMessage, MuxControlType, MuxFrame, MuxLimits;
export 'src/name.dart';
export 'src/naming/naming_protocol.dart';
export 'src/status.dart';
export 'src/switchboard/incoming_channel.dart';
export 'src/switchboard/resolver.dart';
export 'src/talk/talk_channel.dart';
export 'src/talk/talk_frame.dart';
export 'src/talk/talk_message.dart';
export 'src/talk/talk_stream.dart';
export 'src/transport/memory_transport.dart';
export 'src/transport/web_socket_transport.dart';
