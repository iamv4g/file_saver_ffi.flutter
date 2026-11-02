import 'dart:js_interop';

import 'package:web/web.dart';

import '../shared/file_entity.dart';

class WebFileEntity implements FileEntity {
  const WebFileEntity(this._handle);

  final FileSystemDirectoryHandle _handle;

  @override
  Future<bool> exists(String name) async {
    try {
      await _handle.getFileHandle(name).toDart;
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<JSAny?> delete(String name) => _handle.removeEntry(name).toDart;

  /// Only checks that [name] is free: the File System Access API has no
  /// exclusive create.
  @override
  Future<bool> claim(String name) async => !await exists(name);
}
