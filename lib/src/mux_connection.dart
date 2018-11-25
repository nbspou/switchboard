/*
Switchboard
Microservice Network Architecture
Copyright (C) 2018  NO-BREAK SPACE OÜ
Author: Jan Boon <kaetemi@no-break.space>
*/

// TODO: This should just be a stream of MuxChannels

/*
MuxConnection along with the MuxChannel class
implement a multiplexing layer on top of a standard WebSocket.

The frame header consists of
- Flags: 1 byte
- TalkChannel Id: 2 or 6 bytes

Using the flags allows the user to set the size format of the channel id.
The flags also allow to tag a message as either DATA, OPEN, or CLOSE.
TalkChannel state is controlled by the open and close commands.
Data can be sent to any open channel.

Channels are immediately open upon sending an open command,
cannot be used to send data once the close command has been sent,
and cannot receive data once the close command has been received.

Sending data to a closed channel may cause the whole connection to be closed.
Re-opening previously closed channel ids may cause the whole connection to be closed.
Skipping channel ids may cause them to be invalidated as well.
*/

import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'dart:typed_data';

import 'package:switchboard/src/mux_channel.dart';
import 'package:switchboard/src/mux_channel_impl.dart';

import 'package:switchboard/src/mux_connection_impl.dart';

const int kReserveMuxConnectionHeaderSize = 7;

class MuxException implements Exception {
  final String message;
  const MuxException(this.message);
  String toString() {
    return "MuxException: $message";
  }
}

abstract class MuxConnection {
  factory MuxConnection(
    WebSocket webSocket, {
    Function(MuxChannel channel, Uint8List payLoad) onChannel,
    Function(MuxConnection connection) onClose,
    bool client = true,
    // Close the connection after 10 seconds if there are no open channels
    bool autoCloseEmptyConnection = false,
    // Send a keep-alive ping over the connection every 10 seconds, as long as there are open channels
    bool keepActiveAlivePing = true,
  }) {
    return MuxConnectionImpl(
      webSocket,
      onChannel: onChannel,
      onClose: onClose,
      client: client,
      autoCloseEmptyConnection: autoCloseEmptyConnection,
      keepActiveAlivePing: keepActiveAlivePing,
    );
  }

  bool get isOpen;
  bool get channelsAvailable;
  MuxChannel openChannel(Uint8List payLoad);

  Future<void> closeChannels();
  Future<void> close();
}

/* end of file */
