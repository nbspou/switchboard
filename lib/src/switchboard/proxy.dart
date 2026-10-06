/*
Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Author: Jan Boon <jan.boon@kaetemi.be>
*/

import 'dart:async';

import 'package:logging/logging.dart';

import '../address/channel_address.dart';
import '../address/service_address.dart';
import '../mux/mux_channel.dart';
import '../mux/mux_connection.dart';
import '../name.dart';
import '../status.dart';
import 'generic_status.dart';
import 'incoming_channel.dart';
import 'resolver.dart';
import 'switchboard.dart';

final Logger _log = Logger('Switchboard.Router');

/// Channel proxying: forwards every DATA subframe between [a] and [b], in
/// order and unchanged, and forwards the close.
///
/// When one side's stream ends (its peer sent CLOSE, or its connection was
/// lost) the other side is closed with that side's end status.
/// `CONNECTION_LOST`, which is local only, is sent as `UNAVAILABLE`, and
/// application codes (256 and above), which mux CLOSE must not carry, as
/// `UNKNOWN`. A subframe that cannot be forwarded (it exceeds the frame
/// limit the receiving peer announced) closes both sides with that error.
///
/// Both streams are listened to before this returns, so subframes that
/// arrived before the call (buffered by the channels) are forwarded too.
/// Neither stream may have been listened to already (for example by
/// wrapping the channel in a `TalkChannel`); if one has, both channels are
/// closed with `INTERNAL`. Completes when both channels are done; never
/// throws and never completes with an error.
///
/// See the wiki page "Switchboard Proxying", section "Channel proxying".
Future<void> pipeChannels(MuxChannel a, MuxChannel b) {
  try {
    _forward(a, b);
    _forward(b, a);
  } on Object catch (e) {
    _log.warning('proxy: cannot pipe channels ${a.id} and ${b.id}: $e');
    final status = Status.of(StatusCode.internal, 'cannot pipe channels');
    unawaited(a.close(status));
    unawaited(b.close(status));
  }
  return Future.wait<Status>([a.done, b.done]).then<void>((_) {});
}

void _forward(MuxChannel from, MuxChannel to) {
  from.stream.listen(
    (subframe) {
      if (!to.canSend) {
        // The other side is closing; its CLOSE ends this side too.
        return;
      }
      try {
        to.send(subframe);
      } on SwitchboardException catch (e) {
        _log.warning(
          'proxy: cannot forward ${subframe.length} bytes from channel '
          '${from.id} to channel ${to.id}: ${e.status}',
        );
        final status = e.code == null
            ? Status.of(StatusCode.internal)
            : genericStatus(e.code!);
        unawaited(to.close(status));
        unawaited(from.close(status));
      }
    },
    onError: (Object e) => _log.fine('proxy: channel ${from.id} failed: $e'),
    onDone: () {
      unawaited(from.done.then((status) => to.close(_closeStatusFor(status))));
    },
  );
}

/// The status a proxy sends in CLOSE when the channel on the other side
/// ended with [status]: `CONNECTION_LOST` becomes `UNAVAILABLE` (with a
/// generic reason, as the local reason concerns the proxy's own
/// connection) and application codes become `UNKNOWN`; everything else,
/// which the peer on the other side sent, is forwarded as is.
Status _closeStatusFor(Status status) {
  if (status.known == StatusCode.connectionLost) {
    return Status.of(StatusCode.unavailable, 'connection lost');
  }
  if (status.isApplicationCode) {
    return Status.of(
      StatusCode.unknown,
      'application status ${status.code}'
      '${status.reason.isEmpty ? '' : ': ${status.reason}'}',
    );
  }
  return status;
}

/// A [ChannelHandler] that proxies channels to the service they address,
/// for use as [Switchboard.catchAll] on a frontend endpoint or a relay.
///
/// For each channel:
///
/// 1. If [allow] returns false for the address header, the channel is
///    rejected with `PERMISSION_DENIED`. The default [allow] refuses the
///    reserved types (`_ns` and the rest of the `_` namespace), so that
///    the naming service of the mesh behind the proxy is not reachable
///    through it; pass an explicit [allow] to proxy those deliberately. A
///    channel without a service type is rejected with `NOT_FOUND`.
/// 2. If the client connection the channel arrived on already has
///    [maxChannelsPerConnection] channels being forwarded (0 = no limit),
///    the channel is rejected with `RESOURCE_EXHAUSTED`. All clients share
///    the proxy's pooled connections to a backend, so without this bound
///    one client could use up the channels a backend accepts for everyone.
/// 3. If the header carries a host hint and [Switchboard.allowHostHint] is
///    set, the proxy connects to that host: a URI, or `host:port` meaning
///    `tcp://host:port`. Otherwise the hint is ignored and the destination
///    is resolved with [resolver] (default: [Switchboard.resolver]) as in
///    [Switchboard.selectAndConnect]. Destinations that are this node's own
///    listeners ([Switchboard.isOwnEndpoint]) are never connected to: a
///    record or hint pointing back at the proxy would otherwise make it
///    forward to itself without end. A failure rejects the channel with
///    its status code (`NOT_FOUND`, `UNAVAILABLE`, ...); a missing
///    resolver or a closing node is `UNAVAILABLE`.
/// 4. A channel is opened to the destination with the same open payload,
///    except that the host hint is removed and the instance is set to the
///    selected one. The application payload is forwarded unchanged; the
///    proxy's own [Switchboard.defaultPayload] is not applied.
/// 5. The two channels are joined with [pipeChannels].
///
/// Rejections carry the status code and a generic reason only; the
/// details (instance ids, endpoints, resolver state) are logged locally.
///
/// Honouring host hints makes the node an open relay; see
/// [Switchboard.allowHostHint].
ChannelHandler proxyHandler(
  Switchboard switchboard, {
  bool Function(ChannelAddress address)? allow,
  Resolver? resolver,
  int maxChannelsPerConnection = 256,
}) {
  RangeError.checkNotNegative(
    maxChannelsPerConnection,
    'maxChannelsPerConnection',
  );
  final permitted = allow ?? _notReserved;
  // Channels being forwarded, per client connection.
  final forwarding = Expando<int>('forwarded channels');
  return (incoming) async {
    final address = incoming.address;
    if (!permitted(address)) {
      _log.fine('proxy: $incoming not allowed');
      await incoming.reject(genericStatus(StatusCode.permissionDenied));
      return;
    }
    final type = address.type;
    if (type == null) {
      _log.fine('proxy: $incoming has no service type');
      await incoming.reject(genericStatus(StatusCode.notFound));
      return;
    }
    final client = incoming.connection;
    final count = forwarding[client] ?? 0;
    if (maxChannelsPerConnection > 0 && count >= maxChannelsPerConnection) {
      _log.info(
        'proxy: $incoming refused, $count channels of this connection '
        'are being forwarded',
      );
      await incoming.reject(genericStatus(StatusCode.resourceExhausted));
      return;
    }
    forwarding[client] = count + 1;
    try {
      final MuxChannel backend;
      try {
        backend = await _openBackend(switchboard, address, type, resolver);
      } on SwitchboardException catch (e) {
        _log.fine('proxy: $incoming: ${e.status}');
        await incoming.reject(genericStatus(e.code ?? StatusCode.unavailable));
        return;
      }
      _log.fine(
        'proxy: $incoming piped to channel ${backend.id} of '
        '${backend.connection}',
      );
      await pipeChannels(incoming.channel, backend);
    } finally {
      final left = (forwarding[client] ?? 1) - 1;
      forwarding[client] = left > 0 ? left : null;
    }
  };
}

bool _notReserved(ChannelAddress address) =>
    !(address.type?.isReserved ?? false);

/// Opens the outgoing channel. A missing resolver or a closing node
/// (`FAILED_PRECONDITION` locally) is reported as `UNAVAILABLE`: to the
/// client, the proxy is simply unable to forward.
Future<MuxChannel> _openBackend(
  Switchboard switchboard,
  ChannelAddress address,
  Name type,
  Resolver? resolver,
) async {
  try {
    return await _openBackendChannel(switchboard, address, type, resolver);
  } on SwitchboardException catch (e) {
    if (e.code == StatusCode.failedPrecondition) {
      throw SwitchboardException.of(StatusCode.unavailable, e.status.reason);
    }
    rethrow;
  }
}

Future<MuxChannel> _openBackendChannel(
  Switchboard switchboard,
  ChannelAddress address,
  Name type,
  Resolver? resolver,
) async {
  final host = address.host;
  for (var attempt = 0; ; attempt++) {
    final MuxConnection connection;
    final ChannelAddress header;
    if (host != null && switchboard.allowHostHint) {
      final endpoint = _hostHintEndpoint(host);
      if (switchboard.isOwnEndpoint(endpoint)) {
        _log.warning('proxy: host hint $host points at this node itself');
        throw SwitchboardException.of(
          StatusCode.unavailable,
          'host hint $host is this node',
        );
      }
      connection = await switchboard.connect(endpoint);
      header = address.copyWith(clearHost: true);
    } else {
      final (record, selected) = await switchboard.selectAndConnect(
        ServiceAddress(type, address.instance),
        shard: address.shard,
        resolver: resolver,
        excludeOwnEndpoints: true,
      );
      connection = selected;
      header = address.copyWith(
        instance: record.address.instance,
        clearHost: true,
      );
    }
    try {
      return connection.open(header.encode());
    } on SwitchboardException catch (e) {
      // A pooled connection may have received GOAWAY, or filled up to the
      // peer's channel limit, in the meantime; one retry replaces it.
      if (attempt > 0 ||
          (e.code != StatusCode.failedPrecondition &&
              e.code != StatusCode.resourceExhausted)) {
        rethrow;
      }
    }
  }
}

Uri _hostHintEndpoint(String host) {
  try {
    final uri = Uri.parse(host.contains('://') ? host : 'tcp://$host');
    if (uri.host.isEmpty) {
      throw const FormatException('no host');
    }
    return uri;
  } on FormatException catch (e) {
    throw SwitchboardException.of(
      StatusCode.invalidArgument,
      'bad host hint "$host": ${e.message}',
    );
  }
}
