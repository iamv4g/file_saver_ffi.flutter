// Stub for FileSaverWeb, used when compiling for non-web (IO) platforms.
import 'dart:typed_data';

import '../models/conflict_resolution.dart';
import '../models/file_type.dart';
import '../models/locations/save_location.dart';
import '../models/save_input.dart';
import '../models/save_progress.dart';
import '../platform_interface/file_saver_platform.dart';

class FileSaverWeb extends FileSaverPlatform {
  static void registerWith(dynamic registrar) =>
      FileSaverPlatform.instance = FileSaverWeb();

  @override
  Stream<SaveProgress> saveBytes({
    required Uint8List fileBytes,
    required FileType fileType,
    required String fileName,
    SaveLocation? saveLocation,
    String? subDir,
    ConflictResolution conflictResolution = ConflictResolution.autoRename,
  }) =>
      throw UnsupportedError('FileSaverWeb is not supported on this platform.');

  @override
  Stream<SaveProgress> saveFile({
    required String filePath,
    required String fileName,
    required FileType fileType,
    SaveLocation? saveLocation,
    String? subDir,
    ConflictResolution conflictResolution = ConflictResolution.autoRename,
  }) =>
      throw UnsupportedError('FileSaverWeb is not supported on this platform.');

  @override
  Stream<SaveProgress> saveNetwork({
    required String url,
    required String fileName,
    required FileType fileType,
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 60),
    SaveLocation? saveLocation,
    String? subDir,
    ConflictResolution conflictResolution = ConflictResolution.autoRename,
  }) =>
      throw UnsupportedError('FileSaverWeb is not supported on this platform.');

  @override
  Stream<SaveProgress> saveAs({
    required SaveInput input,
    required FileType fileType,
    required String fileName,
    required PickedDirectoryLocation saveLocation,
    ConflictResolution conflictResolution = ConflictResolution.autoRename,
  }) =>
      throw UnsupportedError('FileSaverWeb is not supported on this platform.');
}

/// Stub of the web-only [PickedDirectoryLocation] for IO platforms, where
/// no instance exists. It lets cross-platform code check
/// `location is WebPickedDirectoryLocation`.
final class WebPickedDirectoryLocation extends PickedDirectoryLocation {
  WebPickedDirectoryLocation._() : super(uri: Uri());

  /// The `FileSystemDirectoryHandle` of the picked directory, on web only.
  Never get directoryHandle =>
      throw UnsupportedError('directoryHandle is only available on web.');

  /// Whether the page can write to the directory, on web only.
  Future<bool> hasAccess() =>
      throw UnsupportedError('hasAccess is only available on web.');

  /// Asks the user for write access to the directory, on web only.
  Future<bool> requestAccess() =>
      throw UnsupportedError('requestAccess is only available on web.');
}
