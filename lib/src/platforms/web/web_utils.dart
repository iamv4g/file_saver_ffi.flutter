// Temporary CI probe, do not merge.
import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

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

class WebUtils {
  WebUtils._();

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
    _anchorClick(
      document.createElement('a') as HTMLAnchorElement
        ..href = objectUrl
        ..download = fullName,
    );
    URL.revokeObjectURL(objectUrl);
  }

  static void triggerUrlDownload(String url, String fullName, String mimeType) {
    _anchorClick(
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

  static Future<Response> fetch(
    String url,
    AbortController controller, {
    Map<String, String>? headers,
  }) async {
    try {
      return await window
          .fetch(
            url.toJS,
            RequestInit(
              method: 'GET',
              headers: headers.toJSHeaders,
              signal: controller.signal,
            ),
          )
          .toDart;
    } catch (e) {
      // fetch() will throw on network errors or CORS issues.
      throw NetworkException(e.toString());
    }
  }

  static Stream<SaveProgress> executeSave(
    Future<void> Function(
      WebCancellationToken token,
      MultiStreamController<SaveProgress> controller,
    )
    operation,
  ) {
    return Stream.multi((controller) {
      final token = WebCancellationToken();
      controller.addSync(const SaveProgressStarted());

      operation(token, controller)
          .then((_) {
            if (!controller.isClosed) controller.closeSync();
          })
          .catchError((Object e) {
            if (token.isCancelled) {
              if (!controller.isClosed) {
                controller.addSync(const SaveProgressCancelled());
                controller.closeSync();
              }
              return;
            }
            if (!controller.isClosed) {
              final ex = e is FileSaverException
                  ? e
                  : FileSaverException.fromObj(e);
              controller.addSync(SaveProgressError(ex));
              controller.closeSync();
            }
          });

      controller.onCancel = () {
        token.cancel();
        Future.delayed(const Duration(milliseconds: 500), () {
          if (!controller.isClosed) {
            controller.addSync(const SaveProgressCancelled());
            controller.closeSync();
          }
        });
      };
    });
  }
}
