import 'dart:async';
import 'dart:typed_data';

import 'package:file_saver_ffi/file_saver_ffi.dart';
import 'package:flutter_test/flutter_test.dart';

/// `==`, `hashCode` and `toString` of the inputs, locations, events and
/// exceptions. Each value is built twice from values known only at run time,
/// so the two are never the same canonical `const` instance.
void main() {
  /// Checks that [a] and [b] are equal, with the same hash code.
  void expectEqual(Object a, Object b) {
    expect(identical(a, b), isFalse, reason: 'two instances');
    expect(a, b);
    expect(a.hashCode, b.hashCode);
  }

  final dir = '/tmp/${'out'}';
  final url = 'https://example.com/${'a.bin'}';

  group('SaveInput', () {
    test('bytes inputs with the same bytes are equal', () {
      expectEqual(
        SaveInput.bytes(Uint8List.fromList([1, 2, 3])),
        SaveInput.bytes(Uint8List.fromList([1, 2, 3])),
      );
      expect(
        SaveInput.bytes(Uint8List.fromList([1, 2, 3])),
        isNot(SaveInput.bytes(Uint8List.fromList([1, 2, 4]))),
      );
    });

    test('a bytes input prints its size, not its bytes', () {
      expect(
        SaveInput.bytes(Uint8List(3)).toString(),
        'SaveBytesInput(3 bytes)',
      );
    });

    test('file inputs with the same path are equal', () {
      expectEqual(SaveInput.file(dir), SaveInput.file(dir));
      expect(SaveInput.file(dir), isNot(SaveInput.file('$dir/x')));
      expect(SaveInput.file(dir).toString(), 'SaveFileInput(/tmp/out)');
    });

    test('network inputs compare the url, every header and the timeout', () {
      expectEqual(
        SaveInput.network(url: url, headers: {'A': '1', 'B': '2'}),
        SaveInput.network(url: url, headers: {'B': '2', 'A': '1'}),
      );
      for (final other in [
        SaveInput.network(url: '$url?x'),
        SaveInput.network(url: url, headers: {'A': '2'}),
        SaveInput.network(url: url, timeout: const Duration(seconds: 1)),
      ]) {
        expect(SaveInput.network(url: url, headers: {'A': '1'}), isNot(other));
      }
    });

    test('a network input prints its header names, not their values', () {
      final input = SaveInput.network(
        url: url,
        headers: {'Authorization': 'Bearer secret'},
      );

      expect(
        input.toString(),
        'SaveNetworkInput(https://example.com/a.bin, '
        'headers: [Authorization], timeout: 0:01:00.000000)',
      );
      expect(input.toString(), isNot(contains('secret')));
    });

    test('inputs of different kinds are not equal', () {
      expect(SaveInput.file(url), isNot(SaveInput.network(url: url)));
    });
  });

  group('SaveLocation', () {
    test('path locations with the same path are equal', () {
      expectEqual(PathLocation(dir), PathLocation(dir));
      expect(PathLocation(dir), isNot(PathLocation('$dir/')));
      expect(PathLocation(dir).toString(), 'PathLocation(/tmp/out)');
    });

    test('picked locations with the same uri are equal', () {
      final uri = Uri.parse('content://tree/${'primary'}');

      expectEqual(
        PickedDirectoryLocation(uri: uri),
        PickedDirectoryLocation(uri: Uri.parse(uri.toString())),
      );
      expect(
        PickedDirectoryLocation(uri: uri),
        isNot(PickedDirectoryLocation(uri: Uri.parse('$uri/x'))),
      );
      expect(
        PickedDirectoryLocation(uri: uri).toString(),
        'PickedDirectoryLocation(content://tree/primary)',
      );
    });

    test('a subtype is not equal to the base type with the same uri', () {
      final uri = Uri.file(dir);

      expect(_OtherPicked(uri), isNot(PickedDirectoryLocation(uri: uri)));
      expect(PickedDirectoryLocation(uri: uri), isNot(_OtherPicked(uri)));
      expect(_OtherPath(dir), isNot(PathLocation(dir)));
    });
  });

  group('SaveProgress', () {
    test('events of the same type and fields are equal', () {
      final uri = Uri.file('$dir/a.txt');
      final pairs = <(SaveProgress, SaveProgress)>[
        (SaveProgressStarted(), SaveProgressStarted()),
        (
          SaveProgressUpdate.bytes(5, 10),
          SaveProgressUpdate(0.5, bytesWritten: 5, totalBytes: 10),
        ),
        (SaveProgressUpdate.bytes(5, null), SaveProgressUpdate.bytes(5, null)),
        (SaveProgressComplete(uri), SaveProgressComplete(Uri.parse('$uri'))),
        (
          SaveProgressError(FileExistsException(dir)),
          SaveProgressError(FileExistsException(dir)),
        ),
        (SaveProgressCancelled(), SaveProgressCancelled()),
      ];
      for (final (a, b) in pairs) {
        expectEqual(a, b);
      }
    });

    test('events that differ in a field or type are not equal', () {
      expect(
        SaveProgressUpdate.bytes(5, 10),
        isNot(SaveProgressUpdate.bytes(5, 11)),
      );
      expect(
        SaveProgressUpdate.bytes(5, 10),
        isNot(SaveProgressUpdate.bytes(6, 10)),
      );
      expect(
        SaveProgressComplete(Uri.file(dir)),
        isNot(SaveProgressComplete(Uri.file('$dir/x'))),
      );
      expect(
        SaveProgressError(FileExistsException(dir)),
        isNot(SaveProgressError(FileIOException(dir))),
      );
      expect(SaveProgressStarted(), isNot(SaveProgressCancelled()));
    });

    test('a stream of events can be checked with emitsInOrder', () {
      final uri = Uri.file('$dir/a.txt');
      final events = Stream<SaveProgress>.fromIterable([
        SaveProgressStarted(),
        SaveProgressUpdate.bytes(5, 10),
        SaveProgressComplete(uri),
      ]);

      expect(
        events,
        emitsInOrder([
          SaveProgressStarted(),
          SaveProgressUpdate.bytes(5, 10),
          SaveProgressComplete(Uri.parse('$uri')),
          emitsDone,
        ]),
      );
    });
  });

  group('FileSaverException', () {
    test('exceptions of the same type, message and code are equal', () {
      expectEqual(FileExistsException(dir), FileExistsException(dir));
      expectEqual(
        FileSaverException.fromErrorResult('FILE_IO_ERROR', dir),
        FileIOException(dir),
      );
      expect(FileExistsException(dir), isNot(FileExistsException('$dir/x')));
      expect(
        NativePlatformException(dir, 'A'),
        isNot(NativePlatformException(dir, 'B')),
      );
      expect(InvalidInputException(dir), isNot(FileIOException(dir)));
    });

    test('network exceptions also compare the status code', () {
      expectEqual(NetworkException(url, 404), NetworkException(url, 404));
      expect(NetworkException(url, 404), isNot(NetworkException(url, 500)));
    });
  });
}

class _OtherPicked extends PickedDirectoryLocation {
  const _OtherPicked(Uri uri) : super(uri: uri);
}

class _OtherPath extends PathLocation {
  const _OtherPath(super.path);
}
