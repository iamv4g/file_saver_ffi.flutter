import 'dart:io';

import 'package:ffigen/ffigen.dart';

/// Generates FFI bindings for Darwin (iOS/macOS) native classes.
///
/// Run with:
///   dart run tool/ffigen.dart
void main() {
  final packageRoot = Platform.script.resolve('../');
  final headerUri = packageRoot.resolve(
    'darwin/file_saver_ffi/Sources/file_saver_ffi/FFI/file_saver_ffi.h',
  );
  FfiGenerator(
    output: Output(
      dartFile: packageRoot.resolve('lib/src/platforms/darwin/bindings.g.dart'),
      style: DynamicLibraryBindings(wrapperName: 'FileSaverFFI'),
      // preamble: '''
      //           // ignore_for_file: always_specify_types
      //           // ignore_for_file: camel_case_types
      //           // ignore_for_file: non_constant_identifier_names

      //           ''',
      commentType: CommentType(CommentStyle.any, CommentLength.full),
    ),
    headers: Headers(
      entryPoints: [headerUri],
      include: (uri) => uri == headerUri,
    ),
    functions: Functions(
      include: Declarations.includeSet({
        'file_saver_init',
        'file_saver_init_dart_api_dl',
        'file_saver_save_bytes',
        'file_saver_save_file',
        'file_saver_save_network',
        'file_saver_pick_directory',
        'file_saver_save_bytes_as',
        'file_saver_save_file_as',
        'file_saver_save_network_as',
        'file_saver_cancel',
        'file_saver_dispose',
        'file_saver_open_file',
        'file_saver_can_open_file',
        'file_saver_open_write',
        'file_saver_open_write_as',
        'file_saver_write_chunk',
        'file_saver_flush_write',
        'file_saver_close_write',
        'file_saver_cancel_write',
      }),
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
