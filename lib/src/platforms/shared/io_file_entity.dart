import 'dart:io';

import 'file_entity.dart';

class IOFileEntity implements FileEntity {
  const IOFileEntity();

  @override
  Future<bool> exists(String path) => File(path).exists();

  @override
  Future<void> delete(String path) => File(path).delete();

  @override
  Future<bool> claim(String path) async {
    try {
      await File(path).create(exclusive: true);
      return true;
    } on FileSystemException {
      // Taken by a file, a directory or a link, or an error such as a missing
      // permission, which the write reports.
      if (await FileSystemEntity.type(path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        return false;
      }
      rethrow;
    }
  }
}
