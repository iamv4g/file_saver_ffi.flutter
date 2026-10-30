import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import '../../exceptions/file_saver_exceptions.dart';
import '../../models/file_saver_sink.dart';

/// One write session, as driven by [SessionFileSaverSink].
///
/// Implemented over JNI on Android, FFI on Darwin, and `dart:io` for
/// Windows, Linux and `PathLocation`. Kept free of platform imports so the
/// sink can be unit tested.
abstract interface class WriteSession {
  /// Writes [data] and completes with the session's total bytes written.
  ///
  /// Copies [data] before returning, so the caller may reuse it. Fails with
  /// a [FileSaverException]. The sink never calls it again while a write is
  /// pending.
  Future<int> write(List<int> data);

  /// Flushes the written data to storage. Fails with a [FileSaverException].
  Future<void> flush();

  /// Finishes the file and completes with its URI.
  ///
  /// Fails with a [FileSaverException], and then the file is deleted. This
  /// includes the case where an earlier write failed.
  Future<Uri> close();

  /// Ends the session and deletes the file. Completes once the file is
  /// deleted, or at once where the platform doesn't report it. Never fails.
  ///
  /// May be called while a write is pending.
  Future<void> cancel();
}

/// The [FileSaverSink] of a [WriteSession].
///
/// Writes reach the session one at a time, in order. Chunks passed to [add]
/// while a write is pending are copied and sent together once it completes,
/// so a producer that adds faster than storage accepts grows Dart memory
/// (visible to the Dart GC) instead of the native heap. [flush] waits for
/// them.
///
/// The first failed write fails the sink: later chunks are dropped, and
/// [addStream], [flush], [close], [done] and [result] report that error.
/// A sink that is garbage collected before [close] or [cancel] cancels its
/// session.
class SessionFileSaverSink implements FileSaverSink {
  /// [_totalSize] is the expected file size for [progress], if known.
  SessionFileSaverSink(this._session, this._totalSize) {
    // A failure is reported by whichever of close(), done and result the
    // caller awaits, so none of them may count as unhandled.
    _result.future.ignore();
    _done.future.ignore();
    _finalizer.attach(this, _session, detach: this);
  }

  static final _finalizer = Finalizer<WriteSession>(
    (session) => session.cancel().ignore(),
  );

  /// Upper bound for chunks [add] combines into one native write.
  static const _maxBatchBytes = 1024 * 1024;

  final WriteSession _session;
  final int? _totalSize;

  /// Set by [close], [cancel] and [addError]; no more data is accepted.
  bool _isClosed = false;
  bool _isCancelled = false;
  bool _isAddingStream = false;

  /// Runs while a write is pending, then sends what [add] queued meanwhile.
  Future<void>? _writer;
  final _queue = Queue<Uint8List>();

  /// The first failed write.
  (Object, StackTrace)? _failure;

  final _progressController = StreamController<double>.broadcast();
  final _bytesController = StreamController<int>.broadcast();
  final _result = Completer<Uri>();
  final _done = Completer<void>();

  // ─────────────────────────────────────────────────────────────────────────
  // FileSaverSink interface
  // ─────────────────────────────────────────────────────────────────────────

  @override
  Stream<double> get progress => _progressController.stream;

  @override
  Stream<int> get bytesWritten => _bytesController.stream;

  @override
  Future<Uri> get result => _result.future;

  @override
  Future<void> get done => _done.future;

  // ─────────────────────────────────────────────────────────────────────────
  // StreamSink<List<int>>
  // ─────────────────────────────────────────────────────────────────────────

  @override
  void add(List<int> data) {
    _checkWritable('add');
    _write(data);
  }

  /// Ends the session with [error]: the file is deleted, and [done] and
  /// [result] fail with [error].
  @override
  void addError(Object error, [StackTrace? stackTrace]) {
    _checkWritable('addError');
    _discard().ignore();
    _finishWithError(error, stackTrace ?? StackTrace.current);
  }

  @override
  Future addStream(Stream<List<int>> stream) async {
    _checkWritable('addStream');
    _isAddingStream = true;
    try {
      await for (final chunk in stream) {
        if (_isCancelled) break;
        _write(chunk);
        await _writer;
        _throwIfFailed();
      }
    } finally {
      _isAddingStream = false;
    }
  }

  /// Waits for every chunk added so far, then flushes the session.
  @override
  Future<void> flush() async {
    _checkWritable('flush');
    await _writer;
    _throwIfFailed();
    try {
      await _session.flush();
    } catch (e, st) {
      _failure ??= (e, st);
      rethrow;
    }
  }

  /// Writes what is still queued, finishes the file and completes with its
  /// URI, like [result].
  @override
  Future<Uri> close() {
    if (_isAddingStream) {
      throw StateError('Cannot close a FileSaverSink while addStream runs');
    }
    if (!_isClosed) {
      _isClosed = true;
      _finalizer.detach(this);
      _finish();
    }
    return result;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // cancel
  // ─────────────────────────────────────────────────────────────────────────

  @override
  Future<void> cancel() async {
    if (_isClosed) return;
    final discarded = _discard();
    _closeStreams();
    _result.completeError(const CancelledException());
    _done.complete();
    await discarded;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Private helpers
  // ─────────────────────────────────────────────────────────────────────────

  void _checkWritable(String operation) {
    if (_isClosed) {
      throw StateError('Cannot $operation on a closed FileSaverSink');
    }
    if (_isAddingStream) {
      throw StateError('Cannot $operation while addStream runs');
    }
  }

  void _throwIfFailed() {
    final failure = _failure;
    if (failure != null) Error.throwWithStackTrace(failure.$1, failure.$2);
  }

  /// Sends [data] now if no write is pending, or queues a copy of it.
  void _write(List<int> data) {
    if (_failure != null) return;
    if (_writer == null) {
      _writer = _runWriter(Future.sync(() => _session.write(data)));
    } else {
      _queue.add(Uint8List.fromList(data));
    }
  }

  Future<void> _runWriter(Future<int> write) async {
    try {
      while (true) {
        _reportBytes(await write);
        if (_queue.isEmpty || _isCancelled) break;
        final batch = _takeBatch();
        write = Future.sync(() => _session.write(batch));
      }
    } catch (e, st) {
      _failure ??= (e, st);
      _queue.clear();
    } finally {
      _writer = null;
    }
  }

  /// Removes queued chunks up to [_maxBatchBytes] and joins them.
  Uint8List _takeBatch() {
    final first = _queue.removeFirst();
    if (_queue.isEmpty || first.length >= _maxBatchBytes) return first;
    final builder = BytesBuilder(copy: false)..add(first);
    while (_queue.isNotEmpty &&
        builder.length + _queue.first.length <= _maxBatchBytes) {
      builder.add(_queue.removeFirst());
    }
    return builder.takeBytes();
  }

  void _reportBytes(int bytes) {
    if (_bytesController.isClosed) return;
    _bytesController.add(bytes);
    final total = _totalSize;
    if (total != null && total > 0) _progressController.add(bytes / total);
  }

  Future<void> _finish() async {
    await _writer;
    final failure = _failure;
    if (failure != null) {
      await _session.cancel();
      return _finishWithError(failure.$1, failure.$2);
    }
    try {
      final uri = await _session.close();
      _closeStreams();
      _result.complete(uri);
      _done.complete();
    } catch (e, st) {
      _finishWithError(e, st);
    }
  }

  /// Marks the sink closed and cancels the session, keeping no queued data.
  Future<void> _discard() {
    _isClosed = true;
    _isCancelled = true;
    _finalizer.detach(this);
    _queue.clear();
    return _session.cancel();
  }

  void _finishWithError(Object error, StackTrace stackTrace) {
    _closeStreams();
    _result.completeError(error, stackTrace);
    _done.completeError(error, stackTrace);
  }

  void _closeStreams() {
    _progressController.close().ignore();
    _bytesController.close().ignore();
  }
}
