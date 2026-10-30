// On-device tests of the Android JNI bridge, which `flutter test` can't load
// (Android only).
// Run from example/ with a device attached:
//   flutter test integration_test/android_test.dart -d <device-id>
// They save to Download/fsf_it/<run>/; remove it afterwards with
//   adb shell content delete --uri content://media/external/file \
//     --where "\"_data LIKE '%/Download/fsf_it/%'\""
import 'dart:typed_data';

import 'package:file_saver_ffi/file_saver_ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

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
}
