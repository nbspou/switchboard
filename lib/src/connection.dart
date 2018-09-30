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

import 'package:wstalk/src/channel.dart';
import 'package:wstalk/src/raw_channel.dart';
import 'package:wstalk/src/raw_channel_impl.dart';

abstract class Connection {
  bool get channelsAvailable;

  Connection(WebSocket webSocket, Function() onClose, {bool client = true});

  bool get isOpen;

  Future<void> close();

  // channels are immediately valid until closed -----------------------
  RawChannel openChannel();

/*
  Future<Channel> openChannel() {

  }*/

  // & openRawChannel()
  // etc
}

/* end of file */
