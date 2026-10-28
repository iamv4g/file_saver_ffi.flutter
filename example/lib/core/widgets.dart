import 'package:file_saver_ffi/file_saver_ffi.dart';
import 'package:flutter/material.dart';

import 'types.dart';
import 'utils.dart';

class InputSourceSelector extends StatelessWidget {
  const InputSourceSelector({
    super.key,
    required this.value,
    required this.onChanged,
    required this.enabled,
  });

  final DemoInputSource value;
  final ValueChanged<DemoInputSource> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<DemoInputSource>(
      segments: const [
        ButtonSegment<DemoInputSource>(
          value: DemoInputSource.network,
          icon: Icon(Icons.link),
          label: Text('Network'),
        ),
        ButtonSegment<DemoInputSource>(
          value: DemoInputSource.bytes,
          icon: Icon(Icons.memory),
          label: Text('Bytes'),
        ),
        ButtonSegment<DemoInputSource>(
          value: DemoInputSource.file,
          icon: Icon(Icons.insert_drive_file),
          label: Text('File'),
        ),
      ],
      selected: {value},
      onSelectionChanged: enabled ? (s) => onChanged(s.first) : null,
      showSelectedIcon: false,
    );
  }
}

/// Info card displaying title, description and URL
class InfoCard extends StatelessWidget {
  const InfoCard({
    super.key,
    required this.description,
    required this.url,
    this.urlLabel = 'URL',
  });

  final String description;
  final String url;
  final String urlLabel;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(description),
            const SizedBox(height: 8),
            Text(
              '$urlLabel: $url',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: Colors.grey),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

/// Download button with loading state
class DownloadButton extends StatelessWidget {
  const DownloadButton({
    super.key,
    required this.isLoading,
    required this.onPressed,
    required this.label,
    this.loadingLabel = 'Downloading...',
  });

  final bool isLoading;
  final VoidCallback? onPressed;
  final String label;
  final String loadingLabel;

  @override
  Widget build(BuildContext context) {
    return ElevatedButton.icon(
      onPressed: isLoading ? null : onPressed,
      icon: isLoading
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.download),
      label: Text(isLoading ? loadingLabel : label),
      style: ElevatedButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 16),
      ),
    );
  }
}

/// Progress indicator section
class ProgressSection extends StatelessWidget {
  const ProgressSection({
    super.key,
    required this.progress,
    this.label = 'Saving',
  });

  final double progress;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const SizedBox(height: 16),
        LinearProgressIndicator(value: progress / 100),
        const SizedBox(height: 8),
        Text(
          '$label: ${progress.toStringAsFixed(1)}%',
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

/// Card showing file/media size info
class FileSizeCard extends StatelessWidget {
  const FileSizeCard({super.key, required this.sizeInBytes, this.label});

  final int sizeInBytes;
  final String? label;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Colors.blue.shade50,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(Icons.info, color: Colors.blue.shade700),
            const SizedBox(width: 8),
            Text(
              '${label ?? 'Size'}: ${formatBytes(sizeInBytes)}',
              style: TextStyle(color: Colors.blue.shade700),
            ),
          ],
        ),
      ),
    );
  }
}

/// Card showing successful save path
class SuccessCard extends StatelessWidget {
  const SuccessCard({super.key, required this.savedPath});

  final String savedPath;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Colors.green.shade50,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(Icons.check_circle, color: Colors.green.shade700),
            const SizedBox(width: 8),
            Expanded(
              child: SelectableText(
                'Saved: $savedPath',
                style: TextStyle(color: Colors.green.shade700),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Segmented button for selecting media/file type
class MediaCategorySelector extends StatelessWidget {
  const MediaCategorySelector({
    super.key,
    required this.selected,
    required this.categories,
    required this.onChanged,
    this.enabled = true,
  });

  final dynamic selected;
  final List<({dynamic value, String label, IconData icon})> categories;
  final ValueChanged<dynamic> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return FractionallySizedBox(
      widthFactor: 0.9,
      child: SegmentedButton<dynamic>(
        segments: categories
            .map(
              (c) => ButtonSegment<dynamic>(
                value: c.value,
                icon: Icon(c.icon),
                tooltip: c.label,
              ),
            )
            .toList(),
        selected: {selected},
        onSelectionChanged: enabled ? (s) => onChanged(s.first) : null,
        showSelectedIcon: false,
      ),
    );
  }
}

/// Toggle between Async and Stream API modes
class ApiModeSelector extends StatelessWidget {
  const ApiModeSelector({
    super.key,
    required this.useStreamApi,
    required this.onChanged,
    this.enabled = true,
  });

  final bool useStreamApi;
  final ValueChanged<bool> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return FractionallySizedBox(
      widthFactor: 0.5,
      child: SegmentedButton<bool>(
        segments: const [
          ButtonSegment<bool>(value: false, label: Text('Async')),
          ButtonSegment<bool>(value: true, label: Text('Stream')),
        ],
        selected: {useStreamApi},
        onSelectionChanged: enabled ? (s) => onChanged(s.first) : null,
        showSelectedIcon: false,
      ),
    );
  }
}

/// Picks the [ConflictResolution] for the next save, and whether to reuse a
/// fixed file name so that repeated saves collide with the previous one.
class ConflictResolutionSelector extends StatelessWidget {
  const ConflictResolutionSelector({
    super.key,
    required this.value,
    required this.onChanged,
    required this.reuseFileName,
    required this.onReuseFileNameChanged,
    this.enabled = true,
  });

  final ConflictResolution value;
  final ValueChanged<ConflictResolution> onChanged;
  final bool reuseFileName;
  final ValueChanged<bool> onReuseFileNameChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: SegmentedButton<ConflictResolution>(
                segments: const [
                  ButtonSegment(
                    value: ConflictResolution.autoRename,
                    label: Text('Rename'),
                  ),
                  ButtonSegment(
                    value: ConflictResolution.overwrite,
                    label: Text('Overwrite'),
                  ),
                  ButtonSegment(
                    value: ConflictResolution.fail,
                    label: Text('Fail'),
                  ),
                  ButtonSegment(
                    value: ConflictResolution.skip,
                    label: Text('Skip'),
                  ),
                ],
                selected: {value},
                onSelectionChanged: enabled ? (s) => onChanged(s.first) : null,
                showSelectedIcon: false,
              ),
            ),
            SwitchListTile(
              title: const Text('Reuse file name'),
              subtitle: Text(
                reuseFileName
                    ? 'Every save uses the same name, so it collides'
                    : 'Each save gets a unique timestamped name',
              ),
              value: reuseFileName,
              onChanged: enabled ? onReuseFileNameChanged : null,
            ),
          ],
        ),
      ),
    );
  }
}

/// Button to open the saved file with the system's default app
class OpenFileButton extends StatelessWidget {
  const OpenFileButton({super.key, required this.uri, required this.onError});

  final Uri uri;
  final void Function(Object error) onError;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: () async {
        try {
          await FileSaver.openFile(uri);
        } catch (e) {
          onError(e);
        }
      },
      icon: const Icon(Icons.open_in_new),
      label: const Text('Open File'),
    );
  }
}

/// Cancel button for stream operations
class CancelButton extends StatelessWidget {
  const CancelButton({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: const Icon(Icons.cancel),
      label: const Text('Cancel'),
      style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
    );
  }
}
