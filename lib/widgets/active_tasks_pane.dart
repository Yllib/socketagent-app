import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../models/message.dart';
import '../services/chat_provider.dart';
import 'tool_output_block.dart';
import 'message_bubble.dart';
import 'speak_card.dart';
import 'file_card.dart';
import 'reminder_card.dart';

class ActiveTasksPane extends StatefulWidget {
  final Map<String, Map<String, dynamic>> backgroundTasks;
  final Map<String, Map<String, dynamic>> subagentTasks;
  final List<ChatMessage> messages;
  final void Function(String taskId)? onStopTask;
  final void Function(String toolUseId)? onScrollToTask;
  final void Function(String toolUseId)? onDismissSubagent;

  const ActiveTasksPane({
    super.key,
    required this.backgroundTasks,
    required this.subagentTasks,
    required this.messages,
    this.onStopTask,
    this.onScrollToTask,
    this.onDismissSubagent,
  });

  @override
  State<ActiveTasksPane> createState() => _ActiveTasksPaneState();
}

class _ActiveTasksPaneState extends State<ActiveTasksPane> {
  final Set<String> _expandedIds = {};
  final Set<String> _autoExpandedIds = {}; // track which have been auto-expanded
  final Set<String> _userCollapsedIds = {}; // track which the user manually collapsed
  double _paneHeight = 160;
  static const double _minHeight = 60;
  static const double _maxHeight = 500;
  static const double _headerHeight = 28;

  List<_TaskEntry> get _entries {
    final entries = <_TaskEntry>[];

    // Background bash tasks
    for (final e in widget.backgroundTasks.entries) {
      final originToolUseId = e.value['originToolUseId'] as String?;
      // Find the tool card's streamed output
      String? output;
      if (originToolUseId != null) {
        for (final m in widget.messages.reversed) {
          if (m.type == MessageType.toolCall && m.toolUseId == originToolUseId) {
            output = m.toolOutput;
            break;
          }
        }
      }
      entries.add(_TaskEntry(
        id: e.key,
        kind: 'bash',
        description: e.value['summary'] as String? ?? 'Background task',
        status: e.value['status'] as String? ?? 'running',
        scrollToolUseId: originToolUseId ?? e.key,
        stoppable: true,
        bashOutput: output,
      ));
    }

    // Subagent tasks (running + completed)
    for (final e in widget.subagentTasks.entries) {
      if (e.value['dismissed'] == true) continue;
      final toolUseId = e.key;
      final status = e.value['status'] as String? ?? 'running';
      final children = widget.messages
          .where((m) => m.parentToolUseId == toolUseId)
          .toList();
      // Find the tool call message to get the result output
      String? resultOutput;
      if (status == 'completed') {
        for (final m in widget.messages) {
          if (m.type == MessageType.toolCall && m.toolUseId == toolUseId) {
            resultOutput = m.toolOutput;
            break;
          }
        }
      }
      entries.add(_TaskEntry(
        id: toolUseId,
        kind: 'subagent',
        description: e.value['description'] as String? ?? 'Sub agent',
        prompt: e.value['prompt'] as String?,
        subagentType: e.value['subagentType'] as String?,
        status: status,
        scrollToolUseId: toolUseId,
        stoppable: false,
        childMessages: children,
        resultOutput: resultOutput,
      ));
    }

    return entries;
  }

  @override
  Widget build(BuildContext context) {
    final entries = _entries;
    if (entries.isEmpty) return const SizedBox.shrink();

    final provider = context.read<ChatProvider>();
    final paneCollapsed = provider.taskPaneCollapsed;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Drag handle
        if (!paneCollapsed)
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onVerticalDragUpdate: (details) {
              setState(() {
                _paneHeight = (_paneHeight - details.delta.dy)
                    .clamp(_minHeight, _maxHeight);
              });
            },
            child: Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.blue.shade900.withAlpha(40),
                  border: Border(
                    top: BorderSide(color: Colors.blue.shade900.withAlpha(80)),
                  ),
                ),
                height: 12,
                child: Center(
                  child: Container(
                    width: 32,
                    height: 3,
                    decoration: BoxDecoration(
                      color: Colors.blue.shade700.withAlpha(120),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
            ),
          ),
        // Main pane
        Container(
          height: paneCollapsed ? null : _paneHeight,
          decoration: BoxDecoration(
            color: Colors.blue.shade900.withAlpha(40),
            border: paneCollapsed
                ? Border(top: BorderSide(color: Colors.blue.shade900.withAlpha(80)))
                : null,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Header bar
              InkWell(
                onTap: () => provider.taskPaneCollapsed = !paneCollapsed,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: Row(
                    children: [
                      if (entries.any((e) => e.status == 'running'))
                        SizedBox(
                          width: 10, height: 10,
                          child: CircularProgressIndicator(
                            strokeWidth: 1.5,
                            color: Colors.blue.shade300,
                          ),
                        )
                      else
                        Icon(Icons.check_circle, size: 12, color: Colors.green.shade400),
                      const SizedBox(width: 8),
                      Text(
                        () {
                          final running = entries.where((e) => e.status == 'running').length;
                          final done = entries.where((e) => e.status != 'running').length;
                          final parts = <String>[];
                          if (running > 0) parts.add('$running running');
                          if (done > 0) parts.add('$done done');
                          return parts.join(', ');
                        }(),
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                          color: Colors.blue.shade200,
                        ),
                      ),
                      const Spacer(),
                      Icon(
                        paneCollapsed ? Icons.expand_less : Icons.expand_more,
                        size: 16,
                        color: Colors.blue.shade300,
                      ),
                    ],
                  ),
                ),
              ),
              // Task entries
              if (!paneCollapsed)
                Flexible(
                  child: ListView.builder(
                    padding: EdgeInsets.zero,
                    itemCount: entries.length,
                    itemBuilder: (context, index) => _buildEntry(entries[index]),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildEntry(_TaskEntry entry) {
    final isExpanded = _expandedIds.contains(entry.id);
    final isCompleted = entry.status == 'completed';
    final hasContent = entry.kind == 'subagent'
        ? true  // subagents always expandable (prompt + children + result)
        : (entry.bashOutput?.isNotEmpty ?? false);

    // Auto-expand completed subagents that have results (only once, respect user collapse)
    if (isCompleted && entry.resultOutput != null && entry.resultOutput!.isNotEmpty
        && !_autoExpandedIds.contains(entry.id) && !_userCollapsedIds.contains(entry.id)) {
      _autoExpandedIds.add(entry.id);
      _expandedIds.add(entry.id);
    }

    return Container(
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: Colors.blue.shade900.withAlpha(60)),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Entry header row
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              children: [
                // Expand/collapse chevron
                if (hasContent)
                  GestureDetector(
                    onTap: () => setState(() {
                      if (isExpanded) {
                        _expandedIds.remove(entry.id);
                        _userCollapsedIds.add(entry.id);
                      } else {
                        _expandedIds.add(entry.id);
                        _userCollapsedIds.remove(entry.id);
                      }
                    }),
                    child: Icon(
                      isExpanded ? Icons.expand_less : Icons.expand_more,
                      size: 16,
                      color: Colors.blue.shade300,
                    ),
                  )
                else
                  const SizedBox(width: 16),
                const SizedBox(width: 4),
                // Status icon
                if (isCompleted)
                  Icon(Icons.check_circle, size: 13, color: Colors.green.shade400)
                else
                  Icon(
                    entry.kind == 'subagent'
                        ? Icons.account_tree
                        : Icons.terminal,
                    size: 13,
                    color: Colors.blue.shade300,
                  ),
                const SizedBox(width: 6),
                // Subagent type badge
                if (entry.subagentType != null && entry.subagentType!.isNotEmpty) ...[
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                    decoration: BoxDecoration(
                      color: Colors.blue.shade800.withAlpha(100),
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: Text(
                      entry.subagentType!,
                      style: TextStyle(
                        fontSize: 9,
                        color: Colors.blue.shade200,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  const SizedBox(width: 5),
                ],
                // Description — tap to scroll to task in chat
                Expanded(
                  child: GestureDetector(
                    onTap: () => widget.onScrollToTask?.call(entry.scrollToolUseId),
                    child: Text(
                      entry.description,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: isCompleted
                            ? Colors.green.shade200
                            : Colors.blue.shade100,
                      ),
                    ),
                  ),
                ),
                // Stop button (bash) or dismiss button (completed subagent)
                if (entry.stoppable && widget.onStopTask != null)
                  GestureDetector(
                    onTap: () => widget.onStopTask!(entry.id),
                    child: Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: Icon(
                        Icons.stop_circle_outlined,
                        size: 16,
                        color: Colors.red.shade300,
                      ),
                    ),
                  )
                else if (isCompleted && widget.onDismissSubagent != null)
                  GestureDetector(
                    onTap: () => widget.onDismissSubagent!(entry.id),
                    child: Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: Icon(
                        Icons.close,
                        size: 14,
                        color: Colors.blue.shade400,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          // Expanded content
          if (isExpanded)
            Flexible(
              child: Container(
                margin: const EdgeInsets.only(left: 24, right: 8, bottom: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E1E2E),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: const Color(0xFF313244)),
                ),
                child: SingleChildScrollView(
                  child: entry.kind == 'subagent'
                      ? _buildSubagentContent(entry)
                      : Padding(
                          padding: const EdgeInsets.all(8),
                          child: Text(
                            entry.bashOutput ?? '',
                            style: GoogleFonts.jetBrainsMono(
                              fontSize: 10,
                              color: const Color(0xFFCDD6F4),
                              height: 1.3,
                            ),
                            maxLines: 50,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSubagentContent(_TaskEntry entry) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Result section (shown first for completed agents)
        if (entry.resultOutput != null && entry.resultOutput!.isNotEmpty)
          Container(
            padding: const EdgeInsets.all(8),
            decoration: const BoxDecoration(
              border: Border(
                bottom: BorderSide(color: Color(0xFF313244)),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'RESULT',
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w600,
                    color: Colors.green.shade400,
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  entry.resultOutput!,
                  style: GoogleFonts.jetBrainsMono(
                    fontSize: 10,
                    color: const Color(0xFFCDD6F4),
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        // Prompt section
        if (entry.prompt != null && entry.prompt!.isNotEmpty)
          Container(
            padding: const EdgeInsets.all(8),
            decoration: const BoxDecoration(
              border: Border(
                bottom: BorderSide(color: Color(0xFF313244)),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'PROMPT',
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w600,
                    color: Colors.blue.shade400,
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  entry.prompt!,
                  style: GoogleFonts.jetBrainsMono(
                    fontSize: 10,
                    color: const Color(0xFFA6ADC8),
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        // Child messages
        ...(entry.childMessages ?? [])
            .map((m) => _buildChildMessage(m)),
      ],
    );
  }

  Widget _buildChildMessage(ChatMessage msg) {
    switch (msg.type) {
      case MessageType.text:
        return MessageBubble(message: msg);
      case MessageType.toolCall:
        if (msg.toolName == 'Speak') return SpeakCard(message: msg);
        if (msg.toolName == 'SendFile') return FileCard(message: msg);
        if (msg.toolName == 'ScheduleReminder') return ReminderCard(message: msg);
        return ToolOutputBlock(message: msg);
      case MessageType.toolResult:
        return ToolOutputBlock(message: msg);
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

class _TaskEntry {
  final String id;
  final String kind; // 'bash' or 'subagent'
  final String description;
  final String? prompt;
  final String? subagentType;
  final String status;
  final String scrollToolUseId;
  final bool stoppable;
  final String? bashOutput;
  final List<ChatMessage>? childMessages;
  final String? resultOutput;

  _TaskEntry({
    required this.id,
    required this.kind,
    required this.description,
    this.prompt,
    this.subagentType,
    required this.status,
    required this.scrollToolUseId,
    required this.stoppable,
    this.bashOutput,
    this.childMessages,
    this.resultOutput,
  });
}
