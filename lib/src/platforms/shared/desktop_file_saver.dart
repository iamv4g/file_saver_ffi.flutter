import 'dart:async';
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

/// 1MB chunk size for progress reporting.
const int _chunkSize = 1048576;

/// Shared base class for desktop (Windows + Linux) FileSaver implementations.
///
/// All I/O logic is implemented here. Subclasses only need to implement
/// [resolveDirectory] with platform-specific directory resolution and
/// [launchFile] to open a file with the default application.
abstract class DesktopFileSaver extends FileSaverPlatform {
  final _httpClient = HttpClient();
  int _nextTokenId = 1;
  final _activeTokens = <int, _CancellationToken>{};
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

    if (saveLocation is PathLocation) {
      return PathLocationWriter.saveBytes(
        fileBytes: fileBytes,
        dirPath: saveLocation.path,
        subDir: subDir,
        baseName: fileName,
        ext: fileType.ext,
        conflictResolution: conflictResolution,
      );
    }

    return _executeSave((token, controller) async {
      final dir = await resolveDirectory(saveLocation, subDir);
      final filePath = p.join(dir, '$fileName.${fileType.ext}');
      final resolved = await _conflictResolver.resolve(
        filePath,
        conflictResolution,
      );
      if (resolved == null) {
        controller.add(SaveProgressComplete(Uri.file(filePath)));
        return;
      }

      await _writeBytes(resolved, fileBytes, token, controller);
      controller.add(SaveProgressComplete(Uri.file(resolved)));
    });
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

    if (saveLocation is PathLocation) {
      return PathLocationWriter.saveFile(
        filePath: filePath,
        dirPath: saveLocation.path,
        subDir: subDir,
        baseName: fileName,
        ext: fileType.ext,
        conflictResolution: conflictResolution,
      );
    }

    return _executeSave((token, controller) async {
      final sourcePath = _toFilePath(filePath);
      final source = File(sourcePath);
      if (!await source.exists()) {
        throw SourceFileNotFoundException(sourcePath);
      }

      final dir = await resolveDirectory(saveLocation, subDir);
      final destPath = p.join(dir, '$fileName.${fileType.ext}');
      final resolved = await _conflictResolver.resolve(
        destPath,
        conflictResolution,
      );
      if (resolved == null) {
        controller.add(SaveProgressComplete(Uri.file(destPath)));
        return;
      }

      await _copyFile(source, resolved, token, controller);
      controller.add(SaveProgressComplete(Uri.file(resolved)));
    });
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

    if (saveLocation is PathLocation) {
      return PathLocationWriter.saveNetwork(
        url: url,
        headers: headers,
        timeout: timeout,
        dirPath: saveLocation.path,
        subDir: subDir,
        baseName: fileName,
        ext: fileType.ext,
        conflictResolution: conflictResolution,
      );
    }

    return _executeSave((token, controller) async {
      final dir = await resolveDirectory(saveLocation, subDir);
      final destPath = p.join(dir, '$fileName.${fileType.ext}');
      final resolved = await _conflictResolver.resolve(
        destPath,
        conflictResolution,
      );
      if (resolved == null) {
        controller.add(SaveProgressComplete(Uri.file(destPath)));
        return;
      }

      await _downloadToFile(url, headers, timeout, resolved, token, controller);
      controller.add(SaveProgressComplete(Uri.file(resolved)));
    });
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
    final dirPath = saveLocation.uri.toFilePath();
    return switch (input) {
      SaveBytesInput(:final fileBytes) => _saveBytesTo(
        fileBytes: fileBytes,
        dirPath: dirPath,
        fileName: fileName,
        ext: fileType.ext,
        conflictResolution: conflictResolution,
      ),
      SaveFileInput(:final filePath) => _saveFileTo(
        filePath: filePath,
        dirPath: dirPath,
        fileName: fileName,
        ext: fileType.ext,
        conflictResolution: conflictResolution,
      ),
      SaveNetworkInput(:final url, :final headers, :final timeout) =>
        _saveNetworkTo(
          url: url,
          headers: headers,
          timeout: timeout,
          dirPath: dirPath,
          fileName: fileName,
          ext: fileType.ext,
          conflictResolution: conflictResolution,
        ),
    };
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
    final dir = await resolveDirectory(saveLocation, subDir);
    final filePath = p.join(dir, '$fileName.${fileType.ext}');
    final resolved = await _conflictResolver.resolve(
      filePath,
      conflictResolution,
    );
    if (resolved == null) return null;
    final file = File(resolved);
    return IOFileSaverSink(
      sink: file.openWrite(),
      file: file,
      totalSize: totalSize,
    );
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
    final file = File(resolved);
    return IOFileSaverSink(
      sink: file.openWrite(),
      file: file,
      totalSize: totalSize,
    );
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
  Future<String> resolveDirectory(SaveLocation? saveLocation, String? subDir);

  // ─────────────────────────────────────────────────────────────────────────
  // SaveAs helpers
  // ─────────────────────────────────────────────────────────────────────────

  Stream<SaveProgress> _saveBytesTo({
    required Uint8List fileBytes,
    required String dirPath,
    required String fileName,
    required String ext,
    required ConflictResolution conflictResolution,
  }) {
    return _executeSave((token, controller) async {
      final filePath = p.join(dirPath, '$fileName.$ext');
      final resolved = await _conflictResolver.resolve(
        filePath,
        conflictResolution,
      );
      if (resolved == null) {
        controller.add(SaveProgressComplete(Uri.file(filePath)));
        return;
      }

      await _writeBytes(resolved, fileBytes, token, controller);
      controller.add(SaveProgressComplete(Uri.file(resolved)));
    });
  }

  Stream<SaveProgress> _saveFileTo({
    required String filePath,
    required String dirPath,
    required String fileName,
    required String ext,
    required ConflictResolution conflictResolution,
  }) {
    return _executeSave((token, controller) async {
      final sourcePath = _toFilePath(filePath);
      final source = File(sourcePath);
      if (!await source.exists()) {
        throw SourceFileNotFoundException(sourcePath);
      }

      final destPath = p.join(dirPath, '$fileName.$ext');
      final resolved = await _conflictResolver.resolve(
        destPath,
        conflictResolution,
      );
      if (resolved == null) {
        controller.add(SaveProgressComplete(Uri.file(destPath)));
        return;
      }

      await _copyFile(source, resolved, token, controller);
      controller.add(SaveProgressComplete(Uri.file(resolved)));
    });
  }

  Stream<SaveProgress> _saveNetworkTo({
    required String url,
    required Map<String, String>? headers,
    required Duration timeout,
    required String dirPath,
    required String fileName,
    required String ext,
    required ConflictResolution conflictResolution,
  }) {
    return _executeSave((token, controller) async {
      final destPath = p.join(dirPath, '$fileName.$ext');
      final resolved = await _conflictResolver.resolve(
        destPath,
        conflictResolution,
      );
      if (resolved == null) {
        controller.add(SaveProgressComplete(Uri.file(destPath)));
        return;
      }

      await _downloadToFile(url, headers, timeout, resolved, token, controller);
      controller.add(SaveProgressComplete(Uri.file(resolved)));
    });
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Core I/O operations
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _writeBytes(
    String filePath,
    Uint8List bytes,
    _CancellationToken token,
    StreamController<SaveProgress> controller,
  ) async {
    final file = File(filePath);
    final sink = file.openWrite();
    final total = bytes.length;
    int written = 0;

    try {
      for (int offset = 0; offset < total; offset += _chunkSize) {
        if (token.isCancelled) {
          await sink.close();
          await file.delete();
          return;
        }
        final end = (offset + _chunkSize).clamp(0, total);
        sink.add(bytes.sublist(offset, end));
        written = end;
        controller.add(SaveProgressUpdate(written / total));
      }
      await sink.flush();
      await sink.close();
    } catch (e) {
      await sink.close();
      if (await file.exists()) await file.delete();
      rethrow;
    }
  }

  Future<void> _copyFile(
    File source,
    String destPath,
    _CancellationToken token,
    StreamController<SaveProgress> controller,
  ) async {
    final total = await source.length();
    final dest = File(destPath);
    final sink = dest.openWrite();
    int copied = 0;

    try {
      await for (final chunk in source.openRead()) {
        if (token.isCancelled) {
          await sink.close();
          await dest.delete();
          return;
        }
        sink.add(chunk);
        copied += chunk.length;
        controller.add(SaveProgressUpdate(copied / total));
      }
      await sink.flush();
      await sink.close();
    } catch (e) {
      await sink.close();
      if (await dest.exists()) await dest.delete();
      rethrow;
    }
  }

  Future<void> _downloadToFile(
    String url,
    Map<String, String>? headers,
    Duration timeout,
    String destPath,
    _CancellationToken token,
    StreamController<SaveProgress> controller,
  ) async {
    final uri = Uri.parse(url);

    _httpClient.connectionTimeout = timeout;

    final request = await _httpClient.getUrl(uri);
    token.activeRequest = request;
    headers?.forEach(request.headers.add);

    HttpClientResponse response;
    try {
      response = await request.close();
    } catch (e) {
      token.activeRequest = null;
      throw NetworkException('Connection failed: $e');
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      await response.drain<void>();
      token.activeRequest = null;
      throw NetworkException(
        'HTTP ${response.statusCode}',
        response.statusCode,
      );
    }

    final total = response.contentLength;
    final dest = File(destPath);
    final sink = dest.openWrite();
    int downloaded = 0;

    // HttpClientRequest.abort() does not end a response stream that is
    // already being received, so cancellation and the inactivity timeout
    // cancel the response subscription directly instead.
    final completer = Completer<void>();
    final subscription = response
        .timeout(timeout)
        .listen(
          (chunk) {
            sink.add(chunk);
            downloaded += chunk.length;

            if (total > 0) {
              controller.add(SaveProgressUpdate(downloaded / total));
            }
          },
          onError: (Object e, StackTrace st) {
            if (!completer.isCompleted) completer.completeError(e, st);
          },
          onDone: () {
            if (!completer.isCompleted) completer.complete();
          },
          cancelOnError: true,
        );

    token.onCancel = () {
      subscription.cancel();
      if (!completer.isCompleted) completer.complete();
    };

    try {
      await completer.future;
      token.onCancel = null;
      token.activeRequest = null;

      if (token.isCancelled) {
        await sink.close();
        if (await dest.exists()) await dest.delete();
        return;
      }

      await sink.flush();
      await sink.close();
    } catch (e) {
      token.onCancel = null;
      token.activeRequest = null;

      await sink.close();
      if (await dest.exists()) await dest.delete();

      if (token.isCancelled) return;

      if (e is TimeoutException) {
        throw NetworkException('No data received for ${timeout.inSeconds}s');
      }
      throw FileIOException(e.toString());
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Shared helpers
  // ─────────────────────────────────────────────────────────────────────────

  Stream<SaveProgress> _executeSave(
    Future<void> Function(
      _CancellationToken token,
      MultiStreamController<SaveProgress> controller,
    )
    operation,
  ) {
    return Stream.multi((controller) {
      final tokenId = _nextTokenId++;
      final token = _CancellationToken();
      _activeTokens[tokenId] = token;

      controller.addSync(const SaveProgressStarted());

      operation(token, controller)
          .then((_) {
            _activeTokens.remove(tokenId);
            if (!controller.isClosed) controller.closeSync();
          })
          .catchError((Object e) {
            _activeTokens.remove(tokenId);
            if (token.isCancelled) {
              if (!controller.isClosed) {
                controller.addSync(const SaveProgressCancelled());
                controller.closeSync();
              }
              return;
            }
            if (!controller.isClosed) {
              controller.addSync(
                SaveProgressError(FileSaverException.fromObj(e)),
              );
              controller.closeSync();
            }
          });

      controller.onCancel = () {
        token.cancel();
        _activeTokens.remove(tokenId);
        Future.delayed(const Duration(milliseconds: 500), () {
          if (!controller.isClosed) {
            controller.addSync(const SaveProgressCancelled());
            controller.closeSync();
          }
        });
      };
    });
  }

  String _toFilePath(String filePath) {
    if (filePath.startsWith('file://')) {
      return Uri.parse(filePath).toFilePath();
    }
    return filePath;
  }
}

class _CancellationToken {
  bool isCancelled = false;
  HttpClientRequest? activeRequest;

  /// Stops an in-flight response stream; set while a download is running.
  void Function()? onCancel;

  void cancel() {
    isCancelled = true;
    activeRequest?.abort();
    onCancel?.call();
  }
}
