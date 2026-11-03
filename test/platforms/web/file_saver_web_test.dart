@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:dir_picker/dir_picker.dart'
    show DirPickerPlatform, DirPickerWeb;
import 'package:file_saver_ffi/file_saver_ffi.dart';
import 'package:file_saver_ffi/src/platform_interface/file_saver_platform.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web/web.dart';

/// The directory picker and directory persistence on web, against a stubbed
/// `showDirectoryPicker()` and the origin private file system.
void main() {
  final saver = FileSaverWeb();
  const text = CustomFileType(ext: 'txt', mimeType: 'text/plain');
  late FileSystemDirectoryHandle directory;

  JSAny? eval(String code) =>
      globalContext.callMethod<JSAny?>('eval'.toJS, '($code)'.toJS);

  setUpAll(() {
    DirPickerPlatform.instance = DirPickerWeb();
    FileSaverPlatform.instance = saver;
    // Keeps the browser's picker, which the tests replace or remove.
    eval('''window.fsfPicker = Object.getOwnPropertyDescriptor(
      Window.prototype, 'showDirectoryPicker')''');
  });

  setUp(() async {
    final root = await window.navigator.storage.getDirectory().toDart;
    directory = await root
        .getDirectoryHandle(
          'web_test_${DateTime.now().microsecondsSinceEpoch}',
          FileSystemGetDirectoryOptions(create: true),
        )
        .toDart;
  });

  tearDown(() {
    eval('''(() => {
      delete window.showDirectoryPicker;
      if (window.fsfPicker) {
        Object.defineProperty(
          Window.prototype, 'showDirectoryPicker', window.fsfPicker);
      }
    })()''');
  });

  /// Makes `showDirectoryPicker()` run [picker], a JS function of its
  /// options, and records the options in `fsfPickerOptions`.
  void stubPicker(String picker) {
    globalContext['fsfPickedDirectory'] = directory;
    globalContext['showDirectoryPicker'] = eval('''function(options) {
      window.fsfPickerOptions = options;
      return ($picker)(options);
    }''');
  }

  /// Removes `showDirectoryPicker()`, as in Firefox and Safari.
  void removePicker() {
    eval('''(() => {
      delete window.showDirectoryPicker;
      delete Window.prototype.showDirectoryPicker;
    })()''');
  }

  group('pickDirectory', () {
    test('asks for write access and returns the directory', () async {
      stubPicker('() => Promise.resolve(window.fsfPickedDirectory)');

      final location = await FileSaver.pickDirectory();

      expect(location, isA<WebPickedDirectoryLocation>());
      expect(
        (location! as WebPickedDirectoryLocation).directoryHandle.name,
        directory.name,
      );
      final options = globalContext['fsfPickerOptions'] as JSObject;
      expect((options['mode'] as JSString).toDart, 'readwrite');
    });

    test('a picker error throws NativePlatformException with '
        'PICKER_ERROR', () async {
      stubPicker(
        '() => Promise.reject(new DOMException("No gesture", "SecurityError"))',
      );

      await expectLater(
        FileSaver.pickDirectory(),
        throwsA(
          isA<NativePlatformException>().having(
            (e) => e.code,
            'code',
            'PICKER_ERROR',
          ),
        ),
      );
    });

    test('without showDirectoryPicker it throws UnsupportedError', () async {
      removePicker();

      await expectLater(FileSaver.pickDirectory(), throwsUnsupportedError);
    });
  });

  group('the picker fallback of saveAs and openWriteAs', () {
    test(
      'without showDirectoryPicker, openWriteAs buffers in memory',
      () async {
        removePicker();

        final sink = await FileSaver.openWriteAs(
          fileName: 'log',
          fileType: text,
        );

        expect(sink, isNotNull);
        await sink!.cancel();
      },
    );

    test('a picker error is reported instead of falling back', () async {
      stubPicker(
        '() => Promise.reject(new DOMException("No gesture", "SecurityError"))',
      );

      await expectLater(
        FileSaver.openWriteAs(fileName: 'log', fileType: text),
        throwsA(isA<NativePlatformException>()),
      );
      final events = await FileSaver.saveAs(
        input: SaveInput.bytes(Uint8List.fromList([1])),
        fileName: 'log',
        fileType: text,
      ).toList();
      expect(
        (events.single as SaveProgressError).exception,
        isA<NativePlatformException>(),
      );
    });
  });

  group('persistDirectory', () {
    test('a restored directory can be saved into, until it is '
        'released', () async {
      final token = await FileSaver.persistDirectory(
        WebPickedDirectoryLocation(directory),
      );

      final restored = await FileSaver.restoreDirectory(token);
      expect(restored, isA<WebPickedDirectoryLocation>());
      final location = restored! as WebPickedDirectoryLocation;
      expect(location.directoryHandle.name, directory.name);
      expect(await location.hasAccess(), isTrue);

      final saved = await FileSaver.saveAsAsync(
        input: SaveInput.bytes(Uint8List.fromList('hi'.codeUnits)),
        fileName: 'note',
        fileType: text,
        saveLocation: location,
      );
      expect(saved, Uri(scheme: 'web-directory', path: 'note.txt'));
      final file = await (await directory.getFileHandle('note.txt').toDart)
          .getFile()
          .toDart;
      expect((await file.text().toDart).toDart, 'hi');

      await FileSaver.releaseDirectory(token);
      expect(await FileSaver.restoreDirectory(token), isNull);
    });

    test('the same directory gets the same token', () async {
      final location = WebPickedDirectoryLocation(directory);

      expect(
        await FileSaver.persistDirectory(location),
        await FileSaver.persistDirectory(location),
      );
    });

    test('a location without a directory handle throws '
        'InvalidInputException', () {
      expect(
        () => saver.persistDirectory(PickedDirectoryLocation(uri: Uri())),
        throwsA(isA<InvalidInputException>()),
      );
    });

    test('an unknown token restores nothing', () async {
      expect(await FileSaver.restoreDirectory('unknown'), isNull);
    });
  });
}
