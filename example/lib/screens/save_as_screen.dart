import 'dart:async';

import 'package:file_saver_ffi/file_saver_ffi.dart';
import 'package:flutter/material.dart';

import '../core/core.dart';

class SaveAsScreen extends StatefulWidget {
  const SaveAsScreen({super.key});

  @override
  State<SaveAsScreen> createState() => _SaveAsScreenState();
}

class _SaveAsScreenState extends State<SaveAsScreen> with DemoSaveScreenMixin {
  MediaCategory _selectedCategory = MediaCategory.image;
  bool _useStreamApi = false;
  bool _isSaving = false;
  DemoInputSource _inputSource = DemoInputSource.network;

  PickedDirectoryLocation? _pickedDirectory;

  String? _pickedFilePath;

  StreamSubscription<SaveProgress>? _saveSubscription;

  @override
  MediaCategory get demoSelectedCategory => _selectedCategory;
  @override
  set demoSelectedCategory(MediaCategory value) => _selectedCategory = value;

  @override
  bool get demoUseStreamApi => _useStreamApi;
  @override
  set demoUseStreamApi(bool value) => _useStreamApi = value;

  @override
  bool get demoIsSaving => _isSaving;
  @override
  set demoIsSaving(bool value) => _isSaving = value;

  @override
  DemoInputSource get demoInputSource => _inputSource;
  @override
  set demoInputSource(DemoInputSource value) => _inputSource = value;

  @override
  String? get demoPickedFilePath => _pickedFilePath;
  @override
  set demoPickedFilePath(String? value) => _pickedFilePath = value;

  @override
  StreamSubscription<SaveProgress>? get demoSaveSubscription =>
      _saveSubscription;
  @override
  set demoSaveSubscription(StreamSubscription<SaveProgress>? value) =>
      _saveSubscription = value;

  @override
  void dispose() {
    _saveSubscription?.cancel();
    super.dispose();
  }

  void _onCategoryChanged(MediaCategory category) {
    if (isLoading) return;
    final config = SaveDemoConfig.forCategory(category);
    setState(() {
      _selectedCategory = category;
      _useStreamApi = config.defaultUseStreamApi;
      _pickedFilePath = null;
      savedFilePath = null;
      mediaSize = 0;
    });
  }

  void _onInputSourceChanged(DemoInputSource source) {
    if (isLoading) return;
    setState(() {
      _inputSource = source;
      _pickedFilePath = null;
      savedFilePath = null;
      mediaSize = 0;
      progress = 0;
    });
  }

  void _cancelSave() {
    cancelDemoSave(message: 'Operation cancelled', isSuccess: false);
  }

  Future<void> _pickDirectory() async {
    try {
      final location = await FileSaver.pickDirectory();
      if (!mounted) return;
      if (location == null) {
        showAppSnackBar(context, 'Picker cancelled', isSuccess: false);
        return;
      }
      setState(() => _pickedDirectory = location);
      showAppSnackBar(context, 'Directory selected', isSuccess: true);
    } catch (e) {
      showError(e);
    }
  }

  Future<void> _runSaveAs() async {
    resetState();
    savedFilePath = null;
    progress = 0;

    try {
      final resolved = await resolveDemoSaveParams();

      setState(() => _isSaving = true);

      if (_useStreamApi) {
        await _saveWithStreamApi(
          input: resolved.input,
          fileType: resolved.fileType,
          fileName: resolved.fileName,
        );
      } else {
        await _saveWithAsyncApi(
          input: resolved.input,
          fileType: resolved.fileType,
          fileName: resolved.fileName,
        );
      }
    } on CancelledException {
      if (mounted) {
        showAppSnackBar(context, 'Operation cancelled', isSuccess: false);
      }
    } catch (e) {
      showError(e);
    } finally {
      if (_saveSubscription == null) {
        setState(() => _isSaving = false);
        finishLoading();
      }
    }
  }

  Future<void> _saveWithAsyncApi({
    required SaveInput input,
    required FileType fileType,
    required String fileName,
  }) async {
    try {
      final uri = await FileSaver.saveAsAsync(
        input: input,
        fileType: fileType,
        fileName: fileName,
        saveLocation: _pickedDirectory,
        conflictResolution: demoConflictResolution,
        onProgress: (p) => setState(() => progress = p * 100),
      );

      if (!mounted) return;

      if (uri == null) {
        showAppSnackBar(context, 'Picker cancelled', isSuccess: false);
        return;
      }

      setState(() => savedFilePath = uri.toString());
      showAppSnackBar(
        context,
        'Saved successfully!\nURI: $uri',
        isSuccess: true,
      );
    } on FileSaverException catch (e) {
      showAppSnackBar(
        context,
        'Save failed: ${e.message} (${e.code})',
        isSuccess: false,
      );
    }
  }

  Future<void> _saveWithStreamApi({
    required SaveInput input,
    required FileType fileType,
    required String fileName,
  }) async {
    final stream = FileSaver.saveAs(
      input: input,
      fileType: fileType,
      fileName: fileName,
      saveLocation: _pickedDirectory,
      conflictResolution: demoConflictResolution,
    );
    listenDemoSaveStream(stream, cancelledMessage: 'Picker cancelled');
  }

  @override
  Widget build(BuildContext context) {
    final pickedDirText = _pickedDirectory?.uri.toString() ?? 'Not selected';
    final infoUrlLabel = _inputSource == DemoInputSource.file ? 'Path' : 'URL';
    final infoValue = _inputSource == DemoInputSource.file
        ? (_pickedFilePath ?? 'No file selected')
        : demoConfig.downloadUrl;

    return Scaffold(
      appBar: AppBar(title: const Text('Save As Demo')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InputSourceSelector(
              value: _inputSource,
              enabled: !isLoading,
              onChanged: _onInputSourceChanged,
            ),
            MediaCategorySelector(
              selected: _selectedCategory,
              categories: MediaCategory.values
                  .map((c) => (value: c, label: c.label, icon: c.icon))
                  .toList(),
              onChanged: (c) => _onCategoryChanged(c as MediaCategory),
              enabled: !isLoading,
            ),
            ApiModeSelector(
              useStreamApi: _useStreamApi,
              onChanged: (v) => setState(() => _useStreamApi = v),
              enabled: !isLoading,
            ),
            buildConflictResolutionSelector(),
            InfoCard(
              description:
                  'Save to a user-selected directory via system picker.\n'
                  'Uses: ${_useStreamApi ? "saveAs (Stream)" : "saveAsAsync (Async)"}\n'
                  'Input: ${_inputSource.name}',
              url: infoValue,
              urlLabel: infoUrlLabel,
            ),
            const SizedBox(height: 12),
            Card(
              child: ListTile(
                title: const Text('Selected Directory'),
                subtitle: Text(
                  pickedDirText,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: TextButton(
                  onPressed: isLoading ? null : _pickDirectory,
                  child: const Text('Pick'),
                ),
              ),
            ),
            const SizedBox(height: 8),
            DownloadButton(
              isLoading: isLoading,
              onPressed: _runSaveAs,
              label: 'Save As ${_selectedCategory.label}',
              loadingLabel: 'Saving...',
            ),
            if (_isSaving && _useStreamApi) ...[
              const SizedBox(height: 8),
              CancelButton(onPressed: _cancelSave),
            ],
            const SizedBox(height: 8),
            if (isLoading && progress > 0) ProgressSection(progress: progress),
            if (mediaSize > 0) FileSizeCard(sizeInBytes: mediaSize),
            if (savedFilePath != null) ...[
              SuccessCard(savedPath: savedFilePath!),
              const SizedBox(height: 8),
              OpenFileButton(
                uri: Uri.parse(savedFilePath!),
                onError: showError,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
