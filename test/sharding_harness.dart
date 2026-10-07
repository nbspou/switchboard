/*
Polyverse Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Authors:
  Jan Boon <jan.boon@kaetemi.be>
  Claude Opus 5.5 <noreply@anthropic.com>
*/

// Shared helpers for the sharding tests: scripted instances speaking the
// slot procedures over raw Talk channels, and watches of slot events.

import 'dart:async';
import 'dart:typed_data';

import 'package:async/async.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:switchboard/src/name.dart';
import 'package:switchboard/src/naming/naming_client.dart';
import 'package:switchboard/src/naming/naming_protocol.dart';
import 'package:switchboard/src/status.dart';
import 'package:switchboard/src/talk/talk_channel.dart';
import 'package:switchboard/src/talk/talk_frame.dart';
import 'package:switchboard/src/talk/talk_message.dart';
import 'package:switchboard/src/talk/talk_stream.dart';

import 'naming_harness.dart';

final Name kv = Name('kv');
final Name zone = Name('zone');
final Name userq = Name('userq');
final Name room = Name('room');

/// `SLOTSPC kv 8 managed lazy shared`, `SLOT kv/3 owned 1 holder 1 epoch 1`,
/// and the forms of [describe] for the rest.
String describeItem(TalkMessage m) => switch (m.procedureName) {
  'SLOTSPC' => describeSpace(SlotSpace.decode(m.payload)),
  'SLOT' => describeSlot(SlotItem.decode(m.payload)),
  'PHASE' => 'PHASE ${PhaseItem.decode(m.payload).phase.name}',
  _ => describe(m),
};

String describeSpace(SlotSpace s) =>
    'SLOTSPC ${s.type} ${s.count} ${s.mode.name}'
    '${s.lazy ? ' lazy' : ''}${s.shared ? ' shared' : ''}';

String describeSlot(SlotItem item) =>
    'SLOT ${item.type}/${item.slot} '
    '${item.entry}';

/// A [Watcher] that also reads the slot events (`SLOTSPC`, `SLOT`).
class ItemWatch extends Watcher {
  ItemWatch(super.channel, {super.payload, super.start})
    : super(describer: describeItem);
}

/// A raw `LOOKUP` whose items are read one by one as strings.
class Lookup {
  Lookup(TalkChannel channel, Uint8List payload)
    : stream = channel.streamRequest('LOOKUP', payload) {
    _queue = StreamQueue(stream.items.map(describeItem));
  }

  final TalkStream stream;
  late final StreamQueue<String> _queue;

  Future<List<String>> take(int count) => _queue.take(count).timeout(timeout);
}

/// A sharded instance scripted over a raw Talk channel: registers with a
/// fixed id, answers the naming service's slot requests through the
/// replaceable behaviours, and records every request in [log] (shared
/// between instances to observe the global order).
class Instance {
  Instance(this.harness, this.type, this.id, this.log);

  final Harness harness;
  final Name type;
  final int id;
  final List<String> log;
  late TalkChannel channel;
  late TalkChannel server;

  /// Behaviours; the defaults answer at once (holding for ASSIGN).
  Future<AssignResponse> Function(AssignRequest) onAssign = (_) async =>
      const AssignResponse();
  Future<void> Function(DrainRequest) onDrain = (_) async {};
  Future<void> Function(ForwardRequest) onForward = (_) async {};
  Future<void> Function(ResumeRequest) onResume = (_) async {};

  /// Slots this instance believes it serves, with their epochs.
  final Map<int, int> serving = {};

  /// Sends an empty `EXTEND` every 50 ms while it handles a request, as an
  /// instance written before declared deadlines did (they restart the
  /// naming service's default timeout). Off: it sends none.
  bool heartbeat = true;

  /// Receives the one-way messages (subscription events) of [channel].
  void Function(TalkMessage event)? onEvent;

  Future<void> start({SlotSpace? space, int capacity = 1}) async {
    final (client, server) = harness.link();
    channel = client;
    this.server = server;
    channel.messages.listen(_serve);
    await register(channel, type.toString(), instance: id);
    if (space != null) {
      await slots(space, capacity: capacity);
    }
  }

  void _serve(TalkMessage m) {
    if (!m.expectsReply) {
      onEvent?.call(m);
      return;
    }
    if (!m.canReply) {
      return;
    }
    m.setReplyTimeout(Duration.zero);
    final extend = Timer.periodic(ms50, (t) {
      if (m.canReply && heartbeat) {
        m.extend();
      } else {
        t.cancel();
      }
    });
    unawaited(
      _handle(m)
          .then(
            (payload) {
              if (m.canReply) {
                m.reply(payload);
              }
            },
            onError: (Object e) {
              if (m.canReply) {
                m.replyAbort(
                  e is SwitchboardException
                      ? e.status
                      : Status.of(StatusCode.unavailable, '$e'),
                );
              }
            },
          )
          .whenComplete(extend.cancel),
    );
  }

  Future<Uint8List> _handle(TalkMessage m) async {
    final name = id.toRadixString(16);
    switch (m.procedureName) {
      case 'ASSIGN':
        final r = AssignRequest.decode(m.payload);
        log.add(
          '$name ASSIGN ${r.slot} e${r.epoch} h${r.holder}'
          '${r.shared ? ' shared' : ''}',
        );
        final response = await onAssign(r);
        serving[r.slot] = r.epoch;
        return response.encode();
      case 'DRAIN':
        final r = DrainRequest.decode(m.payload);
        log.add('$name DRAIN ${r.slot} e${r.epoch} to${r.to}');
        await onDrain(r);
        return Uint8List(0);
      case 'FORWARD':
        final r = ForwardRequest.decode(m.payload);
        log.add('$name FORWARD ${r.slot} e${r.epoch} to${r.to}');
        serving.remove(r.slot);
        await onForward(r);
        return Uint8List(0);
      case 'RESUME':
        final r = ResumeRequest.decode(m.payload);
        log.add('$name RESUME ${r.slot} e${r.epoch}');
        await onResume(r);
        return Uint8List(0);
    }
    throw SwitchboardException.of(StatusCode.unimplemented);
  }

  Future<void> slots(SlotSpace space, {int capacity = 1}) => channel.request(
    'SLOTS',
    SlotsRequest(space, capacity: capacity).encode(),
  );

  Future<int> claim(int slot, {bool holding = false, int epoch = 0}) async {
    final r = await channel.request(
      'CLAIM',
      ClaimRequest(type, slot, holding: holding, epoch: epoch).encode(),
    );
    return ClaimResponse.decode(r.payload).epoch;
  }

  Future<void> release(int slot, {bool keepStorage = false}) => channel.request(
    'RELEASE',
    ReleaseRequest(type, slot, keepStorage: keepStorage).encode(),
  );

  Future<List<int>> holding(List<int> slots) async {
    final r = await channel.request(
      'HOLDING',
      HoldingRequest(type, slots).encode(),
    );
    return HoldingResponse.decode(r.payload).discard;
  }

  Future<LocateResponse> locate(int slot) async {
    final r = await channel.request(
      'LOCATE',
      LocateRequest(type, slot).encode(),
    );
    return LocateResponse.decode(r.payload);
  }

  Future<void> close() => channel.close();
}

/// Starts a MIGRATE over [channel]; collects its PHASE items.
class Migration {
  Migration(TalkChannel channel, Name type, int slot, {int to = 0})
    : stream = channel.streamRequest(
        'MIGRATE',
        MigrateRequest(type, slot, to: to).encode(),
      ) {
    stream.items.listen(
      (m) => phases.add(PhaseItem.decode(m.payload).phase.name),
      onError: (Object e) {},
    );
    done = stream.done.then<Status>(
      (_) => Status.ok,
      onError: (Object e) => (e as SwitchboardException).status,
    );
  }

  final TalkStream stream;
  final List<String> phases = [];
  late final Future<Status> done;
}

/// A [TalkConnector] whose naming service can be swapped (a restart) and
/// whose links can drop frames to the client.
class SwitchableConnector {
  SwitchableConnector(this.harness);

  Harness harness;

  /// Drops frames from the naming service to the client.
  bool Function(TalkFrame frame) dropToClient = (_) => false;

  /// Server sides of the links handed out, in order.
  final List<TalkChannel> servers = [];

  Future<TalkChannel> call() async {
    final service = StreamChannelController<Uint8List>();
    final client = StreamChannelController<Uint8List>();
    final server = TalkChannel(service.local, options: serverOptions);
    servers.add(server);
    harness.service.serve(server);
    service.foreign.stream.listen((frame) {
      if (!dropToClient(TalkFrame.decode(frame))) {
        client.local.sink.add(frame);
      }
    }, onDone: client.local.sink.close);
    client.local.stream.listen(
      service.foreign.sink.add,
      onDone: service.foreign.sink.close,
    );
    return TalkChannel(client.foreign, options: clientOptions);
  }
}

/// A [SlotHandler] that records calls and can be scripted.
class RecordingHandler extends SlotHandler {
  RecordingHandler(this.name, this.log);

  final String name;
  final List<String> log;

  Future<AssignResult> Function(AssignRequest) assign = (_) async =>
      AssignResult.holding;
  Future<void> Function(DrainRequest) drain = (_) async {};
  Future<void> Function(ForwardRequest) forward = (_) async {};
  Future<void> Function(ResumeRequest) resume = (_) async {};
  final List<String> revoked = [];

  /// Every [onDiscard], as `type: slots`.
  final List<String> discarded = [];

  /// The context of the latest request of each kind and slot, by
  /// `ASSIGN 3`, `DRAIN 3` and so on; set before the script runs.
  final Map<String, SlotRequestContext> contexts = {};

  @override
  Future<AssignResult> onAssign(AssignRequest r, SlotRequestContext context) {
    log.add('$name ASSIGN ${r.slot} e${r.epoch} h${r.holder}');
    contexts['ASSIGN ${r.slot}'] = context;
    return assign(r);
  }

  @override
  Future<void> onDrain(DrainRequest r, SlotRequestContext context) {
    log.add('$name DRAIN ${r.slot} e${r.epoch} to${r.to}');
    contexts['DRAIN ${r.slot}'] = context;
    return drain(r);
  }

  @override
  Future<void> onForward(ForwardRequest r, SlotRequestContext context) {
    log.add('$name FORWARD ${r.slot} e${r.epoch} to${r.to}');
    contexts['FORWARD ${r.slot}'] = context;
    return forward(r);
  }

  @override
  Future<void> onResume(ResumeRequest r, SlotRequestContext context) {
    log.add('$name RESUME ${r.slot} e${r.epoch}');
    contexts['RESUME ${r.slot}'] = context;
    return resume(r);
  }

  @override
  Future<void> onRevoke(Name type, int slot) async {
    log.add('$name REVOKE $slot');
    revoked.add('$type/$slot');
  }

  @override
  void onDiscard(Name type, List<int> slots) =>
      discarded.add('$type: ${slots.join(',')}');
}

/// A scripted naming service over one link at a time, for timing what the
/// client sends: answers at once `REGISTER` (the id asked for), `SLOTS`,
/// `HOLDING` (nothing to discard) and `CLAIM` (the epoch claimed, unless
/// [answerClaims] is off), and `WATCH` once [watch] completes. Records the
/// requests in [log].
class ScriptedNaming {
  ScriptedNaming({int maxOutgoingRequests = 1024})
    : options = TalkOptions(
        requestTimeout: const Duration(seconds: 2),
        replyTimeout: const Duration(seconds: 1),
        maxOutgoingRequests: maxOutgoingRequests,
      );

  /// The client's options.
  final TalkOptions options;
  final List<String> log = [];
  final Completer<void> watch = Completer<void>();
  bool answerClaims = true;
  int connects = 0;

  /// The service side of the latest link.
  late TalkChannel server;

  Future<TalkChannel> connect() async {
    connects++;
    final link = StreamChannelController<Uint8List>();
    server = TalkChannel(link.local, options: serverOptions);
    server.messages.listen(_serve, onError: (Object _) {});
    return TalkChannel(link.foreign, options: options);
  }

  void _serve(TalkMessage m) {
    if (!m.canReply) {
      return;
    }
    switch (m.procedureName) {
      case 'WATCH':
        log.add('WATCH');
        m.setReplyTimeout(Duration.zero);
        watch.future.then((_) {
          if (m.canReply) {
            m.reply(Uint8List(0));
          }
        });
      case 'REGISTER':
        final r = RegisterRequest.decode(m.payload);
        log.add('REGISTER ${r.type}/${r.requestedInstance}');
        m.reply(RegisterResponse(r.requestedInstance).encode());
      case 'SLOTS':
        log.add('SLOTS ${SlotsRequest.decode(m.payload).space.type}');
        m.reply(Uint8List(0));
      case 'HOLDING':
        final r = HoldingRequest.decode(m.payload);
        log.add('HOLDING ${r.type} ${r.slots.join(',')}');
        m.reply(const HoldingResponse([]).encode());
      case 'CLAIM':
        final r = ClaimRequest.decode(m.payload);
        log.add('CLAIM ${r.type}/${r.slot} e${r.epoch}');
        if (answerClaims) {
          m.reply(ClaimResponse(r.epoch).encode());
        } else {
          m.setReplyTimeout(Duration.zero);
        }
      default:
        log.add(m.procedureName);
        m.reply(Uint8List(0));
    }
  }
}
