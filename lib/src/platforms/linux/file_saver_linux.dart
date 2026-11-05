import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../exceptions/file_saver_exceptions.dart';
import '../../models/locations/save_location.dart';
import '../../platform_interface/file_saver_platform.dart';
import '../shared/desktop_file_saver.dart';

/// Runs an executable, as [Process.run] does.
typedef ProcessRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments,
);

/// FileSaver implementation for Linux.
///
/// Extends [DesktopFileSaver] — only [resolveDirectory] and [launchFile] are
/// platform-specific.
///
/// Each [LinuxSaveLocation] is the XDG user directory that `xdg-user-dir`
/// reports, looked up once per location. When it reports none (the key isn't
/// configured, or set to `$HOME`, which disables it) or isn't installed, the
/// location falls back to its usual folder in `$HOME`: `~/Downloads`,
/// `~/Pictures`, `~/Videos`, `~/Music` or `~/Documents`.
class FileSaverLinux extends DesktopFileSaver<LinuxSaveLocation> {
  FileSaverLinux({
    @visibleForTesting ProcessRunner? runProcess,
    @visibleForTesting Map<String, String>? environment,
    @visibleForTesting super.pathLocationWriter,
  }) : _runProcess = runProcess ?? Process.run,
       _environment = environment ?? Platform.environment;

  /// Registers this class as the default instance of [FileSaverPlatform].
  static void registerWith() {
    FileSaverPlatform.instance = FileSaverLinux();
  }

  final ProcessRunner _runProcess;
  final Map<String, String> _environment;

  /// The directory of each location, once looked up.
  final _userDirectories = <LinuxSaveLocation, Future<String>>{};

  @override
  Future<String> resolveDirectory(
    LinuxSaveLocation? saveLocation,
    String? subDir,
  ) async {
    final location = saveLocation ?? LinuxSaveLocation.downloads;
    final basePath = await (_userDirectories[location] ??=
        _userDirectory(location).catchError((Object e, StackTrace st) {
          // Looked up again by the next save. The removed future is this
          // one, which the caller awaits.
          unawaited(_userDirectories.remove(location));
          Error.throwWithStackTrace(e, st);
        }));

    final dirPath = subDir != null ? p.join(basePath, subDir) : basePath;
    await Directory(dirPath).create(recursive: true);
    return dirPath;
  }

  /// Opens [path] with `xdg-open`. [Process.run] executes it directly (no
  /// shell), so the path reaches `xdg-open` as a single argument.
  @override
  Future<void> launchFile(String path) async {
    final result = await _runProcess('xdg-open', [path]);
    if (result.exitCode != 0) {
      throw OpenFailedException(
        'exitCode=${result.exitCode} stdout=${result.stdout} stderr=${result.stderr}',
      );
    }
  }

  Future<String> _userDirectory(LinuxSaveLocation location) async {
    final (key, folder) = switch (location) {
      LinuxSaveLocation.downloads => ('DOWNLOAD', 'Downloads'),
      LinuxSaveLocation.pictures => ('PICTURES', 'Pictures'),
      LinuxSaveLocation.videos => ('VIDEOS', 'Videos'),
      LinuxSaveLocation.music => ('MUSIC', 'Music'),
      LinuxSaveLocation.documents => ('DOCUMENTS', 'Documents'),
    };
    final home = _environment['HOME'];
    final hasHome = home != null && p.isAbsolute(home);

    final configured = await _xdgUserDir(key);
    // xdg-user-dir prints $HOME for a key that isn't set, and $HOME is also
    // how a directory is disabled.
    if (configured != null &&
        p.isAbsolute(configured) &&
        !(hasHome && p.equals(configured, home))) {
      return configured;
    }

    if (!hasHome) {
      throw NativePlatformException(
        'Could not resolve the $folder directory: xdg-user-dir has no '
        'XDG_${key}_DIR and HOME is not set.',
      );
    }
    return p.join(home, folder);
  }

  /// The first line `xdg-user-dir` prints for [key], or null when it fails
  /// or isn't installed.
  Future<String?> _xdgUserDir(String key) async {
    try {
      final result = await _runProcess('xdg-user-dir', [key]);
      if (result.exitCode != 0) return null;
      return (result.stdout as String).split('\n').first;
    } on ProcessException {
      return null;
    }
  }
}
