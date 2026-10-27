import 'package:web/web.dart';

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
}
