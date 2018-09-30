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

import 'package:wstalk/src/mux_connection.dart';
import 'package:wstalk/src/raw_channel.dart';
import 'package:wstalk/src/raw_channel_impl.dart';

class MuxConnectionImpl implements MuxConnection {
  WebSocket _webSocket;
  Function(RawChannel channel, Uint8List payLoad) _onChannel;
  Function() _onClose;

  final Map<int, RawChannelImpl> _channels = new Map<int, RawChannelImpl>();
  final Map<int, RawChannelImpl> _closingChannels = new Map<int, RawChannelImpl>();

  int _nextChannelId;

  bool get channelsAvailable {
    return _nextChannelId < 0x1000000000000;
  }

  // Function onChannel fires anytime a channel is added by the remote host. Function onClose fires when the connection closed.
  Connection(WebSocket webSocket, {Function(RawChannel channel, Uint8List payLoad) onChannel, Function() onClose, bool client = true}) {
    _webSocket = webSocket;
    _nextChannelId = client ? 2 : 3;
    _onChannel = onChannel;
    _onClose = () {
      _onCloseDo(onClose);
    };
    _listen();
  }

  bool isLocalChannel(RawChannelImpl channel) {
    return (channel.channelId & 1) == (_nextChannelId & 1);
  }

  void _onCloseDo(Function() onClose) {
    if (onClose != null) { 
      try {
        onClose();
      } catch (error, stack) {
        // TODO: LOG: Error in close callback.
      }
    }
    List<RawChannelImpl> channels = (_channels.values.toList()..addAll(_closingChannels.values));
    _channels.clear();
    _closingChannels.clear();
    for (RawChannelImpl channel in channels) {
      try {
        channel.channelClosed();
      } catch (error, stack) {
        // TODO: LOG: Error closing channels.
      }
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

  void _onFrame(Uint8List frame) {
    try {
      int offset = frame.offsetInBytes;
      ByteBuffer buffer = frame.buffer;
      int flags = frame[0];
      // 2-byte channel id instead of 6-byte, more useful for client-server
      bool shortChannelId = (flags & 0x02) != 0;
      // failure in case any of these reserved bits are set, useful for forced breaking of compatibility (changing channel Id format)
      bool reservedBreakingFlags = (flags & 0xCD) != 0;
      if (reservedBreakingFlags) {
        // TODO: LOG: Remote is using protocol features which are not supported.
        close();
        return;
      }
      // these bits are reserved for other protocol behaviour changes, which don't impact compatibility
      bool unknownFlags = (flags & 0x80) != 0;
      if (unknownFlags) {
        // TODO: LOG: Warning: Remote is using an unknown extension.
      }
      int systemCommand = (flags & 0x30) >> 4; // 0: data, 1: open channel, 2: close channel, 3: reserved.
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
      RawChannelImpl channel = _channels[channelId] ?? _closingChannels[channelId];
      switch (systemCommand) {
        case 0: // data
          if (channel != null) {
            channel.receivedFrame(subFrame);
          } else {
            // TODO: LOG: Error. Invalid channel specified by remote.
          }
          break;
        case 1: // open channel
          if (channel == null) {
            channel = new RawChannelImpl(this, channelId);
            _channels[channelId] = channel;
            _onChannel(channel, subFrame);
          } else {
            // TODO: LOG: Error. Invalid channel specified by remote. Already in use.
          }
          break;
        case 2: // close channel
          if (channel != null) {
            channel.channelClosed();
            if (_channels.remove(channelId) == null) {
              // This is the confirmation
              _closingChannels.remove(channelId);
            } else {
              // Reply confirmation
              closeChannel(channelId);
            }
          } else {
            // TODO: LOG: Error. Invalid channel specified by remote.
          }
          break;
        case 3:
          // TODO: LOG: Error. Invalid system command.
          break;
      }
    } catch (error, stack) {
      // TODO: LOG: Error processing frame.
      close();
    }
  }

  /// Send a frame from a channel.
  void sendFrame(int channelId, Uint8List frame, { int command }) {
    int offset = frame.offsetInBytes;
    bool shortChannelId = (channelId < 0x10000);
    int headerSize = shortChannelId ? 3 : 7;
    Uint8List expandedFrame;
    if (offset < headerSize) {
      expandedFrame = new Uint8List(headerSize) + frame;
    } else {
      expandedFrame = frame.buffer.asUint8List(offset - headerSize, headerSize + frame.lengthInBytes);
    }
    int flags = 0;
    if (shortChannelId) flags |= 0x02;
    flags |= (command << 4);
    expandedFrame[0] = flags;
    expandedFrame[1] = channelId & 0xFF;
    expandedFrame[2] = (channelId >> 8) & 0xFF;
    if (!shortChannelId) {
      expandedFrame[3] = (channelId >> 16) & 0xFF;
      expandedFrame[4] = (channelId >> 24) & 0xFF;
      expandedFrame[5] = (channelId >> 32) & 0xFF;
      expandedFrame[6] = (channelId >> 40) & 0xFF;
    }
    _webSocket.add(expandedFrame);
  }

  // RawChannel.close();
  void closeChannel(int channelId) {
    Uint8List frame = new Uint8List(kMaxConnectionFrameHeaderSize).buffer.asUint8List(kMaxConnectionFrameHeaderSize);
    sendFrame(channelId, frame, command: 2);
  }

  RawChannel openChannel(Uint8List payLoad) {
    if (!channelsAvailable) {
      return null;
    }
    int channelId = _nextChannelId++;
    RawChannelImpl channel = new RawChannelImpl(this, channelId);
    _channels[channelId] = channel;
    Uint8List frame = payLoad ?? new Uint8List(kMaxConnectionFrameHeaderSize).buffer.asUint8List(kMaxConnectionFrameHeaderSize);
    sendFrame(channelId, frame, command: 1);
    return channel;
  }
}

// TODO: On close channel and 0 active channels remaining, close() after 10 seconds of no activity (cancel timeout on open channel)

/* end of file */
