import 'package:file_saver_ffi/file_saver_ffi.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FileSaverException.fromErrorResult', () {
    const cases = <String, Type>{
      'CANCELLED': CancelledException,
      'PERMISSION_DENIED': PermissionDeniedException,
      'FILE_EXISTS': FileExistsException,
      'FILE_NOT_FOUND': SourceFileNotFoundException,
      'OPEN_FAILED': OpenFailedException,
      'ICLOUD_DOWNLOAD_FAILED': ICloudDownloadException,
      'NETWORK_ERROR': NetworkException,
      'INVALID_INPUT': InvalidInputException,
      'INVALID_ARGUMENT': InvalidInputException,
      'UNSUPPORTED_FORMAT': UnsupportedFormatException,
      'STORAGE_FULL': StorageFullException,
      'FILE_IO_ERROR': FileIOException,
      'PLATFORM_ERROR': NativePlatformException,
    };

    cases.forEach((code, type) {
      test('$code -> $type', () {
        final e = FileSaverException.fromErrorResult(code, 'details');
        expect(e.runtimeType, type);
      });
    });

    test('unknown code keeps the code on NativePlatformException', () {
      final e = FileSaverException.fromErrorResult('SOMETHING_NEW', 'boom');
      expect(e, isA<NativePlatformException>());
      expect(e.code, 'SOMETHING_NEW');
      expect(e.message, 'boom');
    });
  });

  group('FileSaverException.fromObj', () {
    test('returns FileSaverException instances unchanged', () {
      const errors = <FileSaverException>[
        NetworkException('HTTP 404', 404),
        SourceFileNotFoundException('/missing'),
        FileExistsException('/dup.txt'),
        UnsupportedFormatException('xyz'),
        CancelledException(),
      ];
      for (final error in errors) {
        expect(FileSaverException.fromObj(error), same(error));
      }
    });

    test('maps exception messages containing an error code', () {
      expect(
        FileSaverException.fromObj(Exception('PERMISSION_DENIED: nope')),
        isA<PermissionDeniedException>(),
      );
      expect(
        FileSaverException.fromObj(Exception('NO_APP_FOUND: none')),
        isA<OpenFailedException>(),
      );
      expect(
        FileSaverException.fromObj(Exception('CANCELLED')),
        isA<CancelledException>(),
      );
    });

    test('wraps non-Exception objects as PLATFORM_ERROR', () {
      final e = FileSaverException.fromObj(StateError('bad'));
      expect(e, isA<NativePlatformException>());
      expect(e.code, 'PLATFORM_ERROR');
    });
  });
}
