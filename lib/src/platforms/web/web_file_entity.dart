import 'dart:js_interop';

import 'package:web/web.dart';

import '../shared/file_entity.dart';

class WebFileEntity implements FileEntity {
  const WebFileEntity(this._handle);

  final FileSystemDirectoryHandle _handle;

  /// The names claimed in each directory by saves of this page that haven't
  /// ended yet.
  static final _claimed = <(FileSystemDirectoryHandle, Set<String>)>[];

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

  /// Claims [name] if it is free and no other save of this page has claimed
  /// it. Call [release] once the save has ended.
  ///
  /// The File System Access API has no exclusive create, so a file another
  /// tab or app creates at the same moment can still take the name.
  @override
  Future<bool> claim(String name) async {
    final claimed = await _claimedHere();
    if (!claimed.add(name)) return false;
    if (!await exists(name)) return true;
    claimed.remove(name);
    return false;
  }

  /// Gives up the claim on [name] of [claim].
  Future<void> release(String name) async =>
      (await _claimedHere()).remove(name);

  /// The names claimed in this directory, which other handles of it share.
  Future<Set<String>> _claimedHere() async {
    // `_claimed` can grow during each await. The loop checks the entries
    // added meanwhile too, and adds one only after checking them all, with no
    // await in between, so a directory never gets two entries.
    for (var i = 0; i < _claimed.length; i++) {
      final (directory, names) = _claimed[i];
      if ((await _handle.isSameEntry(directory).toDart).toDart) return names;
    }
    final names = <String>{};
    _claimed.add((_handle, names));
    return names;
  }
}
