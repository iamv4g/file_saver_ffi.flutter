import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:file_saver_ffi/file_saver_ffi.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/core.dart';

class PathLocationScreen extends StatefulWidget {
  const PathLocationScreen({super.key});

  @override
  State<PathLocationScreen> createState() => _PathLocationScreenState();
}

class _PathLocationScreenState extends State<PathLocationScreen> {
  String? _selectedPath;
  bool _isSaving = false;
  String? _savedUri;

  final _fileNameController = TextEditingController(text: 'hello');
  final _contentController = TextEditingController(
    text:
        'Hello from PathLocation!\n\n'
        'This file was saved to a user-specified directory using PathLocation.\n'
        'The caller resolves the path; the plugin just writes the file.',
  );

  static const _txtFileType = CustomFileType(
    ext: 'txt',
    mimeType: 'text/plain',
  );

  @override
  void dispose() {
    _fileNameController.dispose();
    _contentController.dispose();
    super.dispose();
  }

  // ── Path helpers ──────────────────────────────────────────────────────

  Future<void> _pickDirectory() async {
    if (Platform.isIOS) {
      showAppSnackBar(
        context,
        'Directory picking is not supported on iOS due to platform limitations.',
        isSuccess: false,
      );
      return;
    }

    if (Platform.isAndroid) {
      final status = await Permission.manageExternalStorage.status;
      if (!status.isGranted) {
        final result = await Permission.manageExternalStorage.request();
        if (!result.isGranted && mounted) {
          showAppSnackBar(
            context,
            'Storage permission required to pick external directories.',
            isSuccess: false,
          );
          return;
        }
      }
    }
    final result = await FilePicker.getDirectoryPath();
    if (result != null) setState(() => _selectedPath = result);
  }

  Future<void> _useAppDocuments() async {
    final docs = await getApplicationDocumentsDirectory();
    setState(() => _selectedPath = docs.path);
  }

  // ── Save ──────────────────────────────────────────────────────────────

  Future<void> _save() async {
    if (_selectedPath == null) {
      showAppSnackBar(
        context,
        'Please select a directory first.',
        isSuccess: false,
      );
      return;
    }
    final fileName = _fileNameController.text.trim();
    if (fileName.isEmpty) {
      showAppSnackBar(context, 'File name is required.', isSuccess: false);
      return;
    }

    setState(() {
      _isSaving = true;
      _savedUri = null;
    });

    try {
      final bytes = Uint8List.fromList(utf8.encode(_contentController.text));
      final uri = await FileSaver.saveAsync(
        input: SaveInput.bytes(bytes),
        fileName: fileName,
        fileType: _txtFileType,
        saveLocation: PathLocation(_selectedPath!),
        conflictResolution: ConflictResolution.autoRename,
      );
      if (mounted) {
        setState(() => _savedUri = uri.toString());
        showAppSnackBar(context, 'Saved successfully!', isSuccess: true);
      }
    } on FileSaverException catch (e) {
      if (mounted) {
        showAppSnackBar(
          context,
          'Save failed: ${e.message} (${e.code})',
          isSuccess: false,
        );
      }
    } catch (e) {
      if (mounted) showAppSnackBar(context, 'Error: $e', isSuccess: false);
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  // ── UI ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('PathLocation Demo')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Directory selection ─────────────────────────────────────
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Target directory',
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: _isSaving ? null : _pickDirectory,
                            icon: const Icon(Icons.folder_open),
                            label: const Text('Browse'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _isSaving ? null : _useAppDocuments,
                            icon: const Icon(Icons.phone_android),
                            label: const Text('App Documents'),
                          ),
                        ),
                      ],
                    ),
                    if (_selectedPath != null) ...[
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Theme.of(
                            context,
                          ).colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          _selectedPath!,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ] else ...[
                      const SizedBox(height: 8),
                      Text(
                        'No directory selected.\n'
                        '• Browse — pick any accessible directory\n'
                        '• App Documents — app\'s sandbox Documents folder',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),

            // ── File name ───────────────────────────────────────────────
            TextField(
              controller: _fileNameController,
              enabled: !_isSaving,
              decoration: const InputDecoration(
                labelText: 'File name (without extension)',
                hintText: 'hello',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.insert_drive_file),
                suffixText: '.txt',
              ),
            ),
            const SizedBox(height: 12),

            // ── Content ─────────────────────────────────────────────────
            TextField(
              controller: _contentController,
              enabled: !_isSaving,
              maxLines: 6,
              decoration: const InputDecoration(
                labelText: 'File content',
                border: OutlineInputBorder(),
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 16),

            // ── Save button ─────────────────────────────────────────────
            ElevatedButton.icon(
              onPressed: _isSaving ? null : _save,
              icon: _isSaving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save),
              label: Padding(
                padding: const EdgeInsets.symmetric(vertical: 14),
                child: Text(_isSaving ? 'Saving…' : 'Save text file'),
              ),
            ),

            // ── Result ──────────────────────────────────────────────────
            if (_savedUri != null) ...[
              const SizedBox(height: 16),
              SuccessCard(savedPath: _savedUri!),
              const SizedBox(height: 8),
              OpenFileButton(
                uri: Uri.parse(_savedUri!),
                onError: (e) => showAppSnackBar(
                  context,
                  'Cannot open: $e',
                  isSuccess: false,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
