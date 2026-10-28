// ignore_for_file: avoid_print

import 'dart:io';

/// Checks that a release APK still has every class, method and field that
/// the JNI bindings look up by name, after R8 shrank and obfuscated it.
///
/// Run after building one:
///   (cd example && flutter build apk --release)
///   dart run tool/check_jni_keeps.dart example/build/app/outputs/flutter-apk/app-release.apk
///
/// Needs `dexdump` from the Android SDK build-tools (found through
/// `ANDROID_HOME` or `ANDROID_SDK_ROOT`).
void main(List<String> args) {
  if (args.length != 1) {
    stderr.writeln(
      'Usage: dart run tool/check_jni_keeps.dart <app-release.apk>',
    );
    exit(64);
  }

  final bindings = File.fromUri(
    Platform.script.resolve('../$bindingsPath'),
  ).readAsStringSync();
  final expected = jniLookups(bindings);
  if (expected.isEmpty) {
    stderr.writeln('Found no JNI lookups in the bindings; did they move?');
    exit(1);
  }

  final dex = Process.runSync(_dexdump(), [args.single]);
  if (dex.exitCode != 0) {
    stderr.writeln('dexdump failed:\n${dex.stderr}');
    exit(1);
  }
  final present = dexMembers(dex.stdout as String);

  final missing = expected.difference(present);
  for (final member in expected) {
    print('${missing.contains(member) ? 'MISSING' : 'ok     '} $member');
  }
  if (missing.isNotEmpty) {
    stderr.writeln(
      '\n${missing.length} of ${expected.length} JNI lookups are missing from '
      'the release APK. R8 removed or renamed them: check '
      'android/proguard-rules.pro.',
    );
    exit(1);
  }
  print('\nAll ${expected.length} JNI lookups are in the release APK.');
}

/// The jnigen bindings, relative to the package root.
const bindingsPath = 'lib/src/platforms/android/bindings.g.dart';

/// The classes (`Lpkg/Name;`) and members (`Lpkg/Name;->name:type`) that the
/// generated bindings look up.
Set<String> jniLookups(String bindings) {
  final lookups = <String>{};
  final classOf = <String, String>{};
  String? current;

  final tokens = RegExp(
    r"extension type ([\w$]+)\._\("
    r"|JClass\.forName\(\s*r'([^']+)'"
    r"|(?:([\w$]+)\.)?_class\s*\.(constructorId|(?:static|instance)(?:Method|Field)Id)\(\s*r'([^']*)'(?:\s*,\s*r'([^']*)')?",
  );
  for (final match in tokens.allMatches(bindings)) {
    if (match[1] != null) {
      current = match[1];
    } else if (match[2] != null) {
      final descriptor = 'L${match[2]};';
      classOf[current!] = descriptor;
      lookups.add(descriptor);
    } else {
      final owner = classOf[match[3] ?? current]!;
      final (name, type) = match[4] == 'constructorId'
          ? ('<init>', match[5]!)
          : (match[5]!, match[6]!);
      lookups.add('$owner->$name:$type');
    }
  }
  return lookups;
}

/// The classes and members in `dexdump` output, in the same format as
/// [jniLookups].
Set<String> dexMembers(String dexdump) => {
  for (final match in RegExp(
    r"Class descriptor\s*:\s*'([^']+)'",
  ).allMatches(dexdump))
    match[1]!,
  for (final match in RegExp(
    r"\(in (L[^;]+;)\)\s*\n\s*name\s*:\s*'([^']+)'\s*\n\s*type\s*:\s*'([^']+)'",
  ).allMatches(dexdump))
    '${match[1]}->${match[2]}:${match[3]}',
};

String _dexdump() {
  final sdk =
      Platform.environment['ANDROID_HOME'] ??
      Platform.environment['ANDROID_SDK_ROOT'];
  final buildTools = sdk == null ? null : Directory('$sdk/build-tools');
  if (buildTools == null || !buildTools.existsSync()) {
    stderr.writeln('Set ANDROID_HOME to an Android SDK with build-tools.');
    exit(1);
  }
  final versions = buildTools.listSync().whereType<Directory>().toList()
    ..sort((a, b) => _compareVersions(a.path, b.path));
  final name = Platform.isWindows ? 'dexdump.exe' : 'dexdump';
  for (final version in versions.reversed) {
    final dexdump = File('${version.path}/$name');
    if (dexdump.existsSync()) return dexdump.path;
  }
  stderr.writeln('No dexdump found in ${buildTools.path}.');
  exit(1);
}

int _compareVersions(String a, String b) {
  List<int> parts(String path) => path
      .split(RegExp(r'[/\\]'))
      .last
      .split(RegExp(r'\D+'))
      .where((part) => part.isNotEmpty)
      .map(int.parse)
      .toList();
  final pa = parts(a), pb = parts(b);
  for (var i = 0; i < pa.length && i < pb.length; i++) {
    if (pa[i] != pb[i]) return pa[i].compareTo(pb[i]);
  }
  return pa.length.compareTo(pb.length);
}
