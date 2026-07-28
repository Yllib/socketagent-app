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
  final Map<String, Map<String, dynamic>> workflowTasks;
  final List<ChatMessage> messages;
  final void Function(String taskId)? onStopTask;
  final void Function(String toolUseId)? onScrollToTask;
  final void Function(String toolUseId)? onDismissSubagent;
  final void Function(String taskId)? onDismissWorkflow;

  const ActiveTasksPane({
    super.key,
    required this.backgroundTasks,
    required this.subagentTasks,
    required this.workflowTasks,
    required this.messages,
    this.onStopTask,
    this.onScrollToTask,
    this.onDismissSubagent,
    this.onDismissWorkflow,
  });

  @override
  State<ActiveTasksPane> createState() => _ActiveTasksPaneState();
}

class _ActiveTasksPaneState extends State<ActiveTasksPane> {
  final Set<String> _expandedIds = {};
  final Set<String> _autoExpandedIds =
      {}; // track which have been auto-expanded
  final Set<String> _userCollapsedIds =
      {}; // track which the user manually collapsed
  double _paneHeight = 160;
  static const double _minHeight = 60;
  static const double _maxHeight = 500;
  Map<String, ChatMessage> _toolCallsById = {};
  Map<String, List<ChatMessage>> _childMessagesByParent = {};
  Map<String, String?> _monitorOutputByTask = {};
  int _indexedMessageCount = -1;
  ChatMessage? _indexedFirstMessage;
  ChatMessage? _indexedLastMessage;

  @override
  void initState() {
    super.initState();
    _reindexMessages(force: true);
  }

  @override
  void didUpdateWidget(ActiveTasksPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    _reindexMessages();
  }

  void _reindexMessages({bool force = false}) {
    final first = widget.messages.firstOrNull;
    final last = widget.messages.lastOrNull;
    if (!force &&
        _indexedMessageCount == widget.messages.length &&
        identical(_indexedFirstMessage, first) &&
        identical(_indexedLastMessage, last)) {
      return;
    }

    final toolCallsById = <String, ChatMessage>{};
    final childMessagesByParent = <String, List<ChatMessage>>{};
    final monitorOutputByTask = <String, String?>{};
    for (final message in widget.messages) {
      final parentToolUseId = message.parentToolUseId;
      if (parentToolUseId != null && parentToolUseId.isNotEmpty) {
        (childMessagesByParent[parentToolUseId] ??= []).add(message);
      }
      final toolUseId = message.toolUseId;
      if (message.type == MessageType.toolCall &&
          toolUseId != null &&
          toolUseId.isNotEmpty) {
        toolCallsById[toolUseId] = message;
      } else if (message.type == MessageType.monitorOutput &&
          toolUseId != null &&
          toolUseId.isNotEmpty) {
        monitorOutputByTask[toolUseId] = message.toolOutput;
      }
    }
    _toolCallsById = toolCallsById;
    _childMessagesByParent = childMessagesByParent;
    _monitorOutputByTask = monitorOutputByTask;
    _indexedMessageCount = widget.messages.length;
    _indexedFirstMessage = first;
    _indexedLastMessage = last;
  }

  List<_TaskEntry> get _entries {
    final entries = <_TaskEntry>[];

    // Background bash tasks and monitor tasks
    for (final e in widget.backgroundTasks.entries) {
      final originToolUseId = e.value['originToolUseId'] as String?;
      final isMonitor = e.value['isMonitor'] == true;
      // Find the tool card's streamed output (bash tasks only)
      String? output;
      if (!isMonitor && originToolUseId != null) {
        output = _toolCallsById[originToolUseId]?.toolOutput;
      }
      // For monitor tasks, find accumulated monitor output from chat
      if (isMonitor) {
        output = _monitorOutputByTask[e.key];
      }
      entries.add(
        _TaskEntry(
          id: e.key,
          kind: isMonitor ? 'monitor' : 'bash',
          description: e.value['summary'] as String? ?? 'Background task',
          status: e.value['status'] as String? ?? 'running',
          scrollToolUseId: originToolUseId ?? e.key,
          stoppable: true,
          bashOutput: output,
        ),
      );
    }

    // Subagent tasks (running + completed)
    for (final e in widget.subagentTasks.entries) {
      if (e.value['dismissed'] == true) continue;
      final toolUseId = e.key;
      final status = e.value['status'] as String? ?? 'running';
      final children =
          _childMessagesByParent[toolUseId] ?? const <ChatMessage>[];
      // Find the tool call message to get the result output
      final resultOutput = status == 'completed'
          ? _toolCallsById[toolUseId]?.toolOutput
          : null;
      entries.add(
        _TaskEntry(
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
        ),
      );
    }

    // Claude Workflow runs are first-class orchestration tasks. Keep completed
    // runs visible until dismissed, like subagents.
    for (final e in widget.workflowTasks.entries) {
      if (e.value['dismissed'] == true) continue;
      final status = e.value['status']?.toString() ?? 'running';
      entries.add(
        _TaskEntry(
          id: e.key,
          kind: 'workflow',
          description:
              e.value['workflowName']?.toString() ??
              e.value['summary']?.toString() ??
              'Workflow',
          status: status,
          scrollToolUseId: e.value['toolUseId']?.toString() ?? e.key,
          stoppable:
              status == 'running' || status == 'pending' || status == 'paused',
          workflow: e.value,
        ),
      );
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
                _paneHeight = (_paneHeight - details.delta.dy).clamp(
                  _minHeight,
                  _maxHeight,
                );
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
                ? Border(
                    top: BorderSide(color: Colors.blue.shade900.withAlpha(80)),
                  )
                : null,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Header bar
              InkWell(
                onTap: () => provider.taskPaneCollapsed = !paneCollapsed,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  child: Row(
                    children: [
                      if (entries.any(
                        (e) =>
                            e.status == 'running' ||
                            e.status == 'pending' ||
                            e.status == 'paused',
                      ))
                        SizedBox(
                          width: 10,
                          height: 10,
                          child: CircularProgressIndicator(
                            strokeWidth: 1.5,
                            color: Colors.blue.shade300,
                          ),
                        )
                      else
                        Icon(
                          Icons.check_circle,
                          size: 12,
                          color: Colors.green.shade400,
                        ),
                      const SizedBox(width: 8),
                      Text(
                        () {
                          final running = entries
                              .where(
                                (e) =>
                                    e.status == 'running' ||
                                    e.status == 'pending' ||
                                    e.status == 'paused',
                              )
                              .length;
                          final done = entries
                              .where(
                                (e) =>
                                    e.status != 'running' &&
                                    e.status != 'pending' &&
                                    e.status != 'paused',
                              )
                              .length;
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
                    itemBuilder: (context, index) =>
                        _buildEntry(entries[index]),
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
    final isCompleted =
        entry.status == 'completed' ||
        entry.status == 'failed' ||
        entry.status == 'stopped';
    final terminalColor = entry.status == 'failed'
        ? const Color(0xFFF38BA8)
        : entry.status == 'stopped'
        ? const Color(0xFFFAB387)
        : const Color(0xFFA6E3A1);
    final hasContent = entry.kind == 'subagent' || entry.kind == 'workflow'
        ? true // subagents always expandable (prompt + children + result)
        : (entry.bashOutput?.isNotEmpty ?? false) || entry.kind == 'monitor';

    // Auto-expand completed subagents that have results (only once, respect user collapse)
    if (isCompleted &&
        entry.resultOutput != null &&
        entry.resultOutput!.isNotEmpty &&
        !_autoExpandedIds.contains(entry.id) &&
        !_userCollapsedIds.contains(entry.id)) {
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
                  Icon(
                    entry.status == 'failed'
                        ? Icons.error
                        : entry.status == 'stopped'
                        ? Icons.stop_circle
                        : Icons.check_circle,
                    size: 13,
                    color: terminalColor,
                  )
                else
                  Icon(
                    entry.kind == 'monitor'
                        ? Icons.monitor_heart_outlined
                        : entry.kind == 'subagent'
                        ? Icons.account_tree
                        : entry.kind == 'workflow'
                        ? Icons.hub_outlined
                        : Icons.terminal,
                    size: 13,
                    color: entry.kind == 'monitor'
                        ? const Color(0xFF89B4FA)
                        : Colors.blue.shade300,
                  ),
                const SizedBox(width: 6),
                // Subagent type badge
                if (entry.subagentType != null &&
                    entry.subagentType!.isNotEmpty) ...[
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 1,
                    ),
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
                    onTap: () =>
                        widget.onScrollToTask?.call(entry.scrollToolUseId),
                    child: Text(
                      entry.description,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: isCompleted
                            ? terminalColor
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
                else if (isCompleted &&
                    entry.kind == 'workflow' &&
                    widget.onDismissWorkflow != null)
                  GestureDetector(
                    onTap: () => widget.onDismissWorkflow!(entry.id),
                    child: Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: Icon(
                        Icons.close,
                        size: 14,
                        color: Colors.blue.shade400,
                      ),
                    ),
                  )
                else if (isCompleted &&
                    entry.kind == 'subagent' &&
                    widget.onDismissSubagent != null)
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
                      : entry.kind == 'workflow'
                      ? _buildWorkflowContent(entry)
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
              border: Border(bottom: BorderSide(color: Color(0xFF313244))),
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
              border: Border(bottom: BorderSide(color: Color(0xFF313244))),
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
        ...(entry.childMessages ?? []).map((m) => _buildChildMessage(m)),
      ],
    );
  }

  Widget _buildWorkflowContent(_TaskEntry entry) {
    final state = entry.workflow ?? const <String, dynamic>{};
    final phases = (state['phases'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
    final progress = (state['progress'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
    final metrics = <String>[
      if ((state['agentCount'] as num?) case final count? when count > 0)
        '${count.toInt()} agents',
      if ((state['totalTokens'] as num?) case final tokens? when tokens > 0)
        '${tokens.toInt()} tokens',
      if ((state['durationMs'] as num?) case final duration? when duration > 0)
        '${(duration / 1000).round()}s',
    ];
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (state['summary']?.toString().isNotEmpty == true)
            Text(
              state['summary'].toString(),
              style: const TextStyle(fontSize: 10, color: Color(0xFFA6ADC8)),
            ),
          if (metrics.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              metrics.join(' · '),
              style: const TextStyle(fontSize: 9, color: Color(0xFF89B4FA)),
            ),
          ],
          ...List.generate(phases.length, (index) {
            final phase = phases[index];
            final agents = progress.where(
              (item) =>
                  item['type'] == 'workflow_agent' &&
                  (item['phaseIndex'] as num?)?.toInt() == index,
            );
            return Padding(
              padding: const EdgeInsets.only(top: 7),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    phase['title']?.toString() ?? 'Phase ${index + 1}',
                    style: const TextStyle(
                      color: Color(0xFFCBA6F7),
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  ...agents.map((agent) {
                    final status = agent['state']?.toString() ?? 'queued';
                    return Padding(
                      padding: const EdgeInsets.only(top: 3, left: 5),
                      child: Row(
                        children: [
                          Icon(
                            status == 'completed'
                                ? Icons.check_circle
                                : status == 'failed'
                                ? Icons.error
                                : Icons.circle_outlined,
                            size: 10,
                            color: status == 'completed'
                                ? const Color(0xFFA6E3A1)
                                : status == 'failed'
                                ? const Color(0xFFF38BA8)
                                : const Color(0xFF89B4FA),
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              agent['label']?.toString() ??
                                  agent['agentId']?.toString() ??
                                  'Agent',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Color(0xFFCDD6F4),
                                fontSize: 9,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  }),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildChildMessage(ChatMessage msg) {
    switch (msg.type) {
      case MessageType.text:
        return MessageBubble(message: msg);
      case MessageType.toolCall:
        if (msg.toolName == 'Speak') return SpeakCard(message: msg);
        if (msg.toolName == 'SendFile') return FileCard(message: msg);
        if (msg.toolName == 'ScheduleReminder') {
          return ReminderCard(message: msg);
        }
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
  final Map<String, dynamic>? workflow;

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
    this.workflow,
  });
}
