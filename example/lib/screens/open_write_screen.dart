import 'dart:async';

import 'package:file_saver_ffi/file_saver_ffi.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../core/core.dart';

class OpenWriteScreen extends StatefulWidget {
  const OpenWriteScreen({super.key});

  @override
  State<OpenWriteScreen> createState() => _OpenWriteScreenState();
}

class _OpenWriteScreenState extends State<OpenWriteScreen> {
  MediaCategory _selectedCategory = MediaCategory.video;
  bool _pickDirFirst = false;
  bool _isRunning = false;
  ConflictResolution _conflictResolution = ConflictResolution.autoRename;
  bool _reuseFileName = false;

  FileSaverSink? _sink;
  StreamSubscription<int>? _bytesSub;
  StreamSubscription<double>? _progressSub;

  int _bytesWritten = 0;
  double? _progress; // null = totalSize unknown → show indeterminate
  String? _savedUri;

  @override
  void dispose() {
    _bytesSub?.cancel();
    _progressSub?.cancel();
    _sink?.cancel();
    super.dispose();
  }

  SaveDemoConfig get _config => SaveDemoConfig.forCategory(_selectedCategory);

  void _onCategoryChanged(MediaCategory category) {
    if (_isRunning) return;
    setState(() {
      _selectedCategory = category;
      _savedUri = null;
      _bytesWritten = 0;
      _progress = null;
    });
  }

  Future<void> _run() async {
    setState(() {
      _isRunning = true;
      _bytesWritten = 0;
      _progress = null;
      _savedUri = null;
    });

    final config = _config;
    final url = Uri.parse(config.downloadUrl);
    final fileName = _reuseFileName
        ? config.fileNamePrefix
        : '${config.fileNamePrefix}_${DateTime.now().millisecondsSinceEpoch}';
    final client = http.Client();

    try {
      // ── Step 1: HEAD → get Content-Length (fail fast on bad URL) ──────────
      int? totalSize;
      try {
        final head = await client.head(url);
        totalSize = int.tryParse(head.headers['content-length'] ?? '');
      } catch (_) {
        // HEAD not supported by server — proceed without totalSize
      }

      // ── Step 2: Pick dir if requested — fail fast before any I/O ─────────
      SaveLocation? saveLocation = config.saveLocation;
      String? subDir = config.subDir;
      if (_pickDirFirst) {
        try {
          final picked = await FileSaver.pickDirectory();
          if (!mounted) return;
          if (picked == null) {
            showAppSnackBar(context, 'Picker cancelled', isSuccess: false);
            return;
          }
          saveLocation = picked;
          subDir = null; // SAF handles path directly
        } catch (e) {
          if (!mounted) return;
          showAppSnackBar(context, 'Picker error: $e', isSuccess: false);
          return;
        }
      }

      // ── Step 3: Open write session ────────────────────────────────────────
      if (saveLocation is PickedDirectoryLocation) {
        _sink = await FileSaver.openWriteAs(
          fileName: fileName,
          fileType: config.fileType,
          saveLocation: saveLocation,
          totalSize: totalSize,
          conflictResolution: _conflictResolution,
        );
      } else {
        _sink = await FileSaver.openWrite(
          fileName: fileName,
          fileType: config.fileType,
          saveLocation: saveLocation,
          subDir: subDir,
          totalSize: totalSize,
          conflictResolution: _conflictResolution,
        );
      }

      // No sink: ConflictResolution.skip found an existing file.
      if (_sink == null) {
        if (mounted) {
          showAppSnackBar(
            context,
            'Skipped: file already exists',
            isSuccess: true,
          );
        }
        return;
      }

      // ── Step 4: Wire progress streams ─────────────────────────────────────
      _bytesSub = _sink?.bytesWritten.listen((b) {
        if (mounted) setState(() => _bytesWritten = b);
      });
      if (totalSize != null) {
        _progressSub = _sink?.progress.listen((p) {
          if (mounted) setState(() => _progress = p);
        });
      }

      // ── Step 5: Start HTTP GET — only AFTER sink is ready ─────────────────
      final request = http.Request('GET', url);
      final response = await client.send(request);
      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }

      // ── Step 6: Pipe stream → sink (back-pressure via addStream) ──────────
      await _sink?.addStream(response.stream.cast<List<int>>());

      // ── Step 7: Finalize ──────────────────────────────────────────────────
      final savedUri = await _sink?.close();
      _sink = null;

      // Cancel button pressed while streaming: _cancel already reported it.
      if (savedUri == null) return;

      if (mounted) {
        setState(() => _savedUri = savedUri.toString());
        showAppSnackBar(
          context,
          'Saved successfully!\n$savedUri',
          isSuccess: true,
        );
      }
    } on FileSaverException catch (e) {
      await _sink?.cancel();
      _sink = null;
      if (mounted) {
        showAppSnackBar(
          context,
          'Save failed: ${e.message} (${e.code})',
          isSuccess: false,
        );
      }
    } catch (e) {
      await _sink?.cancel();
      _sink = null;
      if (mounted) showAppSnackBar(context, 'Error: $e', isSuccess: false);
    } finally {
      client.close();
      _bytesSub?.cancel();
      _progressSub?.cancel();
      _bytesSub = null;
      _progressSub = null;
      if (mounted) setState(() => _isRunning = false);
    }
  }

  Future<void> _cancel() async {
    await _sink?.cancel();
    _sink = null;
    _bytesSub?.cancel();
    _progressSub?.cancel();
    _bytesSub = null;
    _progressSub = null;
    if (mounted) {
      setState(() {
        _isRunning = false;
        _bytesWritten = 0;
        _progress = null;
      });
      showAppSnackBar(context, 'Cancelled', isSuccess: false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final config = _config;
    final progressValue = _progress;
    final showProgress = _isRunning;

    return Scaffold(
      appBar: AppBar(title: const Text('Open Write Demo')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            MediaCategorySelector(
              selected: _selectedCategory,
              categories: MediaCategory.values
                  .map((c) => (value: c, label: c.label, icon: c.icon))
                  .toList(),
              onChanged: (c) => _onCategoryChanged(c as MediaCategory),
              enabled: !_isRunning,
            ),
            const SizedBox(height: 12),
            Card(
              child: SwitchListTile(
                title: const Text('Pick directory first'),
                subtitle: Text(
                  _pickDirFirst
                      ? 'Flow: pick dir → open sink → GET'
                      : 'Flow: open sink → GET (default location)',
                ),
                value: _pickDirFirst,
                onChanged: _isRunning
                    ? null
                    : (v) => setState(() => _pickDirFirst = v),
              ),
            ),
            ConflictResolutionSelector(
              value: _conflictResolution,
              onChanged: (v) => setState(() => _conflictResolution = v),
              reuseFileName: _reuseFileName,
              onReuseFileNameChanged: (v) => setState(() => _reuseFileName = v),
              enabled: !_isRunning,
            ),
            const SizedBox(height: 8),
            InfoCard(
              description:
                  'Streams file content chunk-by-chunk via openWrite.\n'
                  'HEAD → get size → open sink → GET → addStream → close.',
              url: config.downloadUrl,
            ),
            const SizedBox(height: 12),
            DownloadButton(
              isLoading: _isRunning,
              onPressed: _run,
              label: 'Stream ${_selectedCategory.label}',
              loadingLabel: 'Streaming...',
            ),
            if (_isRunning) ...[
              const SizedBox(height: 8),
              CancelButton(onPressed: _cancel),
            ],
            if (showProgress) ...[
              const SizedBox(height: 16),
              if (progressValue != null)
                ProgressSection(progress: progressValue * 100)
              else
                Column(
                  children: [
                    const LinearProgressIndicator(),
                    const SizedBox(height: 8),
                    Text(
                      'Written: ${formatBytes(_bytesWritten)}',
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
            ],
            if (_bytesWritten > 0 && !_isRunning) ...[
              const SizedBox(height: 8),
              FileSizeCard(sizeInBytes: _bytesWritten, label: 'Total written'),
            ],
            if (_savedUri != null) ...[
              const SizedBox(height: 8),
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
