import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../config/app_palette.dart';
import '../models/traced_error.dart';

/// The line under an error row: its ID, which copies on tap, and a Report
/// action that asks before sending anything.
class ErrorTraceRow extends StatefulWidget {
  const ErrorTraceRow({super.key, required this.trace, this.onReport});

  final TracedError trace;

  /// Sends the report. Returns null on success, otherwise the failure.
  final Future<String?> Function(TracedError trace)? onReport;

  @override
  State<ErrorTraceRow> createState() => _ErrorTraceRowState();
}

class _ErrorTraceRowState extends State<ErrorTraceRow> {
  bool _sending = false;
  bool _reported = false;

  Future<void> _copyId() async {
    await Clipboard.setData(ClipboardData(text: widget.trace.id));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Copied ${widget.trace.id}')));
  }

  Future<void> _report() async {
    final onReport = widget.onReport;
    if (onReport == null) return;
    setState(() => _sending = true);
    final reported = await confirmAndReportError(
      context,
      widget.trace,
      onReport,
    );
    if (!mounted) return;
    setState(() {
      _sending = false;
      _reported = reported;
    });
  }

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(color: context.palette.textMuted, fontSize: 11);
    return Row(
      children: [
        InkWell(
          onTap: _copyId,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(widget.trace.id, style: style),
          ),
        ),
        if (widget.onReport != null) ...[
          const SizedBox(width: 12),
          InkWell(
            onTap: _sending || _reported ? null : _report,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(
                _reported
                    ? 'Reported'
                    : _sending
                    ? 'Reporting'
                    : 'Report',
                style: style.copyWith(
                  decoration: _reported || _sending
                      ? null
                      : TextDecoration.underline,
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// Asks before sending [trace] to SocketAgent, sends it, and says how that
/// went. Returns true when the report was stored.
Future<bool> confirmAndReportError(
  BuildContext context,
  TracedError trace,
  Future<String?> Function(TracedError trace) onReport,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('Report ${trace.id}?'),
      content: const Text(
        'Sends this error, the app version, and your platform to '
        'SocketAgent. No chat text or secrets.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('Report'),
        ),
      ],
    ),
  );
  if (confirmed != true) return false;
  final failure = await onReport(trace);
  messenger.showSnackBar(
    SnackBar(content: Text(failure ?? 'Reported ${trace.id}')),
  );
  return failure == null;
}
