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
      'UNSUPPORTED_FORMAT': UnsupportedFormatException,
      'STORAGE_FULL': StorageFullException,
      'FILE_IO_ERROR': FileIOException,
      'WRITE_SESSION_ERROR': WriteSessionException,
      'PLATFORM_ERROR': NativePlatformException,
    };

    cases.forEach((code, type) {
      test('$code -> $type', () {
        final e = FileSaverException.fromErrorResult(code, 'details');
        expect(e.runtimeType, type);
      });
    });

    test('the message fills the field of the exception, prefixed '
        'once', () {
      final exists =
          FileSaverException.fromErrorResult('FILE_EXISTS', 'a.txt')
              as FileExistsException;
      expect(exists.fileName, 'a.txt');
      expect(exists.message, 'File already exists: a.txt');

      final missing =
          FileSaverException.fromErrorResult('FILE_NOT_FOUND', '/x.bin')
              as SourceFileNotFoundException;
      expect(missing.path, '/x.bin');
      expect(missing.message, 'Source file not found: /x.bin');

      final format =
          FileSaverException.fromErrorResult('UNSUPPORTED_FORMAT', 'heic')
              as UnsupportedFormatException;
      expect(format.format, 'heic');

      expect(
        FileSaverException.fromErrorResult('INVALID_INPUT', 'empty').message,
        'Invalid input: empty',
      );
      expect(
        FileSaverException.fromErrorResult(
          'ICLOUD_DOWNLOAD_FAILED',
          'timed out',
        ).message,
        'iCloud file download failed: timed out',
      );
    });

    test('NETWORK_ERROR keeps the status code', () {
      final e =
          FileSaverException.fromErrorResult(
                'NETWORK_ERROR',
                'HTTP 404',
                statusCode: 404,
              )
              as NetworkException;
      expect(e.statusCode, 404);
      expect(e.message, 'Network error: HTTP 404');
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
        FileSaverException.fromObj(Exception('OPEN_FAILED: none')),
        isA<OpenFailedException>(),
      );
      expect(
        FileSaverException.fromObj(Exception('WRITE_SESSION_ERROR: closed')),
        isA<WriteSessionException>(),
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

  test('NativePlatformException defaults to PLATFORM_ERROR', () {
    expect(const NativePlatformException('boom').code, 'PLATFORM_ERROR');
  });
}
