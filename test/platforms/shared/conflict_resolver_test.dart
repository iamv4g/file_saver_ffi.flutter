import 'package:file_saver_ffi/file_saver_ffi.dart';
import 'package:file_saver_ffi/src/platforms/shared/conflict_resolver.dart';
import 'package:file_saver_ffi/src/platforms/shared/file_entity.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeFileEntity implements FileEntity {
  _FakeFileEntity(this.files);

  final Set<String> files;

  @override
  Future<bool> exists(String path) async => files.contains(path);

  @override
  Future<void> delete(String path) async => files.remove(path);
}

void main() {
  ConflictResolver resolverWith(Set<String> files) =>
      ConflictResolver(_FakeFileEntity(files));

  test('returns the path unchanged when nothing exists', () async {
    final resolver = resolverWith({});
    for (final mode in ConflictResolution.values) {
      expect(await resolver.resolve('/d/a.txt', mode), '/d/a.txt');
    }
  });

  group('when the file exists', () {
    final resolver = resolverWith({'/d/a.txt', '/d/a (1).txt'});

    test('autoRename picks the first free suffix', () async {
      expect(
        await resolver.resolve('/d/a.txt', ConflictResolution.autoRename),
        '/d/a (2).txt',
      );
    });

    test('overwrite keeps the path', () async {
      expect(
        await resolver.resolve('/d/a.txt', ConflictResolution.overwrite),
        '/d/a.txt',
      );
    });

    test('skip returns null', () async {
      expect(
        await resolver.resolve('/d/a.txt', ConflictResolution.skip),
        isNull,
      );
    });

    test('fail throws FileExistsException', () {
      expect(
        resolver.resolve('/d/a.txt', ConflictResolution.fail),
        throwsA(isA<FileExistsException>()),
      );
    });
  });

  test('autoRename works for names without an extension', () async {
    final resolver = resolverWith({'README'});
    expect(
      await resolver.resolve('README', ConflictResolution.autoRename),
      'README (1)',
    );
  });

  test('autoRename only splits on the last dot', () async {
    final resolver = resolverWith({'archive.tar.gz'});
    expect(
      await resolver.resolve('archive.tar.gz', ConflictResolution.autoRename),
      'archive.tar (1).gz',
    );
  });

  test('autoRename gives up after 1000 attempts', () {
    final resolver = resolverWith({
      'a.txt',
      for (var i = 1; i <= 1000; i++) 'a ($i).txt',
    });
    expect(
      resolver.resolve('a.txt', ConflictResolution.autoRename),
      throwsA(isA<FileIOException>()),
    );
  });
}
