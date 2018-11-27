/*
Switchboard
Microservice Network Architecture
Copyright (C) 2018  NO-BREAK SPACE OÜ
Author: Jan Boon <kaetemi@no-break.space>
*/

import 'dart:async';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:switchboard/src/mux_connection_impl.dart';
import 'package:switchboard/src/mux_channel.dart';

class MuxChannelImpl extends Stream<Uint8List> implements MuxChannel {
  static final Logger _log = new Logger('Switchboard.Mux');
  final MuxConnectionImpl connection;
  final int channelId;
  MuxChannelImpl(this.connection, this.channelId);

  StreamController<Uint8List> _streamController =
      new StreamController<Uint8List>();

  bool _closing = false;

  void receivedFrame(Uint8List frame) {
    // Remote to local
    _streamController.add(frame);
  }

  void channelRemoteClosed() {
    // TalkChannel has been closed
    try {
      if (!_streamController.isClosed) {
        _streamController.close();
      }
    } catch (error, stackTrace) {
      _log.fine("Error closing channel: $error\n$stackTrace");
    }
  }

  @override
  bool get isOpen {
    return !_streamController.isClosed;
  }

  @override
  void add(Uint8List event) {
    // Local to remote
    connection.sendFrame(channelId, event);
  }

  @override
  void addError(Object error, [StackTrace stackTrace]) {
    _log.severe("Error in channel stream: $error\n$stackTrace");
  }

  @override
  Future<void> addStream(Stream<Uint8List> stream) async {
    await for (Uint8List event in stream) {
      add(event);
    }
  }

  @override
  Future<void> close() async {
    if (!_streamController.isClosed && !_closing) {
      _closing = true;
      try {
        connection.closeChannel(this);
      } catch (error) {
        _closing = false;
        rethrow;
      }
    }
    await _streamController.done;
    _closing = false;
  }

  @override
  Future<void> get done => _streamController.done;

  @override
  StreamSubscription<Uint8List> listen(void Function(Uint8List event) onData,
      {Function onError, void Function() onDone, bool cancelOnError}) {
    return _streamController.stream.listen(onData,
        onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  }
}
