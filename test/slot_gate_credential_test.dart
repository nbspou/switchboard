// Requests a slot gate forwards to the new owner (queued at DRAIN, or
// arriving during the forwarding grace) present the credential of the
// channel they arrived on, the application payload of its OPEN, and never
// the forwarding node's own default payload: a client request relayed by a
// frontend reaches the new owner as the client's. Three nodes over mem://
// endpoints: the frontend that opens the clients' channels, the old owner
// (kv/1, with the gate) and the new owner (kv/2), both backends with a
// service token as their default payload.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:switchboard/src/switchboard/memory_endpoints.dart';
import 'package:switchboard/switchboard.dart';
import 'package:test/test.dart';

const fast = MuxOptions(
  goAwayGrace: Duration(milliseconds: 100),
  keepAliveInterval: null,
);
const limit = Duration(seconds: 5);

final kv = Name('kv');

Uint8List bytes(String text) => Uint8List.fromList(utf8.encode(text));

String text(Uint8List data) => utf8.decode(data);

Future<void> until(bool Function() condition) async {
  final deadline = DateTime.now().add(limit);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition not met within $limit');
    }
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

/// Answers [m] as a backend that checks the [credential] of its caller:
/// `APPLY` is a client procedure, refused to a service token with
/// `PERMISSION_DENIED` and to no token with `UNAUTHENTICATED`; a client
/// token gets `<who>:<token>:<payload>`.
void answer(TalkMessage m, Uint8List credential, String who) {
  if (!m.canReply) {
    return;
  }
  final token = text(credential);
  if (token.isEmpty) {
    m.replyAbort(Status.of(StatusCode.unauthenticated));
  } else if (!token.startsWith('client-')) {
    m.replyAbort(Status.of(StatusCode.permissionDenied, 'not for $token'));
  } else {
    m.reply(bytes('$who:$token:${text(m.payload)}'));
  }
}

/// The old owner's application: every channel is long-lived, its requests
/// gated by [SlotGate.serveRequest] and answered by [answer].
class Backend extends SlotLifecycle {
  /// Channels served.
  int served = 0;

  /// The caller's credential when it is not the channel's (a relay that
  /// passes it in-band): checked here and given to [SlotGate.serveRequest].
  Uint8List? credential;

  @override
  Future<AssignResult> load(
    int slot, {
    required int epoch,
    required int holder,
    required bool shared,
  }) async => AssignResult.holding;

  @override
  void serve(IncomingChannel channel, int slot) {
    served++;
    gate.detach(channel);
    channel.talk().messages.listen(
      (m) => gate.serveRequest(
        m,
        slot,
        (m) => answer(m, credential ?? channel.address.payload, 'A'),
        payload: credential,
      ),
    );
  }
}

/// The answer to `APPLY payload` on [talk]: the reply text, or the abort
/// code.
Future<Object> apply(TalkChannel talk, String payload) => talk
    .request('APPLY', bytes(payload))
    .then<Object>(
      (m) => text(m.payload),
      onError: (Object e) => (e as SwitchboardException).code!,
    );

void main() {
  late Switchboard front;
  late Switchboard from;
  late Switchboard to;
  late Uri fromUri;
  late NamingClient client;
  late Backend backend;
  late SlotGate gate;

  /// Channels the new owner received.
  late List<IncomingChannel> arrived;

  /// While set, the new owner holds `APPLY hold` until it completes.
  Completer<void>? hold;

  setUp(() async {
    hold = null;
    arrived = [];
    to = Switchboard(muxOptions: fast, defaultPayload: bytes('service'));
    to.registerService(kv, (incoming) {
      arrived.add(incoming);
      incoming.talk().messages.listen((m) async {
        if (text(m.payload) == 'hold') {
          await hold?.future;
        }
        answer(m, incoming.address.payload, 'B');
      });
    }, instance: 2);
    final toUri = await to.listenMemory();
    from = Switchboard(
      muxOptions: fast,
      defaultPayload: bytes('service'),
      resolver: StaticResolver([
        ServiceRecord(ServiceAddress(kv, 2), endpoints: [toUri]),
      ]),
    );
    fromUri = await from.listenMemory();
    client = NamingClient(() async => throw StateError('not connected'));
    backend = Backend();
    gate = SlotGate(
      from,
      client,
      kv,
      lifecycle: backend,
      instance: 1,
      trackChannels: false,
    );
    from.registerService(kv, gate.handler, instance: 1);
    await gate.onAssign(
      AssignRequest(kv, 1, epoch: 1, holder: 0, shared: false),
    );
    // A frontend: each channel carries its client's token, none its own.
    front = Switchboard(muxOptions: fast);
  });

  tearDown(() async {
    await gate.close();
    await client.close();
    await front.close();
    await from.close();
    await to.close();
  });

  tearDownAll(() {
    expect(MemoryEndpoints.ids, isEmpty, reason: 'a memory listener leaked');
  });

  /// A client's channel to slot 1, relayed by the frontend with [token].
  Future<TalkChannel> relay(String token) => front.openTalkAt(
    fromUri,
    ChannelAddress(type: kv, instance: 1, shard: 1, payload: bytes(token)),
  );

  Future<void> handOver() async {
    await gate.onDrain(DrainRequest(kv, 1, epoch: 2, to: 2));
    await gate.onForward(ForwardRequest(kv, 1, epoch: 2, to: 2));
  }

  test('a request forwarded during the grace period presents its '
      "client's token", () async {
    final talk = await relay('client-77');
    expect(await apply(talk, 'a'), 'A:client-77:a');
    await handOver();
    expect(gate.stateOf(1), SlotGateState.forwarding);
    // Forwarded with the old owner's service token, it would be refused.
    expect(await apply(talk, 'b'), 'B:client-77:b');
    expect(arrived, hasLength(1));
    expect(text(arrived.single.address.payload), 'client-77');
    expect(arrived.single.address.instance, 2);
    expect(arrived.single.address.shard, 1);
    await talk.close();
  });

  test("requests queued at DRAIN are forwarded with their clients' tokens "
      'on FORWARD', () async {
    final first = await relay('client-77');
    final second = await relay('client-88');
    expect(await apply(first, 'a'), 'A:client-77:a');
    expect(await apply(second, 'a'), 'A:client-88:a');
    await gate.onDrain(DrainRequest(kv, 1, epoch: 2, to: 2));
    final queued = [apply(first, 'q'), apply(second, 'r'), apply(first, 's')];
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(arrived, isEmpty);
    await gate.onForward(ForwardRequest(kv, 1, epoch: 2, to: 2));
    expect(await Future.wait(queued).timeout(limit), [
      'B:client-77:q',
      'B:client-88:r',
      'B:client-77:s',
    ]);
    expect([
      for (final c in arrived) text(c.address.payload),
    ], unorderedEquals(['client-77', 'client-88']));
    await first.close();
    await second.close();
  });

  test('one forwarding channel per token, each closed once idle', () async {
    final a = await relay('client-77');
    final b = await relay('client-77');
    final c = await relay('client-88');
    for (final talk in [a, b, c]) {
      await apply(talk, 'prime');
    }
    expect(backend.served, 3);
    await handOver();
    expect(
      await Future.wait([apply(a, 'a'), apply(b, 'b'), apply(c, 'c')])
          .timeout(limit),
      ['B:client-77:a', 'B:client-77:b', 'B:client-88:c'],
    );
    // The two channels with the same token share one.
    expect([
      for (final c in arrived) text(c.address.payload),
    ], unorderedEquals(['client-77', 'client-88']));
    // About a second without a request: each is closed.
    for (final forwarded in List.of(arrived)) {
      expect(await forwarded.channel.done.timeout(limit), Status.ok);
    }
    expect(await apply(c, 'again'), 'B:client-88:again');
    expect(arrived, hasLength(3));
    expect(text(arrived.last.address.payload), 'client-88');
    for (final talk in [a, b, c]) {
      await talk.close();
    }
  });

  test('a client without a token is forwarded without one, not with the '
      "node's", () async {
    final talk = await relay('');
    expect(await apply(talk, 'a'), StatusCode.unauthenticated);
    expect(backend.served, 1);
    await handOver();
    expect(await apply(talk, 'b'), StatusCode.unauthenticated);
    expect(arrived.single.address.payload, isEmpty);
    await talk.close();
  });

  test('an explicit payload is presented instead of the channel\'s', () async {
    // A relay that passes its client's token in-band, on a channel that
    // carries its own service token.
    backend.credential = bytes('client-5');
    final talk = await relay('service');
    expect(await apply(talk, 'a'), 'A:client-5:a');
    await gate.onDrain(DrainRequest(kv, 1, epoch: 2, to: 2));
    final queued = apply(talk, 'q');
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await gate.onForward(ForwardRequest(kv, 1, epoch: 2, to: 2));
    expect(await queued.timeout(limit), 'B:client-5:q');
    expect(await apply(talk, 'g'), 'B:client-5:g');
    expect(arrived, hasLength(1));
    expect(text(arrived.single.address.payload), 'client-5');
    await talk.close();
  });

  test('a forwarding channel outlives the slot until its request is '
      'answered', () async {
    final talk = await relay('client-77');
    expect(await apply(talk, 'a'), 'A:client-77:a');
    await handOver();
    hold = Completer<void>();
    final held = apply(talk, 'hold');
    await until(() => arrived.isNotEmpty);
    await gate.onRevoke(kv, 1);
    expect(gate.stateOf(1), isNull);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(arrived.single.channel.canSend, isTrue);
    hold!.complete();
    expect(await held.timeout(limit), 'B:client-77:hold');
    expect(await arrived.single.channel.done.timeout(limit), Status.ok);
    await talk.close();
  });
}
