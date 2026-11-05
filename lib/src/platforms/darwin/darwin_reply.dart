import 'dart:async';
import 'dart:isolate';

import '../../exceptions/file_saver_exceptions.dart';
import '../../models/save_progress.dart';
import '../shared/native_event_parser.dart';

/// Runs [call], which starts a Swift function that posts one message to the
/// port it is given, and completes with that message.
///
/// An error message (`[2, code, message, statusCode]`) fails with its
/// [FileSaverException], and a message that isn't a list starting with an
/// event code with a [NativePlatformException]. The port is closed after the
/// first message, or when [call] throws.
///
/// Kept free of `dart:ffi`, so it can be unit tested: callers pass
/// [SendPort.nativePort] on to Swift.
Future<List<Object?>> callForDarwinReply(void Function(SendPort port) call) {
  final completer = Completer<List<Object?>>();
  final receivePort = ReceivePort();
  receivePort.listen((Object? message) {
    receivePort.close();
    try {
      completer.complete(_checkReply(message));
    } on FileSaverException catch (e) {
      completer.completeError(e);
    } catch (_) {
      // An error message without its code or text.
      completer.completeError(
        NativePlatformException('Invalid reply from Swift: $message'),
      );
    }
  });
  try {
    call(receivePort.sendPort);
  } catch (_) {
    receivePort.close();
    rethrow;
  }
  return completer.future;
}

/// [message] if it is a reply other than an error. Throws the
/// [FileSaverException] of an error message.
List<Object?> _checkReply(Object? message) {
  if (message is! List<Object?> || message.isEmpty || message[0] is! int) {
    throw NativePlatformException('Invalid reply from Swift: $message');
  }
  if (message[0] == 2) {
    throw (parseDarwinMessage(message) as SaveProgressError).exception;
  }
  return message;
}
