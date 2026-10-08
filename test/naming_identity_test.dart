/*
Polyverse Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Authors:
  Jan Boon <jan.boon@kaetemi.be>
  Claude Opus 5.5 <noreply@anthropic.com>
*/

// The naming service and identity (wiki page "Polyverse Switchboard Identity and
// Credentials", stage B): scope enforcement per `_ns` channel (connection
// identity, or a credential in the open payload), RENEW and the renewal of
// a MeshNode's credential (with fake time), the end of a channel whose
// credential expires, slot spaces defined again after a restart, and
// CONNECT brokering (a late dial-back included), over mem:// nodes.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:switchboard/switchboard.dart';
import 'package:test/test.dart';

const fast = MuxOptions(
  goAwayGrace: Duration(milliseconds: 100),
  keepAliveInterval: null,
);
const talk = TalkOptions(
  requestTimeout: Duration(seconds: 2),
  replyTimeout: Duration(seconds: 1),
);
const limit = Duration(seconds: 5);

final naming = Services.naming;
final workerType = Name('worker-g');
final npc = Name('npc');

final authoritySeed = Uint8List.fromList(List.generate(32, (i) => 11 * i));
final meshKey = Uint8List.fromList(List.generate(32, (i) => 200 - i));

late CredentialIssuer authority;
late CredentialIssuer hmac;
late HolderKey key;

final workerScopes = [Scope.of(Right.register, 'worker-*')];
final consumerScopes = [
  Scope.of(Right.watch, '*'),
  Scope.of(Right.open, 'worker-*'),
  Scope.of(Right.broker, 'worker-*'),
];
final adminScopes = [Scope.of(Right.admin, '*')];

Future<Credential> issue(
  String identity,
  List<Scope> scopes, {
  Duration lifetime = const Duration(hours: 8),
  bool bearer = false,
}) => (bearer ? hmac : authority).issue(
  kind: CredentialKind.node,
  identity: identity,
  scopes: scopes,
  holderKey: bearer ? null : key.publicKey,
  lifetime: lifetime,
);

Future<CredentialVerifier> verifier() async {
  final v = CredentialVerifier();
  await v.addIssuer(authority);
  await v.addIssuer(hmac);
  return v;
}

Uint8List bytes(String text) => Uint8List.fromList(utf8.encode(text));

String text(Uint8List data) => utf8.decode(data);

Matcher throwsCode(StatusCode code) =>
    throwsA(isA<SwitchboardException>().having((e) => e.code, 'code', code));

Matcher hasCode(StatusCode code) =>
    isA<Status>().having((s) => s.known, 'known', code);

Future<void> until(bool Function() condition) async {
  final deadline = DateTime.now().add(limit);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition not met within $limit');
    }
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

/// A node, closed after the test (unless [close] is false, for fake time,
/// where the test closes it).
Future<Switchboard> node({
  Credential? credential,
  bool verify = true,
  Duration connectTimeout = const Duration(seconds: 10),
  bool close = true,
}) async {
  final s = Switchboard(
    muxOptions: fast,
    talkOptions: talk,
    credential: credential,
    holderKey: credential == null || credential.isBearer ? null : key,
    verifier: verify ? await verifier() : null,
    connectTimeout: connectTimeout,
  );
  if (close) {
    addTearDown(s.close);
  }
  return s;
}

/// A naming service hosted on a node listening at [uri].
class Mesh {
  Mesh._(this.host, this.service, this.uri);

  static Future<Mesh> start({
    bool requireCredential = true,
    bool withIssuer = true,
    CredentialVerifier? payloadVerifier,
    bool Function(Credential credential)? renewable,
    Duration brokerTimeout = const Duration(seconds: 5),
    bool close = true,
    String? name,
  }) async {
    final host = await node(close: close);
    final service = NamingService(
      assignmentHold: Duration.zero,
      holdingSettle: Duration.zero,
      verifier: payloadVerifier ?? await verifier(),
      requireCredential: requireCredential,
      issuer: withIssuer ? authority : null,
      renewable: renewable,
      brokerTimeout: brokerTimeout,
    );
    if (close) {
      addTearDown(service.close);
    }
    host.registerService(naming, service.handler, instance: 1);
    // The naming service checks identities itself, the payload's too.
    final uri = await host.listenMemory(
      policy: ChannelPolicies.allowTypes({naming}),
      name: name,
    );
    return Mesh._(host, service, uri);
  }

  final Switchboard host;
  final NamingService service;
  final Uri uri;

  Future<void> close() async {
    await service.close();
    await host.close();
  }
}

/// A raw `_ns` channel from [client] to [mesh], with [payload] as the
/// application payload of its OPEN.
Future<TalkChannel> channelTo(
  Switchboard client,
  Mesh mesh, {
  Uint8List? payload,
}) async {
  final channel = await client.openTalkAt(
    mesh.uri,
    ChannelAddress(type: naming, payload: payload ?? Uint8List(0)),
  );
  addTearDown(channel.close);
  return channel;
}

/// The status code a request answered with, or null for success.
Future<StatusCode?> call(
  TalkChannel channel,
  Name procedure,
  Uint8List payload, {
  bool stream = false,
}) async {
  try {
    if (stream) {
      await channel
          .streamRequest(procedure.toString(), payload, name: procedure)
          .done
          .timeout(limit);
    } else {
      await channel
          .request(procedure.toString(), payload, name: procedure)
          .timeout(limit);
    }
    return null;
  } on SwitchboardException catch (e) {
    return e.code;
  }
}

Uint8List registerPayload(Name type, {int instance = 0}) =>
    RegisterRequest(type, requestedInstance: instance).encode();

/// Every request a channel can make about [type] (CONNECT to [instance],
/// default a missing one), and the code it gets.
Future<Map<String, StatusCode?>> survey(
  TalkChannel channel,
  Name type, {
  int instance = 0,
}) async => {
  'WATCH *': await call(channel, Procedures.watch, Uint8List(0)),
  'WATCH type': await call(
    channel,
    Procedures.watch,
    WatchRequest(type).encode(),
  ),
  'LOOKUP': await call(
    channel,
    Procedures.lookup,
    WatchRequest(type).encode(),
    stream: true,
  ),
  'SLOTS': await call(
    channel,
    Procedures.slots,
    SlotsRequest(SlotSpace(type, count: 4), capacity: 0).encode(),
  ),
  'CLAIM': await call(
    channel,
    Procedures.claim,
    ClaimRequest(type, 0).encode(),
  ),
  'LOCATE': await call(
    channel,
    Procedures.locate,
    LocateRequest(type, 0).encode(),
  ),
  'MIGRATE': await call(
    channel,
    Procedures.migrate,
    MigrateRequest(type, 0).encode(),
    stream: true,
  ),
  'CONNECT': await call(
    channel,
    Procedures.connect,
    ConnectRequest(
      type,
      instance == 0 ? 0xABC : instance,
      Uri.parse('mem://nowhere'),
    ).encode(),
  ),
  // Last: a registration would make the claim send ASSIGN to this channel.
  'REGISTER': await call(channel, Procedures.register, registerPayload(type)),
};

const ok = null;
const denied = StatusCode.permissionDenied;

/// A slot lifecycle with nothing to load or serve.
class Idle extends SlotLifecycle {
  @override
  Future<AssignResult> load(
    int slot, {
    required int epoch,
    required int holder,
    required bool shared,
    SlotRequestContext? context,
  }) async => AssignResult.notHolding;

  @override
  void serve(IncomingChannel channel, int slot) {}
}

void main() {
  setUpAll(() async {
    authority = await CredentialIssuer.ed25519FromSeed(
      Name('auth1'),
      authoritySeed,
    );
    hmac = CredentialIssuer.hmac(Name('mesh1'), meshKey);
    key = await HolderKey.generate();
  });

  group('scopes', () {
    test('a worker credential can register its type (and define its slot '
        'space) and nothing else', () async {
      final mesh = await Mesh.start();
      final worker = await node(
        credential: await issue('worker-a1', workerScopes),
      );
      final c = await channelTo(worker, mesh);
      expect(await survey(c, workerType), {
        'REGISTER': ok,
        'WATCH *': denied,
        'WATCH type': denied,
        'LOOKUP': denied,
        'SLOTS': ok,
        'CLAIM': denied,
        'LOCATE': denied,
        'MIGRATE': denied,
        'CONNECT': denied,
      });
      expect(await call(c, Procedures.register, registerPayload(npc)), denied);
      expect(
        await call(
          c,
          Procedures.slots,
          SlotsRequest(SlotSpace(npc, count: 4), capacity: 0).encode(),
        ),
        denied,
      );
      // Its own record it may take back; not another channel's.
      final id = mesh.service.table.keys.single.instance;
      expect(
        await call(
          c,
          Procedures.unregister,
          UnregisterRequest(workerType, id).encode(),
        ),
        ok,
      );
      expect(mesh.service.table, isEmpty);
    });

    test('a consumer credential can watch and broker', () async {
      final mesh = await Mesh.start();
      final consumer = await node(
        credential: await issue('consumer-1', consumerScopes),
      );
      final c = await channelTo(consumer, mesh);
      expect(await survey(c, workerType), {
        'REGISTER': denied,
        'WATCH *': ok,
        'WATCH type': ok,
        'LOOKUP': ok,
        'SLOTS': denied,
        // No slot space: past the scope check, NOT_FOUND.
        'CLAIM': denied,
        'LOCATE': StatusCode.notFound,
        'MIGRATE': denied,
        // No such record: past the scope check.
        'CONNECT': StatusCode.notFound,
      });
      expect(
        await call(
          c,
          Procedures.connect,
          ConnectRequest(npc, 1, Uri.parse('mem://x')).encode(),
        ),
        denied,
      );
    });

    test('admin can do everything', () async {
      final mesh = await Mesh.start();
      final admin = await node(credential: await issue('root', adminScopes));
      final c = await channelTo(admin, mesh);
      expect(await survey(c, workerType), {
        'REGISTER': ok,
        'WATCH *': ok,
        'WATCH type': ok,
        'LOOKUP': ok,
        'SLOTS': ok,
        // Past the scope checks: a claim needs a registration with
        // capacity, a migration an owned slot, CONNECT a record.
        'CLAIM': StatusCode.failedPrecondition,
        'LOCATE': ok,
        'MIGRATE': StatusCode.failedPrecondition,
        'CONNECT': StatusCode.notFound,
      });
    });

    test('a slot space is defined, redefined while blank and confirmed '
        'with claim or register, never with watch alone', () async {
      final mesh = await Mesh.start();
      final watcher = await node(
        credential: await issue('consumer-3', [Scope.of(Right.watch, '*')]),
      );
      final worker = await node(
        credential: await issue('worker-a1', [
          ...workerScopes,
          Scope.of(Right.claim, 'worker-*'),
        ]),
      );
      final registrar = await node(
        credential: await issue('worker-b2', workerScopes),
      );
      final claimer = await node(
        credential: await issue('worker-c3', [
          Scope.of(Right.claim, 'worker-*'),
        ]),
      );
      final admin = await node(credential: await issue('root', adminScopes));
      final v = await channelTo(watcher, mesh);
      final w = await channelTo(worker, mesh);
      final r = await channelTo(registrar, mesh);
      final c = await channelTo(claimer, mesh);
      final a = await channelTo(admin, mesh);
      final space = SlotSpace(workerType, count: 4);
      final wider = SlotSpace(workerType, count: 8);
      Uint8List slots(SlotSpace space) =>
          SlotsRequest(space, capacity: 0).encode();
      SlotSpace? defined() => mesh.service.slotTable(workerType)?.space;
      // watch defines nothing; register alone defines (what an instance
      // does after a restart of the naming service).
      expect(await call(v, Procedures.slots, slots(space)), denied);
      expect(defined(), isNull);
      expect(await call(r, Procedures.slots, slots(space)), ok);
      expect(defined(), space);
      // Confirmed with claim or register, not with watch.
      expect(await call(c, Procedures.slots, slots(space)), ok);
      expect(await call(v, Procedures.slots, slots(space)), denied);
      // While blank, redefined under the same rule.
      expect(await call(v, Procedures.slots, slots(wider)), denied);
      expect(defined(), space);
      expect(await call(c, Procedures.slots, slots(wider)), ok);
      expect(defined(), wider);
      expect(await call(r, Procedures.slots, slots(space)), ok);
      expect(defined(), space);
      // A held slot ends the blank state: a redefinition is refused for
      // everyone, admin included; HOLDING still needs claim.
      expect(
        await call(w, Procedures.register, registerPayload(workerType)),
        ok,
      );
      expect(await call(w, Procedures.slots, slots(space)), ok);
      expect(
        await call(
          w,
          Procedures.holding,
          HoldingRequest(workerType, [0]).encode(),
        ),
        ok,
      );
      expect(
        await call(
          r,
          Procedures.holding,
          HoldingRequest(workerType, [1]).encode(),
        ),
        denied,
      );
      for (final channel in [w, a]) {
        expect(
          await call(channel, Procedures.slots, slots(wider)),
          StatusCode.failedPrecondition,
        );
      }
      expect(await call(a, Procedures.slots, slots(space)), ok);
      expect(defined(), space);
    });

    test('after a naming service restart, an instance defines its slot '
        'space again with its own credential', () async {
      const name = 'ns-restarting';
      final mesh = await Mesh.start(name: name);
      final worker = await node(
        credential: await issue('worker-a1', [
          ...workerScopes,
          Scope.of(Right.claim, 'worker-*'),
        ]),
      );
      final joined = MeshNode.join(
        worker,
        mesh.uri,
        watch: false,
        renewCredential: false,
        reconnectDelay: const Duration(milliseconds: 20),
      );
      addTearDown(joined.leave);
      final space = SlotSpace(workerType, count: 4, mode: SlotMode.static);
      await joined
          .publishSharded(
            workerType,
            Idle(),
            count: space.count,
            mode: space.mode,
            capacity: 0,
            endpoints: const [],
          )
          .timeout(limit);
      await joined.claimSlot(workerType, 2).timeout(limit);
      final id = mesh.service.table.keys.single.instance;
      expect(mesh.service.slotTable(workerType)![2].owner, id);
      await mesh.close();
      // Nobody with admin around: the instance's own SLOTS defines the
      // space on the new naming service, and its slot is claimed back.
      final restarted = await Mesh.start(name: name);
      expect(restarted.uri, mesh.uri);
      await until(
        () => restarted.service.slotTable(workerType)?[2].owner == id,
      );
      expect(restarted.service.slotTable(workerType)!.space, space);
      expect(
        restarted.service.table.keys.single,
        ServiceAddress(workerType, id),
      );
      await joined.leave().timeout(limit);
    });

    test('the connection identity takes precedence over a credential in '
        'the open payload', () async {
      final mesh = await Mesh.start();
      // Identified by IDENT as "weak", which has no scope; its channel's
      // payload carries a valid bearer credential that grants everything.
      final weak = await node(credential: await issue('weak', const []));
      final wide = await issue('wide', adminScopes, bearer: true);
      final c = await channelTo(weak, mesh, payload: wide.encode());
      final results = await survey(c, workerType);
      expect(results.values.toSet(), {denied});
      expect(mesh.service.table, isEmpty);
      expect(mesh.service.slotTable(workerType), isNull);
      // The same payload identifies a channel whose connection has no
      // identity.
      final anonymous = await node(verify: false);
      final a = await channelTo(anonymous, mesh, payload: wide.encode());
      expect(await call(a, Procedures.watch, Uint8List(0)), ok);
      expect(
        await call(a, Procedures.register, registerPayload(workerType)),
        ok,
      );
    });

    test('without a credential: UNAUTHENTICATED when one is required, '
        'everything otherwise', () async {
      final strict = await Mesh.start();
      final lenient = await Mesh.start(requireCredential: false);
      final anonymous = await node();
      final s = await channelTo(anonymous, strict);
      final results = await survey(s, workerType);
      expect(results.values.toSet(), {StatusCode.unauthenticated});
      expect(await call(s, Procedures.renew, Uint8List(0)), results['WATCH *']);
      final l = await channelTo(anonymous, lenient);
      expect(
        await call(l, Procedures.register, registerPayload(workerType)),
        ok,
      );
      expect(await call(l, Procedures.watch, Uint8List(0)), ok);
      // An identified channel is held to its scopes even then.
      final worker = await node(
        credential: await issue('worker-a1', workerScopes),
      );
      final w = await channelTo(worker, lenient);
      expect(await call(w, Procedures.watch, Uint8List(0)), denied);
    });

    test('a bearer credential in the open payload identifies a channel; a '
        'holder-key one does not', () async {
      final mesh = await Mesh.start();
      // The client node has no credential of its own: no IDENT.
      final client = await node(verify: false);
      final bearer = await issue('consumer-2', consumerScopes, bearer: true);
      final c = await channelTo(client, mesh, payload: bearer.encode());
      expect(await call(c, Procedures.watch, Uint8List(0)), ok);
      expect(
        await call(c, Procedures.register, registerPayload(workerType)),
        denied,
      );
      final held = await issue('consumer-3', consumerScopes);
      final h = await channelTo(client, mesh, payload: held.encode());
      expect(
        await call(h, Procedures.watch, Uint8List(0)),
        StatusCode.unauthenticated,
      );
      final junk = await channelTo(client, mesh, payload: bytes('secret'));
      expect(
        await call(junk, Procedures.watch, Uint8List(0)),
        StatusCode.unauthenticated,
      );
    });

    test('a node whose IDENT names the naming service is accepted by a host '
        'that requires it; MeshNode works under the scopes', () async {
      final host = Switchboard(
        muxOptions: fast.copyWith(requireNamedIdent: true),
        talkOptions: talk,
        credential: await issue('ns', const []),
        holderKey: key,
        verifier: await verifier(),
      );
      addTearDown(host.close);
      final service = NamingService(
        assignmentHold: Duration.zero,
        verifier: await verifier(),
        requireCredential: true,
      );
      addTearDown(service.close);
      host.registerService(naming, service.handler, instance: 1);
      final uri = await host.listenMemory(policy: ChannelPolicies.scoped());
      final worker = Switchboard(
        muxOptions: fast,
        talkOptions: talk,
        credential: await issue('worker-a1', workerScopes),
        holderKey: key,
        expectedIdentityFor: (endpoint, record) =>
            endpoint == uri ? 'ns' : null,
      );
      addTearDown(worker.close);
      final mesh = MeshNode.join(
        worker,
        uri,
        renewCredential: false,
        watch: false,
      );
      addTearDown(mesh.leave);
      final id = await mesh
          .publish(workerType, (incoming) {}, endpoints: const [])
          .timeout(limit);
      expect(service.table.keys.single, ServiceAddress(workerType, id));
      expect(mesh.client.isSynced, isFalse);
      // A client that watches anyway is refused once, and keeps its
      // channel and its registrations.
      final watching = MeshNode.join(worker, uri, renewCredential: false);
      addTearDown(watching.leave);
      await watching
          .publish(Name('worker-h'), (incoming) {}, endpoints: const [])
          .timeout(limit);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(watching.client.isConnected, isTrue);
      expect(service.table, hasLength(2));
      // Another node that names nobody is refused by the host.
      final unnamed = await node(
        credential: await issue('consumer-1', consumerScopes),
      );
      await expectLater(
        unnamed.connect(uri),
        throwsCode(StatusCode.unauthenticated),
      );
    });
  });

  group('expiry and RENEW', () {
    test(
      'connection expiry is enforced while the OPEN credential verifies',
      () {
        fakeAsync((async) {
          final checked = Completer<void>();
          late Mesh mesh;
          late Switchboard worker;
          Status? closed;
          Future<void> setUp() async {
            mesh = await Mesh.start(
              close: false,
              payloadVerifier: _DelayedVerifier(
                await verifier(),
                checked.future,
              ),
            );
            worker = await node(
              credential: await issue(
                'worker-a1',
                workerScopes,
                lifetime: const Duration(hours: 1),
              ),
              close: false,
            );
            final payload = await issue('wide', adminScopes, bearer: true);
            final channel = await worker.openTalkAt(
              mesh.uri,
              ChannelAddress(type: naming, payload: payload.encode()),
            );
            unawaited(channel.done.then((status) => closed = status));
          }

          unawaited(setUp());
          async.elapse(const Duration(seconds: 1));
          expect(mesh.service.channelCount, 1);
          async.elapse(const Duration(hours: 1));
          expect(closed, hasCode(StatusCode.unauthenticated));
          expect(mesh.service.channelCount, 0);
          checked.complete();
          async.flushMicrotasks();
          expect(mesh.service.channelCount, 0);
          unawaited(worker.close());
          unawaited(mesh.close());
          async.elapse(const Duration(seconds: 30));
          expect(async.pendingTimers, isEmpty);
        });
      },
    );

    test('connection expiry cannot fall back to the OPEN credential', () {
      fakeAsync((async) {
        late Mesh mesh;
        late Switchboard worker;
        late TalkChannel channel;
        final ended = <Status>[];
        final changes = <ServiceEvent>[];
        Status? closed;
        Future<void> setUp() async {
          mesh = await Mesh.start(close: false);
          mesh.service.events.listen(changes.add);
          worker = await node(
            credential: await issue(
              'worker-a1',
              workerScopes,
              lifetime: const Duration(hours: 1),
            ),
            close: false,
          );
          worker.connections.listen((c) => c.peerGoAwayStatus.then(ended.add));
          final payload = await issue('wide', adminScopes, bearer: true);
          channel = await worker.openTalkAt(
            mesh.uri,
            ChannelAddress(type: naming, payload: payload.encode()),
          );
          unawaited(channel.done.then((status) => closed = status));
          await channel.request('REGISTER', registerPayload(workerType));
        }

        unawaited(setUp());
        async.elapse(const Duration(seconds: 1));
        expect(mesh.service.table, hasLength(1));
        async.elapse(const Duration(hours: 1));
        expect(closed, hasCode(StatusCode.unauthenticated));
        expect(ended, [hasCode(StatusCode.unauthenticated)]);
        expect(mesh.service.table, isEmpty);
        expect(changes.map((e) => e.up), [true, false]);
        unawaited(worker.close());
        unawaited(mesh.close());
        async.elapse(const Duration(seconds: 30));
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('a replacement IDENT updates expiry without another request', () {
      fakeAsync((async) {
        late Mesh mesh;
        late Switchboard worker;
        late TalkChannel channel;
        Status? closed;
        Future<void> setUp() async {
          mesh = await Mesh.start(close: false);
          worker = await node(
            credential: await issue('worker-a1', workerScopes),
            close: false,
          );
          channel = await worker.openTalkAt(
            mesh.uri,
            ChannelAddress(type: naming),
          );
          unawaited(channel.done.then((status) => closed = status));
          await channel.request('REGISTER', registerPayload(workerType));
          await worker.updateCredential(
            await issue(
              'worker-a1',
              workerScopes,
              lifetime: const Duration(hours: 1),
            ),
          );
        }

        unawaited(setUp());
        async.elapse(const Duration(seconds: 1));
        expect(mesh.service.table, hasLength(1));
        async.elapse(const Duration(hours: 1));
        expect(closed, hasCode(StatusCode.unauthenticated));
        expect(mesh.service.table, isEmpty);
        unawaited(worker.close());
        unawaited(mesh.close());
        async.elapse(const Duration(seconds: 30));
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('RENEW re-issues the channel\'s credential', () async {
      final mesh = await Mesh.start();
      final original = await issue(
        'worker-a1',
        workerScopes,
        lifetime: const Duration(hours: 1),
      );
      final worker = await node(credential: original);
      final client = namingClientFor(worker, mesh.uri);
      addTearDown(client.close);
      unawaited(client.start());
      await until(() => client.isConnected);
      for (final current in [null, original]) {
        final renewed = await client.renew(current: current).timeout(limit);
        expect(renewed.identity, 'worker-a1');
        expect(renewed.scopes, original.scopes);
        expect(renewed.holderKey, original.holderKey);
        expect(renewed.kind, original.kind);
        expect(renewed.expiresAt - renewed.issuedAt, 3600);
        expect(renewed.issuedAt, greaterThanOrEqualTo(original.issuedAt));
      }
      // Another identity's credential is refused, an invalid one too.
      await expectLater(
        client.renew(current: await issue('worker-b2', workerScopes)),
        throwsCode(StatusCode.permissionDenied),
      );
      final forged = Uint8List.fromList(original.encode())..last ^= 1;
      await expectLater(
        client.renew(current: Credential.decode(forged)),
        throwsCode(StatusCode.unauthenticated),
      );
      // A naming service without an issuer does not renew.
      final plain = await Mesh.start(withIssuer: false);
      final other = namingClientFor(worker, plain.uri);
      addTearDown(other.close);
      unawaited(other.start());
      await until(() => other.isConnected);
      await expectLater(other.renew(), throwsCode(StatusCode.unimplemented));
      // Not connected.
      final idle = namingClientFor(worker, mesh.uri);
      addTearDown(idle.close);
      await expectLater(idle.renew(), throwsCode(StatusCode.unavailable));
    });

    test('a payload credential is renewed in place; one that is not ends '
        'its channel, and only its channel, at its expiry', () {
      fakeAsync((async) {
        late Mesh mesh;
        late Switchboard client;
        late TalkChannel renewing;
        late TalkChannel lapsing;
        late Credential bearer;
        Credential? renewed;
        Status? lapsed;
        Future<void> setUp() async {
          mesh = await Mesh.start(close: false);
          client = await node(verify: false, close: false);
          bearer = await issue(
            'consumer-2',
            consumerScopes,
            bearer: true,
            lifetime: const Duration(hours: 1),
          );
          Future<TalkChannel> open() => client.openTalkAt(
            mesh.uri,
            ChannelAddress(type: naming, payload: bearer.encode()),
          );
          renewing = await open();
          lapsing = await open();
          unawaited(lapsing.done.then((status) => lapsed = status));
          await lapsing.request('WATCH', Uint8List(0));
        }

        unawaited(setUp());
        async.elapse(const Duration(minutes: 50));
        renewing
            .request('RENEW', Uint8List(0), name: Procedures.renew)
            .then((answer) => renewed = Credential.decode(answer.payload))
            .ignore();
        async.elapse(const Duration(seconds: 1));
        expect(renewed?.identity, 'consumer-2');
        expect(renewed?.isBearer, isTrue);
        expect(renewed?.scopes, bearer.scopes);
        expect(renewed!.expiresAt, greaterThan(bearer.expiresAt));
        // Past the first expiry: the channel that renewed goes on, the
        // other is closed; the connection carries on.
        async.elapse(const Duration(minutes: 11));
        expect(lapsed, hasCode(StatusCode.unauthenticated));
        StatusCode? watched = StatusCode.unknown;
        renewing
            .request('WATCH', Uint8List(0))
            .then<void>((_) => watched = null)
            .catchError(
              (Object e) => watched = (e as SwitchboardException).code,
            )
            .ignore();
        async.elapse(const Duration(seconds: 1));
        expect(watched, isNull);
        expect(renewing.isOpen, isTrue);
        unawaited(renewing.close());
        unawaited(client.close());
        unawaited(mesh.close());
        async.elapse(const Duration(seconds: 30));
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('RENEW of another credential of the same identity does not become '
        'the payload credential', () async {
      final mesh = await Mesh.start();
      final client = await node(verify: false);
      final bearer = await issue('x', workerScopes, bearer: true);
      // Same identity and kind, wider, and bound to a holder key: it
      // identifies only by IDENT, and proves nothing in a payload.
      final held = await issue('x', adminScopes);
      final c = await channelTo(client, mesh, payload: bearer.encode());
      expect(await call(c, Procedures.watch, Uint8List(0)), denied);
      final answer = await c.request(
        'RENEW',
        held.encode(),
        name: Procedures.renew,
      );
      final renewed = Credential.decode(answer.payload);
      expect(renewed.holderKey, held.holderKey);
      expect(renewed.scopes, held.scopes);
      // The channel is still identified by its own bearer credential.
      expect(await call(c, Procedures.watch, Uint8List(0)), denied);
      expect(
        await call(c, Procedures.register, registerPayload(workerType)),
        ok,
      );
    });

    test('MeshNode renews at two thirds of the lifetime; a credential that '
        'is not renewed ends the session at its expiry', () {
      fakeAsync((async) {
        var revoked = false;
        late Mesh mesh;
        late Switchboard worker;
        late MeshNode joined;
        late Credential original;
        final ended = <Status>[];
        Future<void> setUp() async {
          mesh = await Mesh.start(
            close: false,
            renewable: (credential) => !revoked,
          );
          original = await issue(
            'worker-a1',
            workerScopes,
            lifetime: const Duration(hours: 3),
          );
          worker = await node(credential: original, close: false);
          worker.connections.listen((c) => c.peerGoAwayStatus.then(ended.add));
          joined = MeshNode.join(worker, mesh.uri, watch: false);
          await joined.publish(workerType, (incoming) {}, endpoints: const []);
        }

        unawaited(setUp());
        async.elapse(const Duration(seconds: 1));
        expect(mesh.service.table, hasLength(1));
        expect(
          joined.nextRenewalAt,
          DateTime.fromMillisecondsSinceEpoch(
            (original.issuedAt + 7200) * 1000,
            isUtc: true,
          ),
        );
        // Two hours in: renewed, and presented on the naming connection.
        async.elapse(const Duration(hours: 2));
        final renewed = worker.credential!;
        expect(renewed.expiresAt, greaterThan(original.expiresAt));
        expect(renewed.identity, original.identity);
        // Past the first expiry: still registered.
        async.elapse(const Duration(hours: 1, minutes: 30));
        expect(mesh.service.table, hasLength(1));
        expect(ended, isEmpty);
        // Revoked: the next renewals fail (from four hours in), and the
        // session ends at the expiry, five hours in.
        revoked = true;
        async.elapse(const Duration(hours: 1));
        expect(worker.credential, same(renewed));
        expect(mesh.service.table, hasLength(1));
        expect(ended, isEmpty);
        async.elapse(const Duration(minutes: 31));
        expect(mesh.service.table, isEmpty);
        // The naming connection is sent GOAWAY; so is every new one, since
        // the credential has expired.
        expect(ended, isNotEmpty);
        expect(ended, everyElement(hasCode(StatusCode.unauthenticated)));
        unawaited(joined.leave());
        unawaited(worker.close());
        unawaited(mesh.close());
        async.elapse(const Duration(seconds: 30));
        expect(async.pendingTimers, isEmpty);
      });
    });
  });

  group('CONNECT', () {
    /// A mesh, an outbound-only worker registered without endpoints, and a
    /// consumer listening with a scoped policy.
    Future<(Mesh, Switchboard, MeshNode, int, Switchboard, MeshNode)> setUp({
      List<Scope>? consumer,
    }) async {
      final mesh = await Mesh.start();
      final worker = await node(
        credential: await issue('worker-a1', workerScopes),
      );
      final workerMesh = MeshNode.join(worker, mesh.uri, watch: false);
      addTearDown(workerMesh.leave);
      final id = await workerMesh
          .publish(workerType, (incoming) {
            final channel = incoming.talk();
            channel.messages.listen((message) {
              if (message.expectsReply) {
                message.reply(
                  bytes(
                    '${text(message.payload)} by '
                    '${incoming.peerIdentity?.identity}',
                  ),
                );
              }
            });
          }, endpoints: const [])
          .timeout(limit);
      final c = await node(
        credential: await issue('consumer-1', consumer ?? consumerScopes),
      );
      await c.listenMemory(policy: ChannelPolicies.scoped());
      final consumerMesh = MeshNode.join(c, mesh.uri);
      addTearDown(consumerMesh.leave);
      await consumerMesh.synced.timeout(limit);
      return (mesh, worker, workerMesh, id, c, consumerMesh);
    }

    test('the consumer opens a channel to an outbound-only worker', () async {
      final (_, worker, workerMesh, id, consumer, _) = await setUp();
      final address = ServiceAddress(workerType, id);
      final channel = await consumer.openTalk(address).timeout(limit);
      final reply = await channel.request('RUN', bytes('job')).timeout(limit);
      expect(text(reply.payload), 'job by consumer-1');
      // The connection is pooled per instance.
      final again = await consumer.openTalk(address).timeout(limit);
      expect(
        text((await again.request('RUN', bytes('two'))).payload),
        'two by consumer-1',
      );
      expect(workerMesh.brokeredConnections, hasLength(1));
      final brokered = workerMesh.brokeredConnections.single;
      expect(brokered.peerIdentity?.identity, 'consumer-1');
      expect(brokered.peerIdentity?.receiver, 'worker-a1');
      // The worker may open nothing on the consumer.
      final push = worker.openChannelOn(
        brokered,
        ChannelAddress(type: workerType),
      );
      expect(await push.done.timeout(limit), hasCode(denied));
    });

    test('refusals', () async {
      final (mesh, _, _, id, _, _) = await setUp();
      final consumer = await node(
        credential: await issue('consumer-2', consumerScopes),
      );
      await consumer.listenMemory();
      final client = namingClientFor(consumer, mesh.uri);
      addTearDown(client.close);
      unawaited(client.start());
      await until(() => client.isConnected);
      final here = consumer.listeningEndpoints.single;
      // No such instance, or not of that type.
      await expectLater(
        client.connectTo(workerType, id + 100, here, Uint8List(4)),
        throwsCode(StatusCode.notFound),
      );
      await expectLater(
        client.connectTo(Name('worker-x'), id, here, Uint8List(4)),
        throwsCode(StatusCode.notFound),
      );
      // A record with endpoints needs no brokering.
      final lister = await node(
        credential: await issue('worker-b2', workerScopes),
      );
      final listerMesh = MeshNode.join(lister, mesh.uri, watch: false);
      addTearDown(listerMesh.leave);
      final listed = await listerMesh.publish(
        workerType,
        (incoming) {},
        endpoints: [Uri.parse('tcp://10.0.0.9:1')],
      );
      await expectLater(
        client.connectTo(workerType, listed, here, Uint8List(4)),
        throwsCode(StatusCode.notFound),
      );
      // The worker cannot reach the endpoint.
      await expectLater(
        client.connectTo(
          workerType,
          id,
          Uri.parse('mem://nobody-listens-here'),
          Uint8List(4),
        ),
        throwsCode(StatusCode.unavailable),
      );
      // Malformed.
      await expectLater(
        client.connectTo(workerType, id, here, Uint8List(65)),
        throwsArgumentError,
      );
      // Without the broker right.
      final watcher = await node(
        credential: await issue('consumer-3', [Scope.of(Right.watch, '*')]),
      );
      final w = namingClientFor(watcher, mesh.uri);
      addTearDown(w.close);
      unawaited(w.start());
      await until(() => w.isConnected);
      await expectLater(
        w.connectTo(workerType, id, here, Uint8List(4)),
        throwsCode(denied),
      );
    });

    test('a registrant without an identity cannot be brokered', () async {
      final mesh = await Mesh.start(requireCredential: false);
      final anonymous = await node();
      final c = await channelTo(anonymous, mesh);
      expect(
        await call(c, Procedures.register, registerPayload(workerType)),
        ok,
      );
      final id = mesh.service.table.keys.single.instance;
      expect(
        await call(
          c,
          Procedures.connect,
          ConnectRequest(workerType, id, Uri.parse('mem://x')).encode(),
        ),
        StatusCode.failedPrecondition,
      );
    });

    test('an instance that does not dial back: UNAVAILABLE in time', () async {
      final mesh = await Mesh.start(
        brokerTimeout: const Duration(milliseconds: 200),
      );
      // A registrant that never answers CONNECT.
      final silent = await node(
        credential: await issue('worker-a1', workerScopes),
      );
      final r = await channelTo(silent, mesh);
      r.messages.listen((_) {});
      expect(
        await call(r, Procedures.register, registerPayload(workerType)),
        ok,
      );
      final id = mesh.service.table.keys.single.instance;
      final consumer = await node(
        credential: await issue('consumer-1', consumerScopes),
        connectTimeout: const Duration(seconds: 2),
      );
      await consumer.listenMemory();
      final joined = MeshNode.join(consumer, mesh.uri);
      addTearDown(joined.leave);
      await joined.synced.timeout(limit);
      await expectLater(
        consumer.broker(ServiceAddress(workerType, id)),
        throwsCode(StatusCode.unavailable),
      );
      await expectLater(
        consumer.openChannel(ServiceAddress(workerType, id)),
        throwsCode(StatusCode.unavailable),
      );
    });

    test('a dial-back that arrives after the consumer gave up is sent '
        'GOAWAY, and the instance\'s dial fails', () async {
      // Either side gives up first: the consumer (its connectTimeout), or
      // the naming service (its brokerTimeout, then UNAVAILABLE).
      for (final consumerFirst in [true, false]) {
        const short = Duration(milliseconds: 300);
        final mesh = await Mesh.start(
          brokerTimeout: consumerFirst ? limit : short,
        );
        final worker = await node(
          credential: await issue('worker-a1', workerScopes),
        );
        final workerMesh = MeshNode.join(worker, mesh.uri, watch: false);
        addTearDown(workerMesh.leave);
        final id = await workerMesh
            .publish(workerType, (incoming) {}, endpoints: const [])
            .timeout(limit);
        // The instance answers only once the consumer has given up.
        final dialBack = workerMesh.client.connectHandler!;
        final asked = Completer<void>();
        final release = Completer<void>();
        final dialled = Completer<Object?>();
        workerMesh.client.connectHandler = (request) async {
          asked.complete();
          await release.future;
          try {
            await dialBack(request);
            dialled.complete(null);
          } on Object catch (e) {
            dialled.complete(e);
            rethrow;
          }
        };
        final peerGoAways = <Status>[];
        final ended = <Future<Status>>[];
        worker.connections.listen((connection) {
          connection.peerGoAwayStatus.then(peerGoAways.add).ignore();
          ended.add(connection.done);
        });
        final consumer = await node(
          credential: await issue('consumer-1', consumerScopes),
          connectTimeout: consumerFirst ? short : limit,
        );
        await consumer.listenMemory(policy: ChannelPolicies.scoped());
        final consumerMesh = MeshNode.join(consumer, mesh.uri);
        addTearDown(consumerMesh.leave);
        await consumerMesh.synced.timeout(limit);
        await expectLater(
          consumer.broker(ServiceAddress(workerType, id)),
          throwsCode(
            consumerFirst
                ? StatusCode.deadlineExceeded
                : StatusCode.unavailable,
          ),
        );
        await asked.future.timeout(limit);
        release.complete();
        final outcome = await dialled.future.timeout(limit);
        expect(
          outcome,
          isA<SwitchboardException>().having(
            (e) => e.code,
            'code',
            StatusCode.unauthenticated,
          ),
        );
        // The consumer recognised the intent it gave up on and sent GOAWAY
        // once the IDENT verified.
        expect(ended, hasLength(1));
        await ended.single.timeout(limit);
        expect(peerGoAways, [hasCode(StatusCode.goingAway)]);
        expect(workerMesh.brokeredConnections, isEmpty);
      }
    });

    test('broker refuses without a brokering resolver, a listener, an '
        'instance or a verifier', () async {
      final consumer = await node(
        credential: await issue('consumer-1', consumerScopes),
      );
      final address = ServiceAddress(workerType, 5);
      await expectLater(
        consumer.broker(address),
        throwsCode(StatusCode.failedPrecondition),
      );
      final mesh = await Mesh.start();
      final joined = MeshNode.join(consumer, mesh.uri);
      addTearDown(joined.leave);
      await expectLater(
        consumer.broker(address),
        throwsCode(StatusCode.failedPrecondition),
      );
      await consumer.listenMemory();
      await expectLater(
        consumer.broker(ServiceAddress(workerType)),
        throwsCode(StatusCode.invalidArgument),
      );
      // Without a verifier it could not tell who dialled back.
      final blind = await node(
        credential: await issue('consumer-1', consumerScopes),
        verify: false,
      );
      await blind.listenMemory();
      await expectLater(
        blind.broker(address, resolver: consumer.resolver),
        throwsCode(StatusCode.failedPrecondition),
      );
    });

    test('PeerSet brokers, and brokers again after a loss', () async {
      final (_, _, workerMesh, id, consumer, _) = await setUp();
      final set = PeerSet.watch(
        consumer,
        workerType,
        channel: ChannelAddress(type: workerType),
        initialBackoff: const Duration(milliseconds: 20),
        maxBackoff: const Duration(milliseconds: 100),
      );
      addTearDown(set.close);
      final events = <String>[];
      set.events.listen((e) => events.add(e.type.name));
      await until(() => set.online.length == 1);
      final peer = set.peers[id]!;
      expect(peer.endpoint, isNull);
      expect(peer.connection?.peerIdentity?.identity, 'worker-a1');
      final first = peer.connection!;
      await first.close();
      await until(
        () =>
            peer.isOnline &&
            peer.connection != null &&
            !identical(peer.connection, first),
      );
      await until(() => workerMesh.brokeredConnections.length == 1);
      expect(events, ['added', 'online', 'offline', 'online']);
      final talk = await set.openTalk(id);
      expect(
        text((await talk.request('RUN', bytes('x')).timeout(limit)).payload),
        'x by consumer-1',
      );
    });
  });
}

/// Holds just the naming OPEN check across the connection's expiry.
class _DelayedVerifier extends CredentialVerifier {
  _DelayedVerifier(this.delegate, this.ready);

  final CredentialVerifier delegate;
  final Future<void> ready;

  @override
  Future<Credential> verify(Uint8List bytes, {DateTime? now}) async {
    await ready;
    return delegate.verify(bytes, now: now);
  }
}
