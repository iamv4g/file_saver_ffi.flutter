import 'dart:io';

import 'package:path/path.dart' as p;

import '../../exceptions/file_saver_exceptions.dart';

/// Characters Windows doesn't allow in a file name, besides control
/// characters.
final _windowsReserved = RegExp(r'[<>:"/\\|?*\x00-\x1F]');

/// Names of Windows devices, with or without an extension (`CON.txt`).
final _windowsDevice = RegExp(
  r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\..*)?$',
  caseSensitive: false,
);

/// Throws [InvalidInputException] unless [name] can be the name of a file in
/// a directory: not `.` or `..`, without `/` or NUL, and on Windows without
/// `\ < > : " | ? *`, control characters or a device name such as `CON`.
///
/// [windows] defaults to the running platform.
void checkFileName(String name, {bool? windows}) {
  windows ??= Platform.isWindows;
  if (name == '.' || name == '..') {
    throw InvalidInputException('"$name" is not a valid file name.');
  }
  final invalid = windows
      ? _windowsReserved.firstMatch(name)?.group(0)
      : (name.contains('/') ? '/' : (name.contains('\x00') ? r'\0' : null));
  if (invalid != null) {
    throw InvalidInputException(
      'File name "$name" contains "${_describe(invalid)}", which is not '
      'allowed in a file name on this platform.',
    );
  }
  if (windows && _windowsDevice.hasMatch(name)) {
    throw InvalidInputException(
      'File name "$name" is reserved for a device on Windows.',
    );
  }
}

/// Throws [InvalidInputException] unless [subDir] is a relative path that
/// stays inside the directory it is joined to: no root or drive, no `..`
/// segment, and every segment a valid name for [checkFileName].
///
/// [windows] defaults to the running platform. `\` separates segments there.
void checkSubDir(String? subDir, {bool? windows}) {
  if (subDir == null || subDir.isEmpty) return;
  windows ??= Platform.isWindows;
  final context = windows ? p.windows : p.posix;
  if (context.rootPrefix(subDir).isNotEmpty) {
    throw InvalidInputException(
      'subDir "$subDir" must be a relative path, not an absolute one.',
    );
  }
  for (final segment in subDir.split(windows ? RegExp(r'[/\\]') : '/')) {
    if (segment.isEmpty || segment == '.') continue;
    if (segment == '..') {
      throw InvalidInputException(
        'subDir "$subDir" must not contain "..": it would leave the save '
        'location.',
      );
    }
    try {
      checkFileName(segment, windows: windows);
    } on InvalidInputException catch (e) {
      throw InvalidInputException('subDir "$subDir": ${e.message}');
    }
  }
}

String _describe(String character) {
  final code = character.codeUnitAt(0);
  return code < 0x20 && character.length == 1
      ? 'control character 0x${code.toRadixString(16).padLeft(2, '0')}'
      : character;
}
