import 'dart:js_interop';

import 'package:web/web.dart';

import '../../exceptions/file_saver_exceptions.dart';

/// Cancellation and timeout of one web save.
///
/// [cancel] and [timeOut] abort the request through [signal]. The save
/// checks [isCancelled] after each step and deletes what it wrote itself.
class WebCancellationToken {
  final _controller = AbortController();
  var _isCancelled = false;
  var _timedOut = false;

  bool get isCancelled => _isCancelled;

  /// Whether [timeOut] aborted the request.
  bool get timedOut => _timedOut;

  /// Aborts the request of the save.
  AbortSignal get signal => _controller.signal;

  void cancel() {
    if (_isCancelled) return;
    _isCancelled = true;
    _controller.abort('Cancelled'.toJS);
  }

  void timeOut() {
    if (_isCancelled || _timedOut) return;
    _timedOut = true;
    _controller.abort('Timed out'.toJS);
  }

  /// Throws [CancelledException] once the save is cancelled.
  void check() {
    if (_isCancelled) throw const CancelledException();
  }
}
