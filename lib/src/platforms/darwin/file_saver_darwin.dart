import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

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
import 'bindings.g.dart';
import 'darwin_file_saver_sink.dart';

typedef NativeVoidFun = NativeFunction<Void Function(Pointer<Void>)>;

/// FileSaver implementation for Apple platforms (iOS and macOS).
///
/// Uses shared darwin code with platform-specific behaviors:
/// - iOS: Supports Photos Library and Documents
/// - macOS: Supports Documents, Downloads, and Desktop
class FileSaverDarwin extends FileSaverPlatform implements Finalizable {
  FileSaverDarwin() {
    final dylib = DynamicLibrary.process();
    _fileSaver = FileSaverFFI(dylib);

    // Initialize Dart API DL for NativePort communication
    final initResult = _fileSaver.initDartApiDl(NativeApi.initializeApiDLData);
    if (initResult != 0) {
      throw const NativePlatformException(
        'Failed to initialize Dart API DL',
        'INIT_FAILED',
      );
    }

    _saverInstance = _fileSaver.init();

    if (_saverInstance.address != 0) {
      _finalizer.attach(this, _saverInstance.cast());
    }
  }

  late final FileSaverFFI _fileSaver;
  late final Pointer<Void> _saverInstance;

  static final int _disposeAddress =
      DynamicLibrary.process()
          .lookup<NativeVoidFun>('file_saver_dispose')
          .address;

  static final Pointer<NativeFinalizerFunction> _nativeFinalizerPtr =
      Pointer.fromAddress(_disposeAddress);

  static final _finalizer = NativeFinalizer(_nativeFinalizerPtr);

  /// Registers this class as the default instance of [FileSaverPlatform].
  static void registerWith() {
    FileSaverPlatform.instance = FileSaverDarwin();
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
      final receivePort = ReceivePort();
      final arena = Arena();
      final nativePort = receivePort.sendPort.nativePort;
      bool cleanedUp = false;

      void cleanup() {
        if (cleanedUp) return;
        cleanedUp = true;
        receivePort.close();
        arena.releaseAll();
        controller.closeSync();
      }

      // Allocate in arena - all freed together with arena.releaseAll()
      final dataPointer = arena<Uint8>(fileBytes.length);
      dataPointer.asTypedList(fileBytes.length).setAll(0, fileBytes);

      final fileNameCStr = fileName.toNativeUtf8(allocator: arena);
      final extCStr = fileType.ext.toNativeUtf8(allocator: arena);
      final mimeCStr = fileType.mimeType.toNativeUtf8(allocator: arena);
      final saveLocationIndex = _saveLocationToIndex(saveLocation);
      final subDirCStr = subDir?.toNativeUtf8(allocator: arena);

      // Listen to native port - cleanup happens here on terminal events
      receivePort.listen((message) {
        if (cleanedUp || controller.isClosed) return;

        final event = parseDarwinMessage(message);
        controller.addSync(event);

        if (isTerminal(event)) cleanup();
      });

      // Call native function - returns tokenId for cancellation
      final tokenId = _fileSaver.saveBytes(
        _saverInstance,
        dataPointer,
        fileBytes.length,
        fileNameCStr.cast(),
        extCStr.cast(),
        mimeCStr.cast(),
        saveLocationIndex,
        subDirCStr?.cast() ?? nullptr,
        conflictResolution.index,
        nativePort,
      );

      controller.onCancel = () {
        _fileSaver.cancel(tokenId);
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
      final receivePort = ReceivePort();
      final arena = Arena();
      final nativePort = receivePort.sendPort.nativePort;
      bool cleanedUp = false;

      void cleanup() {
        if (cleanedUp) return;
        cleanedUp = true;
        receivePort.close();
        arena.releaseAll();
        controller.closeSync();
      }

      // Allocate in arena - all freed together with arena.releaseAll()
      final filePathCStr = filePath.toNativeUtf8(allocator: arena);
      final fileNameCStr = fileName.toNativeUtf8(allocator: arena);
      final extCStr = fileType.ext.toNativeUtf8(allocator: arena);
      final mimeCStr = fileType.mimeType.toNativeUtf8(allocator: arena);
      final saveLocationIndex = _saveLocationToIndex(saveLocation);
      final subDirCStr = subDir?.toNativeUtf8(allocator: arena);

      // Listen to native port - cleanup happens here on terminal events
      receivePort.listen((message) {
        if (cleanedUp || controller.isClosed) return;

        final event = parseDarwinMessage(message);
        controller.addSync(event);

        if (isTerminal(event)) cleanup();
      });

      // Call native function - returns tokenId for cancellation
      final tokenId = _fileSaver.saveFile(
        _saverInstance,
        filePathCStr.cast(),
        fileNameCStr.cast(),
        extCStr.cast(),
        mimeCStr.cast(),
        saveLocationIndex,
        subDirCStr?.cast() ?? nullptr,
        conflictResolution.index,
        nativePort,
      );

      controller.onCancel = () {
        _fileSaver.cancel(tokenId);
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
      final receivePort = ReceivePort();
      final arena = Arena();
      final nativePort = receivePort.sendPort.nativePort;
      bool cleanedUp = false;

      void cleanup() {
        if (cleanedUp) return;
        cleanedUp = true;
        receivePort.close();
        arena.releaseAll();
        controller.closeSync();
      }

      // Allocate in arena - all freed together with arena.releaseAll()
      final urlCStr = url.toNativeUtf8(allocator: arena);
      final headersJsonCStr =
          headers != null
              ? jsonEncode(headers).toNativeUtf8(allocator: arena)
              : null;
      final fileNameCStr = fileName.toNativeUtf8(allocator: arena);
      final extCStr = fileType.ext.toNativeUtf8(allocator: arena);
      final mimeCStr = fileType.mimeType.toNativeUtf8(allocator: arena);
      final saveLocationIndex = _saveLocationToIndex(saveLocation);
      final subDirCStr = subDir?.toNativeUtf8(allocator: arena);

      // Listen to native port - cleanup happens here on terminal events
      receivePort.listen((message) {
        if (cleanedUp || controller.isClosed) return;

        final event = parseDarwinMessage(message);
        controller.addSync(event);

        if (isTerminal(event)) cleanup();
      });

      // Call native function - returns tokenId for cancellation
      final tokenId = _fileSaver.saveNetwork(
        _saverInstance,
        urlCStr.cast(),
        headersJsonCStr?.cast() ?? nullptr,
        timeout.inSeconds,
        fileNameCStr.cast(),
        extCStr.cast(),
        mimeCStr.cast(),
        saveLocationIndex,
        subDirCStr?.cast() ?? nullptr,
        conflictResolution.index,
        nativePort,
      );

      controller.onCancel = () {
        _fileSaver.cancel(tokenId);
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
        conflictResolution: conflictResolution,
      ),
      SaveFileInput(:final filePath) => _saveFileAs(
        filePath: filePath,
        directoryUri: saveLocation.uri.toString(),
        baseFileName: fileName,
        extension: fileType.ext,
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
          conflictResolution: conflictResolution,
        ),
    };
  }

  Stream<SaveProgress> _saveBytesAs({
    required Uint8List fileBytes,
    required String directoryUri,
    required String baseFileName,
    required String extension,
    required ConflictResolution conflictResolution,
  }) {
    return Stream.multi((controller) {
      final receivePort = ReceivePort();
      final arena = Arena();
      final nativePort = receivePort.sendPort.nativePort;
      bool cleanedUp = false;

      void cleanup() {
        if (cleanedUp) return;
        cleanedUp = true;
        receivePort.close();
        arena.releaseAll();
        controller.closeSync();
      }

      final dataPointer = arena<Uint8>(fileBytes.length);
      dataPointer.asTypedList(fileBytes.length).setAll(0, fileBytes);
      final dirUriCStr = directoryUri.toNativeUtf8(allocator: arena);
      final baseFileNameCStr = baseFileName.toNativeUtf8(allocator: arena);
      final extCStr = extension.toNativeUtf8(allocator: arena);

      receivePort.listen((message) {
        if (cleanedUp || controller.isClosed) return;
        final event = parseDarwinMessage(message);
        controller.addSync(event);
        if (isTerminal(event)) cleanup();
      });

      final tokenId = _fileSaver.saveBytesAs(
        _saverInstance,
        dataPointer,
        fileBytes.length,
        dirUriCStr.cast(),
        baseFileNameCStr.cast(),
        extCStr.cast(),
        conflictResolution.index,
        nativePort,
      );

      controller.onCancel = () {
        _fileSaver.cancel(tokenId);
        Future.delayed(const Duration(milliseconds: 500), cleanup);
      };
    });
  }

  Stream<SaveProgress> _saveFileAs({
    required String filePath,
    required String directoryUri,
    required String baseFileName,
    required String extension,
    required ConflictResolution conflictResolution,
  }) {
    return Stream.multi((controller) {
      final receivePort = ReceivePort();
      final arena = Arena();
      final nativePort = receivePort.sendPort.nativePort;
      bool cleanedUp = false;

      void cleanup() {
        if (cleanedUp) return;
        cleanedUp = true;
        receivePort.close();
        arena.releaseAll();
        controller.closeSync();
      }

      final filePathCStr = filePath.toNativeUtf8(allocator: arena);
      final dirUriCStr = directoryUri.toNativeUtf8(allocator: arena);
      final baseFileNameCStr = baseFileName.toNativeUtf8(allocator: arena);
      final extCStr = extension.toNativeUtf8(allocator: arena);

      receivePort.listen((message) {
        if (cleanedUp || controller.isClosed) return;
        final event = parseDarwinMessage(message);
        controller.addSync(event);
        if (isTerminal(event)) cleanup();
      });

      final tokenId = _fileSaver.saveFileAs(
        _saverInstance,
        filePathCStr.cast(),
        dirUriCStr.cast(),
        baseFileNameCStr.cast(),
        extCStr.cast(),
        conflictResolution.index,
        nativePort,
      );

      controller.onCancel = () {
        _fileSaver.cancel(tokenId);
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
    required ConflictResolution conflictResolution,
  }) {
    return Stream.multi((controller) {
      final receivePort = ReceivePort();
      final arena = Arena();
      final nativePort = receivePort.sendPort.nativePort;
      bool cleanedUp = false;

      void cleanup() {
        if (cleanedUp) return;
        cleanedUp = true;
        receivePort.close();
        arena.releaseAll();
        controller.closeSync();
      }

      final urlCStr = url.toNativeUtf8(allocator: arena);
      final headersJsonCStr =
          headers != null
              ? jsonEncode(headers).toNativeUtf8(allocator: arena)
              : null;
      final dirUriCStr = directoryUri.toNativeUtf8(allocator: arena);
      final baseFileNameCStr = baseFileName.toNativeUtf8(allocator: arena);
      final extCStr = extension.toNativeUtf8(allocator: arena);

      receivePort.listen((message) {
        if (cleanedUp || controller.isClosed) return;
        final event = parseDarwinMessage(message);
        controller.addSync(event);
        if (isTerminal(event)) cleanup();
      });

      final tokenId = _fileSaver.saveNetworkAs(
        _saverInstance,
        urlCStr.cast(),
        headersJsonCStr?.cast() ?? nullptr,
        timeout.inSeconds,
        dirUriCStr.cast(),
        baseFileNameCStr.cast(),
        extCStr.cast(),
        conflictResolution.index,
        nativePort,
      );

      controller.onCancel = () {
        _fileSaver.cancel(tokenId);
        Future.delayed(const Duration(milliseconds: 500), cleanup);
      };
    });
  }

  @override
  Future<bool> canOpenFile(Uri uri) {
    return using((arena) {
      final uriCStr = uri.toString().toNativeUtf8(allocator: arena);
      return Future.value(_fileSaver.canOpenFile(uriCStr.cast()));
    });
  }

  @override
  Future<void> openFile(Uri uri, {String? mimeType}) async {
    final isIos = Platform.isIOS;
    final allowed =
        uri.isScheme('file') || (isIos && uri.scheme.toLowerCase() == 'ph');
    if (!allowed) {
      throw InvalidInputException(
        'openFile supports only file:// URIs${isIos ? " and ph:// URIs" : ""} on ${isIos ? "iOS" : "macOS"} (got: $uri)',
      );
    }

    if (uri.isScheme('file')) {
      if (!await File.fromUri(uri).exists()) {
        throw SourceFileNotFoundException(uri.toString());
      }
      if (!await canOpenFile(uri)) {
        throw OpenFailedException('File is not accessible: $uri');
      }
    } else {
      // iOS-only: ph:// (Photos asset). canOpenFile() checks PHAsset existence.
      if (!await canOpenFile(uri)) {
        throw SourceFileNotFoundException(uri.toString());
      }
    }

    final bool ok = using((arena) {
      final uriCStr = uri.toString().toNativeUtf8(allocator: arena);
      return _fileSaver.openFile(uriCStr.cast());
    });

    if (!ok) {
      throw OpenFailedException('Darwin native open returned false (uri=$uri)');
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

    final receivePort = ReceivePort();
    final completer = Completer<int>();
    receivePort.listen((message) {
      receivePort.close();
      final msg = message as List;
      switch (msg[0] as int) {
        case 3:
          if (!completer.isCompleted) {
            completer.complete(int.parse(msg[1] as String));
          }
        case 2:
          if (!completer.isCompleted) {
            completer.completeError(
              FileSaverException.fromErrorResult(
                msg[1] as String,
                msg[2] as String,
              ),
            );
          }
      }
    });
    using((arena) {
      final fileNameCStr = fileName.toNativeUtf8(allocator: arena);
      final extCStr = fileType.ext.toNativeUtf8(allocator: arena);
      final mimeCStr = fileType.mimeType.toNativeUtf8(allocator: arena);
      final subDirCStr = subDir?.toNativeUtf8(allocator: arena);
      _fileSaver.openWrite(
        _saverInstance,
        fileNameCStr.cast(),
        extCStr.cast(),
        mimeCStr.cast(),
        _saveLocationToIndex(saveLocation),
        subDirCStr?.cast() ?? nullptr,
        conflictResolution.index,
        totalSize ?? -1,
        receivePort.sendPort.nativePort,
      );
    });
    final sessionId = await completer.future;
    if (sessionId == 0) return null;
    return DarwinFileSaverSink(
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
    final receivePort = ReceivePort();
    final completer = Completer<int>();
    receivePort.listen((message) {
      receivePort.close();
      final msg = message as List;
      switch (msg[0] as int) {
        case 3:
          if (!completer.isCompleted) {
            completer.complete(int.parse(msg[1] as String));
          }
        case 2:
          if (!completer.isCompleted) {
            completer.completeError(
              FileSaverException.fromErrorResult(
                msg[1] as String,
                msg[2] as String,
              ),
            );
          }
      }
    });
    using((arena) {
      final dirUriCStr = saveLocation.uri.toString().toNativeUtf8(
        allocator: arena,
      );
      final fileNameCStr = fileName.toNativeUtf8(allocator: arena);
      final extCStr = fileType.ext.toNativeUtf8(allocator: arena);
      _fileSaver.openWriteAs(
        _saverInstance,
        dirUriCStr.cast(),
        fileNameCStr.cast(),
        extCStr.cast(),
        conflictResolution.index,
        totalSize ?? -1,
        receivePort.sendPort.nativePort,
      );
    });
    final sessionId = await completer.future;
    if (sessionId == 0) return null;
    return DarwinFileSaverSink(
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
  /// Maps platform-specific save locations to their FFI integer values:
  /// - iOS: [IosSaveLocation.documents] = 0 (default), etc.
  /// - macOS: [MacosSaveLocation.downloads] = 0 (default), etc.
  int _saveLocationToIndex(SaveLocation? saveLocation) {
    return switch (saveLocation) {
      IosSaveLocation location => location.index,
      MacosSaveLocation location => location.index,
      _ => 0,
    };
  }
}
