import 'dart:typed_data';

import 'package:file_saver_ffi/file_saver_ffi.dart';
import 'package:file_saver_ffi/src/platform_interface/file_saver_platform.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records calls and replays [events] for every save operation.
class _FakePlatform extends FileSaverPlatform {
  final calls = <String, Map<String, Object?>>{};
  List<SaveProgress> events = const [];

  /// Result of [pickDirectory]; a [FileSaverException] is thrown instead.
  Object? pickResult;
  var picks = 0;

  Stream<SaveProgress> _record(String name, Map<String, Object?> args) {
    calls[name] = args;
    return Stream.fromIterable(events);
  }

  @override
  Stream<SaveProgress> saveBytes({
    required Uint8List fileBytes,
    required FileType fileType,
    required String fileName,
    SaveLocation? saveLocation,
    String? subDir,
    ConflictResolution conflictResolution = ConflictResolution.autoRename,
  }) => _record('saveBytes', {
    'fileBytes': fileBytes,
    'fileType': fileType,
    'fileName': fileName,
    'saveLocation': saveLocation,
    'subDir': subDir,
    'conflictResolution': conflictResolution,
  });

  @override
  Stream<SaveProgress> saveFile({
    required String filePath,
    required String fileName,
    required FileType fileType,
    SaveLocation? saveLocation,
    String? subDir,
    ConflictResolution conflictResolution = ConflictResolution.autoRename,
  }) => _record('saveFile', {
    'filePath': filePath,
    'fileName': fileName,
    'conflictResolution': conflictResolution,
  });

  @override
  Stream<SaveProgress> saveNetwork({
    required String url,
    required String fileName,
    required FileType fileType,
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 60),
    SaveLocation? saveLocation,
    String? subDir,
    ConflictResolution conflictResolution = ConflictResolution.autoRename,
  }) => _record('saveNetwork', {
    'url': url,
    'headers': headers,
    'timeout': timeout,
  });

  @override
  Stream<SaveProgress> saveAs({
    required SaveInput input,
    required FileType fileType,
    required String fileName,
    required PickedDirectoryLocation saveLocation,
    ConflictResolution conflictResolution = ConflictResolution.autoRename,
  }) => _record('saveAs', {'input': input, 'saveLocation': saveLocation});

  @override
  Future<FileSaverSink?> openWriteAs({
    required String fileName,
    required FileType fileType,
    required PickedDirectoryLocation saveLocation,
    int? totalSize,
    ConflictResolution conflictResolution = ConflictResolution.autoRename,
  }) async {
    calls['openWriteAs'] = {'saveLocation': saveLocation};
    return null;
  }

  @override
  Future<PickedDirectoryLocation?> pickDirectory({
    bool shouldPersist = true,
  }) async {
    picks++;
    final result = pickResult;
    if (result is FileSaverException) throw result;
    return result as PickedDirectoryLocation?;
  }
}

void main() {
  late _FakePlatform platform;
  final bytes = Uint8List.fromList([1, 2, 3]);
  final savedUri = Uri.parse('file:///tmp/a.png');
  final picked = PickedDirectoryLocation(uri: Uri.parse('file:///picked/'));

  setUp(() {
    platform = _FakePlatform();
    FileSaverPlatform.instance = platform;
  });

  group('save dispatches on SaveInput', () {
    test('bytes', () async {
      await FileSaver.save(
        input: SaveInput.bytes(bytes),
        fileType: ImageType.png,
        fileName: 'a',
        saveLocation: AndroidSaveLocation.pictures,
        subDir: 'album',
        conflictResolution: ConflictResolution.overwrite,
      ).drain<void>();

      expect(platform.calls.keys, ['saveBytes']);
      expect(platform.calls['saveBytes'], {
        'fileBytes': bytes,
        'fileType': ImageType.png,
        'fileName': 'a',
        'saveLocation': AndroidSaveLocation.pictures,
        'subDir': 'album',
        'conflictResolution': ConflictResolution.overwrite,
      });
    });

    test('file', () async {
      await FileSaver.save(
        input: SaveInput.file('/src/a.png'),
        fileType: ImageType.png,
        fileName: 'a',
        conflictResolution: ConflictResolution.skip,
      ).drain<void>();

      expect(platform.calls['saveFile'], {
        'filePath': '/src/a.png',
        'fileName': 'a',
        'conflictResolution': ConflictResolution.skip,
      });
    });

    test('network', () async {
      await FileSaver.save(
        input: SaveInput.network(
          url: 'https://example.com/a.png',
          headers: {'Authorization': 'Bearer x'},
          timeout: const Duration(seconds: 5),
        ),
        fileType: ImageType.png,
        fileName: 'a',
      ).drain<void>();

      expect(platform.calls['saveNetwork'], {
        'url': 'https://example.com/a.png',
        'headers': {'Authorization': 'Bearer x'},
        'timeout': const Duration(seconds: 5),
      });
    });
  });

  group('saveAsync', () {
    Future<Uri> saveAsync({void Function(double)? onProgress}) =>
        FileSaver.saveAsync(
          input: SaveInput.bytes(bytes),
          fileType: ImageType.png,
          fileName: 'a',
          onProgress: onProgress,
        );

    test('returns the URI and reports progress', () async {
      platform.events = [
        const SaveProgressStarted(),
        const SaveProgressUpdate(0.5),
        const SaveProgressUpdate(1.0),
        SaveProgressComplete(savedUri),
      ];
      final progress = <double>[];

      expect(await saveAsync(onProgress: progress.add), savedUri);
      expect(progress, [0.5, 1.0]);
    });

    test('reports progress only when it changes, so a download of unknown '
        'size reports 0.0 once', () async {
      platform.events = [
        const SaveProgressStarted(),
        const SaveProgressUpdate.bytes(100, null),
        const SaveProgressUpdate.bytes(200, null),
        const SaveProgressUpdate.bytes(300, null),
        SaveProgressComplete(savedUri),
      ];
      final progress = <double>[];

      expect(await saveAsync(onProgress: progress.add), savedUri);
      expect(progress, [0.0]);
    });

    test('throws the exception from SaveProgressError', () {
      platform.events = [
        const SaveProgressStarted(),
        const SaveProgressError(PermissionDeniedException()),
      ];
      expect(saveAsync(), throwsA(isA<PermissionDeniedException>()));
    });

    test('throws CancelledException on SaveProgressCancelled', () {
      platform.events = [const SaveProgressCancelled()];
      expect(saveAsync(), throwsA(isA<CancelledException>()));
    });

    test('throws INCOMPLETE when the stream ends without a result', () {
      platform.events = [const SaveProgressStarted()];
      expect(
        saveAsync(),
        throwsA(
          isA<NativePlatformException>().having(
            (e) => e.code,
            'code',
            'INCOMPLETE',
          ),
        ),
      );
    });
  });

  group('saveAs', () {
    Stream<SaveProgress> saveAs({PickedDirectoryLocation? location}) =>
        FileSaver.saveAs(
          input: SaveInput.bytes(bytes),
          fileType: ImageType.png,
          fileName: 'a',
          saveLocation: location,
        );

    test('uses the given location without picking', () async {
      platform.events = [SaveProgressComplete(savedUri)];
      platform.pickResult = const PermissionDeniedException();

      final events = await saveAs(location: picked).toList();

      expect(events.single, isA<SaveProgressComplete>());
      expect(platform.calls['saveAs']!['saveLocation'], picked);
    });

    test('picks a directory when none is given', () async {
      platform.events = [SaveProgressComplete(savedUri)];
      platform.pickResult = picked;

      await saveAs().drain<void>();

      expect(platform.calls['saveAs']!['saveLocation'], picked);
    });

    test('emits Cancelled when the picker is dismissed', () async {
      final events = await saveAs().toList();

      expect(events.single, isA<SaveProgressCancelled>());
      expect(platform.calls, isEmpty);
    });

    test('emits Error when the picker fails', () async {
      platform.pickResult = const PermissionDeniedException();

      final events = await saveAs().toList();

      // The picker's exception as it is, not wrapped once more.
      expect(
        (events.single as SaveProgressError).exception,
        same(platform.pickResult),
      );
      expect(platform.calls, isEmpty);
    });

    test('invalid input throws when saveAs is called, before the '
        'picker', () {
      for (final input in [
        SaveInput.bytes(Uint8List(0)),
        SaveInput.file(''),
        SaveInput.network(url: 'ftp://example.com/a.png'),
      ]) {
        expect(
          () => FileSaver.saveAs(
            input: input,
            fileType: ImageType.png,
            fileName: 'a',
          ),
          throwsA(isA<InvalidInputException>()),
          reason: '$input',
        );
      }
      expect(
        () => FileSaver.saveAs(
          input: SaveInput.bytes(bytes),
          fileType: ImageType.png,
          fileName: '',
        ),
        throwsA(isA<InvalidInputException>()),
      );
      expect(platform.picks, 0);
      expect(platform.calls, isEmpty);
    });

    test('saveAsAsync throws INCOMPLETE when the stream ends without a '
        'result, as saveAsync does', () {
      platform.events = [const SaveProgressStarted()];

      expect(
        FileSaver.saveAsAsync(
          input: SaveInput.bytes(bytes),
          fileType: ImageType.png,
          fileName: 'a',
          saveLocation: picked,
        ),
        throwsA(
          isA<NativePlatformException>().having(
            (e) => e.code,
            'code',
            FileSaverErrorCode.incomplete,
          ),
        ),
      );
    });

    test('saveAsAsync returns the URI and reports progress', () async {
      platform.events = [
        const SaveProgressStarted(),
        const SaveProgressUpdate(0.5),
        SaveProgressComplete(savedUri),
      ];
      final progress = <double>[];

      expect(
        await FileSaver.saveAsAsync(
          input: SaveInput.bytes(bytes),
          fileType: ImageType.png,
          fileName: 'a',
          saveLocation: picked,
          onProgress: progress.add,
        ),
        savedUri,
      );
      expect(progress, [0.5]);
    });

    test('saveAsAsync returns null when cancelled', () async {
      expect(
        await FileSaver.saveAsAsync(
          input: SaveInput.bytes(bytes),
          fileType: ImageType.png,
          fileName: 'a',
        ),
        isNull,
      );
    });
  });

  group('openWriteAs', () {
    test('returns null without calling the platform when not picked', () async {
      final sink = await FileSaver.openWriteAs(
        fileName: 'a',
        fileType: ImageType.png,
      );
      expect(sink, isNull);
      expect(platform.calls, isEmpty);
    });

    test('an empty name throws before the picker', () async {
      await expectLater(
        FileSaver.openWriteAs(fileName: '', fileType: ImageType.png),
        throwsA(isA<InvalidInputException>()),
      );
      expect(platform.picks, 0);
    });

    test('rethrows picker errors', () {
      platform.pickResult = const PermissionDeniedException();
      expect(
        FileSaver.openWriteAs(fileName: 'a', fileType: ImageType.png),
        throwsA(isA<PermissionDeniedException>()),
      );
    });
  });

  group('SaveProgressUpdate', () {
    test('clamps progress to 0.0–1.0', () {
      expect(const SaveProgressUpdate(0.3).progress, 0.3);
      expect(const SaveProgressUpdate(1.5).progress, 1.0);
      expect(const SaveProgressUpdate(-0.1).progress, 0.0);
      expect(SaveProgressUpdate(double.nan).progress, 0.0);
      expect(SaveProgressUpdate(double.infinity).progress, 1.0);
    });

    test('bytes gives the fraction written of a known size', () {
      const update = SaveProgressUpdate.bytes(250, 1000);
      expect(update.progress, 0.25);
      expect(update.bytesWritten, 250);
      expect(update.totalBytes, 1000);
      expect(const SaveProgressUpdate.bytes(2000, 1000).progress, 1.0);
    });

    test('bytes of an unknown size has progress 0.0', () {
      const update = SaveProgressUpdate.bytes(250, null);
      expect(update.progress, 0.0);
      expect(update.bytesWritten, 250);
      expect(update.totalBytes, isNull);
    });

    test('bytes of a size of 0 has progress 0.0, not NaN', () {
      expect(const SaveProgressUpdate.bytes(0, 0).progress, 0.0);
    });
  });
}
