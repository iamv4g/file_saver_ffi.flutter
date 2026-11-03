@TestOn('browser')
library;

import 'dart:async';
import 'dart:js_interop';

import 'package:file_saver_ffi/src/models/save_progress.dart';
import 'package:file_saver_ffi/src/platforms/web/web_cancellation_token.dart';
import 'package:file_saver_ffi/src/platforms/web/web_utils.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web/web.dart';

void main() {
  final realClick = WebUtils.clickAnchor;
  final realDelay = WebUtils.revokeDelay;

  tearDown(() {
    WebUtils.clickAnchor = realClick;
    WebUtils.revokeDelay = realDelay;
  });

  Future<bool> readable(String url) async {
    try {
      await window.fetch(url.toJS).toDart;
      return true;
    } catch (_) {
      return false;
    }
  }

  test('a Blob download keeps its object URL for revokeDelay', () async {
    HTMLAnchorElement? clicked;
    WebUtils.clickAnchor = (anchor) => clicked = anchor;
    WebUtils.revokeDelay = const Duration(milliseconds: 200);

    WebUtils.triggerBlobDownload(
      Blob(['data'.toJS].toJS, BlobPropertyBag(type: 'text/plain')),
      'data.txt',
    );

    expect(clicked!.download, 'data.txt');
    // Still there after the click, while the browser starts the download.
    expect(await readable(clicked!.href), isTrue);

    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(await readable(clicked!.href), isFalse);
  });

  group('executeSave', () {
    test(
      'a save that has ended is not cancelled once its stream is done',
      () async {
        late WebCancellationToken token;
        final events = await WebUtils.executeSave((t, emit) async {
          token = t;
          emit(SaveProgressComplete(Uri(scheme: 'web-directory', path: 'a')));
        }).toList();

        expect(events.last, isA<SaveProgressComplete>());
        expect(token.isCancelled, isFalse);
      },
    );

    test('a second listen throws instead of running the save again', () async {
      var runs = 0;
      final stream = WebUtils.executeSave((token, emit) async => runs++);
      await stream.drain<void>();

      expect(() => stream.listen(null), throwsStateError);
      expect(runs, 1);
    });

    test(
      'cancelling a running save cancels its token and waits for it to end',
      () async {
        final ended = Completer<void>();
        late WebCancellationToken token;
        final subscription = WebUtils.executeSave((t, emit) async {
          token = t;
          await ended.future;
        }).listen(null);
        await Future<void>.delayed(Duration.zero);

        var cancelled = false;
        final cancel = subscription.cancel().then((_) => cancelled = true);
        await Future<void>.delayed(Duration.zero);
        expect(token.isCancelled, isTrue);
        expect(cancelled, isFalse);

        ended.complete();
        await cancel;
        expect(cancelled, isTrue);
      },
    );
  });
}
