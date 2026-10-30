@TestOn('browser')
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:file_saver_ffi/file_saver_ffi.dart';
import 'package:file_saver_ffi/src/models/locations/web_save_location.dart';
import 'package:file_saver_ffi/src/platforms/web/web_file_saver_sink.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web/web.dart';

/// The web write sessions. FSA mode runs against the origin private file
/// system, which gives a [FileSystemDirectoryHandle] without a picker.
void main() {
  late FileSystemDirectoryHandle directory;
  const text = CustomFileType(ext: 'txt', mimeType: 'text/plain');

  setUp(() async {
    final root = await window.navigator.storage.getDirectory().toDart;
    final name = 'sink_test_${DateTime.now().microsecondsSinceEpoch}';
    directory = await root
        .getDirectoryHandle(name, FileSystemGetDirectoryOptions(create: true))
        .toDart;
  });

  Future<FileSaverSink> openFsa({
    ConflictResolution conflictResolution = ConflictResolution.overwrite,
  }) async => (await FileSaverWeb().openWriteAs(
    fileName: 'log',
    fileType: text,
    saveLocation: WebPickedDirectoryLocation(directory),
    conflictResolution: conflictResolution,
  ))!;

  Future<String?> contentOf(String name) async {
    try {
      final handle = await directory.getFileHandle(name).toDart;
      final file = await handle.getFile().toDart;
      return (await file.text().toDart).toDart;
    } catch (_) {
      return null;
    }
  }

  Future<void> writeFile(String name, String content) async {
    final handle = await directory
        .getFileHandle(name, FileSystemGetFileOptions(create: true))
        .toDart;
    final writable = await handle.createWritable().toDart;
    await writable.write(content.toJS as FileSystemWriteChunkType).toDart;
    await writable.close().toDart;
  }

  Stream<List<int>> slowChunks(List<String> chunks) async* {
    for (final chunk in chunks) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      yield chunk.codeUnits;
    }
  }

  group('FSA', () {
    test('writes the chunks and completes with the file name', () async {
      final sink = await openFsa();
      sink.add('ab'.codeUnits);
      await sink.addStream(slowChunks(['c', 'd']));
      await sink.close();

      expect(await sink.result, Uri(scheme: 'web-directory', path: 'log.txt'));
      expect(await contentOf('log.txt'), 'abcd');
    });

    test('cancel deletes a file it created', () async {
      final sink = await openFsa();
      sink.add('partial'.codeUnits);
      await sink.flush();

      await sink.cancel();

      expect(await contentOf('log.txt'), isNull);
    });

    test('cancel keeps a file it would overwrite', () async {
      await writeFile('log.txt', 'original');
      final sink = await openFsa();
      sink.add('new'.codeUnits);
      await sink.flush();

      await sink.cancel();

      expect(await contentOf('log.txt'), 'original');
    });

    test('close while addStream runs throws StateError instead of waiting '
        'forever', () async {
      final sink = await openFsa();
      final adding = sink.addStream(slowChunks(['a', 'b', 'c']));

      expect(() => sink.close(), throwsStateError);

      await adding;
      await sink.close();
      expect(await contentOf('log.txt'), 'abc');
    });
  });

  group('buffer', () {
    test('downloads one Blob of every chunk on close', () async {
      Blob? downloaded;
      String? downloadedName;
      final sink = WebFileSaverSink.buffer(
        name: 'log.txt',
        mimeType: 'text/plain',
        totalSize: null,
        download: (blob, name) {
          downloaded = blob;
          downloadedName = name;
        },
      );
      final buffer = Uint8List.fromList('ab'.codeUnits);
      sink.add(buffer);
      buffer.setAll(0, 'xy'.codeUnits);
      sink.add(buffer);
      await sink.close();

      expect(downloadedName, 'log.txt');
      expect(downloaded!.type, 'text/plain');
      expect((await downloaded!.text().toDart).toDart, 'abxy');
      expect(
        await sink.result,
        Uri(scheme: 'browser-download', path: 'log.txt'),
      );
    });

    test('cancel downloads nothing', () async {
      var downloads = 0;
      final sink = WebFileSaverSink.buffer(
        name: 'log.txt',
        mimeType: 'text/plain',
        totalSize: null,
        download: (_, _) => downloads++,
      );
      sink.add('ab'.codeUnits);

      await sink.cancel();

      expect(downloads, 0);
      await expectLater(sink.result, throwsA(isA<CancelledException>()));
    });
  });
}
