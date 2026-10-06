import 'package:switchboard/src/address/service_address.dart';
import 'package:switchboard/src/name.dart';
import 'package:switchboard/src/naming/naming_protocol.dart';
import 'package:switchboard/src/switchboard/resolver.dart';
import 'package:test/test.dart';

void main() {
  group('StaticResolver', () {
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
  });
}
