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
  String toString() => 'SaveProgressStarted()';
}

/// Progress update during save operation.
///
/// [progress] is a value from 0.0 to 1.0 representing completion percentage.
final class SaveProgressUpdate extends SaveProgress {
  /// Clamps [progress] to 0.0–1.0, so a server that sends more bytes than its
  /// `Content-Length` can't report more than 100%. NaN becomes 0.0.
  const SaveProgressUpdate(double progress)
    : progress = progress >= 1.0
          ? 1.0
          : progress > 0.0
          ? progress
          : 0.0;

  /// Progress value from 0.0 (0%) to 1.0 (100%)
  final double progress;

  @override
  String toString() => 'SaveProgressUpdate($progress)';
}

/// Save completed successfully.
final class SaveProgressComplete extends SaveProgress {
  const SaveProgressComplete(this.uri);

  /// URI of the saved file
  final Uri uri;

  @override
  String toString() => 'SaveProgressComplete($uri)';
}

/// Save failed with error.
final class SaveProgressError extends SaveProgress {
  const SaveProgressError(this.exception);

  /// The exception that caused the failure
  final FileSaverException exception;

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
  String toString() => 'SaveProgressCancelled()';
}
