// The Objective-C runtime exists only on Apple platforms. CI runs this in the
// Darwin unit tests job.
@TestOn('mac-os')
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:file_saver_ffi/src/platforms/darwin/darwin_symbols.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ObjCPointerFunction', () {
    test('calls a class method with a C string', () {
      // +[NSString stringWithUTF8String:] takes a C string and returns a
      // pointer, as +[FileSaverFFISymbols addressOf:] does.
      final stringWithUTF8String = ObjCPointerFunction(
        'NSString',
        'stringWithUTF8String:',
      );
      expect(stringWithUTF8String('abc'), isNot(nullptr));
      expect(stringWithUTF8String('d'), isNot(nullptr));
    });

    test('fails naming a class the app does not have', () {
      expect(
        () => ObjCPointerFunction('FileSaverNoSuchClass', 'addressOf:')('x'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('no Objective-C class FileSaverNoSuchClass'),
          ),
        ),
      );
    });

    test('fails naming a class method the class does not have', () {
      expect(
        () => ObjCPointerFunction('NSObject', 'addressOf:')('x'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'NSObject has no class method +addressOf:.',
          ),
        ),
      );
    });
  });

  test('lookupDarwinSymbol fails without the native code of the plugin', () {
    // flutter test doesn't link the plugin's native code.
    expect(
      () => lookupDarwinSymbol<Utf8>('file_saver_cancel'),
      throwsA(isA<StateError>()),
    );
  });
}
