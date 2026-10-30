// On-device tests of the Darwin FFI bridge on iOS, which `flutter test` can't
// load. Run from example/ on a simulator or device:
//   flutter test integration_test/ios_test.dart -d <device-id>
// They save to the app's Documents/fsf_it/<run>/, which is removed with the
// app.
import 'dart:typed_data';

import 'package:file_saver_ffi/file_saver_ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

final _subDir = 'fsf_it/${DateTime.now().millisecondsSinceEpoch}';
const _text = CustomFileType(ext: 'txt', mimeType: 'text/plain');

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
}
