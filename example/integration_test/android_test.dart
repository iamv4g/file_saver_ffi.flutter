// On-device tests of the Android JNI bridge, which `flutter test` can't load
// (Android only).
// Run from example/ with a device attached:
//   flutter test integration_test/android_test.dart -d <device-id>
// They save to Download/fsf_it/<run>/; remove it afterwards with
//   adb shell content delete --uri content://media/external/file \
//     --where "\"_data LIKE '%/Download/fsf_it/%'\""
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_saver_ffi/file_saver_ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

// `flutter test` uninstalls the app afterwards, and files of an uninstalled
// app are invisible to the next install, so `overwrite` and `skip` could not
// find them. Each run therefore uses its own directory.
final _subDir = 'fsf_it/${DateTime.now().millisecondsSinceEpoch}';
const _text = CustomFileType(ext: 'txt', mimeType: 'text/plain');

Future<Uri> _saveText(String name, String content) => FileSaver.saveAsync(
  input: SaveInput.bytes(Uint8List.fromList(content.codeUnits)),
  fileType: _text,
  fileName: name,
  saveLocation: AndroidSaveLocation.downloads,
  subDir: _subDir,
  conflictResolution: ConflictResolution.overwrite,
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('repeated large saveBytes calls do not exhaust the Java heap', (
    _,
  ) async {
    // 16 × 32 MB is twice the 256 MB heap limit of a typical app. The Java
    // copies of the bytes must be released after each call: a Dart GC, which
    // doesn't see Java heap pressure, may not run in between.
    final bytes = Uint8List(32 * 1024 * 1024);
    for (var i = 0; i < 16; i++) {
      await FileSaver.saveAsync(
        input: SaveInput.bytes(bytes),
        fileType: const CustomFileType(
          ext: 'bin',
          mimeType: 'application/octet-stream',
        ),
        fileName: 'large',
        saveLocation: AndroidSaveLocation.downloads,
        subDir: _subDir,
        conflictResolution: ConflictResolution.overwrite,
      );
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets('canOpenFile is true for a saved file and false once deleted', (
    _,
  ) async {
    final uri = await _saveText('can_open', 'hello');
    expect(await FileSaver.canOpenFile(uri), isTrue);
    expect(await FileSaver.canOpenFile(Uri.parse('$uri-missing')), isFalse);
  });

  testWidgets('openFile of a missing file throws SourceFileNotFoundException', (
    _,
  ) async {
    final uri = await _saveText('missing', 'x');
    final missing = uri.replace(
      pathSegments: [
        ...uri.pathSegments.take(uri.pathSegments.length - 1),
        '999999999',
      ],
    );

    await expectLater(
      FileSaver.openFile(missing),
      throwsA(isA<SourceFileNotFoundException>()),
    );
  });

  testWidgets('openFile of a file URI without a FileProvider throws '
      'OpenFailedException that explains the setup', (_) async {
    final error = await FileSaver.openFile(
      Uri.file('/system/etc/hosts'),
    ).then<Object?>((_) => null, onError: (Object e) => e);

    expect(error, isA<OpenFailedException>());
    expect((error! as OpenFailedException).message, contains('FileProvider'));
  });

  // PathLocation with a content:// source, which dart:io can't read: Kotlin
  // copies it into the file the Dart side claimed.
  group('saveFile of a content:// URI to a PathLocation', () {
    late Directory dir;

    setUp(() async {
      dir = await (await getTemporaryDirectory()).createTemp('fsf_it');
    });

    tearDown(() => dir.delete(recursive: true));

    Stream<SaveProgress> saveTo(Uri source) => FileSaver.save(
      input: SaveInput.file(source.toString()),
      fileType: _text,
      fileName: 'copy',
      saveLocation: PathLocation(dir.path),
      subDir: 'out',
    );

    testWidgets('copies the MediaStore file into the directory', (_) async {
      final source = await _saveText('content_source', 'from MediaStore');

      final events = await saveTo(source).toList();

      final uri = (events.last as SaveProgressComplete).uri;
      expect(uri.toFilePath(), '${dir.path}/out/copy.txt');
      expect(await File.fromUri(uri).readAsString(), 'from MediaStore');
      expect(dir.listSync(recursive: true).whereType<File>(), hasLength(1));
      final last = events.whereType<SaveProgressUpdate>().last;
      expect(last.bytesWritten, 'from MediaStore'.length);
      expect(last.totalBytes, 'from MediaStore'.length);
    });

    testWidgets('cancelling stops the copy and deletes the partial file', (
      _,
    ) async {
      final source = await FileSaver.saveAsync(
        input: SaveInput.bytes(Uint8List(64 * 1024 * 1024)),
        fileType: _text,
        fileName: 'content_large',
        saveLocation: AndroidSaveLocation.downloads,
        subDir: _subDir,
        conflictResolution: ConflictResolution.overwrite,
      );

      // Cancelled at the first update, before the copy of 64 MB can end.
      final cancelled = Completer<void>();
      final events = <SaveProgress>[];
      late final StreamSubscription<SaveProgress> subscription;
      subscription = saveTo(source).listen(
        (event) {
          events.add(event);
          if (event is SaveProgressUpdate && !cancelled.isCompleted) {
            cancelled.complete(subscription.cancel());
          }
        },
        onDone: () {
          if (cancelled.isCompleted) return;
          cancelled.completeError(StateError('Ended with no update: $events'));
        },
      );
      await cancelled.future;

      expect(events.whereType<SaveProgressComplete>(), isEmpty);
      expect(dir.listSync(recursive: true).whereType<File>(), isEmpty);
    });

    testWidgets('a missing content URI throws SourceFileNotFoundException', (
      _,
    ) async {
      final source = await _saveText('content_missing', 'x');

      await expectLater(
        saveTo(Uri.parse('${source}999')).last,
        completion(
          isA<SaveProgressError>().having(
            (e) => e.exception,
            'exception',
            isA<SourceFileNotFoundException>(),
          ),
        ),
      );
      expect(dir.listSync(recursive: true).whereType<File>(), isEmpty);
    });
  });

  testWidgets('cancelling a download completes once the partial file is '
      'deleted', (_) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) {
      // Sends half of the body, then stalls.
      request.response
        ..contentLength = 1024 * 1024
        ..add(Uint8List(512 * 1024));
      request.response.flush();
    });
    final subDir = '$_subDir/cancel';
    final dir = Directory('/storage/emulated/0/Download/$subDir');

    final writing = Completer<void>();
    final events = <SaveProgress>[];
    final subscription =
        FileSaver.save(
          input: SaveInput.network(
            url: 'http://127.0.0.1:${server.port}/stall',
          ),
          fileName: 'stalled',
          fileType: _text,
          saveLocation: AndroidSaveLocation.downloads,
          subDir: subDir,
        ).listen((event) {
          events.add(event);
          // The file exists, as a pending MediaStore entry, once data arrives.
          if (event is SaveProgressUpdate && event.progress >= 0.3) {
            if (!writing.isCompleted) writing.complete();
          }
        });
    await writing.future.timeout(const Duration(seconds: 10));
    expect(dir.listSync(), hasLength(1), reason: 'the partial file');

    await subscription.cancel();

    expect(dir.existsSync() ? dir.listSync() : const [], isEmpty);
    expect(events.whereType<SaveProgressComplete>(), isEmpty);
  });

  testWidgets('a second listen throws instead of saving again', (_) async {
    final subDir = '$_subDir/relisten';
    final dir = Directory('/storage/emulated/0/Download/$subDir');
    final stream = FileSaver.save(
      input: SaveInput.bytes(Uint8List.fromList('x'.codeUnits)),
      fileName: 'once',
      fileType: _text,
      saveLocation: AndroidSaveLocation.downloads,
      subDir: subDir,
    );

    expect((await stream.last), isA<SaveProgressComplete>());
    expect(() => stream.listen(null), throwsStateError);
    expect(dir.listSync(), hasLength(1));
  });

  group('a download reports the bytes written', () {
    final body = Uint8List.fromList(List.generate(256 * 1024, (i) => i % 251));
    late HttpServer server;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        // Without a contentLength, HttpServer sends the body chunked.
        if (request.uri.path == '/sized') {
          request.response.contentLength = body.length;
        }
        for (var offset = 0; offset < body.length; offset += 64 * 1024) {
          request.response.add(body.sublist(offset, offset + 64 * 1024));
          await request.response.flush();
          await Future<void>.delayed(const Duration(milliseconds: 150));
        }
        await request.response.close();
      });
    });

    tearDown(() => server.close(force: true));

    Future<List<SaveProgressUpdate>> download(String path) async {
      final events = await FileSaver.save(
        input: SaveInput.network(url: 'http://127.0.0.1:${server.port}$path'),
        fileName: path.substring(1),
        fileType: _text,
        saveLocation: AndroidSaveLocation.downloads,
        subDir: _subDir,
        conflictResolution: ConflictResolution.overwrite,
      ).toList();
      expect(events.last, isA<SaveProgressComplete>());
      return events.whereType<SaveProgressUpdate>().toList();
    }

    testWidgets('of the Content-Length', (_) async {
      final updates = await download('/sized');

      expect(updates.length, greaterThan(1));
      expect(updates.map((e) => e.totalBytes), everyElement(body.length));
      expect(updates.last.bytesWritten, body.length);
      expect(updates.last.progress, 1.0);
    });

    testWidgets('of an unknown size without Content-Length', (_) async {
      final updates = await download('/chunked');

      expect(updates.length, greaterThan(1));
      expect(updates.map((e) => e.totalBytes), everyElement(isNull));
      expect(updates.map((e) => e.progress), everyElement(0.0));
      expect(updates.last.bytesWritten, body.length);
    });
  });

  testWidgets('an HTTP error throws NetworkException with the status code', (
    _,
  ) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) {
      request.response.statusCode = HttpStatus.notFound;
      request.response.close();
    });

    await expectLater(
      FileSaver.saveAsync(
        input: SaveInput.network(
          url: 'http://127.0.0.1:${server.port}/missing.txt',
        ),
        fileName: 'missing',
        fileType: _text,
        saveLocation: AndroidSaveLocation.downloads,
        subDir: _subDir,
      ),
      throwsA(
        isA<NetworkException>()
            .having((e) => e.statusCode, 'statusCode', 404)
            .having(
              (e) => e.message,
              'message',
              'Network error: HTTP 404: Not Found',
            ),
      ),
    );
  });

  testWidgets('a conflict with fail throws FileExistsException with the '
      'file name', (_) async {
    Future<Uri> save() => FileSaver.saveAsync(
      input: SaveInput.bytes(Uint8List.fromList('x'.codeUnits)),
      fileName: 'taken',
      fileType: _text,
      saveLocation: AndroidSaveLocation.downloads,
      subDir: _subDir,
      conflictResolution: ConflictResolution.fail,
    );
    await save();

    await expectLater(
      save(),
      throwsA(
        isA<FileExistsException>()
            .having((e) => e.fileName, 'fileName', 'taken.txt')
            .having(
              (e) => e.message,
              'message',
              'File already exists: taken.txt',
            ),
      ),
    );
  });

  testWidgets('openWrite with skip returns null for an existing file', (
    _,
  ) async {
    await _saveText('skip', 'kept');

    final sink = await FileSaver.openWrite(
      fileName: 'skip',
      fileType: _text,
      saveLocation: AndroidSaveLocation.downloads,
      subDir: _subDir,
      conflictResolution: ConflictResolution.skip,
    );

    expect(sink, isNull);
  });

  testWidgets('openWrite streams chunks and returns the saved URI', (_) async {
    final sink = (await FileSaver.openWrite(
      fileName: 'session',
      fileType: _text,
      saveLocation: AndroidSaveLocation.downloads,
      subDir: _subDir,
      conflictResolution: ConflictResolution.overwrite,
    ))!;
    sink.add('ab'.codeUnits);
    sink.add('c'.codeUnits);
    await sink.close();

    expect(await FileSaver.canOpenFile(await sink.result), isTrue);
  });

  Future<FileSaverSink> openSession(String name) async =>
      (await FileSaver.openWrite(
        fileName: name,
        fileType: _text,
        saveLocation: AndroidSaveLocation.downloads,
        subDir: _subDir,
        conflictResolution: ConflictResolution.overwrite,
      ))!;

  testWidgets('close while addStream runs throws StateError instead of '
      'freezing the isolate', (_) async {
    final sink = await openSession('close_during_add_stream');
    Stream<List<int>> chunks() async* {
      for (var i = 0; i < 3; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        yield 'line $i\n'.codeUnits;
      }
    }

    final adding = sink.addStream(chunks());
    expect(() => sink.close(), throwsStateError);
    await adding;
    await sink.close();

    expect(await FileSaver.canOpenFile(await sink.result), isTrue);
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets('chunks added without awaiting are all written and counted '
      'before close completes', (_) async {
    // 320 × 1 MB is more than the 256 MB heap limit of a typical app, so
    // chunks added while a write is pending wait on the Dart side.
    final sink = await openSession('add_loop');
    var written = 0;
    sink.bytesWritten.listen((bytes) => written = bytes);
    final chunk = Uint8List(1024 * 1024);
    for (var i = 0; i < 320; i++) {
      sink.add(chunk);
    }
    await sink.close();

    expect(written, 320 * chunk.length);
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets('a directory the app has no access to is neither persisted nor '
      'restored', (_) async {
    // Granting access needs the system picker, so only refusals are tested.
    final tree = Uri.parse(
      'content://com.android.externalstorage.documents/tree/primary%3ADownload',
    );

    await expectLater(
      FileSaver.persistDirectory(PickedDirectoryLocation(uri: tree)),
      throwsA(isA<NativePlatformException>()),
    );
    await expectLater(
      FileSaver.persistDirectory(
        PickedDirectoryLocation(uri: Uri.directory('/sdcard/Download')),
      ),
      throwsA(isA<InvalidInputException>()),
    );
    expect(await FileSaver.restoreDirectory(tree.toString()), isNull);
    expect(await FileSaver.restoreDirectory('not a uri'), isNull);
  });
}
