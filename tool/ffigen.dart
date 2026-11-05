import 'dart:io';

import 'package:ffigen/ffigen.dart';

/// Generates FFI bindings for Darwin (iOS/macOS) native classes.
///
/// Run with:
///   dart run tool/ffigen.dart
///
/// CI runs it and fails if `bindings.g.dart` changes.
void main() {
  final packageRoot = Platform.script.resolve('../');
  final headerUri = packageRoot.resolve(
    'darwin/file_saver_ffi/Sources/file_saver_ffi/FFI/file_saver_ffi.h',
  );
  FfiGenerator(
    output: Output(
      dartFile: packageRoot.resolve('lib/src/platforms/darwin/bindings.g.dart'),
      style: DynamicLibraryBindings(wrapperName: 'FileSaverFFI'),
      commentType: CommentType(CommentStyle.any, CommentLength.full),
    ),
    headers: Headers(
      entryPoints: [headerUri],
      include: (uri) => uri == headerUri,
    ),
    functions: Functions(
      // Every function the header declares: each one is a Swift `@_cdecl`.
      include: (_) => true,
      // For the NativeFinalizer of DarwinFileSaverSink.
      includeSymbolAddress: (decl) =>
          decl.originalName == 'file_saver_finalize_write',
      rename: (decl) {
        final stripped = decl.originalName.replaceFirst('file_saver_', '');
        return stripped.replaceAllMapped(
          RegExp(r'_([a-z])'),
          (m) => m.group(1)!.toUpperCase(),
        );
      },
    ),
  ).generate();
}
