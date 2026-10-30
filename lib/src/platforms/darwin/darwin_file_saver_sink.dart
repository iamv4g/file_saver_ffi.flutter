import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import '../../exceptions/file_saver_exceptions.dart';
import '../../models/file_saver_sink.dart';
import '../shared/session_file_saver_sink.dart';
import 'bindings.g.dart';

/// Darwin (iOS / macOS) implementation of [FileSaverSink], over an FFI write
/// session in `FileSaverFFI.swift`.
class DarwinFileSaverSink extends SessionFileSaverSink {
  DarwinFileSaverSink({
    required FileSaverFFI fileSaver,
    required int sessionId,
    int? totalSize,
  }) : super(_DarwinWriteSession(fileSaver, sessionId), totalSize);
}

/// The FFI calls of one write session.
///
/// Each call uses a one-shot [ReceivePort] that is closed after its message
/// arrives. It must not reference the sink, so the sink can be garbage
/// collected and its session cancelled.
class _DarwinWriteSession implements WriteSession {
  _DarwinWriteSession(this._fileSaver, this._sessionId);

  final FileSaverFFI _fileSaver;
  final int _sessionId;

  @override
  Future<int> write(List<int> data) async {
    final message = await _call((port) {
      // Swift takes ownership of the buffer and frees it once written.
      final dataPtr = malloc<Uint8>(data.length);
      dataPtr.asTypedList(data.length).setAll(0, data);
      _fileSaver.writeChunk(_sessionId, dataPtr, data.length, port);
    });
    return (message[1] as num).toInt();
  }

  @override
  Future<void> flush() async {
    await _call((port) => _fileSaver.flushWrite(_sessionId, port));
  }

  @override
  Future<Uri> close() async {
    final message = await _call(
      (port) => _fileSaver.closeWrite(_sessionId, port),
    );
    return Uri.parse(message[1] as String);
  }

  @override
  Future<void> cancel() async => _fileSaver.cancelWrite(_sessionId);

  /// Runs [start] synchronously with a native port and completes with the
  /// message it receives, or fails with the [FileSaverException] of an error
  /// message (`[2, code, message]`).
  Future<List<Object?>> _call(void Function(int nativePort) start) {
    final completer = Completer<List<Object?>>();
    final receivePort = ReceivePort();
    receivePort.listen((message) {
      receivePort.close();
      final msg = message as List<Object?>;
      if (msg[0] == 2) {
        completer.completeError(
          FileSaverException.fromErrorResult(
            msg[1] as String,
            msg[2] as String,
          ),
        );
      } else {
        completer.complete(msg);
      }
    });
    start(receivePort.sendPort.nativePort);
    return completer.future;
  }
}
