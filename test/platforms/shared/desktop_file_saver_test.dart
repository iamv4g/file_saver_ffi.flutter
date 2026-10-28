@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_saver_ffi/file_saver_ffi.dart';
import 'package:file_saver_ffi/src/platforms/shared/desktop_file_saver.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../helpers/test_http_server.dart';

/// Resolves every [SaveLocation] to a temporary directory so the shared
/// Windows/Linux logic can run on any host.
class _TestDesktopFileSaver extends DesktopFileSaver {
  _TestDesktopFileSaver(this.baseDir);

  final String baseDir;

  /// Paths passed to [launchFile], in call order.
  final launchedPaths = <String>[];

  /// Thrown by [launchFile] when set.
  Object? launchError;

  @override
  Future<void> launchFile(String path) async {
    launchedPaths.add(path);
    if (launchError case final error?) throw error;
  }

  @override
  Future<String> resolveDirectory(
    SaveLocation? saveLocation,
    String? subDir,
  ) async {
    final dir = subDir != null ? p.join(baseDir, subDir) : baseDir;
    await Directory(dir).create(recursive: true);
    return dir;
  }
}

/// Polls [condition] until it holds or [timeout] passes.
Future<void> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

T _last<T>(List<SaveProgress> events) {
  expect(events.last, isA<T>(), reason: '$events');
  return events.last as T;
}

void main() {
  // Larger than the 1 MiB write chunk so progress is reported in steps.
  final bytes = Uint8List.fromList(
    List.generate(2 * 1024 * 1024 + 512 * 1024, (i) => i % 251),
  );
  const fileType = CustomFileType(
    ext: 'bin',
    mimeType: 'application/octet-stream',
  );

  late Directory tmp;
  late _TestDesktopFileSaver saver;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('desktop_file_saver_test');
    saver = _TestDesktopFileSaver(tmp.path);
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  String inTmp(String relative) => p.join(tmp.path, relative);

  group('saveBytes', () {
    test('writes in chunks and reports progress', () async {
      final events = await saver
          .saveBytes(fileBytes: bytes, fileName: 'data', fileType: fileType)
          .toList();

      expect(events.first, isA<SaveProgressStarted>());
      expect(events.whereType<SaveProgressUpdate>().map((e) => e.progress), [
        0.4,
        0.8,
        1.0,
      ]);
      final uri = _last<SaveProgressComplete>(events).uri;
      expect(p.equals(uri.toFilePath(), inTmp('data.bin')), isTrue);
      expect(await File.fromUri(uri).readAsBytes(), bytes);
    });

    test('honours subDir', () async {
      final events = await saver
          .saveBytes(
            fileBytes: bytes,
            fileName: 'data',
            fileType: fileType,
            subDir: 'album',
          )
          .toList();
      final uri = _last<SaveProgressComplete>(events).uri;
      expect(p.equals(uri.toFilePath(), inTmp('album/data.bin')), isTrue);
    });

    test('throws synchronously on invalid input', () {
      expect(
        () => saver.saveBytes(
          fileBytes: Uint8List(0),
          fileName: 'data',
          fileType: fileType,
        ),
        throwsA(isA<InvalidInputException>()),
      );
      expect(
        () =>
            saver.saveBytes(fileBytes: bytes, fileName: '', fileType: fileType),
        throwsA(isA<InvalidInputException>()),
      );
    });

    group('conflict resolution', () {
      setUp(() async {
        await File(inTmp('data.bin')).writeAsString('old');
      });

      Future<List<SaveProgress>> save(ConflictResolution mode) => saver
          .saveBytes(
            fileBytes: bytes,
            fileName: 'data',
            fileType: fileType,
            conflictResolution: mode,
          )
          .toList();

      test('autoRename', () async {
        final uri = _last<SaveProgressComplete>(
          await save(ConflictResolution.autoRename),
        ).uri;
        expect(p.basename(uri.toFilePath()), 'data (1).bin');
        expect(await File(inTmp('data.bin')).readAsString(), 'old');
      });

      test('overwrite', () async {
        await save(ConflictResolution.overwrite);
        expect(await File(inTmp('data.bin')).readAsBytes(), bytes);
      });

      test('skip', () async {
        final uri = _last<SaveProgressComplete>(
          await save(ConflictResolution.skip),
        ).uri;
        expect(p.equals(uri.toFilePath(), inTmp('data.bin')), isTrue);
        expect(await File(inTmp('data.bin')).readAsString(), 'old');
      });

      test('fail emits FileExistsException', () async {
        final error = _last<SaveProgressError>(
          await save(ConflictResolution.fail),
        );
        expect(error.exception, isA<FileExistsException>());
      });
    });
  });

  group('saveFile', () {
    test('copies from a path or file:// URI', () async {
      final source = File(inTmp('source.bin'));
      await source.writeAsBytes(bytes);

      for (final filePath in [source.path, source.uri.toString()]) {
        final events = await saver
            .saveFile(filePath: filePath, fileName: 'copy', fileType: fileType)
            .toList();
        final uri = _last<SaveProgressComplete>(events).uri;
        expect(await File.fromUri(uri).readAsBytes(), bytes);
        expect(events.whereType<SaveProgressUpdate>().last.progress, 1.0);
      }
    });

    test('missing source emits SourceFileNotFoundException', () async {
      final events = await saver
          .saveFile(
            filePath: inTmp('missing.bin'),
            fileName: 'copy',
            fileType: fileType,
          )
          .toList();
      expect(
        _last<SaveProgressError>(events).exception,
        isA<SourceFileNotFoundException>(),
      );
    });
  });

  group('saveNetwork', () {
    late TestHttpServer server;

    setUp(() async {
      server = await TestHttpServer.start(bytes);
    });

    tearDown(() => server.close());

    Stream<SaveProgress> download(String path, {Map<String, String>? headers}) {
      return saver.saveNetwork(
        url: server.url(path),
        headers: headers,
        fileName: 'download',
        fileType: fileType,
        timeout: const Duration(seconds: 5),
      );
    }

    test('downloads the payload with progress', () async {
      final events = await download('/file').toList();
      final uri = _last<SaveProgressComplete>(events).uri;
      expect(await File.fromUri(uri).readAsBytes(), bytes);
      expect(events.whereType<SaveProgressUpdate>().last.progress, 1.0);
    });

    test('sends custom headers', () async {
      final events = await download(
        '/auth',
        headers: {'X-Token': 'secret'},
      ).toList();
      expect(events.last, isA<SaveProgressComplete>());
    });

    test('HTTP error emits NetworkException and leaves no file', () async {
      final events = await download('/404').toList();
      final exception = _last<SaveProgressError>(events).exception;
      expect(exception, isA<NetworkException>());
      expect((exception as NetworkException).statusCode, 404);
      expect(File(inTmp('download.bin')).existsSync(), isFalse);
    });

    test('rejects non-http URLs synchronously', () {
      expect(
        () => saver.saveNetwork(
          url: 'ftp://example.com/a.bin',
          fileName: 'a',
          fileType: fileType,
        ),
        throwsA(isA<InvalidInputException>()),
      );
    });

    test('stalled download times out with NetworkException', () async {
      final events = await saver
          .saveNetwork(
            url: server.url('/slow'),
            fileName: 'download',
            fileType: fileType,
            timeout: const Duration(seconds: 1),
          )
          .toList()
          .timeout(const Duration(seconds: 10));

      expect(
        _last<SaveProgressError>(events).exception,
        isA<NetworkException>(),
      );
      expect(File(inTmp('download.bin')).existsSync(), isFalse);
    });

    test('cancelling the subscription deletes the partial file', () async {
      final firstChunk = Completer<void>();
      final subscription = download('/slow').listen((event) {
        if (event is SaveProgressUpdate && !firstChunk.isCompleted) {
          firstChunk.complete();
        }
      });

      await firstChunk.future.timeout(const Duration(seconds: 5));

      // IOSink creates the file asynchronously, so it can appear after the
      // first progress event on a slow runner.
      final partial = File(inTmp('download.bin'));
      await _waitUntil(partial.existsSync);
      expect(partial.existsSync(), isTrue);

      await subscription.cancel();

      await _waitUntil(() => !partial.existsSync());
      expect(partial.existsSync(), isFalse);
    });
  });

  group('saveAs', () {
    test('writes into the picked directory', () async {
      final picked = Directory(inTmp('picked'))..createSync();
      final events = await saver
          .saveAs(
            input: SaveInput.bytes(bytes),
            fileType: fileType,
            fileName: 'picked',
            saveLocation: PickedDirectoryLocation(uri: picked.uri),
          )
          .toList();
      final uri = _last<SaveProgressComplete>(events).uri;
      expect(
        p.equals(uri.toFilePath(), p.join(picked.path, 'picked.bin')),
        isTrue,
      );
    });
  });

  group('openWrite', () {
    test('streams chunks to disk', () async {
      final sink = await saver.openWrite(
        fileName: 'stream',
        fileType: fileType,
        totalSize: bytes.length,
      );
      await sink!.addStream(Stream.fromIterable([bytes]));
      await sink.close();

      final uri = await sink.result;
      expect(await File.fromUri(uri).readAsBytes(), bytes);
    });

    test('cancel deletes the file and fails result', () async {
      final sink = await saver.openWrite(
        fileName: 'stream',
        fileType: fileType,
      );
      sink!.add(bytes);
      await sink.cancel();

      expect(File(inTmp('stream.bin')).existsSync(), isFalse);
      await expectLater(sink.result, throwsA(isA<CancelledException>()));
      expect(() => sink.add(bytes), throwsStateError);
    });
  });

  group('canOpenFile', () {
    test('true only for existing file:// URIs', () async {
      final file = File(inTmp('exists.txt'))..writeAsStringSync('x');
      expect(await saver.canOpenFile(file.uri), isTrue);
      expect(await saver.canOpenFile(File(inTmp('nope')).uri), isFalse);
      expect(
        await saver.canOpenFile(Uri.parse('https://example.com/a')),
        isFalse,
      );
    });
  });

  group('openFile', () {
    test('passes the path unchanged, including shell metacharacters', () async {
      // Windows forbids `|`, `<` and `>` in file names; `&`, `^`, `%` and `!`
      // are allowed and are special to cmd.exe.
      final file = File(inTmp('a&calc&b ^%PATH%! (1).txt'))
        ..writeAsStringSync('x');

      await saver.openFile(file.uri);

      expect(saver.launchedPaths, [file.path]);
    });

    test('rejects non-file URIs without launching', () async {
      await expectLater(
        saver.openFile(Uri.parse('https://example.com/a.pdf')),
        throwsA(isA<InvalidInputException>()),
      );
      expect(saver.launchedPaths, isEmpty);
    });

    test('throws SourceFileNotFoundException for a missing file', () async {
      await expectLater(
        saver.openFile(File(inTmp('missing.txt')).uri),
        throwsA(isA<SourceFileNotFoundException>()),
      );
      expect(saver.launchedPaths, isEmpty);
    });

    test('wraps launcher errors in OpenFailedException', () async {
      final file = File(inTmp('doc.txt'))..writeAsStringSync('x');
      saver.launchError = const ProcessException('xdg-open', [], 'not found');

      await expectLater(
        saver.openFile(file.uri),
        throwsA(isA<OpenFailedException>()),
      );
    });
  });
}
