@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_saver_ffi/file_saver_ffi.dart';
import 'package:file_saver_ffi/src/platforms/shared/path_location_writer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../helpers/test_http_server.dart';

void main() {
  final bytes = Uint8List.fromList(List.generate(1000, (i) => i % 256));
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('path_location_writer_test');
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  Stream<SaveProgress> saveBytes({
    String? subDir,
    ConflictResolution conflictResolution = ConflictResolution.autoRename,
  }) {
    return PathLocationWriter.saveBytes(
      fileBytes: bytes,
      dirPath: tmp.path,
      subDir: subDir,
      baseName: 'data',
      ext: 'bin',
      conflictResolution: conflictResolution,
    );
  }

  group('saveBytes', () {
    test('emits Started, Update(1.0), Complete and writes the file', () async {
      final events = await saveBytes().toList();

      expect(events, hasLength(3));
      expect(events[0], isA<SaveProgressStarted>());
      expect((events[1] as SaveProgressUpdate).progress, 1.0);
      final uri = (events[2] as SaveProgressComplete).uri;
      expect(p.equals(uri.toFilePath(), p.join(tmp.path, 'data.bin')), isTrue);
      expect(await File.fromUri(uri).readAsBytes(), bytes);
    });

    test('creates subDir', () async {
      final events = await saveBytes(subDir: 'nested/dir').toList();
      final uri = (events.last as SaveProgressComplete).uri;
      expect(
        p.equals(uri.toFilePath(), p.join(tmp.path, 'nested/dir/data.bin')),
        isTrue,
      );
    });

    test('autoRename on conflict', () async {
      await saveBytes().drain<void>();
      final events = await saveBytes().toList();
      final uri = (events.last as SaveProgressComplete).uri;
      expect(p.basename(uri.toFilePath()), 'data (1).bin');
    });

    test('skip returns the existing file untouched', () async {
      final existing = File(p.join(tmp.path, 'data.bin'));
      await existing.writeAsString('old');

      final events = await saveBytes(
        conflictResolution: ConflictResolution.skip,
      ).toList();

      expect(events.last, isA<SaveProgressComplete>());
      expect(await existing.readAsString(), 'old');
    });

    test('fail emits FileExistsException', () async {
      await saveBytes().drain<void>();
      final events = await saveBytes(
        conflictResolution: ConflictResolution.fail,
      ).toList();
      expect(
        (events.last as SaveProgressError).exception,
        isA<FileExistsException>(),
      );
    });
  });

  group('saveFile', () {
    test('copies the source file', () async {
      final source = File(p.join(tmp.path, 'source.bin'));
      await source.writeAsBytes(bytes);

      final events = await PathLocationWriter.saveFile(
        filePath: source.path,
        dirPath: tmp.path,
        subDir: 'out',
        baseName: 'copy',
        ext: 'bin',
        conflictResolution: ConflictResolution.autoRename,
      ).toList();

      final uri = (events.last as SaveProgressComplete).uri;
      expect(await File.fromUri(uri).readAsBytes(), bytes);
    });

    test('copies from a file:// URI', () async {
      final source = File(p.join(tmp.path, 'a#1 50%.bin'));
      await source.writeAsBytes(bytes);

      final events = await PathLocationWriter.saveFile(
        filePath: source.uri.toString(),
        dirPath: tmp.path,
        subDir: 'out',
        baseName: 'copy',
        ext: 'bin',
        conflictResolution: ConflictResolution.autoRename,
      ).toList();

      final uri = (events.last as SaveProgressComplete).uri;
      expect(await File.fromUri(uri).readAsBytes(), bytes);
    });

    test('cancelling stops the copy and deletes the partial file', () async {
      final source = File(p.join(tmp.path, 'large.bin'));
      await source.writeAsBytes(Uint8List(32 * 1024 * 1024));
      final target = File(p.join(tmp.path, 'out', 'copy.bin'));

      final firstUpdate = Completer<void>();
      final events = <SaveProgress>[];
      final subscription =
          PathLocationWriter.saveFile(
            filePath: source.path,
            dirPath: tmp.path,
            subDir: 'out',
            baseName: 'copy',
            ext: 'bin',
            conflictResolution: ConflictResolution.autoRename,
          ).listen((event) {
            events.add(event);
            if (event is SaveProgressUpdate && !firstUpdate.isCompleted) {
              firstUpdate.complete();
            }
          });
      await firstUpdate.future;
      expect(target.existsSync(), isTrue);

      // The cancel completes once the partial file is deleted.
      await subscription.cancel();
      expect(target.existsSync(), isFalse);
      expect(events.whereType<SaveProgressUpdate>().last.progress, lessThan(1));
      expect(events.whereType<SaveProgressComplete>(), isEmpty);
    });

    test('missing source emits SourceFileNotFoundException', () async {
      final events = await PathLocationWriter.saveFile(
        filePath: p.join(tmp.path, 'missing.bin'),
        dirPath: tmp.path,
        baseName: 'copy',
        ext: 'bin',
        conflictResolution: ConflictResolution.autoRename,
      ).toList();

      expect(
        (events.last as SaveProgressError).exception,
        isA<SourceFileNotFoundException>(),
      );
    });
  });

  group('saveNetwork', () {
    // More than the 64 KiB that `/slow` sends before it stalls.
    final payload = Uint8List.fromList(
      List.generate(256 * 1024, (i) => i % 251),
    );
    late TestHttpServer server;

    setUp(() async {
      server = await TestHttpServer.start(payload);
    });

    tearDown(() => server.close());

    Stream<SaveProgress> download(
      String path, {
      Map<String, String>? headers,
      Duration timeout = const Duration(seconds: 5),
      ConflictResolution conflictResolution = ConflictResolution.autoRename,
    }) {
      return PathLocationWriter.saveNetwork(
        url: server.url(path),
        headers: headers,
        timeout: timeout,
        dirPath: tmp.path,
        baseName: 'download',
        ext: 'bin',
        conflictResolution: conflictResolution,
      );
    }

    File target() => File(p.join(tmp.path, 'download.bin'));

    /// Listens to [stream] until its first progress event.
    Future<StreamSubscription<SaveProgress>> listenUntilProgress(
      Stream<SaveProgress> stream,
    ) async {
      final firstUpdate = Completer<void>();
      final subscription = stream.listen((event) {
        if (event is SaveProgressUpdate && !firstUpdate.isCompleted) {
          firstUpdate.complete();
        }
      });
      await firstUpdate.future.timeout(const Duration(seconds: 5));
      return subscription;
    }

    test(
      'cancelling deletes the partial file before the cancel completes',
      () async {
        final subscription = await listenUntilProgress(download('/slow'));
        expect(target().existsSync(), isTrue);

        await subscription.cancel();
        expect(target().existsSync(), isFalse);
      },
    );

    test('a cancelled overwrite keeps the original file', () async {
      await target().writeAsString('original');
      final subscription = await listenUntilProgress(
        download('/slow', conflictResolution: ConflictResolution.overwrite),
      );

      await subscription.cancel();
      expect(await target().readAsString(), 'original');
      expect(tmp.listSync().map((e) => p.basename(e.path)), ['download.bin']);
    });

    test(
      'a server that sends no response times out with NetworkException',
      () async {
        final events = await download(
          '/no-headers',
          timeout: const Duration(seconds: 1),
        ).toList().timeout(const Duration(seconds: 10));

        expect(
          (events.last as SaveProgressError).exception,
          isA<NetworkException>(),
        );
        expect(target().existsSync(), isFalse);
      },
    );

    test('a stalled body times out with NetworkException', () async {
      final events = await download(
        '/slow',
        timeout: const Duration(seconds: 1),
      ).toList().timeout(const Duration(seconds: 10));

      expect(
        (events.last as SaveProgressError).exception,
        isA<NetworkException>(),
      );
      expect(target().existsSync(), isFalse);
    });

    test('a refused connection emits NetworkException', () async {
      final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = closed.port;
      await closed.close();

      final events = await PathLocationWriter.saveNetwork(
        url: 'http://127.0.0.1:$port/file',
        headers: null,
        timeout: const Duration(seconds: 5),
        dirPath: tmp.path,
        baseName: 'download',
        ext: 'bin',
        conflictResolution: ConflictResolution.autoRename,
      ).toList();

      expect(
        (events.last as SaveProgressError).exception,
        isA<NetworkException>(),
      );
    });

    test('downloads with increasing progress', () async {
      final events = await download('/file').toList();

      expect(events.first, isA<SaveProgressStarted>());
      final progress = events
          .whereType<SaveProgressUpdate>()
          .map((e) => e.progress)
          .toList();
      expect(progress, isNotEmpty);
      expect(progress.last, 1.0);
      for (var i = 1; i < progress.length; i++) {
        expect(progress[i], greaterThanOrEqualTo(progress[i - 1]));
      }
      final uri = (events.last as SaveProgressComplete).uri;
      expect(await File.fromUri(uri).readAsBytes(), payload);
    });

    test('forwards headers', () async {
      final events = await download(
        '/auth',
        headers: {'X-Token': 'secret'},
      ).toList();
      expect(events.last, isA<SaveProgressComplete>());
    });

    test('non-2xx emits NetworkException with status code', () async {
      final events = await download('/404').toList();
      final exception = (events.last as SaveProgressError).exception;
      expect(exception, isA<NetworkException>());
      expect((exception as NetworkException).statusCode, 404);
      expect(File(p.join(tmp.path, 'download.bin')).existsSync(), isFalse);
    });
  });

  group('openWrite', () {
    test('writes chunks and returns the file URI on close', () async {
      final sink = await PathLocationWriter.openWrite(
        dirPath: tmp.path,
        baseName: 'stream',
        ext: 'bin',
        conflictResolution: ConflictResolution.autoRename,
        totalSize: bytes.length,
      );
      final progress = <double>[];
      sink!.progress.listen(progress.add);

      sink.add(bytes.sublist(0, 500));
      sink.add(bytes.sublist(500));
      await sink.close();

      final uri = await sink.result;
      expect(await File.fromUri(uri).readAsBytes(), bytes);
      expect(progress, [0.5, 1.0]);
    });

    test('returns null for skip when the file exists', () async {
      await File(p.join(tmp.path, 'stream.bin')).writeAsString('old');
      final sink = await PathLocationWriter.openWrite(
        dirPath: tmp.path,
        baseName: 'stream',
        ext: 'bin',
        conflictResolution: ConflictResolution.skip,
      );
      expect(sink, isNull);
    });
  });
}
