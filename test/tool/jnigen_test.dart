@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/jnigen.dart';

void main() {
  late Directory build;

  setUp(() => build = Directory.systemTemp.createTempSync('jnigen_test'));
  tearDown(() => build.deleteSync(recursive: true));

  const builtIn =
      'intermediates/built_in_kotlinc/debug/compileDebugKotlin/classes';
  const kgp = 'tmp/kotlin-classes/debug';

  /// Writes FileSaver.class under [output], modified at [modified].
  void compile(String output, {DateTime? modified}) {
    final file = File(
      '${build.path}/$output/com/iamv4g/file_saver_ffi/FileSaver.class',
    )..createSync(recursive: true);
    if (modified != null) file.setLastModifiedSync(modified);
  }

  group('kotlinClassesDirectory', () {
    test('finds the classes of AGP 9 built-in Kotlin', () {
      compile(builtIn);
      expect(kotlinClassesDirectory(build).path, '${build.path}/$builtIn');
    });

    test('finds the classes of the Kotlin Gradle Plugin', () {
      compile(kgp);
      expect(kotlinClassesDirectory(build).path, '${build.path}/$kgp');
    });

    test('with both, picks the one compiled last', () {
      final earlier = DateTime(2026, 11);
      final later = earlier.add(const Duration(hours: 1));

      compile(builtIn, modified: earlier);
      compile(kgp, modified: later);
      expect(kotlinClassesDirectory(build).path, '${build.path}/$kgp');

      compile(builtIn, modified: later.add(const Duration(hours: 1)));
      expect(kotlinClassesDirectory(build).path, '${build.path}/$builtIn');
    });

    test('ignores an output directory without the plugin classes', () {
      Directory('${build.path}/$builtIn').createSync(recursive: true);
      compile(kgp);
      expect(kotlinClassesDirectory(build).path, '${build.path}/$kgp');
    });

    test('without the classes, fails naming where it looked', () {
      expect(
        () => kotlinClassesDirectory(build),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains(builtIn), contains(kgp)),
          ),
        ),
      );
    });
  });
}
