/*
Switchboard
Microservice Network Architecture
Copyright (C) 2018  NO-BREAK SPACE OÜ
Author: Jan Boon <kaetemi@no-break.space>
*/

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:switchboard/src/talk_message.dart';
import 'package:switchboard/src/mux_connection.dart';
import 'package:switchboard/src/mux_channel.dart';
import 'package:switchboard/src/rewindable_timer.dart';

/*
Message, no request id, no response id
Simply sent, no requirements
*/

class _LocalAnyResponseState {
  final RewindableTimer timer;
  const _LocalAnyResponseState(this.timer);
}

class _RemoteResponseState {
  // final int id;
  final RewindableTimer timer;
  final Completer<TalkMessage> completer;
  const _RemoteResponseState(/*this.id, */ this.completer, this.timer);
}

class _RemoteStreamResponseState {
  // final int id;
  final RewindableTimer timer;
  final StreamController<TalkMessage> controller;
  const _RemoteStreamResponseState(/*this.id, */ this.controller, this.timer);
}

class TalkAbort implements Exception {
  final String message;
  const TalkAbort(this.message);
  String toString() {
    return "TalkAbort: $message";
  }
}

/// Payload on end of stream.
/// Not supported by Dart.
class TalkEndOfStream implements Exception {
  final TalkMessage message;
  const TalkEndOfStream(this.message);
  String toString() {
    return "TalkEndOfStream has message payload";
  }
}

class TalkException implements Exception {
  final String message;
  const TalkException(this.message);
  String toString() {
    return "TalkException: $message";
  }
}

class TalkChannel extends Stream<TalkMessage> {
  static final Logger _log = new Logger('Switchboard.Talk');

  /// We give the remote host 15 seconds to reply to a message
  static const int _receiveTimeOutMs = 15000;

  /// We give ourselves 10 seconds to reply to a message
  static const int _sendTimeOutMs = 10000;

  /// Maximum number concurrent requests
  static const int _maxConcurrentRequests = 0x7FFFFF;

  StreamController<TalkMessage> _listenController =
      new StreamController<TalkMessage>();

  /// Waiting for the local application to send a reply
  Map<int, _LocalAnyResponseState> _localAnyResponseStates =
      new Map<int, _LocalAnyResponseState>();

  /// Waiting for a reply from the remote host
  Map<int, _RemoteResponseState> _remoteResponseStates =
      new Map<int, _RemoteResponseState>();

  /// Waiting for a reply from the remote host
  Map<int, _RemoteStreamResponseState> _remoteStreamResponseStates =
      new Map<int, _RemoteStreamResponseState>();

  MuxChannel get channel {
    return _channel;
  }

  MuxChannel _channel;
  TalkChannel(MuxChannel raw) {
    _channel = raw;
    _listen();
  }

  int _lastRequestId = 0;

  Future<void> get done => _channel.done;
  Future<void> close() async {
    try {
      await _channel.close();
    } catch (error) {}
    /*
    for (StreamController<TalkMessage> streamController in _streams.values) {
      streamController.close();
    }
    _streams.clear();
    */
    for (_LocalAnyResponseState state in _localAnyResponseStates.values) {
      state.timer.cancel();
    }
    _localAnyResponseStates.clear();
    for (_RemoteResponseState state in _remoteResponseStates.values) {
      state.timer.cancel();
      state.completer.completeError(
          new TalkException("Talk channel closing, reply cannot be received"));
    }
    _remoteResponseStates.clear();
    for (_RemoteStreamResponseState state
        in _remoteStreamResponseStates.values) {
      state.timer.cancel();
      state.controller.addError(new TalkException(
          "Talk channel closing, replies cannot be received"));
      state.controller.close();
    }
    _remoteStreamResponseStates.clear();
  }

  /// A message was received from the remote host.
  void _onMessage(TalkMessage message) {
    _listenController.add(message);
  }

  /// An abort message was received from the remote host.
  void _onAbort(String reason) {
    _log.severe("Abort received from remote: $reason");
    _listenController.addError(new TalkAbort(reason));
  }

  static Uint8List _emptyProcedureId = new Uint8List(8);

  void _onFrame(Uint8List frame) {
    _log.finest("Received frame.");
    try {
      // Parse general header of the message
      final int offset = frame.offsetInBytes;
      ByteBuffer buffer = frame.buffer;
      int flags = frame[0];
      bool hasProcedureId = (flags & 0x01) != 0;
      bool hasRequestId = (flags & 0x02) != 0;
      bool hasResponseId = (flags & 0x04) != 0;
      int o = 1;
      Uint8List procedureIdRaw = _emptyProcedureId;
      int requestId = 0;
      int responseId = 0;
      if (hasProcedureId) {
        procedureIdRaw = buffer.asUint8List(offset + o, 8);
        o += 8;
      }
      if (hasRequestId) {
        requestId = (frame[o++]) | (frame[o++] << 8) | (frame[o++] << 16);
      }
      if (hasResponseId) {
        responseId = (frame[o++]) | (frame[o++] << 8) | (frame[o++] << 16);
      }
      Uint8List subFrame = buffer.asUint8List(offset + o, frame.length - o);
      String procedureId =
          utf8.decode(procedureIdRaw.takeWhile((c) => c != 0).toList());
      // This message expects a stream response (if not set, can only send timeout extend stream response)
      bool expectStreamResponse = (flags & 0x08) != 0; // not necessary?
      // This message is a stream response (a non-stream-response signals end-of-stream)
      bool isStreamResponse = (flags & 0x30) == 0x10;
      // Timeout extend message (must be a stream response) (an extend message with a request id extends the timeout)
      bool isTimeoutExtend = (flags & 0x30) == 0x30;
      // Abort message (must be non-stream response) (an abort message with a request id is a request cancellation)
      bool isAbort = (flags & 0x30) == 0x20;
      TalkMessage message = new TalkMessage(this, procedureId, requestId,
          responseId, expectStreamResponse, subFrame);
      _log.finer("Received message '${procedureId}' (${requestId}, ${responseId}).");

      // Process message
      if (requestId != 0) {
        // This is a remote request that needs to be responded to in time
        // Ensure we're not past the concurrency limit
        int concurrentRequests = _localAnyResponseStates.length;
        if (concurrentRequests >= _maxConcurrentRequests) {
          if (outgoingSafety) {
            _replyAbort(requestId, "Too many incoming concurrent requests.");
          }
          return;
        }
        // Set the timer
        RewindableTimer timer =
            new RewindableTimer(new Duration(milliseconds: _sendTimeOutMs), () {
          _LocalAnyResponseState state =
              _localAnyResponseStates.remove(requestId);
          if (state != null) {
            _log.severe(
                "TalkMessage '$procedureId' was not replied to by the local program in time, sending abort.");
            if (outgoingSafety) {
              _replyAbort(requestId, "Reply not sent in time.");
            }
          }
        });
        _localAnyResponseStates[requestId] = new _LocalAnyResponseState(timer);
      }
      if (responseId != 0) {
        // This message is a response to a request we've sent
        _RemoteResponseState state = _remoteResponseStates[responseId];
        if (state != null) {
          // Received a message in response to a request
          if (isTimeoutExtend) {
            state.timer.rewind();
          } else if (isAbort) {
            state.timer.cancel();
            String reason = utf8.decode(subFrame);
            _log.severe("Abort received from remote in reply to request: $reason");
            state.completer.completeError(new TalkAbort(reason));
            _abortRequiresReply(message);
            _remoteResponseStates.remove(responseId);
          } else if (isStreamResponse) {
            _log.severe(
                "Received stream response [$message] to message request.");
            state.timer.cancel();
            state.completer
                .completeError(new TalkAbort("Received stream response."));
            _invalidResponseType(message);
            _remoteResponseStates.remove(responseId);
          } else {
            state.timer.cancel();
            state.completer.complete(message);
            _remoteResponseStates.remove(responseId);
          }
        } else {
          _RemoteStreamResponseState state =
              _remoteStreamResponseStates[responseId];
          if (state != null) {
            // Received a message in response to a stream request
            if (isTimeoutExtend) {
              state.timer.rewind();
            } else if (isAbort) {
              state.timer.cancel();
              String reason = utf8.decode(subFrame);
              _log.severe(
                  "Abort received from remote in reply to stream request: $reason");
              state.controller.addError(new TalkAbort(reason));
              state.controller.close();
              _abortRequiresReply(message);
              _remoteStreamResponseStates.remove(responseId);
            } else if (isStreamResponse) {
              state.timer.rewind();
              state.controller.add(message);
            } else {
              state.timer.cancel();
              if (message.data.length > 0 || message.requestId != 0) {
                state.controller.addError(new TalkEndOfStream(message));
              }
              state.controller.close();
              _remoteStreamResponseStates.remove(responseId);
            }
          } else {
            _unknownResponseIdentifier(message);
          }
        }
      } else if (isAbort) {
        // New abort, unusual, but okay
        _onAbort(utf8.decode(subFrame));
      } else if (isStreamResponse || isTimeoutExtend) {
        // Invalid message state
        _log.severe(
            "Received invalid talk message flags: $flags (${isStreamResponse ? 'isStreamResponse' : 'isTimeoutExtend'})");
        throw new TalkException(
            "Received invalid talk message flags: $flags (${isStreamResponse ? 'isStreamResponse' : 'isTimeoutExtend'})");
      } else {
        // New message, or new request chain
        _onMessage(message);
      }
    } catch (error, stack) {
      _log.severe(
          "Error while handling channel frame, channel closed: $error\n$stack");
      close();
    }
  }

  void _listen() {
    _channel.listen(
      _onFrame,
      onError: (error, stack) {
        _log.severe("Error from channel: $error\n$stack");
        _listenController.addError(error, stack);
      },
      onDone: () {
        _listenController.close();
      },
      cancelOnError: true,
    );
  }

  @override
  StreamSubscription<TalkMessage> listen(
      void Function(TalkMessage event) onData,
      {Function onError,
      void Function() onDone,
      bool cancelOnError}) {
    return _listenController.stream.listen(onData,
        onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  }

  int _makeRequestId() {
    ++_lastRequestId;
    _lastRequestId &= 0xFFFFFF;
    if (_lastRequestId == 0) ++_lastRequestId;
    while ((_remoteResponseStates[_lastRequestId] ??
            _remoteStreamResponseStates[_lastRequestId]) !=
        null) {
      ++_lastRequestId;
      _lastRequestId &= 0xFFFFFF;
      if (_lastRequestId == 0) ++_lastRequestId;
    }
    return _lastRequestId;
  }

  void _sendMessage(
      String procedureId, Uint8List data, int responseId, bool isStreamResponse,
      [int requestId = 0,
      bool expectStreamResponse = false,
      bool isAbortOrExtend = false]) {
    // Check options
    bool hasProcedureId = procedureId?.isNotEmpty ?? false;
    bool hasRequestId = requestId != 0 && requestId != null;
    bool hasResponseId = responseId != 0 && responseId != null;
    int headerSize = 1;
    if (hasProcedureId) headerSize += 8;
    if (hasRequestId) headerSize += 3;
    if (hasResponseId) headerSize += 3;

    // Expand data frame with channel header plus mux header capacity
    int fullHeaderSize = headerSize + kReserveMuxConnectionHeaderSize;
    Uint8List fullFrame =
        new Uint8List.fromList(Uint8List(fullHeaderSize) + data);
    Uint8List frame =
        fullFrame.buffer.asUint8List(kReserveMuxConnectionHeaderSize);
    int flags = 0;
    if (hasProcedureId) flags |= 0x01;
    if (hasRequestId) flags |= 0x02;
    if (hasResponseId) flags |= 0x04;
    if (expectStreamResponse) flags |= 0x08; // not necessary?
    if (isStreamResponse) flags |= 0x10;
    if (isAbortOrExtend) flags |= 0x20;
    // print("$procedureId, isStreamResponse: $isStreamResponse, isAbortOrExtend: $isAbortOrExtend, expectStreamResponse: $expectStreamResponse");

    // Set header data
    frame[0] = flags;
    int o = 1;
    if (hasProcedureId) {
      List<int> procedureIdRaw = utf8.encode(procedureId).take(8).toList();
      for (int i = 0; i < procedureIdRaw.length; ++i) {
        frame[o + i] = procedureIdRaw[i];
      }
      o += 8;
    }
    if (hasRequestId) {
      frame[o++] = requestId & 0xFF;
      frame[o++] = (requestId >> 8) & 0xFF;
      frame[o++] = (requestId >> 16) & 0xFF;
    }
    if (hasResponseId) {
      frame[o++] = responseId & 0xFF;
      frame[o++] = (responseId >> 8) & 0xFF;
      frame[o++] = (responseId >> 16) & 0xFF;
    }

    // Send frame
    _log.finest("Send frame.");
    _channel.add(frame);
  }

  void _replyAbort(int responseId, String reason) {
    _sendMessage("", utf8.encode(reason), responseId, false, 0, false, true);
  }

  void _sendingResponse(int responseId, bool isStreamResponse) {
    _LocalAnyResponseState state = _localAnyResponseStates[responseId];
    if (state != null) {
      if (isStreamResponse) {
        state.timer.rewind();
      } else {
        state.timer.cancel();
        _localAnyResponseStates.remove(responseId);
      }
    } else {
      if (outgoingSafety) {
        _log.severe("Already sent final response (or timeout).");
        throw new TalkException("Already sent final response (or timeout).");
      }
    }
  }

  Future<TalkMessage> _sendingRequest(String procedureId, int requestId) {
    // Create a completer
    Completer<TalkMessage> completer = new Completer<TalkMessage>();
    // Set a timer for the remote host to respond to this
    RewindableTimer timer =
        new RewindableTimer(new Duration(milliseconds: _receiveTimeOutMs), () {
      _RemoteResponseState state = _remoteResponseStates.remove(requestId);
      if (state != null) {
        assert(state.completer == completer);
        assert(!state.completer.isCompleted);
        _log.severe(
            "TalkMessage '$procedureId' was not replied to by the remote program in time, "
            "and did not receive remote timeout, abort locally.");
        state.completer
            .completeError(new TalkAbort("Reply not received in time."));
      }
    });
    _RemoteResponseState state = new _RemoteResponseState(completer, timer);
    _remoteResponseStates[requestId] = state;
    return completer.future;
  }

  Stream<TalkMessage> _sendingStreamRequest(String procedureId, int requestId) {
    // Create a completer
    StreamController<TalkMessage> controller =
        new StreamController<TalkMessage>();
    // Set a timer for the remote host to respond to this
    RewindableTimer timer =
        new RewindableTimer(new Duration(milliseconds: _receiveTimeOutMs), () {
      _RemoteStreamResponseState state =
          _remoteStreamResponseStates.remove(requestId);
      if (state != null) {
        assert(state.controller == controller);
        assert(!state.controller.isClosed);
        _log.severe(
            "TalkMessage '$procedureId' was not replied to by the remote program in time, "
            "and did not receive remote timeout, abort locally.");
        state.controller.addError(new TalkAbort("Reply not received in time."));
        state.controller.close();
      }
    });
    _RemoteStreamResponseState state =
        new _RemoteStreamResponseState(controller, timer);
    _remoteStreamResponseStates[requestId] = state;
    return controller.stream;
  }

  void sendMessage(String procedureId, Uint8List data,
      {int responseId = 0, bool isStreamResponse = false}) {
    _sendMessage(procedureId, data, responseId, isStreamResponse);
  }

  Future<TalkMessage> sendRequest(String procedureId, Uint8List data,
      {int responseId = 0, bool isStreamResponse = false}) {
    int requestId = _makeRequestId();
    _sendMessage(procedureId, data, responseId, isStreamResponse, requestId);
    return _sendingRequest(procedureId, requestId);
  }

  Stream<TalkMessage> sendStreamRequest(String procedureId, Uint8List data,
      {int responseId = 0, bool isStreamResponse = false}) {
    int requestId = _makeRequestId();
    _sendMessage(
        procedureId, data, responseId, isStreamResponse, requestId, true);
    return _sendingStreamRequest(procedureId, requestId);
  }

  void sendAbort(String reason) {
    _replyAbort(0, reason);
  }

  void replyMessage(TalkMessage replying, String procedureId, Uint8List data) {
    _sendingResponse(replying.requestId, replying.expectStreamResponse);
    sendMessage(procedureId, data,
        responseId: replying.requestId,
        isStreamResponse: replying.expectStreamResponse);
  }

  Future<TalkMessage> replyRequest(
      TalkMessage replying, String procedureId, Uint8List data) {
    _sendingResponse(replying.requestId, replying.expectStreamResponse);
    return sendRequest(procedureId, data,
        responseId: replying.requestId,
        isStreamResponse: replying.expectStreamResponse);
  }

  Stream<TalkMessage> replyStreamRequest(
      TalkMessage replying, String procedureId, Uint8List data) {
    _sendingResponse(replying.requestId, replying.expectStreamResponse);
    return sendStreamRequest(procedureId, data,
        responseId: replying.requestId,
        isStreamResponse: replying.expectStreamResponse);
  }

  void replyEndOfStream(TalkMessage replying,
      [String procedureId, Uint8List data]) {
    // Data is not part of the stream, but post-stream.
    // In the Dart implementation, this is thrown as a TalkEndOfStream error to the message stream.
    _sendingResponse(replying.requestId, false);
    sendMessage(procedureId ?? "", data ?? new Uint8List(0),
        responseId: replying.requestId);
  }

  void replyAbort(TalkMessage replying, String reason) {
    _sendingResponse(replying.requestId, false);
    _replyAbort(replying.requestId, reason);
  }

  void replyExtend(TalkMessage replying) {
    _sendingResponse(replying.requestId, true);
    _sendMessage(
        "", new Uint8List(0), replying.requestId, true, 0, false, true);
  }

  void unknownProcedure(TalkMessage replying) {
    _log.severe("Unknown procedure '${replying.procedureId}' sent by remote.");
    if (replying.requestId != 0) {
      _sendingResponse(replying.requestId, false);
    }
    if (outgoingSafety) {
      _replyAbort(
          replying.requestId, "Unknown procedure '${replying.procedureId}'.");
    }
  }

  void _unknownResponseIdentifier(TalkMessage replying) {
    _log.severe("Unknown response identifier '${replying.responseId}' in message with response procedure '${replying.procedureId}'.");
    if (replying.requestId != 0) {
      _sendingResponse(replying.requestId, false);
    }
    if (outgoingSafety) {
      _replyAbort(replying.requestId, "Unknown response identifier.");
    }
  }

  void _invalidResponseType(TalkMessage replying) {
    _log.severe("Unknown response type in message with response procedure '${replying.procedureId}'");
    if (replying.requestId != 0) {
      _sendingResponse(replying.requestId, false);
    }
    if (outgoingSafety) {
      _replyAbort(replying.requestId, "Invalid response type.");
    }
  }

  void _abortRequiresReply(TalkMessage replying) {
    if (replying.requestId != 0) {
      _sendingResponse(replying.requestId, false);
      _replyAbort(replying.requestId, "Abort received.");
    }
  }

  /// Untested
  void _forwardReply(TalkChannel sender, TalkMessage replying,
      TalkMessage message, bool stream) {
    if (message.requestId != 0) {
      replyStreamRequest(replying, message.procedureId, message.data).listen(
          (TalkMessage reply) {
        sender._forwardReply(sender, message, reply, true);
      }, onError: (error, stack) {
        if (error is TalkEndOfStream) {
          TalkEndOfStream eos = error;
          sender._forwardReply(sender, message, eos.message, false);
        } else if (error is TalkAbort) {
          TalkAbort abort = error;
          sender.replyAbort(message, abort.message);
        } else {
          _log.severe("Forward error.");
          sender.replyAbort(message, "Forward error.");
        }
      });
    } else {
      replyMessage(replying, message.procedureId, message.data);
    }
  }

  /// Untested
  void forward(TalkChannel sender, TalkMessage message) {
    if (message.requestId != 0) {
      sendStreamRequest(message.procedureId, message.data).listen(
          (TalkMessage reply) {
        sender._forwardReply(sender, message, reply, true);
      }, onError: (error, stack) {
        if (error is TalkEndOfStream) {
          TalkEndOfStream eos = error;
          sender._forwardReply(sender, message, eos.message, false);
        } else if (error is TalkAbort) {
          TalkAbort abort = error;
          sender.replyAbort(message, abort.message);
        } else {
          _log.severe("Forward error.");
          sender.replyAbort(message, "Forward error.");
        }
      });
    } else {
      sendMessage(message.procedureId, message.data);
    }
  }

  /// Set false to allow malformed messages to be sent
  bool outgoingSafety = true;
}

/* end of file */
