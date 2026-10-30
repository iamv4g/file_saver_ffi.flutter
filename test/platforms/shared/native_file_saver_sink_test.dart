import 'dart:async';

import 'package:file_saver_ffi/file_saver_ffi.dart';
import 'package:file_saver_ffi/src/platforms/shared/native_file_saver_sink.dart';
import 'package:flutter_test/flutter_test.dart';

/// A [NativeWriteSession] whose replies arrive on the event queue, like the
/// port messages and JNI callbacks of the real sessions.
class _FakeSession implements NativeWriteSession {
  final bytes = <int>[];
  final writeSizes = <int>[];
  var flushes = 0;
  var closes = 0;
  var cancels = 0;

  /// The write (counting from 0) that fails.
  int? failWrite;
  final writeError = FileSaverException.fromErrorResult(
    'FILE_IO_ERROR',
    'No space',
  );

  /// Writes wait for this while it is set.
  Completer<void>? hold;
  var _writing = false;

  @override
  Future<int> write(List<int> data) async {
    if (_writing) fail('write() while another write is pending');
    _writing = true;
    final index = writeSizes.length;
    writeSizes.add(data.length);
    final copy = List.of(data);
    try {
      await _reply();
      await hold?.future;
      if (index == failWrite) throw writeError;
      bytes.addAll(copy);
      return bytes.length;
    } finally {
      _writing = false;
    }
  }

  @override
  Future<void> flush() async {
    await _reply();
    flushes++;
  }

  @override
  Future<Uri> close() async {
    await _reply();
    closes++;
    return Uri.parse('content://saved/1');
  }

  @override
  void cancel() => cancels++;

  Future<void> _reply() => Future<void>.delayed(Duration.zero);
}

void main() {
  late _FakeSession session;
  late NativeFileSaverSink sink;

  setUp(() {
    session = _FakeSession();
    sink = NativeFileSaverSink(session, 6);
  });

  Stream<List<int>> chunks(List<List<int>> chunks) async* {
    for (final chunk in chunks) {
      await Future<void>.delayed(Duration.zero);
      yield chunk;
    }
  }

  test('writes added chunks in order and completes with the URI', () async {
    final bytesWritten = <int>[];
    final progress = <double>[];
    sink.bytesWritten.listen(bytesWritten.add);
    sink.progress.listen(progress.add);

    await sink.addStream(
      chunks([
        [1, 2],
        [3, 4],
      ]),
    );
    sink.add([5, 6]);
    await sink.close();

    expect(session.bytes, [1, 2, 3, 4, 5, 6]);
    expect(await sink.result, Uri.parse('content://saved/1'));
    expect(bytesWritten, [2, 4, 6]);
    expect(progress, [2 / 6, 4 / 6, 1.0]);
    expect(session.cancels, 0);
  });

  group('close while addStream runs', () {
    test('throws StateError instead of waiting forever', () async {
      final adding = sink.addStream(
        chunks([
          [1],
          [2],
          [3],
        ]),
      );

      expect(() => sink.close(), throwsStateError);

      await adding;
      await sink.close();
      expect(session.bytes, [1, 2, 3]);
    });

    test('flush and add throw StateError too', () async {
      final adding = sink.addStream(
        chunks([
          [1],
        ]),
      );

      expect(() => sink.flush(), throwsStateError);
      expect(() => sink.add([2]), throwsStateError);
      await adding;
    });
  });

  group('a failed write', () {
    test(
      'fails addStream, close, done and result with the native error',
      () async {
        session.failWrite = 1;

        await expectLater(
          sink.addStream(
            chunks([
              [1],
              [2],
              [3],
            ]),
          ),
          throwsA(same(session.writeError)),
        );
        await expectLater(sink.close(), throwsA(same(session.writeError)));
        await expectLater(sink.done, throwsA(same(session.writeError)));
        await expectLater(sink.result, throwsA(same(session.writeError)));

        expect(session.bytes, [1]);
        expect(session.writeSizes, hasLength(2), reason: 'stops writing');
        expect(session.closes, 0, reason: 'never publishes the file');
        expect(session.cancels, 1, reason: 'deletes the partial file');
      },
    );

    test(
      'of an added chunk fails flush and close, and drops later chunks',
      () async {
        session.failWrite = 0;

        sink.add([1]);
        await expectLater(sink.flush(), throwsA(same(session.writeError)));
        sink.add([2]);
        await expectLater(sink.close(), throwsA(same(session.writeError)));

        expect(session.writeSizes, [1]);
        expect(session.cancels, 1);
      },
    );

    test('is not an unhandled error when only close is awaited', () async {
      // An unhandled error would fail this test.
      session.failWrite = 0;
      sink.add([1]);

      await expectLater(sink.close(), throwsA(isA<FileIOException>()));
    });
  });

  group('add', () {
    test('keeps one write pending and sends queued chunks together', () async {
      session.hold = Completer<void>();
      sink.add([1]);
      sink.add([2]);
      sink.add([3, 4]);

      await Future<void>.delayed(Duration.zero);
      expect(session.writeSizes, [1]);
      session.hold!.complete();

      await sink.close();
      expect(session.writeSizes, [1, 3]);
      expect(session.bytes, [1, 2, 3, 4]);
    });

    test('copies a queued chunk, so the caller can reuse its buffer', () async {
      session.hold = Completer<void>();
      final buffer = [1, 2];
      sink.add(buffer);
      buffer.setAll(0, [3, 4]);
      sink.add(buffer);
      buffer.setAll(0, [5, 6]);
      session.hold!.complete();

      await sink.close();
      expect(session.bytes, [1, 2, 3, 4]);
    });

    test('sends at most 1 MiB of queued chunks per write', () async {
      session.hold = Completer<void>();
      sink.add([0]);
      for (var i = 0; i < 5; i++) {
        sink.add(List.filled(300 * 1024, i));
      }
      session.hold!.complete();

      await sink.close();
      expect(session.writeSizes, [1, 3 * 300 * 1024, 2 * 300 * 1024]);
    });

    test('flush waits for queued chunks, then flushes the session', () async {
      session.hold = Completer<void>();
      sink.add([1]);
      sink.add([2]);
      final flushed = sink.flush();
      session.hold!.complete();

      await flushed;
      expect(session.bytes, [1, 2]);
      expect(session.flushes, 1);
    });
  });

  group('cancel', () {
    test('during addStream stops reading the source', () async {
      session.hold = Completer<void>();
      var sourceCancelled = false;
      final source = StreamController<List<int>>(
        onCancel: () => sourceCancelled = true,
      );
      source.add([1]);
      source.add([2]);

      final adding = sink.addStream(source.stream);
      await Future<void>.delayed(Duration.zero);
      await sink.cancel();
      session.hold!.complete();
      await adding;

      expect(session.writeSizes, [1]);
      expect(sourceCancelled, isTrue);
      expect(session.cancels, 1);
      expect(session.closes, 0);
      await sink.done;
      await expectLater(sink.result, throwsA(isA<CancelledException>()));
    });

    test('after close does nothing', () async {
      await sink.close();
      await sink.cancel();

      expect(session.cancels, 0);
      expect(await sink.result, Uri.parse('content://saved/1'));
    });
  });

  test(
    'addError deletes the file and fails done and result with the error',
    () async {
      sink.add([1]);
      final error = StateError('source failed');

      sink.addError(error);

      expect(session.cancels, 1);
      await expectLater(sink.done, throwsA(same(error)));
      await expectLater(sink.result, throwsA(same(error)));
      expect(() => sink.add([2]), throwsStateError);
    },
  );

  test('a sink dropped before close cancels its session', () async {
    final dropped = _FakeSession();
    // Created in a closure so no local variable keeps the sink alive.
    final ref = (() => WeakReference(NativeFileSaverSink(dropped, null)))();

    for (var i = 0; i < 1000 && dropped.cancels == 0; i++) {
      // Allocate garbage so the VM collects the sink and runs its finalizer.
      List.generate(10000, (i) => [i]);
      await Future<void>.delayed(Duration.zero);
    }

    expect(ref.target, isNull);
    expect(dropped.cancels, 1);
  });

  test('a closed sink is not cancelled when it is dropped', () async {
    final closed = _FakeSession();
    await (() async {
      final sink = NativeFileSaverSink(closed, null);
      sink.add([1]);
      await sink.close();
    })();

    for (var i = 0; i < 200; i++) {
      List.generate(10000, (i) => [i]);
      await Future<void>.delayed(Duration.zero);
    }

    expect(closed.closes, 1);
    expect(closed.cancels, 0);
  });
}
