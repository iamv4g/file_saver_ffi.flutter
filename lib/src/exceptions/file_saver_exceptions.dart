/// Base exception for all file saver errors.
///
/// Uses sealed class for exhaustive exception handling.
sealed class FileSaverException implements Exception {
  const FileSaverException(this.message, [this.code]);

  factory FileSaverException.fromObj(Object e) {
    if (e is FileSaverException) return e;
    if (e is! Exception) {
      return NativePlatformException('Unexpected error: $e', 'PLATFORM_ERROR');
    }

    final msg = e.toString();
    bool contains(String code) {
      return msg.contains(code);
    }

    return switch (msg) {
      _ when contains('CANCELLED') => const CancelledException(),
      _ when contains('PERMISSION_DENIED') => PermissionDeniedException(msg),
      _ when contains('FILE_EXISTS') => FileExistsException(msg),
      _ when contains('FILE_NOT_FOUND') => SourceFileNotFoundException(msg),
      _ when contains('OPEN_FAILED') => OpenFailedException(msg),
      _ when contains('NO_APP_FOUND') => OpenFailedException(msg),
      _ when contains('FILE_PROVIDER_NOT_CONFIGURED') => OpenFailedException(
        msg,
      ),
      _ when contains('FILE_PROVIDER_PATHS_NOT_COVERED') => OpenFailedException(
        msg,
      ),
      _ when contains('ICLOUD_DOWNLOAD_FAILED') => ICloudDownloadException(msg),
      _ when contains('NETWORK_ERROR') => NetworkException(msg),
      _ when contains('INVALID_INPUT') => InvalidInputException(msg),
      _ when contains('UNSUPPORTED_FORMAT') => UnsupportedFormatException(msg),
      _ when contains('STORAGE_FULL') => const StorageFullException(),
      _ when contains('FILE_IO_ERROR') => FileIOException(msg),
      _ => NativePlatformException(msg, 'PLATFORM_ERROR'),
    };
  }

  factory FileSaverException.fromErrorResult(String errorCode, String message) {
    return switch (errorCode) {
      'CANCELLED' => const CancelledException(),
      'PERMISSION_DENIED' => PermissionDeniedException(message),
      'FILE_EXISTS' => FileExistsException(message),
      'FILE_NOT_FOUND' => SourceFileNotFoundException(message),
      'OPEN_FAILED' => OpenFailedException(message),
      'ICLOUD_DOWNLOAD_FAILED' => ICloudDownloadException(message),
      'NETWORK_ERROR' => NetworkException(message),
      'INVALID_INPUT' || 'INVALID_ARGUMENT' => InvalidInputException(message),
      'UNSUPPORTED_FORMAT' => UnsupportedFormatException(message),
      'STORAGE_FULL' => const StorageFullException(),
      'FILE_IO_ERROR' => FileIOException(message),
      _ => NativePlatformException(message, errorCode),
    };
  }

  /// Human-readable error message.
  final String message;

  /// Machine-readable error code.
  final String? code;

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
    : super(message ?? 'Storage permission denied', 'PERMISSION_DENIED');
}

/// File already exists and conflict resolution strategy is set to fail.
///
/// This exception is thrown when:
/// - A file with the same name already exists at the destination
/// - The conflict resolution strategy is [ConflictResolution.fail]
final class FileExistsException extends FileSaverException {
  const FileExistsException(this.fileName)
    : super('File already exists: $fileName', 'FILE_EXISTS');

  /// The name of the existing file.
  final String fileName;

  @override
  String toString() => 'FileExistsException: File already exists: $fileName';
}

final class InvalidInputException extends FileSaverException {
  const InvalidInputException(String reason)
    : super('Invalid input: $reason', 'INVALID_INPUT');
}

/// Insufficient storage space available.
///
/// This exception is thrown when there is not enough free space
/// on the device to save the file.
final class StorageFullException extends FileSaverException {
  const StorageFullException()
    : super('Insufficient storage space', 'STORAGE_FULL');
}

/// Platform-specific error occurred.
///
/// This exception wraps platform-specific errors from iOS or Android
/// that don't fit into other exception categories.
final class NativePlatformException extends FileSaverException {
  const NativePlatformException(super.message, [super.code]);

  /// Creates a platform exception from native error details.
  factory NativePlatformException.fromNative({
    required String message,
    String? code,
    String? details,
  }) {
    final fullMessage = details != null ? '$message: $details' : message;
    return NativePlatformException(fullMessage, code);
  }
}

/// Open file operation failed.
///
/// This exception is thrown when the platform fails to open a file with a
/// suitable system app (no handler, OS rejected the request, or the open
/// command failed).
final class OpenFailedException extends FileSaverException {
  const OpenFailedException(String message) : super(message, 'OPEN_FAILED');
}

/// File I/O operation failed.
///
/// This exception is thrown when:
/// - Unable to write file to disk
/// - Unable to create directory
/// - File system error occurred
final class FileIOException extends FileSaverException {
  const FileIOException(String reason)
    : super('File I/O error: $reason', 'FILE_IO_ERROR');
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
        'UNSUPPORTED_FORMAT',
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
    : super('Source file not found: $path', 'FILE_NOT_FOUND');

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
        'ICLOUD_DOWNLOAD_FAILED',
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
    : super('Network error: $reason', 'NETWORK_ERROR');

  /// HTTP status code, if available.
  final int? statusCode;

  @override
  String toString() =>
      'NetworkException: $message${statusCode != null ? " (HTTP $statusCode)" : ""}';
}

/// Operation was cancelled by the user.
///
/// This exception is thrown when:
/// - User calls `subscription.cancel()` on a save stream
/// - User breaks from `await for` loop early
/// - The operation is cancelled programmatically
final class CancelledException extends FileSaverException {
  const CancelledException() : super('Operation cancelled', 'CANCELLED');
}

/// Write session error (openWrite / openWriteAs).
///
/// This exception is thrown when:
/// - A write session is not found (invalid or already closed session ID)
/// - A chunk write fails due to a native I/O error
/// - The sink is used after [FileSaverSink.close] or [FileSaverSink.cancel]
final class WriteSessionException extends FileSaverException {
  const WriteSessionException(String reason)
    : super('Write session error: $reason', 'WRITE_SESSION_ERROR');
}
