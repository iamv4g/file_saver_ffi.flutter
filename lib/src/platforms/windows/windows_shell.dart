import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

/// `SHELLEXECUTEINFOW` from `shellapi.h`.
///
/// The `hIcon`/`hMonitor` union is declared as a single pointer field; both
/// members are handles, so the layout is the same.
final class ShellExecuteInfo extends Struct {
  @Uint32()
  external int cbSize;
  @Uint32()
  external int fMask;
  external Pointer<Void> hwnd;
  external Pointer<Utf16> lpVerb;
  external Pointer<Utf16> lpFile;
  external Pointer<Utf16> lpParameters;
  external Pointer<Utf16> lpDirectory;
  @Int32()
  external int nShow;
  external Pointer<Void> hInstApp;
  external Pointer<Void> lpIDList;
  external Pointer<Utf16> lpClass;
  external Pointer<Void> hkeyClass;
  @Uint32()
  external int dwHotKey;
  external Pointer<Void> hIconOrMonitor;
  external Pointer<Void> hProcess;
}

/// Waits for the launch to finish before returning, so COM can be
/// uninitialized right after the call.
const int seeMaskNoAsync = 0x00000100;

/// Suppresses error dialogs (e.g. "Windows can't find …"). Only used by tests.
const int seeMaskFlagNoUi = 0x00000400;

/// `SE_ERR_NOASSOC`: no application is associated with the file type.
const int seErrNoAssoc = 31;

const int _swShowNormal = 1;
const int _coinitApartmentThreaded = 0x2;
const int _coinitDisableOle1Dde = 0x4;

/// Opens [path] with its default application through `ShellExecuteExW`.
///
/// The path is passed to the Shell as a single string, so characters such as
/// `&`, `|` or `^` in a file name are never interpreted as commands (unlike
/// `cmd /c start`).
///
/// Runs on a separate isolate with COM initialized as single-threaded
/// apartment, as required for `ShellExecuteEx`, so the calling isolate is not
/// blocked while the Shell launches the application.
///
/// Returns 0 on success, otherwise the `SE_ERR_*` code reported in
/// `hInstApp` (or -1 if the Shell did not report one).
Future<int> shellOpen(String path, {int extraMask = 0}) {
  return Isolate.run(() => shellOpenSync(path, extraMask: extraMask));
}

/// Synchronous body of [shellOpen]. Must run on a thread that may initialize
/// COM, so call it through [shellOpen] unless already on a worker isolate.
int shellOpenSync(String path, {int extraMask = 0}) {
  final ole32 = DynamicLibrary.open('ole32.dll');
  final shell32 = DynamicLibrary.open('shell32.dll');

  final coInitializeEx = ole32
      .lookupFunction<
        Int32 Function(Pointer<Void>, Uint32),
        int Function(Pointer<Void>, int)
      >('CoInitializeEx');
  final coUninitialize = ole32.lookupFunction<Void Function(), void Function()>(
    'CoUninitialize',
  );
  final shellExecuteEx = shell32
      .lookupFunction<
        Int32 Function(Pointer<ShellExecuteInfo>),
        int Function(Pointer<ShellExecuteInfo>)
      >('ShellExecuteExW');

  // S_OK (0) and S_FALSE (1) must be balanced with CoUninitialize. A failure
  // such as RPC_E_CHANGED_MODE means COM is already set up on this thread.
  final hr = coInitializeEx(
    nullptr,
    _coinitApartmentThreaded | _coinitDisableOle1Dde,
  );

  return using((arena) {
    try {
      final info = arena<ShellExecuteInfo>()
        ..ref.cbSize = sizeOf<ShellExecuteInfo>()
        ..ref.fMask = seeMaskNoAsync | extraMask
        ..ref.lpFile = path.toNativeUtf16(allocator: arena)
        ..ref.nShow = _swShowNormal;

      if (shellExecuteEx(info) != 0) return 0;

      final code = info.ref.hInstApp.address;
      return code > 0 && code <= 32 ? code : -1;
    } finally {
      if (hr >= 0) coUninitialize();
    }
  });
}
