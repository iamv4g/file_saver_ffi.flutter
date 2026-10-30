import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../../exceptions/file_saver_exceptions.dart';
import '../../models/file_saver_sink.dart';
import 'session_file_saver_sink.dart';

/// [FileSaverSink] that writes a file with `dart:io`: on Windows and Linux,
/// and for `PathLocation` on every IO platform.
class IOFileSaverSink extends SessionFileSaverSink {
  IOFileSaverSink._(super.session, super.totalSize);

  /// Opens a sink that writes the file at [path].
  ///
  /// If [path] exists (`overwrite`), the chunks go to a temporary file next
  /// to it, which replaces it on close. Cancelling or a failed write keeps
  /// the original.
  static Future<IOFileSaverSink> open(String path, {int? totalSize}) async =>
      IOFileSaverSink._(await _IOWriteSession.open(path), totalSize);
}

/// Converts an error from `dart:io` into a [FileSaverException].
FileSaverException mapIOException(Object e) {
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

/// A write session on a [RandomAccessFile]. Operations run one at a time, in
/// the order they are called, because a [RandomAccessFile] rejects a call
/// while another is pending.
class _IOWriteSession implements WriteSession {
  _IOWriteSession(this._target, this._writePath, this._file);

  static Future<_IOWriteSession> open(String target) async {
    final writePath = await File(target).exists()
        ? p.join(
            p.dirname(target),
            '.${p.basename(target)}.${DateTime.now().microsecondsSinceEpoch}.part',
          )
        : target;
    try {
      final file = await File(writePath).open(mode: FileMode.writeOnly);
      return _IOWriteSession(target, writePath, file);
    } catch (e) {
      throw mapIOException(e);
    }
  }

  /// The file to save.
  final String _target;

  /// [_target], or the temporary file that replaces it on close.
  final String _writePath;
  final RandomAccessFile _file;
  var _bytesWritten = 0;

  /// Completes when the last operation has ended.
  Future<void> _last = Future.value();

  @override
  Future<int> write(List<int> data) {
    // The write may start after the caller reused its buffer.
    final bytes = Uint8List.fromList(data);
    return _run(() async {
      await _file.writeFrom(bytes);
      return _bytesWritten += bytes.length;
    });
  }

  @override
  Future<void> flush() => _run(() => _file.flush());

  @override
  Future<Uri> close() => _run(() async {
    try {
      await _file.close();
      if (_writePath != _target) await File(_writePath).rename(_target);
      return Uri.file(_target);
    } catch (_) {
      await _discard();
      rethrow;
    }
  });

  @override
  Future<void> cancel() => _run(_discard).catchError((_) {});

  /// Closes and deletes the file being written, ignoring errors.
  Future<void> _discard() async {
    try {
      await _file.close();
    } catch (_) {}
    try {
      await File(_writePath).delete();
    } catch (_) {}
  }

  /// Runs [operation] after the previous ones, mapping its errors with
  /// [mapIOException].
  Future<T> _run<T>(Future<T> Function() operation) {
    final result = _last.then((_) => operation());
    _last = result.then<void>((_) {}, onError: (_) {});
    return result.catchError(
      (Object e, StackTrace st) => Future<T>.error(mapIOException(e), st),
    );
  }
}
