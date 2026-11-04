// On-device tests of the Darwin FFI bridge on iOS, which `flutter test` can't
// load. Run from example/ on a simulator or device:
//   flutter test integration_test/ios_test.dart -d <device-id>
// They save to the app's Documents/fsf_it/<run>/, which is removed with the
// app. The first Photos test asks for Photos access: wait until it has been
// shown for 2 s (the test cancels a save while it is open), then answer "Allow
// Full Access". (`simctl privacy grant` doesn't help: `flutter test`
// reinstalls the app, which drops the grant.) The assets stay in the library:
// delete them in the Photos app.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_saver_ffi/file_saver_ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

final _subDir = 'fsf_it/${DateTime.now().millisecondsSinceEpoch}';
const _text = CustomFileType(ext: 'txt', mimeType: 'text/plain');

/// A 1×1 PNG, small enough to save to Photos quickly.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
);

/// A Photos asset name that is unique to this run.
String _photoName(String name) => 'fsf_${_subDir.split('/').last}_$name';

Future<Uri> _saveToPhotos(
  String name, {
  String? album,
  ConflictResolution conflictResolution = ConflictResolution.autoRename,
}) => FileSaver.saveAsync(
  input: SaveInput.bytes(_png),
  fileName: _photoName(name),
  fileType: ImageType.png,
  saveLocation: IosSaveLocation.photos,
  subDir: album,
  conflictResolution: conflictResolution,
);

/// [length] bytes that differ from one position to the next.
Uint8List _pattern(int length) =>
    Uint8List.fromList(List.generate(length, (i) => i * 7 % 251));

Future<Uri> _saveBytes(
  String name,
  Uint8List bytes, {
  SaveLocation? saveLocation = IosSaveLocation.documents,
}) => FileSaver.saveAsync(
  input: SaveInput.bytes(bytes),
  fileName: name,
  fileType: _text,
  saveLocation: saveLocation,
  subDir: _subDir,
);

Future<FileSaverSink?> _openSession(
  String name, {
  ConflictResolution conflictResolution = ConflictResolution.overwrite,
}) => FileSaver.openWrite(
  fileName: name,
  fileType: _text,
  saveLocation: IosSaveLocation.documents,
  subDir: _subDir,
  conflictResolution: conflictResolution,
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('openWrite streams chunks and returns the saved URI', (_) async {
    final sink = (await _openSession('session'))!;
    sink.add('ab'.codeUnits);
    await sink.addStream(Stream.value('c'.codeUnits));
    await sink.close();

    final uri = await sink.result;
    expect(await FileSaver.canOpenFile(uri), isTrue);
  });

  testWidgets('openWrite with skip returns null for an existing file', (
    _,
  ) async {
    final first = (await _openSession('skip'))!;
    first.add('kept'.codeUnits);
    await first.close();

    final sink = await _openSession(
      'skip',
      conflictResolution: ConflictResolution.skip,
    );

    expect(sink, isNull);
  });

  testWidgets('close while addStream runs throws StateError instead of '
      'freezing the isolate', (_) async {
    final sink = (await _openSession('close_during_add_stream'))!;
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
    final sink = (await _openSession('add_loop'))!;
    var written = 0;
    sink.bytesWritten.listen((bytes) => written = bytes);
    final chunk = Uint8List(1024 * 1024);
    for (var i = 0; i < 64; i++) {
      sink.add(chunk);
    }
    await sink.close();

    expect(written, 64 * chunk.length);
  }, timeout: const Timeout(Duration(minutes: 2)));

  testWidgets('saveBytes, saveAs and openWrite write exactly the bytes '
      'passed', (_) async {
    final bytes = _pattern(3 * 1024 * 1024 + 17);

    final saved = await _saveBytes('bytes', bytes);
    expect(await File.fromUri(saved).readAsBytes(), bytes);

    final savedAs = await FileSaver.saveAsAsync(
      input: SaveInput.bytes(bytes),
      fileName: 'bytes_as',
      fileType: _text,
      saveLocation: PickedDirectoryLocation(
        uri: File.fromUri(saved).parent.uri,
      ),
    );
    expect(await File.fromUri(savedAs!).readAsBytes(), bytes);

    final sink = (await _openSession('chunks'))!;
    for (var offset = 0; offset < bytes.length; offset += 100000) {
      sink.add(bytes.sublist(offset, (offset + 100000).clamp(0, bytes.length)));
    }
    await sink.close();
    expect(await File.fromUri(await sink.result).readAsBytes(), bytes);
  }, timeout: const Timeout(Duration(minutes: 2)));

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
    final dir = Directory(
      '${(await getApplicationDocumentsDirectory()).path}/$subDir',
    );

    final writing = Completer<void>();
    final events = <SaveProgress>[];
    final subscription =
        FileSaver.save(
          input: SaveInput.network(
            url: 'http://127.0.0.1:${server.port}/stall',
          ),
          fileName: 'stalled',
          fileType: _text,
          saveLocation: IosSaveLocation.documents,
          subDir: subDir,
        ).listen((event) {
          events.add(event);
          // The file exists once data arrives.
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
    final dir = Directory(
      '${(await getApplicationDocumentsDirectory()).path}/$subDir',
    );
    final stream = FileSaver.save(
      input: SaveInput.bytes(Uint8List.fromList('x'.codeUnits)),
      fileName: 'once',
      fileType: _text,
      saveLocation: IosSaveLocation.documents,
      subDir: subDir,
    );

    expect((await stream.last), isA<SaveProgressComplete>());
    expect(() => stream.listen(null), throwsStateError);
    expect(dir.listSync(), hasLength(1));
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
        saveLocation: IosSaveLocation.documents,
        subDir: _subDir,
      ),
      throwsA(
        isA<NetworkException>()
            .having((e) => e.statusCode, 'statusCode', 404)
            .having((e) => e.message, 'message', 'Network error: HTTP 404'),
      ),
    );
  });

  testWidgets('a conflict with fail throws FileExistsException with the '
      'file name', (_) async {
    Future<Uri> save() => FileSaver.saveAsync(
      input: SaveInput.bytes(Uint8List.fromList('x'.codeUnits)),
      fileName: 'taken',
      fileType: _text,
      saveLocation: IosSaveLocation.documents,
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

  testWidgets('network progress is sent in steps of about 1%', (_) async {
    final body = _pattern(32 * 1024 * 1024);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.contentLength = body.length;
      for (var offset = 0; offset < body.length; offset += 16 * 1024) {
        request.response.add(body.sublist(offset, offset + 16 * 1024));
      }
      await request.response.close();
    });

    final progress = <double>[];
    final uri = await FileSaver.saveAsync(
      input: SaveInput.network(url: 'http://127.0.0.1:${server.port}/body.bin'),
      fileName: 'network',
      fileType: const CustomFileType(
        ext: 'bin',
        mimeType: 'application/octet-stream',
      ),
      saveLocation: IosSaveLocation.documents,
      subDir: _subDir,
      onProgress: progress.add,
    );

    expect(await File.fromUri(uri).length(), body.length);
    expect(progress.last, 1.0);
    // At most 100 steps of 1%, plus one per 100 ms of the download.
    expect(progress.length, lessThan(150), reason: '$progress');
  }, timeout: const Timeout(Duration(minutes: 2)));

  group('a download reports the bytes written', () {
    final body = _pattern(256 * 1024);
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
        saveLocation: IosSaveLocation.documents,
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

  testWidgets('a file save reports the bytes copied of its size, and a skip '
      'reports none', (_) async {
    final bytes = _pattern(3 * 1024 * 1024 + 17);
    final source = File(
      '${(await getTemporaryDirectory()).path}/fsf_source.txt',
    );
    await source.writeAsBytes(bytes);
    addTearDown(source.delete);

    Future<List<SaveProgress>> save(ConflictResolution conflictResolution) =>
        FileSaver.save(
          input: SaveInput.file(source.path),
          fileName: 'copied',
          fileType: _text,
          saveLocation: IosSaveLocation.documents,
          subDir: _subDir,
          conflictResolution: conflictResolution,
        ).toList();

    final updates = (await save(
      ConflictResolution.overwrite,
    )).whereType<SaveProgressUpdate>().toList();
    expect(updates.map((e) => e.totalBytes), everyElement(bytes.length));
    expect(updates.map((e) => e.bytesWritten), [
      1024 * 1024,
      2 * 1024 * 1024,
      3 * 1024 * 1024,
      bytes.length,
    ]);

    final skipped = await save(ConflictResolution.skip);
    expect(skipped.whereType<SaveProgressUpdate>(), isEmpty);
    expect(skipped.last, isA<SaveProgressComplete>());
  });

  testWidgets('a location of another platform throws InvalidInputException', (
    _,
  ) async {
    final bytes = _pattern(16);
    for (final location in <SaveLocation>[
      MacosSaveLocation.pictures,
      AndroidSaveLocation.downloads,
      PickedDirectoryLocation(uri: Uri.directory(Directory.systemTemp.path)),
    ]) {
      await expectLater(
        () => _saveBytes('other_location', bytes, saveLocation: location),
        throwsA(isA<InvalidInputException>()),
        reason: '$location',
      );
      await expectLater(
        FileSaver.openWrite(
          fileName: 'other_location',
          fileType: _text,
          saveLocation: location,
        ),
        throwsA(isA<InvalidInputException>()),
        reason: '$location',
      );
    }
  });

  testWidgets('a persisted directory is restored, follows a rename, and '
      'restores to null once deleted', (_) async {
    final anchor = await _saveBytes('persist_anchor', _pattern(1));
    final directory = Directory('${File.fromUri(anchor).parent.path}/persisted')
      ..createSync();

    final token = await FileSaver.persistDirectory(
      PickedDirectoryLocation(uri: directory.uri),
    );
    expect(token, isNot(directory.uri.toString()), reason: 'a bookmark');

    final restored = await FileSaver.restoreDirectory(token);
    expect(
      Directory.fromUri(restored!.uri).resolveSymbolicLinksSync(),
      directory.resolveSymbolicLinksSync(),
    );
    final bytes = _pattern(1000);
    final savedAs = await FileSaver.saveAsAsync(
      input: SaveInput.bytes(bytes),
      fileName: 'restored',
      fileType: _text,
      saveLocation: restored,
    );
    expect(
      File.fromUri(savedAs!).parent.resolveSymbolicLinksSync(),
      directory.resolveSymbolicLinksSync(),
    );
    expect(await File.fromUri(savedAs).readAsBytes(), bytes);

    // The bookmark follows the directory, and the restored location can be
    // persisted again.
    final moved = directory.renameSync('${directory.path}_moved');
    final afterMove = await FileSaver.restoreDirectory(token);
    expect(
      Directory.fromUri(afterMove!.uri).resolveSymbolicLinksSync(),
      moved.resolveSymbolicLinksSync(),
    );
    final newToken = await FileSaver.persistDirectory(afterMove);
    await FileSaver.releaseDirectory(token);

    moved.deleteSync(recursive: true);
    expect(await FileSaver.restoreDirectory(newToken), isNull);
    await FileSaver.releaseDirectory(newToken);

    expect(await FileSaver.restoreDirectory('not a bookmark'), isNull);
  });

  group('Photos', () {
    // Runs first: its permission dialog grants the access the others use.
    testWidgets('a save cancelled while the permission dialog is open adds '
        'no asset', (_) async {
      final subscription = FileSaver.save(
        input: SaveInput.bytes(_png),
        fileName: _photoName('cancelled'),
        fileType: ImageType.png,
        saveLocation: IosSaveLocation.photos,
        subDir: 'fsf_it',
      ).listen(null);
      await Future<void>.delayed(const Duration(seconds: 1));
      await subscription.cancel();

      // Waits for the dialog to be answered, with read/write access.
      final uri = await _saveToPhotos('album', album: 'fsf_it');
      expect(await FileSaver.canOpenFile(uri), isTrue);
      // The cancelled save, had it gone ahead after the dialog, is done by now.
      await Future<void>.delayed(const Duration(seconds: 2));

      // `fail` throws FileExistsException if the cancelled save added it.
      await _saveToPhotos(
        'cancelled',
        album: 'fsf_it',
        conflictResolution: ConflictResolution.fail,
      );
    }, timeout: const Timeout(Duration(minutes: 5)));

    testWidgets('a save without subDir uses the read access the app has, so '
        'its URI opens and conflict resolution works', (_) async {
      final uri = await _saveToPhotos('read_access');

      expect(await FileSaver.canOpenFile(uri), isTrue);
      expect(
        await _saveToPhotos(
          'read_access',
          conflictResolution: ConflictResolution.skip,
        ),
        uri,
      );
    });

    testWidgets('a save reports one update with the whole size', (_) async {
      final events = await FileSaver.save(
        input: SaveInput.bytes(_png),
        fileName: _photoName('bytes_progress'),
        fileType: ImageType.png,
        saveLocation: IosSaveLocation.photos,
      ).toList();

      final updates = events.whereType<SaveProgressUpdate>().toList();
      expect(updates, hasLength(1));
      expect(updates.single.bytesWritten, _png.length);
      expect(updates.single.totalBytes, _png.length);
      expect(events.last, isA<SaveProgressComplete>());
    });

    testWidgets('audio and other files are rejected instead of being saved to '
        'Documents', (_) async {
      await expectLater(
        FileSaver.saveAsync(
          input: SaveInput.bytes(Uint8List.fromList('ID3'.codeUnits)),
          fileName: _photoName('audio'),
          fileType: AudioType.mp3,
          saveLocation: IosSaveLocation.photos,
        ),
        throwsA(isA<InvalidInputException>()),
      );
      await expectLater(
        FileSaver.openWrite(
          fileName: _photoName('text'),
          fileType: _text,
          saveLocation: IosSaveLocation.photos,
        ),
        throwsA(isA<InvalidInputException>()),
      );
    });
  });
}
