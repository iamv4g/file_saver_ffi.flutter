import 'package:file_saver_ffi/file_saver_ffi.dart';

/// Gets ImageType from file path extension
ImageType imageTypeFromPath(String path) {
  final ext = path.split('.').last.toLowerCase();
  return switch (ext) {
    'png' => ImageType.png,
    'jpg' => ImageType.jpg,
    'jpeg' => ImageType.jpeg,
    'gif' => ImageType.gif,
    'webp' => ImageType.webp,
    'bmp' => ImageType.bmp,
    'heic' => ImageType.heic,
    'heif' => ImageType.heif,
    'tiff' => ImageType.tiff,
    'tif' => ImageType.tif,
    _ => ImageType.jpg, // Default to jpg
  };
}

/// Gets VideoType from file path extension
VideoType videoTypeFromPath(String path) {
  final ext = path.split('.').last.toLowerCase();
  return switch (ext) {
    'mp4' => VideoType.mp4,
    '3gp' => VideoType.threeGp,
    'webm' => VideoType.webm,
    'm4v' => VideoType.m4v,
    'mkv' => VideoType.mkv,
    'mov' => VideoType.mov,
    'avi' => VideoType.avi,
    'flv' => VideoType.flv,
    'wmv' => VideoType.wmv,
    _ => VideoType.mp4, // Default to mp4
  };
}

/// Gets FileType from file path extension (for generic files)
FileType fileTypeFromPath(String path) {
  final ext = path.split('.').last.toLowerCase();

  // Try image types
  if ([
    'png',
    'jpg',
    'jpeg',
    'gif',
    'webp',
    'bmp',
    'heic',
    'heif',
    'tiff',
    'tif',
  ].contains(ext)) {
    return imageTypeFromPath(path);
  }

  // Try video types
  if ([
    'mp4',
    '3gp',
    'webm',
    'm4v',
    'mkv',
    'mov',
    'avi',
    'flv',
    'wmv',
  ].contains(ext)) {
    return videoTypeFromPath(path);
  }

  // Try audio types
  if ([
    'mp3',
    'aac',
    'wav',
    'amr',
    'm4a',
    'ogg',
    'flac',
    'opus',
    'aiff',
    'caf',
  ].contains(ext)) {
    return switch (ext) {
      'mp3' => AudioType.mp3,
      'aac' => AudioType.aac,
      'wav' => AudioType.wav,
      'amr' => AudioType.amr,
      'm4a' => AudioType.m4a,
      'ogg' => AudioType.ogg,
      'flac' => AudioType.flac,
      'opus' => AudioType.opus,
      'aiff' => AudioType.aiff,
      'caf' => AudioType.caf,
      _ => AudioType.mp3,
    };
  }

  // Default to custom file type
  final mimeType = _getMimeType(ext);
  return CustomFileType(ext: ext, mimeType: mimeType);
}

String _getMimeType(String ext) {
  return switch (ext) {
    'pdf' => 'application/pdf',
    'doc' => 'application/msword',
    'docx' =>
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'xls' => 'application/vnd.ms-excel',
    'xlsx' =>
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'ppt' => 'application/vnd.ms-powerpoint',
    'pptx' => 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    'txt' => 'text/plain',
    'json' => 'application/json',
    'xml' => 'application/xml',
    'zip' => 'application/zip',
    'rar' => 'application/x-rar-compressed',
    '7z' => 'application/x-7z-compressed',
    _ => 'application/octet-stream',
  };
}
