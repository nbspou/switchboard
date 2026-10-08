/*
Polyverse Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Authors:
  Jan Boon <jan.boon@kaetemi.be>
  Claude Opus 5.5 <noreply@anthropic.com>
*/

// Naming payloads larger than a frame go as bulk payloads on their own:
// the naming service and client read `payload`, which a reassembled bulk
// payload fills like an inline one.

import 'dart:typed_data';

import 'package:switchboard/switchboard.dart';
import 'package:test/test.dart';

const mux = MuxOptions(
  goAwayGrace: Duration(milliseconds: 100),
  keepAliveInterval: null,
);

const limit = Duration(seconds: 5);

Switchboard newNode() {
  final node = Switchboard(muxOptions: mux);
  addTearDown(node.close);
  return node;
}

void main() {
  late NamingService service;
  late Uri naming;

  setUp(() async {
    final host = newNode();
    service = NamingService(assignmentHold: Duration.zero);
    addTearDown(service.close);
    host.registerService(Services.naming, service.handler, instance: 1);
    naming = await host.listenMemory();
  });

  MeshNode join(Switchboard node) {
    final mesh = MeshNode.join(node, naming);
    addTearDown(mesh.leave);
    return mesh;
  }

  test('a REGISTER of 40 KiB goes bulk; the record reaches watchers and '
      'LOOKUP whole', () async {
    final publisher = join(newNode());
    final watcher = join(newNode());
    await watcher.synced.timeout(limit);
    // Metadata is at most 4096 bytes; 160 endpoints of 240 bytes make the
    // rest of the 40 KiB.
    final endpoints = [
      for (var i = 0; i < 160; i++)
        Uri.parse('tcp://host-$i-${'x' * 210}.example:${9000 + i}'),
    ];
    final metadata = Uint8List.fromList([
      for (var i = 0; i < maxMetadataLength; i++) i % 251,
    ]);
    final type = Name('big');
    final request = RegisterRequest(
      type,
      endpoints: endpoints,
      metadata: metadata,
    ).encode();
    expect(request.length, greaterThan(40 * 1024));
    final up = watcher.client.events.firstWhere(
      (e) => e.up && e.record.address.type == type,
    );
    final id = await publisher.client
        .register(type, endpoints, metadata: metadata)
        .timeout(limit);
    final record = service.table[ServiceAddress(type, id)];
    expect(record, isNotNull);
    expect(record!.endpoints, endpoints);
    expect(record.metadata, metadata);
    // The UP event to the watcher is as large: a bulk plain message.
    final seen = await up.timeout(limit);
    expect(seen.record.address, ServiceAddress(type, id));
    expect(seen.record.endpoints, endpoints);
    expect(seen.record.metadata, metadata);
    // A LOOKUP item, a bulk stream item.
    final talk = await newNode()
        .openTalkAt(naming, ChannelAddress(type: Services.naming, instance: 1))
        .timeout(limit);
    final lookup = talk.streamRequest(
      Procedures.lookup.toString(),
      WatchRequest(type).encode(),
    );
    final items = await lookup.items.toList().timeout(limit);
    final found = ServiceRecord.decode(items.single.payload);
    expect(items.single.isBulk, isTrue);
    expect(found.endpoints, endpoints);
    expect(found.metadata, metadata);
    await talk.close();
  });

  test('a HOLDING of 20000 slots goes bulk and round-trips', () async {
    final mesh = join(newNode());
    final zone = Name('zone');
    await mesh.client
        .register(zone, [Uri.parse('tcp://127.0.0.1:1')])
        .timeout(limit);
    await mesh.client.defineSlots(zone, count: 20000).timeout(limit);
    final slots = [for (var i = 0; i < 20000; i++) i];
    final discard = await mesh.client
        .declareHolding(zone, slots)
        .timeout(limit);
    expect(discard, isEmpty);
    // Declared again: still held.
    expect(
      await mesh.client.declareHolding(zone, slots).timeout(limit),
      isEmpty,
    );
  });
}
