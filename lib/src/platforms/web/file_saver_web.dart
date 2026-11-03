import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:dir_picker/dir_picker.dart' as dp;
import 'package:flutter/foundation.dart';
import 'package:flutter_web_plugins/flutter_web_plugins.dart';
import 'package:web/web.dart';

import '../../exceptions/file_saver_exceptions.dart';
import '../../models/conflict_resolution.dart';
import '../../models/file_saver_sink.dart';
import '../../models/file_type.dart';
import '../../models/locations/save_location.dart';
import '../../models/locations/web_save_location.dart';
import '../../models/save_input.dart';
import '../../models/save_progress.dart';
import '../../platform_interface/file_saver_platform.dart';
import '../shared/conflict_resolver.dart';
import 'web_file_entity.dart';
import 'web_cancellation_token.dart';
import 'web_file_saver_sink.dart';
import 'web_utils.dart';

export '../../models/locations/web_save_location.dart';

class FileSaverWeb extends FileSaverPlatform {
  /// Registers this class as the default instance of [FileSaverPlatform].
  static void registerWith(Registrar registrar) {
    FileSaverPlatform.instance = FileSaverWeb();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // pickDirectory
  // ─────────────────────────────────────────────────────────────────────────

  /// Shows `window.showDirectoryPicker()` via `dir_picker` and returns a
  /// [WebPickedDirectoryLocation] wrapping the chosen [FileSystemDirectoryHandle].
  ///
  /// Returns `null` if the user cancels.
  /// Throws [NativePlatformException] if the browser does not support the
  /// File System Access API (Firefox / Safari).
  @override
  Future<PickedDirectoryLocation?> pickDirectory({
    bool shouldPersist = true,
  }) async {
    try {
      final location = await dp.DirPicker.pick();
      if (location == null) return null; // user cancelled
      if (location is! dp.WebPickedLocation) {
        throw const NativePlatformException('Unexpected picker result on web.');
      }

      return WebPickedDirectoryLocation(location.handle);
    } catch (e) {
      // dir_picker is an external package and will not throw FileSaverException.
      // Any error here means the browser doesn't support showDirectoryPicker.
      throw NativePlatformException(
        'Directory picker unavailable. '
        'File System Access API not supported in this browser. ($e)',
      );
    }
  }

  // ─────────────────────────────────────────────
  // saveBytes (browser controlled)
  // ─────────────────────────────────────────────

  @override
  Stream<SaveProgress> saveBytes({
    required Uint8List fileBytes,
    required FileType fileType,
    required String fileName,
    SaveLocation? saveLocation,
    String? subDir,
    ConflictResolution conflictResolution = ConflictResolution.autoRename,
  }) {
    validateBytesInput(fileBytes, fileName);
    final fullName = '$fileName.${fileType.ext}';
    return WebUtils.executeSave((token, emit) async {
      WebUtils.triggerBytesDownload(fileBytes, fullName, fileType.mimeType);
      emit(
        SaveProgressComplete(Uri(scheme: 'browser-download', path: fullName)),
      );
    });
  }

  // ─────────────────────────────────────────────────────────────────────────
  @override
  Future<bool> canOpenFile(Uri uri) {
    throw UnsupportedError('canOpenFile is not supported on Web.');
  }

  @override
  Future<void> openFile(Uri uri, {String? mimeType}) {
    throw UnsupportedError(
      'openFile is not supported on Web — the file was already downloaded by the browser.',
    );
  }

  @override
  Future<String> persistDirectory(PickedDirectoryLocation location) {
    throw UnsupportedError('persistDirectory is not supported on Web.');
  }

  @override
  Future<PickedDirectoryLocation?> restoreDirectory(String token) {
    throw UnsupportedError('restoreDirectory is not supported on Web.');
  }

  @override
  Future<void> releaseDirectory(String token) {
    throw UnsupportedError('releaseDirectory is not supported on Web.');
  }

  // saveFile
  // ─────────────────────────────────────────────────────────────────────────

  @override
  Stream<SaveProgress> saveFile({
    required String filePath,
    required String fileName,
    required FileType fileType,
    SaveLocation? saveLocation,
    String? subDir,
    ConflictResolution conflictResolution = ConflictResolution.autoRename,
  }) {
    throw const InvalidInputException(
      'saveFile is not supported on web. Use saveBytes or saveNetwork instead.',
    );
  }

  // ─────────────────────────────────────────────
  // saveNetwork (browser controlled)
  // ─────────────────────────────────────────────

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
    final fullName = '$fileName.${fileType.ext}';

    return WebUtils.executeSave((token, emit) async {
      // No custom headers → let browser stream natively.
      if (headers == null || headers.isEmpty) {
        WebUtils.triggerUrlDownload(url, fullName, fileType.mimeType);
        emit(
          SaveProgressComplete(Uri(scheme: 'browser-download', path: fullName)),
        );
        return;
      }

      // Custom headers require fetch() — loads file into memory (browser limitation).
      final body = await WebUtils.fetch(url, headers, timeout, token);
      final jsChunks = <JSUint8Array>[];
      var received = 0;
      await WebUtils.read(body.reader, timeout, token, (chunk) async {
        jsChunks.add(chunk);
        received += WebUtils.lengthOf(chunk);
        if (body.length case final length? when length > 0) {
          emit(SaveProgressUpdate(received / length));
        }
      });

      final blob = Blob(
        jsChunks.toJS as JSArray<BlobPart>,
        BlobPropertyBag(type: fileType.mimeType),
      );
      WebUtils.triggerBlobDownload(blob, fullName);
      emit(
        SaveProgressComplete(Uri(scheme: 'browser-download', path: fullName)),
      );
    });
  }

  // ─────────────────────────────────────────────
  // saveAs (FSA zero-RAM streaming)
  // ─────────────────────────────────────────────
  @override
  Stream<SaveProgress> saveAs({
    required SaveInput input,
    required FileType fileType,
    required String fileName,
    required PickedDirectoryLocation saveLocation,
    ConflictResolution conflictResolution = ConflictResolution.autoRename,
  }) {
    // If FSA is supported and we have a valid WebPickedDirectoryLocation
    if (saveLocation is WebPickedDirectoryLocation) {
      return switch (input) {
        SaveBytesInput(:final fileBytes) => _saveToDirectory(
          handle: saveLocation.directoryHandle,
          fileBytes: fileBytes,
          fileType: fileType,
          fileName: fileName,
          conflictResolution: conflictResolution,
        ),
        SaveNetworkInput(:final url, :final headers, :final timeout) =>
          _saveNetworkToDirectory(
            handle: saveLocation.directoryHandle,
            url: url,
            headers: headers,
            timeout: timeout,
            fileType: fileType,
            fileName: fileName,
            conflictResolution: conflictResolution,
          ),
        SaveFileInput() => throw const InvalidInputException(
          'saveFile is not supported on web.',
        ),
      };
    }

    // ─────────────────────────────────────────
    // Fallback for browsers WITHOUT FSA
    // ─────────────────────────────────────────

    // ⚠ Browser will control download location.
    return switch (input) {
      SaveBytesInput(:final fileBytes) => saveBytes(
        fileBytes: fileBytes,
        fileType: fileType,
        fileName: fileName,
      ),
      SaveNetworkInput(:final url, :final headers, :final timeout) =>
        saveNetwork(
          url: url,
          fileName: fileName,
          fileType: fileType,
          headers: headers,
          timeout: timeout,
        ),
      SaveFileInput() => throw const InvalidInputException(
        'saveFile is not supported on web.',
      ),
    };
  }

  // ─────────────────────────────────────────────
  // openWrite / openWriteAs
  // ─────────────────────────────────────────────

  /// Buffer fallback — bytes are accumulated in memory and downloaded on [close].
  ///
  /// ⚠ Web: `openWrite` without FSA always buffers to RAM.
  /// For zero-RAM streaming use [openWriteAs] with a [WebPickedDirectoryLocation].
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
    return WebFileSaverSink.buffer(
      name: '$fileName.${fileType.ext}',
      mimeType: fileType.mimeType,
      totalSize: totalSize,
    );
  }

  /// FSA mode when [saveLocation] is [WebPickedDirectoryLocation] — zero-RAM streaming.
  /// Falls back to buffer mode for browsers without FSA support.
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
    final fullName = '$fileName.${fileType.ext}';

    if (saveLocation is WebPickedDirectoryLocation) {
      final handle = saveLocation.directoryHandle;
      final fileEntity = WebFileEntity(handle);
      final resolvedName = await ConflictResolver(
        fileEntity,
      ).resolve(fullName, conflictResolution);
      if (resolvedName == null) return null;
      final created = !await fileEntity.exists(resolvedName);

      final fileHandle = await handle
          .getFileHandle(resolvedName, FileSystemGetFileOptions(create: true))
          .toDart;
      final writable = await fileHandle.createWritable().toDart;

      return WebFileSaverSink.fsa(
        directory: handle,
        name: resolvedName,
        writable: writable,
        created: created,
        totalSize: totalSize,
      );
    }

    // Fallback for browsers without FSA.
    return WebFileSaverSink.buffer(
      name: fullName,
      mimeType: fileType.mimeType,
      totalSize: totalSize,
    );
  }

  // ─────────────────────────────────────────────
  // FSA: Save Bytes
  // ─────────────────────────────────────────────

  Stream<SaveProgress> _saveToDirectory({
    required FileSystemDirectoryHandle handle,
    required Uint8List fileBytes,
    required FileType fileType,
    required String fileName,
    ConflictResolution conflictResolution = ConflictResolution.autoRename,
  }) {
    validateBytesInput(fileBytes, fileName);
    final fullName = '$fileName.${fileType.ext}';

    return WebUtils.executeSave((token, emit) async {
      final resolvedName = await _resolve(handle, fullName, conflictResolution);
      if (resolvedName == null) {
        emit(
          SaveProgressComplete(Uri(scheme: 'web-directory', path: fullName)),
        );
        return;
      }

      await _writeFile(handle, resolvedName, token, (writable) async {
        emit(const SaveProgressUpdate(0.1));
        await writable.write(fileBytes.toJS as FileSystemWriteChunkType).toDart;
        emit(const SaveProgressUpdate(1.0));
      });
      emit(
        SaveProgressComplete(Uri(scheme: 'web-directory', path: resolvedName)),
      );
    });
  }

  // ─────────────────────────────────────────────
  // FSA: Zero-RAM streaming download
  // ─────────────────────────────────────────────

  Stream<SaveProgress> _saveNetworkToDirectory({
    required FileSystemDirectoryHandle handle,
    required String url,
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 60),
    required FileType fileType,
    required String fileName,
    ConflictResolution conflictResolution = ConflictResolution.autoRename,
  }) {
    validateNetworkInput(url, fileName);
    final fullName = '$fileName.${fileType.ext}';

    return WebUtils.executeSave((token, emit) async {
      // Resolved first, so `skip` downloads nothing.
      final resolvedName = await _resolve(handle, fullName, conflictResolution);
      if (resolvedName == null) {
        emit(
          SaveProgressComplete(Uri(scheme: 'web-directory', path: fullName)),
        );
        return;
      }

      final body = await WebUtils.fetch(url, headers, timeout, token);
      try {
        await _writeFile(handle, resolvedName, token, (writable) async {
          var written = 0;
          await WebUtils.read(body.reader, timeout, token, (chunk) async {
            await writable.write(chunk as FileSystemWriteChunkType).toDart;
            written += WebUtils.lengthOf(chunk);
            if (body.length case final length? when length > 0) {
              emit(SaveProgressUpdate(written / length));
            }
          });
        });
      } catch (_) {
        // Closes the connection of a body that won't be read to the end.
        body.reader?.cancel().toDart.ignore();
        rethrow;
      }
      emit(
        SaveProgressComplete(Uri(scheme: 'web-directory', path: resolvedName)),
      );
    });
  }

  /// The name to save [fullName] under in [handle], or null to skip it.
  Future<String?> _resolve(
    FileSystemDirectoryHandle handle,
    String fullName,
    ConflictResolution conflictResolution,
  ) async {
    try {
      return await ConflictResolver(
        WebFileEntity(handle),
      ).resolve(fullName, conflictResolution);
    } on FileSaverException {
      rethrow;
    } catch (e) {
      throw mapFsaError(e);
    }
  }

  /// Writes the file [name] in [directory] with [write], then closes it.
  ///
  /// A failed or cancelled write deletes the file if it is new. An existing
  /// file keeps its content, because the browser writes to a swap file until
  /// the close.
  Future<void> _writeFile(
    FileSystemDirectoryHandle directory,
    String name,
    WebCancellationToken token,
    Future<void> Function(FileSystemWritableFileStream writable) write,
  ) async {
    final fileEntity = WebFileEntity(directory);
    final created = !await fileEntity.exists(name);
    FileSystemWritableFileStream? writable;
    try {
      token.check();
      final fileHandle = await directory
          .getFileHandle(name, FileSystemGetFileOptions(create: true))
          .toDart;
      writable = await fileHandle.createWritable().toDart;
      token.check();
      await write(writable);
      token.check();
      await writable.close().toDart;
    } catch (e) {
      // The open writable locks the file: abort it before the delete.
      try {
        await writable?.abort().toDart;
      } catch (_) {}
      if (created) {
        try {
          await fileEntity.delete(name);
        } catch (_) {}
      }
      throw e is FileSaverException ? e : mapFsaError(e);
    }
  }
}
