// Shared helpers for the naming service, client and resolver tests.

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:async/async.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:switchboard/src/name.dart';
import 'package:switchboard/src/naming/naming_protocol.dart';
import 'package:switchboard/src/naming/naming_service.dart';
import 'package:switchboard/src/status.dart';
import 'package:switchboard/src/talk/talk_channel.dart';
import 'package:switchboard/src/talk/talk_frame.dart';
import 'package:switchboard/src/talk/talk_message.dart';
import 'package:test/test.dart';

const Duration ms10 = Duration(milliseconds: 10);
const Duration ms50 = Duration(milliseconds: 50);
const Duration reconnectDelay = Duration(milliseconds: 20);

/// Upper bound for anything a test waits on; only reached on failure.
const Duration timeout = Duration(seconds: 2);

/// Short timeouts, so that a request left unanswered shows quickly.
const TalkOptions serverOptions = TalkOptions(
  replyTimeout: Duration(milliseconds: 200),
  requestTimeout: Duration(milliseconds: 300),
);
const TalkOptions clientOptions = TalkOptions(
  replyTimeout: Duration(milliseconds: 200),
  requestTimeout: Duration(milliseconds: 300),
);

final Uri uriA = Uri.parse('tcp://10.0.0.5:9101');
final Uri uriB = Uri.parse('ws://10.0.0.6:9100/ws');

Uint8List bytes(List<int> values) => Uint8List.fromList(values);

Matcher isStatus(StatusCode code) =>
    isA<SwitchboardException>().having((e) => e.code, 'code', code);

Matcher throwsStatus(StatusCode code) => throwsA(isStatus(code));

/// Lets pending microtasks and stream events run.
Future<void> pump() => Future<void>.delayed(Duration.zero);

/// Polls [condition] every few milliseconds; fails after [timeout].
Future<void> until(bool Function() condition) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

/// A naming service and in-memory links to it. No assignment hold and no
/// settle window after `SLOTS` unless asked for (most tests assign fresh
/// slots and check the timing of what follows; [productionSettle] opts in
/// to the service's default window); the `ASSIGN` backoff and the
/// hand-over bound of the service by default.
class Harness {
  Harness({
    Duration heldExtendInterval = ms50,
    Duration assignmentHold = Duration.zero,
    Duration holderGrace = const Duration(minutes: 5),
    Duration handoverTimeout = const Duration(milliseconds: 300),
    Duration assignBackoff = const Duration(milliseconds: 200),
    Duration assignBackoffMax = const Duration(seconds: 10),
    Duration holdingSettle = Duration.zero,
    Duration handoverMaxDuration = const Duration(minutes: 10),
  }) : service = NamingService(
         heldExtendInterval: heldExtendInterval,
         assignmentHold: assignmentHold,
         holderGrace: holderGrace,
         handoverTimeout: handoverTimeout,
         assignBackoff: assignBackoff,
         assignBackoffMax: assignBackoffMax,
         holdingSettle: holdingSettle,
         handoverMaxDuration: handoverMaxDuration,
       );

  /// The service's default `holdingSettle`, for tests that run with it.
  static const Duration productionSettle = Duration(seconds: 1);

  final NamingService service;

  /// Server sides of every link, in creation order.
  final List<TalkChannel> servers = [];

  /// Client sides of every link, in creation order.
  final List<TalkChannel> clients = [];

  /// Opens a link: the server side is served, both sides are returned.
  /// With [sync] the link delivers synchronously, so that everything the
  /// service sends in one step reaches the client's channel in one burst,
  /// as the mux delivers a batch of frames.
  (TalkChannel client, TalkChannel server) link({bool sync = false}) {
    final controller = StreamChannelController<Uint8List>(sync: sync);
    final server = TalkChannel(controller.local, options: serverOptions);
    final client = TalkChannel(controller.foreign, options: clientOptions);
    servers.add(server);
    clients.add(client);
    service.serve(server);
    return (client, server);
  }

  Future<void> close() async {
    await service.close();
    await Future.wait([for (final c in clients) c.close()]);
  }
}

/// A [TalkConnector] over a [Harness] that can be switched off. With
/// [sync], its links deliver synchronously (see [Harness.link]).
class Connector {
  Connector(this.harness, {this.sync = false});

  Harness harness;

  final bool sync;

  /// While true, connecting fails.
  bool down = false;

  int calls = 0;

  /// Server sides of the links handed out.
  final List<TalkChannel> servers = [];

  Future<TalkChannel> call() async {
    calls++;
    if (down) {
      throw SwitchboardException.of(StatusCode.unavailable, 'service down');
    }
    final (client, server) = harness.link(sync: sync);
    servers.add(server);
    return client;
  }
}

/// A [TalkConnector] over a [Harness] whose links pass every Talk frame
/// through filters: a frame for which [dropToService] or [dropToClient]
/// returns true is lost on the way.
class LossyConnector {
  LossyConnector(this.harness);

  final Harness harness;

  /// Drops frames from the client to the naming service.
  bool Function(TalkFrame frame) dropToService = _keep;

  /// Drops frames from the naming service to the client.
  bool Function(TalkFrame frame) dropToClient = _keep;

  int calls = 0;

  static bool _keep(TalkFrame frame) => false;

  Future<TalkChannel> call() async {
    calls++;
    final service = StreamChannelController<Uint8List>();
    final client = StreamChannelController<Uint8List>();
    harness.service.serve(TalkChannel(service.local, options: serverOptions));
    service.foreign.stream.listen((frame) {
      if (!dropToClient(TalkFrame.decode(frame))) {
        client.local.sink.add(frame);
      }
    }, onDone: client.local.sink.close);
    client.local.stream.listen((frame) {
      if (!dropToService(TalkFrame.decode(frame))) {
        service.foreign.sink.add(frame);
      }
    }, onDone: service.foreign.sink.close);
    return TalkChannel(client.foreign, options: clientOptions);
  }
}

/// True for the final response to a request (not a stream item, extend or
/// abort).
bool isFinalResponse(TalkFrame frame) =>
    frame.kind == TalkKind.message && frame.responseId != 0;

/// True for a request for [procedure].
bool Function(TalkFrame) isRequestFor(String procedure) =>
    (frame) =>
        frame.kind == TalkKind.message &&
        frame.requestId != 0 &&
        frame.procedure?.toString() == procedure;

/// Registers over a raw Talk channel and returns the instance id. The
/// answer is ordered with the channel's messages: a [Watcher] on the same
/// channel has seen the `UP` when this completes.
Future<int> register(
  TalkChannel channel,
  String type, {
  int instance = 0,
  List<Uri> endpoints = const [],
  Uint8List? metadata,
}) async {
  final response = await channel.request(
    'REGISTER',
    RegisterRequest(
      Name(type),
      requestedInstance: instance,
      endpoints: endpoints,
      metadata: metadata,
    ).encode(),
    ordered: true,
  );
  return RegisterResponse.decode(response.payload).instance;
}

/// Unregisters over a raw Talk channel; ordered like [register].
Future<void> unregister(TalkChannel channel, String type, int instance) =>
    channel.request(
      'UNREGSTR',
      UnregisterRequest(Name(type), instance).encode(),
      ordered: true,
    );

/// The subscriptions of one raw Talk channel to the naming table, read one
/// by one as strings in channel order: the events (`UP npc/1`,
/// `DOWN npc/1`, ... through [describer]) and the answers to [watch] and
/// [unwatch] (`WATCHED`, `UNWATCHED`, or for instance `UNWATCH notFound`).
/// Everything read is also in [log] at once.
class Watcher {
  /// Takes [channel]'s messages, then sends `WATCH` with [type] or
  /// [payload] unless [start] is false.
  Watcher(
    this.channel, {
    String? type,
    Uint8List? payload,
    bool start = true,
    this.describer = describe,
  }) {
    channel.messages.listen(add, onError: (Object _) {});
    if (start) {
      watch(type: type, payload: payload).ignore();
    }
  }

  /// For a channel whose messages are taken elsewhere: that listener
  /// passes the one-way messages to [add].
  Watcher.fed(this.channel, {this.describer = describe});

  final TalkChannel channel;
  final String Function(TalkMessage) describer;

  /// Everything read so far, in order.
  final List<String> log = [];

  // Synchronous, so that the lines are queued in the order they happen.
  final StreamController<String> _lines = StreamController<String>(sync: true);
  late final StreamQueue<String> _queue = StreamQueue(_lines.stream);

  /// Takes one message of the channel.
  void add(TalkMessage message) => _line(describer(message));

  void _line(String line) {
    log.add(line);
    _lines.add(line);
  }

  /// Sends `WATCH` (all types unless [type] or [payload]); its answer is
  /// read in its place among the events.
  Future<void> watch({String? type, Uint8List? payload}) =>
      _subscription('WATCH', type, payload);

  /// Sends `UNWATCH`, like [watch].
  Future<void> unwatch({String? type, Uint8List? payload}) =>
      _subscription('UNWATCH', type, payload);

  Future<void> _subscription(
    String procedure,
    String? type,
    Uint8List? payload,
  ) => channel
      .request(
        procedure,
        payload ?? WatchRequest(type == null ? null : Name(type)).encode(),
        ordered: true,
      )
      .then(
        (_) => _line('${procedure}ED'),
        onError: (Object e) {
          _line(
            '$procedure '
            '${e is SwitchboardException ? e.code?.name ?? e.status : e}',
          );
          throw e;
        },
      );

  Future<String> get next => _queue.next.timeout(timeout);

  Future<List<String>> take(int count) => _queue.take(count).timeout(timeout);

  /// Lines up to and including the first that satisfies [test].
  Future<List<String>> until(bool Function(String) test) async {
    final out = <String>[];
    while (true) {
      final line = await next;
      out.add(line);
      if (test(line)) {
        return out;
      }
    }
  }
}

/// `UP npc/1 tcp://...`, `DOWN npc/1`, or the procedure name.
String describe(TalkMessage m) => switch (m.procedureName) {
  'UP' => describeEvent(ServiceEvent.decodeUp(m.payload)),
  'DOWN' => describeEvent(ServiceEvent.decodeDown(m.payload)),
  _ => m.procedureName,
};

String describeEvent(ServiceEvent e) {
  if (!e.up) {
    return 'DOWN ${e.record.address}';
  }
  final endpoints = e.record.endpoints.join(',');
  final metadata = e.record.metadata;
  return [
    'UP ${e.record.address}',
    if (endpoints.isNotEmpty) endpoints,
    if (metadata.isNotEmpty) 'meta ${utf8.decode(metadata)}',
  ].join(' ');
}

/// Random bytes on even [i]; on odd [i] something shaped like a naming
/// payload (name, u48, endpoint list, then mostly a metadata field, of
/// any size, possibly cut short) with noisy, URI-ish endpoints.
Uint8List fuzzInput(Random random, int i) {
  Uint8List noise(int n) =>
      Uint8List.fromList([for (var k = 0; k < n; k++) random.nextInt(256)]);
  if (i.isEven) {
    return noise(random.nextInt(64));
  }
  final b = BytesBuilder()
    ..add(Name('npc').bytes)
    ..add(random.nextInt(4) == 0 ? Uint8List(6) : noise(6));
  final count = random.nextInt(4);
  b.addByte(count);
  for (var k = 0; k < count; k++) {
    if (random.nextInt(4) == 0) {
      // Random bytes, possibly cut short.
      final length = random.nextInt(256);
      b
        ..addByte(length)
        ..add(noise(random.nextInt(length + 2)));
      continue;
    }
    // Short runs of the pieces that trip up Uri normalisation: dot
    // segments, backslashes, empty authorities and ports, stray escapes.
    const pieces = [
      '/.', '/..', './', '../', '/', '//', '.', '..', r'\', ':', '{', '}',
      '#', '?', '%', '%41', '%zz', '@', '[', ']', 'h', '1', ' ', '\u00e9',
      '\u00ff', '"', '<', '^', '|', '`', //
    ];
    const prefixes = [
      '', 'tcp:', 'ws:', 'tcp:/', 'tcp://', 'ws://h/', 'tcp://h:', 'a:/', //
    ];
    final text =
        prefixes[random.nextInt(prefixes.length)] +
        [
          for (var n = random.nextInt(12); n > 0; n--)
            pieces[random.nextInt(pieces.length)],
        ].join();
    final encoded = utf8.encode(text);
    final length = min(encoded.length, 255);
    b
      ..addByte(length)
      ..add(encoded.sublist(0, length));
  }
  switch (random.nextInt(4)) {
    case 0:
      // No metadata field: the layout before it was added.
      break;
    case 1:
      // A length, possibly over the limit, and up to 8 bytes.
      b
        ..addByte(random.nextInt(256))
        ..addByte(random.nextInt(3) == 0 ? random.nextInt(256) : 0)
        ..add(noise(random.nextInt(9)));
    default:
      final length = random.nextInt(8);
      b
        ..add([length, 0])
        ..add(noise(length));
  }
  return b.toBytes();
}
