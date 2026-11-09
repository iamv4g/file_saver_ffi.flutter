import 'dart:async';

import 'package:jni/jni.dart';

import '../../exceptions/file_saver_exceptions.dart';
import '../shared/native_event_parser.dart';
import 'bindings.g.dart' as bindings;

/// Runs [call], a JNI call that reports one result through the
/// [bindings.ProgressCallback] it is given, and completes with the progress
/// and data of that result: a success event (3), or the progress event (1)
/// with which a write session reports the bytes written. An error event (2)
/// fails with its [FileSaverException]. Other events are ignored.
///
/// The JNI arguments [call] registers on the arena are released once the
/// call has returned, and the callback after its result arrived, or at once
/// when [call] throws.
Future<(double progress, String? data)> callForJniReply(
  void Function(Arena arena, bindings.ProgressCallback callback) call,
) {
  final completer = Completer<(double, String?)>();
  late final bindings.ProgressCallback callback;
  callback = bindings.ProgressCallback.implement(
    bindings.$ProgressCallback(
      onEvent: (eventType, progress, data, message) {
        final dataStr = data?.toDartString(releaseOriginal: true);
        final messageStr = message?.toDartString(releaseOriginal: true);
        if (completer.isCompleted) return;
        switch (NativeEventType.fromIndex(eventType)) {
          case NativeEventType.progress || NativeEventType.success:
            completer.complete((progress, dataStr));
          case NativeEventType.error:
            completer.completeError(
              FileSaverException.fromErrorResult(
                dataStr ?? FileSaverErrorCode.platform,
                messageStr ?? '',
              ),
            );
          default:
            return;
        }
        // Defer release out of [callback]'s own stack.
        unawaited(Future.microtask(callback.release));
      },
      onEvent$async: true,
    ),
  );
  try {
    using((arena) => call(arena, callback));
  } catch (_) {
    callback.release();
    rethrow;
  }
  return completer.future;
}
