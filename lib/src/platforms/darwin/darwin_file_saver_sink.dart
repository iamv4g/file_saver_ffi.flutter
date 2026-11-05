import 'dart:async';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import '../../models/file_saver_sink.dart';
import '../shared/session_file_saver_sink.dart';
import 'bindings.g.dart';
import 'darwin_reply.dart';

/// Darwin (iOS / macOS) implementation of [FileSaverSink], over an FFI write
/// session in `FileSaverFFI.swift`.
///
/// Its native finalizer cancels the session when the sink is left unclosed
/// and becomes unreachable, also when its isolate exits or its engine shuts
/// down. The Dart `Finalizer` of [SessionFileSaverSink] doesn't run then, and
/// Swift would keep the partial file, its handle and, for `openWriteAs`, the
/// security scope of the directory for as long as the process lives.
class DarwinFileSaverSink extends SessionFileSaverSink implements Finalizable {
  DarwinFileSaverSink({
    required FileSaverFFI fileSaver,
    required int sessionId,
    int? totalSize,
  }) : super(_DarwinWriteSession(fileSaver, sessionId), totalSize) {
    // Not detached by close or cancel: once the session has ended, the
    // callback finds no session with that id and does nothing.
    (_finalizer ??= NativeFinalizer(
      fileSaver.addresses.finalizeWrite,
    )).attach(this, Pointer.fromAddress(sessionId));
  }

  /// Calls `file_saver_finalize_write` with the session id. One per isolate,
  /// created with the first sink.
  static NativeFinalizer? _finalizer;
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
