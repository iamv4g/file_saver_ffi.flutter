@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:file_saver_ffi/file_saver_ffi.dart';
import 'package:file_saver_ffi/src/platforms/shared/path_location_writer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// The `dart:io` write session behind `openWrite` on Windows, Linux and
/// `PathLocation`, driven through [PathLocationWriter.openWrite].
void main() {
  late Directory tmp;
  late String target;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('io_file_saver_sink_test');
    target = p.join(tmp.path, 'log.txt');
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  Future<FileSaverSink> open({
    ConflictResolution conflictResolution = ConflictResolution.overwrite,
  }) async => (await PathLocationWriter.openWrite(
    dirPath: tmp.path,
    baseName: 'log',
    ext: 'txt',
    conflictResolution: conflictResolution,
  ))!;

  Stream<List<int>> slowChunks(List<String> chunks) async* {
    for (final chunk in chunks) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      yield chunk.codeUnits;
    }
  }

  List<String> entries() =>
      tmp.listSync().map((e) => p.basename(e.path)).toList()..sort();

  group('overwrite', () {
    test('keeps the original while writing and replaces it on close', () async {
      await File(target).writeAsString('original');
      final sink = await open();

      sink.add('new '.codeUnits);
      await sink.flush();
      expect(await File(target).readAsString(), 'original');

      sink.add('content'.codeUnits);
      await sink.close();

      expect(await File(target).readAsString(), 'new content');
      expect(entries(), ['log.txt'], reason: 'no temporary file is left');
    });

    test('cancel keeps the original', () async {
      await File(target).writeAsString('original');
      final sink = await open();
      sink.add('new'.codeUnits);
      await sink.flush();

      await sink.cancel();

      expect(await File(target).readAsString(), 'original');
      expect(entries(), ['log.txt']);
    });

    test('a failed close deletes the temporary file and throws', () async {
      await File(target).writeAsString('original');
      final sink = await open();
      sink.add('new'.codeUnits);
      await sink.flush();
      // The temporary file can't replace a directory.
      await File(target).delete();
      await Directory(target).create();

      await expectLater(sink.close(), throwsA(isA<FileSaverException>()));
      await expectLater(sink.result, throwsA(isA<FileSaverException>()));
      expect(entries(), ['log.txt']);
      expect(FileSystemEntity.isDirectorySync(target), isTrue);
    });
  });

  test('cancel deletes a new file', () async {
    final sink = await open(conflictResolution: ConflictResolution.autoRename);
    sink.add('partial'.codeUnits);
    await sink.flush();
    expect(File(target).existsSync(), isTrue);

    await sink.cancel();

    expect(entries(), isEmpty);
  });

  test('close while addStream runs throws StateError instead of waiting '
      'forever', () async {
    final sink = await open();
    final adding = sink.addStream(slowChunks(['a', 'b', 'c']));

    expect(() => sink.close(), throwsStateError);

    await adding;
    await sink.close();
    expect(await File(target).readAsString(), 'abc');
  });

  test('addStream waits for each chunk to be written', () async {
    final sink = await open();
    final written = <int>[];
    sink.bytesWritten.listen(written.add);

    await sink.addStream(slowChunks(['ab', 'cde']));

    expect(written, [2, 5]);
    expect(await File(target).length(), 5);
    await sink.close();
  });
}
