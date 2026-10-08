/*
Polyverse Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Authors:
  Jan Boon <jan.boon@kaetemi.be>
  Claude Opus 5.5 <noreply@anthropic.com>
*/

import 'dart:async';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:stream_channel/stream_channel.dart';

import '../status.dart';
import 'transport_capabilities.dart';

final Logger _log = Logger('Switchboard.Transport');

/// In-memory transport pair, for tests and for connecting two endpoints in
/// the same isolate.
abstract final class MemoryTransport {
  /// Two connected transports. Frames added to one appear on the other.
  ///
  /// Frames are copied on [StreamSink.add], so the caller may reuse its
  /// buffer. With [delay], every frame (and the close) is delivered that
  /// much later, in order. With a positive [maxFrameSize], a frame longer
  /// than that fails the receiving side's stream with a [SwitchboardException]
  /// carrying [StatusCode.frameTooLarge] and ends it, mimicking what the
  /// stream binding does: the receiving side's sink stays writable until
  /// it is closed, or until its listener has seen the error and the end
  /// of the stream, so a mux layer can still send GOAWAY to the sender.
  /// Frames sent to the failed side are dropped. Both transports then
  /// implement [FrameLimited]. Null or 0 means no frame size limit.
  ///
  /// Closing one side's sink ends both streams. Errors added to a sink
  /// close the pair and complete that sink's `done` with the error.
  static (StreamChannel<Uint8List>, StreamChannel<Uint8List>) pair({
    Duration? delay,
    int? maxFrameSize,
  }) {
    final link = _MemoryLink(delay, maxFrameSize);
    return (link.a, link.b);
  }
}

class _MemoryLink {
  _MemoryLink(this.delay, this.maxFrameSize) {
    a = _MemoryEndpoint(this, 'a');
    b = _MemoryEndpoint(this, 'b');
    a.peer = b;
    b.peer = a;
  }

  final Duration? delay;
  final int? maxFrameSize;
  late final _MemoryEndpoint a;
  late final _MemoryEndpoint b;
  bool closed = false;
  final Set<Timer> _timers = {};

  void schedule(void Function() action) {
    final d = delay;
    if (d == null) {
      action();
      return;
    }
    late final Timer timer;
    timer = Timer(d, () {
      _timers.remove(timer);
      action();
    });
    _timers.add(timer);
  }

  /// Closes the pair on behalf of [from]: its own stream ends at once,
  /// the other side's stream ends after frames already in flight towards
  /// it (or at once when [immediate]).
  void close(_MemoryEndpoint from, {bool immediate = false}) {
    if (closed) {
      return;
    }
    closed = true;
    from.finish();
    if (immediate) {
      for (final t in _timers) {
        t.cancel();
      }
      _timers.clear();
      from.peer.finish();
    } else {
      schedule(from.peer.finish);
    }
  }
}

class _MemoryEndpoint
    with StreamChannelMixin<Uint8List>
    implements FrameLimited {
  _MemoryEndpoint(this.link, this.label) {
    _sink = _MemorySink(this);
  }

  final _MemoryLink link;
  final String label;
  late final _MemoryEndpoint peer;
  final StreamController<Uint8List> _incoming = StreamController<Uint8List>();
  // The sink is handed to the user, who closes it.
  // ignore: close_sinks
  late final _MemorySink _sink;
  final Completer<void> _done = Completer<void>();

  @override
  Stream<Uint8List> get stream => _incoming.stream;

  @override
  int get maxFrameSize => link.maxFrameSize ?? 0;

  @override
  StreamSink<Uint8List> get sink => _sink;

  void send(Uint8List frame) {
    if (link.closed) {
      return;
    }
    final copy = Uint8List.fromList(frame);
    final max = link.maxFrameSize;
    link.schedule(() {
      if (peer._incoming.isClosed) {
        return;
      }
      if (max != null && max > 0 && copy.length > max) {
        _log.warning(
          'memory transport $label: frame of ${copy.length} bytes exceeds '
          '$max',
        );
        peer.failIncoming(
          SwitchboardException.of(
            StatusCode.frameTooLarge,
            'frame of ${copy.length} bytes exceeds $max',
          ),
        );
        return;
      }
      peer._incoming.add(copy);
    });
  }

  /// Ends this side's stream with [error]. The pair stays open so that
  /// this side can still answer; it closes on this side's behalf once the
  /// listener has seen the error and the end.
  void failIncoming(Object error) {
    if (_incoming.isClosed) {
      return;
    }
    final listened = _incoming.hasListener;
    _incoming.addError(error);
    final closed = _incoming.close();
    if (listened) {
      closed.then((_) => link.close(this), onError: (_) {});
    } else {
      // Nobody to react: close at once, as the stream binding does.
      closed.ignore();
      link.close(this);
    }
  }

  void finish() {
    if (!_incoming.isClosed) {
      unawaited(_incoming.close());
    }
    if (!_done.isCompleted) {
      _done.complete();
    }
  }
}

class _MemorySink implements StreamSink<Uint8List> {
  _MemorySink(this.endpoint);

  final _MemoryEndpoint endpoint;
  bool _closed = false;

  /// [done] after [addError]: one future, failed with the error.
  Future<void>? _failed;

  @override
  void add(Uint8List event) {
    if (_closed) {
      throw StateError('memory transport sink is closed');
    }
    endpoint.send(event);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {
    if (_closed) {
      throw StateError('memory transport sink is closed');
    }
    _closed = true;
    // Reported to whoever awaits done, not as an unhandled error.
    _failed = Future<void>.error(error, stackTrace)..ignore();
    endpoint.link.close(endpoint, immediate: true);
  }

  @override
  Future<void> addStream(Stream<Uint8List> stream) async {
    await for (final frame in stream) {
      if (_closed) {
        break;
      }
      endpoint.send(frame);
    }
  }

  @override
  Future<void> close() {
    _closed = true;
    endpoint.link.close(endpoint);
    return done;
  }

  @override
  Future<void> get done => _failed ?? endpoint._done.future;
}
