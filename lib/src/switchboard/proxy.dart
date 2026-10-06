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
        final status = _closeStatusFor(e.status);
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
/// ended with [status]: `CONNECTION_LOST` becomes `UNAVAILABLE` and
/// application codes become `UNKNOWN`; everything else is forwarded as is.
Status _closeStatusFor(Status status) {
  if (status.known == StatusCode.connectionLost) {
    final reason = status.reason.isEmpty ? '' : ': ${status.reason}';
    return Status.of(StatusCode.unavailable, 'connection lost$reason');
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
/// 1. If [allow] is given and returns false for the address header, the
///    channel is rejected with `PERMISSION_DENIED`. A channel without a
///    service type is rejected with `NOT_FOUND`.
/// 2. If the header carries a host hint and [Switchboard.allowHostHint] is
///    set, the proxy connects to that host: a URI, or `host:port` meaning
///    `tcp://host:port`. Otherwise the hint is ignored and the destination
///    is resolved with [resolver] (default: [Switchboard.resolver]) as in
///    [Switchboard.selectAndConnect]. A failure rejects the channel with
///    its status (`NOT_FOUND`, `UNAVAILABLE`, ...).
/// 3. A channel is opened to the destination with the same open payload,
///    except that the host hint is removed and the instance is set to the
///    selected one. The application payload is forwarded unchanged; the
///    proxy's own [Switchboard.defaultPayload] is not applied.
/// 4. The two channels are joined with [pipeChannels].
///
/// Honouring host hints makes the node an open relay; see
/// [Switchboard.allowHostHint].
ChannelHandler proxyHandler(
  Switchboard switchboard, {
  bool Function(ChannelAddress address)? allow,
  Resolver? resolver,
}) {
  return (incoming) async {
    final address = incoming.address;
    if (allow != null && !allow(address)) {
      _log.fine('proxy: $incoming not allowed');
      await incoming.reject(
        Status.of(StatusCode.permissionDenied, 'destination not allowed'),
      );
      return;
    }
    final type = address.type;
    if (type == null) {
      await incoming.reject(
        Status.of(StatusCode.notFound, 'no service type to proxy to'),
      );
      return;
    }
    final MuxChannel backend;
    try {
      backend = await _openBackend(switchboard, address, type, resolver);
    } on SwitchboardException catch (e) {
      _log.fine('proxy: $incoming: ${e.status}');
      await incoming.reject(e.status);
      return;
    }
    _log.fine(
      'proxy: $incoming piped to channel ${backend.id} of '
      '${backend.connection}',
    );
    await pipeChannels(incoming.channel, backend);
  };
}

Future<MuxChannel> _openBackend(
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
      connection = await switchboard.connect(_hostHintEndpoint(host));
      header = address.copyWith(clearHost: true);
    } else {
      final (record, selected) = await switchboard.selectAndConnect(
        ServiceAddress(type, address.instance),
        shard: address.shard,
        resolver: resolver,
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
      // A pooled connection may have received GOAWAY in the meantime; one
      // retry replaces it.
      if (attempt > 0 || e.code != StatusCode.failedPrecondition) {
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
