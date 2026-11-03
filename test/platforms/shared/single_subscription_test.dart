import 'dart:async';

import 'package:file_saver_ffi/src/platforms/shared/single_subscription.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('runs onListen once and throws on a second listen', () async {
    var listens = 0;
    final stream = singleSubscription<int>((controller) {
      listens++;
      controller
        ..addSync(1)
        ..closeSync();
    });

    expect(stream.isBroadcast, isFalse);
    expect(await stream.toList(), [1]);
    expect(() => stream.listen(null), throwsStateError);
    expect(listens, 1);
  });

  test('a listener that cancels early still leaves no second run', () async {
    var listens = 0;
    final stream = singleSubscription<int>((controller) {
      listens++;
      controller.addSync(1);
    });

    expect(await stream.first, 1);
    expect(() => stream.first, throwsStateError);
    expect(listens, 1);
  });

  test('passes the cancel future of onCancel through', () async {
    final cleanedUp = Completer<void>();
    final stream = singleSubscription<int>((controller) {
      controller.onCancel = () => cleanedUp.future;
    });
    final subscription = stream.listen(null);

    var cancelled = false;
    final cancel = subscription.cancel().then((_) => cancelled = true);
    await Future<void>.delayed(Duration.zero);
    expect(cancelled, isFalse);

    cleanedUp.complete();
    await cancel;
    expect(cancelled, isTrue);
  });
}
