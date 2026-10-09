import 'package:flutter/material.dart';

import '../services/chat_provider.dart';
import '../services/session_transcript_cache.dart';
import '../util/format.dart';

/// Settings row for how many session transcripts stay on this device, so
/// sessions on offline computers can still be read.
class TranscriptCacheTile extends StatelessWidget {
  const TranscriptCacheTile({super.key, required this.provider});

  final ChatProvider provider;

  @override
  Widget build(BuildContext context) {
    final limit = provider.transcriptCacheLimit;
    return ListTile(
      leading: const Icon(Icons.offline_pin_outlined),
      title: const Text('Offline transcripts'),
      subtitle: Text('Keep the last ${formatThousands(limit)} sessions'),
      trailing: const Icon(Icons.edit_outlined),
      onTap: () => showDialog<void>(
        context: context,
        builder: (_) => _TranscriptCacheDialog(provider: provider),
      ),
    );
  }
}

class _TranscriptCacheDialog extends StatefulWidget {
  const _TranscriptCacheDialog({required this.provider});

  final ChatProvider provider;

  @override
  State<_TranscriptCacheDialog> createState() => _TranscriptCacheDialogState();
}

class _TranscriptCacheDialogState extends State<_TranscriptCacheDialog> {
  late final _controller = TextEditingController(
    text: '${widget.provider.transcriptCacheLimit}',
  );
  late final _usage = widget.provider.transcriptCacheUsage();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  int? get _value {
    final value = int.tryParse(_controller.text.trim());
    return value != null && value >= 1 ? value : null;
  }

  @override
  Widget build(BuildContext context) {
    final value = _value;
    return AlertDialog(
      title: const Text('Offline transcripts'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _controller,
            autofocus: true,
            keyboardType: TextInputType.number,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: 'Sessions',
              errorText: value == null ? 'Enter a whole number above 0' : null,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          FutureBuilder(
            future: _usage,
            builder: (context, snapshot) {
              final usage = snapshot.data;
              if (usage == null) return const SizedBox.shrink();
              return Text(
                transcriptCacheEstimate(usage, value),
                style: const TextStyle(fontSize: 13),
              );
            },
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: value == null
              ? null
              : () {
                  widget.provider.setTranscriptCacheLimit(value);
                  Navigator.pop(context);
                },
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// Describes current cache use and the projected size at [limit] sessions,
/// scaled from the average transcript on this device.
String transcriptCacheEstimate(({int count, int bytes}) usage, int? limit) {
  final now = usage.count == 0
      ? 'Nothing cached yet.'
      : 'Now ${formatThousands(usage.count)} sessions use '
            '${formatBytes(usage.bytes)}.';
  if (limit == null) return now;
  final cap = formatBytes(limit * SessionTranscriptCache.maxSnapshotBytes);
  final sessions = '${formatThousands(limit)} sessions';
  final projected = usage.count == 0
      ? 'At $sessions, at most $cap, since each is capped at 2 MB.'
      : 'At $sessions, about ${formatBytes(usage.bytes * limit ~/ usage.count)}. '
            'Each is capped at 2 MB, so never more than $cap.';
  final dropped = usage.count - limit;
  return [
    now,
    projected,
    if (dropped > 0)
      'Saving deletes the ${formatThousands(dropped)} oldest '
          'cached ${dropped == 1 ? 'transcript' : 'transcripts'}.',
  ].join('\n');
}
