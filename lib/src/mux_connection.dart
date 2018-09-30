/*
WSTalk
Microservice Network Architecture
Copyright (C) 2018  NO-BREAK SPACE OÜ
Author: Jan Boon <kaetemi@no-break.space>
*/

import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'dart:typed_data';

import 'package:wstalk/src/raw_channel.dart';
import 'package:wstalk/src/raw_channel_impl.dart';

const int kMaxConnectionFrameHeaderSize = 7;

abstract class MuxConnection {
  Connection(WebSocket webSocket, {Function(RawChannel channel, Uint8List payLoad) onChannel, Function() onClose, bool client = true});

  bool get isOpen;
  bool get channelsAvailable;
  RawChannel openChannel(Uint8List payLoad);

  Future<void> close();
}

/* end of file */
