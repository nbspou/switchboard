/*
Switchboard
Microservice Network Architecture
Copyright (C) 2018  NO-BREAK SPACE OÜ
Author: Jan Boon <kaetemi@no-break.space>
*/

/*
MuxConnection along with the RawChannel class
implement a multiplexing layer on top of a standard WebSocket.

The frame header consists of
- Flags: 1 byte
- Channel Id: 2 or 6 bytes

Using the flags allows the user to set the size format of the channel id.
The flags also allow to tag a message as either DATA, OPEN, or CLOSE.
Channel state is controlled by the open and close commands.
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

import 'package:wstalk/src/raw_channel.dart';
import 'package:wstalk/src/raw_channel_impl.dart';

const int kReserveMuxConnectionHeaderSiwe = 7;

abstract class MuxConnection {
  Connection(
    WebSocket webSocket, {
    Function(RawChannel channel, Uint8List payLoad) onChannel,
    Function() onClose,
    bool client = true,
    // Close the connection after 10 seconds if there are no open channels
    bool autoCloseEmptyConnection = false,
    // Send a keep-alive ping over the connection every 10 seconds, as long as there are open channels
    bool keepActiveAlivePing = true,
  });

  bool get isOpen;
  bool get channelsAvailable;
  RawChannel openChannel(Uint8List payLoad);

  Future<void> close();
}

/* end of file */
