import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart' hide FileType;
import 'package:file_saver_ffi/file_saver_ffi.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';

import 'file_type_config.dart';
import 'file_utils.dart';
import 'types.dart';
import 'utils.dart';

typedef DemoResolvedSaveParams = ({
  SaveInput input,
  FileType fileType,
  String fileName,
  int? sizeInBytes,
});

/// Shared logic for the example's "Save" and "Save As" screens.
///
/// The goal is to keep UI flexible while reusing all the boring bits:
/// picking inputs, building params, wiring progress stream, and cancellation.
mixin DemoSaveScreenMixin<T extends StatefulWidget> on State<T> {
  final ImagePicker _imagePicker = ImagePicker();

  bool isLoading = false;
  String? savedFilePath;
  double progress = 0.0;
  int mediaSize = 0;

  /// Downloads file from URL (used for bytes-mode demos).
  Future<Uint8List> downloadFromUrl(String url) async {
    final response = await http.get(Uri.parse(url));
    if (response.statusCode == 200) {
      return response.bodyBytes;
    } else {
      throw Exception('Failed to download: ${response.statusCode}');
    }
  }

  /// Resets state before starting an operation.
  void resetState() {
    setState(() {
      isLoading = true;
      savedFilePath = null;
      progress = 0.0;
      mediaSize = 0;
    });
  }

  /// Finishes loading state.
  void finishLoading() {
    setState(() {
      isLoading = false;
    });
  }

  /// Shows error message.
  void showError(dynamic error) {
    if (mounted) {
      showAppSnackBar(context, 'Error: ${error.toString()}', isSuccess: false);
    }
  }

  Future<void> runSaveCatching(Future<Uri> Function() saveFn) async {
    if (!mounted) return;

    try {
      final uri = await saveFn();

      if (!mounted) return;

      setState(() {
        savedFilePath = uri.toString();
      });

      showAppSnackBar(
        context,
        'Saved successfully!\nURI: $uri',
        isSuccess: true,
      );
    } on PermissionDeniedException catch (e) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        'Permission denied: ${e.message}',
        isSuccess: false,
      );
    } on FileExistsException catch (e) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        'File already exists: ${e.fileName}',
        isSuccess: false,
      );
    } on StorageFullException catch (e) {
      if (!mounted) return;
      showAppSnackBar(context, 'Storage full: ${e.message}', isSuccess: false);
    } on CancelledException {
      if (!mounted) return;
      showAppSnackBar(context, 'Operation cancelled', isSuccess: false);
    } on FileSaverException catch (e) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        'Save failed: ${e.message} (${e.code})',
        isSuccess: false,
      );
    }
  }

  MediaCategory get demoSelectedCategory;
  set demoSelectedCategory(MediaCategory value);

  bool get demoUseStreamApi;
  set demoUseStreamApi(bool value);

  bool get demoIsSaving;
  set demoIsSaving(bool value);

  DemoInputSource get demoInputSource;
  set demoInputSource(DemoInputSource value);

  String? get demoPickedFilePath;
  set demoPickedFilePath(String? value);

  StreamSubscription<SaveProgress>? get demoSaveSubscription;
  set demoSaveSubscription(StreamSubscription<SaveProgress>? value);

  SaveDemoConfig get demoConfig =>
      SaveDemoConfig.forCategory(demoSelectedCategory);

  String buildDemoFileNamePrefix(SaveDemoConfig config) {
    return '${config.fileNamePrefix}_${DateTime.now().millisecondsSinceEpoch}';
  }

  Future<String?> pickDemoFilePath() async {
    // Prefer Photos picker UX for images/videos.
    switch (demoSelectedCategory) {
      case MediaCategory.image:
        final image = await _imagePicker.pickImage(source: ImageSource.gallery);
        return image?.path;
      case MediaCategory.video:
        final video = await _imagePicker.pickVideo(source: ImageSource.gallery);
        return video?.path;
      case MediaCategory.audio:
      case MediaCategory.document:
        final result = await FilePicker.pickFile();
        return result?.path;
    }
  }

  /// Resolve [SaveInput]/[FileType]/[fileName] for Network/Bytes/File modes.
  ///
  /// For Bytes/File sources, this updates [mediaSize] for the UI.
  Future<DemoResolvedSaveParams> resolveDemoSaveParams() async {
    final config = demoConfig;

    switch (demoInputSource) {
      case DemoInputSource.network:
        return (
          input: SaveInput.network(url: config.downloadUrl),
          fileType: config.fileType,
          fileName: buildDemoFileNamePrefix(config),
          sizeInBytes: null,
        );

      case DemoInputSource.bytes:
        if (config.category == MediaCategory.video ||
            config.category == MediaCategory.audio) {
          showAppSnackBar(
            context,
            'Downloading ${config.category.label.toLowerCase()} into memory... This may take a while',
            isSuccess: true,
          );
        }

        final bytes = await downloadFromUrl(config.downloadUrl);
        setState(() => mediaSize = bytes.length);

        return (
          input: SaveInput.bytes(bytes),
          fileType: config.fileType,
          fileName: buildDemoFileNamePrefix(config),
          sizeInBytes: bytes.length,
        );

      case DemoInputSource.file:
        final pickedPath = demoPickedFilePath ?? await pickDemoFilePath();
        if (pickedPath == null) {
          throw const CancelledException();
        }

        final file = File(pickedPath);
        final fileSize = await file.length();
        final fileType = fileTypeFromPath(pickedPath);
        final fileName = fileNameWithoutExt(pickedPath.split('/').last);

        setState(() {
          demoPickedFilePath = pickedPath;
          mediaSize = fileSize;
        });

        return (
          input: SaveInput.file(pickedPath),
          fileType: fileType,
          fileName: fileName,
          sizeInBytes: fileSize,
        );
    }
  }

  void cancelDemoSave({
    String message = 'Operation cancelled',
    bool isSuccess = false,
  }) {
    demoSaveSubscription?.cancel();
    demoSaveSubscription = null;
    setState(() {
      isLoading = false;
      demoIsSaving = false;
      progress = 0;
    });
    showAppSnackBar(context, message, isSuccess: isSuccess);
  }

  /// Wires a [Stream<SaveProgress>] to shared UI state (progress + snackbars).
  void listenDemoSaveStream(
    Stream<SaveProgress> stream, {
    String cancelledMessage = 'Operation cancelled',
  }) {
    demoSaveSubscription?.cancel();
    demoSaveSubscription = stream.listen(
      (event) {
        if (!mounted) return;
        switch (event) {
          case SaveProgressStarted():
            break;
          case SaveProgressUpdate(:final progress):
            setState(() => this.progress = progress * 100);
          case SaveProgressComplete(:final uri):
            setState(() {
              savedFilePath = uri.toString();
              isLoading = false;
              demoIsSaving = false;
            });
            showAppSnackBar(
              context,
              'Saved successfully!\nURI: $uri',
              isSuccess: true,
            );
          case SaveProgressError(:final exception):
            setState(() {
              isLoading = false;
              demoIsSaving = false;
            });
            showAppSnackBar(
              context,
              'Save failed: ${exception.message}',
              isSuccess: false,
            );
          case SaveProgressCancelled():
            setState(() {
              isLoading = false;
              demoIsSaving = false;
              progress = 0;
            });
            showAppSnackBar(context, cancelledMessage, isSuccess: false);
        }
      },
      onError: (error) {
        if (!mounted) return;
        setState(() {
          isLoading = false;
          demoIsSaving = false;
        });
        showError(error);
      },
      onDone: () => demoSaveSubscription = null,
    );
  }
}
