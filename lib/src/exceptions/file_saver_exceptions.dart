import 'package:flutter/foundation.dart';

/// The [FileSaverException.code] values.
///
/// Kotlin (`utils/Constants.kt`) and Swift (`Utils/Constants.swift`) report
/// errors with the same strings, and an error message that holds only the
/// detail [FileSaverException.fromErrorResult] needs:
///
/// | Code | Message from native code |
/// |------|--------------------------|
/// | [fileExists] | the file name |
/// | [fileNotFound] | the source path or URI |
/// | [unsupportedFormat] | the file extension |
/// | [network] | the reason, with the HTTP status code sent separately |
/// | [invalidInput], [fileIO], [iCloudDownloadFailed] | the reason |
/// | [storageFull], [cancelled] | ignored |
/// | others | the full message |
abstract final class FileSaverErrorCode {
  static const cancelled = 'CANCELLED';
  static const permissionDenied = 'PERMISSION_DENIED';
  static const fileExists = 'FILE_EXISTS';
  static const fileNotFound = 'FILE_NOT_FOUND';
  static const openFailed = 'OPEN_FAILED';
  static const iCloudDownloadFailed = 'ICLOUD_DOWNLOAD_FAILED';
  static const network = 'NETWORK_ERROR';
  static const invalidInput = 'INVALID_INPUT';
  static const unsupportedFormat = 'UNSUPPORTED_FORMAT';
  static const storageFull = 'STORAGE_FULL';
  static const fileIO = 'FILE_IO_ERROR';
  static const writeSession = 'WRITE_SESSION_ERROR';

  /// An error that fits no other code, including an unexpected native error
  /// or reply.
  static const platform = 'PLATFORM_ERROR';

  /// A save stream that ended without a result (`saveAsync`).
  static const incomplete = 'INCOMPLETE';

  /// Every code that maps to its own exception type, in the order
  /// [FileSaverException.fromObj] looks for them.
  static const mapped = [
    cancelled,
    permissionDenied,
    fileExists,
    fileNotFound,
    openFailed,
    iCloudDownloadFailed,
    network,
    invalidInput,
    unsupportedFormat,
    storageFull,
    fileIO,
    writeSession,
  ];
}

/// Base exception for all file saver errors.
///
/// Uses sealed class for exhaustive exception handling.
@immutable
sealed class FileSaverException implements Exception {
  const FileSaverException(this.message, [this.code]);

  /// Converts any error into a [FileSaverException]: returns one unchanged,
  /// and maps an [Exception] whose text contains an error code like
  /// [FileSaverException.fromErrorResult], with the whole text as message.
  factory FileSaverException.fromObj(Object e) {
    if (e is FileSaverException) return e;
    if (e is! Exception) {
      return NativePlatformException('Unexpected error: $e');
    }

    final msg = e.toString();
    final code = FileSaverErrorCode.mapped.where(msg.contains).firstOrNull;
    return code == null
        ? NativePlatformException(msg)
        : FileSaverException.fromErrorResult(code, msg);
  }

  /// Converts an error that native code reported as [errorCode] and
  /// [message] into a [FileSaverException]. See [FileSaverErrorCode] for what
  /// [message] holds. [statusCode] is the HTTP status of a
  /// [FileSaverErrorCode.network] error.
  factory FileSaverException.fromErrorResult(
    String errorCode,
    String message, {
    int? statusCode,
  }) {
    return switch (errorCode) {
      FileSaverErrorCode.cancelled => const CancelledException(),
      FileSaverErrorCode.permissionDenied => PermissionDeniedException(message),
      FileSaverErrorCode.fileExists => FileExistsException(message),
      FileSaverErrorCode.fileNotFound => SourceFileNotFoundException(message),
      FileSaverErrorCode.openFailed => OpenFailedException(message),
      FileSaverErrorCode.iCloudDownloadFailed => ICloudDownloadException(
        message,
      ),
      FileSaverErrorCode.network => NetworkException(message, statusCode),
      FileSaverErrorCode.invalidInput => InvalidInputException(message),
      FileSaverErrorCode.unsupportedFormat => UnsupportedFormatException(
        message,
      ),
      FileSaverErrorCode.storageFull => const StorageFullException(),
      FileSaverErrorCode.fileIO => FileIOException(message),
      FileSaverErrorCode.writeSession => WriteSessionException(message),
      _ => NativePlatformException(message, errorCode),
    };
  }

  /// Human-readable error message.
  final String message;

  /// Machine-readable error code.
  final String? code;

  /// Two exceptions of the same type with the same [message] and [code] are
  /// equal, so a test can compare the `SaveProgressError` it expects.
  @override
  bool operator ==(Object other) =>
      other is FileSaverException &&
      other.runtimeType == runtimeType &&
      message == other.message &&
      code == other.code;

  @override
  int get hashCode => Object.hash(runtimeType, message, code);

  @override
  String toString() {
    final codeStr = code != null ? ' ($code)' : '';
    return 'FileSaverException: $message$codeStr';
  }
}

/// Permission was denied for storage access.
///
/// This exception is thrown when the user denies storage permission
/// or when permissions are not granted.
final class PermissionDeniedException extends FileSaverException {
  const PermissionDeniedException([String? message])
    : super(
        message ?? 'Storage permission denied',
        FileSaverErrorCode.permissionDenied,
      );
}

/// File already exists and conflict resolution strategy is set to fail.
///
/// This exception is thrown when:
/// - A file with the same name already exists at the destination
/// - The conflict resolution strategy is [ConflictResolution.fail]
final class FileExistsException extends FileSaverException {
  const FileExistsException(this.fileName)
    : super('File already exists: $fileName', FileSaverErrorCode.fileExists);

  /// The name of the existing file.
  final String fileName;

  @override
  String toString() => 'FileExistsException: File already exists: $fileName';
}

final class InvalidInputException extends FileSaverException {
  const InvalidInputException(String reason)
    : super('Invalid input: $reason', FileSaverErrorCode.invalidInput);
}

/// Insufficient storage space available.
///
/// This exception is thrown when there is not enough free space
/// on the device to save the file.
final class StorageFullException extends FileSaverException {
  const StorageFullException()
    : super('Insufficient storage space', FileSaverErrorCode.storageFull);
}

/// Platform-specific error occurred.
///
/// This exception wraps platform-specific errors from iOS or Android
/// that don't fit into other exception categories.
final class NativePlatformException extends FileSaverException {
  const NativePlatformException(
    super.message, [
    super.code = FileSaverErrorCode.platform,
  ]);
}

/// Open file operation failed.
///
/// This exception is thrown when the platform fails to open a file with a
/// suitable system app (no handler, OS rejected the request, or the open
/// command failed).
final class OpenFailedException extends FileSaverException {
  const OpenFailedException(String message)
    : super(message, FileSaverErrorCode.openFailed);
}

/// File I/O operation failed.
///
/// This exception is thrown when:
/// - Unable to write file to disk
/// - Unable to create directory
/// - File system error occurred
final class FileIOException extends FileSaverException {
  const FileIOException(String reason)
    : super('File I/O error: $reason', FileSaverErrorCode.fileIO);
}

/// File format is not supported on this platform or OS version.
///
/// This exception is thrown when:
/// - File format is not supported by the platform (e.g., HEIC/HEIF on some Android versions)
/// - Platform-specific codec is missing
/// - OS version doesn't support the format
final class UnsupportedFormatException extends FileSaverException {
  const UnsupportedFormatException(this.format, [String? details])
    : super(
        'File format "$format" is not supported on this platform${details != null ? ": $details" : ""}',
        FileSaverErrorCode.unsupportedFormat,
      );

  /// The unsupported file format/extension.
  final String format;

  @override
  String toString() =>
      'UnsupportedFormatException: File format "$format" is not supported on this platform';
}

/// Source file was not found at the specified path.
///
/// This exception is thrown when:
/// - The source file path does not exist
/// - The file was deleted before the operation completed
/// - The path is invalid or inaccessible
final class SourceFileNotFoundException extends FileSaverException {
  const SourceFileNotFoundException(this.path)
    : super('Source file not found: $path', FileSaverErrorCode.fileNotFound);

  /// The path of the file that was not found.
  final String path;

  @override
  String toString() =>
      'SourceFileNotFoundException: Source file not found: $path';
}

/// iCloud file download failed or timed out (iOS only).
///
/// This exception is thrown when:
/// - The iCloud file could not be downloaded
/// - The download timed out (default 60 seconds)
/// - Network connection is unavailable
final class ICloudDownloadException extends FileSaverException {
  const ICloudDownloadException([String? details])
    : super(
        'iCloud file download failed${details != null ? ": $details" : ""}',
        FileSaverErrorCode.iCloudDownloadFailed,
      );
}

/// Network error occurred during download.
///
/// This exception is thrown when:
/// - The URL is unreachable or invalid
/// - HTTP response status is not 2xx
/// - Network connection timed out
/// - Download was interrupted
final class NetworkException extends FileSaverException {
  const NetworkException(String reason, [this.statusCode])
    : super('Network error: $reason', FileSaverErrorCode.network);

  /// HTTP status code, if available.
  final int? statusCode;

  @override
  bool operator ==(Object other) =>
      super == other &&
      other is NetworkException &&
      statusCode == other.statusCode;

  @override
  int get hashCode => Object.hash(super.hashCode, statusCode);

  @override
  String toString() =>
      'NetworkException: $message${statusCode != null ? " (HTTP $statusCode)" : ""}';
}

/// A write session was cancelled.
///
/// `FileSaverSink.close()` and `FileSaverSink.result` throw it after
/// `FileSaverSink.cancel()`. Cancelling the subscription of a save stream
/// doesn't throw it: the stream just emits nothing more.
final class CancelledException extends FileSaverException {
  const CancelledException()
    : super('Operation cancelled', FileSaverErrorCode.cancelled);
}

/// Write session error (openWrite / openWriteAs).
///
/// The plugin no longer throws this. A failed write reports the native error,
/// such as [FileIOException], and using a closed sink throws [StateError].
/// It is kept so that existing `on WriteSessionException` clauses compile.
final class WriteSessionException extends FileSaverException {
  const WriteSessionException(String reason)
    : super('Write session error: $reason', FileSaverErrorCode.writeSession);
}
