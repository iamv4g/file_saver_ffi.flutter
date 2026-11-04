@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:file_saver_ffi/file_saver_ffi.dart';
import 'package:file_saver_ffi/platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory home;

  /// What `xdg-user-dir` prints for each key; a missing key exits with 1.
  late Map<String, String> xdgOutput;

  /// The keys `xdg-user-dir` was run with, in order.
  late List<String> xdgCalls;

  /// Thrown instead of running `xdg-user-dir` when set.
  Object? runError;

  setUp(() async {
    home = await Directory.systemTemp.createTemp('file_saver_linux_test');
    xdgOutput = {};
    xdgCalls = [];
    runError = null;
  });

  tearDown(() => home.delete(recursive: true));

  FileSaverLinux saver({Map<String, String>? environment}) => FileSaverLinux(
    environment: environment ?? {'HOME': home.path},
    runProcess: (executable, arguments) async {
      expect(executable, 'xdg-user-dir');
      xdgCalls.add(arguments.single);
      if (runError case final error?) throw error;
      final output = xdgOutput[arguments.single];
      return ProcessResult(0, output == null ? 1 : 0, output ?? '', '');
    },
  );

  String inHome(String relative) => p.join(home.path, relative);

  test('uses the directory xdg-user-dir reports, and creates subDir', () async {
    xdgOutput['PICTURES'] = '${inHome('Bilder')}\n';

    final dir = await saver().resolveDirectory(
      LinuxSaveLocation.pictures,
      'album',
    );

    expect(dir, p.join(inHome('Bilder'), 'album'));
    expect(Directory(dir).existsSync(), isTrue);
    expect(xdgCalls, ['PICTURES']);
  });

  test('null is the download directory', () async {
    xdgOutput['DOWNLOAD'] = inHome('Tải xuống');

    expect(await saver().resolveDirectory(null, null), inHome('Tải xuống'));
  });

  test('each location falls back to its own folder in HOME', () async {
    final linux = saver();
    for (final (location, folder) in [
      (LinuxSaveLocation.downloads, 'Downloads'),
      (LinuxSaveLocation.pictures, 'Pictures'),
      (LinuxSaveLocation.videos, 'Videos'),
      (LinuxSaveLocation.music, 'Music'),
      (LinuxSaveLocation.documents, 'Documents'),
    ]) {
      expect(await linux.resolveDirectory(location, null), inHome(folder));
    }
  });

  test(
    'HOME, an empty line or a relative path from xdg-user-dir falls back',
    () async {
      for (final output in [
        '${home.path}\n',
        '${home.path}/\n',
        '\n',
        'Videos\n',
      ]) {
        xdgOutput['VIDEOS'] = output;
        expect(
          await saver().resolveDirectory(LinuxSaveLocation.videos, null),
          inHome('Videos'),
          reason: output,
        );
      }
    },
  );

  test('a missing xdg-user-dir falls back', () async {
    runError = const ProcessException('xdg-user-dir', [], 'not found', 2);

    expect(
      await saver().resolveDirectory(LinuxSaveLocation.music, null),
      inHome('Music'),
    );
  });

  test('each location is looked up once', () async {
    xdgOutput['DOCUMENTS'] = inHome('Docs');
    final linux = saver();

    for (var i = 0; i < 3; i++) {
      await linux.resolveDirectory(LinuxSaveLocation.documents, 'sub$i');
      await linux.resolveDirectory(LinuxSaveLocation.downloads, null);
    }

    expect(xdgCalls, ['DOCUMENTS', 'DOWNLOAD']);
  });

  test(
    'without HOME and an XDG directory it throws, and looks up again',
    () async {
      final linux = saver(environment: {});

      await expectLater(
        linux.resolveDirectory(LinuxSaveLocation.downloads, null),
        throwsA(isA<NativePlatformException>()),
      );
      expect(Directory('Downloads').existsSync(), isFalse);

      xdgOutput['DOWNLOAD'] = inHome('Downloads');
      expect(
        await linux.resolveDirectory(LinuxSaveLocation.downloads, null),
        inHome('Downloads'),
      );
      expect(xdgCalls, ['DOWNLOAD', 'DOWNLOAD']);
    },
  );

  test(
    'with the real xdg-user-dir, a set key is used and an unset or disabled '
    'one falls back',
    () async {
      final config = Directory(inHome('.config'))..createSync();
      File(p.join(config.path, 'user-dirs.dirs')).writeAsStringSync(
        'XDG_PICTURES_DIR="\$HOME/Bilder"\n'
        'XDG_MUSIC_DIR="\$HOME/"\n',
      );
      final linux = FileSaverLinux(
        environment: {'HOME': home.path},
        runProcess: (executable, arguments) => Process.run(
          executable,
          arguments,
          environment: {'HOME': home.path, 'XDG_CONFIG_HOME': config.path},
        ),
      );

      expect(
        await linux.resolveDirectory(LinuxSaveLocation.pictures, null),
        inHome('Bilder'),
      );
      // xdg-user-dir prints $HOME for both.
      expect(
        await linux.resolveDirectory(LinuxSaveLocation.downloads, null),
        inHome('Downloads'),
      );
      expect(
        await linux.resolveDirectory(LinuxSaveLocation.music, null),
        inHome('Music'),
      );
    },
    skip:
        Platform.isLinux &&
            Process.runSync('sh', ['-c', 'command -v xdg-user-dir']).exitCode ==
                0
        ? false
        : 'needs xdg-user-dir (Linux)',
  );

  test('a save lands in the resolved directory', () async {
    xdgOutput['DOWNLOAD'] = inHome('Downloads');
    FileSaverPlatform.instance = saver();

    final uri = await FileSaver.saveAsync(
      input: SaveInput.bytes(Uint8List.fromList([1, 2, 3])),
      fileName: 'a',
      fileType: const CustomFileType(
        ext: 'bin',
        mimeType: 'application/octet-stream',
      ),
      saveLocation: LinuxSaveLocation.downloads,
    );

    expect(p.equals(uri.toFilePath(), inHome('Downloads/a.bin')), isTrue);
    expect(File(inHome('Downloads/a.bin')).readAsBytesSync(), [1, 2, 3]);
  });
}
