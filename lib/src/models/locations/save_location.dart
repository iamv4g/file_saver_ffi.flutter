/// @docImport '../../exceptions/file_saver_exceptions.dart';
library;

/// Base sealed class for all save locations.
///
/// This class provides a type-safe way to specify where files should be saved
/// on different platforms. Each platform has its own set of supported locations
/// through platform-specific enum implementations.
sealed class SaveLocation {
  const SaveLocation();
}

/// Android-specific save locations.
///
/// Each value is a public top-level directory. On Android 10 and later, files
/// go through MediaStore: the collection is picked from the file's MIME type
/// (Images, Video or Audio, and Downloads for everything else, or for any type
/// saved to [downloads]). Android decides which types a directory accepts, and
/// a rejected combination fails with an [InvalidInputException]. Measured on
/// Android 10 and 16:
///
/// | Location      | Images | Videos                 | Audio | Other files |
/// | ------------- | ------ | ---------------------- | ----- | ----------- |
/// | [downloads]   | yes    | yes                    | yes   | yes         |
/// | [pictures]    | yes    | Android 16 yes, 10 no  | no    | no          |
/// | [dcim]        | yes    | yes                    | no    | no          |
/// | [movies]      | no     | yes                    | no    | no          |
/// | [music]       | no     | no                     | yes   | no          |
///
/// On Android 9 and below, files are written directly to the directory, so
/// any type works in any location.
///
/// A `subDir` with a `..` segment is rejected with an [InvalidInputException].
enum AndroidSaveLocation implements SaveLocation {
  /// Pictures/: images, and videos on newer Android versions (accepted on
  /// Android 16, rejected on Android 10).
  pictures,

  /// Movies/: videos.
  movies,

  /// Music/: audio.
  music,

  /// Download/: any file type (default).
  downloads,

  /// DCIM/: camera images and videos.
  dcim;

  const AndroidSaveLocation();
}

/// iOS-specific save locations.
///
/// These locations map to iOS's Photos Library and FileManager directories.
///
/// Platform mappings:
/// - [photos]: Photos Library (requires Photos permission)
/// - [documents]: Documents/ directory in app's container (default, no permission required)
enum IosSaveLocation implements SaveLocation {
  /// Save to app's Documents/ directory (default)
  ///
  /// Files are saved to the app's Documents directory and are visible in
  /// the Files app under "On My iPhone/iPad" → [App Name].
  /// No special permissions required.
  documents,

  /// Save to Photos Library
  ///
  /// Requires Photos permission. Files are saved to the user's Photos app
  /// and can optionally be organized into albums using the subDir parameter.
  ///
  /// Only images and videos can be saved here. Other file types throw
  /// `InvalidInputException`.
  photos;

  const IosSaveLocation();
}

/// macOS-specific save locations.
///
/// Behavior depends on whether the app has `com.apple.security.app-sandbox` enabled:
///
/// - **With Sandbox**: Can only save to [documents] (App Container) and other locations
///   if the corresponding entitlement is set.
/// - **Without Sandbox**: Can save to any user-accessible directory.
enum MacosSaveLocation implements SaveLocation {
  /// Save to the standard ~/Downloads directory.
  ///
  /// In Sandbox: Requires `com.apple.security.files.downloads.read-write` entitlement.
  downloads,

  /// Save to the standard ~/Pictures directory.
  ///
  /// In Sandbox: Requires `com.apple.security.assets.pictures.read-write` entitlement.
  pictures,

  /// Save to the standard ~/Movies directory.
  ///
  /// In Sandbox: Requires `com.apple.security.assets.movies.read-write` entitlement.
  movies,

  /// Save to the standard ~/Music directory.
  ///
  /// In Sandbox: Requires `com.apple.security.assets.music.read-write` entitlement.
  music,

  /// Save to the app's specific Documents directory.
  ///
  /// In Sandbox: This is inside the App Container (`~/Library/Containers/<bundle-id>/Data/Documents/`).
  /// Without Sandbox: This is the global `~/Documents` directory.
  documents;

  const MacosSaveLocation();
}

/// Windows-specific save locations.
///
/// These locations map to Windows Known Folders via `SHGetKnownFolderPath`.
///
/// Platform mappings:
/// - [downloads]: FOLDERID_Downloads (%USERPROFILE%\Downloads)
/// - [pictures]: FOLDERID_Pictures (%USERPROFILE%\Pictures)
/// - [videos]: FOLDERID_Videos (%USERPROFILE%\Videos)
/// - [music]: FOLDERID_Music (%USERPROFILE%\Music)
/// - [documents]: FOLDERID_Documents (%USERPROFILE%\Documents)
enum WindowsSaveLocation implements SaveLocation {
  /// Save to Downloads directory (default)
  downloads,

  /// Save to Pictures directory
  pictures,

  /// Save to Videos directory
  videos,

  /// Save to Music directory
  music,

  /// Save to Documents directory
  documents;

  const WindowsSaveLocation();
}

/// Linux-specific save locations.
///
/// Resolved via XDG Base Directory Specification (`xdg-user-dirs`).
/// Falls back to `~/Downloads` if the XDG variable is not configured.
enum LinuxSaveLocation implements SaveLocation {
  /// XDG_DOWNLOAD_DIR — typically `~/Downloads` (default)
  downloads,

  /// XDG_PICTURES_DIR — typically `~/Pictures`
  pictures,

  /// XDG_VIDEOS_DIR — typically `~/Videos`
  videos,

  /// XDG_MUSIC_DIR — typically `~/Music`
  music,

  /// XDG_DOCUMENTS_DIR — typically `~/Documents`
  documents;

  const LinuxSaveLocation();
}

/// User-selected directory location.
///
/// This represents a directory chosen by the user through the system picker:
/// - **Android**: Storage Access Framework (ACTION_OPEN_DOCUMENT_TREE)
/// - **iOS**: UIDocumentPickerViewController
/// - **Windows**: IFileOpenDialog with FOS_PICKFOLDERS
/// - **Web**: File System Access API — see [WebPickedDirectoryLocation]
///
/// Use [FileSaver.pickDirectory] to obtain a [PickedDirectoryLocation], then
/// pass it to [FileSaver.saveAs] or [FileSaver.saveAsAsync].
///
/// Example:
/// ```dart
/// // Pick once, save multiple files
/// final location = await FileSaver.pickDirectory();
/// if (location == null) return; // User cancelled
///
/// // Save files to the selected location
/// await FileSaver.saveAsAsync(
///   input: SaveInput.bytes(imageBytes),
///   fileType: ImageType.png,
///   fileName: 'screenshot',
///   saveLocation: location,
/// );
/// ```
class PickedDirectoryLocation implements SaveLocation {
  const PickedDirectoryLocation({required this.uri});

  /// Directory URI from the system picker.
  ///
  /// - **Android**: Content URI from SAF (e.g., `content://...`)
  /// - **iOS**: File URL from Document Picker (e.g., `file://...`)
  /// - **macOS**: File URL from Open Panel (e.g., `file://...`)
  /// - **Linux**: File URL from file chooser (e.g., `file://...`)
  /// - **Windows**: File system path (e.g., `C:\Users\...`)
  /// - **Web**: Placeholder URI — browsers do not expose filesystem paths.
  ///   Use [WebPickedDirectoryLocation] to access the [FileSystemDirectoryHandle].
  final Uri uri;
}

/// Save to a specific filesystem directory path.
///
/// The plugin writes the file directly using `dart:io`. The caller is
/// responsible for providing a valid, accessible path — the plugin only
/// creates the directory (if absent) and writes the file.
///
/// **Getting a path:**
/// ```dart
/// // App Documents directory (all platforms)
/// final docs = await getApplicationDocumentsDirectory();
/// PathLocation(p.join(docs.path, 'my_recordings'))
///
/// // User-picked directory (macOS / Desktop / Android)
/// final picked = await FilePicker.platform.getDirectoryPath();
/// if (picked != null) PathLocation(picked)
/// ```
///
/// **Platform notes:**
/// - **iOS**: Only paths within the app sandbox are writable.
/// - **macOS (sandboxed)**: Only paths inside the app container or picked via
///   system picker are accessible. Opening via picker grants access.
/// - **Android 11+**: Paths outside app storage (e.g., `/storage/emulated/0/`)
///   require `MANAGE_EXTERNAL_STORAGE` permission.
class PathLocation implements SaveLocation {
  const PathLocation(this.path);

  /// The filesystem directory path to save the file into.
  final String path;
}
