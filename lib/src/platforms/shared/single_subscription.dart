import 'dart:async';

/// A single-subscription stream that calls [onListen] when it is listened
/// to, as [Stream.multi] does.
///
/// A save starts in [onListen], so a [Stream.multi] would run it once per
/// listener and save the file again. Listening to this stream a second time
/// throws a [StateError] instead, as with any single-subscription stream.
Stream<T> singleSubscription<T>(
  void Function(MultiStreamController<T> controller) onListen,
) => _SingleSubscriptionStream(Stream.multi(onListen));

final class _SingleSubscriptionStream<T> extends Stream<T> {
  _SingleSubscriptionStream(this._stream);

  /// Null once listened to.
  Stream<T>? _stream;

  @override
  StreamSubscription<T> listen(
    void Function(T event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    final stream = _stream;
    if (stream == null) {
      throw StateError('Stream has already been listened to.');
    }
    _stream = null;
    return stream.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }
}
