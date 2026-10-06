/*
Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Author: Jan Boon <jan.boon@kaetemi.be>
*/

/// The isolate-wide registry of in-process (`mem://`) listeners behind
/// `Switchboard.listenMemory`. Internal to the package; not exported.
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:stream_channel/stream_channel.dart';

import '../status.dart';

/// Takes one side of a new in-memory transport pair as an accepted
/// connection. [remote] describes the initiator, for logs.
typedef MemoryAcceptor = void Function(
  StreamChannel<Uint8List> transport,
  String remote,
);

/// The `mem://<id>` listeners of this isolate, by id.
///
/// A static map: every `Switchboard` of the isolate sees the same
/// listeners, and nothing outside the isolate does. Ids are compared in
/// lower case, as URI hosts are.
abstract final class MemoryEndpoints {
  /// The URI scheme of in-process endpoints.
  static const String scheme = 'mem';

  static final Map<String, MemoryAcceptor> _acceptors = {};
  static final Random _random = Random();
  static int _counter = 0;

  static final RegExp _validName = RegExp(r'^[A-Za-z0-9._~-]+$');

  /// Registers [acceptor] under [name] (lower-cased), or under a new id
  /// unique in this isolate when [name] is null, and returns its
  /// `mem://<id>` URI.
  ///
  /// Throws [ArgumentError] if [name] is empty or has characters other
  /// than ASCII letters, digits, `.`, `_`, `~` and `-`, and
  /// [SwitchboardException] with [StatusCode.alreadyExists] if a listener
  /// of this isolate already has that id.
  static Uri register(MemoryAcceptor acceptor, {String? name}) {
    final String id;
    if (name != null) {
      if (!_validName.hasMatch(name)) {
        throw ArgumentError.value(
          name,
          'name',
          'must be ASCII letters, digits, ".", "_", "~" or "-"',
        );
      }
      id = name.toLowerCase();
      if (_acceptors.containsKey(id)) {
        throw SwitchboardException.of(
          StatusCode.alreadyExists,
          'memory endpoint $scheme://$id is already listening',
        );
      }
    } else {
      id = _generateId();
    }
    _acceptors[id] = acceptor;
    return Uri(scheme: scheme, host: id);
  }

  /// A fresh id: a counter, unique in this isolate, and a random suffix,
  /// so that ids of different runs or isolates are unlikely to match. Never
  /// an id in use (a name given to [register] may look like one).
  static String _generateId() {
    while (true) {
      _counter++;
      final suffix = _random.nextInt(1 << 24).toRadixString(16).padLeft(6, '0');
      final id = 'sb$_counter-$suffix';
      if (!_acceptors.containsKey(id)) {
        return id;
      }
    }
  }

  /// The acceptor listening at [id] (compared in lower case), or null.
  static MemoryAcceptor? lookup(String id) => _acceptors[id.toLowerCase()];

  /// Removes the listener at [id], if any.
  static void unregister(String id) => _acceptors.remove(id.toLowerCase());

  /// The ids listening now. For tests: empty once every node that listened
  /// has closed.
  static Iterable<String> get ids => List.unmodifiable(_acceptors.keys);
}
