import '../../exceptions/file_saver_exceptions.dart';
import '../../models/save_progress.dart';

/// Converts a native progress event into a [SaveProgress].
///
/// Shared by the Android (JNI) and Darwin (FFI) bridges. Kept free of
/// `dart:ffi` / `package:jni` imports so the protocol can be unit tested.
///
/// Event codes:
/// - 0: Started
/// - 1: Progress ([bytesWritten], and [totalBytes] if known)
/// - 2: Error ([data] = error code, [message] = its detail, see
///   [FileSaverErrorCode]; [statusCode] = HTTP status of a network error)
/// - 3: Success ([data] = file URI)
/// - 4: Cancelled. Sent only after a cancel, once the save has stopped and
///   deleted what it wrote; the listener has cancelled, so only the bridge
///   sees it.
SaveProgress parseNativeEvent(
  int eventType, {
  int bytesWritten = 0,
  int? totalBytes,
  String? data,
  String? message,
  int? statusCode,
}) {
  switch (eventType) {
    case 0: // Started
      return const SaveProgressStarted();

    case 1: // Progress
      return SaveProgressUpdate.bytes(bytesWritten, totalBytes);

    case 2: // Error
      return SaveProgressError(
        FileSaverException.fromErrorResult(
          data ?? FileSaverErrorCode.platform,
          message ?? 'Unknown error',
          statusCode: statusCode,
        ),
      );

    case 3: // Success
      return SaveProgressComplete(Uri.parse(data ?? ''));

    case 4: // Cancelled
      return const SaveProgressCancelled();

    default:
      return SaveProgressError(
        NativePlatformException('Unknown event type: $eventType'),
      );
  }
}

/// Parses a message posted by the Darwin side through a Dart `NativePort`.
///
/// Protocol:
/// - Started:    [0]
/// - Progress:   [1, bytesWritten, totalBytes]   (totalBytes is null if
///               unknown)
/// - Error:      [2, errorCode, errorMessage, statusCode]   (statusCode is
///               an int for a network error with an HTTP status, else null)
/// - Success:    [3, fileUri]
/// - Cancelled:  [4]
SaveProgress parseDarwinMessage(dynamic message) {
  if (message is! List || message.isEmpty || message[0] is! int) {
    return const SaveProgressError(
      NativePlatformException('Invalid message format'),
    );
  }

  final type = message[0] as int;
  return switch (type) {
    1 => parseNativeEvent(
      type,
      bytesWritten: message[1] as int,
      totalBytes: message[2] as int?,
    ),
    2 => parseNativeEvent(
      type,
      data: message[1] as String,
      message: message[2] as String,
      statusCode: message.length > 3 ? message[3] as int? : null,
    ),
    3 => parseNativeEvent(type, data: message[1] as String),
    _ => parseNativeEvent(type),
  };
}
