@TestOn('vm')
library;

import 'dart:io';

import 'package:file_saver_ffi/file_saver_ffi.dart';
import 'package:file_saver_ffi/src/platforms/shared/native_event_parser.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../tool/contracts.dart';

void main() {
  final packageRoot = Directory.current.uri;
  final read = readContracts(packageRoot);

  List<(String, Object?)> valuesOf(String dartName) =>
      read.singleWhere((r) => r.contract.dartName == dartName).values;

  /// [path] with `\n` line ends, as git may check it out with `\r\n` on
  /// Windows.
  String committed(String path) =>
      File.fromUri(packageRoot.resolve(path))
          .readAsStringSync()
          .replaceAll('\r\n', '\n');

  test('the committed Kotlin and Swift files are what it generates', () {
    const hint = 'Run `dart run tool/contracts.dart`, and commit the result.';
    expect(committed(kotlinOutput), kotlin(read), reason: hint);
    expect(committed(swiftOutput), swift(read), reason: hint);
  });

  test('reads every enum in index order, as Dart sends it', () {
    for (final values in <List<Enum>>[
      NativeEventType.values,
      ConflictResolution.values,
      AndroidSaveLocation.values,
      IosSaveLocation.values,
      MacosSaveLocation.values,
    ]) {
      final dartName = values.first.runtimeType.toString();
      expect(
        valuesOf(dartName).map((v) => v.$1),
        values.map((v) => v.name),
        reason: dartName,
      );
    }
  });

  test('reads every FileSaverErrorCode', () {
    expect(valuesOf('FileSaverErrorCode').map((v) => v.$2).toSet(), {
      ...FileSaverErrorCode.mapped,
      FileSaverErrorCode.platform,
      FileSaverErrorCode.incomplete,
    });
  });

  test('reads the write session reply values', () {
    expect(valuesOf('NativeWriteSession'), [
      ('skippedId', NativeWriteSession.skippedId),
    ]);
  });

  group('generates', () {
    test('Kotlin enums with the Dart order, and named constants', () {
      final source = kotlin(read);
      expect(
        source,
        contains(
          'enum class SaveLocation {\n'
          '    PICTURES,\n'
          '    MOVIES,\n'
          '    MUSIC,\n'
          '    DOWNLOADS,\n'
          '    DCIM,\n'
          '    ;\n',
        ),
      );
      expect(source, contains('    const val SUCCESS = 3\n'));
      expect(
        source,
        contains('    const val FILE_IO_ERROR = "FILE_IO_ERROR"\n'),
      );
    });

    test('Swift enums with the index as raw value, one per Apple OS', () {
      final source = swift(read);
      expect(
        source,
        contains(
          '#if os(iOS)\n'
          '/// `IosSaveLocation` (lib/src/models/locations/save_location.dart), '
          'which Dart sends as its index.\n'
          'enum SaveLocation: Int, CaseIterable {\n'
          '    case documents = 0\n'
          '    case photos = 1\n'
          '}\n'
          '\n'
          '#elseif os(macOS)\n',
        ),
      );
      expect(source.trimRight(), endsWith('#endif'));
      expect(source, contains('    static let success: Int64 = 3\n'));
      expect(source, contains('    static let fileIO = "FILE_IO_ERROR"\n'));
    });
  });

  group('readValues', () {
    const enumContract = EnumContract('a.dart', 'Mode', kotlin: 'Mode');
    const codes = ConstantsContract('a.dart', 'Codes', kotlin: 'Codes');

    test('reads only the static const strings and ints of a class', () {
      const source = '''
abstract final class Codes {
  static const first = 'FIRST';
  static const count = 2;
  static const list = [first];
  static final notConst = 'NOT_CONST';
  final String instance = 'INSTANCE';
}
''';
      expect(readValues(source, codes), [('first', 'FIRST'), ('count', 2)]);
    });

    test('names Kotlin strings after their value, ints after their name', () {
      final source = kotlin([
        (
          contract: codes,
          values: [('fileIO', 'FILE_IO_ERROR'), ('maxSize', 2)],
        ),
      ]);
      expect(
        source,
        contains('    const val FILE_IO_ERROR = "FILE_IO_ERROR"\n'),
      );
      expect(source, contains('    const val MAX_SIZE = 2\n'));
    });

    test('fails naming a declaration it can not find', () {
      expect(
        () => readValues('enum Other { a }', enumContract),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'No enum Mode in a.dart',
          ),
        ),
      );
    });

    test('rejects an error code that is not UPPER_SNAKE_CASE', () {
      final values = readValues(
        "abstract final class Codes { static const bad = 'bad-code'; }",
        codes,
      );
      expect(
        () => kotlin([(contract: codes, values: values)]),
        throwsA(isA<StateError>()),
      );
    });
  });

  test('upperSnake', () {
    expect(upperSnake('autoRename'), 'AUTO_RENAME');
    expect(upperSnake('dcim'), 'DCIM');
    expect(upperSnake('started'), 'STARTED');
  });
}
