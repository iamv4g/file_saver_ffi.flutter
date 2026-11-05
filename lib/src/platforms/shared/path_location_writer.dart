import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../exceptions/file_saver_exceptions.dart';
import '../../models/conflict_resolution.dart';
import '../../models/file_saver_sink.dart';
import '../../models/save_input.dart';
import '../../models/save_progress.dart';
import 'conflict_resolver.dart';
import 'file_name.dart';
import 'io_file_entity.dart';
import 'io_file_saver_sink.dart';
import 'single_subscription.dart';

/// The size of the chunks [SaveBytesInput] bytes are written in.
const int _chunkSize = 1024 * 1024;

/// Copies a source that `dart:io` can't read, such as an Android `content://`
/// URI, into the existing file at `path`, calling `onProgress` with the bytes
/// copied.
///
/// `done` completes when the copy has ended, or fails with a
/// [FileSaverException]. After `cancel` it completes once the copy no longer
/// writes to `path`.
typedef SourceCopier =
    ({Future<void> done, void Function() cancel}) Function(
      String source,
      String path,
      void Function(SaveProgressUpdate update) onProgress,
    );

/// Saves with `dart:io` into a directory: [PathLocation] on every IO platform,
/// and every save on Windows and Linux.
///
/// A save writes through an [IOWriteSession], one chunk at a time, so
/// progress counts bytes in the file and the source is paused while a chunk
/// is written. Cancelling the subscription stops the save, and a cancelled or
/// failed save deletes what it wrote and keeps a file it would overwrite.
///
/// [createHttpClient] creates the client of each download; a test can pass
/// one to see the client a download used.
final class PathLocationWriter {
  const PathLocationWriter({
    @visibleForTesting this.createHttpClient = HttpClient.new,
  });

  /// Creates the client of each download.
  final HttpClient Function() createHttpClient;

  static final _conflictResolver = ConflictResolver(const IOFileEntity());

  // MARK: PathLocation

  Stream<SaveProgress> saveBytes({
    required Uint8List fileBytes,
    required String dirPath,
    String? subDir,
    required String baseName,
    required String ext,
    required ConflictResolution conflictResolution,
  }) => save(
    input: SaveBytesInput(fileBytes),
    directory: _directory(dirPath, subDir),
    baseName: baseName,
    ext: ext,
    conflictResolution: conflictResolution,
  );

  /// Saves the file at [filePath], a path or `file://` URI. With
  /// [copySource], the source is copied by it instead, for a source `dart:io`
  /// can't read.
  Stream<SaveProgress> saveFile({
    required String filePath,
    required String dirPath,
    String? subDir,
    required String baseName,
    required String ext,
    required ConflictResolution conflictResolution,
    SourceCopier? copySource,
  }) => save(
    input: SaveFileInput(filePath),
    directory: _directory(dirPath, subDir),
    baseName: baseName,
    ext: ext,
    conflictResolution: conflictResolution,
    copySource: copySource,
  );

  Stream<SaveProgress> saveNetwork({
    required String url,
    required Map<String, String>? headers,
    required Duration timeout,
    required String dirPath,
    String? subDir,
    required String baseName,
    required String ext,
    required ConflictResolution conflictResolution,
  }) => save(
    input: SaveNetworkInput(url: url, headers: headers, timeout: timeout),
    directory: _directory(dirPath, subDir),
    baseName: baseName,
    ext: ext,
    conflictResolution: conflictResolution,
  );

  Future<FileSaverSink?> openWrite({
    required String dirPath,
    String? subDir,
    required String baseName,
    required String ext,
    required ConflictResolution conflictResolution,
    int? totalSize,
  }) async {
    checkFileName('$baseName.$ext');
    final targetDirPath = await _directory(dirPath, subDir)();
    final resolved = await _conflictResolver.claim(
      p.join(targetDirPath, '$baseName.$ext'),
      conflictResolution,
    );
    if (resolved == null) return null;
    return IOFileSaverSink.open(resolved, totalSize: totalSize);
  }

  // MARK: Any directory

  /// Saves [input] as `baseName.ext` into the directory that [directory]
  /// returns. The input must be validated already; the file name is checked
  /// here, with [checkFileName].
  ///
  /// A [SaveFileInput] is copied by [copySource] when it is given, and read
  /// with `dart:io` otherwise.
  ///
  /// Emits [SaveProgressStarted], [SaveProgressUpdate]s and then
  /// [SaveProgressComplete] or [SaveProgressError]. Once the subscription is
  /// cancelled nothing more is emitted, and the cancel completes when the
  /// partial file has been deleted.
  Stream<SaveProgress> save({
    required SaveInput input,
    required Future<String> Function() directory,
    required String baseName,
    required String ext,
    required ConflictResolution conflictResolution,
    SourceCopier? copySource,
  }) {
    assert(copySource == null || input is SaveFileInput);
    checkFileName('$baseName.$ext');
    return singleSubscription((controller) {
      final cancellation = _Cancellation();

      void emit(SaveProgress event) {
        if (!cancellation.isCancelled) controller.addSync(event);
      }

      Future<void> run() async {
        try {
          if (input case SaveFileInput(
            :final filePath,
          ) when copySource == null) {
            final path = _sourcePath(filePath);
            if (!await File(path).exists()) {
              throw SourceFileNotFoundException(path);
            }
          }

          final path = p.join(await directory(), '$baseName.$ext');
          if (cancellation.isCancelled) return;
          final resolved = await _conflictResolver.claim(
            path,
            conflictResolution,
          );
          if (resolved == null) {
            emit(SaveProgressComplete(Uri.file(path)));
            return;
          }

          // Opened before the source, so a failed request deletes the file
          // the resolver claimed.
          final session = await IOWriteSession.open(resolved);
          try {
            if (input case SaveFileInput(
              :final filePath,
            ) when copySource != null) {
              await _copy(copySource, filePath, session, cancellation, emit);
            } else {
              final source = await _open(input, cancellation);
              if (!cancellation.isCancelled) {
                await _pipe(
                  source.data,
                  session,
                  cancellation,
                  (written) =>
                      emit(SaveProgressUpdate.bytes(written, source.length)),
                );
              } else {
                // Closes the connection of a download that won't be read.
                await source.data.listen(null).cancel();
              }
            }
            if (cancellation.isCancelled) {
              await session.cancel();
              return;
            }
            emit(SaveProgressComplete(await session.close()));
          } catch (_) {
            await session.cancel();
            rethrow;
          }
        } catch (e) {
          emit(SaveProgressError(mapIOException(e)));
        } finally {
          if (!controller.isClosed) controller.closeSync();
        }
      }

      controller.addSync(const SaveProgressStarted());
      final done = run();
      controller.onCancel = () {
        cancellation.cancel();
        return done;
      };
    });
  }

  // MARK: Private helpers

  /// Checks [subDir] with [checkSubDir] and returns a function that creates
  /// `dirPath/subDir`.
  static Future<String> Function() _directory(String dirPath, String? subDir) {
    checkSubDir(subDir);
    return () async {
      final path = subDir == null || subDir.isEmpty
          ? dirPath
          : p.join(dirPath, subDir);
      await Directory(path).create(recursive: true);
      return path;
    };
  }

  /// [filePath] as a path, decoding a `file://` URI.
  static String _sourcePath(String filePath) => filePath.startsWith('file://')
      ? Uri.parse(filePath).toFilePath()
      : filePath;

  /// Opens the bytes to save and their length, if known.
  Future<({Stream<List<int>> data, int? length})> _open(
    SaveInput input,
    _Cancellation cancellation,
  ) async {
    switch (input) {
      case SaveBytesInput(:final fileBytes):
        return (
          data: Stream.fromIterable([
            for (
              var offset = 0;
              offset < fileBytes.length;
              offset += _chunkSize
            )
              Uint8List.sublistView(
                fileBytes,
                offset,
                min(offset + _chunkSize, fileBytes.length),
              ),
          ]),
          length: fileBytes.length,
        );
      case SaveFileInput(:final filePath):
        final file = File(_sourcePath(filePath));
        return (data: file.openRead(), length: await file.length());
      case SaveNetworkInput(:final url, :final headers, :final timeout):
        return _request(url, headers, timeout, cancellation);
    }
  }

  /// Requests [url] with a client of its own, so [timeout] applies to this
  /// download only, and closes the client when the body has been read or the
  /// save is cancelled.
  ///
  /// [timeout] limits connecting, waiting for the response headers, and each
  /// wait for more of the body. Every failure is a [NetworkException].
  Future<({Stream<List<int>> data, int? length})> _request(
    String url,
    Map<String, String>? headers,
    Duration timeout,
    _Cancellation cancellation,
  ) async {
    final client = createHttpClient()..connectionTimeout = timeout;
    cancellation.onCancel = () => client.close(force: true);
    final HttpClientResponse response;
    try {
      final request = await client.getUrl(Uri.parse(url)).timeout(timeout);
      headers?.forEach(request.headers.set);
      response = await request.close().timeout(timeout);
    } catch (e) {
      client.close(force: true);
      throw e is TimeoutException
          ? NetworkException('No response within ${timeout.inSeconds}s')
          : NetworkException('Connection failed: $e');
    } finally {
      cancellation.onCancel = null;
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      client.close(force: true);
      throw NetworkException(
        'HTTP ${response.statusCode}',
        response.statusCode,
      );
    }

    final data = response
        .timeout(timeout)
        .handleError(
          (Object e) => throw e is TimeoutException
              ? NetworkException('No data received for ${timeout.inSeconds}s')
              : NetworkException('Download failed: $e'),
        );
    // HttpClient decodes a compressed body, but contentLength stays the
    // length of the encoded one.
    final encoding = response.headers.value(HttpHeaders.contentEncodingHeader);
    final compressed = encoding != null && encoding != 'identity';
    return (
      data: _onDone(data, () => client.close(force: true)),
      length: response.contentLength >= 0 && !compressed
          ? response.contentLength
          : null,
    );
  }

  /// [stream], calling [onDone] once it ends or its subscription is
  /// cancelled.
  static Stream<T> _onDone<T>(Stream<T> stream, void Function() onDone) {
    final controller = StreamController<T>(sync: true);
    controller.onListen = () {
      final subscription = stream.listen(
        controller.add,
        onError: controller.addError,
        onDone: () {
          onDone();
          unawaited(controller.close());
        },
      );
      controller
        ..onPause = subscription.pause
        ..onResume = subscription.resume
        ..onCancel = () {
          onDone();
          return subscription.cancel();
        };
    };
    return controller.stream;
  }

  /// Copies [source] into the file of [session] with [copySource], unless
  /// the save is cancelled already. Cancelling the save cancels the copy, and
  /// this completes once the copy has stopped.
  static Future<void> _copy(
    SourceCopier copySource,
    String source,
    IOWriteSession session,
    _Cancellation cancellation,
    void Function(SaveProgressUpdate update) onProgress,
  ) async {
    if (cancellation.isCancelled) return;
    final copy = copySource(source, session.path, onProgress);
    cancellation.onCancel = copy.cancel;
    try {
      await copy.done;
    } finally {
      cancellation.onCancel = null;
    }
  }

  /// Writes [source] to [session] one chunk at a time, pausing [source] while
  /// a chunk is written, and calls [onWritten] with the bytes written so far.
  ///
  /// Completes when [source] ends or [cancellation] is cancelled, and fails
  /// with the first error of [source] or of a write.
  static Future<void> _pipe(
    Stream<List<int>> source,
    IOWriteSession session,
    _Cancellation cancellation,
    void Function(int written) onWritten,
  ) {
    final done = Completer<void>();
    late final StreamSubscription<List<int>> subscription;

    void fail(Object e, StackTrace st) {
      if (done.isCompleted) return;
      unawaited(subscription.cancel());
      done.completeError(e, st);
    }

    subscription = source.listen(
      (chunk) => subscription.pause(
        session.write(chunk).then(onWritten, onError: fail),
      ),
      onError: fail,
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
      cancelOnError: true,
    );
    cancellation.onCancel = () {
      unawaited(subscription.cancel());
      if (!done.isCompleted) done.complete();
    };
    return done.future.whenComplete(() => cancellation.onCancel = null);
  }
}

/// Cancellation of one save. [onCancel] stops what the save is waiting for.
class _Cancellation {
  bool isCancelled = false;
  void Function()? onCancel;

  void cancel() {
    isCancelled = true;
    onCancel?.call();
  }
}
