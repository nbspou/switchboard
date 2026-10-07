/*
Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Author: Jan Boon <jan.boon@kaetemi.be>
*/

import '../address/channel_address.dart';
import '../switchboard/switchboard.dart';
import '../talk/talk_channel.dart';
import 'naming_client.dart';
import 'naming_protocol.dart';

/// A [NamingClient] that reaches the naming service at [namingEndpoint]
/// through [switchboard].
///
/// Every (re)connect opens a fresh channel with
/// [Switchboard.openTalkAt] to `_ns` (any instance) at [namingEndpoint],
/// on the node's pooled connection to that endpoint, carrying the payload
/// the node gives that endpoint: `credentialFor(namingEndpoint, null)`
/// when the node has a [Switchboard.credentialFor] hook (a hook that
/// returns null there sends an empty credential to the naming service),
/// else the node's [Switchboard.defaultPayload]. [talkOptions] (default: the node's
/// [Switchboard.talkOptions]) apply to that channel; [reconnectDelay] and
/// [watchTimeout] are passed to [NamingClient.new].
///
/// Nothing happens until [NamingClient.start]. Close the client before
/// closing [switchboard]: once the node is closed every reconnect attempt
/// fails, and the client keeps retrying until it is closed.
NamingClient namingClientFor(
  Switchboard switchboard,
  Uri namingEndpoint, {
  Duration reconnectDelay = const Duration(seconds: 1),
  Duration? watchTimeout,
  TalkOptions? talkOptions,
}) => NamingClient(
  () => switchboard.openTalkAt(
    namingEndpoint,
    ChannelAddress(type: Services.naming),
    options: talkOptions,
  ),
  reconnectDelay: reconnectDelay,
  watchTimeout: watchTimeout,
);
