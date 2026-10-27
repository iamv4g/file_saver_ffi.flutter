import '../../exceptions/file_saver_exceptions.dart';
import '../../models/save_progress.dart';

/// Converts a native progress event into a [SaveProgress].
///
/// Shared by the Android (JNI) and Darwin (FFI) bridges. Kept free of
/// `dart:ffi` / `package:jni` imports so the protocol can be unit tested.
///
/// Event codes:
/// - 0: Started
/// - 1: Progress ([progress] is 0.0 to 1.0)
/// - 2: Error ([data] = error code, [message] = error message)
/// - 3: Success ([data] = file URI)
/// - 4: Cancelled
SaveProgress parseNativeEvent(
  int eventType, {
  double progress = 0,
  String? data,
  String? message,
}) {
  switch (eventType) {
    case 0: // Started
      return const SaveProgressStarted();

    case 1: // Progress
      return SaveProgressUpdate(progress);

    case 2: // Error
      return SaveProgressError(
        FileSaverException.fromErrorResult(
          data ?? 'UNKNOWN',
          message ?? 'Unknown error',
        ),
      );

    case 3: // Success
      return SaveProgressComplete(Uri.parse(data ?? ''));

    case 4: // Cancelled
      return const SaveProgressCancelled();

    default:
      return SaveProgressError(
        NativePlatformException(
          'Unknown event type: $eventType',
          'UNKNOWN_TYPE',
        ),
      );
  }
}

/// Parses a message posted by the Darwin side through a Dart `NativePort`.
///
/// Protocol:
/// - Started:    [0]
/// - Progress:   [1, progress]    (progress is 0.0 to 1.0)
/// - Error:      [2, errorCode, errorMessage]
/// - Success:    [3, fileUri]
/// - Cancelled:  [4]
SaveProgress parseDarwinMessage(dynamic message) {
  if (message is! List || message.isEmpty || message[0] is! int) {
    return const SaveProgressError(
      NativePlatformException('Invalid message format', 'INVALID_MESSAGE'),
    );
  }

  final type = message[0] as int;
  return switch (type) {
    1 => parseNativeEvent(type, progress: (message[1] as num).toDouble()),
    2 => parseNativeEvent(
      type,
      data: message[1] as String,
      message: message[2] as String,
    ),
    3 => parseNativeEvent(type, data: message[1] as String),
    _ => parseNativeEvent(type),
  };
}
