/*
Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Author: Jan Boon <jan.boon@kaetemi.be>
*/

/// Channel forwarding shared by `proxyHandler` and `RelayService`: the
/// bound on the channels forwarded per client connection and the opening
/// of the outgoing channel (never to the node itself). The piping is
/// `pipeChannels`. Internal to the package; not exported.
library;

import 'package:logging/logging.dart';

import '../address/channel_address.dart';
import '../address/service_address.dart';
import '../mux/mux_channel.dart';
import '../mux/mux_connection.dart';
import '../name.dart';
import '../naming/naming_protocol.dart';
import '../status.dart';
import 'resolver.dart';
import 'switchboard.dart';

final Logger _log = Logger('Switchboard.Router');

/// Counts the channels being forwarded for each client connection,
/// bounded by [max] (0: no bound), wiki page "Switchboard Proxying": all
/// clients share the forwarding node's connections to a destination, so
/// without a bound one client could use up the channels a destination
/// accepts for everyone.
class ForwardingBound {
  /// A bound of [max] channels per connection; 0 for none.
  ForwardingBound(this.max);

  /// The bound; 0 for none.
  final int max;

  final Expando<int> _counts = Expando<int>('forwarded channels');

  /// The channels of [connection] being forwarded.
  int countOf(MuxConnection connection) => _counts[connection] ?? 0;

  /// Counts one more channel of [connection]; false, counting nothing,
  /// when [connection] has [max] already. Each true is matched by an
  /// [exit] once the channel is done.
  bool enter(MuxConnection connection) {
    final count = countOf(connection);
    if (max > 0 && count >= max) {
      return false;
    }
    _counts[connection] = count + 1;
    return true;
  }

  /// A channel of [connection] counted by [enter] is done.
  void exit(MuxConnection connection) {
    final left = countOf(connection) - 1;
    _counts[connection] = left > 0 ? left : null;
  }
}

/// The outgoing channel of a forwarded channel, the header it was opened
/// with, and whether it went to a host hint rather than through the
/// resolver.
typedef ForwardTarget = ({
  MuxChannel channel,
  ChannelAddress header,
  bool hostHint,
});

/// Opens the outgoing channel for a forwarded channel addressed to
/// [address] (of service [type]): to its host hint when it has one and
/// [Switchboard.allowHostHint] is set, otherwise to the instance the node
/// selects through [resolver] (default: the node's) as
/// [Switchboard.selectAndConnect] does, the selected instance filled in
/// and the host hint removed, and only to records [where] accepts. Never
/// to the node's own listeners ([Switchboard.isOwnEndpoint]): a record or
/// a hint pointing back at the node would make it forward to itself
/// without end. The application payload is [address]'s, unchanged.
///
/// Throws [SwitchboardException] with the status of the failure
/// (`NOT_FOUND`, `UNAVAILABLE`, ...); a missing resolver or a closing node
/// (`FAILED_PRECONDITION` locally) is reported as `UNAVAILABLE`: to the
/// client, the node is simply unable to forward.
Future<ForwardTarget> openForwarded(
  Switchboard switchboard,
  ChannelAddress address,
  Name type, {
  Resolver? resolver,
  bool Function(ServiceRecord record)? where,
}) async {
  try {
    return await _open(switchboard, address, type, resolver, where);
  } on SwitchboardException catch (e) {
    if (e.code == StatusCode.failedPrecondition) {
      throw SwitchboardException.of(StatusCode.unavailable, e.status.reason);
    }
    rethrow;
  }
}

Future<ForwardTarget> _open(
  Switchboard switchboard,
  ChannelAddress address,
  Name type,
  Resolver? resolver,
  bool Function(ServiceRecord record)? where,
) async {
  final host = address.host;
  if (host == null || !switchboard.allowHostHint) {
    final (channel, header) = await switchboard.openSelected(
      ServiceAddress(type, address.instance),
      address,
      resolver: resolver,
      excludeOwnEndpoints: true,
      where: where,
    );
    return (channel: channel, header: header, hostHint: false);
  }
  final endpoint = _hostHintEndpoint(host);
  if (switchboard.isOwnEndpoint(endpoint)) {
    _log.warning('forwarding: host hint $host points at this node itself');
    throw SwitchboardException.of(
      StatusCode.unavailable,
      'host hint $host is this node',
    );
  }
  final header = address.copyWith(clearHost: true);
  for (var attempt = 0; ; attempt++) {
    final connection = await switchboard.connect(endpoint);
    try {
      return (
        channel: connection.open(header.encode()),
        header: header,
        hostHint: true,
      );
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
