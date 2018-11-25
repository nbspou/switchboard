/*
Switchboard
Microservice Network Architecture
Copyright (C) 2018  NO-BREAK SPACE OÜ
Author: Jan Boon <kaetemi@no-break.space>
*/

import 'dart:async';
import 'dart:typed_data';

import 'package:switchboard/src/mux_connection.dart';

abstract class MuxChannel implements Stream<Uint8List>, StreamSink<Uint8List> {
  MuxConnection get connection;
  int get channelId;
  bool get isOpen;
}
