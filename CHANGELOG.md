## Unreleased

### Changed

- **Android:** the consumer ProGuard/R8 rules now only keep what the JNI bindings look up by name: `FileSaver`, `FileSaver$Companion` and `ProgressCallback`, plus the names of two types in their signatures. Before, they kept all of `kotlinx.coroutines`, `kotlin.coroutines` and `kotlin.jvm.internal`, and turned on `-keepparameternames` and `-keepattributes … Signature, Exceptions, Metadata` for the whole app, so release builds of apps using the plugin shrank and obfuscated less.
- **Android:** the plugin now declares `minSdk 24` (Android 7.0), and the README says so. This matches what apps already needed: the `dir_picker` dependency requires API 24, so an app with a lower `minSdk` failed at manifest merge. The README previously claimed API 21+.
- **Android:** `openFile` of a file that no longer exists now throws `SourceFileNotFoundException`, as on iOS, macOS, Windows and Linux. Before, it threw `OpenFailedException('File is not accessible')`. A file that exists but can't be opened still throws `OpenFailedException`. Examples are a file with no app to open it, or a `file://` URI without the FileProvider setup. Its message now explains the cause, without the Java exception name and stack trace it used to include.

### Fixed

- **Android:** `ConflictResolution.skip` no longer writes anything when the file exists. It completes with the existing file's URI on every backend. Previously it created a duplicate (`photo (1).jpg`) on Android 10+, overwrote the file on Android 9 and below, and wrote into the existing document for user-picked (SAF) directories, which could delete that document if the write then failed.
- **Android:** `ConflictResolution.overwrite` replaces the existing file only after the new content has been written. A failed or cancelled save now keeps the original. Previously the original was deleted before writing. If the original cannot be deleted (for example a MediaStore file owned by another app), the new file is kept under its auto-renamed name.
- **Android:** images, videos and audio saved on Android 9 and below are now passed to the media scanner, so they appear in gallery and music apps right away instead of after the next system scan.
- **Android:** a cancelled or failed save on Android 9 and below now deletes the partial file, and a MediaStore entry or SAF document is no longer left behind when its output stream cannot be opened.
- **Android:** an unexpected error in `openWrite`/`openWriteAs` or in a write-session chunk no longer crashes the app. Examples are a `PickedDirectoryLocation` that isn't a directory tree URI, a revoked directory permission, or a file type the MediaStore collection rejects. The error is reported as a `FileSaverException` instead, and the session no longer hangs.
- **Android:** the final `SaveProgressComplete`/`SaveProgressError` event of a save can no longer be dropped when progress events pile up, which left the stream open forever.
- **Android:** a video saved to `AndroidSaveLocation.dcim` (or `pictures`, where newer Android versions accept videos) now works on Android 10+. The MediaStore collection is now picked from the file's MIME type instead of the location, so it went to the Images collection and failed. Combinations Android doesn't accept, such as an image in `movies` or a PDF in `pictures`, now fail with `InvalidInputException` that names the file type and directory, instead of `NativePlatformException`.
- **Android:** a `subDir` with a `..` segment is rejected with `InvalidInputException`. On Android 9 and below it could write outside the public directory.
- **Android:** a save whose MediaStore entry can't be published (clearing `IS_PENDING` fails) now fails with `FileIOException` and removes the entry. Before, it was reported as complete although the file stayed invisible and was purged by the system after about a week.
- **Android:** a save that fails with an unexpected error while writing, such as a revoked permission, no longer leaves its new MediaStore entry, file or SAF document behind.
- **Android:** on Android 9 and below, `autoRename` of a file without an extension now produces `name (1)` instead of `name (1).`.
- **Android:** a network download that fails while the body is transferring (timeout, connection reset, or a body shorter than its `Content-Length`) now fails with `NetworkException`. Before, it was a `FileIOException`, and a body that ended early could even be saved as a truncated file.
- **Android:** cancelling a network download now closes the connection right away. Before, a cancel during a stalled connect or read waited for the `timeout` (60 s by default) before the partial file was removed.
- **Android:** network downloads now follow redirects between http and https, up to 5 hops. `Authorization`, `Cookie` and `Proxy-Authorization` headers are not sent to another host after a redirect.
- **Android:** on Android 9 and below, saves that need the storage permission while its dialog is showing now wait for that dialog's answer. Before, the first save hung forever and the second failed with `PermissionDeniedException` even when the user allowed it.
- **Android:** an app with more than one Flutter engine (add-to-app, background engines) no longer breaks saving in the remaining engines when one engine is destroyed. Before, saves then failed with "FileSaver not initialized", and `saveAs` threw instead of returning an error event. The permission dialog is shown in the Activity of the most recently attached engine.
- **Android:** with a cached engine (add-to-app), the answer to the storage permission dialog is no longer lost when the Activity is recreated by a configuration change while the dialog is showing. Before, the save failed with `PermissionDeniedException`.
- **Android:** when a Flutter engine is destroyed while the app process keeps running, its running saves are now cancelled and their partial files deleted, and its open `openWrite`/`openWriteAs` sessions are discarded. This happens, for example, when the user backs out of the app or an add-to-app screen closes. Before, a download kept running with nothing left to report to, and an open write session left a pending (invisible) MediaStore file until the system purged it. Saves of other engines, and of background isolates, are not affected.
- **Android:** repeated `save`/`saveAs` calls with large `SaveInput.bytes` no longer run the app out of Java heap memory. Each call's copy of the bytes, and its string arguments, are now released once the native call returns. Before, they stayed alive until a Dart garbage collection, which doesn't track Java memory, so a few saves of 32 MB crashed the app with `OutOfMemoryError`.
- **Android:** `canOpenFile` and `openFile` no longer block the calling thread, which is the UI thread, while Android checks the file. For MediaStore and SAF files that check is a call to another process.
- **Android:** saving to a user-picked directory (`saveAs`, `openWriteAs`) checks for an existing file and picks an `autoRename` name from a single directory listing. Before, it listed the directory again for every name it tried, with one IPC call per file in it. A save into a directory with 100 files named `note (n).txt` took 16–21 s on a Galaxy S22 and now takes under 0.25 s. `autoRename` also no longer fails when `name (999)` is the first free name, and continues past 999.
- **iOS/macOS:** `ConflictResolution.skip` no longer writes anything when the file exists, and completes with the existing file's URI. Previously it truncated and rewrote the existing file, and a failed or cancelled network download then deleted it.
- **iOS/macOS:** `ConflictResolution.overwrite` replaces the existing file only after the new content has been written: the content goes to a temporary file in the same directory, which replaces the original on success. A failed or cancelled save, including a cancelled `openWrite` session, now keeps the original. Previously it was deleted before writing started.
- **iOS:** `overwrite` to the Photos Library saves the new asset first and deletes the old one afterwards. If the user declines the deletion prompt, both are kept.
- **iOS:** conflict lookup for a Photos album that doesn't exist yet no longer searches the whole library, so `skip`, `fail` and `overwrite` can't match (or delete) a same-named asset outside the album.
- **iOS/macOS:** a failed save no longer leaves a partial file behind. Previously only cancellation removed it.
- **iOS:** concurrent network or video saves with the same file name no longer share a temporary file.


## 0.10.1

### Fixed

- **Windows/Linux:** save errors now surface as their specific exception (`NetworkException`, `SourceFileNotFoundException`, `FileExistsException`, …) instead of being wrapped in `NativePlatformException`.
- **Windows/Linux:** cancelling a network download, or hitting the inactivity `timeout`, now stops the transfer and deletes the partial file even when the server stops sending data. Previously the download could hang indefinitely. A timeout is reported as `NetworkException`.
- **Web:** `flutter build web --wasm` now compiles. The FFI/JNI implementations are excluded with `dart.library.js_interop` instead of `dart.library.html`, which is false under dart2wasm. The `dir_picker` constraint is raised to `^0.5.1`, which contains the matching fix. Thanks to [@coco-de-dev](https://github.com/coco-de-dev) ([#16](https://github.com/iamv4g/file_saver_ffi.flutter/pull/16)).
- **Windows:** `openFile` now opens files with `ShellExecuteExW` instead of `cmd /c start`. File names containing characters that are special to `cmd` (such as `&`, `^` or `%`) are passed to the Shell unchanged, so these files now open correctly.

## 0.10.0

### Breaking Changes

- **Minimum supported SDK raised to Flutter 3.44 / Dart 3.12** (required for built-in Kotlin).

### Changed

- Migrated the Android plugin and example app to built-in Kotlin (removes the Kotlin Gradle Plugin).
- Update `dir_picker` dependency to `^0.5.0` (also migrated to built-in Kotlin).

## 0.9.2

### Added

- **Swift Package Manager support** for iOS and macOS (CocoaPods is still supported).
  - Native sources moved to `darwin/file_saver_ffi/Sources/` with a new `Package.swift`.
  - The Dart API shim is now the `FileSaverDartApi` C target, with prefixed symbols (`FileSaver_InitializeApiDL`, `FileSaver_PostCObject_DL`) so it no longer clashes with other FFI plugins (e.g. `dir_picker`) when statically linked.

## 0.9.1

- Update `jni` dependency to `1.0.0`
- Update `jnigen` dev dependency to `0.16.0`

## 0.9.0

### Breaking Changes

- **Renamed exceptions and locations:**
  - `UserSelectedLocation` has been renamed to `PickedDirectoryLocation`.
  - `WebSelectedLocation` has been renamed to `WebPickedDirectoryLocation`.
  - `PlatformException` has been renamed to `NativePlatformException` to avoid conflict with the `PlatformException` from the Flutter SDK.

### Added

- **Stream-based incremental file writing**:
  - `FileSaver.openWrite(SaveInput)`: Opens a file for incremental writing and returns a `FileSaverSink`.
  - `FileSaver.openWriteAs(SaveInput)`: Opens a file for incremental writing via system directory picker and returns a `FileSaverSink`.
- **Custom path support**:
  - `PathLocation`: Allows saving files directly to specific filesystem directory paths.
- **`file://` URI support**:
  - `FileSaver.canOpenFile(Uri)` and `FileSaver.openFile(Uri)` now support `file://` URIs.

## 0.8.3

### Added

- **`FileSaver.canOpenFile(Uri)`** — Checks whether the file at [uri] is accessible for reading.
  - Supported on Android, iOS, macOS, Windows, and Linux.
  - Not supported on Web.

## 0.8.2

### Added

- **`FileSaver.openFile(Uri)`** — opens a saved file with the system viewer.
  - Supported on Android, iOS, macOS, Windows, and Linux.
  - Not supported on Web (files are already handled by the browser download mechanism).

## 0.8.1

### Fixed

- **Android: Fatal crash on startup** (SIGSEGV in `FindClassUnchecked`)
  - The native `FileSaver` JNI object was eagerly constructed during plugin registration
    (`registerWith()`), before `JniPlugin` had a chance to set up the JVM context in
    `libdartjni.so`. This caused a null-pointer dereference inside `FindClass`.

## 0.8.0

### Breaking Changes

- **Static API**: `FileSaver` no longer requires an instance. All methods are now static.
  - Before: `FileSaver.instance.saveBytes(...)` → After: `FileSaver.saveBytes(...)`
  - Before: `FileSaver.instance.saveFile(...)` → After: `FileSaver.saveFile(...)`
  - Before: `FileSaver.instance.saveNetwork(...)` → After: `FileSaver.saveNetwork(...)`
  - Before: `FileSaver.instance.save(...)` → After: `FileSaver.save(...)`
  - Before: `FileSaver.instance.saveAs(...)` → After: `FileSaver.saveAs(...)`
  - Before: `FileSaver.instance.pickDirectory(...)` → After: `FileSaver.pickDirectory(...)`
  - Before: `FileSaver.instance.dispose()` → After: removed (no longer needed)

### Removed

The following methods have been removed. Use `save()` / `saveAsync()` with a `SaveInput` instead:

- `saveBytes()` → `save(input: SaveInput.bytes(...))`
- `saveBytesAsync()` → `saveAsync(input: SaveInput.bytes(...))`
- `saveFile()` → `save(input: SaveInput.file(...))`
- `saveFileAsync()` → `saveAsync(input: SaveInput.file(...))`
- `saveNetwork()` → `save(input: SaveInput.network(...))`
- `saveNetworkAsync()` → `saveAsync(input: SaveInput.network(...))`
- `dispose()` → removed (resources are managed automatically)

## 0.7.0

### Added

- **Web Support**: Full file saving support on Flutter Web

### Fixed

- **Desktop `saveNetwork`**: Added per-chunk idle timer — previously only the connection timeout was enforced; a stalled download would hang indefinitely after the connection was established

## 0.6.0

### Added

- **Linux Support**: Full file saving support on Linux — no native plugin code required
  - Directory resolution via XDG Base Directory Specification (`xdg-user-dirs`)
  - Supports all standard locations: `downloads`, `pictures`, `videos`, `music`, `documents`
  - Falls back to `~/Downloads` if XDG variable is not configured

### Refactored

- **`DesktopFileSaver` shared base class**: Extracted all common I/O logic (Windows + Linux)
  into an abstract `DesktopFileSaver` class. Each platform only implements `resolveDirectory()`.

## 0.5.0

### Added

- **Windows Support**: Full file saving support on Windows — no native C++ plugin code required

### Refactored

- **`FileSaverPlatform` is now a pure interface** — removed circular imports between the platform interface and
  platform implementations. Platform initialization is handled uniformly in `FileSaver._()` for all platforms.

## 0.4.0

### Added

- **macOS Support**: Save files to macOS directories using FFI with shared Darwin source code
- **Android: Automatic storage permission handling** for Android 9 and below

### Fixed

- **Network save: file deleted immediately after successful download**
  - `invalidateAndCancel()` triggered `didCompleteWithError` with cancellation error, which deleted the saved file
  - Replaced with `finishTasksAndInvalidate()` to allow the task to complete normally
  - Affected all platforms using native network save (`saveNetwork` / `saveNetworkAs`)
- **iOS: Network save to Photos requested permission after download**
  - Permission and conflict resolution are now checked before starting the download
  - Avoids wasting bandwidth if permission is denied or file already exists (skip/fail)

## 0.3.1

### Fixed

- **iOS: Photos Library crash on iOS 14+ with add-only permission** (`PHPhotosErrorDomain error 3311`)
  - Previously requested `.addOnly` permission but incorrectly treated it as having read access
  - This caused crashes when attempting album creation or conflict resolution without read permission
  - Now requests the appropriate permission level based on usage:
    - With `subDir` (album name): requests `.readWrite` for album & conflict resolution support
    - Without `subDir`: requests `.addOnly` for basic save

## 0.3.0

### Breaking Changes

- **Renamed `InvalidFileException` to `InvalidInputException`**
  - Error code changed from `INVALID_FILE` to `INVALID_INPUT`
  - This aligns error codes between iOS and Android platforms
  - Migration: Replace `InvalidFileException` with `InvalidInputException` in your catch blocks

### Added

- **User-Selected Directory Support**:
  - `pickDirectory()`: Show system directory picker (Android SAF / iOS Document Picker)
  - `saveAs()`: Stream-based API to save to user-selected directory using `SaveInput`
  - `saveAsync()`: Async wrapper for [saveAs] with optional progress callback.
- **Save Locations Update**: Add UserSelectedLocation for User-selected directory location

## 0.2.0

### Added

- **Network Save Support**:
  - `saveNetwork()`: Stream-based API to download and save files directly from URLs
  - `saveNetworkAsync()`: Future-based API for network downloads with optional progress callback
  - Native optimization: Downloads directly to storage to avoid double storage (memory + disk)
  - Supports custom HTTP headers and timeouts

- **Unified API Entrypoints**:
  - `save()`: Single stream-based entrypoint using `SaveInput` sealed class (`SaveBytesInput`, `SaveFileInput`,
    `SaveNetworkInput`)
  - `saveAsync()`: Single future-based entrypoint using `SaveInput`
  - Allows polymorphic usage: `FileSaver.instance.save(input: SaveNetworkInput(...))`

### Refactored

- Source code refactoring

## 0.1.1

### Documentation

- **Save Locations Update**: Split table into separate `AndroidSaveLocation` and `IosSaveLocation` sections to clarify
  distinct enums

## 0.1.0

### Breaking Changes

- **`saveBytes()` now returns `Stream<SaveProgress>`** instead of `Future<Uri>`
  - Renamed `saveBytes` parameter from `bytes` to `fileBytes`.
  - Renamed `saveBytesAsync` parameter from `bytes` to `fileBytes`.

### Added

- **`saveFile()` method**: Save files from source path instead of bytes in memory
  - Stream-based API returning `Stream<SaveProgress>` for real-time progress tracking
  - Handles large files efficiently without loading entire file into RAM
  - Supports `file://` paths and picker results

- **`saveFileAsync()` method**: Convenience API returning `Future<Uri>` with optional `onProgress` callback

  ```dart
  final uri = await FileSaver.instance.saveFileAsync(
    filePath: '/path/to/source/video.mp4',
    fileName: 'my_video',
    fileType: VideoType.mp4,
    onProgress: (progress) => print('${(progress * 100).toInt()}%'),
  );
  ```

- **True Cancellation Support**: Cancel save operations mid-stream with proper cleanup
  - Call `subscription.cancel()` or break from `await for` loop to cancel
  - Native code stops I/O operations between chunks (1MB)
  - Partial files are automatically deleted on cancellation
  - `SaveProgressCancelled` event emitted on successful cancellation
  - Works for both `saveBytes()` and `saveFile()` streams

  ```dart
  // Example: Cancel with subscription
  final subscription = FileSaver.instance.saveBytes(...).listen((event) {
    if (event is SaveProgressCancelled) {
      print('Cancelled and cleaned up!');
    }
  });

  // Cancel when needed
  await subscription.cancel();

  // Example: Cancel with await for
  await for (final event in FileSaver.instance.saveBytes(...)) {
    if (shouldCancel) break;  // Triggers native cancellation
    // handle event...
  }
  ```

- **iOS iCloud download progress**: When saving files from iCloud Drive, progress is split into 2 phases:
  - Phase 1 (0% → 50%): iCloud download progress
  - Phase 2 (50% → 100%): Copy to destination progress

- **New exceptions**:
  - `FileNotFoundException`: Source file not found
  - `ICloudDownloadException`: iCloud download failed or timed out (iOS only)

### Changed

- **Simplified FormatValidator**: Removed codec/encoder validation on both platforms
  - iOS: Removed AVAssetWriter and ImageIO validation
  - Android: Removed MediaCodecList encoder checks
  - Now only validates MIME type category (image/video/audio)
  - Rationale: This library is a file saver, not a media player. Files are written as raw bytes without
    encoding/decoding. The developer is responsible for choosing appropriate formats.

### Fixed

- **iOS video filename**: Videos saved to Photos Library now preserve the specified filename instead of using UUID
- **iOS audio format crash**: Fixed crash when saving MP3 and other audio formats that AVAssetWriter doesn't support
- **Android audio format rejection**: Fixed rejection of audio formats not in MediaCodecList (AMR, OPUS, etc.)

## 0.0.5

### Breaking Changes

- **`saveBytes()` now returns `Stream<SaveProgress>`** instead of `Future<Uri>`
  - Enables real-time progress tracking during save operations
  - Use `saveBytesAsync()` for the previous `Future<Uri>` behavior

### Added

- **`SaveProgress` sealed class** for streaming progress events:
  - `SaveProgressStarted` - Operation started
  - `SaveProgressUpdate(double progress)` - Progress 0.0 to 1.0
  - `SaveProgressComplete(Uri uri)` - Success with file URI
  - `SaveProgressError(FileSaverException)` - Error occurred
  - `SaveProgressCancelled` - User cancelled
- **`saveBytesAsync()` method** - Convenience API returning `Future<Uri>` with optional `onProgress` callback
- **Real progress reporting for iOS** - Chunked file writes with progress callbacks (1MB chunks)

### Migration Guide

- To migrate from version 0.0.4 to 0.0.5, update your code as follows:

  ```dart
  // Before (0.0.4)
  final uri = await FileSaver.instance.saveBytes(...);

  // After (0.0.5) - Option 1: Use saveBytesAsync (minimal change)
  final uri = await FileSaver.instance.saveBytesAsync(...);

  // After (0.0.5) - Option 2: Use saveBytesAsync with progress
  final uri = await FileSaver.instance.saveBytesAsync(
    ...,
    onProgress: (progress) => print('${(progress * 100).toInt()}%'),
  );

  // After (0.0.5) - Option 3: Use saveBytes stream for full control
  await for (final event in FileSaver.instance.saveBytes(...)) {
    switch (event) {
      case SaveProgressStarted(): showLoading();
      case SaveProgressUpdate(:final progress): updateUI(progress);
      case SaveProgressComplete(:final uri): handleSuccess(uri);
      case SaveProgressError(:final exception): handleError(exception);
      case SaveProgressCancelled(): handleCancel();
    }
  }
  ```

## 0.0.4

### Added

- **SaveLocation Feature**: Explicit control over save locations with platform-specific enums
  - Android: `pictures`, `movies`, `music`, `downloads` (default), `dcim`
  - iOS: `photos` (Photos Library), `documents` (default, no permission)
  - Type-safe sealed class design with platform defaults

### Changed

- Added optional `saveLocation` parameter to `saveBytes()`
- Standardized parameter order: `saveLocation` now before `subDir`

### Breaking Changes

- **Default locations changed** for better UX:
  - Android: All files → Downloads (was type-based: Images→Pictures, Videos→Movies, etc.)
  - iOS: All files → Documents (was Images/Videos→Photos Library)
- **Migration**: Explicitly set `saveLocation` to maintain old behavior:
  ```dart
  saveLocation: Platform.isAndroid
    ? AndroidSaveLocation.pictures
    : [PlatformX]SaveLocation.photos
  ```

## 0.0.3

### Added

- **OVERWRITE Functionality**: Fully implemented overwrite conflict resolution
  - Android (Legacy): Delete existing file and save new one
  - Android 10+: Delete existing file via ContentResolver
  - iOS: Optimized with early return check
- **Platform Behavior Documentation**: Comprehensive guide for overwrite behavior
  - iOS Photos: Own files overwritten; other apps' files create duplicates
  - iOS Documents: Full overwrite capability (sandboxed per app)
  - Android 10+: Only detects/overwrites own files; other apps' files auto-renamed
  - Platform comparison table in README
- **iOS 14+ Dialog Prevention**: Added `PHPhotoLibraryPreventAutomaticLimitedAccessAlert` key
  - Prevents automatic "Select More Photos" prompt on iOS 14+
  - Provides better user experience with limited photos access
  - Documented in README with setup instructions

### Refactored

- **iOS Code Quality**: Extracted common logic from ImageSaver and VideoSaver
  - Moved `findOrCreateAlbum()` to BaseFileSaver extension
  - Moved `handlePhotosConflictResolution()` to BaseFileSaver extension
  - Removed 38 lines of duplicated code for better maintainability

## 0.0.2

- Refactor `FileSaverIos` to use NativeFinalizer + Arena for safer native resource management, more robust, and less
  prone to native memory leaks while maintaining performance.
- Make `FileSaverPlatform.instance` a true singleton
- Update document and README.md

## 0.0.1

- Initial version
