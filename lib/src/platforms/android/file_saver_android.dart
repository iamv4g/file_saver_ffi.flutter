import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:jni/jni.dart';

import '../../exceptions/file_saver_exceptions.dart';
import '../../models/conflict_resolution.dart';
import '../../models/file_saver_sink.dart';
import '../../models/file_type.dart';
import '../../models/locations/save_location.dart';
import '../../models/save_input.dart';
import '../../models/save_progress.dart';
import '../../platform_interface/file_saver_platform.dart';
import '../shared/native_event_parser.dart';
import '../shared/path_location_writer.dart';
import 'android_file_saver_sink.dart';
import 'bindings.g.dart' as bindings;

class FileSaverAndroid extends FileSaverPlatform {
  /// Native FileSaver instance - lazily initialized to avoid JNI calls during
  /// plugin registration (before JniPlugin has set up the JVM context).
  late final bindings.FileSaver _fileSaver = bindings.FileSaver();

  /// Registers this class as the default instance of [FileSaverPlatform].
  static void registerWith() {
    FileSaverPlatform.instance = FileSaverAndroid();
  }

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

    return Stream.multi((controller) {
      bool cleanedUp = false;
      late final bindings.ProgressCallback callback;

      final jByteArray = JByteArray.of(fileBytes);
      final jFileName = fileName.toJString();
      final jExtension = fileType.ext.toJString();
      final jMimeType = fileType.mimeType.toJString();
      final jConflictMode = conflictResolution.index;
      final jSaveLocationIndex = _saveLocationToIndex(saveLocation);
      final jSubDir = subDir?.toJString();

      void cleanup() {
        if (cleanedUp) return;
        cleanedUp = true;

        // Defer release out of [callback] stack
        Future.microtask(() {
          if (!controller.isClosed) controller.closeSync();
          callback.release();
        });
      }

      // Create callback - cleanup happens on terminal events
      callback = bindings.ProgressCallback.implement(
        bindings.$ProgressCallback(
          onEvent: (eventType, progress, data, message) {
            if (cleanedUp || controller.isClosed) return;

            final event = _parseEvent(eventType, progress, data, message);
            controller.addSync(event);

            if (isTerminal(event)) cleanup();
          },
          onEvent$async: true,
        ),
      );

      // Call native method - returns operationId for cancellation
      final operationId = _fileSaver.saveBytes(
        jByteArray,
        jFileName,
        jExtension,
        jMimeType,
        jSaveLocationIndex,
        jSubDir,
        jConflictMode,
        callback,
      );

      controller.onCancel = () {
        _fileSaver.cancelOperation(operationId);
        // Fallback cleanup if native doesn't respond with Cancelled event
        Future.delayed(const Duration(milliseconds: 500), cleanup);
      };
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

    return Stream.multi((controller) {
      bool cleanedUp = false;
      late final bindings.ProgressCallback callback;

      final jFilePath = filePath.toJString();
      final jFileName = fileName.toJString();
      final jExtension = fileType.ext.toJString();
      final jMimeType = fileType.mimeType.toJString();
      final jConflictMode = conflictResolution.index;
      final jSaveLocationIndex = _saveLocationToIndex(saveLocation);
      final jSubDir = subDir?.toJString();

      void cleanup() {
        if (cleanedUp) return;
        cleanedUp = true;

        // Defer release out of [callback] stack
        Future.microtask(() {
          if (!controller.isClosed) controller.closeSync();
          callback.release();
        });
      }

      // Create callback - cleanup happens on terminal events
      callback = bindings.ProgressCallback.implement(
        bindings.$ProgressCallback(
          onEvent: (eventType, progress, data, message) {
            if (cleanedUp || controller.isClosed) return;

            final event = _parseEvent(eventType, progress, data, message);
            controller.addSync(event);

            if (isTerminal(event)) cleanup();
          },
          onEvent$async: true,
        ),
      );

      // Call native method - returns operationId for cancellation
      final operationId = _fileSaver.saveFile(
        jFilePath,
        jFileName,
        jExtension,
        jMimeType,
        jSaveLocationIndex,
        jSubDir,
        jConflictMode,
        callback,
      );

      controller.onCancel = () {
        _fileSaver.cancelOperation(operationId);
        // Fallback cleanup if native doesn't respond with Cancelled event
        Future.delayed(const Duration(milliseconds: 500), cleanup);
      };
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

    return Stream.multi((controller) {
      bool cleanedUp = false;
      late final bindings.ProgressCallback callback;

      final jUrl = url.toJString();
      final jHeadersJson = headers != null
          ? jsonEncode(headers).toJString()
          : null;
      final jTimeoutMs = timeout.inMilliseconds;
      final jFileName = fileName.toJString();
      final jExtension = fileType.ext.toJString();
      final jMimeType = fileType.mimeType.toJString();
      final jConflictMode = conflictResolution.index;
      final jSaveLocationIndex = _saveLocationToIndex(saveLocation);
      final jSubDir = subDir?.toJString();

      void cleanup() {
        if (cleanedUp) return;
        cleanedUp = true;

        // Defer release out of [callback] stack
        Future.microtask(() {
          if (!controller.isClosed) controller.closeSync();
          callback.release();
        });
      }

      // Create callback - cleanup happens on terminal events
      callback = bindings.ProgressCallback.implement(
        bindings.$ProgressCallback(
          onEvent: (eventType, progress, data, message) {
            if (cleanedUp || controller.isClosed) return;

            final event = _parseEvent(eventType, progress, data, message);
            controller.addSync(event);

            if (isTerminal(event)) cleanup();
          },
          onEvent$async: true,
        ),
      );

      // Call native method - returns operationId for cancellation
      final operationId = _fileSaver.saveNetwork(
        jUrl,
        jHeadersJson,
        jTimeoutMs,
        jFileName,
        jExtension,
        jMimeType,
        jSaveLocationIndex,
        jSubDir,
        jConflictMode,
        callback,
      );

      controller.onCancel = () {
        _fileSaver.cancelOperation(operationId);
        // Fallback cleanup if native doesn't respond with Cancelled event
        Future.delayed(const Duration(milliseconds: 500), cleanup);
      };
    });
  }

  @override
  Stream<SaveProgress> saveAs({
    required SaveInput input,
    required FileType fileType,
    required String fileName,
    required PickedDirectoryLocation saveLocation,
    ConflictResolution conflictResolution = ConflictResolution.autoRename,
  }) {
    return switch (input) {
      SaveBytesInput(:final fileBytes) => _saveBytesAs(
        fileBytes: fileBytes,
        directoryUri: saveLocation.uri.toString(),
        baseFileName: fileName,
        extension: fileType.ext,
        mimeType: fileType.mimeType,
        conflictResolution: conflictResolution,
      ),
      SaveFileInput(:final filePath) => _saveFileAs(
        filePath: filePath,
        directoryUri: saveLocation.uri.toString(),
        baseFileName: fileName,
        extension: fileType.ext,
        mimeType: fileType.mimeType,
        conflictResolution: conflictResolution,
      ),
      SaveNetworkInput(:final url, :final headers, :final timeout) =>
        _saveNetworkAs(
          url: url,
          headers: headers,
          timeout: timeout,
          directoryUri: saveLocation.uri.toString(),
          baseFileName: fileName,
          extension: fileType.ext,
          mimeType: fileType.mimeType,
          conflictResolution: conflictResolution,
        ),
    };
  }

  Stream<SaveProgress> _saveBytesAs({
    required Uint8List fileBytes,
    required String directoryUri,
    required String baseFileName,
    required String extension,
    required String mimeType,
    required ConflictResolution conflictResolution,
  }) {
    return Stream.multi((controller) {
      bool cleanedUp = false;
      late final bindings.ProgressCallback callback;

      final jByteArray = JByteArray.of(fileBytes);
      final jDirectoryUri = directoryUri.toJString();
      final jBaseFileName = baseFileName.toJString();
      final jExtension = extension.toJString();
      final jMimeType = mimeType.toJString();
      final jConflictMode = conflictResolution.index;

      void cleanup() {
        if (cleanedUp) return;
        cleanedUp = true;
        Future.microtask(() {
          if (!controller.isClosed) controller.closeSync();
          callback.release();
        });
      }

      callback = bindings.ProgressCallback.implement(
        bindings.$ProgressCallback(
          onEvent: (eventType, progress, data, message) {
            if (cleanedUp || controller.isClosed) return;
            final event = _parseEvent(eventType, progress, data, message);
            controller.addSync(event);
            if (isTerminal(event)) cleanup();
          },
          onEvent$async: true,
        ),
      );

      final operationId = _fileSaver.saveBytesAs(
        jByteArray,
        jDirectoryUri,
        jBaseFileName,
        jExtension,
        jMimeType,
        jConflictMode,
        callback,
      );

      controller.onCancel = () {
        _fileSaver.cancelOperation(operationId);
        Future.delayed(const Duration(milliseconds: 500), cleanup);
      };
    });
  }

  Stream<SaveProgress> _saveFileAs({
    required String filePath,
    required String directoryUri,
    required String baseFileName,
    required String extension,
    required String mimeType,
    required ConflictResolution conflictResolution,
  }) {
    return Stream.multi((controller) {
      bool cleanedUp = false;
      late final bindings.ProgressCallback callback;

      final jFilePath = filePath.toJString();
      final jDirectoryUri = directoryUri.toJString();
      final jBaseFileName = baseFileName.toJString();
      final jExtension = extension.toJString();
      final jMimeType = mimeType.toJString();
      final jConflictMode = conflictResolution.index;

      void cleanup() {
        if (cleanedUp) return;
        cleanedUp = true;
        Future.microtask(() {
          if (!controller.isClosed) controller.closeSync();
          callback.release();
        });
      }

      callback = bindings.ProgressCallback.implement(
        bindings.$ProgressCallback(
          onEvent: (eventType, progress, data, message) {
            if (cleanedUp || controller.isClosed) return;
            final event = _parseEvent(eventType, progress, data, message);
            controller.addSync(event);
            if (isTerminal(event)) cleanup();
          },
          onEvent$async: true,
        ),
      );

      final operationId = _fileSaver.saveFileAs(
        jFilePath,
        jDirectoryUri,
        jBaseFileName,
        jExtension,
        jMimeType,
        jConflictMode,
        callback,
      );

      controller.onCancel = () {
        _fileSaver.cancelOperation(operationId);
        Future.delayed(const Duration(milliseconds: 500), cleanup);
      };
    });
  }

  Stream<SaveProgress> _saveNetworkAs({
    required String url,
    required Map<String, String>? headers,
    required Duration timeout,
    required String directoryUri,
    required String baseFileName,
    required String extension,
    required String mimeType,
    required ConflictResolution conflictResolution,
  }) {
    return Stream.multi((controller) {
      bool cleanedUp = false;
      late final bindings.ProgressCallback callback;

      final jUrl = url.toJString();
      final jHeadersJson = headers != null
          ? jsonEncode(headers).toJString()
          : null;
      final jTimeoutMs = timeout.inMilliseconds;
      final jDirectoryUri = directoryUri.toJString();
      final jBaseFileName = baseFileName.toJString();
      final jExtension = extension.toJString();
      final jMimeType = mimeType.toJString();
      final jConflictMode = conflictResolution.index;

      void cleanup() {
        if (cleanedUp) return;
        cleanedUp = true;
        Future.microtask(() {
          if (!controller.isClosed) controller.closeSync();
          callback.release();
        });
      }

      callback = bindings.ProgressCallback.implement(
        bindings.$ProgressCallback(
          onEvent: (eventType, progress, data, message) {
            if (cleanedUp || controller.isClosed) return;
            final event = _parseEvent(eventType, progress, data, message);
            controller.addSync(event);
            if (isTerminal(event)) cleanup();
          },
          onEvent$async: true,
        ),
      );

      final operationId = _fileSaver.saveNetworkAs(
        jUrl,
        jHeadersJson,
        jTimeoutMs,
        jDirectoryUri,
        jBaseFileName,
        jExtension,
        jMimeType,
        jConflictMode,
        callback,
      );

      controller.onCancel = () {
        _fileSaver.cancelOperation(operationId);
        Future.delayed(const Duration(milliseconds: 500), cleanup);
      };
    });
  }

  @override
  Future<bool> canOpenFile(Uri uri) async {
    final jUri = uri.toString().toJString();
    return _fileSaver.canOpenFile(jUri);
  }

  @override
  Future<void> openFile(Uri uri, {String? mimeType}) async {
    if (!uri.isScheme('content') && !uri.isScheme('file')) {
      throw InvalidInputException(
        'openFile supports only content:// and file:// URIs on Android (got: $uri)',
      );
    }

    if (!await canOpenFile(uri)) {
      throw OpenFailedException('File is not accessible: $uri');
    }

    try {
      final jUri = uri.toString().toJString();
      final jMimeType = mimeType?.toJString();
      _fileSaver.openFile(jUri, jMimeType);
    } catch (e) {
      if (e is FileSaverException) rethrow;
      throw OpenFailedException('$e');
    }
  }

  @override
  Future<FileSaverSink?> openWrite({
    required String fileName,
    required FileType fileType,
    SaveLocation? saveLocation,
    String? subDir,
    int? totalSize,
    ConflictResolution conflictResolution = ConflictResolution.autoRename,
  }) async {
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

    final completer = Completer<int>();
    bindings.ProgressCallback? callback;
    callback = bindings.ProgressCallback.implement(
      bindings.$ProgressCallback(
        onEvent: (eventType, progress, jStr1, jStr2) {
          switch (eventType) {
            case 3:
              final sessionIdStr =
                  jStr1?.toDartString(releaseOriginal: true) ?? '0';
              jStr2?.release();
              if (!completer.isCompleted) {
                completer.complete(int.parse(sessionIdStr));
              }
            case 2:
              final code =
                  jStr1?.toDartString(releaseOriginal: true) ?? 'UNKNOWN';
              final msg = jStr2?.toDartString(releaseOriginal: true) ?? '';
              if (!completer.isCompleted) {
                completer.completeError(
                  FileSaverException.fromErrorResult(code, msg),
                );
              }
            default:
              jStr1?.release();
              jStr2?.release();
          }
          Future.microtask(() => callback?.release());
        },
        onEvent$async: true,
      ),
    );
    _fileSaver.openWriteSession(
      fileName.toJString(),
      fileType.ext.toJString(),
      fileType.mimeType.toJString(),
      _saveLocationToIndex(saveLocation),
      subDir?.toJString(),
      conflictResolution.index,
      totalSize ?? -1,
      callback,
    );
    final sessionId = await completer.future;
    if (sessionId == 0) return null;
    return AndroidFileSaverSink(
      fileSaver: _fileSaver,
      sessionId: sessionId,
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
    final completer = Completer<int>();
    bindings.ProgressCallback? callback;
    callback = bindings.ProgressCallback.implement(
      bindings.$ProgressCallback(
        onEvent: (eventType, progress, jStr1, jStr2) {
          switch (eventType) {
            case 3:
              final sessionIdStr =
                  jStr1?.toDartString(releaseOriginal: true) ?? '0';
              jStr2?.release();
              if (!completer.isCompleted) {
                completer.complete(int.parse(sessionIdStr));
              }
            case 2:
              final code =
                  jStr1?.toDartString(releaseOriginal: true) ?? 'UNKNOWN';
              final msg = jStr2?.toDartString(releaseOriginal: true) ?? '';
              if (!completer.isCompleted) {
                completer.completeError(
                  FileSaverException.fromErrorResult(code, msg),
                );
              }
            default:
              jStr1?.release();
              jStr2?.release();
          }
          Future.microtask(() => callback?.release());
        },
        onEvent$async: true,
      ),
    );
    _fileSaver.openWriteSessionAs(
      saveLocation.uri.toString().toJString(),
      fileName.toJString(),
      fileType.ext.toJString(),
      fileType.mimeType.toJString(),
      conflictResolution.index,
      totalSize ?? -1,
      callback,
    );
    final sessionId = await completer.future;
    if (sessionId == 0) return null;
    return AndroidFileSaverSink(
      fileSaver: _fileSaver,
      sessionId: sessionId,
      totalSize: totalSize,
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Private Methods
  // ─────────────────────────────────────────────────────────────────────────

  /// Returns the native index for a [SaveLocation].
  ///
  /// Maps [AndroidSaveLocation] to its index value.
  /// Defaults to [AndroidSaveLocation.downloads] index.
  int _saveLocationToIndex(SaveLocation? saveLocation) {
    return switch (saveLocation) {
      AndroidSaveLocation location => location.index,
      _ => AndroidSaveLocation.downloads.index,
    };
  }

  /// Converts the JNI callback arguments to Dart and delegates to
  /// [parseNativeEvent]. See there for the event protocol.
  SaveProgress _parseEvent(
    int eventType,
    double progress,
    JString? data,
    JString? message,
  ) {
    return parseNativeEvent(
      eventType,
      progress: progress,
      data: data?.toDartString(releaseOriginal: true),
      message: message?.toDartString(releaseOriginal: true),
    );
  }
}
