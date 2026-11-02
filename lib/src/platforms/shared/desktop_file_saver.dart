import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../exceptions/file_saver_exceptions.dart';
import '../../models/conflict_resolution.dart';
import '../../models/file_saver_sink.dart';
import '../../models/file_type.dart';
import '../../models/locations/save_location.dart';
import '../../models/save_input.dart';
import '../../models/save_progress.dart';
import '../../platform_interface/file_saver_platform.dart';
import 'conflict_resolver.dart';
import 'io_file_entity.dart';
import 'io_file_saver_sink.dart';
import 'path_location_writer.dart';

/// Shared base class for desktop (Windows + Linux) FileSaver implementations.
///
/// Saves go through [PathLocationWriter], write sessions through
/// [IOFileSaverSink]. Subclasses only need to implement [resolveDirectory]
/// with platform-specific directory resolution and [launchFile] to open a
/// file with the default application.
///
/// [L] is the platform's save location enum. Any other location throws
/// [InvalidInputException].
abstract class DesktopFileSaver<L extends SaveLocation>
    extends FileSaverPlatform {
  final _conflictResolver = ConflictResolver(const IOFileEntity());

  // ─────────────────────────────────────────────────────────────────────────
  // Save operations
  // ─────────────────────────────────────────────────────────────────────────

  @override
  Stream<SaveProgress> saveBytes({
    required Uint8List fileBytes,
    required String fileName,
    required FileType fileType,
    SaveLocation? saveLocation,
    String? subDir,
    ConflictResolution conflictResolution = ConflictResolution.autoRename,
  }) {
    validateBytesInput(fileBytes, fileName);
    return _save(
      SaveBytesInput(fileBytes),
      fileName,
      fileType,
      saveLocation,
      subDir,
      conflictResolution,
    );
  }

  @override
  Stream<SaveProgress> saveFile({
    required String filePath,
    required String fileName,
    required FileType fileType,
    SaveLocation? saveLocation,
    String? subDir,
    ConflictResolution conflictResolution = ConflictResolution.autoRename,
  }) {
    validateFilePathInput(filePath, fileName);
    return _save(
      SaveFileInput(filePath),
      fileName,
      fileType,
      saveLocation,
      subDir,
      conflictResolution,
    );
  }

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
  }) {
    validateNetworkInput(url, fileName);
    return _save(
      SaveNetworkInput(url: url, headers: headers, timeout: timeout),
      fileName,
      fileType,
      saveLocation,
      subDir,
      conflictResolution,
    );
  }

  /// Saves validated [input] to [saveLocation], a [PathLocation] or a [L].
  Stream<SaveProgress> _save(
    SaveInput input,
    String fileName,
    FileType fileType,
    SaveLocation? saveLocation,
    String? subDir,
    ConflictResolution conflictResolution,
  ) {
    if (saveLocation is PathLocation) {
      return switch (input) {
        SaveBytesInput(:final fileBytes) => PathLocationWriter.saveBytes(
          fileBytes: fileBytes,
          dirPath: saveLocation.path,
          subDir: subDir,
          baseName: fileName,
          ext: fileType.ext,
          conflictResolution: conflictResolution,
        ),
        SaveFileInput(:final filePath) => PathLocationWriter.saveFile(
          filePath: filePath,
          dirPath: saveLocation.path,
          subDir: subDir,
          baseName: fileName,
          ext: fileType.ext,
          conflictResolution: conflictResolution,
        ),
        SaveNetworkInput(:final url, :final headers, :final timeout) =>
          PathLocationWriter.saveNetwork(
            url: url,
            headers: headers,
            timeout: timeout,
            dirPath: saveLocation.path,
            subDir: subDir,
            baseName: fileName,
            ext: fileType.ext,
            conflictResolution: conflictResolution,
          ),
      };
    }

    final location = checkSaveLocation<L>(saveLocation);
    return PathLocationWriter.save(
      input: input,
      directory: () => resolveDirectory(location, subDir),
      baseName: fileName,
      ext: fileType.ext,
      conflictResolution: conflictResolution,
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // User-Selected Location
  // ─────────────────────────────────────────────────────────────────────────

  // pickDirectory() is inherited from FileSaverPlatform (uses DirPicker).

  @override
  Stream<SaveProgress> saveAs({
    required SaveInput input,
    required FileType fileType,
    required String fileName,
    required PickedDirectoryLocation saveLocation,
    ConflictResolution conflictResolution = ConflictResolution.autoRename,
  }) {
    switch (input) {
      case SaveBytesInput(:final fileBytes):
        validateBytesInput(fileBytes, fileName);
      case SaveFileInput(:final filePath):
        validateFilePathInput(filePath, fileName);
      case SaveNetworkInput(:final url):
        validateNetworkInput(url, fileName);
    }
    final dirPath = saveLocation.uri.toFilePath();
    return PathLocationWriter.save(
      input: input,
      directory: () async => dirPath,
      baseName: fileName,
      ext: fileType.ext,
      conflictResolution: conflictResolution,
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Session-based streaming write
  // ─────────────────────────────────────────────────────────────────────────

  @override
  Future<FileSaverSink?> openWrite({
    required String fileName,
    required FileType fileType,
    SaveLocation? saveLocation,
    String? subDir,
    int? totalSize,
    ConflictResolution conflictResolution = ConflictResolution.autoRename,
  }) async {
    if (fileName.isEmpty) {
      throw const InvalidInputException('File name cannot be empty');
    }
    if (saveLocation is PathLocation) {
      return PathLocationWriter.openWrite(
        dirPath: saveLocation.path,
        subDir: subDir,
        baseName: fileName,
        ext: fileType.ext,
        conflictResolution: conflictResolution,
        totalSize: totalSize,
      );
    }
    final dir = await resolveDirectory(
      checkSaveLocation<L>(saveLocation),
      subDir,
    );
    final filePath = p.join(dir, '$fileName.${fileType.ext}');
    final resolved = await _conflictResolver.resolve(
      filePath,
      conflictResolution,
    );
    if (resolved == null) return null;
    return IOFileSaverSink.open(resolved, totalSize: totalSize);
  }

  @override
  Future<FileSaverSink?> openWriteAs({
    required String fileName,
    required FileType fileType,
    required PickedDirectoryLocation saveLocation,
    int? totalSize,
    ConflictResolution conflictResolution = ConflictResolution.autoRename,
  }) async {
    if (fileName.isEmpty) {
      throw const InvalidInputException('File name cannot be empty');
    }
    final dirPath = saveLocation.uri.toFilePath();
    final filePath = p.join(dirPath, '$fileName.${fileType.ext}');
    final resolved = await _conflictResolver.resolve(
      filePath,
      conflictResolution,
    );
    if (resolved == null) return null;
    return IOFileSaverSink.open(resolved, totalSize: totalSize);
  }

  @override
  Future<bool> canOpenFile(Uri uri) async {
    if (!uri.isScheme('file')) return false;
    return File.fromUri(uri).exists();
  }

  @override
  Future<void> openFile(Uri uri, {String? mimeType}) async {
    if (!uri.isScheme('file')) {
      throw InvalidInputException(
        'openFile only supports file:// URIs on desktop (got: $uri)',
      );
    }

    if (!await File.fromUri(uri).exists()) {
      throw SourceFileNotFoundException(uri.toString());
    }

    try {
      await launchFile(uri.toFilePath());
    } catch (e) {
      if (e is FileSaverException) rethrow;
      throw OpenFailedException('$e');
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Platform-specific hooks
  // ─────────────────────────────────────────────────────────────────────────

  /// Opens the existing file at [path] with the default application.
  ///
  /// Called by [openFile] after the URI and the file have been validated.
  /// Implementations must pass [path] to the OS as a single argument and never
  /// through a shell, because file names may contain shell metacharacters.
  /// Throw [OpenFailedException] when the file cannot be opened.
  @protected
  Future<void> launchFile(String path);

  /// Resolves the target directory for the save operation.
  ///
  /// - Windows: Uses Known Folder GUIDs via [PathProviderWindows]
  /// - Linux: Uses XDG Base Directory Specification via `xdg_directories`
  @protected
  Future<String> resolveDirectory(L? saveLocation, String? subDir);
}
