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

  /// [fileName] without a trailing `.ext` of [fileType], which every
  /// platform appends: `photo.png` and `photo.PNG` become `photo` for
  /// [ImageType.png], so the file isn't saved as `photo.png.png`.
  static String _baseName(String fileName, FileType fileType) {
    final ext = fileType.ext;
    if (ext.isEmpty || fileName.length <= ext.length + 1) return fileName;
    final suffix = fileName.substring(fileName.length - ext.length - 1);
    return suffix.toLowerCase() == '.${ext.toLowerCase()}'
        ? fileName.substring(0, fileName.length - suffix.length)
        : fileName;
  }

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
  ///
  /// Cancelling the subscription cancels the save: the stream emits nothing
  /// more, and the cancel completes once the partial file is deleted.
  ///
  /// The stream is single-subscription. The save starts when it is listened
  /// to, and listening again throws a [StateError] instead of saving the file
  /// a second time.
  ///
  /// [saveLocation] defaults by platform:
  /// - Android: [AndroidSaveLocation.downloads]
  /// - iOS: [IosSaveLocation.documents]
  /// - macOS / Windows / Linux: user's Downloads folder
  /// - Web: ignored (browser controls the destination)
  ///
  /// A location of another platform, such as [IosSaveLocation.photos] on
  /// macOS, throws [InvalidInputException], and so does a
  /// [PickedDirectoryLocation]: pass it to [saveAs].
  ///
  /// [fileName] is the name without the extension, which [fileType] adds. A
  /// name that already ends with it is saved once: `photo.png` with
  /// [ImageType.png] gives `photo.png`. On Windows, Linux and with a
  /// [PathLocation], a name with `/` (on Windows also `\ < > : " | ? *` or a
  /// device name such as `CON`), and a [subDir] that is absolute or contains
  /// `..`, throw [InvalidInputException].
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
        fileName: _baseName(fileName, fileType),
        saveLocation: saveLocation,
        subDir: subDir,
        conflictResolution: conflictResolution,
      ),
      SaveFileInput(:final filePath) => _platform.saveFile(
        filePath: filePath,
        fileType: fileType,
        fileName: _baseName(fileName, fileType),
        saveLocation: saveLocation,
        subDir: subDir,
        conflictResolution: conflictResolution,
      ),
      SaveNetworkInput(:final url, :final headers, :final timeout) =>
        _platform.saveNetwork(
          url: url,
          fileType: fileType,
          fileName: _baseName(fileName, fileType),
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
  /// Returns the saved [Uri]. Throws on error.
  static Future<Uri> saveAsync({
    required SaveInput input,
    required FileType fileType,
    required String fileName,
    SaveLocation? saveLocation,
    String? subDir,
    ConflictResolution conflictResolution = ConflictResolution.autoRename,
    void Function(double progress)? onProgress,
  }) async {
    final uri = await _result(
      save(
        input: input,
        fileType: fileType,
        fileName: fileName,
        saveLocation: saveLocation,
        subDir: subDir,
        conflictResolution: conflictResolution,
      ),
      onProgress,
    );
    return uri ?? (throw const CancelledException());
  }

  /// Runs [saves] to its end and returns the [Uri] of its
  /// [SaveProgressComplete], or null for [SaveProgressCancelled].
  ///
  /// Throws the exception of a [SaveProgressError], and a
  /// [NativePlatformException] with [FileSaverErrorCode.incomplete] if the
  /// stream ends without a result.
  static Future<Uri?> _result(
    Stream<SaveProgress> saves,
    void Function(double progress)? onProgress,
  ) async {
    await for (final event in saves) {
      switch (event) {
        case SaveProgressStarted():
          break;
        case SaveProgressUpdate(:final progress):
          onProgress?.call(progress);
        case SaveProgressComplete(:final uri):
          return uri;
        case SaveProgressError(:final exception):
          throw exception;
        case SaveProgressCancelled():
          return null;
      }
    }
    throw const NativePlatformException(
      'Save operation did not complete',
      FileSaverErrorCode.incomplete,
    );
  }

  /// Saves to a user-selected directory with progress streaming.
  ///
  /// **Platforms:** Android · iOS · macOS · Windows · Linux · Web
  ///
  /// If [saveLocation] is null, shows the directory picker first.
  /// Yields [SaveProgressCancelled] if the picker is dismissed. Cancelling the
  /// subscription works as in [save], and the stream is single-subscription
  /// too.
  ///
  /// Web: falls back to anchor-download if the browser has no
  /// `showDirectoryPicker()` (Firefox, Safari). Other picker errors, such as
  /// a missing user gesture, are reported as [SaveProgressError].
  ///
  /// [fileName] works as in [save]. Invalid input, such as empty bytes or a
  /// non-HTTP URL, throws [InvalidInputException] when [saveAs] is called,
  /// as with [save], before the picker opens.
  static Stream<SaveProgress> saveAs({
    required SaveInput input,
    required FileType fileType,
    required String fileName,
    PickedDirectoryLocation? saveLocation,
    ConflictResolution conflictResolution = ConflictResolution.autoRename,
  }) {
    final baseName = _baseName(fileName, fileType);
    _platform.validateSaveAsInput(
      input: input,
      fileName: baseName,
      fileType: fileType,
    );
    return _saveAs(
      input: input,
      fileType: fileType,
      fileName: baseName,
      saveLocation: saveLocation,
      conflictResolution: conflictResolution,
    );
  }

  static Stream<SaveProgress> _saveAs({
    required SaveInput input,
    required FileType fileType,
    required String fileName,
    required PickedDirectoryLocation? saveLocation,
    required ConflictResolution conflictResolution,
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
      } on UnsupportedError catch (e) {
        if (!kIsWeb) {
          yield SaveProgressError(NativePlatformException(e.toString()));
          return;
        }
        // The browser has no showDirectoryPicker() (Firefox / Safari). A
        // plain PickedDirectoryLocation makes FileSaverWeb.saveAs() fall
        // through to its anchor-download fallback.
        resolvedLocation = PickedDirectoryLocation(uri: Uri());
      } catch (e) {
        yield SaveProgressError(FileSaverException.fromObj(e));
        return;
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
  /// Throws on error, and like [saveAsync] a [NativePlatformException] with
  /// [FileSaverErrorCode.incomplete] if the save ends without a result.
  static Future<Uri?> saveAsAsync({
    required SaveInput input,
    required FileType fileType,
    required String fileName,
    PickedDirectoryLocation? saveLocation,
    ConflictResolution conflictResolution = ConflictResolution.autoRename,
    void Function(double progress)? onProgress,
  }) async {
    return _result(
      saveAs(
        input: input,
        fileType: fileType,
        fileName: fileName,
        saveLocation: saveLocation,
        conflictResolution: conflictResolution,
      ),
      onProgress,
    );
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
  /// [saveLocation] works as in [save]: a location of another platform, or a
  /// [PickedDirectoryLocation] (pass it to [openWriteAs]), throws
  /// [InvalidInputException].
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
  ///
  /// [fileName] works as in [save].
  static Future<FileSaverSink?> openWrite({
    required String fileName,
    required FileType fileType,
    SaveLocation? saveLocation,
    String? subDir,
    int? totalSize,
    ConflictResolution conflictResolution = ConflictResolution.autoRename,
  }) {
    return _platform.openWrite(
      fileName: _baseName(fileName, fileType),
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
  /// falls back to in-memory buffering when it has no `showDirectoryPicker()`.
  /// Other picker errors are thrown.
  ///
  /// [fileName] works as in [save]. An invalid name throws
  /// [InvalidInputException] before the picker opens.
  static Future<FileSaverSink?> openWriteAs({
    required String fileName,
    required FileType fileType,
    PickedDirectoryLocation? saveLocation,
    int? totalSize,
    ConflictResolution conflictResolution = ConflictResolution.autoRename,
  }) async {
    final baseName = _baseName(fileName, fileType);
    _platform.validateSaveAsInput(fileName: baseName, fileType: fileType);
    PickedDirectoryLocation? resolvedLocation = saveLocation;
    if (resolvedLocation == null) {
      try {
        final picked = await pickDirectory();
        if (picked == null) return null;
        resolvedLocation = picked;
      } on UnsupportedError {
        if (!kIsWeb) rethrow;
        // The browser has no showDirectoryPicker() — fall through to buffer
        // mode.
        resolvedLocation = PickedDirectoryLocation(uri: Uri());
      }
    }
    return _platform.openWriteAs(
      fileName: baseName,
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
  /// [shouldPersist] is Android-only and deprecated: if true, the picked
  /// directory is persisted as with [persistDirectory], but the token is
  /// discarded, so it can't be released. Call [persistDirectory] instead,
  /// which works on every platform. Ignored on all other platforms.
  ///
  /// Returns [PickedDirectoryLocation], or null if cancelled.
  /// Throws [UnsupportedError] on browsers without `showDirectoryPicker()`
  /// (Firefox, Safari), and [NativePlatformException] if the picker fails;
  /// its `code` is the `DirPickerException.code` of `dir_picker`, such as
  /// `ALREADY_ACTIVE` when another pick is still open.
  static Future<PickedDirectoryLocation?> pickDirectory({
    @Deprecated(
      'Call persistDirectory on the result instead; it works on every '
      'platform and returns a token for restoreDirectory and '
      'releaseDirectory. shouldPersist will be removed in 1.0.0, and '
      'pickDirectory will then no longer persist on Android.',
    )
    bool shouldPersist = true,
  }) {
    return _platform.pickDirectory(shouldPersist: shouldPersist);
  }

  /// Keeps access to [location] after the app restarts, and returns a token
  /// to store, for example in shared preferences. On a later launch, pass it
  /// to [restoreDirectory] to save to the same directory without asking the
  /// user again.
  ///
  /// **Platforms:** Android · iOS · macOS · Windows · Linux · Web
  ///
  /// [location] has to come from [pickDirectory] or [restoreDirectory].
  ///
  /// | Platform | Token | Keeps |
  /// |----------|-------|-------|
  /// | Android  | The `content://` URI | A persistable URI permission. The system keeps at most 128 per app (512 from Android 11) and drops the oldest, so [releaseDirectory] the ones you no longer need. |
  /// | iOS      | Bookmark data (base64) | A bookmark of the directory. |
  /// | macOS    | Security-scoped bookmark data (base64) | A security-scoped bookmark. A sandboxed app needs the `com.apple.security.files.user-selected.read-write` entitlement. |
  /// | Windows, Linux | The `file://` URI | Nothing: the path stays usable. |
  /// | Web      | A random key | The directory handle, in the IndexedDB database of `dir_picker`. Persisting the same directory again returns the same token. |
  ///
  /// ```dart
  /// final location = await FileSaver.pickDirectory();
  /// if (location != null) {
  ///   prefs.setString('exportDir', await FileSaver.persistDirectory(location));
  /// }
  /// ```
  ///
  /// Throws [InvalidInputException] for a location the platform can't
  /// persist, such as a `file://` URI on Android, and
  /// [NativePlatformException] when the platform refuses, for example on
  /// Android when the app no longer has access to the directory.
  static Future<String> persistDirectory(PickedDirectoryLocation location) {
    return _platform.persistDirectory(location);
  }

  /// Returns the directory a [persistDirectory] token points to, with access
  /// to it restored, or null when the token no longer gives access: the
  /// directory was deleted or moved out of reach, the permission was revoked
  /// or released with [releaseDirectory], or the token isn't from this
  /// platform. Ask the user with [pickDirectory] again then.
  ///
  /// **Platforms:** Android · iOS · macOS · Windows · Linux · Web
  ///
  /// On web the directory comes back, but the browser may not let the page
  /// write to it yet. Check `WebPickedDirectoryLocation.hasAccess`, and if it
  /// is false, call `requestAccess` from a button before saving.
  ///
  /// On iOS and macOS a bookmark goes stale when the directory is moved or
  /// renamed. It still restores, so persist the restored location and store
  /// the new token:
  ///
  /// ```dart
  /// final token = prefs.getString('exportDir');
  /// final location =
  ///     token == null ? null : await FileSaver.restoreDirectory(token);
  /// if (location != null) {
  ///   prefs.setString('exportDir', await FileSaver.persistDirectory(location));
  ///   await FileSaver.saveAsAsync(
  ///     input: SaveInput.bytes(bytes),
  ///     fileName: 'report',
  ///     fileType: CustomFileType(ext: 'pdf', mimeType: 'application/pdf'),
  ///     saveLocation: location,
  ///   );
  /// }
  /// ```
  ///
  /// Throws [NativePlatformException] if the platform call fails.
  static Future<PickedDirectoryLocation?> restoreDirectory(String token) {
    return _platform.restoreDirectory(token);
  }

  /// Gives up the access a [persistDirectory] token keeps, for a directory
  /// the app no longer needs. Delete the stored token too.
  ///
  /// **Platforms:** Android · iOS · macOS · Windows · Linux · Web
  ///
  /// - **Android**: releases the persisted permission, so [restoreDirectory]
  ///   returns null for the token.
  /// - **iOS, macOS**: a bookmark can't be revoked. This ends the access that
  ///   [restoreDirectory] (and on iOS, [pickDirectory]) started, which
  ///   otherwise lasts until the app exits.
  /// - **Windows, Linux**: does nothing.
  /// - **Web**: deletes the stored handle, so [restoreDirectory] returns
  ///   null for the token.
  ///
  /// Throws [NativePlatformException] if the platform call fails.
  static Future<void> releaseDirectory(String token) {
    return _platform.releaseDirectory(token);
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
