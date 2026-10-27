import 'package:file_saver_ffi/file_saver_ffi.dart';
import 'package:file_saver_ffi/src/platforms/shared/native_event_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseNativeEvent', () {
    test('0 -> Started', () {
      expect(parseNativeEvent(0), isA<SaveProgressStarted>());
    });

    test('1 -> Update with progress', () {
      final event = parseNativeEvent(1, progress: 0.25);
      expect(event, isA<SaveProgressUpdate>());
      expect((event as SaveProgressUpdate).progress, 0.25);
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

    test('2 without code or message -> NativePlatformException UNKNOWN', () {
      final event = parseNativeEvent(2) as SaveProgressError;
      expect(event.exception, isA<NativePlatformException>());
      expect(event.exception.code, 'UNKNOWN');
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

    test('unknown type -> UNKNOWN_TYPE error', () {
      final event = parseNativeEvent(99) as SaveProgressError;
      expect(event.exception.code, 'UNKNOWN_TYPE');
    });
  });

  group('parseDarwinMessage', () {
    test('decodes every protocol message', () {
      expect(parseDarwinMessage([0]), isA<SaveProgressStarted>());
      expect(
        (parseDarwinMessage([1, 0.5]) as SaveProgressUpdate).progress,
        0.5,
      );
      expect(
        (parseDarwinMessage([1, 1]) as SaveProgressUpdate).progress,
        1.0,
        reason: 'integer progress from native must be accepted',
      );
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

    test('rejects malformed messages', () {
      for (final message in <Object?>[
        null,
        'oops',
        <Object>[],
        ['0'],
      ]) {
        final event = parseDarwinMessage(message);
        expect(event, isA<SaveProgressError>(), reason: '$message');
        expect((event as SaveProgressError).exception.code, 'INVALID_MESSAGE');
      }
    });

    test('unknown type -> UNKNOWN_TYPE error', () {
      final event = parseDarwinMessage([7]) as SaveProgressError;
      expect(event.exception.code, 'UNKNOWN_TYPE');
    });
  });
}
