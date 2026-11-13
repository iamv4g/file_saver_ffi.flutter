import 'package:material_ui/material_ui.dart';

String fileNameWithoutExt(String name) {
  final idx = name.lastIndexOf('.');
  if (idx <= 0) return name;
  return name.substring(0, idx);
}

/// Formats bytes to human readable string
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

/// Shows a snackbar message
void showAppSnackBar(
  BuildContext context,
  String message, {
  required bool isSuccess,
}) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(message, style: const TextStyle(color: Colors.white)),
      backgroundColor: isSuccess ? Colors.green : Colors.red,
      duration: const Duration(seconds: 4),
      behavior: SnackBarBehavior.floating,
    ),
  );
}
