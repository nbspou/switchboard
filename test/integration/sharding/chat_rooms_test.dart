// Use case 5 of the wiki page "Switchboard Sharding": chat rooms (`room`,
// eager managed, shared recovery). The wiki has N = 256; 16 rooms keep
// the test fast. Room history is in shared storage (a map shared by the
// servers), so a crashed server's rooms are reassigned at once. Members
// hold a long-lived channel per room: the server greets them with the
// history, pushes new messages, and closes their channels with RELOCATED
// naming the new owner when the room moves (they were served, so MOVED,
// which means nothing was processed, does not apply); members then rejoin
// through openTalkToSlot.

import 'dart:async';

import 'package:switchboard/switchboard.dart';
import 'package:test/test.dart';

import 'cluster.dart';

final room = Name('room');
const rooms = 16;

/// A room server. [storage] is the shared storage: room -> messages.
class RoomServer extends SlotLifecycle {
  RoomServer(this.storage);

  final Map<int, List<String>> storage;
  final Map<int, Set<IncomingChannel>> members = {};

  @override
  Future<AssignResult> load(
    int slot, {
    required int epoch,
    required int holder,
    required bool shared,
    SlotRequestContext? context,
  }) async {
    expect(shared, isTrue);
    storage.putIfAbsent(slot, () => []);
    members[slot] = {};
    // Nothing is kept locally.
    return AssignResult.notHolding;
  }

  /// The history is in shared storage already; the members rejoin at the
  /// new owner (their posts in flight are answered first: the gate waited
  /// for them).
  @override
  Future<void> drain(
    int slot, {
    required int epoch,
    required int to,
    SlotRequestContext? context,
  }) async => _dismiss(slot);

  @override
  Future<void> unload(int slot) async {
    _dismiss(slot);
    members.remove(slot);
  }

  void _dismiss(int slot) {
    final relocated = gate.relocatedStatus(slot);
    for (final member in members[slot]?.toList() ?? const <IncomingChannel>[]) {
      unawaited(member.reject(relocated));
    }
  }

  @override
  void serve(IncomingChannel channel, int slot) {
    gate.detach(channel);
    final present = members[slot]!..add(channel);
    final talk = channel.talk();
    unawaited(talk.done.then((_) => present.remove(channel)));
    talk.send('HIST', bytes(storage[slot]!.join('\n')));
    talk.messages.listen(
      (m) => gate.serveRequest(m, slot, (m) {
        final message = text(m.payload);
        final history = storage[slot]!;
        // Posts carry their author and number: a retried post whose answer
        // was lost is not added twice.
        if (!history.contains(message)) {
          history.add(message);
          for (final other in present) {
            try {
              other.talk().send('MSG', bytes(message));
            } on SwitchboardException {
              // Leaving.
            }
          }
        }
        m.reply(bytes('ok'));
      }),
      onError: (Object _) {},
    );
  }
}

/// Whether a member rejoins and posts again after [error]: [retryable], or
/// `RELOCATED`, the room moving while the member was in it. Posts carry
/// their author and number, so one that may have been applied is safely
/// sent again.
bool rejoinable(Object error) =>
    retryable(error) ||
    (error is SwitchboardException && error.code == StatusCode.relocated);

/// A chat member in one room.
class Member {
  Member(this.node, this.slot, this.name);

  final Switchboard node;
  final int slot;
  final String name;
  TalkChannel? _talk;
  bool _leaving = false;
  List<String> view = [];

  /// How each channel ended (while the member stayed).
  final List<StatusCode?> ends = [];
  int joins = 0;
  int posted = 0;

  Future<TalkChannel> _join() async {
    while (true) {
      try {
        final talk = await node.openTalkToSlot(room, slot);
        final greeted = Completer<void>();
        talk.messages.listen((m) {
          final message = text(m.payload);
          if (m.procedureName == 'HIST') {
            view = message.isEmpty ? [] : message.split('\n');
            greeted.complete();
          } else {
            view.add(message);
          }
        }, onError: (Object _) {});
        final ended = talk.done.then<void>(
          (status) => throw SwitchboardException(status),
        );
        ended.ignore();
        await Future.any([greeted.future, ended]).timeout(limit);
        joins++;
        unawaited(
          talk.done.then((status) {
            if (!_leaving) {
              ends.add(status.known);
            }
            if (identical(_talk, talk)) {
              _talk = null;
            }
          }),
        );
        return _talk = talk;
      } on Object catch (e) {
        if (!rejoinable(e)) {
          rethrow;
        }
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }
  }

  Future<void> join() => _join();

  Future<void> post() async {
    final message = '$name:${++posted}';
    while (true) {
      final talk = _talk ?? await _join();
      try {
        await talk.request('POST', bytes(message));
        return;
      } on Object catch (e) {
        if (!rejoinable(e)) {
          rethrow;
        }
        if (identical(_talk, talk)) {
          _talk = null;
        }
      }
    }
  }

  Future<void> leave() async {
    _leaving = true;
    await _talk?.close();
  }
}

void main() {
  test('a crashed server\'s rooms are reassigned at once; members follow '
      'the rooms through RELOCATED', () async {
    final cluster = Cluster('tcp');
    await cluster.start();
    final storage = <int, List<String>>{};
    Future<MeshNode> server(int id) async {
      final mesh = await cluster.member();
      await mesh
          .publishSharded(
            room,
            RoomServer(storage),
            count: rooms,
            shared: true,
            instance: id,
            trackChannels: false,
            forwardGrace: const Duration(milliseconds: 200),
          )
          .timeout(limit);
      return mesh;
    }

    final observer = await cluster.member(listen: false);
    final watch = MigrationWatch(observer.client, room);
    final table = observer.client;
    int ownerOf(int slot) => table.slotOwner(room, slot)?.owner ?? 0;
    final r1 = await server(0x41);
    await server(0x42);
    await server(0x43);
    await until(
      () =>
          watch.idle &&
          [0x41, 0x42, 0x43].every(
            (id) => table.slotTable(room)!.slotsOf(id).length >= rooms ~/ 3,
          ),
      'the rooms spread over three servers',
    );

    // A member in every room, a second one in four rooms.
    final onR1 = table.slotTable(room)!.slotsOf(0x41);
    final members = [
      for (var slot = 0; slot < rooms; slot++)
        Member(observer.switchboard, slot, 'm$slot'),
      for (var slot = 0; slot < 4; slot++)
        Member(observer.switchboard, slot, 'n$slot'),
    ];
    for (final member in members) {
      await member.join();
    }
    var stop = false;
    final loops = [
      for (final member in members)
        () async {
          while (!stop) {
            await member.post();
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
        }(),
    ];
    await until(() => members.every((m) => m.posted >= 3));

    // The first server crashes: its rooms go to the others at once.
    final crashed = DateTime.now();
    await cluster.crash(r1);
    await until(
      () =>
          table.slotOwners(room).length == 2 &&
          [for (var s = 0; s < rooms; s++) ownerOf(s)].every((o) => o != 0),
      'every room has a new owner',
    );
    expect(DateTime.now().difference(crashed), lessThan(limit));
    expect(table.slotOwners(room), {0x42, 0x43});
    final posted = {for (final m in members) m.name: m.posted};
    await until(
      () => members.every((m) => m.posted >= posted[m.name]! + 3),
      'members of the crashed server rejoined',
    );
    for (final member in members) {
      if (onR1.contains(member.slot)) {
        expect(member.joins, 2, reason: member.name);
        expect(member.ends, [StatusCode.connectionLost], reason: member.name);
      }
    }

    // It comes back: rooms move to it one at a time, and members on their
    // old channels are told RELOCATED.
    final movesBefore = watch.moves.length;
    await server(0x41);
    await until(
      () => watch.idle && table.slotTable(room)!.slotsOf(0x41).length >= 5,
      'rooms back on the restarted server',
    );
    expect(watch.maxConcurrent, 1);
    final movedRooms = {
      for (final (slot, _, to) in watch.moves.skip(movesBefore))
        if (to == 0x41) slot,
    };
    final followers = [
      for (final m in members)
        if (movedRooms.contains(m.slot)) m,
    ];
    expect(followers, isNotEmpty);
    for (final m in members) {
      posted[m.name] = m.posted;
    }
    await until(
      () => members.every((m) => m.posted >= posted[m.name]! + 3),
      'members rejoined after the moves',
    );
    stop = true;
    await Future.wait(loops).timeout(limit);
    for (final m in followers) {
      expect(m.ends.last, StatusCode.relocated, reason: m.name);
    }

    // Every post is in its room once, in order; members see the room as
    // it is.
    await Future<void>.delayed(const Duration(milliseconds: 20));
    for (final member in members) {
      final history = storage[member.slot]!;
      expect(
        [
          for (final message in history)
            if (message.startsWith('${member.name}:')) message,
        ],
        [for (var n = 1; n <= member.posted; n++) '${member.name}:$n'],
      );
      expect(member.view, history, reason: member.name);
      await member.leave();
    }
  });
}
