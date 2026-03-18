import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/message.dart';
import '../models/raw_event.dart';
import 'message_bubble.dart';
import 'tool_output_block.dart';
import 'speak_card.dart';
import 'file_card.dart';
import 'question_card.dart';
import 'email_preview_card.dart';
import 'todo_list_card.dart';
import 'reminder_card.dart';
import 'outlook_auth_card.dart';
import 'ibs_auth_card.dart';
import 'claude_auth_card.dart';
import 'raw_event_card.dart';
import 'subagent_card.dart';
import 'thinking_card.dart';

class ChatView extends StatefulWidget {
  final List<ChatMessage> messages;
  final bool isProcessing;
  final bool isLoadingHistory;
  final bool isLoadingMore;
  final bool hasMoreHistory;
  final List<Map<String, dynamic>> todos;
  final void Function(String questionId, Map<String, String> answers) onAnswer;
  final VoidCallback? onLoadMore;
  final void Function(String taskId)? onStopTask;
  final VoidCallback? onDismissTodos;
  final void Function(String uuid)? onRewind;
  final bool rawMode;
  final List<SdkItem> rawItems;
  // For SubAgentCard: tracked subagent tasks and full message list for child lookup
  final Map<String, Map<String, dynamic>> subagentTasks;
  final List<ChatMessage> allMessages;

  const ChatView({
    super.key,
    required this.messages,
    required this.isProcessing,
    this.isLoadingHistory = false,
    this.isLoadingMore = false,
    this.hasMoreHistory = false,
    required this.todos,
    required this.onAnswer,
    this.onLoadMore,
    this.onStopTask,
    this.onDismissTodos,
    this.onRewind,
    this.rawMode = false,
    this.rawItems = const [],
    this.subagentTasks = const {},
    this.allMessages = const [],
  });

  @override
  State<ChatView> createState() => ChatViewState();
}

class ChatViewState extends State<ChatView> {
  final ScrollController _scrollController = ScrollController();
  bool _userScrolledUp = false;
  bool _isAutoScrolling = false;
  bool _userTouching = false;
  int _lastKnownMessageCount = 0;
  String _lastKnownText = '';
  bool _lastKnownProcessing = false;
  final Map<String, GlobalKey> _taskKeys = {};

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  void _onScroll() {
    if (!_scrollController.hasClients || _isAutoScrolling) return;
    final pos = _scrollController.position;
    _userScrolledUp = pos.maxScrollExtent - pos.pixels > 150;
  }

  /// Scroll to a task card in the chat by its toolUseId
  void scrollToTask(String toolUseId) {
    final key = _taskKeys[toolUseId];
    if (key?.currentContext != null) {
      Scrollable.ensureVisible(
        key!.currentContext!,
        alignment: 0.3,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  void didUpdateWidget(ChatView oldWidget) {
    super.didUpdateWidget(oldWidget);

    // History just finished loading — jump to bottom unconditionally
    if (oldWidget.isLoadingHistory && !widget.isLoadingHistory) {
      _lastKnownMessageCount = widget.messages.length;
      _lastKnownText = widget.messages.isNotEmpty
          ? widget.messages.last.textContent
          : '';
      _lastKnownProcessing = widget.isProcessing;
      _userScrolledUp = false;
      _jumpToBottomRepeatedly();
      return;
    }

    // "Load more" just finished — preserve scroll position
    if (oldWidget.isLoadingMore && !widget.isLoadingMore) {
      final oldMax = _scrollController.hasClients
          ? _scrollController.position.maxScrollExtent
          : 0.0;
      final oldOffset = _scrollController.hasClients
          ? _scrollController.position.pixels
          : 0.0;
      _lastKnownMessageCount = widget.messages.length;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scrollController.hasClients) return;
        final newMax = _scrollController.position.maxScrollExtent;
        final addedHeight = newMax - oldMax;
        if (addedHeight > 0) {
          _scrollController.jumpTo(oldOffset + addedHeight);
        }
      });
      return;
    }

    final currentCount = widget.messages.length;
    final currentText = widget.messages.isNotEmpty
        ? widget.messages.last.textContent
        : '';
    final currentProcessing = widget.isProcessing;

    final hasNewContent =
        currentCount != _lastKnownMessageCount ||
        currentProcessing != _lastKnownProcessing ||
        currentText != _lastKnownText;

    _lastKnownMessageCount = currentCount;
    _lastKnownText = currentText;
    _lastKnownProcessing = currentProcessing;

    if (hasNewContent && !_userScrolledUp && !_userTouching) {
      _scrollToBottom();
    }
  }

  /// After history load, keep jumping to bottom until maxScrollExtent stabilizes.
  /// ListView is lazy so it keeps laying out more items after each jump.
  void _jumpToBottomRepeatedly([int attempts = 0]) {
    if (attempts > 10) return; // safety limit
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      final target = _scrollController.position.maxScrollExtent;
      _scrollController.jumpTo(target);
      // Check again — if maxScrollExtent changed, more items were laid out
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scrollController.hasClients) return;
        final newTarget = _scrollController.position.maxScrollExtent;
        if (newTarget > target + 1) {
          _jumpToBottomRepeatedly(attempts + 1);
        }
      });
    });
  }

  bool _scrollPending = false;

  void _scrollToBottom({bool jump = false}) {
    if (_scrollPending) return;
    _scrollPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollPending = false;
      if (!_scrollController.hasClients) return;
      final target = _scrollController.position.maxScrollExtent;
      final distance = target - _scrollController.position.pixels;
      if (distance <= 0) return;

      if (jump || distance > 2000) {
        // Large jump (history load) — instant, no animation
        _scrollController.jumpTo(target);
      } else {
        final duration = distance < 200
            ? const Duration(milliseconds: 80)
            : const Duration(milliseconds: 180);

        _isAutoScrolling = true;
        _scrollController
            .animateTo(target, duration: duration, curve: Curves.easeOut)
            .then((_) { _isAutoScrolling = false; })
            .catchError((_) { _isAutoScrolling = false; });
      }
    });
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.isLoadingHistory) {
      return const Center(child: CircularProgressIndicator());
    }

    if (widget.rawMode) {
      return _buildRawView(context);
    }

    if (widget.messages.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.chat_outlined,
              size: 64,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: 16),
            Text(
              'Start a conversation',
              style: TextStyle(
                fontSize: 16,
                color: Theme.of(context).colorScheme.outline,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Type a message or tap the mic',
              style: TextStyle(
                fontSize: 13,
                color: Theme.of(context).colorScheme.outline.withAlpha(178),
              ),
            ),
          ],
        ),
      );
    }

    final hasLoadMore = widget.hasMoreHistory;
    final loadMoreOffset = hasLoadMore ? 1 : 0;
    final itemCount =
        loadMoreOffset + widget.messages.length + (widget.isProcessing ? 1 : 0);

    return Column(
      children: [
        if (widget.todos.isNotEmpty) TodoListCard(todos: widget.todos, onDismiss: widget.onDismissTodos),
        Expanded(
          child: Listener(
            onPointerDown: (_) => _userTouching = true,
            onPointerUp: (_) => _userTouching = false,
            onPointerCancel: (_) => _userTouching = false,
            child: ListView.builder(
              controller: _scrollController,
            padding: const EdgeInsets.only(top: 8, bottom: 8),
            itemCount: itemCount,
            itemBuilder: (context, index) {
              // "Load More" button at the top
              if (hasLoadMore && index == 0) {
                return _buildLoadMoreButton(context);
              }
              final msgIndex = index - loadMoreOffset;
              if (msgIndex == widget.messages.length && widget.isProcessing) {
                return _buildThinkingIndicator(context);
              }
              final msg = widget.messages[msgIndex];
              return _buildMessageWidget(msg);
            },
          ),
          ),
        ),
      ],
    );
  }

  Widget _buildMessageWidget(ChatMessage msg) {
    return _buildMessageContent(msg);
  }

  Widget _buildMessageContent(ChatMessage msg) {
    switch (msg.type) {
      case MessageType.text:
        return MessageBubble(message: msg, onRewind: widget.onRewind);
      case MessageType.toolCall:
        if (msg.toolName == 'Speak') {
          return SpeakCard(message: msg);
        }
        if (msg.toolName == 'SendFile') {
          return FileCard(message: msg);
        }
        if (msg.toolName == 'ScheduleReminder') {
          return ReminderCard(message: msg);
        }
        // Task tool calls get a dedicated SubAgentCard
        if ((msg.toolName == 'Task' || msg.toolName == 'Agent') && msg.toolUseId != null &&
            widget.subagentTasks.containsKey(msg.toolUseId)) {
          final toolUseId = msg.toolUseId!;
          _taskKeys.putIfAbsent(toolUseId, () => GlobalKey());
          final isRunning = widget.subagentTasks[toolUseId]?['status'] == 'running';
          final children = widget.allMessages
              .where((m) => m.parentToolUseId == toolUseId)
              .toList();
          return SubAgentCard(
            message: msg,
            childMessages: children,
            isRunning: isRunning,
            scrollKey: _taskKeys[toolUseId],
          );
        }
        // Backgrounded bash — register key for scroll-to
        if (msg.isBackgrounded && msg.toolUseId != null) {
          _taskKeys.putIfAbsent(msg.toolUseId!, () => GlobalKey());
          return Container(
            key: _taskKeys[msg.toolUseId!],
            child: ToolOutputBlock(message: msg),
          );
        }
        return ToolOutputBlock(message: msg);
      case MessageType.toolResult:
        return ToolOutputBlock(message: msg);
      case MessageType.question:
        if (msg.emailPreview != null) {
          return EmailPreviewCard(
            message: msg,
            onAnswer: widget.onAnswer,
          );
        }
        return QuestionCard(
          message: msg,
          onAnswer: widget.onAnswer,
        );
      case MessageType.result:
        return MessageBubble(message: msg);
      case MessageType.error:
        return _buildErrorWidget(msg);
      case MessageType.taskNotification:
        return _buildTaskNotification(msg);
      case MessageType.compactBoundary:
        return _buildCompactBoundaryDivider(msg);
      case MessageType.outlookAuth:
        return OutlookAuthCard(
          message: msg,
          onAnswer: widget.onAnswer,
        );
      case MessageType.ibsAuth:
        return IBSAuthCard(
          message: msg,
          onAnswer: widget.onAnswer,
        );
      case MessageType.claudeAuth:
        return ClaudeAuthCard(message: msg);
      case MessageType.toolSummary:
        return _buildToolSummary(msg);
      case MessageType.thinking:
        return ThinkingCard(message: msg);
    }
  }

  Widget _buildLoadMoreButton(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: widget.isLoadingMore
            ? const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : TextButton.icon(
                onPressed: widget.onLoadMore,
                icon: const Icon(Icons.expand_less, size: 18),
                label: const Text('Load earlier messages'),
                style: TextButton.styleFrom(
                  foregroundColor: Theme.of(context).colorScheme.primary,
                  textStyle: const TextStyle(fontSize: 13),
                ),
              ),
      ),
    );
  }

  Widget _buildThinkingIndicator(BuildContext context) {
    final theme = Theme.of(context);

    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(left: 8, right: 64, top: 4, bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(16),
            topRight: Radius.circular(16),
            bottomLeft: Radius.circular(4),
            bottomRight: Radius.circular(16),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(width: 10),
            Text(
              'Working...',
              style: TextStyle(
                color: theme.colorScheme.onSurface.withAlpha(178),
                fontSize: 14,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTaskNotification(ChatMessage msg) {
    final status = msg.toolName ?? 'unknown'; // status stored in toolName
    final isSuccess = status == 'completed' || status == 'success';
    final isFailed = status == 'failed';
    final isCancelled = status == 'cancelled';
    final isUploaded = status == 'uploaded';
    final isTodoUpdate = status == 'todos_updated';

    // Todo updates get a dedicated card
    if (isTodoUpdate) {
      return _buildTodoUpdateCard(msg);
    }

    final IconData icon;
    final Color color;
    final Color bgColor;

    if (isCancelled) {
      icon = Icons.cancel_outlined;
      color = Colors.red.shade300;
      bgColor = Colors.red.shade900.withAlpha(40);
    } else if (isUploaded) {
      icon = Icons.upload_file;
      color = Colors.teal.shade300;
      bgColor = Colors.teal.shade900.withAlpha(40);
    } else if (isSuccess) {
      icon = Icons.check_circle_outline;
      color = Colors.green.shade300;
      bgColor = Colors.green.shade900.withAlpha(50);
    } else if (isFailed) {
      icon = Icons.error_outline;
      color = Colors.orange.shade300;
      bgColor = Colors.orange.shade900.withAlpha(50);
    } else {
      icon = Icons.info_outline;
      color = Colors.blue.shade300;
      bgColor = Colors.blue.shade900.withAlpha(50);
    }

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withAlpha(60)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              msg.textContent,
              style: TextStyle(color: color, fontSize: 12),
            ),
          ),
          if (widget.onStopTask != null &&
              !['completed', 'failed', 'stopped', 'cancelled', 'uploaded', 'success'].contains(status) &&
              msg.toolUseId != null && msg.toolUseId!.isNotEmpty)
            IconButton(
              onPressed: () {
                widget.onStopTask!(msg.toolUseId!);
              },
              icon: Icon(Icons.stop_circle_outlined, size: 18, color: Colors.red.shade300),
              padding: const EdgeInsets.only(right: 8),
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              splashRadius: 16,
            ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: color.withAlpha(30),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              status.toUpperCase(),
              style: TextStyle(
                color: color,
                fontSize: 10,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTodoUpdateCard(ChatMessage msg) {
    return _TodoUpdateCard(msg: msg);
  }

  Widget _buildCompactBoundaryDivider(ChatMessage msg) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.tertiary;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
      child: Row(
        children: [
          Expanded(child: Divider(color: color.withAlpha(80))),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.compress, size: 14, color: color),
                const SizedBox(width: 4),
                Text(
                  msg.textContent,
                  style: TextStyle(fontSize: 11, color: color),
                ),
              ],
            ),
          ),
          Expanded(child: Divider(color: color.withAlpha(80))),
        ],
      ),
    );
  }

  Widget _buildToolSummary(ChatMessage msg) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E2E),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF45475A)),
      ),
      child: Row(
        children: [
          const Icon(Icons.summarize, size: 14, color: Color(0xFF89B4FA)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              msg.textContent,
              style: const TextStyle(fontSize: 12, color: Color(0xFFA6ADC8)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRawView(BuildContext context) {
    final items = widget.rawItems;
    if (items.isEmpty) {
      return Center(
        child: Text(
          'No SDK events yet.\nSend a message to see the raw stream.',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Theme.of(context).colorScheme.outline,
            fontSize: 14,
          ),
        ),
      );
    }

    return Listener(
      onPointerDown: (_) => _userTouching = true,
      onPointerUp: (_) => _userTouching = false,
      onPointerCancel: (_) => _userTouching = false,
      child: ListView.builder(
        controller: _scrollController,
        padding: const EdgeInsets.only(top: 4, bottom: 8),
        itemCount: items.length,
        itemBuilder: (context, index) => RawEventCard(item: items[index]),
      ),
    );
  }

  Widget _buildErrorWidget(ChatMessage msg) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.red.shade900.withAlpha(76),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.red.shade300.withAlpha(76)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(Icons.error_outline, size: 18, color: Colors.red.shade300),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _buildErrorText(msg.textContent),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorText(String text) {
    final urlPattern = RegExp(r'https?://\S+');
    final style = TextStyle(color: Colors.red.shade200, fontSize: 13);
    final linkStyle = TextStyle(color: Colors.blue.shade300, fontSize: 13, decoration: TextDecoration.underline);
    final matches = urlPattern.allMatches(text).toList();
    if (matches.isEmpty) return Text(text, style: style);

    final spans = <TextSpan>[];
    int last = 0;
    for (final m in matches) {
      if (m.start > last) spans.add(TextSpan(text: text.substring(last, m.start)));
      final url = m.group(0)!;
      spans.add(TextSpan(
        text: 'Open login page',
        style: linkStyle,
        recognizer: TapGestureRecognizer()..onTap = () => launchUrl(Uri.parse(url)),
      ));
      last = m.end;
    }
    if (last < text.length) spans.add(TextSpan(text: text.substring(last)));
    return RichText(text: TextSpan(style: style, children: spans));
  }
}

class _TodoUpdateCard extends StatefulWidget {
  final ChatMessage msg;
  const _TodoUpdateCard({required this.msg});

  @override
  State<_TodoUpdateCard> createState() => _TodoUpdateCardState();
}

class _TodoUpdateCardState extends State<_TodoUpdateCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final lines = widget.msg.textContent.split('\n').where((l) => l.isNotEmpty).toList();
    const baseColor = Color(0xFF89B4FA);

    return GestureDetector(
      onTap: () => setState(() => _expanded = !_expanded),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFF1E1E2E),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: baseColor.withAlpha(40)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.checklist, size: 14, color: baseColor),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Tasks Modified',
                    style: TextStyle(
                      color: baseColor,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Icon(
                  _expanded ? Icons.expand_less : Icons.expand_more,
                  size: 16,
                  color: const Color(0xFF6C7086),
                ),
              ],
            ),
            if (_expanded) ...[
              const SizedBox(height: 6),
              ...lines.map((line) {
                final Color lineColor;
                final IconData lineIcon;
                if (line.startsWith('\u2713 ')) {
                  lineColor = Colors.green.shade300;
                  lineIcon = Icons.check_circle;
                } else if (line.startsWith('\u25b6 ')) {
                  lineColor = Colors.yellow.shade300;
                  lineIcon = Icons.play_circle_fill;
                } else if (line.startsWith('+ ')) {
                  lineColor = const Color(0xFFA6ADC8);
                  lineIcon = Icons.radio_button_unchecked;
                } else if (line.startsWith('- ')) {
                  lineColor = Colors.red.shade300;
                  lineIcon = Icons.remove_circle_outline;
                } else if (line.startsWith('\u25cb ')) {
                  lineColor = const Color(0xFF585B70);
                  lineIcon = Icons.radio_button_unchecked;
                } else {
                  lineColor = const Color(0xFFA6ADC8);
                  lineIcon = Icons.info_outline;
                }

                final hasPrefix = line.startsWith('\u2713 ') || line.startsWith('\u25b6 ') || line.startsWith('+ ') || line.startsWith('- ') || line.startsWith('\u25cb ');
                final text = hasPrefix ? line.substring(2) : line;
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Icon(lineIcon, size: 13, color: lineColor),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          text,
                          style: TextStyle(
                            color: lineColor,
                            fontSize: 12,
                            decoration: line.startsWith('\u2713 ') ? TextDecoration.lineThrough : null,
                            decorationColor: lineColor.withAlpha(120),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              }),
            ],
          ],
        ),
      ),
    );
  }
}
