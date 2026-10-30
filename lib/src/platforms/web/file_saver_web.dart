import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
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
import 'web_file_saver_sink.dart';
import 'web_utils.dart';

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
  }) async* {
    yield const SaveProgressStarted();
    validateBytesInput(fileBytes, fileName);
    WebUtils.triggerBytesDownload(
      fileBytes,
      '$fileName.${fileType.ext}',
      fileType.mimeType,
    );
    yield SaveProgressComplete(
      Uri(scheme: 'browser-download', path: '$fileName.${fileType.ext}'),
    );
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
  }) async* {
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

    return WebUtils.executeSave((token, controller) async {
      // No custom headers → let browser stream natively.
      if (headers == null || headers.isEmpty) {
        WebUtils.triggerUrlDownload(url, fullName, fileType.mimeType);
        controller.addSync(
          SaveProgressComplete(Uri(scheme: 'browser-download', path: fullName)),
        );
        return;
      }

      // Custom headers require fetch() — loads file into memory (browser limitation).
      final fetchController = AbortController();
      token.setController(fetchController);
      final connectionTimer = Timer(
        timeout,
        () => fetchController.abort("Connection timed out".toJS),
      );

      final Response response;
      try {
        response = await WebUtils.fetch(url, fetchController, headers: headers);
      } finally {
        connectionTimer.cancel();
      }

      if (token.isCancelled) return;

      if (!response.ok) {
        controller.addSync(
          SaveProgressError(
            NetworkException('HTTP ${response.status}: ${response.statusText}'),
          ),
        );
        return;
      }

      final total = int.tryParse(response.headers.get('content-length') ?? '');
      final reader = response.body!.getReader() as ReadableStreamDefaultReader;
      final jsChunks = <JSUint8Array>[];
      int received = 0;

      while (true) {
        if (token.isCancelled) return;
        final result = await reader.read().toDart;
        if (result.done) break;
        final chunk = result.value! as JSUint8Array;
        jsChunks.add(chunk);
        received += (chunk.getProperty('length'.toJS) as JSNumber).toDartInt;
        if (total != null && total > 0) {
          controller.addSync(SaveProgressUpdate(received / total));
        }
      }

      if (token.isCancelled) return;

      final blob = Blob(
        jsChunks.toJS as JSArray<BlobPart>,
        BlobPropertyBag(type: fileType.mimeType),
      );
      WebUtils.triggerBlobDownload(blob, fullName);
      controller.addSync(
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

    return WebUtils.executeSave((token, controller) async {
      final fileEntity = WebFileEntity(handle);
      final resolvedName = await ConflictResolver(
        fileEntity,
      ).resolve(fullName, conflictResolution);
      if (resolvedName == null) {
        controller.addSync(
          SaveProgressComplete(Uri(scheme: 'web-directory', path: fullName)),
        );
        return;
      }

      final fileHandle = await handle
          .getFileHandle(resolvedName, FileSystemGetFileOptions(create: true))
          .toDart;

      if (conflictResolution != ConflictResolution.overwrite) {
        token.setFileEntry(fileEntity, resolvedName);
      }

      if (token.isCancelled) return;

      controller.addSync(const SaveProgressUpdate(0.1));
      final writable = await fileHandle.createWritable().toDart;
      token.setWritable(writable);
      if (token.isCancelled) return;

      await writable.write(fileBytes.toJS as FileSystemWriteChunkType).toDart;
      if (token.isCancelled) return;
      controller.addSync(const SaveProgressUpdate(1.0));
      await writable.close().toDart;
      token.complete();
      controller.addSync(
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

    return WebUtils.executeSave((token, controller) async {
      final fileEntity = WebFileEntity(handle);
      final resolvedName = await ConflictResolver(
        fileEntity,
      ).resolve(fullName, conflictResolution);
      if (resolvedName == null) {
        controller.addSync(
          SaveProgressComplete(Uri(scheme: 'web-directory', path: fullName)),
        );
        return;
      }

      final fetchController = AbortController();
      token.setController(fetchController);

      Timer? idleTimer;

      void resetIdleTimer() {
        idleTimer?.cancel();
        idleTimer = Timer(
          timeout,
          () => fetchController.abort("Request timed out".toJS),
        );
      }

      resetIdleTimer();
      final response = await WebUtils.fetch(
        url,
        fetchController,
        headers: headers,
      );
      if (token.isCancelled) {
        idleTimer?.cancel();
        return;
      }

      if (!response.ok) {
        idleTimer?.cancel();
        controller.addSync(
          SaveProgressError(
            NetworkException('HTTP ${response.status}: ${response.statusText}'),
          ),
        );
        return;
      }

      final fileHandle = await handle
          .getFileHandle(resolvedName, FileSystemGetFileOptions(create: true))
          .toDart;

      if (conflictResolution != ConflictResolution.overwrite) {
        token.setFileEntry(fileEntity, resolvedName);
      }

      if (token.isCancelled) {
        idleTimer?.cancel();
        return;
      }

      final writable = await fileHandle.createWritable().toDart;
      token.setWritable(writable);
      final total = int.tryParse(response.headers.get('content-length') ?? '');
      final reader = response.body!.getReader() as ReadableStreamDefaultReader;

      int written = 0;
      resetIdleTimer();

      while (true) {
        if (token.isCancelled) break;

        final result = await reader.read().toDart;
        if (result.done) break;

        resetIdleTimer();

        final chunk = (result.value! as JSUint8Array).toDart;
        await writable.write(chunk.toJS as FileSystemWriteChunkType).toDart;
        written += chunk.lengthInBytes;

        if (total != null && total > 0) {
          controller.addSync(SaveProgressUpdate(written / total));
        }
      }

      idleTimer?.cancel();
      if (token.isCancelled) return;

      await writable.close().toDart;
      token.complete();
      controller.addSync(
        SaveProgressComplete(Uri(scheme: 'web-directory', path: resolvedName)),
      );
    });
  }
}
