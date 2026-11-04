import 'dart:typed_data';

import 'package:file_saver_ffi/file_saver_ffi.dart';
import 'package:file_saver_ffi/platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

/// A fake an app can write with the public libraries alone.
class _FakeFileSaver extends FileSaverPlatform {
  final saved = <String>[];

  @override
  Stream<SaveProgress> saveBytes({
    required Uint8List fileBytes,
    required FileType fileType,
    required String fileName,
    SaveLocation? saveLocation,
    String? subDir,
    ConflictResolution conflictResolution = ConflictResolution.autoRename,
  }) {
    saved.add(fileName);
    return Stream.value(SaveProgressComplete(Uri.parse('file:///$fileName')));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// `flutter test` doesn't run the plugin registrant, so nothing sets
/// [FileSaverPlatform.instance] in this file until a test does.
void main() {
  test('an unset instance throws StateError, also in release builds', () {
    expect(
      () => FileSaverPlatform.instance,
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('FileSaverPlatform.instance'),
        ),
      ),
    );
  });

  test('FileSaver saves through a fake set as the instance', () async {
    final fake = _FakeFileSaver();
    FileSaverPlatform.instance = fake;

    final uri = await FileSaver.saveAsync(
      input: SaveInput.bytes(Uint8List.fromList([1])),
      fileName: 'report',
      fileType: const CustomFileType(ext: 'bin', mimeType: 'x/y'),
    );

    expect(uri, Uri.parse('file:///report'));
    expect(fake.saved, ['report']);
  });
}
