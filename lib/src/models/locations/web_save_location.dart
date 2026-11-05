import 'package:dir_picker/dir_picker.dart' as dp;
import 'package:web/web.dart';

import '../../exceptions/file_saver_exceptions.dart';
import 'save_location.dart';

/// Web-only subtype of [PickedDirectoryLocation] carrying a
/// [FileSystemDirectoryHandle] from the File System Access API.
///
/// Returned by [FileSaverWeb.pickDirectory] on Chrome/Edge 86+.
/// Pass it to [FileSaver.saveAs] to write files directly into the chosen
/// directory — no dialog appears, no data is loaded into RAM for network files.
///
/// Example:
/// ```dart
/// final location = await FileSaver.pickDirectory();
/// if (location == null) return; // cancelled or not supported
///
/// await FileSaver.saveAsAsync(
///   input: SaveInput.bytes(imageBytes),
///   fileType: ImageType.png,
///   fileName: 'screenshot',
///   saveLocation: location, // WebPickedDirectoryLocation on web
/// );
/// ```
final class WebPickedDirectoryLocation extends PickedDirectoryLocation {
  WebPickedDirectoryLocation(this.directoryHandle)
    : super(
        uri: Uri(scheme: 'web-directory', path: directoryHandle.name),
      );

  /// The [FileSystemDirectoryHandle] obtained from `window.showDirectoryPicker()`.
  final FileSystemDirectoryHandle directoryHandle;

  /// Two locations are equal when they hold the same handle object. Two
  /// picks of the same directory give different handles, which compare
  /// unequal: only `FileSystemHandle.isSameEntry` can tell, and it's
  /// asynchronous.
  @override
  bool operator ==(Object other) =>
      other is WebPickedDirectoryLocation &&
      directoryHandle == other.directoryHandle;

  @override
  int get hashCode => directoryHandle.hashCode;

  /// Whether the page can write to the directory now, without asking the
  /// user.
  ///
  /// A location from [FileSaver.pickDirectory] can. One from
  /// [FileSaver.restoreDirectory] can only while another tab of the site
  /// still has access, or when the user chose "Allow on every visit" in
  /// Chrome. Otherwise call [requestAccess] from a button before saving: a
  /// save without access fails with [PermissionDeniedException].
  Future<bool> hasAccess() => dp.WebPickedLocation(
    directoryHandle,
  ).hasAccess(mode: dp.WebPermissionMode.readwrite);

  /// Asks the user for write access to the directory if the page doesn't
  /// have it yet, and returns whether it has it now. Returns `false` when
  /// the user denies it.
  ///
  /// The browser shows the prompt only for a user gesture, so call it from a
  /// click handler, such as the `onPressed` of a button. Without one it
  /// throws [NativePlatformException].
  Future<bool> requestAccess() async {
    try {
      return await dp.WebPickedLocation(
        directoryHandle,
      ).requestAccess(mode: dp.WebPermissionMode.readwrite);
    } on dp.DirPickerException catch (e) {
      throw NativePlatformException(
        'Request access failed: ${e.message ?? e.code}',
        e.code,
      );
    }
  }
}
