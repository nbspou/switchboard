/*
Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Author: Jan Boon <jan.boon@kaetemi.be>
*/

import 'dart:async';

import '../address/service_address.dart';
import '../name.dart';
import '../naming/naming_client.dart';
import '../naming/naming_client_io.dart';
import '../naming/naming_resolver.dart';
import '../status.dart';
import '../talk/talk_channel.dart';
import 'incoming_channel.dart';
import 'switchboard.dart';

/// Wires a [Switchboard] into a mesh run by a naming service: the usual
/// setup of a backend service node.
///
/// [MeshNode.join] creates a [NamingClient] that reaches the naming service
/// through the node, installs a [NamingResolver] over it as the node's
/// [Switchboard.resolver], and starts the client. [publish] registers a
/// local service with the naming service and dispatches channels for the
/// instance id it was assigned to the handler. [leave] undoes all of it.
///
/// ```dart
/// final node = Switchboard();
/// await node.listenTcp('10.0.0.5', 9101);
/// final mesh = MeshNode.join(node, Uri.parse('tcp://10.0.0.2:9100'));
/// final id = await mesh.publish(Name('npc'), npcHandler);
/// // ... node.openTalk(ServiceAddress(Name('chat'))) reaches the mesh.
/// await mesh.leave();
/// await node.close();
/// ```
class MeshNode {
  MeshNode._(this.switchboard, this.client, this.resolver);

  /// Joins the mesh whose naming service listens at [namingEndpoint].
  ///
  /// Creates the client with [namingClientFor] (passing [reconnectDelay],
  /// [watchTimeout] and [talkOptions]), sets `switchboard.resolver` to a
  /// [NamingResolver] with [resolveTimeout], replacing any resolver the
  /// node had, and starts the client. Returns at once; the client keeps
  /// connecting in the background until [leave], and [synced] completes
  /// once the table is mirrored.
  factory MeshNode.join(
    Switchboard switchboard,
    Uri namingEndpoint, {
    Duration reconnectDelay = const Duration(seconds: 1),
    Duration? watchTimeout,
    Duration resolveTimeout = const Duration(seconds: 5),
    TalkOptions? talkOptions,
  }) {
    final client = namingClientFor(
      switchboard,
      namingEndpoint,
      reconnectDelay: reconnectDelay,
      watchTimeout: watchTimeout,
      talkOptions: talkOptions,
    );
    final resolver = NamingResolver(client, resolveTimeout: resolveTimeout);
    switchboard.resolver = resolver;
    unawaited(client.start());
    return MeshNode._(switchboard, client, resolver);
  }

  /// The node this joined to the mesh.
  final Switchboard switchboard;

  /// The naming client: registrations and the mirrored table.
  final NamingClient client;

  /// The resolver installed on [switchboard].
  final NamingResolver resolver;

  final Map<ServiceAddress, ChannelHandler> _published = {};
  bool _leaving = false;
  Future<void>? _leaveFuture;

  /// The client's [NamingClient.synced]: completes once the current
  /// session has mirrored the table.
  Future<void> get synced => client.synced;

  /// The addresses of the services published through this object and
  /// dispatched locally, with their current instance ids.
  Iterable<ServiceAddress> get published => List.unmodifiable(_published.keys);

  /// Registers a local service of [type] with the naming service and
  /// returns its instance id.
  ///
  /// [instance] 0 lets the naming service assign the id; a non-zero id is
  /// requested as is. [endpoints] (default: the node's
  /// [Switchboard.listeningEndpoints] at the time of the call, so listen
  /// first, on an address other nodes can reach) are what other nodes
  /// connect to. Once the id is known, [handler] is registered with
  /// [Switchboard.registerService] for exactly `(type, id)`, so channels
  /// addressed to this instance, and channels to any instance of [type]
  /// that reach this node, are dispatched to it. If a reconnect to the
  /// naming service has to assign a different id (the old one was taken),
  /// the local registration moves to the new id.
  ///
  /// Fails like [NamingClient.register], and with
  /// [StatusCode.failedPrecondition] after [leave].
  Future<int> publish(
    Name type,
    ChannelHandler handler, {
    int instance = 0,
    List<Uri>? endpoints,
  }) {
    if (_leaving) {
      return Future.error(
        SwitchboardException.of(StatusCode.failedPrecondition, 'left mesh'),
      );
    }
    ServiceAddress? current;
    return client.register(
      type,
      endpoints ?? switchboard.listeningEndpoints,
      instance: instance,
      onAssigned: (id) {
        if (_leaving) {
          return;
        }
        final previous = current;
        if (previous != null && _published.remove(previous) != null) {
          switchboard.unregisterService(type, instance: previous.instance);
        }
        final address = ServiceAddress(type, id);
        current = address;
        _published[address] = handler;
        switchboard.registerService(type, handler, instance: id);
      },
    );
  }

  /// Unregisters `type/instance`, published through this object, from the
  /// naming service, then stops dispatching it locally.
  ///
  /// Fails like [NamingClient.unregister] ([StatusCode.notFound] if it was
  /// not published here) and with [StatusCode.failedPrecondition] after
  /// [leave]. The local registration is removed even if the naming service
  /// refuses.
  Future<void> unpublish(Name type, int instance) async {
    if (_leaving) {
      throw SwitchboardException.of(StatusCode.failedPrecondition, 'left mesh');
    }
    try {
      await client.unregister(type, instance);
    } finally {
      if (_published.remove(ServiceAddress(type, instance)) != null) {
        switchboard.unregisterService(type, instance: instance);
      }
    }
  }

  /// Leaves the mesh: closes the resolver and with it the client (the
  /// naming service then drops every registration of this node and
  /// publishes `DOWN` for each), stops dispatching the published services
  /// locally, and removes the resolver from [switchboard] if it is still
  /// installed there. Channels already open are unaffected.
  ///
  /// Call this before closing [switchboard]. Calling it again returns the
  /// same future.
  Future<void> leave() => _leaveFuture ??= _leave();

  Future<void> _leave() async {
    _leaving = true;
    if (identical(switchboard.resolver, resolver)) {
      switchboard.resolver = null;
    }
    await resolver.close();
    for (final address in _published.keys) {
      switchboard.unregisterService(address.type, instance: address.instance);
    }
    _published.clear();
  }
}
