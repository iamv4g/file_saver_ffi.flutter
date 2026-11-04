/// The platform interface of `file_saver_ffi`.
///
/// Use it to replace the platform in your app's tests with a fake:
///
/// ```dart
/// import 'package:file_saver_ffi/file_saver_ffi.dart';
/// import 'package:file_saver_ffi/platform_interface.dart';
///
/// class FakeFileSaver extends FileSaverPlatform {
///   final saved = <String>[];
///
///   @override
///   Stream<SaveProgress> saveBytes({
///     required Uint8List fileBytes,
///     required FileType fileType,
///     required String fileName,
///     SaveLocation? saveLocation,
///     String? subDir,
///     ConflictResolution conflictResolution = ConflictResolution.autoRename,
///   }) {
///     saved.add(fileName);
///     return Stream.value(SaveProgressComplete(Uri.parse('file:///$fileName')));
///   }
///
///   // Fails the test on any call it doesn't expect.
///   @override
///   dynamic noSuchMethod(Invocation invocation) =>
///       super.noSuchMethod(invocation);
/// }
///
/// void main() {
///   setUp(() => FileSaverPlatform.instance = FakeFileSaver());
/// }
/// ```
///
/// Extend [FileSaverPlatform] rather than implementing it, so the methods
/// it implements itself, such as `pickDirectory`, keep working.
library;

export 'src/platform_interface/file_saver_platform.dart' show FileSaverPlatform;
