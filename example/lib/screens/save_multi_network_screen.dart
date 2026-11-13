import 'dart:async';

import 'package:file_saver_ffi/file_saver_ffi.dart';
import 'package:material_ui/material_ui.dart';

import '../core/core.dart';

class SaveMultiNetworkScreen extends StatefulWidget {
  const SaveMultiNetworkScreen({super.key});

  @override
  State<SaveMultiNetworkScreen> createState() => _SaveMultiNetworkScreenState();
}

class _SaveMultiNetworkScreenState extends State<SaveMultiNetworkScreen> {
  final List<_DownloadItem> _items = [
    _DownloadItem(config: NetworkDemoConfig.image),
    _DownloadItem(config: NetworkDemoConfig.video),
    _DownloadItem(config: NetworkDemoConfig.audio),
    _DownloadItem(config: NetworkDemoConfig.document),
  ];

  bool get _isBatchRunning =>
      _items.any((item) => item.status == _DownloadStatus.downloading);

  @override
  void dispose() {
    for (final item in _items) {
      item.subscription?.cancel();
    }
    super.dispose();
  }

  String _buildFileName(NetworkDemoConfig config) {
    return '${config.fileNamePrefix}_${DateTime.now().millisecondsSinceEpoch}';
  }

  Future<void> _startItem(_DownloadItem item) async {
    if (item.status == _DownloadStatus.downloading) return;

    if (mounted &&
        (item.config.category == MediaCategory.video ||
            item.config.category == MediaCategory.audio)) {
      showAppSnackBar(
        context,
        'Downloading ${item.config.category.label.toLowerCase()}... This may take a while',
        isSuccess: true,
      );
    }

    final stream = FileSaver.save(
      input: SaveInput.network(url: item.config.downloadUrl),
      fileName: _buildFileName(item.config),
      fileType: item.config.fileType,
      saveLocation: item.config.saveLocation,
      subDir: item.config.subDir,
      conflictResolution: ConflictResolution.autoRename,
    );

    setState(() {
      item.status = _DownloadStatus.downloading;
      item.progress = 0;
      item.update = null;
      item.savedUri = null;
      item.errorMessage = null;
    });

    item.subscription?.cancel();
    item.subscription = stream.listen(
      (event) {
        if (!mounted) return;
        switch (event) {
          case SaveProgressStarted():
            break;
          case SaveProgressUpdate(:final progress):
            setState(() {
              item.progress = progress * 100;
              item.update = event;
            });
          case SaveProgressComplete(:final uri):
            setState(() {
              item.status = _DownloadStatus.completed;
              item.progress = 100;
              item.savedUri = uri;
            });
          case SaveProgressError(:final exception):
            setState(() {
              item.status = _DownloadStatus.failed;
              item.errorMessage = exception.message;
            });
            showAppSnackBar(
              context,
              'Save failed: ${exception.message}',
              isSuccess: false,
            );
          case SaveProgressCancelled():
            setState(() {
              item.status = _DownloadStatus.cancelled;
              item.progress = 0;
            });
        }
      },
      onError: (error) {
        if (!mounted) return;
        setState(() {
          item.status = _DownloadStatus.failed;
          item.errorMessage = error.toString();
        });
        showError(error);
      },
      onDone: () => item.subscription = null,
    );
  }

  Future<void> _cancelItem(_DownloadItem item) async {
    await item.subscription?.cancel();
    item.subscription = null;
    if (!mounted) return;
    setState(() {
      item.status = _DownloadStatus.cancelled;
      item.progress = 0;
    });
    showAppSnackBar(context, 'Operation cancelled', isSuccess: false);
  }

  Future<void> _startAll() async {
    for (final item in _items) {
      if (item.status != _DownloadStatus.downloading) {
        await _startItem(item);
      }
    }
  }

  Future<void> _cancelAll() async {
    for (final item in _items) {
      if (item.status == _DownloadStatus.downloading) {
        await _cancelItem(item);
      }
    }
  }

  /// Shows error message
  void showError(dynamic error) {
    if (mounted) {
      showAppSnackBar(context, 'Error: ${error.toString()}', isSuccess: false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Save Multi Network')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ElevatedButton.icon(
              onPressed: _isBatchRunning ? _cancelAll : _startAll,
              icon: Icon(_isBatchRunning ? Icons.cancel : Icons.cloud_download),
              label: Text(
                _isBatchRunning
                    ? 'Cancel All Downloads'
                    : 'Start All Downloads',
              ),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
                backgroundColor: _isBatchRunning ? Colors.red.shade600 : null,
              ),
            ),
            const SizedBox(height: 16),
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _items.length,
              separatorBuilder: (_, _) => const SizedBox(height: 12),
              itemBuilder: (context, index) {
                final item = _items[index];
                return _DownloadItemTile(
                  item: item,
                  onStart: () => _startItem(item),
                  onCancel: () => _cancelItem(item),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

enum _DownloadStatus { idle, downloading, completed, failed, cancelled }

class _DownloadItem {
  _DownloadItem({required this.config});

  final NetworkDemoConfig config;
  _DownloadStatus status = _DownloadStatus.idle;
  double progress = 0;

  /// The last update, with the bytes downloaded.
  SaveProgressUpdate? update;
  StreamSubscription<SaveProgress>? subscription;
  Uri? savedUri;
  String? errorMessage;
}

class _DownloadItemTile extends StatelessWidget {
  const _DownloadItemTile({
    required this.item,
    required this.onStart,
    required this.onCancel,
  });

  final _DownloadItem item;
  final VoidCallback onStart;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final isDownloading = item.status == _DownloadStatus.downloading;
    // A download without a known size shows its bytes on an indeterminate bar.
    final unknownSizeBytes = switch (item.update) {
      SaveProgressUpdate(:final bytesWritten, totalBytes: null)
          when isDownloading =>
        bytesWritten,
      _ => null,
    };
    final statusLabel = switch (item.status) {
      _DownloadStatus.idle => 'Idle',
      _DownloadStatus.downloading => 'Downloading',
      _DownloadStatus.completed => 'Completed',
      _DownloadStatus.failed => 'Failed',
      _DownloadStatus.cancelled => 'Cancelled',
    };

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.config.downloadUrl,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  LinearProgressIndicator(
                    value: unknownSizeBytes != null
                        ? null
                        : (item.progress / 100).clamp(0.0, 1.0),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    unknownSizeBytes != null
                        ? '$statusLabel • ${formatBytes(unknownSizeBytes)}'
                        : '$statusLabel • ${item.progress.toStringAsFixed(1)}%',
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                  if (item.errorMessage != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      item.errorMessage!,
                      style: Theme.of(context).textTheme.labelSmall
                          ?.copyWith(color: Colors.red),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              icon: Icon(isDownloading ? Icons.cancel : Icons.play_arrow),
              tooltip: isDownloading ? 'Cancel' : 'Start',
              onPressed: isDownloading ? onCancel : onStart,
              color: isDownloading ? Colors.red : Colors.green,
            ),
          ],
        ),
      ),
    );
  }
}
