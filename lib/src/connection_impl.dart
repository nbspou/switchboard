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
import 'package:wstalk/src/connection.dart';
import 'package:wstalk/src/raw_channel.dart';
import 'package:wstalk/src/raw_channel_impl.dart';

class ConnectionImpl implements Connection {
  WebSocket _webSocket;
  Function() _onClose;

  final Map<int, RawChannelImpl> _channels = new Map<int, RawChannelImpl>();

  int _nextChannelId;

  bool get channelsAvailable {
    return _nextChannelId < 0x1000000000000;
  }

  Connection(WebSocket webSocket, Function() onClose, {bool client = true}) {
    _webSocket = webSocket;
    _nextChannelId = client ? 2 : 3;
    _onClose = () {
      _onCloseDo(onClose);
    };
    _listen();
  }

  void _onCloseDo(Function() onClose) {
    try {
      onClose();
    } catch (error, stack) {
      // TODO: LOG: Error in close callback.
    }
    try {
      // TODO: Close channels.
    } catch (error, stack) {
      // TODO: LOG: Error closing channels.
    }
  }

  bool get isOpen {
    return _webSocket != null;
  }

  Future<void> close() {
    Completer<void> completer = new Completer<void>();
    try {
      if (_webSocket != null) {
        WebSocket webSocket = _webSocket;
        _webSocket = null;
        webSocket.close().catchError((error, stack) {
          // Ignore error, close does not throw.
        }).whenComplete(() {
          if (!completer.isCompleted) {
            completer.complete();
          }
          if (_onClose != null) {
            Function() onClose = _onClose;
            _onClose = null;
            onClose();
          }
        });
      }
    } catch (error, stack) {
      // TODO: LOG: Error. This should not happen.
      if (!completer.isCompleted) {
        completer.completeError(error, stack);
      }
    }
    return completer.future;
  }

  void _onFrame(Uint8List frame) {
    try {
      int offset = frame.offsetInBytes;
      ByteBuffer buffer = frame.buffer;
      int flags = frame[0];
      // 2-byte channel id instead of 6-byte, more useful for client-server
      bool shortChannelId = (flags & 0x02) != 0;
      // failure in case any of these reserved bits are set, useful for forced breaking of compatibility (changing channel Id format)
      bool reservedBreakingFlags = (flags & 0x8D) != 0;
      if (reservedBreakingFlags) {
        // TODO: LOG: Remote is using protocol features which are not supported.
        close();
        return;
      }
      // these bits are reserved for other protocol behaviour changes, which don't impact compatibility
      bool unknownFlags = (flags & 0x70) != 0;
      if (unknownFlags) {
        // TODO: LOG: Warning: Remote is using unknown protocol features.
      }
      int channelId = (frame[1]) | (frame[2] << 8);
      Uint8List subFrame;
      if (shortChannelId) {
        subFrame = buffer.asUint8List(offset + 3);
      } else {
        channelId |= (frame[3] << 16) |
            (frame[4] << 24) |
            (frame[5] << 32) |
            (frame[6] << 40);
        subFrame = buffer.asUint8List(offset + 7);
      }
      RawChannelImpl channel = _channels[channelId];
      if (channel != null) {
        channel.receivedFrame(subFrame);
      } else {
        // TODO: LOG: Error. Invalid channel specified by remote.
      }
    } catch (error, stack) {
      // TODO: LOG: Error processing frame.
      close();
    }
  }

  void _listen() {
    try {
      _webSocket.listen(
        _onFrame,
        onError: (error, stack) {
          // Ignore error
          close();
        },
        onDone: () {
          // Ignore error
          close();
        },
        cancelOnError: true,
      );
    } catch (error, stack) {
      // TODO: LOG: Error while trying to listen to WebSocket.
      close();
    }
  }

  /// Send a frame from a channel.
  void sendFrame(int channelId, Uint8List frame) {}

  Future<void> closeChannel(int channelId) async {
    // TODO
  }

/*
  Future<Channel> openChannel() {

  }*/

  // & openRawChannel()
  // etc
}

/* end of file */
