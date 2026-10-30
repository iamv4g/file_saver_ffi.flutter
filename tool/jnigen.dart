// ignore_for_file: avoid_print

import 'dart:io';

import 'package:jnigen/jnigen.dart';

/// Generates JNI bindings for the Android native classes.
///
/// Run with:
///   dart run tool/jnigen.dart
Future<void> main(List<String> args) async {
  final packageRoot = Platform.script.resolve('../');

  // Step 1 — Compile plugin Kotlin classes first. This avoids a bootstrap
  // issue where Flutter's Dart build may reference bindings that are about to
  // be regenerated.
  print(
    'Running Gradle :file_saver_ffi:compileDebugKotlin in example/android/...',
  );

  final result = await Process.run(
    './gradlew',
    [':file_saver_ffi:compileDebugKotlin'],
    workingDirectory: packageRoot.resolve('example/android/').toFilePath(),
    runInShell: true,
  );

  stdout.write(result.stdout);
  stderr.write(result.stderr);

  if (result.exitCode != 0) {
    throw Exception('Gradle :file_saver_ffi:compileDebugKotlin failed');
  }

  // Step 2 — Generate JNI bindings
  print('Generating JNI bindings...');
  await generateJniBindings(
    Config(
      outputConfig: OutputConfig(
        dartConfig: DartCodeOutputConfig(
          path: packageRoot.resolve(
            'lib/src/platforms/android/bindings.g.dart',
          ),
          structure: OutputStructure.singleFile,
        ),
      ),
      sourcePath: [
        packageRoot.resolve(
          'android/src/main/kotlin/com/iamv4g/file_saver_ffi',
        ),
      ],
      // Output of compileDebugKotlin with AGP 9's built-in Kotlin support.
      classPath: [
        packageRoot.resolve(
          'example/build/file_saver_ffi/intermediates/built_in_kotlinc/debug/compileDebugKotlin/classes',
        ),
      ],
      classes: [
        'com.iamv4g.file_saver_ffi.FileSaver',
        'com.iamv4g.file_saver_ffi.models.ProgressCallback',
      ],
    ),
  );

  print('JNI bindings generated successfully.');
}
