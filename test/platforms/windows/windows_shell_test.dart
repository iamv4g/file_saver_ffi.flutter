import 'dart:ffi';
import 'dart:io';

import 'package:file_saver_ffi/src/platforms/windows/windows_shell.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('ShellExecuteInfo matches the 64-bit SHELLEXECUTEINFOW layout', () {
    // sizeof(SHELLEXECUTEINFOW) on x64 and arm64 Windows. A wrong size makes
    // ShellExecuteExW fail with ERROR_INVALID_PARAMETER.
    expect(sizeOf<ShellExecuteInfo>(), 112);
  });

  test(
    'shellOpen reports SE_ERR_FNF for a missing file without running cmd',
    () async {
      final dir = await Directory.systemTemp.createTemp('windows_shell_test');
      addTearDown(() => dir.delete(recursive: true));

      // If the path went through cmd.exe, `&calc&` would start Calculator.
      // ShellExecuteExW treats the whole string as one file name instead.
      final path = p.join(dir.path, 'missing&calc&x.txt');

      // SEE_MASK_FLAG_NO_UI keeps the Shell from showing an error dialog.
      final code = await shellOpen(path, extraMask: seeMaskFlagNoUi);

      // SE_ERR_FNF (2) or SE_ERR_PNF (3).
      expect(code, anyOf(2, 3));
    },
    skip: !Platform.isWindows ? 'Calls shell32.dll' : false,
  );
}
