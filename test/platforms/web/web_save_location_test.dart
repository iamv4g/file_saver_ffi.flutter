@TestOn('browser')
library;

import 'dart:js_interop';

import 'package:file_saver_ffi/file_saver_ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web/web.dart';

/// `==` of [WebPickedDirectoryLocation], on directories of the origin private
/// file system.
void main() {
  late FileSystemDirectoryHandle root;

  Future<FileSystemDirectoryHandle> directory(String name) => root
      .getDirectoryHandle(name, FileSystemGetDirectoryOptions(create: true))
      .toDart;

  setUp(() async {
    root = await window.navigator.storage.getDirectory().toDart;
  });

  test('locations of the same handle are equal', () async {
    final handle = await directory('location_a');

    final a = WebPickedDirectoryLocation(handle);
    final b = WebPickedDirectoryLocation(handle);

    expect(a, b);
    expect(a.hashCode, b.hashCode);
  });

  test('locations of different directories with the same name are not '
      'equal', () async {
    final a = await directory('location_a');
    final nested = await (await directory('location_b'))
        .getDirectoryHandle(
          'location_a',
          FileSystemGetDirectoryOptions(create: true),
        )
        .toDart;

    // The uri holds only the name, so the base class alone would call them
    // equal.
    expect(
      WebPickedDirectoryLocation(a).uri,
      WebPickedDirectoryLocation(nested).uri,
    );
    expect(
      WebPickedDirectoryLocation(a),
      isNot(WebPickedDirectoryLocation(nested)),
    );
  });

  test('a web location is not equal to a plain one with its uri', () async {
    final location = WebPickedDirectoryLocation(await directory('location_a'));

    expect(location, isNot(PickedDirectoryLocation(uri: location.uri)));
    expect(PickedDirectoryLocation(uri: location.uri), isNot(location));
  });
}
