/*
Switchboard
Microservice Network Architecture
Copyright (C) 2018  NO-BREAK SPACE OÜ
Author: Jan Boon <kaetemi@no-break.space>
*/

import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:switchboard/src/mux_connection.dart';
import 'package:switchboard/src/mux_channel.dart';
import 'package:switchboard/src/mux_channel_impl.dart';

class MuxConnectionImpl implements MuxConnection {
  static final Logger _log = new Logger('Switchboard.Mux');
  WebSocket _webSocket;
  Function(MuxChannel channel, Uint8List payLoad) _onChannel;
  Function() _onClose;

  /// Open channels
  final Map<int, MuxChannelImpl> _channels = new Map<int, MuxChannelImpl>();

  /// Channels to which the close command has been sent, which have not yet received close confirmation
  final Map<int, MuxChannelImpl> _closingChannels =
      new Map<int, MuxChannelImpl>();

  int _nextChannelId;

  static const int _closeTimeoutMs = 10000;
  static const int _keepAliveIntervalMs = 10000;

  Timer _closeTimeoutTimer;
  bool _autoCloseEmptyConnection;
  bool _keepActiveAlivePing;

  bool get channelsAvailable {
    return _nextChannelId < 0x1000000000000;
  }

  // Function onChannel fires anytime a channel is added by the remote host. Function onClose fires when the connection closed.
  MuxConnectionImpl(
    WebSocket webSocket, {
    Function(MuxChannel channel, Uint8List payLoad) onChannel,
    Function(MuxConnection connection) onClose,
    bool client = true,
    bool autoCloseEmptyConnection = false,
    bool keepActiveAlivePing = true,
  }) {
    _autoCloseEmptyConnection = autoCloseEmptyConnection;
    _keepActiveAlivePing = keepActiveAlivePing;
    _webSocket = webSocket;
    _nextChannelId = client ? 2 : 3;
    _onChannel = onChannel;
    _onClose = () {
      _onCloseDo(onClose);
    };
    if (keepActiveAlivePing) {
      _webSocket.pingInterval =
          new Duration(milliseconds: _keepAliveIntervalMs);
    }
    if (autoCloseEmptyConnection) {
      _closeTimeoutTimer =
          new Timer(new Duration(milliseconds: _closeTimeoutMs), () {
        // Empty connection timeout
        _closeTimeoutTimer = null;
        close();
      });
    }
    _listen();
  }

  bool isLocalChannel(MuxChannelImpl channel) {
    return (channel.channelId & 1) == (_nextChannelId & 1);
  }

  void _onCloseDo(Function(MuxConnection connection) onClose) {
    _log.finest("Connection closed.");
    if (_closeTimeoutTimer != null) {
      _closeTimeoutTimer.cancel();
      _closeTimeoutTimer = null;
    }
    if (onClose != null) {
      try {
        onClose(this);
      } catch (error, stack) {
        _log.severe("Error in close callback: $error\n$stack");
      }
    }
    List<MuxChannelImpl> channels =
        (_channels.values.toList()..addAll(_closingChannels.values));
    _channels.clear();
    _closingChannels.clear();
    for (MuxChannelImpl channel in channels) {
      try {
        channel.channelRemoteClosed();
      } catch (error, stack) {
        _log.severe("Error in closing channels: $error\n$stack");
      }
    }
  }

  bool get isOpen {
    return _webSocket != null;
  }

  Future<void> closeChannels() async {
    List<MuxChannelImpl> channels = _channels.values.toList();
    List<Future<void>> futures = new List<Future<void>>();
    for (MuxChannelImpl channel in channels) {
      futures.add(channel.close());
    }
    await futures;
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
      } else {
        completer.complete();
      }
    } catch (error, stack) {
      _log.severe(
          "Error closing, severe error, must not occur: $error\n$stack");
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
      _log.severe("Error while trying to listen to WebSocket: $error\n$stack");
      close();
    }
  }

  void _onFrame(dynamic f) {
    try {
      Uint8List frame = f;
      final int offset = frame.offsetInBytes;
      ByteBuffer buffer = frame.buffer;
      int flags = frame[0];
      // 2-byte channel id instead of 6-byte, more useful for client-server
      bool shortChannelId = (flags & 0x02) != 0;
      // failure in case any of these reserved bits are set, useful for forced breaking of compatibility (changing channel Id format)
      bool reservedBreakingFlags = (flags & 0xCD) != 0;
      if (reservedBreakingFlags) {
        _log.severe(
            "Remote is using protocol features which are not supported.");
        close();
        return;
      }
      // these bits are reserved for other protocol behaviour changes, which don't impact compatibility
      bool unknownFlags = (flags & 0x80) != 0;
      if (unknownFlags) {
        _log.warning("Remote is using an unknown protocol extension.");
      }
      int systemCommand = (flags & 0x30) >>
          4; // 0: data, 1: open channel, 2: close channel, 3: reserved.
      int channelId = (frame[1]) | (frame[2] << 8);
      Uint8List subFrame;
      if (shortChannelId) {
        subFrame = buffer.asUint8List(offset + 3, frame.length - 3);
      } else {
        channelId |= (frame[3] << 16) |
            (frame[4] << 24) |
            (frame[5] << 32) |
            (frame[6] << 40);
        subFrame = buffer.asUint8List(offset + 7, frame.length - 3);
      }
      // Can still receive frames when close was sent to the remote
      MuxChannelImpl channel =
          _channels[channelId] ?? _closingChannels[channelId];
      switch (systemCommand) {
        case 0: // data
          if (channel != null) {
            channel.receivedFrame(subFrame);
          } else {
            _log.severe("Remote attempts to communicate on a closed channel.");
            close();
          }
          break;
        case 1: // open channel
          if (channel == null) {
            channel = new MuxChannelImpl(this, channelId);
            _channels[channelId] = channel;
            if (_keepActiveAlivePing) {
              _webSocket.pingInterval =
                  new Duration(milliseconds: _keepAliveIntervalMs);
            }
            if (_closeTimeoutTimer != null) {
              _closeTimeoutTimer.cancel();
              _closeTimeoutTimer = null;
            }
            _log.finer("Remote opened channel.");
            _onChannel(channel, subFrame);
          } else {
            _log.severe(
                "Remote attempts to open a channel which is already open or closing.");
            close();
          }
          break;
        case 2: // close channel
          if (channel != null) {
            // Remote closes the channel
            channel.channelRemoteClosed();
            if (_channels.remove(channelId) == null) {
              // This is the confirmation
              if (_closingChannels.remove(channelId) == null) {
                _log.severe(
                    "Attempt to close channel twice. Protocol violation, close connection.");
                close();
              } else {
                _log.finer("Remote confirmed channel closed.");
              }
            } else {
              // Reply confirmation
              _log.finer("Remote is closing channel, channel closed.");
              _closeChannel(channelId);
            }
            if (_channels.isEmpty && _closingChannels.isEmpty) {
              if (_keepActiveAlivePing) {
                _webSocket.pingInterval = null;
              }
              if (_autoCloseEmptyConnection && _closeTimeoutTimer == null) {
                _closeTimeoutTimer =
                    new Timer(new Duration(milliseconds: _closeTimeoutMs), () {
                  // Empty connection timeout
                  _closeTimeoutTimer = null;
                  close();
                });
              }
            }
          } else {
            if (_onClose != null) {
              _log.severe("Invalid channel specified by remote.");
            }
            close();
          }
          break;
        case 3:
          _log.severe("Invalid system command.");
          close();
          break;
      }
    } catch (error, stack) {
      _log.severe("Error processing frame: $error\n$stack");
      close();
    }
  }

  /// Send a frame from a channel.
  void sendFrame(int channelId, Uint8List frame, {int command = 0}) {
    if (!_channels.containsKey(channelId) && command != 2) {
      _log.severe("Attempt to send frame to closed channel.");
      throw new MuxException("Attempt to send frame to closed channel.");
    }
    int offset = frame.offsetInBytes;
    bool shortChannelId = (channelId < 0x10000);
    int headerSize = shortChannelId ? 3 : 7;
    Uint8List expandedFrame;
    if (offset < headerSize) {
      expandedFrame = new Uint8List.fromList(new Uint8List(headerSize) + frame);
    } else {
      expandedFrame = frame.buffer
          .asUint8List(offset - headerSize, headerSize + frame.lengthInBytes);
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

  // MuxChannel.close();
  void closeChannel(MuxChannelImpl channel) {
    if (_channels.remove(channel.channelId) != null) {
      _log.finer("Closing channel.");
      _closingChannels[channel.channelId] = channel;
      _closeChannel(channel.channelId);
    }
  }

  // MuxChannel.close();
  void _closeChannel(int channelId) {
    Uint8List frame = new Uint8List(kReserveMuxConnectionHeaderSize)
        .buffer
        .asUint8List(kReserveMuxConnectionHeaderSize);
    sendFrame(channelId, frame, command: 2);
  }

  MuxChannel openChannel(Uint8List payLoad) {
    if (!channelsAvailable) {
      _log.severe("No more channels available.");
      return null;
    }
    int channelId = _nextChannelId++;
    MuxChannelImpl channel = new MuxChannelImpl(this, channelId);
    _channels[channelId] = channel;
    Uint8List frame = payLoad ??
        new Uint8List(kReserveMuxConnectionHeaderSize)
            .buffer
            .asUint8List(kReserveMuxConnectionHeaderSize);
    _log.finer("Open channel.");
    sendFrame(channelId, frame, command: 1);
    if (_keepActiveAlivePing) {
      _webSocket.pingInterval =
          new Duration(milliseconds: _keepAliveIntervalMs);
    }
    if (_closeTimeoutTimer != null) {
      _closeTimeoutTimer.cancel();
      _closeTimeoutTimer = null;
    }
    return channel;
  }
}

// TODO: On close channel and 0 active channels remaining, close() after 10 seconds of no activity (cancel timeout on open channel)

/* end of file */
