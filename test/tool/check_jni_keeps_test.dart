@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/check_jni_keeps.dart';

void main() {
  group('jniLookups', () {
    test('reads classes, constructors, fields and methods', () {
      const bindings = r'''
extension type Foo$Companion._(jni$_.JObject _$this) {
  static final _class = jni$_.JClass.forName(
    r'com/example/Foo$Companion',
  );
  static final _id_new$ = _class.constructorId(
    r'(Lkotlin/jvm/internal/DefaultConstructorMarker;)V',
  );
}

extension type Foo._(jni$_.JObject _$this) implements jni$_.JObject {
  static final _class = jni$_.JClass.forName(r'com/example/Foo');
  static final _id_Companion = _class.staticFieldId(
    r'Companion',
    r'Lcom/example/Foo$Companion;',
  );
  static final _id_save = Foo._class.instanceMethodId(
    r'save',
    r'([BLjava/lang/String;)J',
  );
}
''';

      expect(jniLookups(bindings), {
        r'Lcom/example/Foo$Companion;',
        r'Lcom/example/Foo$Companion;-><init>:(Lkotlin/jvm/internal/DefaultConstructorMarker;)V',
        'Lcom/example/Foo;',
        r'Lcom/example/Foo;->Companion:Lcom/example/Foo$Companion;',
        'Lcom/example/Foo;->save:([BLjava/lang/String;)J',
      });
    });

    test('finds every lookup in the real bindings', () {
      final bindings = File(bindingsPath).readAsStringSync();
      final lookups = jniLookups(bindings);

      // One entry per JClass.forName and per *Id(...) call. A jnigen update
      // that changes their shape would otherwise silently shrink the check.
      final calls = RegExp(
        r'JClass\.forName\(|_class\s*\.(constructorId|(static|instance)(Method|Field)Id)\(',
      ).allMatches(bindings).length;
      expect(lookups, hasLength(calls));

      expect(
        lookups,
        containsAll([
          'Lcom/vanvixi/file_saver_ffi/FileSaver;',
          'Lcom/vanvixi/file_saver_ffi/FileSaver;-><init>:(J)V',
          'Lcom/vanvixi/file_saver_ffi/models/ProgressCallback;->onEvent:(IDLjava/lang/String;Ljava/lang/String;)V',
        ]),
      );
    });
  });

  test('dexMembers reads classes and members from dexdump output', () {
    // Trimmed from `dexdump app-release.apk`.
    const dexdump = '''
Class #186            -
  Class descriptor  : 'Lcom/vanvixi/file_saver_ffi/models/ProgressCallback;'
  Access flags      : 0x0601 (PUBLIC INTERFACE ABSTRACT)
  Superclass        : 'Ljava/lang/Object;'
  Interfaces        -
  Static fields     -
  Instance fields   -
  Direct methods    -
  Virtual methods   -
    #0              : (in Lcom/vanvixi/file_saver_ffi/models/ProgressCallback;)
      name          : 'onEvent'
      type          : '(IDLjava/lang/String;Ljava/lang/String;)V'
      access        : 0x0401 (PUBLIC ABSTRACT)
      code          : (none)

Class #187            -
  Class descriptor  : 'Lr0/e;'
  Access flags      : 0x0401 (PUBLIC ABSTRACT)
  Superclass        : 'Landroid/app/Activity;'
  Static fields     -
    #0              : (in Lr0/e;)
      name          : 'e'
      type          : 'I'
      access        : 0x0019 (PUBLIC STATIC FINAL)
''';

    expect(dexMembers(dexdump), {
      'Lcom/vanvixi/file_saver_ffi/models/ProgressCallback;',
      'Lcom/vanvixi/file_saver_ffi/models/ProgressCallback;->onEvent:(IDLjava/lang/String;Ljava/lang/String;)V',
      'Lr0/e;',
      'Lr0/e;->e:I',
    });
  });
}
