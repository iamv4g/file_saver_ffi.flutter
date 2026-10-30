import 'dart:async';

import '../exceptions/file_saver_exceptions.dart';

/// A session-based streaming sink for writing file data incrementally.
///
/// Obtain via [FileSaver.openWrite] or [FileSaver.openWriteAs].
///
/// Call [add] or [addStream] to write chunks of bytes, then [close] to
/// finalize the file and receive its [Uri]. Use [cancel] to abort and discard
/// the partially written file.
///
/// [progress] emits 0.0–1.0 only if [totalSize] was provided at open time.
/// [bytesWritten] always emits the cumulative byte count as chunks are written.
///
/// Example:
/// ```dart
/// final sink = await FileSaver.openWrite(
///   fileName: 'recording',
///   fileType: CustomFileType('mp4', 'video/mp4'),
///   totalSize: expectedBytes,
/// );
///
/// if (sink == null) return; // skip: the file exists
///
/// sink.progress.listen((p) => setState(() => _progress = p));
///
/// await sink.addStream(chunkStream);
/// final uri = await sink.close();
/// ```
abstract interface class FileSaverSink implements StreamSink<List<int>> {
  /// Emits fraction 0.0–1.0 as chunks reach storage, like [bytesWritten].
  ///
  /// Only emits if [totalSize] was provided to [openWrite] or [openWriteAs].
  /// The stream is broadcast — multiple listeners are allowed.
  Stream<double> get progress;

  /// Emits cumulative bytes written as chunks reach storage.
  ///
  /// Chunks added while a write is running may be written, and counted,
  /// together. Always emits regardless of whether [totalSize] was provided.
  /// The stream is broadcast — multiple listeners are allowed.
  Stream<int> get bytesWritten;

  /// Flushes any buffered data to the underlying storage.
  Future<void> flush();

  /// Cancels the session, discarding any written data.
  ///
  /// The partially-written file is deleted on all platforms.
  /// Subsequent calls to [add] will throw [StateError].
  Future<void> cancel();

  /// Resolves with the [Uri] of the saved file after [close] completes.
  ///
  /// Throws if the sink was cancelled or an error occurred.
  Future<Uri> get result;

  /// Writes what is still queued, finishes the file and completes with its
  /// [Uri], the same value as [result].
  ///
  /// Throws the error of a failed write, or why the file couldn't be
  /// finished; the partial file is then deleted. After [cancel], throws
  /// [CancelledException]. Throws [StateError] while [addStream] runs.
  /// Calling it again returns the same result.
  @override
  Future<Uri> close();

  // Inherited from StreamSink<List<int>>:
  //   void add(List<int> data)                        — write a chunk (non-blocking)
  //   void addError(Object error, [StackTrace?])       — propagate an error
  //   Future addStream(Stream<List<int>> stream)       — pipe a stream of chunks
  //   Future get done                                  — completes when closed/errored
}
