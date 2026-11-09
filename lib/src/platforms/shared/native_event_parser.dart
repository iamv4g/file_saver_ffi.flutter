import '../../exceptions/file_saver_exceptions.dart';
import '../../models/save_progress.dart';

/// The type of a native progress event, which Kotlin
/// (`ProgressCallback.onEvent`) and Swift (`ProgressReporter`) send as its
/// [index].
///
/// Kotlin and Swift have generated copies of these indices (`EventType`).
/// After changing this enum, run `dart run tool/contracts.dart`.
enum NativeEventType {
  /// The save started.
  started,

  /// Progress: the bytes written, and the size if known. For a write
  /// session, the ACK of a chunk or flush.
  progress,

  /// Error: the error code (see [FileSaverErrorCode]) and its detail, and
  /// the HTTP status of a network error.
  error,

  /// Success: the file URI. For a write session, the session id (open) or
  /// the file URI (close).
  success,

  /// Cancelled. Sent only after a cancel, once the save has stopped and
  /// deleted what it wrote; the listener has cancelled, so only the bridge
  /// sees it.
  cancelled;

  /// The type with index [index], or null for an unknown one.
  static NativeEventType? fromIndex(int index) => values.elementAtOrNull(index);
}

/// Values of the replies to opening a write session.
///
/// Kotlin and Swift have generated copies of these values
/// (`WriteSessionReply`). After changing them, run
/// `dart run tool/contracts.dart`.
abstract final class NativeWriteSession {
  /// The session id of the [NativeEventType.success] reply to opening a
  /// session that found an existing file and, with
  /// `ConflictResolution.skip`, opened nothing.
  static const skippedId = 0;
}

/// Converts a native progress event of type [eventType] (a [NativeEventType]
/// index) into a [SaveProgress].
///
/// Shared by the Android (JNI) and Darwin (FFI) bridges. Kept free of
/// `dart:ffi` / `package:jni` imports so the protocol can be unit tested.
///
/// - [NativeEventType.progress]: [bytesWritten], and [totalBytes] if known.
/// - [NativeEventType.error]: [data] = error code, [message] = its detail,
///   see [FileSaverErrorCode]; [statusCode] = HTTP status of a network error.
/// - [NativeEventType.success]: [data] = file URI.
SaveProgress parseNativeEvent(
  int eventType, {
  int bytesWritten = 0,
  int? totalBytes,
  String? data,
  String? message,
  int? statusCode,
}) {
  switch (NativeEventType.fromIndex(eventType)) {
    case NativeEventType.started:
      return const SaveProgressStarted();

    case NativeEventType.progress:
      return SaveProgressUpdate.bytes(bytesWritten, totalBytes);

    case NativeEventType.error:
      return SaveProgressError(
        FileSaverException.fromErrorResult(
          data ?? FileSaverErrorCode.platform,
          message ?? 'Unknown error',
          statusCode: statusCode,
        ),
      );

    case NativeEventType.success:
      return SaveProgressComplete(Uri.parse(data ?? ''));

    case NativeEventType.cancelled:
      return const SaveProgressCancelled();

    case null:
      return SaveProgressError(
        NativePlatformException('Unknown event type: $eventType'),
      );
  }
}

/// Parses a message posted by the Darwin side through a Dart `NativePort`:
/// a list whose first element is a [NativeEventType] index.
///
/// Protocol:
/// - started:    [0]
/// - progress:   [1, bytesWritten, totalBytes]   (totalBytes is null if
///               unknown)
/// - error:      [2, errorCode, errorMessage, statusCode]   (statusCode is
///               an int for a network error with an HTTP status, else null)
/// - success:    [3, fileUri]
/// - cancelled:  [4]
SaveProgress parseDarwinMessage(dynamic message) {
  if (message is! List || message.isEmpty || message[0] is! int) {
    return const SaveProgressError(
      NativePlatformException('Invalid message format'),
    );
  }

  final type = message[0] as int;
  return switch (NativeEventType.fromIndex(type)) {
    NativeEventType.progress => parseNativeEvent(
      type,
      bytesWritten: message[1] as int,
      totalBytes: message[2] as int?,
    ),
    NativeEventType.error => parseNativeEvent(
      type,
      data: message[1] as String,
      message: message[2] as String,
      statusCode: message.length > 3 ? message[3] as int? : null,
    ),
    NativeEventType.success => parseNativeEvent(
      type,
      data: message[1] as String,
    ),
    _ => parseNativeEvent(type),
  };
}
