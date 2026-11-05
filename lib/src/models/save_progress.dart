import 'package:flutter/foundation.dart';

import '../exceptions/file_saver_exceptions.dart';

/// Base sealed class for save progress events.
///
/// Use pattern matching to handle different event types:
/// ```dart
/// await for (final event in FileSaver.saveBytes(...)) {
///   switch (event) {
///     case SaveProgressStarted():
///       showLoadingIndicator();
///     case SaveProgressUpdate(:final progress):
///       updateProgressBar(progress);
///     case SaveProgressComplete(:final uri):
///       handleSuccess(uri);
///     case SaveProgressError(:final exception):
///       handleError(exception);
///     case SaveProgressCancelled():
///       handlePickerDismissed();
///   }
/// }
/// ```
///
/// To cancel a save, cancel its subscription (or leave the `await for`). The
/// stream emits nothing more after that, and the Future that
/// `subscription.cancel()` returns completes once the save has stopped and
/// deleted the partial file.
///
/// A save stream is single-subscription: listening to it again throws a
/// [StateError] instead of running the save a second time.
///
/// Events are values: two events of the same type with the same fields are
/// `==`, so a test can check a stream with `emitsInOrder([...])`.
@immutable
sealed class SaveProgress {
  const SaveProgress();
}

/// Emitted immediately when save operation starts.
///
/// Useful for UI feedback before actual progress begins,
/// especially when saving from file or path which takes time to open.
final class SaveProgressStarted extends SaveProgress {
  const SaveProgressStarted();

  @override
  bool operator ==(Object other) => other is SaveProgressStarted;

  @override
  int get hashCode => (SaveProgressStarted).hashCode;

  @override
  String toString() => 'SaveProgressStarted()';
}

/// Progress update during save operation.
///
/// [bytesWritten] counts the bytes of the file written so far, and
/// [totalBytes] is the size the file will have, or null when it isn't known,
/// as for a download without a `Content-Length`. [progress] is the fraction
/// written, from 0.0 to 1.0, and stays 0.0 while [totalBytes] is null: show
/// [bytesWritten] or an indeterminate indicator then.
final class SaveProgressUpdate extends SaveProgress {
  /// Clamps [progress] to 0.0–1.0, so a server that sends more bytes than its
  /// `Content-Length` can't report more than 100%. NaN becomes 0.0.
  const SaveProgressUpdate(
    double progress, {
    this.bytesWritten = 0,
    this.totalBytes,
  }) : progress = progress >= 1.0
           ? 1.0
           : progress > 0.0
           ? progress
           : 0.0;

  /// The update for [bytesWritten] of [totalBytes] bytes, with [progress]
  /// their fraction, or 0.0 when [totalBytes] is null.
  const SaveProgressUpdate.bytes(int bytesWritten, int? totalBytes)
    : this(
        totalBytes == null ? 0.0 : bytesWritten / totalBytes,
        bytesWritten: bytesWritten,
        totalBytes: totalBytes,
      );

  /// Progress value from 0.0 (0%) to 1.0 (100%)
  final double progress;

  /// Bytes of the file written so far.
  final int bytesWritten;

  /// The size of the file once saved, or null if it isn't known.
  final int? totalBytes;

  @override
  bool operator ==(Object other) =>
      other is SaveProgressUpdate &&
      progress == other.progress &&
      bytesWritten == other.bytesWritten &&
      totalBytes == other.totalBytes;

  @override
  int get hashCode =>
      Object.hash(SaveProgressUpdate, progress, bytesWritten, totalBytes);

  @override
  String toString() =>
      'SaveProgressUpdate($progress, $bytesWritten of ${totalBytes ?? '?'} bytes)';
}

/// Save completed successfully.
final class SaveProgressComplete extends SaveProgress {
  const SaveProgressComplete(this.uri);

  /// URI of the saved file
  final Uri uri;

  @override
  bool operator ==(Object other) =>
      other is SaveProgressComplete && uri == other.uri;

  @override
  int get hashCode => Object.hash(SaveProgressComplete, uri);

  @override
  String toString() => 'SaveProgressComplete($uri)';
}

/// Save failed with error.
final class SaveProgressError extends SaveProgress {
  const SaveProgressError(this.exception);

  /// The exception that caused the failure
  final FileSaverException exception;

  @override
  bool operator ==(Object other) =>
      other is SaveProgressError && exception == other.exception;

  @override
  int get hashCode => Object.hash(SaveProgressError, exception);

  @override
  String toString() => 'SaveProgressError($exception)';
}

/// The user dismissed the directory picker of `FileSaver.saveAs`, so nothing
/// was saved.
///
/// Cancelling the subscription doesn't emit it: a cancelled stream emits
/// nothing more.
final class SaveProgressCancelled extends SaveProgress {
  const SaveProgressCancelled();

  @override
  bool operator ==(Object other) => other is SaveProgressCancelled;

  @override
  int get hashCode => (SaveProgressCancelled).hashCode;

  @override
  String toString() => 'SaveProgressCancelled()';
}
