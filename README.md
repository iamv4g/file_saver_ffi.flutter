<p align="center">
  <img alt="cover" src="https://raw.githubusercontent.com/vanvixi/file_saver_ffi.flutter/main/screenshots/cover.png" />
</p>

## File Saver FFI

<p align="left">
  <a href="https://github.com/vanvixi/file_saver_ffi"><img src="https://img.shields.io/badge/platform-Android%20%7C%20iOS%20%7C%20macOS%20%7C%20Windows%20%7C%20Linux%20%7C%20Web-blue.svg" alt="Platform"></a>
  <a href="https://opensource.org/licenses/MIT"><img src="https://img.shields.io/badge/license-MIT-purple.svg" alt="License: MIT"></a>
  <a href="https://deepwiki.com/vanvixi/file_saver_ffi.flutter"><img src="https://deepwiki.com/badge.svg" alt="Ask DeepWiki"></a>
</p>

A high-performance file saver for Flutter supporting Android, iOS, macOS, Windows, Linux, and Web. Save to gallery,
device storage, or a user-chosen directory — with real-time progress tracking.

## Features

- 🖼️ **Gallery Saving** – Save images and videos to iOS Photos or Android Gallery with custom albums
- ⚡ **Native Performance** – Powered by FFI (iOS/macOS/Windows/Linux) and JNI (Android) for near-zero latency
- 🌐 **Web Support** – Browser download via anchor element or File System Access API (FSA) for Chrome/Edge
- 📁 **Universal Storage** – Save any file type (PDF, ZIP, DOCX, etc.) to device storage
- 💾 **Original Quality** – Files saved bit-for-bit without compression or metadata loss
- 📊 **Progress & Cancellation** – Real-time progress tracking with cancellable operations
- ⚙️ **Conflict Resolution** – Auto-rename, overwrite, skip, or fail on existing files

If you want to say thank you, star us on GitHub or like us on pub.dev.

## 🤖 Ask AI About This Library

Have questions about `file_saver_ffi`? Get instant AI-powered answers about the library's features, usage, and best
practices.

**[→ Chat with AI Documentation Assistant](https://deepwiki.com/vanvixi/file_saver_ffi.flutter)**

Ask anything like:

- "How do I save a video to the gallery with progress tracking?"
- "What's the difference between save and saveAs?"
- "How to handle permission errors on Android 10+?"
- "Show me examples of custom file types"

## Installation

First, follow the [package installation instructions](https://pub.dev/packages/file_saver_ffi/install) and add
`file_saver_ffi` to your app.

## Quick Start

### Platform Setup

<details>
<summary><b>Android Configuration</b></summary>

**Supported:** API 21+ (Android 5.0+)

For **Standard Save Locations** (Downloads, Pictures, etc.), no configuration is needed. The plugin automatically:
- Declares `WRITE_EXTERNAL_STORAGE` permission (merged via manifest merger, only applies to API ≤ 28)
- Requests runtime permission when needed (Android 9 and below)
- Uses scoped storage on Android 10+ (no permission required)

### Custom Paths (`PathLocation`)

Saving to custom paths on **Android 11+** requires the `MANAGE_EXTERNAL_STORAGE` permission. 

Add to `android/app/src/main/AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.MANAGE_EXTERNAL_STORAGE" />
```

> **Important:** You must also request this permission at runtime using a package like `permission_handler` before calling any `FileSaver` API with a `PathLocation` or `file://` URI on Android 11+.

### Opening `file://` URIs (PathLocation)

If you save to a filesystem directory path (e.g. `PathLocation(...)`), the returned URI can be `file://...`.
On Android, opening `file://` URIs requires a `FileProvider` (Android N+ blocks sharing raw `file://` URIs).

Only add this if you call `FileSaver.openFile(uri)` with `file://...` URIs.

Add to `android/app/src/main/AndroidManifest.xml`:

```xml
<provider
    android:name="androidx.core.content.FileProvider"
    android:authorities="${applicationId}.file_saver_ffi.fileprovider"
    android:exported="false"
    android:grantUriPermissions="true">
    <meta-data
        android:name="android.support.FILE_PROVIDER_PATHS"
        android:resource="@xml/file_saver_ffi_file_paths" />
</provider>
```

Create `android/app/src/main/res/xml/file_saver_ffi_file_paths.xml`:

```xml
<?xml version="1.0" encoding="utf-8"?>
<paths>
    <files-path name="files" path="." />
    <cache-path name="cache" path="." />
    <external-files-path name="external_files" path="." />
    <external-cache-path name="external_cache" path="." />
    <!-- Include this if you save to public external storage paths -->
    <external-path name="external" path="." />
</paths>
```

</details>

<details>
<summary><b>IOS Configuration</b></summary>

**Supported:** IOS 13.0+ (Swift Package Manager and CocoaPods)

Add to `ios/Runner/Info.plist`:

```xml
<!-- For Photos Library Access (images/videos) -->
<key>NSPhotoLibraryAddUsageDescription</key>
<string>This app needs permission to save photos and videos to your library</string>

<key>NSPhotoLibraryUsageDescription</key>
<string>This app needs permission to access your photo library</string>

<!-- Prevent automatic "Select More Photos" prompt on iOS 14+ -->
<key>PHPhotoLibraryPreventAutomaticLimitedAccessAlert</key>
<true/>

<!-- Optional: Make files visible in Files app -->
<key>UIFileSharingEnabled</key>
<true/>

<key>LSSupportsOpeningDocumentsInPlace</key>
<true/>
```

</details>

<details>
<summary><b>MacOS Configuration</b></summary>

**Supported:** macOS 10.15.4+ (Swift Package Manager and CocoaPods)

Add to `macos/Runner/DebugProfile.entitlements` and `macos/Runner/Release.entitlements`:

```xml
<!-- Required for network downloads -->
<key>com.apple.security.network.client</key>
<true/>

<!-- Required for directory picker (NSOpenPanel) -->
<key>com.apple.security.files.user-selected.read-write</key>
<true/>

<!-- Add entitlements for each MacosSaveLocation you use -->
<key>com.apple.security.files.downloads.read-write</key>
<true/>
<key>com.apple.security.assets.pictures.read-write</key>
<true/>
<key>com.apple.security.assets.movies.read-write</key>
<true/>
<key>com.apple.security.assets.music.read-write</key>
<true/>
```

> **Note:** Each `MacosSaveLocation` requires its corresponding entitlement in sandboxed apps. Only `MacosSaveLocation.documents` (App Container) works without any entitlement. Use `pickDirectory()` to let users choose directories outside the sandbox.


</details>

<details>
<summary><b>Windows Configuration</b></summary>

**Supported:** Windows 10+

No configuration needed. Files are saved directly to Windows Known Folders (Downloads, Pictures, Videos, Music, Documents).

</details>

<details>
<summary><b>Linux Configuration</b></summary>

**Supported:** Ubuntu 20.04+ and other modern Linux distributions

Enable Linux desktop support on your development machine:

```bash
flutter config --enable-linux-desktop
```

Install required system packages (if not already present):

```bash
sudo apt-get install -y \
  clang cmake ninja-build \
  libgtk-3-dev pkg-config \
  libblkid-dev liblzma-dev
```

No additional app configuration needed. Directories are resolved via the XDG Base Directory Specification (`xdg-user-dirs`).

</details>

<details>
<summary><b>Web Configuration</b></summary>

**Supported:** All modern browsers (Chrome / Edge 86+ recommended)

**Browser capabilities:**

| Feature                     | Chrome / Edge 86+                                             | Firefox                          | Safari                           |
|-----------------------------|---------------------------------------------------------------|----------------------------------|----------------------------------|
| `save` / `saveNetwork`      | ✅                                                             | ✅                                | ✅                                |
| `saveAs` (directory picker) | ✅ File System Access API                                      | ❌ falls back to browser download | ❌ falls back to browser download |
| Download progress           | ✅ `saveAs` + `SaveNetworkInput` only (needs `Content-Length`) | ❌                                | ❌                                |

**Download mechanism:**

| API           | Scenario              | Mechanism                                          | CORS required | Progress                   |
|---------------|-----------------------|----------------------------------------------------|---------------|----------------------------|
| `saveNetwork` | No custom `headers`   | `<a href=url download>` — browser native streaming | ❌             | ❌                          |
| `saveNetwork` | With custom `headers` | `window.fetch()` → Blob → `<a download>`           | ✅             | ❌                          |
| `saveAs`      | Chrome / Edge 86+     | FSA: streams chunks directly to disk (zero RAM)    | ✅             | ✅ (needs `Content-Length`) |
| `saveAs`      | Firefox / Safari      | Falls back to standard browser download            | —             | —                          |

> **Note:** `saveAs` with directory selection requires the app to be served over **HTTPS** or `localhost`. `http://` origins cannot use `showDirectoryPicker`.

See **[Web – Limitations](WEB_LIMITATIONS.md)** for CORS, memory usage, and browser-specific constraints.

</details>

### Basic Usage

```dart
import 'package:file_saver_ffi/file_saver_ffi.dart';

try {
  final uri = await FileSaver.saveAsync(
    input: SaveInput.bytes(imageBytes),
    fileName: 'my_image',
    fileType: ImageType.jpg,
  );

  print('Saved to: $uri');
} on PermissionDeniedException catch (e) {
  print('Permission denied: ${e.message}');
} on FileSaverException catch (e) {
  print('Save failed: ${e.message}');
}
```

## Core Concepts

### Unified API

The library provides a single, consistent API for all save operations using `SaveInput` polymorphism:

- **`save`**: Stream-based save to standard location (Downloads, Photos, etc.).
- **`saveAsync`**: Future-based save to standard location.
- **`saveAs`**: Stream-based save to a user-selected location (System Picker).
- **`saveAsAsync`**: Future-based save to a user-selected location.

#### Input Sources (`SaveInput`)

Use the appropriate input class for your data source:

| Input Type             | Data Source     | Use Case                                       |
|------------------------|-----------------|------------------------------------------------|
| **`SaveBytesInput`**   | `Uint8List`     | Small files in memory (images, generated PDFs) |
| **`SaveFileInput`**    | `String` (path) | Large files from disk (videos, recordings)     |
| **`SaveNetworkInput`** | `String` (URL)  | Download and save directly from internet       |

> **Web:** `SaveFileInput` is not supported and throws `InvalidInputException`. Use `SaveBytesInput` or `SaveNetworkInput` instead.


#### Usage Matrix 📊

|                                            | **Standard Location**<br>*(Downloads, Photos, etc.)* | **User-Chosen Location**<br>*(System Picker)* |
|:-------------------------------------------|:-----------------------------------------------------|:----------------------------------------------|
| **Advanced Control**<br>*(Stream, Cancel)* | **`save()`**                                         | **`saveAs()`**                                |
| **Simple / Await**<br>*(Future)*           | **`saveAsync()`**                                    | **`saveAsAsync()`**                           |

> *Standard Location*: defined enum (e.g., `Downloads`, `Photos`).
> *User-Chosen*: via `pickDirectory()` or auto-prompt.


### File Types

The library supports 35+ file formats across 4 categories:

| Category   | Formats                                              | Count | Example Types                                             |
|------------|------------------------------------------------------|-------|-----------------------------------------------------------|
| **Images** | PNG, JPG, GIF, WebP, BMP, HEIC, HEIF, TIFF, ICO, DNG | 12    | `ImageType.png`, `ImageType.jpg`                          |
| **Videos** | MP4, MOV, MKV, WebM, AVI, 3GP, M4V, FLV, WMV, HEVC   | 12    | `VideoType.mp4`, `VideoType.mov`                          |
| **Audio**  | MP3, AAC, WAV, FLAC, OGG, M4A, AMR, Opus, AIFF, CAF  | 11    | `AudioType.mp3`, `AudioType.aac`                          |
| **Custom** | Any format via extension + MIME type                 | ∞     | `CustomFileType(ext: 'pdf', mimeType: 'application/pdf')` |

### Save Locations

Control where files are saved using platform-specific enum values:

#### Platform Comparison

| Value        | Android (`AndroidSaveLocation`) | iOS (`IosSaveLocation`)  | macOS (`MacosSaveLocation`) | Windows (`WindowsSaveLocation`) | Linux (`LinuxSaveLocation`) |
|--------------|---------------------------------|--------------------------|-----------------------------|---------------------------------|-----------------------------|
| `.downloads` | **Downloads/** (default)        | -                        | **Downloads/** (default)    | **Downloads/** (default)        | **~/Downloads/** (default)  |
| `.pictures`  | **Pictures/**                   | -                        | **Pictures/**               | **Pictures/**                   | **~/Pictures/**             |
| `.movies`    | **Movies/**                     | -                        | **Movies/**                 | -                               | -                           |
| `.videos`    | -                               | -                        | -                           | **Videos/**                     | **~/Videos/**               |
| `.music`     | **Music/**                      | -                        | **Music/**                  | **Music/**                      | **~/Music/**                |
| `.dcim`      | **DCIM/**                       | -                        | -                           | -                               | -                           |
| `.documents` | -                               | **Documents/** (default) | **Documents/**              | **Documents/**                  | **~/Documents/**            |
| `.photos`    | -                               | **Photos Library**       | -                           | -                               | -                           |

> **Custom Paths (`PathLocation`):** You can also pass `PathLocation('/your/custom/path')` anywhere a `SaveLocation` is expected, to save files directly to specific filesystem directory paths across all platforms (except Web). **Note: On iOS, `PathLocation` only supports the app's document sandbox due to iOS system limitations.**

> **Web:** Platform-specific `SaveLocation` enums are not available. The `saveLocation` parameter in `save`/`saveAsync` is ignored — the browser controls the download destination (usually the Downloads folder). To save to a specific directory, use `saveAs` with `pickDirectory()` (requires Chrome / Edge 86+).


### Conflict Resolution

Handle existing files with 4 strategies:

| Strategy               | Behavior                           | Use Case                 |
|------------------------|------------------------------------|--------------------------|
| `autoRename` (default) | Appends (1), (2), etc. to filename | Safe, prevents data loss |
| `overwrite`            | Replaces existing file*            | Update existing files    |
| `fail`                 | Throws `FileExistsException`       | Strict validation        |
| `skip`                 | Returns existing file URI          | Idempotent saves         |

\* **Platform limitations:**

- iOS Photos: Can only overwrite files owned by your app
- Android 10+: Can only overwrite files owned by your app (scoped storage)

## Common Use Cases

### Download video from Network to Gallery

```dart
final uri = await FileSaver.saveAsync(
  input: SaveNetworkInput(
    url: 'https://example.com/video.mp4',
    headers: {'Authorization': 'Bearer token'}, // Optional headers
    timeout: Duration(minutes: 1), // Custom timeout
  ),
  fileName: 'downloaded_video',
  fileType: VideoType.mp4,
  saveLocation: switch (defaultTargetPlatform) {
    TargetPlatform.android => AndroidSaveLocation.movies,
    TargetPlatform.iOS => IosSaveLocation.photos,
    TargetPlatform.macOS => MacosSaveLocation.downloads,
    TargetPlatform.windows => WindowsSaveLocation.downloads,
    TargetPlatform.linux => LinuxSaveLocation.downloads,
    _ => null,
  },
);
```

### Progress Tracking

```dart
// Using Unified API
await FileSaver.saveAsync(
  input: SaveNetworkInput(url: '...'),
  fileName: 'video',
  fileType: VideoType.mp4,
  onProgress: (progress) {
    print('Download progress: ${(progress * 100).toInt()}%');
  },
);
```

### Cancellation

```dart
// Stream API allows cancellation
final subscription = FileSaver.save(
  input: SaveNetworkInput(url: '...'), // Works for all inputs
  fileName: 'video',
  fileType: VideoType.mp4,
).listen((event) {
    if (event is SaveProgressCancelled) {
      print('Cancelled!');
    }
});

// Cancel anytime
subscription.cancel();
```

### Save to User-Selected Directory

```dart
// 1. Pick directory (Optional, saveAs handles this automatically if null)
final location = await FileSaver.pickDirectory();

if (location != null) {
  // 2. Save file to that directory
  await FileSaver.saveAsAsync(
    input: SaveBytesInput(pdfBytes),
    fileName: 'invoice',
    fileType: CustomFileType(ext: 'pdf', mimeType: 'application/pdf'),
    saveLocation: location,
  );
}
```

## API Reference

### Unified API

#### `save`
Stream-based API for advanced control (cancellation, detailed events).

```dart
Stream<SaveProgress> save({
  required SaveInput input,
  required String fileName,
  required FileType fileType,
  // ... same optional params
})
```

#### `saveAsync`
Future-based API for simple usage.

```dart
Future<Uri> saveAsync({
  required SaveInput input,
  required String fileName,
  required FileType fileType,
  SaveLocation? saveLocation,
  String? subDir,
  ConflictResolution conflictResolution,
  Function(double)? onProgress,
})
```

#### `saveAs`
Stream-based interactive save.

```dart
Stream<SaveProgress> saveAs({
  required SaveInput input,
  required String fileName,
  required FileType fileType,
  PickedDirectoryLocation? saveLocation,
  ConflictResolution conflictResolution,
})
```

#### `saveAsAsync`
Interactive save (shows picker) or save to specific `PickedDirectoryLocation`.

```dart
Future<Uri?> saveAsAsync({
  required SaveInput input,
  required String fileName,
  required FileType fileType,
  PickedDirectoryLocation? saveLocation,
  ConflictResolution conflictResolution,
  Function(double)? onProgress,
})
```

#### `openWrite`
Opens a file for interactive streaming write operations, allowing iterative data chunks to be written. Returns a `FileSaverSink`.

```dart
Future<FileSaverSink> openWrite({
  required SaveInput input,
  required String fileName,
  required FileType fileType,
  SaveLocation? saveLocation,
  String? subDir,
  ConflictResolution conflictResolution,
})
```

#### `openWriteAs`
Interactive streaming write via system picker, allowing iterative data chunks to be written to a user-selected location. Returns a `FileSaverSink?`.

```dart
Future<FileSaverSink?> openWriteAs({
  required SaveInput input,
  required String fileName,
  required FileType fileType,
  PickedDirectoryLocation? saveLocation,
  ConflictResolution conflictResolution,
})
```

#### `pickDirectory`
Open system picker to let user choose a folder.

```dart
Future<PickedDirectoryLocation?> pickDirectory({bool shouldPersist = true})
```

#### `canOpenFile`
Checks whether the file at `uri` is accessible for reading.

```dart
static Future<bool> canOpenFile(Uri uri)
```

#### `openFile`
Opens a saved file with the appropriate system app.

```dart
static Future<void> openFile(Uri uri, {String? mimeType})
```

### Input Models

#### `SaveBytesInput`
- `fileBytes`: `Uint8List` (Required)

#### `SaveFileInput`
- `filePath`: `String` (Required - absolute path)

#### `SaveNetworkInput`
- `url`: `String` (Required)
- `headers`: `Map<String, String>?` (Optional)
- `timeout`: `Duration` (Default: 60s) — enforced on Web via `AbortController` when custom `headers` are used; ignored for header-less requests (anchor element)

### SaveProgress Events

Stream API emits these sealed class events:

| Event                   | Properties                      | Description                 |
|-------------------------|---------------------------------|-----------------------------|
| `SaveProgressStarted`   | -                               | Operation began             |
| `SaveProgressUpdate`    | `progress: double`              | Progress from 0.0 to 1.0    |
| `SaveProgressComplete`  | `uri: Uri`                      | Success with saved file URI |
| `SaveProgressError`     | `exception: FileSaverException` | Error occurred              |
| `SaveProgressCancelled` | -                               | User cancelled operation    |

## Exception Reference

| Exception                     | Description                             | Error Code               |
|-------------------------------|-----------------------------------------|--------------------------|
| `PermissionDeniedException`   | Storage access denied                   | `PERMISSION_DENIED`      |
| `FileExistsException`         | File exists with `fail` strategy        | `FILE_EXISTS`            |
| `StorageFullException`        | Insufficient device storage             | `STORAGE_FULL`           |
| `InvalidInputException`       | Empty bytes or invalid input            | `INVALID_INPUT`          |
| `FileIOException`             | File system error                       | `FILE_IO_ERROR`          |
| `UnsupportedFormatException`  | Format not supported on platform        | `UNSUPPORTED_FORMAT`     |
| `SourceFileNotFoundException` | Source file not found (saveFile)        | `FILE_NOT_FOUND`         |
| `ICloudDownloadException`     | iCloud download failed (iOS)            | `ICLOUD_DOWNLOAD_FAILED` |
| `NetworkException`            | Network error occurred during download. | `NETWORK_ERROR`          |
| `CancelledException`          | Operation cancelled by user             | `CANCELLED`              |
| `NativePlatformException`           | Generic platform error                  | `PLATFORM_ERROR`         |

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.


## FAQ

<details>
<summary><b>ℹ️ iOS Photos Permissions & Albums</b></summary>

<br>

When saving to `IosSaveLocation.photos`, the permission requested depends on the `subDir`:

| `subDir`    | Permission   | Dialog (iOS 14+)      | Capabilities                        |
|:------------|:-------------|:----------------------|:------------------------------------|
| `"MyAlbum"` | `.readWrite` | Full / Limited / Deny | Album creation, conflict resolution |
| `null`      | `.addOnly`   | Allow / Deny          | Basic save only (no album)          |

> **Important:** If `.readWrite` is denied, the save fails. There is no automatic fallback to `.addOnly`.

</details>


<details>
<summary><b>❓ Why are files not saving to Downloads, Pictures, Music (macOS)?</b></summary>

<br>

**App Sandbox** restricts access to user folders by default. If your app is sandboxed (which is typical for macOS Store apps), you must add specific entitlements to your `.entitlements` files.

**Solution:**
Add the required keys (e.g., `com.apple.security.files.downloads.read-write`) to your `macos/Runner/*.entitlements` files.

Check the **MacOS Configuration** section above for the full list of required keys.

</details>


## License

MIT License - see [LICENSE](LICENSE) file for details.
