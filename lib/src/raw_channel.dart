import 'dart:async';
import 'dart:typed_data';

import 'package:wstalk/src/mux_connection.dart';

abstract class RawChannel implements Stream<Uint8List>, StreamSink<Uint8List> {
  MuxConnection get connection;
  int get channelId;

}
