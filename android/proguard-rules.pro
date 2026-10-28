# Consumer rules, merged into every app that depends on file_saver_ffi. Keep
# them scoped to what the plugin itself needs.
#
# The JNI bindings (lib/src/platforms/android/bindings.g.dart) look up these
# classes and members by name from Dart, which R8 can't see. CI checks the
# release APK against the bindings with tool/check_jni_keeps.dart.
-keep class com.vanvixi.file_saver_ffi.FileSaver { public *; }
-keep class com.vanvixi.file_saver_ffi.FileSaver$Companion { public *; }

# Implemented from Dart through java.lang.reflect.Proxy, by binary name.
-keep interface com.vanvixi.file_saver_ffi.models.ProgressCallback { *; }

# Types in the signatures of the members above. A member can only be found
# by its JNI descriptor if these keep their names too.
-keepnames interface com.vanvixi.file_saver_ffi.utils.StoragePermissionHandler
-keepnames class kotlin.jvm.internal.DefaultConstructorMarker
