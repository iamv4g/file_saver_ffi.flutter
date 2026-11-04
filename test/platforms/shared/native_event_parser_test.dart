import 'package:file_saver_ffi/file_saver_ffi.dart';
import 'package:file_saver_ffi/src/platforms/shared/native_event_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseNativeEvent', () {
    test('0 -> Started', () {
      expect(parseNativeEvent(0), isA<SaveProgressStarted>());
    });

    test('1 -> Update with the bytes written of the size', () {
      final event = parseNativeEvent(1, bytesWritten: 25, totalBytes: 100);
      expect(event, isA<SaveProgressUpdate>());
      event as SaveProgressUpdate;
      expect(event.bytesWritten, 25);
      expect(event.totalBytes, 100);
      expect(event.progress, 0.25);
    });

    test('2 -> Error mapped from error code', () {
      final event = parseNativeEvent(
        2,
        data: 'PERMISSION_DENIED',
        message: 'denied',
      );
      expect(event, isA<SaveProgressError>());
      expect(
        (event as SaveProgressError).exception,
        isA<PermissionDeniedException>(),
      );
    });

    test('2 with a status code -> NetworkException with it', () {
      final event =
          parseNativeEvent(
                2,
                data: 'NETWORK_ERROR',
                message: 'HTTP 503',
                statusCode: 503,
              )
              as SaveProgressError;
      expect(
        event.exception,
        isA<NetworkException>().having((e) => e.statusCode, 'statusCode', 503),
      );
    });

    test('2 without code or message -> PLATFORM_ERROR', () {
      final event = parseNativeEvent(2) as SaveProgressError;
      expect(event.exception, isA<NativePlatformException>());
      expect(event.exception.code, 'PLATFORM_ERROR');
      expect(event.exception.message, 'Unknown error');
    });

    test('3 -> Complete with parsed URI', () {
      final event = parseNativeEvent(
        3,
        data: 'content://media/external/images/media/42',
      );
      expect(event, isA<SaveProgressComplete>());
      expect(
        (event as SaveProgressComplete).uri,
        Uri.parse('content://media/external/images/media/42'),
      );
    });

    test('4 -> Cancelled', () {
      expect(parseNativeEvent(4), isA<SaveProgressCancelled>());
    });

    test('unknown type -> PLATFORM_ERROR', () {
      final event = parseNativeEvent(99) as SaveProgressError;
      expect(event.exception.code, 'PLATFORM_ERROR');
    });
  });

  group('parseDarwinMessage', () {
    test('decodes every protocol message', () {
      expect(parseDarwinMessage([0]), isA<SaveProgressStarted>());
      final update = parseDarwinMessage([1, 512, 1024]) as SaveProgressUpdate;
      expect(update.bytesWritten, 512);
      expect(update.totalBytes, 1024);
      expect(update.progress, 0.5);
      final unknown = parseDarwinMessage([1, 512, null]) as SaveProgressUpdate;
      expect(unknown.bytesWritten, 512);
      expect(unknown.totalBytes, isNull);
      expect(unknown.progress, 0.0);
      expect(
        (parseDarwinMessage([2, 'FILE_EXISTS', 'dup']) as SaveProgressError)
            .exception,
        isA<FileExistsException>(),
      );
      expect(
        (parseDarwinMessage([3, 'file:///tmp/a.png']) as SaveProgressComplete)
            .uri,
        Uri.parse('file:///tmp/a.png'),
      );
      expect(parseDarwinMessage([4]), isA<SaveProgressCancelled>());
    });

    test('an error with a fourth element carries the status code', () {
      final event =
          parseDarwinMessage([2, 'NETWORK_ERROR', 'HTTP 404', 404])
              as SaveProgressError;
      expect(
        event.exception,
        isA<NetworkException>().having((e) => e.statusCode, 'statusCode', 404),
      );
    });

    test('rejects malformed messages', () {
      for (final message in <Object?>[
        null,
        'oops',
        <Object>[],
        ['0'],
      ]) {
        final event = parseDarwinMessage(message);
        expect(event, isA<SaveProgressError>(), reason: '$message');
        expect((event as SaveProgressError).exception.code, 'PLATFORM_ERROR');
      }
    });

    test('unknown type -> PLATFORM_ERROR', () {
      final event = parseDarwinMessage([7]) as SaveProgressError;
      expect(event.exception.code, 'PLATFORM_ERROR');
    });
  });
}
