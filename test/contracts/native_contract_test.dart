// Guards the cross-language contracts listed in CLAUDE.md that
// tool/contracts.dart doesn't generate (test/tool/contracts_test.dart checks
// what it does): native error codes map back to Dart exceptions, native code
// sends no event type or error code but the generated ones, and native
// messages hold only the detail Dart needs. These tests read the Kotlin and
// Swift sources so drift is caught without building native code.
@TestOn('vm')
library;

import 'dart:io';

import 'package:file_saver_ffi/file_saver_ffi.dart';
import 'package:flutter_test/flutter_test.dart';

const _swiftSources = 'darwin/file_saver_ffi/Sources/file_saver_ffi';

/// The Kotlin and Swift sources, except the files tool/contracts.dart
/// generates.
List<File> _nativeSources() => [
  ...Directory('android/src/main/kotlin')
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.kt')),
  ...Directory(_swiftSources)
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.swift')),
].where((f) => !f.path.contains('Contracts.g.')).toList();

void main() {
  group('error codes', () {
    void expectAllMapped(Iterable<String> codes) {
      expect(codes, isNotEmpty);
      for (final code in codes) {
        final e = FileSaverException.fromErrorResult(code, 'details');
        expect(e.code, code, reason: '$code maps to ${e.runtimeType}');
        if (code != FileSaverErrorCode.platform) {
          expect(e, isNot(isA<NativePlatformException>()), reason: code);
        }
      }
    }

    test('every FileSaverErrorCode maps to a dedicated exception', () {
      expectAllMapped(FileSaverErrorCode.mapped);
    });

    // The Dart exceptions add these to the detail native code sends (see
    // FileSaverErrorCode), so a native message that has them shows them twice.
    test('native messages leave out the prefixes Dart adds', () {
      const prefixes = [
        'File already exists',
        'Source file not found',
        'Invalid input:',
        'Network error:',
        'Network download failed',
        'iCloud download failed',
        'iCloud file download failed',
      ];
      final sources = _nativeSources();
      expect(sources, isNotEmpty);
      for (final file in sources) {
        final source = file.readAsStringSync();
        for (final prefix in prefixes) {
          expect(
            source.contains('"$prefix'),
            isFalse,
            reason: '${file.path} sends "$prefix…"',
          );
        }
      }
    });
  });

  // Kotlin and Swift take these from the files tool/contracts.dart generates
  // (EventType, ErrorCode), whose test checks them against Dart.
  group('native code uses the generated contracts', () {
    test('for the event type of every event it sends', () {
      final literal = RegExp(r'onEvent\(\s*\d|createInt\(\s*\d');
      for (final file in _nativeSources()) {
        expect(
          literal.hasMatch(file.readAsStringSync()),
          isFalse,
          reason: '${file.path} sends an event type as a number',
        );
      }
    });

    test('for every error code', () {
      final codes = {
        ...FileSaverErrorCode.mapped,
        FileSaverErrorCode.platform,
        FileSaverErrorCode.incomplete,
      };
      for (final file in _nativeSources()) {
        final source = file.readAsStringSync();
        for (final code in codes) {
          expect(
            source.contains('"$code"'),
            isFalse,
            reason: '${file.path} has "$code" instead of ErrorCode',
          );
        }
      }
    });
  });
}
