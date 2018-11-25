/*
Switchboard
Microservice Network Architecture
Copyright (C) 2018  NO-BREAK SPACE OÜ
Author: Jan Boon <kaetemi@no-break.space>
*/

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:synchronized/synchronized.dart';
import 'package:switchboard/src/mux_channel.dart';
import 'package:switchboard/src/mux_connection.dart';
import 'package:switchboard/src/talk_channel.dart';
import 'package:switchboard/src/talk_message.dart';

class SwitchboardException implements Exception {
  final String message;
  const SwitchboardException(this.message);
  String toString() {
    return "SwitchboardException: $message";
  }
}

class ChannelInfo {
  final MuxChannel channel;

  final String host;

  final String service;
  final int serviceId;
  final String serviceName;

  final int shardSlot;

  final Uint8List payload;

  const ChannelInfo(this.channel, this.host, this.service, this.serviceId,
      this.serviceName, this.shardSlot, this.payload);
  factory ChannelInfo.fromPayload(MuxChannel channel, Uint8List payload) {
    int flags = payload[0];
    ByteBuffer buffer = payload.buffer;
    int o = 1 + payload.offsetInBytes;

    bool hasHost = (flags & 0x01) == 0x01;
    String host;

    bool hasService = (flags & 0x06) == 0x02;
    bool hasServiceId = (flags & 0x06) == 0x04;
    bool hasServiceName = (flags & 0x06) == 0x06;
    String service;
    int serviceId;
    String serviceName;

    bool hasShardSlot = (flags & 0x08) == 0x08;
    int shardSlot;

    if (hasHost) {
      int length = buffer.asUint8List(o++)[0];
      host = utf8.decode(buffer.asUint8List(o, length));
      o += length;
    }

    if (hasService) {
      int length = buffer.asUint8List(o++)[0];
      service = utf8.decode(buffer.asUint8List(o, length));
      o += length;
    } else if (hasServiceId) {
      serviceId = buffer.asUint32List(o)[0];
      o += 4;
    } else if (hasServiceName) {
      int length = buffer.asUint8List(o++)[0];
      serviceName = utf8.decode(buffer.asUint8List(o, length));
      o += length;
    }

    if (hasShardSlot) {
      shardSlot = buffer.asUint32List(o)[0];
      o += 4;
    }

    return new ChannelInfo(
        channel,
        host,
        service,
        serviceId,
        serviceName,
        shardSlot,
        buffer.asUint8List(o, payload.length + payload.offsetInBytes - o));
  }

  Uint8List toPayload() {
    Uint8List res = new Uint8List(1 +
        1 +
        ((host?.length ?? 0) * 4) +
        1 +
        ((service?.length ?? 0) * 4) +
        4 +
        1 +
        ((serviceName?.length ?? 0) * 4) +
        (payload?.length ?? 0));
    int o = 1;
    int flags = 0;
    if (host != null) {
      flags |= 0x01;
      Uint8List str = utf8.encode(host);
      res[o++] = str.length;
      res.setAll(o, str);
      o += str.length;
    }
    if (service != null) {
      flags |= 0x02;
      Uint8List str = utf8.encode(service);
      res[o++] = str.length;
      res.setAll(o, str);
      o += str.length;
    } else if (serviceId != null) {
      flags |= 0x04;
      res.buffer.asUint32List(o)[0] = serviceId;
      o += 4;
    } else if (serviceName != null) {
      flags |= 0x06;
      Uint8List str = utf8.encode(service);
      res[o++] = str.length;
      res.setAll(o, str);
      o += str.length;
    }
    if (shardSlot != null) {
      flags |= 0x08;
      res.buffer.asUint32List(o)[0] = shardSlot;
      o += 4;
    }
    if (payload != null) {
      res.setAll(o, payload);
      o += payload.length;
    }
    res[0] = flags;
    return res.buffer.asUint8List(0, o);
  }
}

class Switchboard extends Stream<ChannelInfo> {
  static Logger _log = new Logger('Switchboard.Router');
  final Lock _lock = new Lock();
  final StreamController<ChannelInfo> _controller =
      new StreamController<ChannelInfo>();
  final Set<HttpServer> _boundWebSockets = new Set<HttpServer>();
  final Set<MuxConnection> _muxConnections = new Set<MuxConnection>();
  final Map<String, MuxConnection> _openedConnectionMap =
      new Map<String, MuxConnection>();
  final Map<String, TalkChannel> _sharedTalkChannelMap =
      new Map<String, TalkChannel>();
  final Map<String, Future<TalkChannel>> _openingSharedTalkChannelMap =
      new Map<String, Future<TalkChannel>>();

  MuxConnection _endPointConnection;
  String _endPoint;

  TalkChannel _discoveryChannel; // TODO: DiscoveryInterface class
  String _discoveryEndPoint;
  String _discoveryService = "discover";

  Uint8List _payload = new Uint8List(0);

  bool _isPayload(Uint8List payload) {
    bool equalData = _payload == payload;
    if (!equalData && _payload != null && payload != null) {
      if (_payload.length == payload.length) {
        equalData = true;
        for (int i = 0; i < payload.length; ++i) {
          if (_payload[i] != payload[i]) {
            equalData = false;
            break;
          }
        }
      }
    }
    return equalData;
  }

  /// Sets the end point through which to connect to services.
  /// Either an end point or discovery service is set.
  Future<void> setEndPoint(String endPoint,
      {bool disconnectExisting: true}) async {
    _log.finest("Request to set endpoint to '$endPoint'.");
    _discoveryEndPoint = null;
    _endPoint = Uri.parse(endPoint).toString();
    return await _lock.synchronized(() async {
      _log.finest("Set endpoint to '$endPoint'.");
      MuxConnection endPointConnection = _endPointConnection;
      _endPointConnection = null;
      TalkChannel discoveryChannel = _discoveryChannel;
      _discoveryChannel = null;
      if (disconnectExisting) await endPointConnection?.closeChannels();
      await discoveryChannel?.close();
    });
  }

  /// Sets the discovery service to use to find services to connect to.
  /// Either an end point or discovery service is set.
  Future<void> setDiscoveryService(String endPoint,
      {String service = "discover", bool disconnectExisting: true}) async {
    _log.finest("Request to set discovery service to '$endPoint' '$service'.");
    _endPoint = null;
    _discoveryEndPoint = endPoint;
    _discoveryService = service;
    return await _lock.synchronized(() async {
      _log.finest("Set discovery service to '$endPoint' '$service'.");
      MuxConnection endPointConnection = _endPointConnection;
      _endPointConnection = null;
      TalkChannel discoveryChannel = _discoveryChannel;
      _discoveryChannel = null;
      if (disconnectExisting) await discoveryChannel?.close();
      await endPointConnection?.closeChannels();
    });
  }

  Future<void> setPayload(Uint8List payload, {bool closeExisting: true}) async {
    _log.finest("Request to set channel payload to '$payload'.");
    _payload = payload;
    return await _lock.synchronized(() async {
      _log.finest("Set channel payload to '$payload'.");
      // Wait for any pending opening channels
      await _openingSharedTalkChannelMap.values.toList();
      // Wait for all existing channels to close
      if (closeExisting)
        await _openedConnectionMap.values
            .map((MuxConnection connection) => connection.closeChannels());
    });
  }

  void listenDiscard() {
    listen((ChannelInfo event) {
      event.channel.listen(null);
      event.channel.close();
    });
  }

  @override
  StreamSubscription<ChannelInfo> listen(
      void Function(ChannelInfo event) onData,
      {Function onError,
      void Function() onDone,
      bool cancelOnError}) {
    return _controller.stream.listen(onData,
        onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  }

  void _onMuxChannel(MuxChannel channel, Uint8List payload) {
    _lock.synchronized(() {
      ChannelInfo info = new ChannelInfo.fromPayload(channel, payload);
      _log.fine(
          "Incoming channel to host '${info.host}', service '${info.service}', "
          "serviceId '${info.serviceId}', serviceName '${info.serviceName}', "
          "shardSlot '${info.shardSlot}'.");
      _controller.add(info);
    });
  }

  void _onMuxConnectionClose(MuxConnection connection) {
    _muxConnections.remove(connection);
    _log.fine(
        "Connection closed, ${_muxConnections.length} open connections remaining.");
  }

  Future<MuxChannel> openChannel(
    String uri, {
    String service,
    int serviceId,
    String serviceName,
    int shardSlot,
    Uint8List payload,
    bool autoCloseEmptyConnection = false,
  }) async {
    Uint8List pl = payload ?? _payload;
    Uri u = Uri.parse(uri ?? _endPoint);
    String us = u.toString();
    MuxConnection connection = _openedConnectionMap[us];
    await _lock.synchronized(() async {
      connection = _openedConnectionMap[us];
      if (connection == null) {
        if (u.scheme == "ws" || u.scheme == "wss") {
          _log.fine("Attempt to connect to WebSocket endpoint '${us}'.");
          WebSocket ws = await WebSocket.connect(us, protocols: ['wstalk2']);
          connection = new MuxConnection(
            ws,
            onChannel: _onMuxChannel,
            onClose: (MuxConnection connection) {
              _onMuxConnectionClose(connection);
              _openedConnectionMap.remove(us);
            },
            client: true,
            autoCloseEmptyConnection: autoCloseEmptyConnection,
            keepActiveAlivePing: true,
          );
          _openedConnectionMap[us] = connection;
          if (us == _endPoint) {
            _endPointConnection = connection;
          }
          _muxConnections.add(connection);
        } else {
          _log.severe(
              "Unknown uri scheme '${u.scheme}' in '${uri ?? _endPoint}'.");
          throw new SwitchboardException(
              "Unknown uri scheme '${u.scheme}' in '${uri ?? _endPoint}'.");
        }
      }
    });
    if (connection != null) {
      ChannelInfo info = new ChannelInfo(
          null, u.host, service, serviceId, serviceName, shardSlot, pl);
      _log.fine("Open channel on endpoint '$us', service '${info.service}', "
          "serviceId '${info.serviceId}', serviceName '${info.serviceName}', "
          "shardSlot '${info.shardSlot}', payload ${info.payload}");
      MuxChannel channel = connection.openChannel(info.toPayload());
      return channel;
    }
    return null;
  }

  Future<TalkChannel> openTalkChannel(
    String uri, {
    String service,
    int serviceId,
    String serviceName,
    int shardSlot,
    Uint8List payload,
    bool autoCloseEmptyConnection = false,
    bool shared = false,
  }) async {
    Uint8List pl = payload ?? _payload;
    String us = Uri.parse(uri ?? _endPoint).toString();
    String ush = us +
        "#" +
        (service ??
            (serviceId != null ? "~$serviceId" : ("@serviceName" ?? "*"))) +
        (shardSlot != 0 ? "/$shardSlot" : "");
    if (shared) {
      if (_sharedTalkChannelMap[ush]?.channel?.isOpen == true) {
        return _sharedTalkChannelMap[ush];
      }
      while (_openingSharedTalkChannelMap[ush] != null) {
        TalkChannel channel = await _openingSharedTalkChannelMap[ush];
        if (channel?.channel?.isOpen == true) {
          return channel;
        }
      }
    }
    Completer<TalkChannel> completer;
    if (shared) {
      completer = new Completer<TalkChannel>();
      _openingSharedTalkChannelMap[ush] = completer.future;
    }
    MuxChannel channel = await openChannel(uri,
        service: service,
        serviceId: serviceId,
        serviceName: serviceName,
        shardSlot: shardSlot,
        payload: pl,
        autoCloseEmptyConnection: autoCloseEmptyConnection);
    if (channel != null) {
      TalkChannel talkChannel = new TalkChannel(channel);
      if (shared) {
        _openingSharedTalkChannelMap.remove(ush);
        if (_isPayload(pl)) {
          _sharedTalkChannelMap[ush] = talkChannel;
          completer.complete(talkChannel);
        } else {
          completer.complete(null);
        }
      }
      return talkChannel;
    }
    if (shared) {
      completer.complete(null);
    }
    return null;
  }

  Future<void> bindWebSocket(dynamic address, int port, String path,
      {bool autoCloseEmptyConnection = false}) async {
    await _lock.synchronized(() async {
      _log.info(
          "Listen to WebSocket on address '${address}', port '${port}', path '$path'");
      HttpServer server = await HttpServer.bind(address, port);
      _boundWebSockets.add(server);
      try {
        server.listen((HttpRequest request) async {
          try {
            if (request.uri.path == path || request.uri.path == path + '/') {
              try {
                WebSocket ws = await WebSocketTransformer.upgrade(request);
                MuxConnection connection = new MuxConnection(
                  ws,
                  onChannel: _onMuxChannel,
                  onClose: _onMuxConnectionClose,
                  client: false,
                  autoCloseEmptyConnection: autoCloseEmptyConnection,
                  keepActiveAlivePing: false,
                );
                _muxConnections.add(connection);
              } catch (error, stack) {
                // TODO: Log
              }
            } else {
              // TODO: Log
              try {
                request.response.statusCode = HttpStatus.forbidden;
                request.response.close();
              } catch (error, stack) {
                // TODO: Log
              }
            }
          } catch (error, stack) {
            // TODO: Log
          }
        }, onError: (error, stack) {
          // TODO: Log
        }, onDone: () {
          if (_boundWebSockets.remove(server) != null) {
            // TODO: Log (ended without being closed, rebind?)
          }
        });
      } catch (error, stack) {
        _boundWebSockets.remove(server);
        server.close();
        rethrow;
      }
    });
  }

  Future<void> sendMessage(String service, String procedureId, Uint8List data,
      {int shardSlot}) async {
    TalkChannel channel = await openTalkChannel(_endPoint,
        service: service,
        shardSlot: shardSlot,
        payload: _payload,
        shared: true);
    channel.sendMessage(procedureId, data);
  }

  Future<TalkMessage> sendRequest(
      String service, String procedureId, Uint8List data,
      {int shardSlot}) async {
    TalkChannel channel = await openTalkChannel(_endPoint,
        service: service,
        shardSlot: shardSlot,
        payload: _payload,
        shared: true);
    return await channel.sendRequest(procedureId, data);
  }

  Stream<TalkMessage> sendStreamRequest(
      String service, String procedureId, Uint8List data,
      {int shardSlot}) async* {
    TalkChannel channel = await openTalkChannel(_endPoint,
        service: service,
        shardSlot: shardSlot,
        payload: _payload,
        shared: true);
    await for (TalkMessage message
        in channel.sendStreamRequest(procedureId, data)) {
      yield message;
    }
  }

  Future<void> close() async {
    List<Future<dynamic>> opening =
        _openingSharedTalkChannelMap.values.toList();
    await _lock.synchronized(() async {
      _log.fine("Close switchboard.");
      List<Future<dynamic>> futures = new List<Future<dynamic>>();
      // await _openingConnectionMap.values.toList();
      List<HttpServer> boundWebSockets = _boundWebSockets.toList();
      for (HttpServer server in boundWebSockets) {
        _boundWebSockets.remove(server);
        futures.add(server.close());
      }
      List<MuxConnection> openedMuxConnections =
          _openedConnectionMap.values.toList();
      _openedConnectionMap.clear();
      for (MuxConnection connection in openedMuxConnections) {
        futures.add(connection.close());
      }
      await futures + opening;
    });
  }
}

/* end of file */
