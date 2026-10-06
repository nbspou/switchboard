/*
Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Author: Jan Boon <jan.boon@kaetemi.be>
*/

/// Platform independent core of Switchboard: status codes, names, byte
/// helpers, the in-memory and WebSocket transports, the stream binding's
/// wire format, the mux and talk layers, addressing, the naming service and
/// client, resolvers, and the reference key-to-slot function.
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
export 'src/naming/naming_client.dart';
export 'src/naming/naming_protocol.dart';
export 'src/naming/naming_resolver.dart';
export 'src/naming/naming_service.dart';
export 'src/naming/slot_table.dart';
export 'src/status.dart';
export 'src/status_closable.dart';
export 'src/switchboard/channel_policy.dart';
export 'src/switchboard/incoming_channel.dart';
export 'src/switchboard/resolver.dart';
export 'src/switchboard/slot_key.dart';
export 'src/talk/talk_channel.dart';
export 'src/talk/talk_frame.dart';
export 'src/talk/talk_message.dart';
export 'src/talk/talk_request.dart';
export 'src/talk/talk_stream.dart';
export 'src/transport/memory_transport.dart';
export 'src/transport/stream_framing.dart';
export 'src/transport/transport_capabilities.dart';
export 'src/transport/web_socket_transport.dart';
