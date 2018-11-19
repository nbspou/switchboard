import 'dart:async';
import 'dart:typed_data';

import 'package:wstalk/src/mux_connection_impl.dart';
import 'package:wstalk/src/mux_channel.dart';

class MuxChannelImpl extends Stream<Uint8List> implements MuxChannel {
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
    // Channel has been closed
    try {
      if (!_streamController.isClosed) {
        _streamController.close();
      }
    } catch (error, stack) {
      // LOG: Ignore error
    }
  }

  @override
  void add(Uint8List event) {
    // Local to remote
    connection.sendFrame(channelId, event);
  }

  @override
  void addError(Object error, [StackTrace stackTrace]) {
    // TODO: LOG
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
      } catch (error, stack) {
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
