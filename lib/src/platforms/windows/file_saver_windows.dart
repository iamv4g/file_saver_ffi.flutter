import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider_windows/path_provider_windows.dart';

import '../../exceptions/file_saver_exceptions.dart';
import '../../models/locations/save_location.dart';
import '../../platform_interface/file_saver_platform.dart';
import '../shared/desktop_file_saver.dart';
import 'windows_shell.dart';

// Windows Known Folder GUIDs — mirrors WindowsKnownFolder from path_provider_windows.
// Defined locally because the analyzer on non-Windows resolves the stub class
// (empty WindowsKnownFolder {}) instead of the real one with static getters.
const String _kDownloads = '{374DE290-123F-4565-9164-39C4925E467B}';
const String _kPictures = '{33E28130-4E1E-4676-835A-98395C3BC3BB}';
const String _kVideos = '{18989B1D-99B5-455B-841C-AB7C74E4DDFC}';
const String _kMusic = '{4BD8D571-6D19-48D3-BE97-422220080E43}';
const String _kDocuments = '{FDD39AD0-238F-46AF-ADB4-6C85480369C7}';

/// FileSaver implementation for Windows.
///
/// Extends [DesktopFileSaver] — only [resolveDirectory] and [launchFile] are
/// platform-specific. Directory resolution uses [PathProviderWindows]
/// (SHGetKnownFolderPath via dart:ffi); files are opened with ShellExecuteExW.
class FileSaverWindows extends DesktopFileSaver {
  /// Registers this class as the default instance of [FileSaverPlatform].
  static void registerWith() {
    FileSaverPlatform.instance = FileSaverWindows();
  }

  final _pathProvider = PathProviderWindows();

  @override
  Future<String> resolveDirectory(
    SaveLocation? saveLocation,
    String? subDir,
  ) async {
    final folderGuid = switch (saveLocation) {
      WindowsSaveLocation.downloads => _kDownloads,
      WindowsSaveLocation.pictures => _kPictures,
      WindowsSaveLocation.videos => _kVideos,
      WindowsSaveLocation.music => _kMusic,
      WindowsSaveLocation.documents => _kDocuments,
      _ => _kDownloads,
    };

    final basePath = await _pathProvider.getPath(folderGuid);
    // The stub PathProviderWindows (used by the analyzer on non-Windows) declares
    // getPath() as Future<String> (non-nullable), but the real implementation
    // returns Future<String?> (nullable). The null check is necessary at runtime.
    // ignore: unnecessary_null_comparison
    if (basePath == null || basePath.isEmpty) {
      throw const NativePlatformException(
        'Could not resolve save directory',
        'PLATFORM_ERROR',
      );
    }

    final dirPath = subDir != null ? p.join(basePath, subDir) : basePath;
    final dir = Directory(dirPath);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dirPath;
  }

  /// Opens [path] through `ShellExecuteExW`, never through `cmd`, so shell
  /// metacharacters in file names (`&`, `|`, `^`, …) cannot run commands.
  @override
  Future<void> launchFile(String path) async {
    final code = await shellOpen(path);
    if (code == 0) return;
    throw OpenFailedException(
      code == seErrNoAssoc
          ? 'No application is associated with this file type: $path'
          : 'ShellExecuteEx failed (SE_ERR $code): $path',
    );
  }
}
