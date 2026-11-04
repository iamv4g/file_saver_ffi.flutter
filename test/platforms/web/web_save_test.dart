@TestOn('browser')
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:file_saver_ffi/file_saver_ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web/web.dart';

/// The web saves, against a stubbed `fetch` and the origin private file
/// system, which gives a [FileSystemDirectoryHandle] without a picker.
void main() {
  final saver = FileSaverWeb();
  const bin = CustomFileType(ext: 'bin', mimeType: 'application/octet-stream');
  late FileSystemDirectoryHandle directory;
  late JSAny? realFetch;

  JSAny? eval(String code) =>
      globalContext.callMethod<JSAny?>('eval'.toJS, '($code)'.toJS);

  setUpAll(() {
    realFetch = globalContext['fetch'];
    // A body of [chunks] that then closes, errors or stays open ('hang'),
    // and errors when the request is aborted, as a real body does.
    globalContext['fsfBody'] = eval('''function(signal, chunks, end) {
      return new ReadableStream({start(c) {
        for (const chunk of chunks) c.enqueue(new Uint8Array(chunk));
        signal.addEventListener('abort', () => {
          try { c.error(signal.reason); } catch (_) {}
        });
        if (end === 'close') c.close();
        if (end === 'error') c.error(new TypeError('network dropped'));
      }});
    }''');
  });

  setUp(() async {
    final root = await window.navigator.storage.getDirectory().toDart;
    directory = await root
        .getDirectoryHandle(
          'save_test_${DateTime.now().microsecondsSinceEpoch}',
          FileSystemGetDirectoryOptions(create: true),
        )
        .toDart;
  });

  tearDown(() => globalContext['fetch'] = realFetch);

  /// Makes `fetch` call [respond], a JS function of the abort signal that
  /// returns a Response, or null to never answer. Counts the calls in
  /// `fsfFetchCalls`.
  void stubFetch(String respond) {
    globalContext['fsfFetchCalls'] = 0.toJS;
    globalContext['fetch'] = eval('''function(url, init) {
      window.fsfFetchCalls++;
      const signal = init.signal;
      return new Promise((resolve, reject) => {
        signal.addEventListener('abort', () => reject(signal.reason));
        const response = ($respond)(signal);
        if (response) resolve(response);
      });
    }''');
  }

  int fetchCalls() => (globalContext['fsfFetchCalls'] as JSNumber).toDartInt;

  /// A 200 response with [chunks] and the [end] of `fsfBody`.
  String body(
    List<List<int>> chunks, {
    String end = 'close',
    Map<String, String> headers = const {},
  }) {
    final h = headers.entries.map((e) => "'${e.key}': '${e.value}'").join(',');
    return '(signal) => new Response('
        'fsfBody(signal, ${chunks.toString()}, "$end"), '
        '{status: 200, headers: {$h}})';
  }

  Stream<SaveProgress> download({
    Duration timeout = const Duration(seconds: 5),
    ConflictResolution conflictResolution = ConflictResolution.autoRename,
  }) => saver.saveAs(
    input: SaveInput.network(
      url: 'https://example.com/data.bin',
      timeout: timeout,
    ),
    fileType: bin,
    fileName: 'data',
    saveLocation: WebPickedDirectoryLocation(directory),
    conflictResolution: conflictResolution,
  );

  Future<Uint8List?> contentOf(String name) async {
    try {
      final handle = await directory.getFileHandle(name).toDart;
      final file = await handle.getFile().toDart;
      return (await file.arrayBuffer().toDart).toDart.asUint8List();
    } catch (_) {
      return null;
    }
  }

  Future<void> writeFile(String name, List<int> content) async {
    final handle = await directory
        .getFileHandle(name, FileSystemGetFileOptions(create: true))
        .toDart;
    final writable = await handle.createWritable().toDart;
    await writable
        .write(Uint8List.fromList(content).toJS as FileSystemWriteChunkType)
        .toDart;
    await writable.close().toDart;
  }

  FileSaverException errorOf(List<SaveProgress> events) =>
      (events.last as SaveProgressError).exception;

  group('saveAs a download into a picked directory', () {
    test('streams the body into the file, with progress', () async {
      stubFetch(
        body(
          [
            [1, 2, 3],
            [4, 5],
          ],
          headers: {'content-length': '5'},
        ),
      );

      final events = await download().toList();

      expect(events.first, isA<SaveProgressStarted>());
      final updates = events.whereType<SaveProgressUpdate>();
      expect(updates.map((e) => e.progress), [0.6, 1.0]);
      expect(updates.map((e) => e.bytesWritten), [3, 5]);
      expect(updates.map((e) => e.totalBytes), [5, 5]);
      expect(
        (events.last as SaveProgressComplete).uri,
        Uri(scheme: 'web-directory', path: 'data.bin'),
      );
      expect(await contentOf('data.bin'), [1, 2, 3, 4, 5]);
    });

    test('a body without content-length reports the bytes written, of an '
        'unknown size', () async {
      stubFetch(
        body([
          [1, 2, 3],
          [4, 5],
        ]),
      );

      final events = await download().toList();

      final updates = events.whereType<SaveProgressUpdate>();
      expect(updates.map((e) => e.bytesWritten), [3, 5]);
      expect(updates.map((e) => e.totalBytes), [null, null]);
      expect(updates.map((e) => e.progress), [0.0, 0.0]);
      expect(events.last, isA<SaveProgressComplete>());
    });

    test('a compressed body reports the bytes written, of an unknown size, '
        'as its content-length is that of the encoded body', () async {
      stubFetch(
        body(
          [
            [1, 2, 3, 4, 5, 6],
          ],
          headers: {'content-length': '3', 'content-encoding': 'gzip'},
        ),
      );

      final events = await download().toList();

      final updates = events.whereType<SaveProgressUpdate>();
      expect(updates.map((e) => e.bytesWritten), [6]);
      expect(updates.map((e) => e.totalBytes), [null]);
      expect(events.last, isA<SaveProgressComplete>());
    });

    test('a response without a body saves an empty file', () async {
      stubFetch('() => new Response(null, {status: 204})');

      final events = await download().toList();

      expect(events.last, isA<SaveProgressComplete>());
      expect(await contentOf('data.bin'), isEmpty);
    });

    test('a non-2xx status is a NetworkException with the status code, and '
        'creates no file', () async {
      stubFetch('() => new Response("missing", {status: 404})');

      final events = await download().toList();

      expect(
        errorOf(events),
        isA<NetworkException>().having((e) => e.statusCode, 'statusCode', 404),
      );
      expect(await contentOf('data.bin'), isNull);
    });

    test('a failed connection is a NetworkException', () async {
      stubFetch('() => { throw new TypeError("Failed to fetch"); }');

      final events = await download().toList();

      expect(errorOf(events), isA<NetworkException>());
    });

    test('a body that fails is a NetworkException and deletes the new '
        'file', () async {
      stubFetch(
        body([
          [1, 2],
        ], end: 'error'),
      );

      final events = await download().toList();

      expect(
        errorOf(events),
        isA<NetworkException>().having(
          (e) => e.message,
          'message',
          contains('network dropped'),
        ),
      );
      expect(await contentOf('data.bin'), isNull);
    });

    test('a failed overwrite keeps the original', () async {
      await writeFile('data.bin', [9, 9]);
      stubFetch(
        body([
          [1, 2],
        ], end: 'error'),
      );

      final events = await download(
        conflictResolution: ConflictResolution.overwrite,
      ).toList();

      expect(errorOf(events), isA<NetworkException>());
      expect(await contentOf('data.bin'), [9, 9]);
    });

    test(
      'a server that never answers times out with NetworkException',
      () async {
        stubFetch('() => null');

        final events = await download(
          timeout: const Duration(milliseconds: 100),
        ).toList();

        expect(
          errorOf(events),
          isA<NetworkException>().having(
            (e) => e.message,
            'message',
            contains('No response'),
          ),
        );
      },
    );

    test('a stalled body times out with NetworkException and deletes the '
        'file', () async {
      stubFetch(
        body([
          [1, 2],
        ], end: 'hang'),
      );

      final events = await download(
        timeout: const Duration(milliseconds: 100),
      ).toList();

      expect(
        errorOf(events),
        isA<NetworkException>().having(
          (e) => e.message,
          'message',
          contains('No data received'),
        ),
      );
      expect(await contentOf('data.bin'), isNull);
    });

    test('cancelling completes once the partial file is deleted', () async {
      stubFetch(
        body(
          [
            [1, 2],
          ],
          end: 'hang',
          headers: {'content-length': '100'},
        ),
      );
      final events = <SaveProgress>[];
      final firstUpdate = Completer<void>();
      final subscription = download().listen((event) {
        events.add(event);
        if (event is SaveProgressUpdate && !firstUpdate.isCompleted) {
          firstUpdate.complete();
        }
      });
      await firstUpdate.future;
      expect(await contentOf('data.bin'), isNotNull);

      await subscription.cancel();

      expect(await contentOf('data.bin'), isNull);
      await pumpEventQueue();
      expect(events.last, isA<SaveProgressUpdate>());
    });

    test('skip of an existing file downloads nothing', () async {
      await writeFile('data.bin', [9]);
      stubFetch(body([]));

      final events = await download(
        conflictResolution: ConflictResolution.skip,
      ).toList();

      expect(events.last, isA<SaveProgressComplete>());
      expect(fetchCalls(), 0);
      expect(await contentOf('data.bin'), [9]);
    });
  });

  group('saveAs bytes into a picked directory', () {
    test('reports the bytes written once the file is written', () async {
      final events = await saver
          .saveAs(
            input: SaveInput.bytes(Uint8List.fromList([1, 2])),
            fileType: bin,
            fileName: 'data',
            saveLocation: WebPickedDirectoryLocation(directory),
          )
          .toList();

      final updates = events.whereType<SaveProgressUpdate>();
      expect(updates.map((e) => (e.bytesWritten, e.totalBytes, e.progress)), [
        (2, 2, 1.0),
      ]);
      expect(events.last, isA<SaveProgressComplete>());
    });

    test('writes the file and autoRenames on a conflict', () async {
      Future<SaveProgress> save() => saver
          .saveAs(
            input: SaveInput.bytes(Uint8List.fromList([1, 2])),
            fileType: bin,
            fileName: 'data',
            saveLocation: WebPickedDirectoryLocation(directory),
          )
          .last;

      expect(
        (await save() as SaveProgressComplete).uri,
        Uri(scheme: 'web-directory', path: 'data.bin'),
      );
      expect(
        (await save() as SaveProgressComplete).uri,
        Uri(scheme: 'web-directory', path: 'data (1).bin'),
      );
      expect(await contentOf('data (1).bin'), [1, 2]);
    });
  });

  group('saves of the same name into a picked directory at the same time', () {
    Future<SaveProgress> saveBytes(List<int> content) => saver
        .saveAs(
          input: SaveInput.bytes(Uint8List.fromList(content)),
          fileType: bin,
          fileName: 'data',
          saveLocation: WebPickedDirectoryLocation(directory),
        )
        .last;

    /// The name in the URI of a [SaveProgressComplete].
    String savedName(SaveProgress event) =>
        Uri.decodeComponent((event as SaveProgressComplete).uri.path);

    test('each get their own file', () async {
      final results = await Future.wait([
        saveBytes([1]),
        saveBytes([2]),
      ]);

      final names = results.map(savedName).toList();
      expect(names.toSet(), {'data.bin', 'data (1).bin'});
      expect(await contentOf(names[0]), [1]);
      expect(await contentOf(names[1]), [2]);
    });
  });

  group('saveNetwork with headers (browser download)', () {
    Stream<SaveProgress> download() => saver.saveNetwork(
      url: 'https://example.com/data.bin',
      headers: const {'Authorization': 'Bearer x'},
      fileName: 'data',
      fileType: bin,
    );

    test(
      'a non-2xx status is a NetworkException with the status code',
      () async {
        stubFetch('() => new Response("", {status: 403})');

        final events = await download().toList();

        expect(
          errorOf(events),
          isA<NetworkException>().having(
            (e) => e.statusCode,
            'statusCode',
            403,
          ),
        );
      },
    );

    test('a body that fails is a NetworkException', () async {
      stubFetch(
        body([
          [1],
        ], end: 'error'),
      );

      final events = await download().toList();

      expect(errorOf(events), isA<NetworkException>());
    });
  });

  group('invalid input', () {
    test('throws synchronously, as on the other platforms', () {
      expect(
        () => saver.saveBytes(
          fileBytes: Uint8List(0),
          fileType: bin,
          fileName: 'data',
        ),
        throwsA(isA<InvalidInputException>()),
      );
      expect(
        () => saver.saveFile(filePath: '/x', fileType: bin, fileName: 'data'),
        throwsA(isA<InvalidInputException>()),
      );
    });
  });
}
