import 'package:flutter/foundation.dart';

/// Base sealed class for save input types.
///
/// Defines the source of data to be saved:
/// - [SaveBytesInput]: Raw bytes in memory
/// - [SaveFileInput]: File path on disk
/// - [SaveNetworkInput]: URL to download from network
///
/// Inputs are values: two inputs with the same content are `==`.
@immutable
sealed class SaveInput {
  factory SaveInput.bytes(Uint8List fileBytes) => SaveBytesInput(fileBytes);

  factory SaveInput.file(String filePath) => SaveFileInput(filePath);

  factory SaveInput.network({
    required String url,
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 60),
  }) => SaveNetworkInput(url: url, headers: headers, timeout: timeout);
}

/// Input from raw bytes in memory.
final class SaveBytesInput implements SaveInput {
  const SaveBytesInput(this.fileBytes);

  /// The file content as bytes.
  final Uint8List fileBytes;

  /// Compares the bytes one by one.
  @override
  bool operator ==(Object other) =>
      other is SaveBytesInput && listEquals(fileBytes, other.fileBytes);

  /// Hashes only the length, so it stays cheap for large files.
  @override
  int get hashCode => Object.hash(SaveBytesInput, fileBytes.length);

  @override
  String toString() => 'SaveBytesInput(${fileBytes.length} bytes)';
}

/// Input from a file path on disk.
/// Does not support web, as browsers cannot access arbitrary file paths.
final class SaveFileInput implements SaveInput {
  const SaveFileInput(this.filePath);

  /// The source file path (file:// URI or content:// URI on Android).
  final String filePath;

  @override
  bool operator ==(Object other) =>
      other is SaveFileInput && filePath == other.filePath;

  @override
  int get hashCode => Object.hash(SaveFileInput, filePath);

  @override
  String toString() => 'SaveFileInput($filePath)';
}

/// Input from a network URL.
///
/// The file is downloaded natively to avoid double storage.
final class SaveNetworkInput implements SaveInput {
  const SaveNetworkInput({
    required this.url,
    this.headers,
    this.timeout = const Duration(seconds: 60),
  });

  /// The URL to download the file from.
  final String url;

  /// Optional HTTP headers for the request (e.g., Authorization).
  final Map<String, String>? headers;

  /// Inactivity timeout — how long to wait without receiving new data before
  /// aborting. Defaults to 60 seconds.
  ///
  /// On Web without custom headers, the browser controls the request and this
  /// value is ignored. On Web with custom headers, this is applied as a
  /// connection timeout (time until the server responds).
  final Duration timeout;

  @override
  bool operator ==(Object other) =>
      other is SaveNetworkInput &&
      url == other.url &&
      mapEquals(headers, other.headers) &&
      timeout == other.timeout;

  @override
  int get hashCode => Object.hash(
    SaveNetworkInput,
    url,
    headers == null
        ? null
        : Object.hashAllUnordered(
            headers!.entries.map((e) => Object.hash(e.key, e.value)),
          ),
    timeout,
  );

  /// Names the headers without their values, which may hold credentials.
  @override
  String toString() =>
      'SaveNetworkInput($url, '
      '${headers == null ? '' : 'headers: ${headers!.keys.toList()}, '}'
      'timeout: $timeout)';
}
