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
import '../shared/single_subscription.dart';
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

    final jSaveLocationIndex = _saveLocationToIndex(saveLocation);
    return _runSave(
      (arena, callback) => _fileSaver.saveBytes(
        JByteArray.of(fileBytes)..releasedBy(arena),
        fileName.toJString()..releasedBy(arena),
        fileType.ext.toJString()..releasedBy(arena),
        fileType.mimeType.toJString()..releasedBy(arena),
        jSaveLocationIndex,
        subDir?.toJString()?..releasedBy(arena),
        conflictResolution.index,
        callback,
      ),
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

    if (saveLocation is PathLocation) {
      return PathLocationWriter.saveFile(
        filePath: filePath,
        dirPath: saveLocation.path,
        subDir: subDir,
        baseName: fileName,
        ext: fileType.ext,
        conflictResolution: conflictResolution,
        // dart:io can't open a content:// URI: the ContentResolver reads it.
        copySource: filePath.startsWith('content:') ? _copyToPath : null,
      );
    }

    final jSaveLocationIndex = _saveLocationToIndex(saveLocation);
    return _runSave(
      (arena, callback) => _fileSaver.saveFile(
        filePath.toJString()..releasedBy(arena),
        fileName.toJString()..releasedBy(arena),
        fileType.ext.toJString()..releasedBy(arena),
        fileType.mimeType.toJString()..releasedBy(arena),
        jSaveLocationIndex,
        subDir?.toJString()?..releasedBy(arena),
        conflictResolution.index,
        callback,
      ),
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

    final jSaveLocationIndex = _saveLocationToIndex(saveLocation);
    return _runSave(
      (arena, callback) => _fileSaver.saveNetwork(
        url.toJString()..releasedBy(arena),
        headers != null
            ? (jsonEncode(headers).toJString()..releasedBy(arena))
            : null,
        timeout.inMilliseconds,
        fileName.toJString()..releasedBy(arena),
        fileType.ext.toJString()..releasedBy(arena),
        fileType.mimeType.toJString()..releasedBy(arena),
        jSaveLocationIndex,
        subDir?.toJString()?..releasedBy(arena),
        conflictResolution.index,
        callback,
      ),
    );
  }

  @override
  Stream<SaveProgress> saveAs({
    required SaveInput input,
    required FileType fileType,
    required String fileName,
    required PickedDirectoryLocation saveLocation,
    ConflictResolution conflictResolution = ConflictResolution.autoRename,
  }) {
    validateSaveAsInput(input: input, fileName: fileName, fileType: fileType);
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
    return _runSave(
      (arena, callback) => _fileSaver.saveBytesAs(
        JByteArray.of(fileBytes)..releasedBy(arena),
        directoryUri.toJString()..releasedBy(arena),
        baseFileName.toJString()..releasedBy(arena),
        extension.toJString()..releasedBy(arena),
        mimeType.toJString()..releasedBy(arena),
        conflictResolution.index,
        callback,
      ),
    );
  }

  Stream<SaveProgress> _saveFileAs({
    required String filePath,
    required String directoryUri,
    required String baseFileName,
    required String extension,
    required String mimeType,
    required ConflictResolution conflictResolution,
  }) {
    return _runSave(
      (arena, callback) => _fileSaver.saveFileAs(
        filePath.toJString()..releasedBy(arena),
        directoryUri.toJString()..releasedBy(arena),
        baseFileName.toJString()..releasedBy(arena),
        extension.toJString()..releasedBy(arena),
        mimeType.toJString()..releasedBy(arena),
        conflictResolution.index,
        callback,
      ),
    );
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
    return _runSave(
      (arena, callback) => _fileSaver.saveNetworkAs(
        url.toJString()..releasedBy(arena),
        headers != null
            ? (jsonEncode(headers).toJString()..releasedBy(arena))
            : null,
        timeout.inMilliseconds,
        directoryUri.toJString()..releasedBy(arena),
        baseFileName.toJString()..releasedBy(arena),
        extension.toJString()..releasedBy(arena),
        mimeType.toJString()..releasedBy(arena),
        conflictResolution.index,
        callback,
      ),
    );
  }

  /// Picks a directory, and with [shouldPersist] keeps access to it after a
  /// restart with [persistDirectory], discarding the token.
  @override
  Future<PickedDirectoryLocation?> pickDirectory({
    bool shouldPersist = true,
  }) async {
    final location = await super.pickDirectory();
    if (location != null && shouldPersist) await persistDirectory(location);
    return location;
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

    final saveLocationIndex = _saveLocationToIndex(saveLocation);
    // Session id 0 means SKIP found an existing file and opened nothing.
    final result = await _callForResult(
      (arena, callback) => _fileSaver.openWriteSession(
        fileName.toJString()..releasedBy(arena),
        fileType.ext.toJString()..releasedBy(arena),
        fileType.mimeType.toJString()..releasedBy(arena),
        saveLocationIndex,
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
                  dataStr ?? FileSaverErrorCode.platform,
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

  /// How long cancelling a save waits for Kotlin to report that it stopped.
  static const _cancelTimeout = Duration(seconds: 2);

  /// Starts a save with [start] and returns its events.
  ///
  /// [start] calls the native function with the callback and returns the
  /// operation ID. The JNI arguments it registers on the arena are released
  /// once it has returned; the JVM keeps its own references.
  ///
  /// Cancelling the subscription cancels the save, and completes once Kotlin
  /// reports cancelled (4), which it does after deleting what it wrote, or
  /// after [_cancelTimeout] if a blocked read keeps it from stopping.
  Stream<SaveProgress> _runSave(
    int Function(Arena arena, bindings.ProgressCallback callback) start,
  ) {
    return singleSubscription((controller) {
      final ended = Completer<void>();
      late final bindings.ProgressCallback callback;

      void end() {
        if (ended.isCompleted) return;
        ended.complete();
        // Defer release out of [callback]'s own stack.
        Future.microtask(() {
          if (!controller.isClosed) controller.closeSync();
          callback.release();
        });
      }

      callback = bindings.ProgressCallback.implement(
        bindings.$ProgressCallback(
          onEvent: (eventType, progress, data, message) {
            final event = _parseEvent(eventType, progress, data, message);
            if (ended.isCompleted) return;
            controller.addSync(event);
            if (isTerminal(event)) end();
          },
          onEvent$async: true,
        ),
      );

      final int operationId;
      try {
        operationId = using((arena) => start(arena, callback));
      } catch (e) {
        callback.release();
        controller
          ..addSync(SaveProgressError(FileSaverException.fromObj(e)))
          ..closeSync();
        return;
      }

      controller.onCancel = () {
        // Also called once the stream has ended.
        if (ended.isCompleted) return null;
        _fileSaver.cancelOperation(operationId);
        return ended.future.timeout(_cancelTimeout, onTimeout: end);
      };
    });
  }

  /// Copies [source] into the file at [path] in Kotlin, which reads a
  /// `content://` URI through the `ContentResolver`. See [SourceCopier].
  ({Future<void> done, void Function() cancel}) _copyToPath(
    String source,
    String path,
    void Function(double progress) onProgress,
  ) {
    final done = Completer<void>();
    late final bindings.ProgressCallback callback;
    callback = bindings.ProgressCallback.implement(
      bindings.$ProgressCallback(
        onEvent: (eventType, progress, data, message) {
          final dataStr = data?.toDartString(releaseOriginal: true);
          final messageStr = message?.toDartString(releaseOriginal: true);
          if (done.isCompleted) return;
          switch (eventType) {
            case 1:
              onProgress(progress);
              return;
            case 3 || 4:
              done.complete();
            case 2:
              done.completeError(
                FileSaverException.fromErrorResult(
                  dataStr ?? FileSaverErrorCode.platform,
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

    final int operationId;
    try {
      operationId = using(
        (arena) => _fileSaver.copyToPath(
          source.toJString()..releasedBy(arena),
          path.toJString()..releasedBy(arena),
          callback,
        ),
      );
    } catch (_) {
      callback.release();
      rethrow;
    }

    return (
      done: done.future,
      cancel: () {
        _fileSaver.cancelOperation(operationId);
        // Kotlin opens [path] before it reads the source, so once a copy
        // stuck in the provider is given up on, it can't recreate the file.
        Future.delayed(_cancelTimeout, () {
          if (done.isCompleted) return;
          done.complete();
          callback.release();
        });
      },
    );
  }

  /// Returns the native index of [saveLocation], and that of
  /// [AndroidSaveLocation.downloads] for null.
  ///
  /// Throws [InvalidInputException] for another platform's location.
  int _saveLocationToIndex(SaveLocation? saveLocation) {
    final location = checkSaveLocation<AndroidSaveLocation>(saveLocation);
    return (location ?? AndroidSaveLocation.downloads).index;
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
      // Kotlin sends the HTTP status of a network error as the progress.
      statusCode: eventType == 2 && progress > 0 ? progress.toInt() : null,
    );
  }
}
