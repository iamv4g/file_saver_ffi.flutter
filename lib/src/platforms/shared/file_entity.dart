abstract interface class FileEntity {
  Future<bool> exists(String path);
  Future<void> delete(String path);

  /// Reserves [path] for a new file. Returns true if nothing existed there.
  ///
  /// The IO implementation creates an empty file exclusively, so two saves
  /// can't both claim the same path; the caller writes into it. Web only
  /// checks that the name is free.
  Future<bool> claim(String path);
}
