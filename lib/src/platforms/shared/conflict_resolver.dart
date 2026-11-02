import '../../exceptions/file_saver_exceptions.dart';
import '../../models/conflict_resolution.dart';
import 'file_entity.dart';

/// The path a save writes to. [isNew] is true when the path was claimed with
/// [FileEntity.claim], false when it is an existing file to overwrite.
typedef ResolvedPath = ({String path, bool isNew});

class ConflictResolver {
  const ConflictResolver(this._entity);

  final FileEntity _entity;

  /// Resolves the path/filename based on conflict mode.
  ///
  /// Returns the resolved path, or `null` if [ConflictResolution.skip].
  /// Throws [FileExistsException] if [ConflictResolution.fail] and file exists.
  Future<String?> resolve(String path, ConflictResolution mode) async =>
      (await claim(path, mode))?.path;

  /// Like [resolve], but claims a new path with [FileEntity.claim], so
  /// concurrent saves of the same name get different paths.
  Future<ResolvedPath?> claim(String path, ConflictResolution mode) async {
    if (await _entity.claim(path)) return (path: path, isNew: true);

    return switch (mode) {
      ConflictResolution.skip => null,
      ConflictResolution.overwrite => (path: path, isNew: false),
      ConflictResolution.autoRename => (
        path: await _autoRename(path),
        isNew: true,
      ),
      ConflictResolution.fail => throw FileExistsException(path),
    };
  }

  /// Claims `name (1).ext`, `name (2).ext`, ... up to `name (1000).ext`.
  ///
  /// Works for both full paths (Desktop) and bare filenames (Web). The
  /// extension is what follows the last dot of the file name, unless the name
  /// starts with it (`.env`).
  Future<String> _autoRename(String path) async {
    final nameStart = path.lastIndexOf(RegExp(r'[/\\]')) + 1;
    final dotIndex = path.lastIndexOf('.');
    final hasExt = dotIndex > nameStart;
    final base = hasExt ? path.substring(0, dotIndex) : path;
    final ext = hasExt ? path.substring(dotIndex) : '';

    for (int i = 1; i <= 1000; i++) {
      final candidate = '$base ($i)$ext';
      if (await _entity.claim(candidate)) return candidate;
    }

    throw const FileIOException(
      'Could not find available filename after 1000 attempts',
    );
  }
}
