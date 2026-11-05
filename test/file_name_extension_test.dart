import 'package:file_saver_ffi/file_saver_ffi.dart';
import 'package:file_saver_ffi/platform_interface.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records the file name every operation receives.
class _NamePlatform extends FileSaverPlatform {
  final names = <String>[];

  @override
  dynamic noSuchMethod(Invocation invocation) {
    names.add(invocation.namedArguments[#fileName] as String);
    return const Stream<SaveProgress>.empty();
  }

  @override
  Future<FileSaverSink?> openWrite({
    required String fileName,
    required FileType fileType,
    SaveLocation? saveLocation,
    String? subDir,
    int? totalSize,
    ConflictResolution conflictResolution = ConflictResolution.autoRename,
  }) async {
    names.add(fileName);
    return null;
  }

  @override
  Future<FileSaverSink?> openWriteAs({
    required String fileName,
    required FileType fileType,
    required PickedDirectoryLocation saveLocation,
    int? totalSize,
    ConflictResolution conflictResolution = ConflictResolution.autoRename,
  }) async {
    names.add(fileName);
    return null;
  }
}

void main() {
  late _NamePlatform platform;
  final picked = PickedDirectoryLocation(uri: Uri.parse('file:///picked/'));

  setUp(() {
    platform = _NamePlatform();
    FileSaverPlatform.instance = platform;
  });

  /// The name each API passes to the platform for [fileName].
  Future<List<String>> namesFor(String fileName, FileType fileType) async {
    platform.names.clear();
    for (final input in [
      SaveInput.bytes(Uint8List(1)),
      SaveInput.file('/src/a'),
      SaveInput.network(url: 'https://example.com/a'),
    ]) {
      await FileSaver.save(
        input: input,
        fileType: fileType,
        fileName: fileName,
      ).drain<void>();
    }
    await FileSaver.saveAs(
      input: SaveInput.bytes(Uint8List(1)),
      fileType: fileType,
      fileName: fileName,
      saveLocation: picked,
    ).drain<void>();
    await FileSaver.openWrite(fileName: fileName, fileType: fileType);
    await FileSaver.openWriteAs(
      fileName: fileName,
      fileType: fileType,
      saveLocation: picked,
    );
    return platform.names;
  }

  test('a name ending with the extension of its type loses it', () async {
    for (final name in ['photo.png', 'photo.PNG', 'photo.Png']) {
      expect(await namesFor(name, ImageType.png), List.filled(6, 'photo'));
    }
    expect(
      await namesFor(
        'report.tar.gz',
        const CustomFileType(ext: 'tar.gz', mimeType: 'application/gzip'),
      ),
      List.filled(6, 'report'),
    );
  });

  test('other names are passed unchanged', () async {
    for (final name in ['photo', 'photo.jpg', 'photo.png.bak', '.png', 'png']) {
      expect(
        await namesFor(name, ImageType.png),
        List.filled(6, name),
        reason: name,
      );
    }
    const noExt = CustomFileType(ext: '', mimeType: 'text/plain');
    expect(await namesFor('notes.', noExt), List.filled(6, 'notes.'));
  });
}
