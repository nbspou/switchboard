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

import 'package:switchboard/src/mux_channel.dart';
import 'package:switchboard/src/mux_connection.dart';

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
        payload.length);

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
    res.setAll(o, payload);
    o += payload.length;
    res[0] = flags;
    return res.buffer.asUint8List(0, o);
  }
}

class Switchboard extends Stream<ChannelInfo> {
  final StreamController<ChannelInfo> _controller =
      new StreamController<ChannelInfo>();
  final Set<HttpServer> _boundWebSockets = new Set<HttpServer>();
  final Set<MuxConnection> _muxConnections = new Set<MuxConnection>();
  final Map<String, MuxConnection> _openedConnectionMap =
      new Map<String, MuxConnection>();

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
    _controller.add(new ChannelInfo.fromPayload(channel, payload));
  }

  void _onMuxConnectionClose(MuxConnection connection) {
    _muxConnections.remove(connection);
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
    Uri u = Uri.parse(uri);
    String us = u.toString();
    MuxConnection connection = _openedConnectionMap[us];
    if (connection == null) {
      if (u.scheme == "ws" || u.scheme == "wss") {
        WebSocket ws = await WebSocket.connect(uri, protocols: ['wstalk2']);
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
        _muxConnections.add(connection);
      } else {
        throw new SwitchboardException(
            "Unknown uri scheme '${u.scheme}' in '$uri'.");
      }
    }
    if (connection != null) {
      return connection.openChannel(new ChannelInfo(
              null, u.host, service, serviceId, serviceName, shardSlot, payload)
          .toPayload());
    }
  }

  Future<void> bindWebSocket(dynamic address, int port, String path,
      bool autoCloseEmptyConnection) async {
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
  }

  Future<void> close() async {
    List<HttpServer> boundWebSockets = _boundWebSockets.toList();
    for (HttpServer server in boundWebSockets) {
      _boundWebSockets.remove(server);
      await server.close();
    }
    List<MuxConnection> openedMuxConnections =
        _openedConnectionMap.values.toList();
    _openedConnectionMap.clear();
    for (MuxConnection connection in openedMuxConnections) {
      await connection.close();
    }
  }
}

/* end of file */
