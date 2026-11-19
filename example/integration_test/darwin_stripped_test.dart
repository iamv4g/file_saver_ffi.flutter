// Tests of the Darwin FFI bridge in an app whose symbols are stripped, as
// Xcode strips an App Store archive (STRIP_STYLE = all, its default for apps).
// `flutter test` doesn't build them stripped; run from example/ with
// `flutter drive`, in profile mode, on macOS or an iOS device:
//   FLUTTER_XCODE_DEPLOYMENT_POSTPROCESSING=YES FLUTTER_XCODE_STRIP_STYLE=all \
//     flutter drive --profile -d <device> \
//     --driver=test_driver/integration_test.dart \
//     --target=integration_test/darwin_stripped_test.dart
// They save to the app's Documents/fsf_it/<run>/. The directory tests also
// check dir_picker, which file_saver_ffi uses for them and which had the
// same bug before 0.8.1.
import 'dart:io';
import 'dart:typed_data';

import 'package:file_saver_ffi/file_saver_ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

final _subDir = 'fsf_it/${DateTime.now().millisecondsSinceEpoch}';
const _text = CustomFileType(ext: 'txt', mimeType: 'text/plain');

final SaveLocation _documents = Platform.isIOS
    ? IosSaveLocation.documents
    : MacosSaveLocation.documents;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('saves bytes, and finds the saved file', (_) async {
    final uri = await FileSaver.saveAsync(
      input: SaveInput.bytes(Uint8List.fromList('abc'.codeUnits)),
      fileName: 'bytes',
      fileType: _text,
      saveLocation: _documents,
      subDir: _subDir,
    );
    expect(File.fromUri(uri).readAsStringSync(), 'abc');
    expect(await FileSaver.canOpenFile(uri), isTrue);
  });

  testWidgets('streams a write session', (_) async {
    final sink = (await FileSaver.openWrite(
      fileName: 'session',
      fileType: _text,
      saveLocation: _documents,
      subDir: _subDir,
    ))!;
    sink.add('ab'.codeUnits);
    await sink.flush();
    sink.add('c'.codeUnits);
    await sink.close();
    expect(File.fromUri(await sink.result).readAsStringSync(), 'abc');
  });

  testWidgets('cancels a write session', (_) async {
    final sink = (await FileSaver.openWrite(
      fileName: 'cancelled',
      fileType: _text,
      saveLocation: _documents,
      subDir: _subDir,
    ))!;
    sink.add('ab'.codeUnits);
    await sink.cancel();
    await expectLater(sink.result, throwsA(isA<CancelledException>()));
  });

  testWidgets('persists, restores and releases a directory', (_) async {
    final anchor = await FileSaver.saveAsync(
      input: SaveInput.bytes(Uint8List.fromList('x'.codeUnits)),
      fileName: 'anchor',
      fileType: _text,
      saveLocation: _documents,
      subDir: _subDir,
    );
    final directory = Directory('${File.fromUri(anchor).parent.path}/persisted')
      ..createSync();

    final token = await FileSaver.persistDirectory(
      PickedDirectoryLocation(uri: directory.uri),
    );
    final restored = await FileSaver.restoreDirectory(token);
    expect(
      Directory.fromUri(restored!.uri).resolveSymbolicLinksSync(),
      directory.resolveSymbolicLinksSync(),
    );
    await FileSaver.releaseDirectory(token);
  });
}
