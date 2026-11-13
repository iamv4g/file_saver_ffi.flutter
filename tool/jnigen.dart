// ignore_for_file: avoid_print

import 'dart:io';

import 'package:jnigen/jnigen.dart';

/// Generates JNI bindings for the Android native classes.
///
/// Run with:
///   dart run tool/jnigen.dart
///
/// CI runs it and fails if `bindings.g.dart` changes.
Future<void> main(List<String> args) async {
  final packageRoot = Platform.script.resolve('../');

  // Step 1 — Compile plugin Kotlin classes first. This avoids a bootstrap
  // issue where Flutter's Dart build may reference bindings that are about to
  // be regenerated.
  print(
    'Running Gradle :file_saver_ffi:compileDebugKotlin in example/android/...',
  );

  final result = await Process.run(
    Platform.isWindows ? 'gradlew.bat' : './gradlew',
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
  await JniGenerator(
    input: Input(
      sourcePath: [
        packageRoot.resolve(
          'android/src/main/kotlin/com/iamv4g/file_saver_ffi',
        ),
      ],
      classPath: [
        kotlinClassesDirectory(
          Directory.fromUri(
            packageRoot.resolve('example/build/file_saver_ffi'),
          ),
        ).uri,
      ],
      classes: [
        'com.iamv4g.file_saver_ffi.FileSaver',
        'com.iamv4g.file_saver_ffi.models.ProgressCallback',
      ],
    ),
    output: Output(
      dart: DartOutput(
        path: packageRoot.resolve('lib/src/platforms/android/bindings.g.dart'),
        structure: OutputStructure.singleFile,
      ),
      // jnigen's own suppressions miss this one, which flutter_lints reports.
      preamble: '// ignore_for_file: prefer_initializing_formals',
    ),
  ).generate();

  print('JNI bindings generated successfully.');
}

/// Where `compileDebugKotlin` puts the plugin's classes, in [buildDirectory],
/// the plugin module's build directory.
///
/// AGP 9's built-in Kotlin, which the example turns on, and the Kotlin Gradle
/// Plugin use different directories. When both hold the classes, from builds
/// with either, it picks the one compiled last. Throws a [StateError] when
/// neither does.
Directory kotlinClassesDirectory(Directory buildDirectory) {
  const outputs = [
    // AGP 9 with android.builtInKotlin=true.
    'intermediates/built_in_kotlinc/debug/compileDebugKotlin/classes',
    // The Kotlin Gradle Plugin.
    'tmp/kotlin-classes/debug',
  ];
  const fileSaverClass = 'com/iamv4g/file_saver_ffi/FileSaver.class';

  final compiled = [
    for (final output in outputs)
      if (File('${buildDirectory.path}/$output/$fileSaverClass') case final file
          when file.existsSync())
        (directory: Directory('${buildDirectory.path}/$output'), file: file),
  ];
  if (compiled.isEmpty) {
    throw StateError(
      'No compiled $fileSaverClass in ${buildDirectory.path}. Looked in:\n'
      '${outputs.map((output) => '  $output').join('\n')}\n'
      'Has the Android Gradle Plugin moved its Kotlin output?',
    );
  }
  compiled.sort(
    (a, b) => b.file.lastModifiedSync().compareTo(a.file.lastModifiedSync()),
  );
  return compiled.first.directory;
}
