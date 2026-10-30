import 'dart:async';

import 'package:jni/jni.dart';

import '../../exceptions/file_saver_exceptions.dart';
import '../../models/file_saver_sink.dart';
import '../shared/session_file_saver_sink.dart';
import 'bindings.g.dart' as bindings;

/// Android implementation of [FileSaverSink], over a JNI write session in
/// `FileSaver.kt`.
class AndroidFileSaverSink extends SessionFileSaverSink {
  AndroidFileSaverSink({
    required bindings.FileSaver fileSaver,
    required int sessionId,
    int? totalSize,
  }) : super(_AndroidWriteSession(fileSaver, sessionId), totalSize);
}

/// The JNI calls of one write session.
///
/// Each call uses a one-shot [bindings.ProgressCallback] that is released via
/// [Future.microtask] after its event fires. It must not reference the sink,
/// so the sink can be garbage collected and its session cancelled.
class _AndroidWriteSession implements WriteSession {
  _AndroidWriteSession(this._fileSaver, this._sessionId);

  final bindings.FileSaver _fileSaver;
  final int _sessionId;

  @override
  Future<int> write(List<int> data) async {
    final (bytesWritten, _) = await _call((callback) {
      // Kotlin keeps its own reference to the array.
      final jData = JByteArray.of(data);
      _fileSaver.writeChunk(_sessionId, jData, callback);
      jData.release();
    });
    return bytesWritten.toInt();
  }

  @override
  Future<void> flush() async {
    await _call((callback) => _fileSaver.flushSession(_sessionId, callback));
  }

  @override
  Future<Uri> close() async {
    final (_, uri) = await _call(
      (callback) => _fileSaver.closeSession(_sessionId, callback),
    );
    return Uri.parse(uri ?? '');
  }

  @override
  Future<void> cancel() async => _fileSaver.cancelSession(_sessionId);

  /// Runs [start] synchronously with a callback and completes with the
  /// progress and data of the event it reports, or fails with the
  /// [FileSaverException] of an error event.
  Future<(double, String?)> _call(
    void Function(bindings.ProgressCallback callback) start,
  ) {
    final completer = Completer<(double, String?)>();
    bindings.ProgressCallback? callback;
    callback = bindings.ProgressCallback.implement(
      bindings.$ProgressCallback(
        onEvent: (eventType, progress, jStr1, jStr2) {
          final data = jStr1?.toDartString(releaseOriginal: true);
          final message = jStr2?.toDartString(releaseOriginal: true);
          if (!completer.isCompleted) {
            if (eventType == 2) {
              completer.completeError(
                FileSaverException.fromErrorResult(
                  data ?? 'UNKNOWN',
                  message ?? '',
                ),
              );
            } else {
              completer.complete((progress, data));
            }
          }
          Future.microtask(() => callback?.release());
        },
        onEvent$async: true,
      ),
    );
    start(callback);
    return completer.future;
  }
}
