import 'dart:ffi';

import 'package:ffi/ffi.dart';

/// Looks up the function of the C header
/// (darwin/file_saver_ffi/Sources/file_saver_ffi/FFI/file_saver_ffi.h) named
/// [name], for `FileSaverFFI.fromLookup`.
///
/// It asks the Objective-C class `FileSaverFFISymbols`
/// (Sources/FileSaverDartApi/file_saver_symbols.m) for the address, instead of
/// looking the name up with `DynamicLibrary.process()`. An app that links the
/// plugin statically (Swift Package Manager, or CocoaPods with static
/// linkage) has no such names once Xcode archives it with
/// STRIP_STYLE = all, its default for apps. The Objective-C runtime keeps
/// class names, and the symbols of libobjc, a system library, are never
/// stripped.
///
/// Throws an [ArgumentError] like [DynamicLibrary.lookup] for a name the class
/// doesn't know, and a [StateError] if the app has no such class.
Pointer<T> lookupDarwinSymbol<T extends NativeType>(String name) =>
    _fileSaverSymbols(name).cast();

final _fileSaverSymbols = ObjCPointerFunction(
  'FileSaverFFISymbols',
  'addressOf:',
);

/// The class method [selector] of the Objective-C class [className], which
/// takes a C string and returns a pointer, such as
/// `+[FileSaverFFISymbols addressOf:]`.
final class ObjCPointerFunction {
  ObjCPointerFunction(this.className, this.selector);

  final String className;
  final String selector;

  late final Pointer<Void> _class = () {
    final cls = using(
      (arena) => _getClass(className.toNativeUtf8(allocator: arena)),
    );
    if (cls == nullptr) {
      throw StateError(
        'The app has no Objective-C class $className: the native code of '
        'file_saver_ffi is not linked into it.',
      );
    }
    return cls;
  }();

  late final Pointer<Void> _selector = using(
    (arena) => _registerName(selector.toNativeUtf8(allocator: arena)),
  );

  late final _ObjCPointerMethod _call = () {
    final method = _getClassMethod(_class, _selector);
    if (method == nullptr) {
      throw StateError('$className has no class method +$selector.');
    }
    return _getImplementation(method)
        .cast<NativeFunction<_NativeObjCPointerMethod>>()
        .asFunction<_ObjCPointerMethod>();
  }();

  /// Calls the method with [argument], and throws an [ArgumentError] if it
  /// returns null.
  Pointer<Void> call(String argument) {
    final call = _call;
    final result = using(
      (arena) =>
          call(_class, _selector, argument.toNativeUtf8(allocator: arena)),
    );
    if (result == nullptr) {
      throw ArgumentError.value(
        argument,
        'name',
        'Failed to look up symbol: +[$className $selector] returned NULL',
      );
    }
    return result;
  }
}

/// The implementation of such a method: `IMP` with the class, the selector
/// and the C string.
typedef _NativeObjCPointerMethod =
    Pointer<Void> Function(Pointer<Void>, Pointer<Void>, Pointer<Utf8>);
typedef _ObjCPointerMethod = _NativeObjCPointerMethod;

final _objc = DynamicLibrary.process();

final _getClass = _objc
    .lookupFunction<
      Pointer<Void> Function(Pointer<Utf8>),
      Pointer<Void> Function(Pointer<Utf8>)
    >('objc_getClass');

final _registerName = _objc
    .lookupFunction<
      Pointer<Void> Function(Pointer<Utf8>),
      Pointer<Void> Function(Pointer<Utf8>)
    >('sel_registerName');

final _getClassMethod = _objc
    .lookupFunction<
      Pointer<Void> Function(Pointer<Void>, Pointer<Void>),
      Pointer<Void> Function(Pointer<Void>, Pointer<Void>)
    >('class_getClassMethod');

final _getImplementation = _objc
    .lookupFunction<
      Pointer<Void> Function(Pointer<Void>),
      Pointer<Void> Function(Pointer<Void>)
    >('method_getImplementation');
