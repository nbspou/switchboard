import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'dart:typed_data';

import 'wstalk_message.dart';

class _RemoteResponseState {
  final int id;
  final Completer<TalkMessage> completer;
  final Timer timer;
  const _RemoteResponseState(this.id, this.completer, this.timer);
}

class _RemoteStreamResponseState {
  final int id;
  final StreamController<TalkMessage> controller;
  final Timer timer;
  const _RemoteStreamResponseState(this.id, this.controller, this.timer);
}

class TalkException implements Exception {
  final String message;
  const TalkException(this.message);
  String toString() {
    return "ClientException { message: \"${message}\" }";
  }
}

class TalkSocket {
  /// We give the remote host 15 seconds to reply to a message
  static const int _receiveTimeOutMs = 15000;

  /// We give ourselves 10 seconds to reply to a message
  static const int _sendTimeOutMs = 10000;

  static int _idExtend = encode("_EXTEND_");
  static int _idExcept = encode("_EXCEPT_");
  static int _idPing = encode("__PING__");
  static int _idPong = encode("__PONG__");

  static int _idEndOfStream = encode("__EOFS__");
  static int _idMultiPing = encode("_M_PING_");
  static int _idMultiPong = encode("_M_PONG_");

  final WebSocket _webSocket;

  Map<int, StreamController<TalkMessage>> _streams =
      new Map<int, StreamController<TalkMessage>>();
  bool _listening;

  Map<int, Timer> _localReplyTimers = new Map<int, Timer>();
  Map<int, _RemoteResponseState> _remoteResponseStates =
      new Map<int, _RemoteResponseState>();
  Map<int, _RemoteStreamResponseState> _remoteStreamResponseStates =
      new Map<int, _RemoteStreamResponseState>();

  int _nextRequestId = 1;

  int get closeCode {
    return _webSocket.closeCode;
  }

  String get closeReason {
    return _webSocket.closeReason;
  }

  int get readyState {
    return _webSocket.readyState;
  }

  TalkSocket(WebSocket webSocket) : _webSocket = webSocket {
    _listening = true;
    stream(_idExcept).listen((TalkMessage message) {
      throw new TalkException(
          "Received '_EXCEPT_' with no response identifier. Invalid message");
    });
    stream(_idPing).listen((TalkMessage message) {
      try {
        sendMessage(_idPong, new List<int>(), replying: message);
      } catch (error, stack) {
        // Can silently discard any failure here, it's not important
      }
    });
  }

  /// Call once to start processing incoming messages.
  /// Disconnection exceptions and so on will come from here.
  /// When this returns, the connection is guaranteed dead.
  /// Can only be called once.
  Future<Null> listen() async {
    return await _listen(_webSocket);
  }

  Future<Null> _listen(Stream<dynamic> s) async {
    if (!_listening) {
      throw new TalkException(
          "Not listening to this talk socket, connection was already lost");
    }
    try {
      await for (dynamic e in s) {
        if (e is List<int>) {
          List<int> bytes = e;
          int reserved =
              bytes[0] | (bytes[1] << 8) | (bytes[2] << 16) | (bytes[3] << 24);
          if (reserved != 1 || reserved != 2)
            throw new TalkException(
                "Unexpected reserved value (${reserved}), expect 1 or 2");
          int id = bytes[4] |
              (bytes[5] << 8) |
              (bytes[6] << 16) |
              (bytes[7] << 24) |
              (bytes[8] << 32) |
              (bytes[9] << 40) |
              (bytes[10] << 48) |
              (bytes[11] << 56);
          int request = bytes[12] | (bytes[13] << 8);
          int response = bytes[14] | (bytes[15] << 8);
          List<int> data = bytes.sublist(16);
          bool streamRequest = reserved == 2;
          TalkMessage message = new TalkMessage(id, request, response, data, streamRequest);
          _received(message);
        } else {
          throw new TalkException(
              "Unexpected WebSocket stream data type '${e.runtimeType}'");
        }
      }
    } catch (ex) {
      _listening = false;
      _webSocket.close(1011).catchError((ex) {
        throw ex;
      });
      _closeAndClear();
      throw ex;
    }
    _listening = false;
    _webSocket.close(1000).catchError((ex) {
      throw ex;
    });
    _closeAndClear();
  }

  Future<int> ping() async {
    DateTime now = new DateTime.now();
    TalkMessage pong = await sendRequest(_idPing, new List<int>());
    assert(pong.id == _idPong);
    return new DateTime.now().millisecondsSinceEpoch -
        now.millisecondsSinceEpoch;
  }

  // stream responses and completions can be requests as well!
  void _send(TalkMessage message) async {
    Uint8List data = new Uint8List(message.data.length + 16);
    data[0] = message.streamRequest ? 2 : 1;
    data[1] = 0;
    data[2] = 0;
    data[3] = 0;
    data[4] = (message.id) & 0xFF;
    data[5] = (message.id >> 8) & 0xFF;
    data[6] = (message.id >> 16) & 0xFF;
    data[7] = (message.id >> 24) & 0xFF;
    data[8] = (message.id >> 32) & 0xFF;
    data[9] = (message.id >> 40) & 0xFF;
    data[10] = (message.id >> 48) & 0xFF;
    data[11] = (message.id >> 56) & 0xFF;
    data[12] = (message.request) & 0xFF;
    data[13] = (message.request >> 8) & 0xFF;
    data[14] = (message.response) & 0xFF;
    data[15] = (message.response >> 8) & 0xFF;
    data.setRange(16, message.data.length + 16, message.data);
    _webSocket.add(data);
  }

  /// Extend timeouts (or fail)
  void sendExtend(TalkMessage replying) {
    if (_localReplyTimers.containsKey(replying.request)) {
      _localReplyTimers[replying.request].cancel();
      _localReplyTimers.remove(replying.request);
      _setLocalReplyTimer(replying);
      // Note this isn't using 'more', specially handled
      sendMessage(_idExtend, new Uint8List(0), replying: replying);
    } else {
      throw new TalkException(
          "Failed to extend time, already replied or timed out");
    }
  }

  void sendEndOfStream(TalkMessage replying) {
    sendMessage(_idEndOfStream, new Uint8List(0), replying: replying);
  }

  /// Throw an exception as message reply
  void sendException(String message, TalkMessage replying) {
    sendMessage(_idExcept, utf8.encode(message), replying: replying);
  }

  void sendMessage(int id, List<int> data, {TalkMessage replying,}) {
    if (!_listening) {
      throw new TalkException(
          "Not sending to this talk socket, connection was already lost");
    }

    if (replying != null && id != _idExtend) {
      if (!_localReplyTimers.containsKey(replying.request)) {
        throw new TalkException(
            "Request was already replied to, or request timed out");
      }
      _localReplyTimers[replying.request].cancel();
      _localReplyTimers.remove(replying.request);
      // Keep restoring timer until end of stream
      if (replying.streamRequest && id != _idEndOfStream)
        _setLocalReplyTimer(replying);
    }

    _send(
        new TalkMessage(id, 0, replying != null ? replying.request : 0, data));
  }

  void _setRemoteResponseTimer(
      Completer<TalkMessage> completer, int request, int id) {
    Timer timer = new Timer(new Duration(milliseconds: _receiveTimeOutMs), () {
      // Check if it's not already been removed, may happen due to race condition
      if (_remoteResponseStates.containsKey(request)) {
        print(
            "Message was not replied to by the remote server in time '${decode(id)}', throw exception");
        completer.completeError(new TalkException(
            "No reply received in time from the remote server"));
        _remoteResponseStates.remove(request);
      }
    });
    _remoteResponseStates[request] =
        new _RemoteResponseState(id, completer, timer);
  }

  void _setRemoteStreamResponseTimer(
      StreamController<TalkMessage> controller, int request, int id) {
    Timer timer = new Timer(new Duration(milliseconds: _receiveTimeOutMs), () {
      // Check if it's not already been removed, may happen due to race condition
      if (_remoteStreamResponseStates.containsKey(request)) {
        print(
            "Message was not replied to further by the remote server in time '${decode(id)}', throw exception");
        controller.addError(new TalkException(
            "No additional streaming replies received in time from the remote server"));
        controller.close();
        _remoteStreamResponseStates.remove(request);
      }
    });
    _remoteStreamResponseStates[request] =
        new _RemoteStreamResponseState(id, controller, timer);
  }

  void _preValidateRequest() {
    if (!_listening) {
      throw new TalkException(
          "Not sending to this talk socket, connection was already lost");
    }

    if (_remoteResponseStates.length + _remoteStreamResponseStates.length >=
        4096) {
      throw new TalkException(
          "Too many requests sent, potential out-of-memory attack");
    }
  }

  /// Sends a request, expecting a message in reply
  Future<TalkMessage> sendRequest(int id, List<int> data,
      {TalkMessage replying,}) {
    _preValidateRequest();

    if (replying != null) {
      if (!_localReplyTimers.containsKey(replying.request)) {
        throw new TalkException(
            "Request was already replied to, or request timed out");
      }
      _localReplyTimers[replying.request].cancel();
      _localReplyTimers.remove(replying.request);
      // Keep restoring timer until end of stream
      if (replying.streamRequest && id != _idEndOfStream)
        _setLocalReplyTimer(replying);
    }

    int request = _nextRequestId;
    _incrementNextRequestId();

    Completer<TalkMessage> completer = new Completer<TalkMessage>();
    _setRemoteResponseTimer(completer, request, id);

    _send(
        new TalkMessage(
            id, request, replying != null ? replying.request : 0, data));
    return completer.future;
  }

  Stream<TalkMessage> sendStreamRequest(int id, List<int> data,
      {TalkMessage replying,}) {
    _preValidateRequest();

    if (replying != null) {
      if (!_localReplyTimers.containsKey(replying.request)) {
        throw new TalkException(
            "Request was already replied to, or request timed out");
      }
      _localReplyTimers[replying.request].cancel();
      _localReplyTimers.remove(replying.request);
      // Keep restoring timer until end of stream
      if (replying.streamRequest && id != _idEndOfStream)
        _setLocalReplyTimer(replying);
    }

    int request = _nextRequestId;
    _incrementNextRequestId();

    StreamController<TalkMessage> controller =
        new StreamController<TalkMessage>();
    _setRemoteStreamResponseTimer(controller, request, id);

    _send(
        new TalkMessage(
            id, request, replying != null ? replying.request : 0, data, true));
    return controller.stream;
  }

  void _incrementNextRequestId() {
    ++_nextRequestId;
    _nextRequestId &= 0x7FFF;
    if (_nextRequestId == 0) ++_nextRequestId;
  }

  /// Encode a name into it's integer representation
  /// Names both starting and ending with underscore are reserved for now for internal implementation
  static int encode(String name) {
    Uint8List nameenc = utf8.encode(name);
    Uint8List idstr = new Uint8List(8);
    int i = 0;
    for (; i < nameenc.length && i < 8; ++i) {
      idstr[i] = nameenc[i];
    }
    for (; i < 8; ++i) {
      idstr[i] = 0;
    }
    return idstr[0] |
        (idstr[1] << 8) |
        (idstr[2] << 16) |
        (idstr[3] << 24) |
        (idstr[4] << 32) |
        (idstr[5] << 40) |
        (idstr[6] << 48) |
        (idstr[7] << 56);
  }

  /// Decode an id into it's string representation
  static String decode(int id) {
    List<int> idstr = new List<int>(9);
    idstr[0] = id & 0xFF;
    idstr[1] = (id >> 8) & 0xFF;
    idstr[2] = (id >> 16) & 0xFF;
    idstr[3] = (id >> 24) & 0xFF;
    idstr[4] = (id >> 32) & 0xFF;
    idstr[5] = (id >> 40) & 0xFF;
    idstr[6] = (id >> 48) & 0xFF;
    idstr[7] = (id >> 56) & 0xFF;
    idstr[8] = 0;
    return utf8.decode(idstr);
  }

  StreamController<TalkMessage> _streamController(int id) {
    if (!_listening) {
      throw new TalkException(
          "Not listening to this talk socket, connection was already lost");
    }
    if (_streams.containsKey(id)) {
      return _streams[id];
    } else {
      if (_streams.length >= 4096) {
        throw new TalkException(
            "Too many stream controllers requested, potential out-of-memory attack");
      }
      StreamController<TalkMessage> streamController =
          new StreamController<TalkMessage>();
      _streams[id] = streamController;
      return streamController;
    }
  }

  /// Get a named message stream to listen to
  Stream<TalkMessage> stream(int id) {
    return _streamController(id).stream;
  }

  void _setLocalReplyTimer(TalkMessage message) {
    Timer timer = new Timer(new Duration(milliseconds: _sendTimeOutMs), () {
      // Check if it's not already been removed, may happen due to race condition
      if (_localReplyTimers.containsKey(message.request)) {
        print(
            "Message was not replied to by the local program in time '${decode(message.id)}', reply with '_EXCEPT_'");
        sendException("No Reply Sent", message);
        _localReplyTimers.remove(message.request);
      }
    });
    _localReplyTimers[message.request] = timer;
  }

  /// Processes a received message
  void _received(TalkMessage message) {
    // print("Received message with name '${decode(message.id)}'");
    if (message.request != 0) {
      // Requesting message requires a swift reply from us,
      // if not handled by the code in time this may indicate a serious issue!
      if (_localReplyTimers.length >= 4096) {
        throw new TalkException(
            "Too many requests received, potential out-of-memory attack");
      }
      _setLocalReplyTimer(message);
    }
    if (message.response != 0) {
      // Responding messages are handled specially,
      // they are passed directly to the requesting function
      if (!_remoteResponseStates.containsKey(message.response)) {
        if (!_remoteStreamResponseStates.containsKey(message.response)) {
          // Response received but no longer expected
          if (message.request != 0) {
            sendException("No Request Sent / Response Timeout", message);
          }
          print(
              "Message was not replied to by the remote server in time, ignoring late response '${decode(message.id)}'");
        } else {
          // TODO: Received response to stream request, depending on the message mode the request will be closed
        }
      } else {
        // Received response to a regular request
        _RemoteResponseState state = _remoteResponseStates[message.response];
        _remoteResponseStates.remove(message.response);
        state.timer.cancel();
        if (message.id == _idExtend) {
          _setRemoteResponseTimer(state.completer, message.response, state.id);
        } else if (message.id == _idExcept) {
          state.completer
              .completeError(new TalkException(utf8.decode(message.data)));
        } else {
          state.completer.complete(message);
        }
      }
    } else {
      _streamController(message.id).add(message);
    }
  }

  /// Close and clear all the stream listeners
  void _closeAndClear() {
    for (StreamController<TalkMessage> streamController in _streams.values) {
      streamController.close();
    }
    _streams.clear();
    for (Timer timer in _localReplyTimers.values) {
      timer.cancel();
    }
    _localReplyTimers.clear();
    for (_RemoteResponseState state in _remoteResponseStates.values) {
      state.timer.cancel();
      state.completer.completeError(
          new TalkException("Talk socket closing, reply cannot be received"));
    }
    _remoteResponseStates.clear();
    for (_RemoteStreamResponseState state
        in _remoteStreamResponseStates.values) {
      state.timer.cancel();
      state.controller.addError(
          new TalkException("Talk socket closing, replies cannot be received"));
      state.controller.close();
    }
    _remoteStreamResponseStates.clear();
  }

  // Closes the connection
  void close() {
    if (_listening) {
      _webSocket.close(1000).catchError((ex) {
        throw ex;
      });
    }
  }

  static Future<TalkSocket> connect(String url) async {
    WebSocket webSocket = await WebSocket.connect(url, protocols: ['wstalk']);
    return new TalkSocket(webSocket);
  }
}
