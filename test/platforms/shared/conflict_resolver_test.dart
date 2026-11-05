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

  @override
  Future<bool> claim(String path) async => files.add(path);
}

void main() {
  ConflictResolver resolverWith(Set<String> files) =>
      ConflictResolver(_FakeFileEntity(files));

  test('returns the path unchanged when nothing exists', () async {
    for (final mode in ConflictResolution.values) {
      expect(await resolverWith({}).resolve('/d/a.txt', mode), '/d/a.txt');
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

  test(
    'autoRename keeps a dot in the directory out of the extension',
    () async {
      final resolver = resolverWith({'/d.x/README'});
      expect(
        await resolver.resolve('/d.x/README', ConflictResolution.autoRename),
        '/d.x/README (1)',
      );
    },
  );

  test('autoRename treats a leading dot as part of the name', () async {
    for (final path in ['/d/.env', r'C:\d\.env', '.env']) {
      final resolver = resolverWith({path});
      expect(
        await resolver.resolve(path, ConflictResolution.autoRename),
        '$path (1)',
      );
    }
  });

  group('claim', () {
    test('a new path is claimed as new', () async {
      final files = <String>{};
      final resolved = await resolverWith(files)
          .claim('/d/a.txt', ConflictResolution.fail);
      expect(resolved, (path: '/d/a.txt', isNew: true));
      expect(files, {'/d/a.txt'});
    });

    test('overwrite of an existing file is not new', () async {
      final resolved = await resolverWith({'/d/a.txt'})
          .claim('/d/a.txt', ConflictResolution.overwrite);
      expect(resolved, (path: '/d/a.txt', isNew: false));
    });

    test('autoRename claims the free name it returns', () async {
      final files = {'/d/a.txt'};
      final resolver = resolverWith(files);
      expect(await resolver.claim('/d/a.txt', ConflictResolution.autoRename), (
        path: '/d/a (1).txt',
        isNew: true,
      ));
      expect(await resolver.claim('/d/a.txt', ConflictResolution.autoRename), (
        path: '/d/a (2).txt',
        isNew: true,
      ));
    });
  });

  test('autoRename gives up after 1000 attempts', () {
    final resolver = resolverWith({
      'a.txt',
      for (var i = 1; i <= 1000; i++) 'a ($i).txt',
    });
    expect(
      resolver.resolve('a.txt', ConflictResolution.autoRename),
      throwsA(
        isA<FileIOException>().having(
          (e) => e.message,
          'message',
          'File I/O error: Could not find available filename after 1000 '
              'attempts',
        ),
      ),
    );
  });

  test('autoRename still tries the 1000th name', () async {
    final resolver = resolverWith({
      'a.txt',
      for (var i = 1; i < 1000; i++) 'a ($i).txt',
    });
    expect(
      await resolver.resolve('a.txt', ConflictResolution.autoRename),
      'a (1000).txt',
    );
  });
}
