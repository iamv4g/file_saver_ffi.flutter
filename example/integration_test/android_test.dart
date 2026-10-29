// On-device tests of the Android JNI bridge, which `flutter test` can't load
// (Android only).
// Run from example/ with a device attached:
//   flutter test integration_test/android_test.dart -d <device-id>
// They save to Download/fsf_it/; remove it afterwards with
//   adb shell content delete --uri content://media/external/file \
//     --where "\"_data LIKE '%/Download/fsf_it/%'\""
import 'dart:typed_data';

import 'package:file_saver_ffi/file_saver_ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _subDir = 'fsf_it';
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
}
