// ignore_for_file: avoid_print

import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';

/// Generates the Kotlin and Swift copies of the values Dart and native code
/// exchange as plain ints and strings: the enums Dart sends as `.index`, the
/// native event types and the error codes.
///
/// Run with:
///   dart run tool/contracts.dart
///
/// after changing any of the Dart declarations in [contracts]. The Dart test
/// `test/tool/contracts_test.dart` fails if the committed files differ from
/// what this generates.
void main() {
  final packageRoot = Platform.script.resolve('../');
  final read = readContracts(packageRoot);
  for (final (path, content) in [
    (kotlinOutput, kotlin(read)),
    (swiftOutput, swift(read)),
  ]) {
    File.fromUri(packageRoot.resolve(path)).writeAsStringSync(content);
    print('Wrote $path');
  }
}

const kotlinOutput =
    'android/src/main/kotlin/com/iamv4g/file_saver_ffi/models/Contracts.g.kt';
const swiftOutput =
    'darwin/file_saver_ffi/Sources/file_saver_ffi/Models/Contracts.g.swift';

/// A Dart declaration whose values Kotlin and Swift need.
sealed class Contract {
  const Contract(this.dartFile, this.dartName, {this.kotlin, this.swift});

  /// The file that declares [dartName], relative to the package root.
  final String dartFile;
  final String dartName;

  /// The name of the Kotlin copy, or null if Kotlin doesn't need it.
  final String? kotlin;

  /// The name of the Swift copy, or null if Swift doesn't need it.
  final String? swift;
}

/// An enum Dart sends as its `.index`. Kotlin gets an enum class with the
/// constants in the same order, Swift an `Int` enum with the index as raw
/// value.
final class EnumContract extends Contract {
  const EnumContract(
    super.dartFile,
    super.dartName, {
    super.kotlin,
    super.swift,
    this.swiftPlatform,
  });

  /// The Swift `os()` condition the Swift enum is compiled for, when iOS and
  /// macOS each have their own enum of the same name.
  final String? swiftPlatform;
}

/// An enum whose `.index` native code sends to Dart. Kotlin and Swift get
/// named constants, to pass where the bridge takes an int.
final class IndexConstantsContract extends Contract {
  const IndexConstantsContract(
    super.dartFile,
    super.dartName, {
    super.kotlin,
    super.swift,
  });
}

/// A class of `static const` strings and ints that native code sends to Dart.
///
/// Kotlin names a string constant after its value, which must be
/// UPPER_SNAKE_CASE, and an int constant after its Dart name; Swift names
/// both after the Dart name.
final class ConstantsContract extends Contract {
  const ConstantsContract(
    super.dartFile,
    super.dartName, {
    super.kotlin,
    super.swift,
  });
}

const contracts = <Contract>[
  IndexConstantsContract(
    'lib/src/platforms/shared/native_event_parser.dart',
    'NativeEventType',
    kotlin: 'EventType',
    swift: 'EventType',
  ),
  ConstantsContract(
    'lib/src/exceptions/file_saver_exceptions.dart',
    'FileSaverErrorCode',
    kotlin: 'ErrorCode',
    swift: 'ErrorCode',
  ),
  ConstantsContract(
    'lib/src/platforms/shared/native_event_parser.dart',
    'NativeWriteSession',
    kotlin: 'WriteSessionReply',
    swift: 'WriteSessionReply',
  ),
  EnumContract(
    'lib/src/models/conflict_resolution.dart',
    'ConflictResolution',
    kotlin: 'ConflictResolution',
    swift: 'ConflictResolution',
  ),
  EnumContract(
    'lib/src/models/locations/save_location.dart',
    'AndroidSaveLocation',
    kotlin: 'SaveLocation',
  ),
  EnumContract(
    'lib/src/models/locations/save_location.dart',
    'IosSaveLocation',
    swift: 'SaveLocation',
    swiftPlatform: 'iOS',
  ),
  EnumContract(
    'lib/src/models/locations/save_location.dart',
    'MacosSaveLocation',
    swift: 'SaveLocation',
    swiftPlatform: 'macOS',
  ),
];

/// The names a [Contract] declares, in declaration order, with their values
/// (a String or an int) for a [ConstantsContract].
typedef ReadContract = ({Contract contract, List<(String, Object?)> values});

/// Reads every contract in [contracts] from the Dart sources under
/// [packageRoot].
List<ReadContract> readContracts(Uri packageRoot) => [
  for (final contract in contracts)
    (
      contract: contract,
      values: readValues(
        File.fromUri(packageRoot.resolve(contract.dartFile)).readAsStringSync(),
        contract,
      ),
    ),
];

/// Reads the values of [contract] from the Dart [source] of its file.
List<(String, Object?)> readValues(String source, Contract contract) {
  final unit = parseString(content: source, throwIfDiagnostics: true).unit;
  final declarations = unit.declarations;
  switch (contract) {
    case EnumContract() || IndexConstantsContract():
      final enumDeclaration = declarations
          .whereType<EnumDeclaration>()
          .where((d) => d.namePart.typeName.lexeme == contract.dartName)
          .firstOrNull;
      if (enumDeclaration == null) {
        throw StateError(
          'No enum ${contract.dartName} in ${contract.dartFile}',
        );
      }
      return [
        for (final c in enumDeclaration.body.constants) (c.name.lexeme, null),
      ];
    case ConstantsContract():
      final classDeclaration = declarations
          .whereType<ClassDeclaration>()
          .where((d) => d.namePart.typeName.lexeme == contract.dartName)
          .firstOrNull;
      if (classDeclaration == null) {
        throw StateError(
          'No class ${contract.dartName} in ${contract.dartFile}',
        );
      }
      return [
        for (final field
            in classDeclaration.body.members.whereType<FieldDeclaration>())
          if (field.isStatic && field.fields.isConst)
            for (final variable in field.fields.variables)
              // Other constants, such as the list FileSaverErrorCode.mapped,
              // aren't copied.
              if (variable.initializer
                  case SimpleStringLiteral(:final Object value) ||
                      IntegerLiteral(:final Object value))
                (variable.name.lexeme, value),
      ];
  }
}

const _header = '''
Generated by tool/contracts.dart from the Dart declarations named below.
Don't edit: change the Dart declaration, then run `dart run tool/contracts.dart`.''';

/// `autoRename` → `AUTO_RENAME`.
String upperSnake(String camel) => camel
    .replaceAllMapped(RegExp('(?<=[a-z0-9])[A-Z]'), (m) => '_${m[0]}')
    .toUpperCase();

/// A string constant's value, such as `FILE_IO_ERROR`, as a Kotlin name.
String _identifierOf(String value) {
  if (!RegExp(r'^[A-Z][A-Z0-9_]*$').hasMatch(value)) {
    throw StateError('$value is not an UPPER_SNAKE_CASE string constant');
  }
  return value;
}

/// [value] as a Kotlin or Swift literal.
String _literal(Object? value) => value is String ? '"$value"' : '$value';

String _source(Contract c) => '`${c.dartName}` (${c.dartFile})';

/// The Kotlin file, in package `com.iamv4g.file_saver_ffi.models`.
String kotlin(List<ReadContract> read) {
  final out = StringBuffer()
    ..writeln(_header.split('\n').map((l) => '// $l').join('\n'))
    ..writeln()
    ..writeln('package com.iamv4g.file_saver_ffi.models');
  for (final (:contract, :values) in read) {
    final name = contract.kotlin;
    if (name == null) continue;
    out.writeln();
    switch (contract) {
      case IndexConstantsContract():
        out
          ..writeln('/** The indices of ${_source(contract)}. */')
          ..writeln('object $name {');
        for (final (i, (value, _)) in values.indexed) {
          out.writeln('    const val ${upperSnake(value)} = $i');
        }
        out.writeln('}');
      case ConstantsContract():
        out
          ..writeln('/** The values of ${_source(contract)}. */')
          ..writeln('object $name {');
        for (final (constant, value) in values) {
          final kotlinName = value is String
              ? _identifierOf(value)
              : upperSnake(constant);
          out.writeln('    const val $kotlinName = ${_literal(value)}');
        }
        out.writeln('}');
      case EnumContract():
        out
          ..writeln(
            '/** ${_source(contract)}, which Dart sends as its index. */',
          )
          ..writeln('enum class $name {');
        for (final (value, _) in values) {
          out.writeln('    ${upperSnake(value)},');
        }
        out
          ..writeln('    ;')
          ..writeln()
          ..writeln('    companion object {')
          ..writeln(
            '        /** The value at [index], or null for an index Dart '
            "doesn't send. */",
          )
          ..writeln(
            '        fun fromIndex(index: Int): $name? = '
            'entries.getOrNull(index)',
          )
          ..writeln('    }')
          ..writeln('}');
    }
  }
  return out.toString();
}

/// The Swift file, in the `file_saver_ffi` module.
String swift(List<ReadContract> read) {
  final out = StringBuffer()
    ..writeln(_header.split('\n').map((l) => '// $l').join('\n'))
    ..writeln()
    ..writeln('import Foundation');
  final entries = [
    for (final r in read)
      if (r.contract.swift != null) r,
  ];
  for (final (index, (:contract, :values)) in entries.indexed) {
    final name = contract.swift!;
    final platform = contract is EnumContract ? contract.swiftPlatform : null;
    final previous = index > 0 ? entries[index - 1].contract : null;
    final next = index + 1 < entries.length
        ? entries[index + 1].contract
        : null;
    bool sameEnum(Contract? other) =>
        other is EnumContract &&
        other.swift == name &&
        other.swiftPlatform != null &&
        platform != null;

    if (platform != null) {
      out
        ..writeln()
        ..writeln(
          sameEnum(previous) ? '#elseif os($platform)' : '#if os($platform)',
        );
    } else {
      out.writeln();
    }
    switch (contract) {
      case IndexConstantsContract():
        out
          ..writeln('/// The indices of ${_source(contract)}.')
          ..writeln('enum $name {');
        for (final (i, (value, _)) in values.indexed) {
          out.writeln('    static let $value: Int64 = $i');
        }
        out.writeln('}');
      case ConstantsContract():
        out
          ..writeln('/// The values of ${_source(contract)}.')
          ..writeln('enum $name {');
        for (final (constant, value) in values) {
          if (value is String) _identifierOf(value);
          out.writeln('    static let $constant = ${_literal(value)}');
        }
        out.writeln('}');
      case EnumContract():
        out
          ..writeln('/// ${_source(contract)}, which Dart sends as its index.')
          ..writeln('enum $name: Int, CaseIterable {');
        for (final (i, (value, _)) in values.indexed) {
          out.writeln('    case $value = $i');
        }
        out.writeln('}');
    }
    if (platform != null && !sameEnum(next)) out.writeln('#endif');
  }
  return out.toString();
}
