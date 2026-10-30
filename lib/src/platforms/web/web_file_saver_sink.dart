import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart';

import '../../exceptions/file_saver_exceptions.dart';
import '../../models/file_saver_sink.dart';
import '../shared/session_file_saver_sink.dart';
import 'web_utils.dart';

/// Web implementation of [FileSaverSink].
///
/// Two modes:
/// - **FSA mode**: Uses [FileSystemWritableFileStream] for zero-RAM streaming
///   (Chrome/Edge 86+). Each chunk is written to disk before the next one.
/// - **Buffer mode**: Accumulates all bytes in memory, triggers an anchor
///   download on [close] (Firefox / Safari / browsers without FSA).
class WebFileSaverSink extends SessionFileSaverSink {
  /// Creates an FSA-backed sink that writes [name] in [directory] through
  /// [writable].
  ///
  /// Set [created] when [name] didn't exist before, so cancelling deletes it.
  /// An existing file keeps its content until [close], because the browser
  /// writes to a swap file.
  WebFileSaverSink.fsa({
    required FileSystemDirectoryHandle directory,
    required String name,
    required FileSystemWritableFileStream writable,
    required bool created,
    required int? totalSize,
  }) : super(_FsaWriteSession(directory, name, writable, created), totalSize);

  /// Creates an in-memory buffer sink that downloads [name] on [close].
  WebFileSaverSink.buffer({
    required String name,
    required String mimeType,
    required int? totalSize,
    void Function(Blob blob, String name) download =
        WebUtils.triggerBlobDownload,
  }) : super(_BufferWriteSession(name, mimeType, download), totalSize);
}

/// Converts a rejected File System Access call into a [FileSaverException].
///
/// Matches on the text, which names the `DOMException` under both dart2js
/// and dart2wasm.
FileSaverException _mapError(Object e) {
  if (e is FileSaverException) return e;
  final text = e.toString();
  if (text.contains('QuotaExceededError')) return const StorageFullException();
  if (text.contains('NotAllowedError') || text.contains('SecurityError')) {
    return PermissionDeniedException(text);
  }
  return FileIOException(text);
}

class _FsaWriteSession implements WriteSession {
  _FsaWriteSession(this._directory, this._name, this._writable, this._created);

  final FileSystemDirectoryHandle _directory;
  final String _name;
  final FileSystemWritableFileStream _writable;
  final bool _created;
  var _bytesWritten = 0;

  @override
  Future<int> write(List<int> data) async {
    // The write runs asynchronously, so it must not see later changes the
    // caller makes to its buffer.
    final bytes = Uint8List.fromList(data);
    try {
      await _writable.write(bytes.toJS as FileSystemWriteChunkType).toDart;
    } catch (e) {
      throw _mapError(e);
    }
    return _bytesWritten += bytes.length;
  }

  /// FSA has no flush: written chunks are already in the swap file.
  @override
  Future<void> flush() async {}

  @override
  Future<Uri> close() async {
    try {
      await _writable.close().toDart;
    } catch (e) {
      await cancel();
      throw _mapError(e);
    }
    return Uri(scheme: 'web-directory', path: _name);
  }

  @override
  Future<void> cancel() async {
    try {
      await _writable.abort().toDart;
    } catch (_) {}
    if (_created) {
      try {
        await _directory.removeEntry(_name).toDart;
      } catch (_) {}
    }
  }
}

class _BufferWriteSession implements WriteSession {
  _BufferWriteSession(this._name, this._mimeType, this._download);

  final String _name;
  final String _mimeType;
  final void Function(Blob blob, String name) _download;

  /// The chunks so far, joined into a [Blob] on close.
  final _chunks = <JSUint8Array>[];
  var _bytesWritten = 0;

  @override
  Future<int> write(List<int> data) async {
    _chunks.add(Uint8List.fromList(data).toJS);
    return _bytesWritten += data.length;
  }

  @override
  Future<void> flush() async {}

  @override
  Future<Uri> close() async {
    final blob = Blob(_chunks.toJS, BlobPropertyBag(type: _mimeType));
    _chunks.clear();
    _download(blob, _name);
    return Uri(scheme: 'browser-download', path: _name);
  }

  @override
  Future<void> cancel() async => _chunks.clear();
}
