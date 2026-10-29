import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' show PlatformDispatcher;

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
  ///
  /// It is tied to the engine running this isolate, so its saves are cancelled
  /// when that engine is destroyed. A background isolate has no engine (-1).
  late final bindings.FileSaver _fileSaver = bindings.FileSaver(
    PlatformDispatcher.instance.engineId ?? -1,
  );

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
      // Releases the JNI arguments once the native call has returned; the JVM
      // keeps its own references for as long as the save runs.
      final arena = Arena();
      bool cleanedUp = false;
      late final bindings.ProgressCallback callback;

      final jByteArray = JByteArray.of(fileBytes)..releasedBy(arena);
      final jFileName = fileName.toJString()..releasedBy(arena);
      final jExtension = fileType.ext.toJString()..releasedBy(arena);
      final jMimeType = fileType.mimeType.toJString()..releasedBy(arena);
      final jConflictMode = conflictResolution.index;
      final jSaveLocationIndex = _saveLocationToIndex(saveLocation);
      final jSubDir = subDir?.toJString()?..releasedBy(arena);

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
      final int operationId;
      try {
        operationId = _fileSaver.saveBytes(
          jByteArray,
          jFileName,
          jExtension,
          jMimeType,
          jSaveLocationIndex,
          jSubDir,
          jConflictMode,
          callback,
        );
      } finally {
        arena.releaseAll();
      }

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
      // Releases the JNI arguments once the native call has returned; the JVM
      // keeps its own references for as long as the save runs.
      final arena = Arena();
      bool cleanedUp = false;
      late final bindings.ProgressCallback callback;

      final jFilePath = filePath.toJString()..releasedBy(arena);
      final jFileName = fileName.toJString()..releasedBy(arena);
      final jExtension = fileType.ext.toJString()..releasedBy(arena);
      final jMimeType = fileType.mimeType.toJString()..releasedBy(arena);
      final jConflictMode = conflictResolution.index;
      final jSaveLocationIndex = _saveLocationToIndex(saveLocation);
      final jSubDir = subDir?.toJString()?..releasedBy(arena);

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
      final int operationId;
      try {
        operationId = _fileSaver.saveFile(
          jFilePath,
          jFileName,
          jExtension,
          jMimeType,
          jSaveLocationIndex,
          jSubDir,
          jConflictMode,
          callback,
        );
      } finally {
        arena.releaseAll();
      }

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
      // Releases the JNI arguments once the native call has returned; the JVM
      // keeps its own references for as long as the save runs.
      final arena = Arena();
      bool cleanedUp = false;
      late final bindings.ProgressCallback callback;

      final jUrl = url.toJString()..releasedBy(arena);
      final jHeadersJson = headers != null
          ? (jsonEncode(headers).toJString()..releasedBy(arena))
          : null;
      final jTimeoutMs = timeout.inMilliseconds;
      final jFileName = fileName.toJString()..releasedBy(arena);
      final jExtension = fileType.ext.toJString()..releasedBy(arena);
      final jMimeType = fileType.mimeType.toJString()..releasedBy(arena);
      final jConflictMode = conflictResolution.index;
      final jSaveLocationIndex = _saveLocationToIndex(saveLocation);
      final jSubDir = subDir?.toJString()?..releasedBy(arena);

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
      final int operationId;
      try {
        operationId = _fileSaver.saveNetwork(
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
      } finally {
        arena.releaseAll();
      }

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
      // Releases the JNI arguments once the native call has returned; the JVM
      // keeps its own references for as long as the save runs.
      final arena = Arena();
      bool cleanedUp = false;
      late final bindings.ProgressCallback callback;

      final jByteArray = JByteArray.of(fileBytes)..releasedBy(arena);
      final jDirectoryUri = directoryUri.toJString()..releasedBy(arena);
      final jBaseFileName = baseFileName.toJString()..releasedBy(arena);
      final jExtension = extension.toJString()..releasedBy(arena);
      final jMimeType = mimeType.toJString()..releasedBy(arena);
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

      final int operationId;
      try {
        operationId = _fileSaver.saveBytesAs(
          jByteArray,
          jDirectoryUri,
          jBaseFileName,
          jExtension,
          jMimeType,
          jConflictMode,
          callback,
        );
      } finally {
        arena.releaseAll();
      }

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
      // Releases the JNI arguments once the native call has returned; the JVM
      // keeps its own references for as long as the save runs.
      final arena = Arena();
      bool cleanedUp = false;
      late final bindings.ProgressCallback callback;

      final jFilePath = filePath.toJString()..releasedBy(arena);
      final jDirectoryUri = directoryUri.toJString()..releasedBy(arena);
      final jBaseFileName = baseFileName.toJString()..releasedBy(arena);
      final jExtension = extension.toJString()..releasedBy(arena);
      final jMimeType = mimeType.toJString()..releasedBy(arena);
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

      final int operationId;
      try {
        operationId = _fileSaver.saveFileAs(
          jFilePath,
          jDirectoryUri,
          jBaseFileName,
          jExtension,
          jMimeType,
          jConflictMode,
          callback,
        );
      } finally {
        arena.releaseAll();
      }

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
      // Releases the JNI arguments once the native call has returned; the JVM
      // keeps its own references for as long as the save runs.
      final arena = Arena();
      bool cleanedUp = false;
      late final bindings.ProgressCallback callback;

      final jUrl = url.toJString()..releasedBy(arena);
      final jHeadersJson = headers != null
          ? (jsonEncode(headers).toJString()..releasedBy(arena))
          : null;
      final jTimeoutMs = timeout.inMilliseconds;
      final jDirectoryUri = directoryUri.toJString()..releasedBy(arena);
      final jBaseFileName = baseFileName.toJString()..releasedBy(arena);
      final jExtension = extension.toJString()..releasedBy(arena);
      final jMimeType = mimeType.toJString()..releasedBy(arena);
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

      final int operationId;
      try {
        operationId = _fileSaver.saveNetworkAs(
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
      } finally {
        arena.releaseAll();
      }

      controller.onCancel = () {
        _fileSaver.cancelOperation(operationId);
        Future.delayed(const Duration(milliseconds: 500), cleanup);
      };
    });
  }

  @override
  Future<bool> canOpenFile(Uri uri) async {
    final result = await _callForResult(
      (arena, callback) => _fileSaver.canOpenFile(
        uri.toString().toJString()..releasedBy(arena),
        callback,
      ),
    );
    return result == 'true';
  }

  @override
  Future<void> openFile(Uri uri, {String? mimeType}) async {
    if (!uri.isScheme('content') && !uri.isScheme('file')) {
      throw InvalidInputException(
        'openFile supports only content:// and file:// URIs on Android (got: $uri)',
      );
    }

    // Native side checks that the file exists and is readable, and reports
    // FILE_NOT_FOUND / OPEN_FAILED / INVALID_INPUT error codes.
    await _callForResult(
      (arena, callback) => _fileSaver.openFile(
        uri.toString().toJString()..releasedBy(arena),
        mimeType?.toJString()?..releasedBy(arena),
        callback,
      ),
    );
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

    // Session id 0 means SKIP found an existing file and opened nothing.
    final result = await _callForResult(
      (arena, callback) => _fileSaver.openWriteSession(
        fileName.toJString()..releasedBy(arena),
        fileType.ext.toJString()..releasedBy(arena),
        fileType.mimeType.toJString()..releasedBy(arena),
        _saveLocationToIndex(saveLocation),
        subDir?.toJString()?..releasedBy(arena),
        conflictResolution.index,
        totalSize ?? -1,
        callback,
      ),
    );
    final sessionId = int.parse(result ?? '0');
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
    // Session id 0 means SKIP found an existing file and opened nothing.
    final result = await _callForResult(
      (arena, callback) => _fileSaver.openWriteSessionAs(
        saveLocation.uri.toString().toJString()..releasedBy(arena),
        fileName.toJString()..releasedBy(arena),
        fileType.ext.toJString()..releasedBy(arena),
        fileType.mimeType.toJString()..releasedBy(arena),
        conflictResolution.index,
        totalSize ?? -1,
        callback,
      ),
    );
    final sessionId = int.parse(result ?? '0');
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

  /// Runs a native call that reports one result through a
  /// [bindings.ProgressCallback], and returns the data of its success event
  /// (3) or throws the [FileSaverException] of its error event (2).
  ///
  /// The JNI arguments [call] registers on the arena are released once the
  /// call has returned, and the callback after its result arrived.
  Future<String?> _callForResult(
    void Function(Arena arena, bindings.ProgressCallback callback) call,
  ) {
    final completer = Completer<String?>();
    late final bindings.ProgressCallback callback;
    callback = bindings.ProgressCallback.implement(
      bindings.$ProgressCallback(
        onEvent: (eventType, progress, data, message) {
          final dataStr = data?.toDartString(releaseOriginal: true);
          final messageStr = message?.toDartString(releaseOriginal: true);
          if (completer.isCompleted) return;
          switch (eventType) {
            case 3:
              completer.complete(dataStr);
            case 2:
              completer.completeError(
                FileSaverException.fromErrorResult(
                  dataStr ?? 'UNKNOWN',
                  messageStr ?? '',
                ),
              );
            default:
              return;
          }
          // Defer release out of [callback]'s own stack.
          Future.microtask(callback.release);
        },
        onEvent$async: true,
      ),
    );
    try {
      using((arena) => call(arena, callback));
    } catch (_) {
      callback.release();
      rethrow;
    }
    return completer.future;
  }

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
