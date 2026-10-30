// Guards the cross-language contracts listed in CLAUDE.md: Dart sends enum
// `.index` values over the bridge as plain ints, and native error code
// strings are mapped back to Dart exceptions. These tests read the Kotlin and
// Swift sources so drift is caught without building native code.
@TestOn('vm')
library;

import 'dart:io';

import 'package:file_saver_ffi/file_saver_ffi.dart';
import 'package:flutter_test/flutter_test.dart';

const _kotlinModels =
    'android/src/main/kotlin/com/iamv4g/file_saver_ffi/models';
const _kotlinConstants =
    'android/src/main/kotlin/com/iamv4g/file_saver_ffi/utils/Constants.kt';
const _swiftSources = 'darwin/file_saver_ffi/Sources/file_saver_ffi';

String _read(String path) => File(path).readAsStringSync();

/// `autoRename` -> `AUTO_RENAME`.
String _upperSnake(String camel) =>
    camel.replaceAllMapped(RegExp('[A-Z]'), (m) => '_${m[0]}').toUpperCase();

/// Parses `case name = 0` lines into `{name: 0}`.
Map<String, int> _swiftRawValues(String source) => {
  for (final m in RegExp(r'case (\w+) = (\d+)').allMatches(source))
    m[1]!: int.parse(m[2]!),
};

Map<String, int> _dartIndices(List<Enum> values) => {
  for (final v in values) v.name: v.index,
};

void main() {
  group('ConflictResolution', () {
    test('matches Kotlin values', () {
      final source = _read('$_kotlinModels/ConflictResolution.kt');
      final kotlin = {
        for (final m in RegExp(r'([A-Z_]+)\((\d+)\)').allMatches(source))
          m[1]!: int.parse(m[2]!),
      };
      expect(kotlin, {
        for (final v in ConflictResolution.values) _upperSnake(v.name): v.index,
      });
    });

    test('matches Swift raw values', () {
      final source = _read('$_swiftSources/Models/ConflictResolution.swift');
      expect(_swiftRawValues(source), _dartIndices(ConflictResolution.values));
    });
  });

  group('SaveLocation', () {
    test('AndroidSaveLocation matches Kotlin ordinals', () {
      final source = _read('$_kotlinModels/SaveLocation.kt');
      final body = source.substring(
        source.indexOf('{') + 1,
        source.indexOf('companion object'),
      );
      final kotlin = RegExp(
        r'^\s*([A-Z_]+),',
        multiLine: true,
      ).allMatches(body).map((m) => m[1]).toList();
      expect(
        kotlin,
        AndroidSaveLocation.values.map((v) => _upperSnake(v.name)).toList(),
      );
    });

    test('IosSaveLocation and MacosSaveLocation match Swift raw values', () {
      final source = _read('$_swiftSources/Models/SaveLocation.swift');
      final split = source.indexOf('#elseif os(macOS)');
      expect(split, isNot(-1), reason: 'expected iOS/macOS #if blocks');

      expect(
        _swiftRawValues(source.substring(0, split)),
        _dartIndices(IosSaveLocation.values),
      );
      expect(
        _swiftRawValues(source.substring(split)),
        _dartIndices(MacosSaveLocation.values),
      );
    });
  });

  group('error codes', () {
    void expectAllMapped(Iterable<String> codes) {
      expect(codes, isNotEmpty);
      for (final code in codes) {
        final e = FileSaverException.fromErrorResult(code, 'details');
        expect(e.code, code, reason: '$code maps to ${e.runtimeType}');
        if (code != 'PLATFORM_ERROR') {
          expect(e, isNot(isA<NativePlatformException>()), reason: code);
        }
      }
    }

    test('every Kotlin error code maps to a dedicated exception', () {
      final source = _read(_kotlinConstants);
      expectAllMapped(
        RegExp(r'ERROR_\w+ = "(\w+)"').allMatches(source).map((m) => m[1]!),
      );
    });

    test('every Swift error code maps to a dedicated exception', () {
      final source = _read('$_swiftSources/Utils/Constants.swift');
      expectAllMapped(
        RegExp(r'error\w+ = "(\w+)"').allMatches(source).map((m) => m[1]!),
      );
    });
  });
}
