import 'package:dir_picker/dir_picker.dart';
import 'package:flutter/foundation.dart';

import '../exceptions/file_saver_exceptions.dart';
import '../models/conflict_resolution.dart';
import '../models/file_saver_sink.dart';
import '../models/file_type.dart';
import '../models/locations/save_location.dart';
import '../models/save_input.dart';
import '../models/save_progress.dart';

/// Platform interface for file saver implementations.
///
/// This abstract class defines the contract that platform-specific
/// implementations must implement.
///
/// Platform implementations:
/// - iOS/macOS: Uses FFI to call Swift code (shared darwin source)
/// - Android: Uses JNI to call Kotlin code
/// - Windows: Dart FFI via path_provider_windows (SHGetKnownFolderPath) + dart:io
/// - Linux: Dart FFI via xdg-user-dir + dart:io
/// - Web: Uses browser APIs via dart:web + dart:js_interop
abstract class FileSaverPlatform {
  static FileSaverPlatform? _instance;

  /// The current platform implementation.
  ///
  /// Set automatically before [runApp] via each platform's [registerWith] method,
  /// which is invoked by Flutter's generated plugin registrant.
  static FileSaverPlatform get instance {
    assert(_instance != null, 'FileSaverPlatform.instance is not set.');
    return _instance!;
  }

  /// Used by each platform's [registerWith] to register itself.
  static set instance(FileSaverPlatform value) {
    _instance = value;
  }

  /// Saves file bytes to device storage with progress streaming.
  ///
  /// **Platforms:** Android · iOS · macOS · Windows · Linux · Web
  ///
  /// - [saveLocation]: Where to save the file (platform-specific, optional)
  /// - [subDir]: Optional subdirectory within the standard save location
  /// - [conflictResolution]: How to handle filename conflicts
  ///
  /// Yields [SaveProgress] events during save operation.
  Stream<SaveProgress> saveBytes({
    required Uint8List fileBytes,
    required FileType fileType,
    required String fileName,
    SaveLocation? saveLocation,
    String? subDir,
    ConflictResolution conflictResolution = ConflictResolution.autoRename,
  });

  /// Saves a file from [filePath] to device storage with progress streaming.
  ///
  /// **Platforms:** Android · iOS · macOS · Windows · Linux
  /// (Web: not supported — browsers cannot access arbitrary file paths)
  ///
  /// Streams in chunks — suitable for large files.
  ///
  /// - [filePath]: Source path (file:// URI or content:// URI on Android)
  /// - [saveLocation]: Where to save the file (platform-specific, optional)
  /// - [subDir]: Optional subdirectory within the standard save location
  /// - [conflictResolution]: How to handle filename conflicts
  ///
  /// Yields [SaveProgress] events during save operation.
  ///
  /// Throws [SourceFileNotFoundException] if the source file does not exist.
  /// Throws [ICloudDownloadException] on iOS if iCloud file download fails.
  Stream<SaveProgress> saveFile({
    required String filePath,
    required String fileName,
    required FileType fileType,
    SaveLocation? saveLocation,
    String? subDir,
    ConflictResolution conflictResolution = ConflictResolution.autoRename,
  });

  /// Downloads from [url] and saves to device storage with progress streaming.
  ///
  /// **Platforms:** Android · iOS · macOS · Windows · Linux · Web
  ///
  /// Downloaded natively to avoid double storage:
  /// - Android: streams directly to MediaStore (zero temp files)
  /// - iOS Documents: downloads directly to target path
  /// - iOS Photos: temp → Photos Library → delete temp
  ///
  /// - [headers]: Optional HTTP headers for the request
  /// - [timeout]: Network timeout (default 60s)
  /// - [saveLocation]: Where to save the file (platform-specific, optional)
  /// - [subDir]: Optional subdirectory within the standard save location
  /// - [conflictResolution]: How to handle filename conflicts
  ///
  /// Yields [SaveProgress] events during save operation.
  ///
  /// Throws [NetworkException] if the download fails.
  Stream<SaveProgress> saveNetwork({
    required String url,
    required String fileName,
    required FileType fileType,
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 60),
    SaveLocation? saveLocation,
    String? subDir,
    ConflictResolution conflictResolution = ConflictResolution.autoRename,
  });

  /// Saves to a user-selected directory with progress streaming.
  ///
  /// **Platforms:** Android · iOS · macOS · Windows · Linux · Web
  ///
  /// - [saveLocation]: User-selected directory from [pickDirectory]
  /// - [conflictResolution]: How to handle filename conflicts
  ///
  /// Yields [SaveProgress] events during save operation.
  Stream<SaveProgress> saveAs({
    required SaveInput input,
    required FileType fileType,
    required String fileName,
    required PickedDirectoryLocation saveLocation,
    ConflictResolution conflictResolution = ConflictResolution.autoRename,
  });

  // ─────────────────────────────────────────────────────────────────────────
  // MARK: Session-based streaming write
  // ─────────────────────────────────────────────────────────────────────────

  /// Opens a streaming write session to an auto-resolved location.
  ///
  /// **Platforms:** Windows · Linux · Web (buffer fallback) · Android · iOS · macOS
  ///
  /// Returns a [FileSaverSink] that accepts incremental chunks via [add].
  /// Call [FileSaverSink.close] to finalize and obtain the saved file [Uri].
  ///
  /// Returns null if [conflictResolution] is [ConflictResolution.skip] and the
  /// target file already exists.
  ///
  /// [totalSize] is optional. When provided, [FileSaverSink.progress] emits
  /// per-chunk progress (0.0–1.0). [FileSaverSink.bytesWritten] always emits.
  Future<FileSaverSink?> openWrite({
    required String fileName,
    required FileType fileType,
    SaveLocation? saveLocation,
    String? subDir,
    int? totalSize,
    ConflictResolution conflictResolution = ConflictResolution.autoRename,
  }) {
    throw UnimplementedError('openWrite is not implemented on this platform');
  }

  /// Opens a streaming write session to a user-selected directory.
  ///
  /// **Platforms:** Windows · Linux · Web (FSA) · Android · iOS · macOS
  ///
  /// [saveLocation] must be a [PickedDirectoryLocation] obtained via [pickDirectory].
  ///
  /// Returns null if [conflictResolution] is [ConflictResolution.skip] and the
  /// target file already exists.
  Future<FileSaverSink?> openWriteAs({
    required String fileName,
    required FileType fileType,
    required PickedDirectoryLocation saveLocation,
    int? totalSize,
    ConflictResolution conflictResolution = ConflictResolution.autoRename,
  }) {
    throw UnimplementedError('openWriteAs is not implemented on this platform');
  }

  // ─────────────────────────────────────────────────────────────────────────
  // MARK:Directory picker and file opener
  // ─────────────────────────────────────────────────────────────────────────

  /// Shows the system directory picker.
  ///
  /// **Platforms:** Android · iOS · macOS · Windows · Linux · Web
  ///
  /// [shouldPersist] is Android-only: if true, calls takePersistableUriPermission
  /// so the app can write to the selected directory across restarts without re-picking.
  /// Ignored on all other platforms.
  ///
  /// Returns [PickedDirectoryLocation], or null if cancelled.
  /// Throws [UnsupportedError] on browsers that do not support the File System Access API.
  Future<PickedDirectoryLocation?> pickDirectory({
    bool shouldPersist = true,
  }) async {
    try {
      final location = await DirPicker.pick(
        options: AndroidOptions(shouldPersist: shouldPersist),
      );
      if (location == null) return null;
      return PickedDirectoryLocation(uri: location.uri!);
    } on FileSaverException {
      rethrow;
    } catch (e) {
      throw NativePlatformException('Pick directory failed: $e');
    }
  }

  /// Checks whether the file at [uri] is accessible for reading.
  ///
  /// **Platforms:** Android · iOS · macOS · Windows · Linux
  /// **Web:** throws [UnsupportedError]
  ///
  /// Notes:
  /// - Android supports `content://` and `file://` URIs.
  /// - iOS supports `file://` and `ph://` (Photos assets) URIs.
  ///
  /// Returns `false` if the file has been deleted or is no longer accessible.
  Future<bool> canOpenFile(Uri uri) {
    throw UnimplementedError('canOpenFile is not implemented on this platform');
  }

  /// Opens a saved file with the appropriate system app.
  ///
  /// **Platforms:** Android · iOS · macOS · Windows · Linux
  /// **Web:** throws [UnsupportedError] — files are already browser-downloaded.
  ///
  /// [uri] should be a [Uri] returned from a save operation (for example: [saveAsync],
  /// [SaveProgressComplete.uri], or a write-session result like [FileSaverSink.result]).
  ///
  /// [mimeType] is optional. On Android, it is queried from ContentResolver for `content://`
  /// URIs if not provided.
  ///
  /// **Android note:** If [uri] is a `file://...` URI, the host app may need to
  /// configure a `FileProvider` to open it.
  ///
  /// **iOS note:** `ph://` URIs are opened via a system preview (QuickLook).
  Future<void> openFile(Uri uri, {String? mimeType}) {
    throw UnimplementedError('openFile is not implemented on this platform');
  }

  // ─────────────────────────────────────────────────────────────────────────
  // MARK: Protected helpers for subclasses
  // ─────────────────────────────────────────────────────────────────────────

  /// Returns [saveLocation] as a location of the running platform, [T], or
  /// null for the platform's default. Call it after handling [PathLocation].
  ///
  /// Throws [InvalidInputException] for another platform's location, such as
  /// [IosSaveLocation.photos] on macOS, and for a [PickedDirectoryLocation],
  /// which [saveAs] and [openWriteAs] take.
  @protected
  T? checkSaveLocation<T extends SaveLocation>(SaveLocation? saveLocation) {
    return switch (saveLocation) {
      null => null,
      final T location => location,
      PickedDirectoryLocation() => throw const InvalidInputException(
        'A PickedDirectoryLocation is saved to with saveAs or openWriteAs.',
      ),
      _ => throw InvalidInputException(
        "$saveLocation isn't a save location on this platform. Pass a $T, a "
        'PathLocation, or null for the default.',
      ),
    };
  }

  /// Validates input for [saveBytes] and [saveBytesAsync].
  @protected
  void validateBytesInput(Uint8List bytes, String fileName) {
    if (bytes.isEmpty) {
      throw const InvalidInputException('File bytes cannot be empty');
    }
    if (fileName.isEmpty) {
      throw const InvalidInputException('File name cannot be empty');
    }
  }

  /// Validates input for [saveFile] and [saveFileAsync].
  @protected
  void validateFilePathInput(String filePath, String fileName) {
    if (filePath.isEmpty) {
      throw const InvalidInputException('File path cannot be empty');
    }
    if (fileName.isEmpty) {
      throw const InvalidInputException('File name cannot be empty');
    }
  }

  /// Validates input for [saveNetwork] and [saveNetworkAsync].
  @protected
  void validateNetworkInput(String url, String fileName) {
    if (url.isEmpty) {
      throw const InvalidInputException('URL cannot be empty');
    }
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !uri.hasScheme ||
        (!uri.isScheme('http') && !uri.isScheme('https'))) {
      throw const InvalidInputException('URL must use http or https scheme');
    }
    if (fileName.isEmpty) {
      throw const InvalidInputException('File name cannot be empty');
    }
  }

  /// Checks if [SaveProgress] event is terminal.
  @protected
  bool isTerminal(SaveProgress e) =>
      e is SaveProgressComplete ||
      e is SaveProgressError ||
      e is SaveProgressCancelled;
}
