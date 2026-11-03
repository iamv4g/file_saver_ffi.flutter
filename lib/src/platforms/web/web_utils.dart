import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/foundation.dart';
import 'package:web/web.dart';

import '../../exceptions/file_saver_exceptions.dart';
import '../../models/save_progress.dart';
import 'web_cancellation_token.dart';

extension on Map<String, String>? {
  Headers get toJSHeaders {
    final h = Headers();
    this?.forEach((key, value) => h.append(key, value));
    return h;
  } // Converts Dart Map to JS object for headers.
}

/// Converts a rejected File System Access call into a [FileSaverException].
///
/// Matches on the text, which names the `DOMException` under both dart2js
/// and dart2wasm.
FileSaverException mapFsaError(Object e) {
  if (e is FileSaverException) return e;
  final text = e.toString();
  if (text.contains('QuotaExceededError')) return const StorageFullException();
  if (text.contains('NotAllowedError') || text.contains('SecurityError')) {
    return PermissionDeniedException(text);
  }
  return FileIOException(text);
}

class WebUtils {
  WebUtils._();

  /// How long a Blob download keeps its object URL. Revoking it right after
  /// the click can cancel the download in some browsers, which start it
  /// asynchronously.
  @visibleForTesting
  static Duration revokeDelay = const Duration(seconds: 60);

  /// Clicks the download link. Tests replace it to see the link without
  /// starting a download.
  @visibleForTesting
  static void Function(HTMLAnchorElement anchor) clickAnchor = _anchorClick;

  static void triggerBytesDownload(
    Uint8List bytes,
    String fullName,
    String mimeType,
  ) {
    final blob = Blob([bytes.toJS].toJS, BlobPropertyBag(type: mimeType));
    triggerBlobDownload(blob, fullName);
  }

  static void triggerBlobDownload(Blob blob, String fullName) {
    final objectUrl = URL.createObjectURL(blob);
    clickAnchor(
      document.createElement('a') as HTMLAnchorElement
        ..href = objectUrl
        ..download = fullName,
    );
    Timer(revokeDelay, () => URL.revokeObjectURL(objectUrl));
  }

  static void triggerUrlDownload(String url, String fullName, String mimeType) {
    clickAnchor(
      document.createElement('a') as HTMLAnchorElement
        ..href = url
        ..type = mimeType
        ..download = fullName,
    );
  }

  static void _anchorClick(HTMLAnchorElement anchor) {
    document.body!.append(anchor);
    anchor.click();
    anchor.remove();
  }

  /// Requests [url] with [headers], aborted when [token] is cancelled.
  ///
  /// Returns the body, null when the response has none, and its length if
  /// known. A compressed response has no known length, because the body is
  /// decompressed. [timeout] limits waiting for the response; failures are
  /// [NetworkException]s, with the status code for a non-2xx response.
  static Future<({ReadableStreamDefaultReader? reader, int? length})> fetch(
    String url,
    Map<String, String>? headers,
    Duration timeout,
    WebCancellationToken token,
  ) async {
    final timer = Timer(timeout, token.timeOut);
    final Response response;
    try {
      response = await window
          .fetch(
            url.toJS,
            RequestInit(
              method: 'GET',
              headers: headers.toJSHeaders,
              signal: token.signal,
            ),
          )
          .toDart;
    } catch (e) {
      token.check();
      // fetch() rejects on network errors and CORS failures.
      throw token.timedOut
          ? NetworkException('No response within ${timeout.inSeconds}s')
          : NetworkException('Connection failed: $e');
    } finally {
      timer.cancel();
    }

    if (!response.ok) {
      throw NetworkException(
        response.statusText.isEmpty
            ? 'HTTP ${response.status}'
            : 'HTTP ${response.status}: ${response.statusText}',
        response.status,
      );
    }
    final compressed = response.headers.get('content-encoding') != null;
    return (
      reader: response.body?.getReader() as ReadableStreamDefaultReader?,
      length: compressed
          ? null
          : int.tryParse(response.headers.get('content-length') ?? ''),
    );
  }

  /// Reads [reader] to the end and calls [onChunk] with each chunk, waiting
  /// for it before the next read. Does nothing for a null [reader] (no body).
  ///
  /// [timeout] limits each wait for more of the body. Failures are
  /// [NetworkException]s, and a cancelled [token] throws
  /// [CancelledException].
  static Future<void> read(
    ReadableStreamDefaultReader? reader,
    Duration timeout,
    WebCancellationToken token,
    Future<void> Function(JSUint8Array chunk) onChunk,
  ) async {
    if (reader == null) return;
    while (true) {
      final timer = Timer(timeout, token.timeOut);
      final ReadableStreamReadResult result;
      try {
        result = await reader.read().toDart;
      } catch (e) {
        token.check();
        throw token.timedOut
            ? NetworkException('No data received for ${timeout.inSeconds}s')
            : NetworkException('Download failed: $e');
      } finally {
        timer.cancel();
      }
      token.check();
      if (result.done) return;
      await onChunk(result.value! as JSUint8Array);
    }
  }

  /// The number of bytes in [chunk], without copying it.
  static int lengthOf(JSUint8Array chunk) =>
      (chunk.getProperty('length'.toJS) as JSNumber).toDartInt;

  /// Runs [operation] as a save: emits [SaveProgressStarted], the events
  /// [operation] emits, and a [SaveProgressError] if it throws.
  ///
  /// [operation] deletes what it wrote when it fails or is cancelled. Once the
  /// subscription is cancelled nothing more is emitted, and the cancel
  /// completes when [operation] has ended.
  static Stream<SaveProgress> executeSave(
    Future<void> Function(
      WebCancellationToken token,
      void Function(SaveProgress event) emit,
    )
    operation,
  ) {
    return Stream.multi((controller) {
      final token = WebCancellationToken();

      void emit(SaveProgress event) {
        if (!token.isCancelled && !controller.isClosed) {
          controller.addSync(event);
        }
      }

      Future<void> run() async {
        try {
          await operation(token, emit);
        } catch (e) {
          emit(SaveProgressError(FileSaverException.fromObj(e)));
        } finally {
          if (!controller.isClosed) controller.closeSync();
        }
      }

      controller.addSync(const SaveProgressStarted());
      final done = run();
      controller.onCancel = () {
        token.cancel();
        return done;
      };
    });
  }
}
