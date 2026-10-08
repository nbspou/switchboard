/*
Polyverse Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Authors:
  Jan Boon <jan.boon@kaetemi.be>
  Claude Opus 5.5 <noreply@anthropic.com>
*/

import 'dart:async';

import '../address/channel_address.dart';
import '../identity/peer_identity.dart';
import '../mux/mux_channel.dart';
import '../mux/mux_connection.dart';
import '../status.dart';
import '../talk/talk_channel.dart';

/// Receives a channel dispatched to a local service, the default service
/// or the catch-all handler.
///
/// The handler owns the channel: it reads [IncomingChannel.channel] (or
/// wraps it with [IncomingChannel.talk]) and closes it when done, or
/// rejects it with [IncomingChannel.reject] after inspecting the address
/// and application payload.
///
/// A handler may be synchronous or asynchronous. If it throws, or the
/// future it returns fails, the error is logged and the channel is closed
/// with `INTERNAL`. The dispatcher never waits for a returned future.
typedef ChannelHandler = FutureOr<void> Function(IncomingChannel channel);

/// A channel opened by a peer, as delivered to a [ChannelHandler].
///
/// Gives the handler the raw mux channel, the parsed address header with
/// the application payload, and the connection it arrived on (on which the
/// handler may open channels back to the peer).
class IncomingChannel {
  /// Wraps [channel]. [address] defaults to the parsed OPEN payload of
  /// [channel] (throwing [ProtocolException] if it is malformed);
  /// [talkOptions] are the defaults for [talk]; [remote] describes the
  /// peer for logs.
  ///
  /// The `Switchboard` creates these; the constructor is public so that
  /// handlers can be driven directly in tests.
  IncomingChannel(
    this.channel, {
    ChannelAddress? address,
    this.talkOptions,
    this.remote,
  }) : address = address ?? ChannelAddress.decode(channel.openPayload);

  /// The mux channel. Its stream buffers subframes until listened to.
  final MuxChannel channel;

  /// The parsed address header and application payload of the OPEN.
  final ChannelAddress address;

  /// A description of the remote side of the connection, for logs: the
  /// remote socket address of an accepted connection or the endpoint URI
  /// of an initiated one; `local` on the accepted side of a connection the
  /// node made to one of its own listeners (`Switchboard.localConnections`).
  /// Null when unknown.
  final String? remote;

  /// Default options for [talk]; null means the [TalkOptions] defaults.
  final TalkOptions? talkOptions;

  TalkChannel? _talk;

  /// The connection the channel arrived on. Channels opened on it reach
  /// the peer's own dispatcher (symmetric dispatch).
  MuxConnection get connection => channel.connection;

  /// Who the peer of [connection] proved to be with `IDENT`, or null
  /// ([MuxConnection.peerIdentity]). A channel proxied through an endpoint
  /// arrives on the proxy's connection, so this is the proxy's identity,
  /// not the client's: clients present their credentials in the
  /// application payload.
  PeerIdentity? get peerIdentity => connection.peerIdentity;

  /// The channel wrapped as a [TalkChannel]. Wraps on the first call and
  /// returns the same instance afterwards; [options] (default: the
  /// Switchboard's talk options) only apply to the first call.
  ///
  /// Do not also read [channel] directly once this has been called.
  TalkChannel talk({TalkOptions? options}) =>
      _talk ??= TalkChannel(channel, options: options ?? talkOptions);

  /// Rejects or ends the channel with CLOSE carrying [status].
  ///
  /// If [talk] was called, the talk channel is closed with [status] so that
  /// its outstanding requests fail too. Application codes (256 and above)
  /// must not appear in a mux CLOSE and are sent as `UNKNOWN`. Does
  /// nothing if the channel is already closing. Completes when the channel
  /// is closed; never throws.
  Future<void> reject(Status status) {
    final wire = status.isApplicationCode
        ? Status.of(
            StatusCode.unknown,
            'application status ${status.code}'
            '${status.reason.isEmpty ? '' : ': ${status.reason}'}',
          )
        : status;
    final talk = _talk;
    if (talk != null) {
      return talk.close(wire);
    }
    return channel.close(wire);
  }

  @override
  String toString() =>
      'IncomingChannel(${channel.id}, $address'
      '${remote != null ? ' from $remote' : ''})';
}
