/*
Polyverse Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Authors:
  Jan Boon <jan.boon@kaetemi.be>
  GPT-6 Astra <noreply@anthropic.com>
*/

/// Bounded identity holds shared by node dispatch and the relay.
/// Internal to the package; not exported.
library;

import 'dart:async';

import '../mux/mux_channel.dart';
import '../mux/mux_connection.dart';

final Expando<_IdentityWaiters> _waiters = Expando<_IdentityWaiters>(
  'identity waiters',
);

/// Waits until the identity changes, [channel] ends, or [timeout] passes.
///
/// Only one listener is attached to a connection's next identity event.
/// Closed or timed-out channels remove their waiters: an unidentified peer
/// opening and closing channels must not accumulate listeners on a future
/// that may never complete.
Future<void> waitForIdentityChange(MuxChannel channel, Duration timeout) {
  final connection = channel.connection;
  return (_waiters[connection] ??= _IdentityWaiters(
    connection,
  )).wait(channel, timeout);
}

class _IdentityWaiters {
  _IdentityWaiters(this.connection);

  final MuxConnection connection;
  final Set<Completer<void>> _waiting = {};
  bool _listening = false;

  Future<void> wait(MuxChannel channel, Duration timeout) async {
    final done = Completer<void>();
    _waiting.add(done);
    if (!_listening) {
      _listening = true;
      unawaited(
        connection.identityChanged.then((_) {
          _listening = false;
          for (final waiter in _waiting) {
            waiter.complete();
          }
          _waiting.clear();
        }),
      );
    }
    void finish() {
      if (_waiting.remove(done)) {
        done.complete();
      }
    }

    final timer = Timer(timeout, finish);
    unawaited(channel.done.then((_) => finish()));
    try {
      await done.future;
    } finally {
      timer.cancel();
      _waiting.remove(done);
    }
  }
}
