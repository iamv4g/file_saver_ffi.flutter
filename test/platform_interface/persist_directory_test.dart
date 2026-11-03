import 'package:dir_picker/dir_picker.dart';
import 'package:file_saver_ffi/file_saver_ffi.dart';
import 'package:file_saver_ffi/src/platform_interface/file_saver_platform.dart';
import 'package:flutter_test/flutter_test.dart';

/// A platform that keeps the default directory methods of
/// [FileSaverPlatform], as every IO platform does.
class _IoPlatform extends FileSaverPlatform {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Records the calls `DirPicker` makes and answers with the given results.
class _FakeDirPicker extends DirPickerPlatform {
  final calls = <String, Object?>{};

  /// Thrown by every call when set.
  Object? error;
  String persistToken = 'token';
  PickedLocation? restored;
  PickedLocation? picked;

  @override
  Future<PickedLocation?> pick({
    PickOptions? options,
    PickedLocation? initialDirectory,
  }) async {
    calls['pick'] = options;
    if (error case final error?) throw error;
    return picked;
  }

  @override
  Future<List<FileSystemEntry>> listEntries(
    PickedLocation location, {
    bool recursive = false,
  }) => throw UnimplementedError();

  @override
  Future<String> persist(PickedLocation location) async {
    calls['persist'] = location;
    if (error case final error?) throw error;
    return persistToken;
  }

  @override
  Future<PickedLocation?> restore(String token) async {
    calls['restore'] = token;
    if (error case final error?) throw error;
    return restored;
  }

  @override
  Future<void> release(String token) async {
    calls['release'] = token;
    if (error case final error?) throw error;
  }
}

void main() {
  late _FakeDirPicker dirPicker;
  final uri = Uri.parse('file:///Users/me/Exports/');

  setUp(() {
    FileSaverPlatform.instance = _IoPlatform();
    dirPicker = _FakeDirPicker();
    DirPickerPlatform.instance = dirPicker;
  });

  group('pickDirectory', () {
    test('returns the picked location without options', () async {
      dirPicker.picked = IOPickedLocation(uri);

      final location = await FileSaver.pickDirectory();

      expect(location!.uri, uri);
      expect(dirPicker.calls, {'pick': null});
    });

    test('a picker failure throws NativePlatformException with the '
        'dir_picker code', () {
      dirPicker.error = const DirPickerException(
        DirPickerException.alreadyActive,
        'Another pick is open',
      );

      expect(
        FileSaver.pickDirectory(),
        throwsA(
          isA<NativePlatformException>()
              .having((e) => e.code, 'code', 'ALREADY_ACTIVE')
              .having(
                (e) => e.message,
                'message',
                'Pick directory failed: Another pick is open',
              ),
        ),
      );
    });

    group('on Android', () {
      final contentUri = Uri.parse(
        'content://com.android.externalstorage.documents/tree/primary%3AX',
      );

      setUp(() {
        FileSaverPlatform.instance = FileSaverAndroid();
        dirPicker.picked = IOPickedLocation(contentUri);
      });

      test('persists the location by default', () async {
        final location = await FileSaver.pickDirectory();

        expect(location!.uri, contentUri);
        expect(dirPicker.calls['persist'], IOPickedLocation(contentUri));
      });

      test('shouldPersist: false only picks', () async {
        // ignore: deprecated_member_use_from_same_package
        await FileSaver.pickDirectory(shouldPersist: false);

        expect(dirPicker.calls.keys, ['pick']);
      });

      test('a cancelled pick persists nothing', () async {
        dirPicker.picked = null;

        expect(await FileSaver.pickDirectory(), isNull);
        expect(dirPicker.calls.keys, ['pick']);
      });
    });
  });

  group('persistDirectory', () {
    test(
      'persists the location with dir_picker and returns its token',
      () async {
        dirPicker.persistToken = 'bookmark';

        final token = await FileSaver.persistDirectory(
          PickedDirectoryLocation(uri: uri),
        );

        expect(token, 'bookmark');
        expect(dirPicker.calls['persist'], IOPickedLocation(uri));
      },
    );

    test('a location the platform rejects throws InvalidInputException', () {
      dirPicker.error = ArgumentError.value(
        uri,
        'location',
        'persist requires a content:// location on Android.',
      );

      expect(
        FileSaver.persistDirectory(PickedDirectoryLocation(uri: uri)),
        throwsA(
          isA<InvalidInputException>().having(
            (e) => e.message,
            'message',
            contains('content://'),
          ),
        ),
      );
    });

    test('a refusal throws NativePlatformException with the dir_picker '
        'code', () {
      dirPicker.error = const DirPickerException(
        DirPickerException.persistError,
        'No permission',
      );

      expect(
        FileSaver.persistDirectory(PickedDirectoryLocation(uri: uri)),
        throwsA(
          isA<NativePlatformException>()
              .having((e) => e.code, 'code', 'PERSIST_ERROR')
              .having((e) => e.message, 'message', contains('No permission')),
        ),
      );
    });
  });

  group('restoreDirectory', () {
    test(
      'returns the restored location as a PickedDirectoryLocation',
      () async {
        dirPicker.restored = IOPickedLocation(uri);

        final location = await FileSaver.restoreDirectory('bookmark');

        expect(dirPicker.calls['restore'], 'bookmark');
        expect(location, isA<PickedDirectoryLocation>());
        expect(location!.uri, uri);
      },
    );

    test('returns null when the token no longer gives access', () async {
      dirPicker.restored = null;

      expect(await FileSaver.restoreDirectory('revoked'), isNull);
    });

    test('a failure throws NativePlatformException', () {
      dirPicker.error = const DirPickerException(
        DirPickerException.restoreError,
        'Failed',
      );

      expect(
        FileSaver.restoreDirectory('bookmark'),
        throwsA(
          isA<NativePlatformException>().having(
            (e) => e.code,
            'code',
            'RESTORE_ERROR',
          ),
        ),
      );
    });
  });

  group('releaseDirectory', () {
    test('releases the token with dir_picker', () async {
      await FileSaver.releaseDirectory('bookmark');

      expect(dirPicker.calls['release'], 'bookmark');
    });

    test('a failure throws NativePlatformException', () {
      dirPicker.error = const DirPickerException(
        DirPickerException.releaseError,
        'Failed',
      );

      expect(
        FileSaver.releaseDirectory('bookmark'),
        throwsA(
          isA<NativePlatformException>().having(
            (e) => e.code,
            'code',
            'RELEASE_ERROR',
          ),
        ),
      );
    });
  });
}
