/// @docImport '../exceptions/file_saver_exceptions.dart';
/// @docImport 'save_progress.dart';
library;

/// Strategy for handling file name conflicts when saving files.
///
/// Defines how to handle the case when a file with the same name
/// already exists at the destination.
enum ConflictResolution {
  /// Automatically rename the file by appending (1), (2), etc.
  ///
  /// Example:
  /// - photo.jpg exists
  /// - Saves as photo (1).jpg
  /// - If photo (1).jpg exists, saves as photo (2).jpg
  ///
  /// This is the default and recommended strategy for most use cases.
  autoRename,

  /// Overwrite the existing file with the new file.
  ///
  /// **Platform behavior:**
  /// - **iOS**:
  ///   - Photos: Own files ✅ | Other apps → Creates duplicate
  ///   - Documents: ✅ Full overwrite (sandboxed per app)
  /// - **Android 9-**: ✅ Full overwrite (requires WRITE_EXTERNAL_STORAGE)
  /// - **Android 10+**: Own files ✅ | Other apps → Auto-rename
  ///
  /// **Important:** On Android 10+, files from other apps cannot be detected.
  /// MediaStore will automatically rename your file if conflict exists
  /// (e.g., photo.jpg → photo (1).jpg).
  ///
  /// See README.md "Overwrite Behavior" section for details.
  ///
  /// **Warning:** Permanently deletes the existing file when successful.
  overwrite,

  /// Fail the save operation if a file with the same name exists.
  ///
  /// Emits [SaveProgressError] with a [FileExistsException]
  /// (error code "FILE_EXISTS").
  fail,

  /// Skip the save operation if a file with the same name exists.
  ///
  /// Emits [SaveProgressComplete] with the URI of the existing file.
  /// No actual file writing occurs.
  skip,
}
