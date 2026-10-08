/*
Polyverse Switchboard
Microservice Network Architecture
Copyright (C) 2018-2026  Jan BOON (Kaetemi)
Authors:
  Jan Boon <jan.boon@kaetemi.be>
  Claude Opus 5.5 <noreply@anthropic.com>
*/

part of 'talk_channel.dart';

/// What the payload of a bulk message is sent from: a byte stream, bytes
/// in memory, or the bulk channel of a message being forwarded.
class _BulkSource {
  _BulkSource.stream(Stream<List<int>> this._stream, this.length)
    : _bytes = null,
      _from = null;

  _BulkSource.bytes(Uint8List this._bytes)
    : _stream = null,
      _from = null,
      length = _bytes.length;

  _BulkSource.pipe(_BulkIn this._from)
    : _stream = null,
      _bytes = null,
      length = _from.length;

  final Stream<List<int>>? _stream;
  final Uint8List? _bytes;
  final _BulkIn? _from;

  /// The declared length; null when not known in advance.
  final int? length;
}

/// The status a bulk channel is closed with for [status]: a mux CLOSE
/// carries neither application codes nor OK for a failure.
Status _bulkCloseStatus(Status status) {
  if (status.isOk) {
    return Status.of(StatusCode.internal, 'bulk payload failed');
  }
  if (status.isApplicationCode) {
    return Status.of(
      StatusCode.unknown,
      'application status ${status.code}'
      '${status.reason.isEmpty ? '' : ': ${status.reason}'}',
    );
  }
  return status;
}

/// The status of an error a bulk source emitted.
Status _sourceStatus(Object error, StackTrace stackTrace) {
  if (error is SwitchboardException) {
    return error.status.isOk
        ? Status.of(StatusCode.internal, 'bulk source failed')
        : error.status;
  }
  _log.warning('bulk source failed', error, stackTrace);
  return Status.of(StatusCode.internal, 'bulk source failed');
}

/// One bulk payload this side sends: the bulk channel, and what feeds it.
class _BulkOut {
  _BulkOut(this.talk, this.channel, this.number, this.length);

  final TalkChannel talk;

  /// The bulk channel, opened in order with the parent's frames.
  final MuxChannel channel;

  /// The bulk number the reference carries.
  final int number;

  /// The declared length, null when unknown.
  final int? length;

  final Completer<void> _done = Completer<void>()..future.ignore();
  bool _stopped = false;
  StreamIterator<List<int>>? _iterator;

  /// Called each time a chunk was handed to the bulk channel (its window
  /// took it): the transfer progresses.
  void Function()? onProgress;

  void _progress() {
    final callback = onProgress;
    if (callback != null) {
      try {
        callback();
      } catch (e, st) {
        _log.severe('bulk progress callback failed', e, st);
      }
    }
  }

  _BulkIn? _from;

  /// Completes once the payload was sent whole and the bulk channel
  /// closed; fails with the status the transfer ended with otherwise.
  /// Never reports an unhandled error.
  Future<void> get done => _done.future;

  /// Starts sending from [source].
  void start(_BulkSource source) {
    talk._bulkOuts.add(this);
    unawaited(channel.done.then(_channelDone));
    final bytes = source._bytes;
    final stream = source._stream;
    if (bytes != null) {
      unawaited(_pumpStream(_pieces(bytes)));
    } else if (stream != null) {
      unawaited(_pumpStream(stream));
    } else {
      _pipeFrom(source._from!);
    }
  }

  /// Stops the transfer: closes the bulk channel with [status] (the
  /// source, if any, is cancelled; a forwarded payload's own bulk channel
  /// is closed with it too).
  void cancel(Status status) {
    if (_stopped) {
      return;
    }
    _stopped = true;
    _stopSource();
    _from?.close(status);
    unawaited(channel.close(_bulkCloseStatus(status)));
  }

  void _stopSource() {
    final iterator = _iterator;
    _iterator = null;
    if (iterator != null) {
      iterator.cancel().then<void>(
        (_) {},
        onError: (Object e, StackTrace st) =>
            _log.fine('cancelling a bulk source failed', e, st),
      );
    }
    _from?._detach();
  }

  /// The payload went whole ([failure] null) or failed: closes the bulk
  /// channel accordingly.
  void _finish(Status? failure) {
    if (_stopped) {
      return;
    }
    _stopped = true;
    _stopSource();
    if (failure != null) {
      _log.fine('bulk payload $number failed: $failure');
      _from?.close(failure);
    }
    unawaited(
      channel.close(failure == null ? Status.ok : _bulkCloseStatus(failure)),
    );
  }

  void _channelDone(Status status) {
    talk._bulkOuts.remove(this);
    if (!_stopped) {
      // The receiver closed it (it does not want the rest), or the
      // connection ended.
      _stopped = true;
      _stopSource();
      _from?.close(status);
    }
    if (status.isOk) {
      _done.complete();
    } else {
      _done.completeError(SwitchboardException(status));
    }
  }

  /// [bytes] as views of [TalkOptions.bulkChunkSize] bytes, without a
  /// copy.
  Stream<List<int>> _pieces(Uint8List bytes) {
    final chunk = talk.options.bulkChunkSize;
    return Stream<List<int>>.fromIterable([
      for (var offset = 0; offset < bytes.length; offset += chunk)
        Uint8List.sublistView(
          bytes,
          offset,
          offset + chunk < bytes.length ? offset + chunk : bytes.length,
        ),
    ]);
  }

  Future<void> _pumpStream(Stream<List<int>> source) async {
    final iterator = _iterator = StreamIterator<List<int>>(source);
    final chunk = talk.options.bulkChunkSize;
    final parts = Queue<Uint8List>();
    var held = 0;
    var total = 0;
    Status? failure;
    try {
      while (!_stopped && await iterator.moveNext()) {
        if (_stopped) {
          break;
        }
        final data = iterator.current;
        final bytes = data is Uint8List ? data : Uint8List.fromList(data);
        total += bytes.length;
        final declared = length;
        if (declared != null && total > declared) {
          failure = Status.of(
            StatusCode.invalidArgument,
            'the bulk source produced more than the $declared bytes declared',
          );
          break;
        }
        if (bytes.isNotEmpty) {
          parts.add(bytes);
          held += bytes.length;
        }
        while (held >= chunk && !_stopped) {
          final piece = _take(parts, chunk);
          held -= piece.length;
          await channel.send(piece);
          _progress();
        }
      }
      if (!_stopped && failure == null) {
        final declared = length;
        if (declared != null && total != declared) {
          failure = Status.of(
            StatusCode.invalidArgument,
            'the bulk source produced $total bytes, $declared declared',
          );
        } else {
          while (held > 0 && !_stopped) {
            final piece = _take(parts, held < chunk ? held : chunk);
            held -= piece.length;
            await channel.send(piece);
            _progress();
          }
        }
      }
    } on SwitchboardException catch (e) {
      // The bulk channel stopped (the receiver closed it, the connection
      // ended), or refused a chunk.
      if (!_stopped) {
        failure = e.status;
      }
    } catch (e, st) {
      if (!_stopped) {
        failure = _sourceStatus(e, st);
      }
    }
    if (identical(_iterator, iterator)) {
      _iterator = null;
      unawaited(
        iterator.cancel().then<void>(
          (_) {},
          onError: (Object e, StackTrace st) =>
              _log.fine('cancelling a bulk source failed', e, st),
        ),
      );
    }
    _finish(failure);
  }

  /// The first [n] bytes of [parts], removed from them.
  static Uint8List _take(Queue<Uint8List> parts, int n) {
    final first = parts.first;
    if (first.length == n) {
      parts.removeFirst();
      return first;
    }
    if (first.length > n) {
      parts
        ..removeFirst()
        ..addFirst(Uint8List.sublistView(first, n));
      return Uint8List.sublistView(first, 0, n);
    }
    final out = Uint8List(n);
    var offset = 0;
    while (offset < n) {
      final part = parts.removeFirst();
      final take = part.length <= n - offset ? part.length : n - offset;
      out.setRange(offset, offset + take, part);
      offset += take;
      if (take < part.length) {
        parts.addFirst(Uint8List.sublistView(part, take));
      }
    }
    return out;
  }

  /// Forwards the bytes of [from], a bulk channel of a message being
  /// forwarded, with credit passed through: what [from] received counts as
  /// consumed once this channel's send took it.
  void _pipeFrom(_BulkIn from) {
    _from = from;
    from._grant();
    var received = 0;
    from._attach(
      (data) {
        final length = data.length;
        received += length;
        final declared = from.length;
        if (declared != null && received > declared) {
          from._consume(length);
          _finish(
            Status.of(
              StatusCode.protocolError,
              'bulk payload longer than the $declared bytes declared',
            ),
          );
          return;
        }
        if (_stopped || !channel.canSend) {
          from._consume(length);
          return;
        }
        try {
          channel
              .send(data)
              .then(
                (_) => from._consume(length),
                onError: (Object _) => from._consume(length),
              );
        } on SwitchboardException catch (e) {
          from._consume(length);
          _finish(e.status);
        }
      },
      (status) {
        final declared = from.length;
        if (!status.isOk) {
          _finish(status);
        } else if (declared != null && received != declared) {
          _finish(
            Status.of(
              StatusCode.protocolError,
              'bulk payload of $received bytes, $declared declared',
            ),
          );
        } else {
          _finish(null);
        }
      },
    );
  }
}

/// One bulk payload the peer sends this side: the bulk channel it arrived
/// on, adopted for a parent channel and claimed by the message that
/// references it.
///
/// Read from adoption on, in manual credit: what arrives before a reader
/// takes it waits here, bounded by the bulk channel's window and, like
/// everything Talk holds, left out of the connection's receive high-water
/// mark, so that payloads nobody reads yet cannot pause the connection.
class _BulkIn {
  _BulkIn(this.talk, this.channel, this.number) {
    // Never paused nor cancelled: it ends with the bulk channel, and what
    // arrives for nobody is dropped (and consumed) here.
    channel.stream.listen(_onChunk, onDone: _onEnd);
  }

  final TalkChannel talk;

  /// The bulk channel, in manual credit: its subframes are consumed as
  /// the reader takes them.
  final MuxChannel channel;

  /// The bulk number of its OPEN.
  final int number;

  /// The declared length, once claimed; null when unknown.
  int? length;

  /// What arrived before a reader was attached.
  final Queue<Uint8List> _buffer = Queue<Uint8List>();

  /// The attached reader, if any.
  void Function(Uint8List data)? _onData;
  void Function(Status status)? _onDone;

  /// Whether something reads it (the application's stream, the
  /// reassembly, a forwarding pipe), or it was abandoned.
  bool _read = false;

  /// Abandoned, or its reader gone: what arrives is dropped.
  bool _dropping = false;

  /// The bulk channel's end status, once known.
  Status? _endStatus;

  /// Bounds the wait of an unclaimed bulk channel for its message.
  Timer? unclaimedTimer;

  /// Called each time the reader took a chunk: the transfer progresses.
  void Function()? onProgress;

  void _onChunk(Uint8List data) {
    if (_dropping) {
      _consume(data.length);
      return;
    }
    final onData = _onData;
    if (onData == null) {
      _buffer.add(data);
      return;
    }
    onData(data);
  }

  void _onEnd() {
    talk._bulkIns.remove(this);
    unawaited(
      channel.done.then((status) {
        _endStatus = status;
        if (!_dropping) {
          _onDone?.call(status);
        }
      }),
    );
  }

  /// Attaches the reader: [onData] gets what arrived so far and every
  /// later chunk, [onDone] the bulk channel's end status after the last.
  void _attach(
    void Function(Uint8List data) onData,
    void Function(Status status) onDone,
  ) {
    _read = true;
    _onData = onData;
    _onDone = onDone;
    while (_buffer.isNotEmpty && identical(_onData, onData)) {
      onData(_buffer.removeFirst());
    }
    final status = _endStatus;
    if (status != null && identical(_onDone, onDone) && !_dropping) {
      onDone(status);
    }
  }

  /// The reader went away: what arrives from now on is dropped.
  void _detach() {
    _dropping = true;
    _onData = null;
    _onDone = null;
    _dropBuffer();
  }

  void _dropBuffer() {
    var bytes = 0;
    final frames = _buffer.length;
    for (final chunk in _buffer) {
      bytes += chunk.length;
    }
    _buffer.clear();
    if (frames > 0) {
      try {
        channel.consumed(bytes, subframes: frames);
      } on StateError catch (e) {
        _log.warning('bulk credit accounting: $e');
      }
    }
  }

  /// Closes the bulk channel with [status] if it is still open: the
  /// receiver does not want the rest, or the message or channel it belongs
  /// to ended.
  void close(Status status) {
    if (channel.state == MuxChannelState.open) {
      unawaited(channel.close(_bulkCloseStatus(status)));
    }
  }

  /// Nobody will read it: closes it `CANCELLED` if it is still in transfer
  /// and drops what it holds.
  void abandon() {
    unclaimedTimer?.cancel();
    unclaimedTimer = null;
    if (_read) {
      return;
    }
    _read = true;
    talk._bulkIns.remove(this);
    close(Status.of(StatusCode.cancelled, 'bulk payload not read'));
    _detach();
  }

  /// Raises the window to the declared length, up to
  /// [TalkOptions.bulkWindow]: the reader is ready for more than the
  /// initial window.
  void _grant() {
    final declared = length;
    if (declared == null) {
      return;
    }
    final cap = talk.options.bulkWindow;
    final want = declared < cap ? declared : cap;
    final extra = want - channel.connection.options.initialWindow;
    if (extra > 0) {
      try {
        channel.grant(extra);
      } on ArgumentError catch (e) {
        _log.fine('bulk window not raised: $e');
      }
    }
  }

  /// The payload as a byte stream, once: ends with an error if the
  /// transfer failed (the sender's status, `PROTOCOL_ERROR` for another
  /// length than declared, `CONNECTION_LOST`). Credit for each chunk goes
  /// back when the listener takes it; cancelling the subscription closes
  /// the bulk channel `CANCELLED`. Throws [StateError] the second time.
  Stream<Uint8List> stream() {
    if (_read) {
      throw StateError('the bulk payload is read already');
    }
    _read = true;
    var received = 0;
    var finished = false;
    late final StreamController<Uint8List> controller;
    void fail(Status status) {
      finished = true;
      close(status);
      _detach();
      if (!controller.isClosed) {
        controller
          ..addError(SwitchboardException(status))
          ..close().ignore();
      }
    }

    controller = StreamController<Uint8List>(
      onListen: () {
        _grant();
        _attach(
          (data) {
            if (controller.isClosed) {
              _consume(data.length);
              return;
            }
            received += data.length;
            final declared = length;
            if (declared != null && received > declared) {
              _consume(data.length);
              fail(
                Status.of(
                  StatusCode.protocolError,
                  'bulk payload longer than the $declared bytes declared',
                ),
              );
              return;
            }
            controller.add(data);
          },
          (status) {
            finished = true;
            if (controller.isClosed) {
              return;
            }
            final declared = length;
            if (!status.isOk) {
              controller.addError(SwitchboardException(status));
            } else if (declared != null && received != declared) {
              controller.addError(
                SwitchboardException.of(
                  StatusCode.protocolError,
                  'bulk payload of $received bytes, $declared declared',
                ),
              );
            }
            controller.close().ignore();
          },
        );
      },
      onCancel: () {
        if (!finished) {
          close(Status.of(StatusCode.cancelled, 'bulk payload not wanted'));
          _detach();
        }
      },
    );
    return _BulkStream(controller.stream, this);
  }

  void _consume(int length) {
    try {
      channel.consumed(length);
    } on StateError catch (e) {
      _log.warning('bulk credit accounting: $e');
    }
  }

  /// The reader took a chunk.
  void _taken(int length) {
    _consume(length);
    final callback = onProgress;
    if (callback != null) {
      try {
        callback();
      } catch (e, st) {
        _log.severe('bulk progress callback failed', e, st);
      }
    }
  }

  /// Reads the whole payload, at most [max] bytes: beyond, the bulk channel
  /// is closed `RESOURCE_EXHAUSTED` and the future fails with it.
  Future<Uint8List> collect(int max) {
    final completer = Completer<Uint8List>()..future.ignore();
    final declared = length;
    if (declared != null && declared > max) {
      final status = Status.of(
        StatusCode.resourceExhausted,
        'bulk payload of $declared bytes, more than $max',
      );
      _read = true;
      talk._bulkIns.remove(this);
      close(status);
      _detach();
      completer.completeError(SwitchboardException(status));
      return completer.future;
    }
    final builder = BytesBuilder(copy: false);
    late final StreamSubscription<Uint8List> subscription;
    subscription = stream().listen(
      (data) {
        if (completer.isCompleted) {
          return;
        }
        if (builder.length + data.length > max) {
          final status = Status.of(
            StatusCode.resourceExhausted,
            'bulk payload of more than $max bytes',
          );
          close(status);
          subscription.cancel().ignore();
          completer.completeError(SwitchboardException(status));
          return;
        }
        builder.add(data);
      },
      onError: (Object error) {
        if (!completer.isCompleted) {
          completer.completeError(
            error is SwitchboardException
                ? error
                : SwitchboardException.of(StatusCode.internal, '$error'),
          );
        }
      },
      onDone: () {
        if (!completer.isCompleted) {
          completer.complete(builder.takeBytes());
        }
      },
      cancelOnError: true,
    );
    return completer.future;
  }
}

/// The stream of a bulk payload as the application sees it: each chunk's
/// credit goes back to the sender when the listener takes it.
class _BulkStream extends Stream<Uint8List> {
  _BulkStream(this._source, this._bulk);

  final Stream<Uint8List> _source;
  final _BulkIn _bulk;

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return _BulkSubscription(
      _source.listen(
        null,
        onError: onError,
        onDone: onDone,
        cancelOnError: cancelOnError,
      ),
      _bulk,
    )..onData(onData);
  }
}

class _BulkSubscription extends DelegatingStreamSubscription<Uint8List> {
  _BulkSubscription(super.sourceSubscription, this._bulk);

  final _BulkIn _bulk;

  @override
  void onData(void Function(Uint8List data)? handleData) {
    super.onData((data) {
      _bulk._taken(data.length);
      handleData?.call(data);
    });
  }
}

/// A message whose bulk channel has not been adopted yet (its OPEN came
/// first on the wire, but dispatch may lag): delivered, or dropped, when it
/// arrives. Bounded by [TalkOptions.bulkOpenTimeout].
class _Awaited {
  _Awaited(this.message, this.timer);

  /// Null when the message was dropped: the bulk channel is closed when it
  /// arrives.
  final _Message? message;
  final Timer timer;
}

/// Deliveries that must keep their order while some wait for a bulk
/// payload: the messages of [TalkChannel.messages], or what answers one
/// request. Each entry is delivered once it and everything before it is
/// ready.
class _Lane {
  final Queue<(_Message?, void Function())> _queue =
      Queue<(_Message?, void Function())>();
  bool _advancing = false;

  /// Whether deliveries wait here.
  bool get isWaiting => _queue.isNotEmpty;

  /// Delivers [deliver] now if nothing waits and [message] (null for a
  /// delivery without a payload) is ready, else in its turn.
  void add(_Message? message, void Function() deliver) {
    if (_queue.isEmpty && (message == null || message._ready)) {
      deliver();
      return;
    }
    message?._lane = this;
    _queue.add((message, deliver));
    advance();
  }

  /// Delivers what is ready at the head.
  void advance() {
    if (_advancing) {
      return;
    }
    _advancing = true;
    try {
      while (_queue.isNotEmpty) {
        final (message, deliver) = _queue.first;
        if (message != null && !message._ready) {
          return;
        }
        _queue.removeFirst();
        deliver();
      }
    } finally {
      _advancing = false;
    }
  }

  /// Delivers what is ready, in order, dropping (with their bulk payloads
  /// and credit) the entries that wait.
  void flush() {
    final entries = List.of(_queue);
    _queue.clear();
    for (final (message, deliver) in entries) {
      if (message == null || message._ready) {
        deliver();
      } else {
        message._drop();
      }
    }
  }

  /// Drops everything waiting, with bulk payloads and credit.
  void drop() {
    final entries = List.of(_queue);
    _queue.clear();
    for (final (message, _) in entries) {
      message?._drop();
    }
  }

  /// Nobody will read incoming messages. Keep ordered answers, which
  /// still belong to their requests, but refuse and drop everything else.
  void dropIncoming(Status status) {
    final entries = List.of(_queue);
    _queue.clear();
    for (final entry in entries) {
      final message = entry.$1;
      if (message != null && !message.frame.hasResponse) {
        message._abortQuietly(status);
        message._drop();
      } else {
        _queue.add(entry);
      }
    }
    advance();
  }
}
