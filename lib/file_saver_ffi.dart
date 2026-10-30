library;

import 'package:flutter/foundation.dart';

import 'src/exceptions/file_saver_exceptions.dart';
import 'src/models/conflict_resolution.dart';
import 'src/models/file_saver_sink.dart';
import 'src/models/file_type.dart';
import 'src/models/locations/save_location.dart';
import 'src/models/save_input.dart';
import 'src/models/save_progress.dart';
import 'src/platform_interface/file_saver_platform.dart';

// Public API
export 'src/exceptions/file_saver_exceptions.dart';
export 'src/models/conflict_resolution.dart';
export 'src/models/file_saver_sink.dart';
export 'src/models/file_type.dart';
export 'src/models/locations/save_location.dart';
export 'src/models/save_input.dart';
export 'src/models/save_progress.dart';
export 'src/platforms/io_platforms.dart'
    if (dart.library.js_interop) 'src/platforms/io_stub.dart';
export 'src/platforms/web/file_saver_web.dart'
    if (dart.library.io) 'src/platforms/web_stub.dart';

class FileSaver {
  FileSaver._();

  static FileSaverPlatform get _platform => FileSaverPlatform.instance;

  /// Saves a file to device storage with progress streaming.
  ///
  /// **Platforms:** Android · iOS · macOS · Windows · Linux · Web
  ///
  /// Selects the save strategy based on [input]:
  /// - [SaveBytesInput]: write bytes directly
  /// - [SaveFileInput]: stream from source path (memory-efficient for large files)
  /// - [SaveNetworkInput]: download then save natively
  ///
  /// Yields [SaveProgress] events:
  /// - [SaveProgressStarted]: operation began
  /// - [SaveProgressUpdate]: progress 0.0–1.0
  /// - [SaveProgressComplete]: success with [Uri]
  /// - [SaveProgressError]: failed with exception
  /// - [SaveProgressCancelled]: cancelled
  ///
  /// [saveLocation] defaults by platform:
  /// - Android: [AndroidSaveLocation.downloads]
  /// - iOS: [IosSaveLocation.documents]
  /// - macOS / Windows / Linux: user's Downloads folder
  /// - Web: ignored (browser controls the destination)
  static Stream<SaveProgress> save({
    required SaveInput input,
    required FileType fileType,
    required String fileName,
    SaveLocation? saveLocation,
    String? subDir,
    ConflictResolution conflictResolution = ConflictResolution.autoRename,
  }) {
    return switch (input) {
      SaveBytesInput(:final fileBytes) => _platform.saveBytes(
        fileBytes: fileBytes,
        fileType: fileType,
        fileName: fileName,
        saveLocation: saveLocation,
        subDir: subDir,
        conflictResolution: conflictResolution,
      ),
      SaveFileInput(:final filePath) => _platform.saveFile(
        filePath: filePath,
        fileType: fileType,
        fileName: fileName,
        saveLocation: saveLocation,
        subDir: subDir,
        conflictResolution: conflictResolution,
      ),
      SaveNetworkInput(:final url, :final headers, :final timeout) =>
        _platform.saveNetwork(
          url: url,
          fileType: fileType,
          fileName: fileName,
          headers: headers,
          timeout: timeout,
          saveLocation: saveLocation,
          subDir: subDir,
          conflictResolution: conflictResolution,
        ),
    };
  }

  /// [Future] wrapper for [save] with an optional [onProgress] callback.
  ///
  /// **Platforms:** Android · iOS · macOS · Windows · Linux · Web
  ///
  /// Returns the saved [Uri]. Throws on error; throws [CancelledException] if cancelled.
  static Future<Uri> saveAsync({
    required SaveInput input,
    required FileType fileType,
    required String fileName,
    SaveLocation? saveLocation,
    String? subDir,
    ConflictResolution conflictResolution = ConflictResolution.autoRename,
    void Function(double progress)? onProgress,
  }) async {
    Uri? result;

    await for (final event in save(
      input: input,
      fileType: fileType,
      fileName: fileName,
      saveLocation: saveLocation,
      subDir: subDir,
      conflictResolution: conflictResolution,
    )) {
      switch (event) {
        case SaveProgressStarted():
          break;
        case SaveProgressUpdate(:final progress):
          onProgress?.call(progress);
        case SaveProgressComplete(:final uri):
          result = uri;
        case SaveProgressError(:final exception):
          throw exception;
        case SaveProgressCancelled():
          throw const CancelledException();
      }
    }

    if (result == null) {
      throw const NativePlatformException(
        'Save operation did not complete',
        'INCOMPLETE',
      );
    }
    return result;
  }

  /// Saves to a user-selected directory with progress streaming.
  ///
  /// **Platforms:** Android · iOS · macOS · Windows · Linux · Web
  ///
  /// If [saveLocation] is null, shows the directory picker first.
  /// Yields [SaveProgressCancelled] if the picker is dismissed.
  ///
  /// Web: falls back to anchor-download if the browser does not support FSA.
  static Stream<SaveProgress> saveAs({
    required SaveInput input,
    required FileType fileType,
    required String fileName,
    PickedDirectoryLocation? saveLocation,
    ConflictResolution conflictResolution = ConflictResolution.autoRename,
  }) async* {
    PickedDirectoryLocation? resolvedLocation = saveLocation;
    if (resolvedLocation == null) {
      try {
        final picked = await pickDirectory();
        if (picked == null) {
          yield const SaveProgressCancelled();
          return;
        }
        resolvedLocation = picked;
      } catch (e) {
        if (kIsWeb) {
          // Browser doesn't support FSA (Firefox / Safari).
          // Pass a plain PickedDirectoryLocation so FileSaverWeb.saveAs()
          // falls through to its anchor-download fallback.
          resolvedLocation = PickedDirectoryLocation(uri: Uri());
        } else {
          yield SaveProgressError(NativePlatformException(e.toString()));
          return;
        }
      }
    }

    yield* _platform.saveAs(
      input: input,
      fileType: fileType,
      fileName: fileName,
      saveLocation: resolvedLocation,
      conflictResolution: conflictResolution,
    );
  }

  /// [Future] wrapper for [saveAs] with an optional [onProgress] callback.
  ///
  /// **Platforms:** Android · iOS · macOS · Windows · Linux · Web
  ///
  /// Returns the saved [Uri], or null if the picker was cancelled.
  /// Throws on error.
  static Future<Uri?> saveAsAsync({
    required SaveInput input,
    required FileType fileType,
    required String fileName,
    PickedDirectoryLocation? saveLocation,
    ConflictResolution conflictResolution = ConflictResolution.autoRename,
    void Function(double progress)? onProgress,
  }) async {
    Uri? result;

    await for (final event in saveAs(
      input: input,
      fileType: fileType,
      fileName: fileName,
      saveLocation: saveLocation,
      conflictResolution: conflictResolution,
    )) {
      switch (event) {
        case SaveProgressStarted():
          break;
        case SaveProgressUpdate(:final progress):
          onProgress?.call(progress);
        case SaveProgressComplete(:final uri):
          result = uri;
        case SaveProgressError(:final exception):
          throw exception;
        case SaveProgressCancelled():
          return null;
      }
    }

    return result;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Session-based streaming write
  // ─────────────────────────────────────────────────────────────────────────

  /// Opens a streaming write session to an auto-resolved location.
  ///
  /// **Platforms:** Windows · Linux · Web (buffer fallback) · Android · iOS · macOS
  ///
  /// Returns a [FileSaverSink] that accepts incremental chunks via [FileSaverSink.add].
  /// Call [FileSaverSink.close] to finalize and obtain the saved file [Uri].
  /// Call [FileSaverSink.cancel] to abort and delete the partial file.
  ///
  /// [totalSize] is optional. When provided, [FileSaverSink.progress] emits
  /// per-chunk progress (0.0–1.0). [FileSaverSink.bytesWritten] always emits.
  ///
  /// Example:
  /// ```dart
  /// final sink = await FileSaver.openWrite(
  ///   fileName: 'recording',
  ///   fileType: CustomFileType('mp4', 'video/mp4'),
  ///   totalSize: expectedBytes,
  /// );
  ///
  /// if (sink == null) return; // conflictResolution is skip and the file exists.
  ///
  /// sink.progress.listen((p) => setState(() => _progress = p));
  /// sink.add(chunk);           // non-blocking
  /// await sink.addStream(src); // back-pressure friendly
  /// final uri = await sink.close();
  /// ```
  static Future<FileSaverSink?> openWrite({
    required String fileName,
    required FileType fileType,
    SaveLocation? saveLocation,
    String? subDir,
    int? totalSize,
    ConflictResolution conflictResolution = ConflictResolution.autoRename,
  }) {
    return _platform.openWrite(
      fileName: fileName,
      fileType: fileType,
      saveLocation: saveLocation,
      subDir: subDir,
      totalSize: totalSize,
      conflictResolution: conflictResolution,
    );
  }

  /// Opens a streaming write session to a user-selected directory.
  ///
  /// **Platforms:** Windows · Linux · Web (FSA) · Android · iOS · macOS
  ///
  /// If [saveLocation] is null, shows the directory picker first.
  /// Returns null if the picker is cancelled.
  /// Returns null if [conflictResolution] is [ConflictResolution.skip] and the
  /// target file already exists.
  ///
  /// Web: uses [FileSystemWritableFileStream] (FSA) when the browser supports it,
  /// falls back to in-memory buffering otherwise.
  static Future<FileSaverSink?> openWriteAs({
    required String fileName,
    required FileType fileType,
    PickedDirectoryLocation? saveLocation,
    int? totalSize,
    ConflictResolution conflictResolution = ConflictResolution.autoRename,
  }) async {
    PickedDirectoryLocation? resolvedLocation = saveLocation;
    if (resolvedLocation == null) {
      try {
        final picked = await pickDirectory();
        if (picked == null) return null;
        resolvedLocation = picked;
      } catch (e) {
        if (kIsWeb) {
          // Browser doesn't support FSA — fall through to buffer mode.
          resolvedLocation = PickedDirectoryLocation(uri: Uri());
        } else {
          rethrow;
        }
      }
    }
    return _platform.openWriteAs(
      fileName: fileName,
      fileType: fileType,
      saveLocation: resolvedLocation,
      totalSize: totalSize,
      conflictResolution: conflictResolution,
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Directory picker, file access, and open-in-app functionality
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
  static Future<PickedDirectoryLocation?> pickDirectory({
    bool shouldPersist = true,
  }) {
    return _platform.pickDirectory(shouldPersist: shouldPersist);
  }

  /// Checks whether the file at [uri] is accessible for reading.
  ///
  /// **Platforms:** Android · iOS · macOS · Windows · Linux
  /// **Web:** throws [UnsupportedError]
  ///
  /// On Android, both `content://` and `file://` URIs are supported.
  /// On iOS, both `file://` and `ph://` (Photos assets) URIs are supported.
  ///
  /// Use this before calling [openFile] or passing the URI to third-party
  /// libraries to confirm the file has not been deleted.
  ///
  /// Returns `false` if the file has been deleted or is no longer accessible.
  static Future<bool> canOpenFile(Uri uri) => _platform.canOpenFile(uri);

  /// Opens a saved file with the appropriate system app.
  ///
  /// **Platforms:** Android · iOS · macOS · Windows · Linux
  /// **Web:** throws [UnsupportedError] — files are already browser-downloaded.
  ///
  /// [uri] should be a [Uri] returned from a save operation (for example: [saveAsync],
  /// [SaveProgressComplete.uri], or a write-session result like [FileSaverSink.result]).
  ///
  /// [mimeType] is optional.
  /// - Android: for `content://` URIs it is queried from ContentResolver if not provided.
  ///   For `file://` URIs it is inferred from the file extension when possible.
  /// - Other platforms may ignore this parameter.
  ///
  /// **Android note:** If [uri] is a `file://...` URI (for example, when saving via
  /// `PathLocation`), opening it requires a `FileProvider` configuration in the host app.
  /// See the "Android Configuration" section on pub.dev.
  ///
  /// **iOS note:** `ph://` URIs (Photos Library assets) are opened via an in-app
  /// system preview (QuickLook).
  static Future<void> openFile(Uri uri, {String? mimeType}) =>
      _platform.openFile(uri, mimeType: mimeType);
}
