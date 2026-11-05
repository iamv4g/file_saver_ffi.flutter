@TestOn('vm')
library;

import 'package:file_saver_ffi/file_saver_ffi.dart';
import 'package:file_saver_ffi/src/platforms/darwin/darwin_reply.dart';
import 'package:flutter_test/flutter_test.dart';

/// [callForDarwinReply], with the test posting what Swift would.
void main() {
  /// Calls [callForDarwinReply] and posts [message] to its port, as Swift
  /// does after the call has returned.
  Future<List<Object?>> reply(Object? message) =>
      callForDarwinReply((port) => Future(() => port.send(message)));

  test('completes with the message Swift posts', () async {
    expect(await reply([3, '42']), [3, '42']);
    expect(await reply([1, 1024, null]), [1, 1024, null]);
  });

  test('an error message fails with its exception', () async {
    await expectLater(
      reply([2, 'FILE_EXISTS', 'a.txt', null]),
      throwsA(
        isA<FileExistsException>().having((e) => e.fileName, 'name', 'a.txt'),
      ),
    );
    await expectLater(
      reply([2, 'NETWORK_ERROR', 'HTTP 404', 404]),
      throwsA(
        isA<NetworkException>().having((e) => e.statusCode, 'status', 404),
      ),
    );
  });

  test('a malformed message fails instead of leaving the call '
      'waiting', () async {
    for (final message in [
      null,
      'done',
      <Object?>[],
      <Object?>['3'],
      <Object?>[2],
    ]) {
      await expectLater(
        reply(message),
        throwsA(isA<NativePlatformException>()),
        reason: '$message',
      );
    }
  });

  test('only the first message counts', () async {
    final result = callForDarwinReply((port) {
      port
        ..send([3, '1'])
        ..send([2, 'FILE_IO_ERROR', 'late', null]);
    });

    expect(await result, [3, '1']);
  });

  test('a call that throws rethrows', () {
    expect(
      () => callForDarwinReply((port) => throw StateError('no session')),
      throwsStateError,
    );
  });
}
