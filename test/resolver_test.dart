/*
Polyverse Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Authors:
  Jan Boon <jan.boon@kaetemi.be>
  Claude Fable 5.1 <noreply@anthropic.com>
  Claude Opus 5.5 <noreply@anthropic.com>
  GPT-6 Astra <noreply@anthropic.com>
*/

import 'package:switchboard/src/address/service_address.dart';
import 'package:switchboard/src/name.dart';
import 'package:switchboard/src/naming/naming_protocol.dart';
import 'package:switchboard/src/status.dart';
import 'package:switchboard/src/switchboard/resolver.dart';
import 'package:test/test.dart';

void main() {
  final closed = isA<SwitchboardException>().having(
    (e) => e.code,
    'code',
    StatusCode.failedPrecondition,
  );

  group('StaticResolver', () {
    test('close ends resolution and refuses changes before mutating', () async {
      final type = Name('npc');
      final record = ServiceRecord(ServiceAddress(type, 1));
      final r = StaticResolver([record]);
      r.defineSlots(SlotSpace(type, count: 2));
      r.setSlot(type, 0, const SlotEntry.owned(1, epoch: 1));
      await r.close();
      await r.close();
      await expectLater(r.resolve(type), throwsA(closed));
      await expectLater(r.locateSlot(type, 0), throwsA(closed));
      expect(
        () => r.add(ServiceRecord(ServiceAddress(type, 2))),
        throwsA(closed),
      );
      expect(() => r.remove(record.address), throwsA(closed));
      expect(() => r.defineSlots(SlotSpace(type, count: 3)), throwsA(closed));
      expect(() => r.removeSlots(type), throwsA(closed));
      expect(() => r.setSlot(type, 0, SlotEntry.unassigned), throwsA(closed));
      expect(r.table.values, [record]);
      expect(r.slotTable(type)!.count, 2);
      expect(r.slotOwner(type, 0)!.owner, 1);
    });

    test('close completes while a listener of events is paused', () async {
      final r = StaticResolver();
      final events = r.events.listen((_) {});
      final slots = r.slotEvents.listen((_) {});
      events.pause();
      slots.pause();
      r.add(ServiceRecord(ServiceAddress(Name('npc'), 1)));
      await r.close().timeout(const Duration(seconds: 2));
      await events.cancel();
      await slots.cancel();
    });

    test('resolves by type and emits events', () async {
      final r = StaticResolver([
        ServiceRecord(
          ServiceAddress(Name('npc'), 1),
          endpoints: [Uri.parse('tcp://a:1')],
        ),
        ServiceRecord(
          ServiceAddress(Name('api'), 2),
          endpoints: [Uri.parse('tcp://b:1')],
        ),
      ]);
      await r.ready;
      expect((await r.resolve(Name('npc'))).single.address.instance, 1);
      expect(await r.resolve(Name('none')), isEmpty);
      final events = <ServiceEvent>[];
      final sub = r.events.listen(events.add);
      r.add(
        ServiceRecord(
          ServiceAddress(Name('npc'), 3),
          endpoints: [Uri.parse('tcp://c:1')],
        ),
      );
      r.remove(ServiceAddress(Name('npc'), 1));
      r.remove(ServiceAddress(Name('npc'), 1));
      await Future<void>.delayed(Duration.zero);
      expect(events.map((e) => e.up), [true, false]);
      expect(events.last.record.address, ServiceAddress(Name('npc'), 1));
      expect((await r.resolve(Name('npc'))).single.address.instance, 3);
      await sub.cancel();
      await r.close();
    });
  });

  test('EndpointResolver resolves everything to the endpoint', () async {
    final r = EndpointResolver(Uri.parse('ws://ep/ws'));
    final records = await r.resolve(Name('x'));
    expect(records.single.address, ServiceAddress(Name('x')));
    expect(records.single.endpoints, [Uri.parse('ws://ep/ws')]);
    await r.close();
    await r.close();
    await expectLater(r.resolve(Name('x')), throwsA(closed));
  });
}
