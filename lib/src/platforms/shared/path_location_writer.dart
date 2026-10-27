import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../../exceptions/file_saver_exceptions.dart';
import '../../models/conflict_resolution.dart';
import '../../models/file_saver_sink.dart';
import '../../models/save_progress.dart';
import 'conflict_resolver.dart';
import 'io_file_entity.dart';
import 'io_file_saver_sink.dart';

/// Shared dart:io implementation for [PathLocation] saves.
///
/// Used by all platforms. When a filesystem path is already known,
/// dart:io can write to it directly without going through native code.
///
/// All methods are async and non-blocking — they schedule work on the
/// Dart I/O thread pool via `Future(() async {...})` inside `Stream.multi`.
abstract final class PathLocationWriter {
  PathLocationWriter._();

  static final _conflictResolver = ConflictResolver(const IOFileEntity());

  // MARK: Public API

  static Stream<SaveProgress> saveBytes({
    required Uint8List fileBytes,
    required String dirPath,
    String? subDir,
    required String baseName,
    required String ext,
    required ConflictResolution conflictResolution,
  }) {
    return Stream.multi((controller) {
      Future(() async {
        try {
          controller.addSync(const SaveProgressStarted());
          final targetDirPath = _resolveDirPath(dirPath, subDir);
          await Directory(targetDirPath).create(recursive: true);
          final resolved = await _resolveConflict(
            targetDirPath,
            baseName,
            ext,
            conflictResolution,
          );
          final uri = resolved == null
              ? File(p.join(targetDirPath, '$baseName.$ext')).uri
              : (await File(resolved).writeAsBytes(fileBytes)).uri;
          controller.addSync(SaveProgressUpdate(1.0));
          controller.addSync(SaveProgressComplete(uri));
        } catch (e) {
          controller.addSync(SaveProgressError(_mapException(e)));
        } finally {
          if (!controller.isClosed) controller.closeSync();
        }
      });
    });
  }

  static Stream<SaveProgress> saveFile({
    required String filePath,
    required String dirPath,
    String? subDir,
    required String baseName,
    required String ext,
    required ConflictResolution conflictResolution,
  }) {
    return Stream.multi((controller) {
      Future(() async {
        try {
          controller.addSync(const SaveProgressStarted());
          final targetDirPath = _resolveDirPath(dirPath, subDir);
          await Directory(targetDirPath).create(recursive: true);
          final resolved = await _resolveConflict(
            targetDirPath,
            baseName,
            ext,
            conflictResolution,
          );
          final uri = resolved == null
              ? File(p.join(targetDirPath, '$baseName.$ext')).uri
              : (await File(filePath).copy(resolved)).uri;
          controller.addSync(SaveProgressUpdate(1.0));
          controller.addSync(SaveProgressComplete(uri));
        } catch (e) {
          controller.addSync(SaveProgressError(_mapException(e)));
        } finally {
          if (!controller.isClosed) controller.closeSync();
        }
      });
    });
  }

  static Stream<SaveProgress> saveNetwork({
    required String url,
    required Map<String, String>? headers,
    required Duration timeout,
    required String dirPath,
    String? subDir,
    required String baseName,
    required String ext,
    required ConflictResolution conflictResolution,
  }) {
    return Stream.multi((controller) {
      Future(() async {
        final client = HttpClient()..connectionTimeout = timeout;
        try {
          controller.addSync(const SaveProgressStarted());
          final targetDirPath = _resolveDirPath(dirPath, subDir);
          await Directory(targetDirPath).create(recursive: true);
          final resolved = await _resolveConflict(
            targetDirPath,
            baseName,
            ext,
            conflictResolution,
          );
          if (resolved == null) {
            // SKIP — file exists, return existing URI
            controller.addSync(SaveProgressUpdate(1.0));
            controller.addSync(
              SaveProgressComplete(
                File(p.join(targetDirPath, '$baseName.$ext')).uri,
              ),
            );
            return;
          }
          final request = await client.getUrl(Uri.parse(url));
          headers?.forEach(request.headers.set);
          final response = await request.close();
          if (response.statusCode < 200 || response.statusCode >= 300) {
            await response.drain<void>();
            throw NetworkException(
              'HTTP ${response.statusCode}',
              response.statusCode,
            );
          }

          final file = File(resolved);
          final sink = file.openWrite();
          int received = 0;
          final contentLength = response.contentLength;

          try {
            await for (final chunk in response) {
              sink.add(chunk);
              received += chunk.length;
              if (contentLength > 0) {
                controller.addSync(
                  SaveProgressUpdate(received / contentLength),
                );
              }
            }
            await sink.flush();
            await sink.close();
          } catch (e) {
            await sink.close();
            try {
              if (await file.exists()) await file.delete();
            } catch (_) {}
            rethrow;
          }

          controller.addSync(SaveProgressUpdate(1.0));
          controller.addSync(SaveProgressComplete(file.uri));
        } catch (e) {
          controller.addSync(SaveProgressError(_mapException(e)));
        } finally {
          client.close();
          if (!controller.isClosed) controller.closeSync();
        }
      });
    });
  }

  static Future<FileSaverSink?> openWrite({
    required String dirPath,
    String? subDir,
    required String baseName,
    required String ext,
    required ConflictResolution conflictResolution,
    int? totalSize,
  }) async {
    final targetDirPath = _resolveDirPath(dirPath, subDir);
    await Directory(targetDirPath).create(recursive: true);
    final resolved = await _resolveConflict(
      targetDirPath,
      baseName,
      ext,
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

  // MARK: Private helpers

  /// Resolves naming conflict and returns the final file path.
  /// Returns `null` for [ConflictResolution.skip] when file exists.
  static Future<String?> _resolveConflict(
    String dirPath,
    String baseName,
    String ext,
    ConflictResolution resolution,
  ) async {
    return _conflictResolver.resolve(
      p.join(dirPath, '$baseName.$ext'),
      resolution,
    );
  }

  static String _resolveDirPath(String dirPath, String? subDir) {
    if (subDir == null || subDir.isEmpty) return dirPath;
    return p.join(dirPath, subDir);
  }

  static FileSaverException _mapException(Object e) {
    if (e is FileSaverException) return e;

    if (e is FileSystemException) {
      final errno = e.osError?.errorCode;
      final message = e.path == null ? e.message : '${e.message} (${e.path})';

      return switch (errno) {
        // POSIX: EACCES=13, Windows: ERROR_ACCESS_DENIED=5
        13 || 5 => PermissionDeniedException(message),
        // POSIX/Windows: ENOENT / ERROR_FILE_NOT_FOUND = 2
        2 => SourceFileNotFoundException(e.path ?? message),
        // POSIX: EEXIST=17, Windows: ERROR_ALREADY_EXISTS=183
        17 || 183 => FileExistsException(e.path ?? message),
        // POSIX: ENOSPC=28, Windows: ERROR_DISK_FULL=112
        28 || 112 => const StorageFullException(),
        _ => FileIOException(message),
      };
    }

    if (e is SocketException || e is HttpException || e is HandshakeException) {
      return NetworkException(e.toString());
    }

    return NativePlatformException(e.toString(), 'UNKNOWN');
  }
}
