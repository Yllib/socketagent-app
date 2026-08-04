import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../models/message.dart';
import 'tool_output_block.dart';
import 'message_bubble.dart';
import 'speak_card.dart';
import 'file_card.dart';
import 'reminder_card.dart';
import 'scroll_passthrough.dart';
import 'thinking_card.dart';

class SubAgentCard extends StatefulWidget {
  final ChatMessage message;
  final List<ChatMessage> childMessages;
  final bool isRunning;
  final GlobalKey? scrollKey;
  final bool greenTheme; // completion card styling
  final String? sourceServerId;

  const SubAgentCard({
    super.key,
    required this.message,
    required this.childMessages,
    required this.isRunning,
    this.scrollKey,
    this.greenTheme = false,
    this.sourceServerId,
  });

  @override
  State<SubAgentCard> createState() => _SubAgentCardState();
}

class _SubAgentCardState extends State<SubAgentCard> {
  bool _expanded = false;

  String get _description {
    final input = widget.message.toolInput;
    if (input == null) return 'Sub agent task';
    return input['description'] as String? ?? 'Sub agent task';
  }

  String get _agentType {
    final input = widget.message.toolInput;
    if (input == null) return '';
    return input['subagent_type'] as String? ?? '';
  }

  String get _prompt {
    final input = widget.message.toolInput;
    if (input == null) return '';
    return input['prompt'] as String? ?? '';
  }

  String get _resultOutput {
    return widget.message.toolOutput ?? '';
  }

  String get _taskStatus {
    return widget.message.toolInput?['_task_status']?.toString() ??
        (widget.isRunning ? 'running' : 'completed');
  }

  String get _progressSummary {
    return widget.message.toolInput?['_progress_summary']?.toString() ?? '';
  }

  String get _lastToolName {
    return widget.message.toolInput?['_last_tool_name']?.toString() ?? '';
  }

  Map<String, dynamic> get _taskUsage {
    final raw = widget.message.toolInput?['_task_usage'];
    return raw is Map ? Map<String, dynamic>.from(raw) : const {};
  }

  String get _activityDetail {
    final parts = <String>[];
    if (_progressSummary.isNotEmpty) {
      parts.add(_progressSummary);
    } else if (_lastToolName.isNotEmpty) {
      parts.add('Using $_lastToolName');
    }
    final durationMs =
        (_taskUsage['durationMs'] as num?)?.toInt() ??
        (_taskUsage['duration_ms'] as num?)?.toInt() ??
        0;
    final totalTokens =
        (_taskUsage['totalTokens'] as num?)?.toInt() ??
        (_taskUsage['total_tokens'] as num?)?.toInt() ??
        0;
    final metrics = <String>[];
    if (durationMs > 0) metrics.add('${(durationMs / 1000).round()}s');
    if (totalTokens > 0) metrics.add('$totalTokens tokens');
    if (metrics.isNotEmpty) parts.add(metrics.join(' · '));
    return parts.join('  •  ');
  }

  @override
  Widget build(BuildContext context) {
    final isDone = !widget.isRunning;
    final hasChildren = widget.childMessages.isNotEmpty;
    final hasPrompt = _prompt.isNotEmpty;
    final hasResult = _resultOutput.isNotEmpty;
    final hasExpandableContent = hasChildren || hasPrompt;
    final green = widget.greenTheme;
    final failed = _taskStatus == 'failed' || _taskStatus == 'errored';
    final stopped = _taskStatus == 'stopped' || _taskStatus == 'interrupted';
    final accentColor = failed
        ? const Color(0xFFF38BA8)
        : stopped
        ? const Color(0xFFF9E2AF)
        : green || isDone
        ? const Color(0xFFA6E3A1)
        : const Color(0xFF89B4FA);
    final statusLabel = widget.isRunning
        ? 'Sub Agent'
        : failed
        ? 'Failed'
        : stopped
        ? 'Stopped'
        : 'Completed';

    return Container(
      key: widget.scrollKey,
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E2E),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: widget.isRunning
              ? accentColor.withAlpha(100)
              : green
              ? const Color(0xFFA6E3A1).withAlpha(60)
              : const Color(0xFF313244),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header
          InkWell(
            onTap: isDone && hasExpandableContent
                ? () => setState(() => _expanded = !_expanded)
                : null,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Icon(
                    failed
                        ? Icons.error_outline
                        : stopped
                        ? Icons.stop_circle_outlined
                        : isDone
                        ? Icons.check_circle
                        : Icons.account_tree,
                    size: 16,
                    color: accentColor,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    statusLabel,
                    style: GoogleFonts.jetBrainsMono(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: accentColor,
                    ),
                  ),
                  if (_agentType.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFFA6E3A1).withAlpha(25),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        _agentType,
                        style: GoogleFonts.jetBrainsMono(
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                          color: const Color(0xFFA6E3A1),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _description,
                      style: GoogleFonts.jetBrainsMono(
                        fontSize: 11,
                        color: const Color(0xFFA6ADC8),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (widget.isRunning) ...[
                    if (widget.message.toolElapsedSeconds > 0)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: Text(
                          '${widget.message.toolElapsedSeconds.toStringAsFixed(0)}s',
                          style: GoogleFonts.jetBrainsMono(
                            fontSize: 10,
                            color: const Color(0xFF6C7086),
                          ),
                        ),
                      ),
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Color(0xFF89B4FA),
                      ),
                    ),
                  ] else if (hasExpandableContent)
                    Icon(
                      _expanded ? Icons.expand_less : Icons.expand_more,
                      size: 18,
                      color: const Color(0xFF6C7086),
                    )
                  else
                    const Icon(Icons.check, size: 16, color: Color(0xFF6C7086)),
                ],
              ),
            ),
          ),
          if (_activityDetail.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(36, 0, 12, 8),
              child: Text(
                _activityDetail,
                style: GoogleFonts.jetBrainsMono(
                  fontSize: 10,
                  color: const Color(0xFFA6ADC8),
                  height: 1.35,
                ),
                maxLines: widget.isRunning ? 2 : 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          // Response section (always visible when completed with result)
          if (isDone && hasResult)
            Container(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Text(
                _resultOutput,
                style: GoogleFonts.jetBrainsMono(
                  fontSize: 10,
                  color: const Color(0xFFCDD6F4),
                  height: 1.4,
                ),
                maxLines: 6,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          // Expanded content (prompt + child messages)
          if (_expanded && hasExpandableContent) ...[
            Container(
              decoration: const BoxDecoration(
                border: Border(
                  top: BorderSide(color: Color(0xFF313244), width: 1),
                ),
              ),
              constraints: const BoxConstraints(maxHeight: 400),
              child: ScrollPassthrough(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Prompt
                      if (hasPrompt)
                        _buildSection(
                          label: 'PROMPT',
                          labelColor: const Color(0xFF89B4FA),
                          content: _prompt,
                        ),
                      // Child messages
                      ...widget.childMessages.map(
                        (child) => _buildChildMessage(child),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSection({
    required String label,
    required Color labelColor,
    required String content,
  }) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xFF313244), width: 1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: GoogleFonts.jetBrainsMono(
              fontSize: 9,
              fontWeight: FontWeight.w600,
              color: labelColor,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            content,
            style: GoogleFonts.jetBrainsMono(
              fontSize: 10,
              color: const Color(0xFFCDD6F4),
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChildMessage(ChatMessage msg) {
    switch (msg.type) {
      case MessageType.text:
        return MessageBubble(
          message: msg,
          sourceServerId: widget.sourceServerId,
        );
      case MessageType.toolCall:
        if (msg.toolName == 'Speak') return SpeakCard(message: msg);
        if (msg.toolName == 'SendFile') return FileCard(message: msg);
        if (msg.toolName == 'ScheduleReminder') {
          return ReminderCard(message: msg);
        }
        return ToolOutputBlock(message: msg);
      case MessageType.toolResult:
        return ToolOutputBlock(message: msg);
      case MessageType.thinking:
        return ThinkingCard(message: msg);
      default:
        if (msg.textContent.isNotEmpty) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Text(
              msg.textContent,
              style: const TextStyle(fontSize: 12, color: Color(0xFFA6ADC8)),
            ),
          );
        }
        return const SizedBox.shrink();
    }
  }
}
