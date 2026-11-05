import 'dart:async';

import 'package:jni/jni.dart';

import '../../models/file_saver_sink.dart';
import '../shared/session_file_saver_sink.dart';
import 'bindings.g.dart' as bindings;
import 'jni_reply.dart';

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
    final (bytesWritten, _) = await callForJniReply((arena, callback) {
      // Kotlin keeps its own reference to the array.
      final jData = JByteArray.of(data)..releasedBy(arena);
      _fileSaver.writeChunk(_sessionId, jData, callback);
    });
    return bytesWritten.toInt();
  }

  @override
  Future<void> flush() async {
    await callForJniReply(
      (_, callback) => _fileSaver.flushSession(_sessionId, callback),
    );
  }

  @override
  Future<Uri> close() async {
    final (_, uri) = await callForJniReply(
      (_, callback) => _fileSaver.closeSession(_sessionId, callback),
    );
    return Uri.parse(uri ?? '');
  }

  @override
  Future<void> cancel() async => _fileSaver.cancelSession(_sessionId);
}
