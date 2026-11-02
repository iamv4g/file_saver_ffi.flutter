import 'package:file_saver_ffi/file_saver_ffi.dart';
import 'package:file_saver_ffi/src/platforms/shared/file_name.dart';
import 'package:flutter_test/flutter_test.dart';

final _invalid = throwsA(isA<InvalidInputException>());

void main() {
  group('checkFileName', () {
    test('accepts ordinary names on both platforms', () {
      for (final windows in [false, true]) {
        for (final name in ['photo.png', '.env', 'a b (1).tar.gz', 'ảnh.jpg']) {
          expect(() => checkFileName(name, windows: windows), returnsNormally);
        }
      }
    });

    test('rejects . and .. and a separator on both platforms', () {
      for (final windows in [false, true]) {
        for (final name in ['.', '..', 'a/b.txt', '../a.txt']) {
          expect(
            () => checkFileName(name, windows: windows),
            _invalid,
            reason: '$name, windows: $windows',
          );
        }
      }
      expect(() => checkFileName('a\x00b.txt', windows: false), _invalid);
    });

    test('rejects characters and device names only Windows forbids', () {
      for (final name in [
        r'a\b.txt',
        'a<b.txt',
        'a>b.txt',
        'a:b.txt',
        'a"b.txt',
        'a|b.txt',
        'a?b.txt',
        'a*b.txt',
        'a\tb.txt',
        'CON',
        'con.txt',
        'LPT1.log',
        'nul.tar.gz',
      ]) {
        expect(
          () => checkFileName(name, windows: true),
          _invalid,
          reason: name,
        );
        expect(() => checkFileName(name, windows: false), returnsNormally);
      }
      // Only the whole first part is a device name.
      expect(
        () => checkFileName('console.txt', windows: true),
        returnsNormally,
      );
      expect(() => checkFileName('COM10.txt', windows: true), returnsNormally);
    });

    test('names the character in the message', () {
      expect(
        () => checkFileName('a?b.txt', windows: true),
        throwsA(
          isA<InvalidInputException>().having(
            (e) => e.message,
            'message',
            contains('"?"'),
          ),
        ),
      );
    });
  });

  group('checkSubDir', () {
    test('accepts null, empty and nested relative paths', () {
      for (final windows in [false, true]) {
        for (final subDir in [null, '', 'album', 'a/b', 'a/./b', 'a//b']) {
          expect(
            () => checkSubDir(subDir, windows: windows),
            returnsNormally,
            reason: '$subDir',
          );
        }
      }
      expect(() => checkSubDir(r'a\b', windows: true), returnsNormally);
    });

    test('rejects an absolute path and .. on both platforms', () {
      for (final windows in [false, true]) {
        for (final subDir in ['/etc', '..', '../x', 'a/../../x']) {
          expect(
            () => checkSubDir(subDir, windows: windows),
            _invalid,
            reason: '$subDir, windows: $windows',
          );
        }
      }
    });

    test('rejects a drive, a UNC path and a backslash .. on Windows', () {
      for (final subDir in [r'C:\x', 'C:x', r'\\server\share', r'..\x']) {
        expect(
          () => checkSubDir(subDir, windows: true),
          _invalid,
          reason: subDir,
        );
      }
    });

    test('rejects a segment that is not a valid name', () {
      expect(() => checkSubDir('a/b?c', windows: true), _invalid);
      expect(() => checkSubDir('a/b?c', windows: false), returnsNormally);
    });
  });
}
