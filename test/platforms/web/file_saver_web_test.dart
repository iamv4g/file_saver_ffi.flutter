@TestOn('browser')
library;

import 'package:file_saver_ffi/file_saver_ffi.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final saver = FileSaverWeb();

  test('directory persistence is unsupported', () {
    expect(
      () => saver.persistDirectory(PickedDirectoryLocation(uri: Uri())),
      throwsUnsupportedError,
    );
    expect(() => saver.restoreDirectory('token'), throwsUnsupportedError);
    expect(() => saver.releaseDirectory('token'), throwsUnsupportedError);
  });
}
