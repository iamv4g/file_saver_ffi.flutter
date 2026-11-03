@TestOn('browser')
library;

import 'dart:js_interop';

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
}
