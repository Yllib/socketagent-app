import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../models/message.dart';
import 'scroll_passthrough.dart';
import 'tool_output_block.dart';

class MonitorToolDetails {
  final String description;
  final String command;
  final String? taskId;
  final String? pid;
  final int? timeoutSeconds;
  final String status;
  final String result;

  const MonitorToolDetails({
    required this.description,
    required this.command,
    required this.taskId,
    required this.pid,
    required this.timeoutSeconds,
    required this.status,
    required this.result,
  });

  factory MonitorToolDetails.fromMessage(ChatMessage message) {
    final input = message.toolInput ?? const <String, dynamic>{};
    final command = input['command']?.toString() ?? '';
    final requestedTaskId =
        input['taskId']?.toString() ?? input['task_id']?.toString();
    final rawResult = message.toolOutput ?? '';
    final result = normalizeStructuredToolOutput(rawResult).trim();
    final resultTaskId = RegExp(
      r'Task ID:\s*([A-Za-z0-9_-]+)',
      caseSensitive: false,
    ).firstMatch(result)?.group(1);
    final pid = RegExp(
      r'PID:\s*([A-Za-z0-9_-]+)',
      caseSensitive: false,
    ).firstMatch(result)?.group(1);
    final resultTimeout = RegExp(
      r'(?:Monitoring\s+)?timeout:\s*(\d+)s',
      caseSensitive: false,
    ).firstMatch(result)?.group(1);
    final inputTimeout = input['timeoutSeconds'] ?? input['timeout_seconds'];
    final timeoutSeconds = inputTimeout is num
        ? inputTimeout.toInt()
        : int.tryParse(inputTimeout?.toString() ?? resultTimeout ?? '');
    final taskId =
        input['_monitorTaskId']?.toString() ?? resultTaskId ?? requestedTaskId;

    String status;
    final trackedStatus = input['_monitorStatus']?.toString();
    if (trackedStatus != null && trackedStatus.isNotEmpty) {
      status = trackedStatus;
    } else if (message.toolStreaming || message.toolOutput == null) {
      status = 'starting';
    } else if (result.toLowerCase().contains('error') ||
        result.toLowerCase().contains('requires either')) {
      status = 'failed';
    } else if (result.toLowerCase().contains('disabled') ||
        result.toLowerCase().contains('not being monitored')) {
      status = 'stopped';
    } else if (result.toLowerCase().contains('monitoring enabled') ||
        result.toLowerCase().contains('process started')) {
      // A restored tool result proves the process started, but not that it is
      // still alive. Live lifecycle events promote this to running/completed.
      status = 'started';
    } else {
      status = 'completed';
    }

    final description = input['description']?.toString().trim();
    return MonitorToolDetails(
      description: description?.isNotEmpty == true
          ? description!
          : command.isNotEmpty
          ? command
          : requestedTaskId == null
          ? 'Background process'
          : 'Monitor $requestedTaskId',
      command: command,
      taskId: taskId,
      pid: pid,
      timeoutSeconds: timeoutSeconds,
      status: status,
      result: result,
    );
  }
}

class MonitorToolCard extends StatefulWidget {
  final ChatMessage message;

  const MonitorToolCard({super.key, required this.message});

  @override
  State<MonitorToolCard> createState() => _MonitorToolCardState();
}

class _MonitorToolCardState extends State<MonitorToolCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final details = MonitorToolDetails.fromMessage(widget.message);
    final statusColor = _statusColor(details.status);
    final canExpand =
        details.command.isNotEmpty ||
        details.taskId != null ||
        details.pid != null ||
        details.timeoutSeconds != null ||
        (details.result.isNotEmpty && details.status == 'failed');

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E2E),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF89B4FA).withAlpha(80)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: canExpand
                ? () => setState(() => _expanded = !_expanded)
                : null,
            borderRadius: BorderRadius.vertical(
              top: const Radius.circular(12),
              bottom: _expanded ? Radius.zero : const Radius.circular(12),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              child: Row(
                children: [
                  const Icon(
                    Icons.monitor_heart_outlined,
                    size: 17,
                    color: Color(0xFF89B4FA),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Monitor',
                    style: GoogleFonts.jetBrainsMono(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: const Color(0xFF89B4FA),
                    ),
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      details.description,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.jetBrainsMono(
                        fontSize: 11,
                        color: const Color(0xFFA6ADC8),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _StatusBadge(status: details.status, color: statusColor),
                  if (canExpand) ...[
                    const SizedBox(width: 4),
                    Icon(
                      _expanded ? Icons.expand_less : Icons.expand_more,
                      size: 18,
                      color: const Color(0xFF6C7086),
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (!_expanded &&
              (details.pid != null || details.timeoutSeconds != null))
            Padding(
              padding: const EdgeInsets.fromLTRB(37, 0, 12, 9),
              child: Wrap(
                spacing: 12,
                runSpacing: 4,
                children: [
                  if (details.pid != null) _metaText('PID ${details.pid}'),
                  if (details.timeoutSeconds != null)
                    _metaText('Timeout ${_duration(details.timeoutSeconds!)}'),
                ],
              ),
            ),
          if (_expanded)
            Container(
              constraints: const BoxConstraints(maxHeight: 300),
              decoration: const BoxDecoration(
                color: Color(0xFF181825),
                border: Border(
                  top: BorderSide(color: Color(0xFF313244), width: 1),
                ),
                borderRadius: BorderRadius.vertical(
                  bottom: Radius.circular(12),
                ),
              ),
              child: ScrollPassthrough(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (details.command.isNotEmpty) ...[
                        _label('COMMAND'),
                        const SizedBox(height: 5),
                        SelectableText(
                          details.command,
                          style: GoogleFonts.jetBrainsMono(
                            fontSize: 11,
                            height: 1.4,
                            color: const Color(0xFFF9E2AF),
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],
                      Wrap(
                        spacing: 16,
                        runSpacing: 8,
                        children: [
                          if (details.taskId != null)
                            _detail('TASK', details.taskId!),
                          if (details.pid != null) _detail('PID', details.pid!),
                          if (details.timeoutSeconds != null)
                            _detail(
                              'TIMEOUT',
                              _duration(details.timeoutSeconds!),
                            ),
                        ],
                      ),
                      if (details.status == 'failed' &&
                          details.result.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        SelectableText(
                          details.result,
                          style: GoogleFonts.jetBrainsMono(
                            fontSize: 11,
                            height: 1.4,
                            color: const Color(0xFFF38BA8),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  static Color _statusColor(String status) {
    switch (status) {
      case 'running':
        return const Color(0xFFA6E3A1);
      case 'failed':
        return const Color(0xFFF38BA8);
      case 'stopped':
      case 'cancelled':
        return const Color(0xFFF9E2AF);
      case 'completed':
        return const Color(0xFF94E2D5);
      case 'started':
        return const Color(0xFF89B4FA);
      default:
        return const Color(0xFF89B4FA);
    }
  }

  static String _duration(int seconds) {
    if (seconds % 3600 == 0) return '${seconds ~/ 3600}h';
    if (seconds % 60 == 0) return '${seconds ~/ 60}m';
    return '${seconds}s';
  }

  static Widget _metaText(String value) => Text(
    value,
    style: GoogleFonts.jetBrainsMono(
      fontSize: 10,
      color: const Color(0xFF6C7086),
    ),
  );

  static Widget _label(String value) => Text(
    value,
    style: GoogleFonts.jetBrainsMono(
      fontSize: 9,
      fontWeight: FontWeight.bold,
      letterSpacing: 0.8,
      color: const Color(0xFF6C7086),
    ),
  );

  static Widget _detail(String label, String value) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      _label(label),
      const SizedBox(height: 2),
      SelectableText(
        value,
        style: GoogleFonts.jetBrainsMono(
          fontSize: 10,
          color: const Color(0xFFCDD6F4),
        ),
      ),
    ],
  );
}

class _StatusBadge extends StatelessWidget {
  final String status;
  final Color color;

  const _StatusBadge({required this.status, required this.color});

  @override
  Widget build(BuildContext context) {
    final label = status == 'starting' ? 'STARTING' : status.toUpperCase();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withAlpha(24),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: color.withAlpha(55)),
      ),
      child: Text(
        label,
        style: GoogleFonts.jetBrainsMono(
          fontSize: 8,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.3,
          color: color,
        ),
      ),
    );
  }
}
