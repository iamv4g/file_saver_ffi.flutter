import 'dart:io';

import 'package:ffigen/ffigen.dart';

/// Generates FFI bindings for Darwin (iOS/macOS) native classes.
///
/// Run with:
///   dart run tool/ffigen.dart
///
/// CI runs it and fails if `bindings.g.dart` changes.
Future<void> main() async {
  final packageRoot = Platform.script.resolve('../');
  final headerUri = packageRoot.resolve(
    'darwin/file_saver_ffi/Sources/file_saver_ffi/FFI/file_saver_ffi.h',
  );
  await FfiGenerator(
    output: Output(
      dart: DartOutput(
        path: packageRoot.resolve('lib/src/platforms/darwin/bindings.g.dart'),
      ),
      style: const DynamicLibraryBindings(wrapperName: 'FileSaverFFI'),
      commentType: const CommentType(CommentStyle.any, CommentLength.full),
    ),
    input: Input(entryPoints: [headerUri], include: (uri) => uri == headerUri),
    visitors: [
      Visitor(
        func: (func) {
          // Every function the header declares: each one is a Swift
          // `@_cdecl`.
          func
            ..isIncluded = true
            // For the NativeFinalizer of DarwinFileSaverSink.
            ..exposeSymbolAddress =
                func.originalName == 'file_saver_finalize_write'
            ..name = func.originalName
                .replaceFirst('file_saver_', '')
                .replaceAllMapped(
                  RegExp('_([a-z])'),
                  (m) => m.group(1)!.toUpperCase(),
                );
        },
      ),
    ],
  ).generate();
}
