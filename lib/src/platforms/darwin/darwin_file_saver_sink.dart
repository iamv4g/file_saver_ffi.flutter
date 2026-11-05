import 'dart:async';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import '../../models/file_saver_sink.dart';
import '../shared/session_file_saver_sink.dart';
import 'bindings.g.dart';
import 'darwin_reply.dart';

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
/// Each call waits for its reply with [callForDarwinReply]. It must not reference the sink, so the sink can be garbage
/// collected and its session cancelled.
class _DarwinWriteSession implements WriteSession {
  _DarwinWriteSession(this._fileSaver, this._sessionId);

  final FileSaverFFI _fileSaver;
  final int _sessionId;

  @override
  Future<int> write(List<int> data) async {
    final message = await callForDarwinReply((port) {
      // Swift takes ownership of the buffer and frees it once written.
      final dataPtr = malloc<Uint8>(data.length);
      dataPtr.asTypedList(data.length).setAll(0, data);
      _fileSaver.writeChunk(_sessionId, dataPtr, data.length, port.nativePort);
    });
    return (message[1] as num).toInt();
  }

  @override
  Future<void> flush() async {
    await callForDarwinReply(
      (port) => _fileSaver.flushWrite(_sessionId, port.nativePort),
    );
  }

  @override
  Future<Uri> close() async {
    final message = await callForDarwinReply(
      (port) => _fileSaver.closeWrite(_sessionId, port.nativePort),
    );
    return Uri.parse(message[1] as String);
  }

  @override
  Future<void> cancel() async => _fileSaver.cancelWrite(_sessionId);
}
