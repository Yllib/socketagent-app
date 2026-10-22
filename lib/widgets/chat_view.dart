import 'dart:async';
import 'resume_context_card.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import '../models/message.dart';
import '../models/ai_response_report.dart';
import '../models/traced_error.dart';
import '../models/condensed_chat_rows.dart';
import '../models/message_reconciliation.dart';
import '../models/raw_event.dart';
import '../services/socketagent_link_router.dart';
import '../util/format.dart';
import 'error_trace_row.dart';
import 'message_bubble.dart';
import 'message_timestamp.dart';
import 'tool_output_block.dart';
import 'speak_card.dart';
import 'file_card.dart';
import 'question_card.dart';
import 'refusal_card.dart';
import 'email_preview_card.dart';
import 'todo_list_card.dart';
import 'reminder_card.dart';
import 'outlook_auth_card.dart';
import 'ibs_auth_card.dart';
import 'claude_auth_card.dart';
import 'backend_auth_card.dart';
import 'raw_event_card.dart';
import 'subagent_card.dart';
import 'thinking_card.dart';
import 'elicitation_card.dart';
import 'monitor_card.dart';
import 'monitor_tool_card.dart';
import 'codex_plan_card.dart';
import 'codex_command_card.dart';
import 'secure_input_card.dart';
import 'computer_access_card.dart';
import 'html_plan_card.dart';
import 'work_review_card.dart';
import 'browser_session_card.dart';
import 'workflow_card.dart';
import 'codex_activity_card.dart';
import 'notification_receipt_card.dart';
import 'socketagent_tool_card.dart';
import '../models/composer_attachment.dart';
import '../config/app_palette.dart';
import 'light_backdrop.dart';
import 'second_ticker.dart';
import 'chat_scroll_controller.dart';
import 'chat_scrollbar.dart';

class ChatView extends StatefulWidget {
  final List<ChatMessage> messages;
  final String? sessionStorageKey;
  final String? serverId;
  final bool isProcessing;

  /// The agent is idle while agents it delegated to keep working.
  final bool isWaitingOnAgent;
  final bool followLatest;
  final bool condensedToolUsage;
  final ValueChanged<bool>? onFollowLatestChanged;
  final DateTime? processingStartedAt;
  final bool isCompacting;
  final bool isLoadingHistory;
  final bool isLoadingMore;
  final bool hasMoreHistory;

  /// History entries before the oldest loaded one. The scrollbar counts them
  /// as track above the loaded rows, so the thumb covers the conversation.
  final int olderHistoryCount;
  final int historyWindowRevision;
  final String? targetEntryId;
  final int? targetSessionSeq;

  /// Scrolls to this message, like [targetEntryId], for find in chat.
  final String? targetMessageId;

  /// Tints the row showing this message: the current find match.
  final String? highlightMessageId;
  final VoidCallback? onTranscriptTargetReached;
  final List<Map<String, dynamic>> todos;
  final void Function(String questionId, Map<String, String> answers) onAnswer;
  final void Function(String requestId, String value) onSecureInputSubmit;
  final void Function(String requestId, SecretMetadata secret)
  onSecureInputUseStored;
  final void Function(String requestId) onSecureInputCancel;
  final List<SecretMetadata> availableSecrets;
  final VoidCallback? onLoadMore;
  final void Function(String taskId)? onStopTask;

  /// Moves a running Bash command or subagent to the background by tool use
  /// id. Null when the session's server cannot.
  final ValueChanged<String>? onBackgroundTask;
  final VoidCallback? onDismissTodos;
  final bool showCodexPlan;
  final bool codexRewind;
  final bool showTodos;
  final Widget? tasksHidingNotice;
  final Widget? codexPlanHidingNotice;
  final VoidCallback? onDismissCodexPlan;
  final void Function(List<String> keys)? onDismissTasks;
  final void Function(String uuid, {bool rewindFiles})? onRewindConversation;
  final void Function(String uuid)? onBranch;
  final void Function(String messageId)? onRetractQueuedMessage;
  final ValueChanged<String>? onReadAloud;
  final Future<String?> Function(
    ChatMessage message,
    AiResponseReportCategory category,
  )?
  onReportAiResponse;

  /// Sends a traced error to SocketAgent after the user confirms.
  final Future<String?> Function(TracedError trace)? onReportError;
  final bool rawMode;
  final List<SdkItem> rawItems;
  // For SubAgentCard: tracked subagent tasks and full message list for child lookup
  final Map<String, Map<String, dynamic>> subagentTasks;
  final Map<String, Map<String, dynamic>> workflowTasks;
  final List<ChatMessage> allMessages;

  const ChatView({
    super.key,
    required this.messages,
    this.sessionStorageKey,
    this.serverId,
    required this.isProcessing,
    this.isWaitingOnAgent = false,
    this.followLatest = true,
    this.condensedToolUsage = false,
    this.onFollowLatestChanged,
    this.processingStartedAt,
    this.isCompacting = false,
    this.isLoadingHistory = false,
    this.isLoadingMore = false,
    this.hasMoreHistory = false,
    this.olderHistoryCount = 0,
    this.historyWindowRevision = 0,
    this.targetEntryId,
    this.targetSessionSeq,
    this.targetMessageId,
    this.highlightMessageId,
    this.onTranscriptTargetReached,
    required this.todos,
    required this.onAnswer,
    required this.onSecureInputSubmit,
    required this.onSecureInputUseStored,
    required this.onSecureInputCancel,
    this.availableSecrets = const [],
    this.onLoadMore,
    this.onStopTask,
    this.onBackgroundTask,
    this.onDismissTodos,
    this.showCodexPlan = true,
    this.codexRewind = false,
    this.showTodos = true,
    this.tasksHidingNotice,
    this.codexPlanHidingNotice,
    this.onDismissCodexPlan,
    this.onDismissTasks,
    this.onRewindConversation,
    this.onBranch,
    this.onRetractQueuedMessage,
    this.onReadAloud,
    this.onReportAiResponse,
    this.onReportError,
    this.rawMode = false,
    this.rawItems = const [],
    this.subagentTasks = const {},
    this.workflowTasks = const {},
    this.allMessages = const [],
  });

  @override
  State<ChatView> createState() => ChatViewState();
}

typedef _RenderRow = ({CondensedChatRow content, String rowKey});

/// The expanded tool group whose header has scrolled above the viewport while
/// the rest of the group is still on screen.
class _PinnedCondensedGroup {
  const _PinnedCondensedGroup({required this.rowKey, required this.row});

  final String rowKey;
  final CondensedWorkRow row;

  @override
  bool operator ==(Object other) =>
      other is _PinnedCondensedGroup &&
      other.rowKey == rowKey &&
      identical(other.row, row);

  @override
  int get hashCode => Object.hash(rowKey, identityHashCode(row));
}

class ChatViewState extends State<ChatView> with WidgetsBindingObserver {
  late final ChatScrollController _scroll;
  final Set<String> _expandedImageCardIds = {};
  final Map<String, Set<String>> _expandedCondensedRowsBySession = {};
  final _pinnedCondensedGroup = ValueNotifier<_PinnedCondensedGroup?>(null);
  final _pinnedCondensedHeaderKey = GlobalKey();
  final Map<String, GlobalKey> _messageRowKeys = {};
  final Map<String, GlobalKey> _taskKeys = {};
  final Map<String, String> _taskRowKeyByToolUseId = {};
  Map<String, ChatMessage> _toolCallsById = {};
  Map<String, List<ChatMessage>> _childMessagesByParent = {};
  int _indexedAllMessageCount = -1;
  ChatMessage? _indexedFirstMessage;
  ChatMessage? _indexedLastMessage;
  int _indexedHistoryWindowRevision = -1;
  String? _indexedSessionStorageKey;
  int _transcriptTargetGeneration = 0;
  int _transcriptTargetSeekAttempts = 0;
  String? _lastTranscriptTargetIdentity;

  /// Row that starts the forward-growing sliver. Rows before it render in a
  /// sliver that grows upward, so older pages never move the viewport.
  String? _centerRowKey;
  Set<String> _windowRowKeys = const {};
  int _centerGeneration = 0;

  /// True from asking for an older page until that page has been laid out.
  bool _olderHistoryRequested = false;
  bool _olderHistoryCheckScheduled = false;

  /// Row over the whole conversation the scrollbar thumb is being dragged
  /// to, while it is held.
  double? _thumbSeekRow;

  static const _centerSliverKey = ValueKey<String>('chat-window-center');

  bool get _hasTranscriptTarget =>
      (widget.targetEntryId?.isNotEmpty ?? false) ||
      (widget.targetMessageId?.isNotEmpty ?? false) ||
      (widget.targetSessionSeq != null && widget.targetSessionSeq! > 0);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scroll = ChatScrollController(following: widget.followLatest);
    _scroll.followingListenable.addListener(_onFollowingChanged);
    _scroll.addListener(_onScroll);
    if (_hasTranscriptTarget) _scroll.hold();
    _reindexAllMessages(force: true);
    _scheduleTranscriptTargetSeek();
    _scheduleOlderHistoryCheck();
  }

  void _reindexAllMessages({bool force = false}) {
    final first = widget.allMessages.firstOrNull;
    final last = widget.allMessages.lastOrNull;
    if (!force &&
        _indexedAllMessageCount == widget.allMessages.length &&
        identical(_indexedFirstMessage, first) &&
        identical(_indexedLastMessage, last) &&
        _indexedHistoryWindowRevision == widget.historyWindowRevision &&
        _indexedSessionStorageKey == widget.sessionStorageKey) {
      return;
    }
    final toolCallsById = <String, ChatMessage>{};
    final childMessagesByParent = <String, List<ChatMessage>>{};
    for (final message in widget.allMessages) {
      final toolUseId = message.toolUseId;
      if (message.type == MessageType.toolCall &&
          toolUseId != null &&
          toolUseId.isNotEmpty) {
        toolCallsById[toolUseId] = message;
      }
      final parentToolUseId = message.parentToolUseId;
      if (parentToolUseId != null && parentToolUseId.isNotEmpty) {
        (childMessagesByParent[parentToolUseId] ??= []).add(message);
      }
    }
    _toolCallsById = toolCallsById;
    _childMessagesByParent = childMessagesByParent;
    _indexedAllMessageCount = widget.allMessages.length;
    _indexedFirstMessage = first;
    _indexedLastMessage = last;
    _indexedHistoryWindowRevision = widget.historyWindowRevision;
    _indexedSessionStorageKey = widget.sessionStorageKey;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _releaseScrollInteractionAfterLifecycle();
      return;
    }

    // Android can pause Flutter in the middle of ScrollController.animateTo.
    // DrivenScrollActivity intentionally ignores every pointer in its
    // Scrollable subtree, including buttons in chat cards. Force the retained
    // scroll position idle again when its route resumes.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _releaseScrollInteractionAfterLifecycle();
    });
  }

  void _releaseScrollInteractionAfterLifecycle() {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    // Same offset, so the mode is untouched; only the activity is replaced.
    _scroll.jumpTo(
      position.pixels
          .clamp(position.minScrollExtent, position.maxScrollExtent)
          .toDouble(),
    );
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    _scheduleOlderHistoryCheck();
    _updatePinnedCondensedGroup();
  }

  /// Vertical margin of a condensed work card, so the pinned header and the
  /// revealed collapsed card share the same top edge.
  static const double _condensedCardMargin = 4;

  /// Scroll offset at which [box]'s leading edge meets the top of the chat
  /// viewport, or null when the row is not laid out inside it.
  double? _revealOffsetFor(RenderBox box) {
    if (!box.attached || !box.hasSize) return null;
    final viewport = RenderAbstractViewport.maybeOf(box);
    if (viewport == null) return null;
    return viewport.getOffsetToReveal(box, 0).offset;
  }

  /// Recomputes which expanded tool group, if any, needs a pinned header. Runs
  /// on every scroll frame but only touches the few rows the user expanded,
  /// and only the pinned header rebuilds when the answer changes.
  void _updatePinnedCondensedGroup() {
    final expanded = widget.condensedToolUsage
        ? _expandedCondensedRowsBySession[widget.sessionStorageKey ?? '']
        : null;
    if (expanded == null || expanded.isEmpty || !_scroll.hasClients) {
      _pinnedCondensedGroup.value = null;
      return;
    }
    final pixels = _scroll.position.pixels;
    final headerBox = _pinnedCondensedHeaderKey.currentContext
        ?.findRenderObject();
    final headerHeight = headerBox is RenderBox && headerBox.hasSize
        ? headerBox.size.height
        : 56.0;
    String? pinnedKey;
    for (final rowKey in expanded) {
      final box = _messageRowKeys[rowKey]?.currentContext?.findRenderObject();
      if (box is! RenderBox) continue;
      final reveal = _revealOffsetFor(box);
      if (reveal == null) continue;
      // The row box includes the card's vertical margins; measure the card.
      final top = reveal - pixels + _condensedCardMargin;
      final bottom = reveal - pixels + box.size.height - _condensedCardMargin;
      if (top < 0 && bottom > headerHeight) {
        pinnedKey = rowKey;
        break;
      }
    }
    final current = _pinnedCondensedGroup.value;
    if (pinnedKey == null) {
      _pinnedCondensedGroup.value = null;
      return;
    }
    final row = _lastRenderedRows
        .where((candidate) => candidate.rowKey == pinnedKey)
        .firstOrNull
        ?.content;
    if (row is! CondensedWorkRow) {
      _pinnedCondensedGroup.value = null;
      return;
    }
    if (current?.rowKey == pinnedKey && identical(current?.row, row)) return;
    _pinnedCondensedGroup.value = _PinnedCondensedGroup(
      rowKey: pinnedKey,
      row: row,
    );
  }

  void _toggleCondensedGroup(String rowKey) {
    final expanded = _expandedCondensedRows;
    setState(() {
      if (!expanded.remove(rowKey)) expanded.add(rowKey);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _updatePinnedCondensedGroup();
    });
  }

  /// Collapses an expanded tool group from its pinned header and leaves the
  /// collapsed card at the top of the viewport, where the header was. The
  /// offset is corrected during the same layout pass that shrinks the group,
  /// so the reader never sees the rows that used to sit below it.
  void _collapseCondensedGroupFromPinnedHeader(String rowKey) {
    final box = _messageRowKeys[rowKey]?.currentContext?.findRenderObject();
    if (box is RenderBox) {
      _scroll.revealAfterLayout(box, inset: _condensedCardMargin);
    }
    _pinnedCondensedGroup.value = null;
    _toggleCondensedGroup(rowKey);
  }

  /// Scroll to a task card in the chat by its toolUseId
  void scrollToTask(String toolUseId) {
    final rowKey = _taskRowKeyByToolUseId[toolUseId];
    final key = rowKey == null ? null : _taskKeys[rowKey];
    if (key?.currentContext != null) {
      Scrollable.ensureVisible(
        key!.currentContext!,
        alignment: 0.3,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
      return;
    }
    if (!widget.condensedToolUsage) return;
    final row = _renderRows().where((candidate) {
      final content = candidate.content;
      return content is CondensedWorkRow &&
          content.messages.any((message) => message.toolUseId == toolUseId);
    }).firstOrNull;
    if (row == null || row.content is! CondensedWorkRow) return;
    _expandedCondensedRows.add(row.rowKey);
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final context = _messageRowKeys[row.rowKey]?.currentContext;
      if (context != null) {
        Scrollable.ensureVisible(
          context,
          alignment: 0.25,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Set<String> get _expandedCondensedRows => _expandedCondensedRowsBySession
      .putIfAbsent(widget.sessionStorageKey ?? '', () => <String>{});

  bool _rowMatchesTranscriptTarget(CondensedChatRow row) {
    if (row case CondensedVisibleRow(:final message)) {
      return _matchesTranscriptTarget(message);
    }
    if (row case CondensedWorkRow(:final messages)) {
      return messages.any(_matchesTranscriptTarget);
    }
    return false;
  }

  String _transcriptTargetIdentity() =>
      '${widget.sessionStorageKey ?? ''}\u0001'
      '${widget.targetEntryId ?? ''}\u0001'
      '${widget.targetMessageId ?? ''}\u0001'
      '${widget.targetSessionSeq ?? ''}';

  bool _matchesTranscriptTarget(ChatMessage message) {
    final messageId = widget.targetMessageId;
    if (messageId != null && messageId.isNotEmpty && message.id == messageId) {
      return true;
    }
    final entryId = widget.targetEntryId;
    if (entryId != null && entryId.isNotEmpty && message.entryId == entryId) {
      return true;
    }
    final sessionSeq = widget.targetSessionSeq;
    return sessionSeq != null &&
        sessionSeq > 0 &&
        message.sessionSeq == sessionSeq;
  }

  void _scheduleTranscriptTargetSeek() {
    if (!_hasTranscriptTarget ||
        widget.isLoadingHistory ||
        widget.isLoadingMore) {
      return;
    }
    final identity = _transcriptTargetIdentity();
    if (_lastTranscriptTargetIdentity != identity) {
      _lastTranscriptTargetIdentity = identity;
      _transcriptTargetSeekAttempts = 0;
    }
    final generation = ++_transcriptTargetGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          generation != _transcriptTargetGeneration ||
          !_hasTranscriptTarget ||
          widget.isLoadingHistory ||
          widget.isLoadingMore) {
        return;
      }
      final rows = _renderRows();
      final messageIndex = rows.indexWhere(
        (row) => _rowMatchesTranscriptTarget(row.content),
      );
      if (messageIndex < 0) {
        // Page backwards until the target row is loaded. The seek runs
        // again when each page lands.
        if (!_requestOlderHistory() && !widget.hasMoreHistory) {
          widget.onTranscriptTargetReached?.call();
        }
        return;
      }
      _seekMountedTranscriptRow(
        rowKey: rows[messageIndex].rowKey,
        targetListIndex: messageIndex,
        listItemCount: rows.length + (_showsStatusRow ? 1 : 0),
        generation: generation,
      );
    });
  }

  void _seekMountedTranscriptRow({
    required String rowKey,
    required int targetListIndex,
    required int listItemCount,
    required int generation,
  }) {
    if (!mounted ||
        generation != _transcriptTargetGeneration ||
        !_hasTranscriptTarget) {
      return;
    }
    final context = _messageRowKeys[rowKey]?.currentContext;
    if (context != null) {
      Scrollable.ensureVisible(
        context,
        alignment: 0.3,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      ).whenComplete(() {
        if (mounted && generation == _transcriptTargetGeneration) {
          widget.onTranscriptTargetReached?.call();
        }
      });
      return;
    }
    if (!_scroll.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _seekMountedTranscriptRow(
          rowKey: rowKey,
          targetListIndex: targetListIndex,
          listItemCount: listItemCount,
          generation: generation,
        );
      });
      return;
    }

    // The row is not built yet. Jump to where the mounted rows suggest it
    // is and try again next frame, until it mounts or attempts run out.
    _transcriptTargetSeekAttempts++;
    final position = _scroll.position;
    final rows = _renderRows();
    final listIndexByRowKey = <String, int>{
      for (var index = 0; index < rows.length; index++)
        rows[index].rowKey: index,
    };
    final mountedRows = <({int listIndex, double top})>[];
    for (final entry in _messageRowKeys.entries) {
      final listIndex = listIndexByRowKey[entry.key];
      final box = entry.value.currentContext?.findRenderObject() as RenderBox?;
      if (listIndex == null || box == null || !box.hasSize) continue;
      mountedRows.add((
        listIndex: listIndex,
        top: box.localToGlobal(Offset.zero).dy,
      ));
    }

    double targetPixels;
    if (mountedRows.isNotEmpty) {
      mountedRows.sort(
        (left, right) => left.listIndex.compareTo(right.listIndex),
      );
      var averageExtent =
          position.viewportDimension / mountedRows.length.clamp(1, 8);
      if (mountedRows.length >= 2) {
        final first = mountedRows.first;
        final last = mountedRows.last;
        final indexSpan = (last.listIndex - first.listIndex).abs();
        if (indexSpan > 0) {
          averageExtent = (last.top - first.top).abs() / indexSpan;
        }
      }
      averageExtent = averageExtent.clamp(36.0, 420.0);
      final nearest = mountedRows.reduce(
        (left, right) =>
            (left.listIndex - targetListIndex).abs() <=
                (right.listIndex - targetListIndex).abs()
            ? left
            : right,
      );
      targetPixels =
          position.pixels +
          (targetListIndex - nearest.listIndex) * averageExtent;
    } else {
      final denominator = (listItemCount - 1).clamp(1, 1 << 30);
      targetPixels =
          position.minScrollExtent +
          (position.maxScrollExtent - position.minScrollExtent) *
              targetListIndex /
              denominator;
    }
    position.jumpTo(
      targetPixels
          .clamp(position.minScrollExtent, position.maxScrollExtent)
          .toDouble(),
    );

    if (_transcriptTargetSeekAttempts <= 10) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _seekMountedTranscriptRow(
          rowKey: rowKey,
          targetListIndex: targetListIndex,
          listItemCount: listItemCount,
          generation: generation,
        );
      });
    }
  }

  final _rowCache = CondensedChatRowsCache();
  List<CondensedChatRow>? _lastCondensedRows;
  List<({CondensedChatRow content, String rowKey})> _lastRenderedRows = [];
  List<({CondensedChatRow content, String rowKey})>? _rowsForWidget;

  List<({CondensedChatRow content, String rowKey})> _renderRows() {
    final ready = _rowsForWidget;
    if (ready != null) return ready;
    final rows = _rowCache.render(
      widget.messages.where((message) => message.type != MessageType.codexPlan),
      messageKey: _messageRowKey,
      enabled: widget.condensedToolUsage,
      isProcessing: widget.isProcessing,
    );
    if (!identical(rows, _lastCondensedRows)) {
      final occurrences = <String, int>{};
      _lastCondensedRows = rows;
      _lastRenderedRows = [
        for (final row in rows)
          (
            content: row,
            rowKey: _collisionSafeRowKey(row.keySeed, occurrences),
          ),
      ];
    }
    return _rowsForWidget = _lastRenderedRows;
  }

  String _collisionSafeRowKey(String base, Map<String, int> occurrences) {
    final occurrence = occurrences.update(
      base,
      (current) => current + 1,
      ifAbsent: () => 0,
    );
    return occurrence == 0 ? base : '$base#duplicate:$occurrence';
  }

  /// Splits the rows at the center row. Rows before it render, newest first,
  /// in a sliver that grows upward, so an older page lands above the viewport
  /// without moving anything inside it.
  ({List<_RenderRow> older, List<_RenderRow> window}) _splitRows(
    List<_RenderRow> rows,
  ) {
    final centerKey = _centerRowKey;
    var centerIndex = centerKey == null
        ? -1
        : rows.indexWhere((row) => row.rowKey == centerKey);
    if (centerIndex < 0) {
      // The center row is gone. Rows still mounted in the window sliver keep
      // their layout when the center moves to the earliest survivor. With no
      // survivor, both slivers start over.
      centerIndex = rows.indexWhere(
        (row) => _windowRowKeys.contains(row.rowKey),
      );
      if (centerIndex < 0) {
        centerIndex = 0;
        if (_windowRowKeys.isNotEmpty) _centerGeneration++;
      }
      _centerRowKey = rows.isEmpty ? null : rows[centerIndex].rowKey;
    }
    final window = rows.sublist(centerIndex);
    _windowRowKeys = {for (final row in window) row.rowKey};
    return (
      older: rows.sublist(0, centerIndex).reversed.toList(),
      window: window,
    );
  }

  @override
  void didUpdateWidget(ChatView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _rowsForWidget = null;
    _reindexAllMessages();

    final sessionChanged =
        widget.sessionStorageKey != oldWidget.sessionStorageKey;
    if (sessionChanged) {
      // The scroll view is keyed by session, so a fresh viewport is coming.
      _centerRowKey = null;
      _windowRowKeys = const {};
      _centerGeneration++;
      _olderHistoryRequested = false;
      _expandedImageCardIds.clear();
      _messageRowKeys.clear();
      _taskKeys.clear();
      _taskRowKeyByToolUseId.clear();
      // Not synchronously: this runs during build and the pinned header's
      // ValueListenableBuilder may not rebuild from inside it.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _updatePinnedCondensedGroup();
      });
      if (widget.followLatest && !_hasTranscriptTarget) {
        _scroll.follow();
      } else {
        _scroll.hold();
      }
    } else if (widget.followLatest != oldWidget.followLatest) {
      // Only transitions matter. Between them the controller owns the mode,
      // and the parent's value is a mirror of it.
      if (widget.followLatest) {
        _scroll.follow();
      } else {
        _scroll.hold();
      }
    }

    final targetIdentity = _transcriptTargetIdentity();
    if (_lastTranscriptTargetIdentity != targetIdentity) {
      _lastTranscriptTargetIdentity = targetIdentity;
      _transcriptTargetSeekAttempts = 0;
      _transcriptTargetGeneration++;
      if (_hasTranscriptTarget) _scroll.hold();
    }
    if (oldWidget.isLoadingMore && !widget.isLoadingMore) {
      // The page is part of this frame's layout; the post-frame check
      // below measures the distance only after it has been placed.
      _olderHistoryRequested = false;
      if (_thumbSeekRow != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _thumbSeekRow != null) _seekRow(_thumbSeekRow!);
        });
      }
    }

    final activeRowKeys = {for (final row in _renderRows()) row.rowKey};
    _messageRowKeys.removeWhere((rowKey, _) => !activeRowKeys.contains(rowKey));
    _taskKeys.removeWhere((rowKey, _) => !activeRowKeys.contains(rowKey));
    _taskRowKeyByToolUseId.removeWhere(
      (_, rowKey) => !activeRowKeys.contains(rowKey),
    );

    _scheduleOlderHistoryCheck();
    if (_hasTranscriptTarget) _scheduleTranscriptTargetSeek();
  }

  void _scheduleOlderHistoryCheck() {
    if (_olderHistoryCheckScheduled) return;
    _olderHistoryCheckScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _olderHistoryCheckScheduled = false;
      if (mounted) _requestOlderHistoryIfNearTop();
    });
  }

  /// Asks for the previous page while the top of the loaded history is
  /// within 1.25 viewports of the reader. This also fills a window shorter
  /// than the viewport. It runs after layout, so a page that just landed has
  /// been placed before the distance is measured.
  void _requestOlderHistoryIfNearTop() {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    if (!position.hasContentDimensions) return;
    final distanceFromOldestLoaded = position.pixels - position.minScrollExtent;
    if (distanceFromOldestLoaded > position.viewportDimension * 1.25) return;
    _requestOlderHistory();
  }

  /// The thumb is over [row], counted over the whole conversation. A row in
  /// loaded history is scrolled to; one above it means the top of what is
  /// loaded plus another page, and the thumb keeps asking as pages land.
  void _seekRow(double row) {
    _thumbSeekRow = row;
    final loadedRow = row - widget.olderHistoryCount;
    if (loadedRow >= 0) {
      _scroll.scrollToRow(loadedRow);
      return;
    }
    _scroll.endRowScroll();
    if (_scroll.hasClients) {
      final position = _scroll.position;
      if (position.hasContentDimensions &&
          position.pixels != position.minScrollExtent) {
        position.jumpTo(position.minScrollExtent);
      }
    }
    _requestOlderHistory();
  }

  void _endSeekRow() {
    _thumbSeekRow = null;
    _scroll.endRowScroll();
  }

  /// One older page at a time: never while a page is loading, and never
  /// again until the page that was asked for has been laid out.
  bool _requestOlderHistory() {
    if (_olderHistoryRequested ||
        widget.isLoadingMore ||
        widget.isLoadingHistory ||
        !widget.hasMoreHistory ||
        widget.onLoadMore == null) {
      return false;
    }
    _olderHistoryRequested = true;
    widget.onLoadMore!();
    return true;
  }

  void _handleToolExpansionChanged(
    String messageId,
    bool expanded, {
    required bool hasImage,
  }) {
    if (!hasImage) return;
    final changed = expanded
        ? _expandedImageCardIds.add(messageId)
        : _expandedImageCardIds.remove(messageId);
    if (changed && mounted) setState(() {});
  }

  Widget _buildToolOutputBlock(
    ChatMessage msg, {
    bool greenTheme = false,
    String? inspectionId,
  }) {
    final id = inspectionId ?? msg.id;
    return ToolOutputBlock(
      message: msg,
      greenTheme: greenTheme,
      expanded: _expandedImageCardIds.contains(id) ? true : null,
      onExpansionChanged: (expanded, {required hasImage}) =>
          _handleToolExpansionChanged(id, expanded, hasImage: hasImage),
      onBackgroundTask: widget.onBackgroundTask,
    );
  }

  /// Mirrors the controller's mode to the parent. Deferred because the mode
  /// can change inside layout, where the parent cannot set state.
  void _onFollowingChanged() {
    final following = _scroll.following;
    if (following == widget.followLatest) return;
    scheduleMicrotask(() {
      if (!mounted ||
          _scroll.following != following ||
          widget.followLatest == following) {
        return;
      }
      widget.onFollowLatestChanged?.call(following);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scroll.removeListener(_onScroll);
    _scroll.followingListenable.removeListener(_onFollowingChanged);
    _scroll.dispose();
    _pinnedCondensedGroup.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final chatSurfaceColor = Theme.of(context).colorScheme.surface;
    if (widget.isLoadingHistory && widget.messages.isEmpty) {
      return ColoredBox(
        key: const ValueKey('chat-surface'),
        color: chatSurfaceColor,
        child: const Center(child: CircularProgressIndicator()),
      );
    }

    if (widget.rawMode) {
      return ColoredBox(
        key: const ValueKey('chat-surface'),
        color: chatSurfaceColor,
        child: _buildRawView(context),
      );
    }

    final codexPlanMessages = widget.messages
        .where((m) => m.type == MessageType.codexPlan)
        .toList();
    final activeCodexPlan = codexPlanMessages.isEmpty
        ? null
        : codexPlanMessages.last;
    final visibleRows = _renderRows();

    if (visibleRows.isEmpty && activeCodexPlan == null) {
      return ColoredBox(
        key: const ValueKey('chat-surface'),
        color: chatSurfaceColor,
        child: Center(
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
        ),
      );
    }

    final split = _splitRows(visibleRows);
    final older = split.older;
    final window = split.window;
    final olderIndexByKey = <Key, int>{
      for (var index = 0; index < older.length; index++)
        _messageSliverKey(older[index].rowKey): index,
    };
    final windowIndexByKey = <Key, int>{
      for (var index = 0; index < window.length; index++)
        _messageSliverKey(window[index].rowKey): index,
    };
    final windowCount = window.length + (_showsStatusRow ? 1 : 0);
    _scroll.sliverRowCounts = [older.length, windowCount];

    return ColoredBox(
      key: const ValueKey('chat-surface'),
      color: chatSurfaceColor,
      child: Column(
        children: [
          if (widget.todos.isNotEmpty && widget.showTodos)
            TodoListCard(
              key: ValueKey((
                'tasks',
                widget.serverId,
                widget.sessionStorageKey,
              )),
              todos: widget.todos,
              hidingNotice: widget.tasksHidingNotice,
              onDismiss: widget.onDismissTodos,
              onDismissTasks: widget.onDismissTasks,
            ),
          if (activeCodexPlan != null && widget.showCodexPlan)
            CodexPlanCard(
              key: ValueKey((
                'plan',
                widget.serverId,
                widget.sessionStorageKey,
                activeCodexPlan.id,
              )),
              msg: activeCodexPlan,
              serverId: widget.serverId,
              sessionId: widget.sessionStorageKey,
              hidingNotice: widget.codexPlanHidingNotice,
              onDismiss: widget.onDismissCodexPlan,
            ),
          Expanded(
            child: ColoredBox(
              key: const ValueKey('chat-scroll-surface'),
              color: chatSurfaceColor,
              // The glow paints inside this opaque surface, so the viewport
              // stays opaque while light mode still gets it.
              child: LightBackdrop(
                child: SizedBox.expand(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      // Own layer, so the pinned header appearing or
                      // disappearing never repaints the transcript.
                      RepaintBoundary(
                        // Desktop would add its own scrollbar; the chat
                        // paints one below that covers the whole
                        // conversation.
                        child: ScrollConfiguration(
                          behavior: ScrollConfiguration.of(
                            context,
                          ).copyWith(scrollbars: false),
                          child: NotificationListener<ScrollMetricsNotification>(
                            onNotification: _handleScrollMetricsNotification,
                            child: NotificationListener<ScrollNotification>(
                              onNotification: _scroll.handleScrollNotification,
                              child: CustomScrollView(
                                key: ValueKey<String>(
                                  'chat-list:${widget.sessionStorageKey ?? ''}',
                                ),
                                controller: _scroll,
                                center: _centerSliverKey,
                                slivers: [
                                  // Before the center, topmost first. These
                                  // grow upward, so a page of older rows or
                                  // the header never moves the viewport.
                                  SliverPadding(
                                    padding: const EdgeInsets.only(top: 8),
                                    sliver: widget.hasMoreHistory
                                        ? SliverToBoxAdapter(
                                            child: _buildLoadMoreButton(
                                              context,
                                            ),
                                          )
                                        : null,
                                  ),
                                  SliverList(
                                    key: ValueKey<String>(
                                      'chat-older:$_centerGeneration',
                                    ),
                                    delegate: SliverChildBuilderDelegate(
                                      (context, index) => _buildRenderRow(
                                        older[index].content,
                                        older[index].rowKey,
                                      ),
                                      childCount: older.length,
                                      findChildIndexCallback: (key) =>
                                          olderIndexByKey[key],
                                    ),
                                  ),
                                  SliverPadding(
                                    key: _centerSliverKey,
                                    padding: const EdgeInsets.only(bottom: 8),
                                    sliver: SliverList(
                                      key: ValueKey<String>(
                                        'chat-window:$_centerGeneration',
                                      ),
                                      delegate: SliverChildBuilderDelegate(
                                        (context, index) {
                                          if (index < window.length) {
                                            return _buildRenderRow(
                                              window[index].content,
                                              window[index].rowKey,
                                            );
                                          }
                                          return _buildThinkingIndicator(
                                            context,
                                          );
                                        },
                                        childCount: windowCount,
                                        findChildIndexCallback: (key) =>
                                            windowIndexByKey[key],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        top: 0,
                        left: _condensedCardMarginHorizontal,
                        right: _condensedCardMarginHorizontal,
                        child: RepaintBoundary(
                          child: ValueListenableBuilder<_PinnedCondensedGroup?>(
                            valueListenable: _pinnedCondensedGroup,
                            builder: (context, pinned, _) => pinned == null
                                ? const SizedBox.shrink()
                                : _buildPinnedCondensedHeader(pinned),
                          ),
                        ),
                      ),
                      Positioned.fill(
                        child: RepaintBoundary(
                          child: ChatScrollbar(
                            controller: _scroll,
                            olderRowCount: widget.olderHistoryCount,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant.withAlpha(145),
                            onSeekRow: _seekRow,
                            onSeekEnd: _endSeekRow,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRenderRow(CondensedChatRow row, String rowKey) {
    return KeyedSubtree(
      key: _messageSliverKey(rowKey),
      child: KeyedSubtree(
        key: _messageRowKeys.putIfAbsent(rowKey, () => GlobalKey()),
        child: switch (row) {
          CondensedVisibleRow(:final message)
              when message.id == widget.highlightMessageId =>
            ColoredBox(
              color: Theme.of(context).colorScheme.primary.withAlpha(48),
              child: _buildMessageContent(message, rowKey),
            ),
          CondensedVisibleRow(:final message) => _buildMessageContent(
            message,
            rowKey,
          ),
          CondensedWorkRow() => _buildCondensedWorkRow(row, rowKey),
        },
      ),
    );
  }

  static const double _condensedCardMarginHorizontal = 8;

  Widget _buildCondensedWorkRow(CondensedWorkRow row, String rowKey) {
    final expanded = _expandedCondensedRows.contains(rowKey);
    final theme = Theme.of(context);

    return Container(
      key: ValueKey<String>('condensed-work:$rowKey'),
      margin: const EdgeInsets.symmetric(
        horizontal: _condensedCardMarginHorizontal,
        vertical: _condensedCardMargin,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildCondensedWorkHeader(
            row,
            key: ValueKey<String>('condensed-work-toggle:$rowKey'),
            summaryKey: ValueKey<String>('condensed-work-summary:$rowKey'),
            expanded: expanded,
            onTap: () => _toggleCondensedGroup(rowKey),
          ),
          if (expanded && row.messages.isNotEmpty) ...[
            Divider(height: 1, color: theme.colorScheme.outlineVariant),
            for (var index = 0; index < row.messages.length; index++)
              _buildCondensedChild(
                row.messages[index],
                '$rowKey:child:$index:${_messageRowKey(row.messages[index])}',
              ),
          ],
        ],
      ),
    );
  }

  /// Header row of a condensed work card. The card uses it in place, and the
  /// same widget is pinned to the top of the viewport while the card's own
  /// header is scrolled away.
  Widget _buildCondensedWorkHeader(
    CondensedWorkRow row, {
    required Key key,
    required bool expanded,
    required VoidCallback onTap,
    Key? summaryKey,
  }) {
    final theme = Theme.of(context);
    final summary = _condensedSummary(row.metrics);
    Widget header(BuildContext context) {
      final details = _condensedDetails(row.metrics, DateTime.now());
      return Semantics(
        button: true,
        expanded: expanded,
        label: '$summary. $details',
        child: InkWell(
          key: key,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
            child: Row(
              children: [
                Icon(
                  expanded ? Icons.expand_more : Icons.chevron_right,
                  size: 19,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Icon(
                  Icons.view_stream_outlined,
                  size: 16,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        summary,
                        key: summaryKey,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (details.isNotEmpty)
                        Text(
                          details,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 10.5,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      if (row.messages.isNotEmpty)
                        MessageTimestamp(
                          timestamp: row.messages.first.timestamp,
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    // A live row's elapsed label ticks once a second on its own.
    return row.metrics.liveSince == null
        ? header(context)
        : EverySecond(builder: header);
  }

  /// Copy of an expanded group's header, pinned over the top of the viewport
  /// so the group can be collapsed from anywhere inside it.
  Widget _buildPinnedCondensedHeader(_PinnedCondensedGroup pinned) {
    final theme = Theme.of(context);
    return Material(
      key: _pinnedCondensedHeaderKey,
      color: theme.colorScheme.surfaceContainerLow,
      shape: Border(
        left: BorderSide(color: theme.colorScheme.outlineVariant),
        right: BorderSide(color: theme.colorScheme.outlineVariant),
        bottom: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: _buildCondensedWorkHeader(
        pinned.row,
        key: ValueKey<String>('condensed-work-pinned:${pinned.rowKey}'),
        expanded: true,
        onTap: () => _collapseCondensedGroupFromPinnedHeader(pinned.rowKey),
      ),
    );
  }

  /// Row heights can change without the offset moving, for example when a
  /// live group grows below the fold. Re-check the pinned header then too.
  bool _handleScrollMetricsNotification(
    ScrollMetricsNotification notification,
  ) {
    if (notification.depth == 0) _updatePinnedCondensedGroup();
    return false;
  }

  Widget _buildCondensedChild(ChatMessage message, String rowKey) {
    return KeyedSubtree(
      key: ValueKey<String>('condensed-child:$rowKey'),
      child: _buildMessageContent(message, rowKey),
    );
  }

  String _condensedSummary(CondensedWorkMetrics metrics) {
    final parts = <String>[];
    if (metrics.toolUses > 0) {
      parts.add(
        '${metrics.toolUses} tool ${metrics.toolUses == 1 ? 'use' : 'uses'}',
      );
    }
    if (metrics.thinkingTokens > 0) {
      parts.add('${formatCompactCount(metrics.thinkingTokens)} thought tokens');
    } else if (metrics.thinkingBlocks > 0) {
      parts.add(
        '${metrics.thinkingBlocks} ${metrics.thinkingBlocks == 1 ? 'thought' : 'thoughts'}',
      );
    }
    if (parts.isEmpty) {
      final count = metrics.internalEvents;
      parts.add('$count internal ${count == 1 ? 'event' : 'events'}');
    }
    return parts.join(' · ');
  }

  String _condensedDetails(CondensedWorkMetrics metrics, DateTime now) {
    final parts = <String>[];
    final elapsed = metrics.elapsedAt(now);
    if (elapsed > Duration.zero) {
      parts.add(
        elapsed < const Duration(seconds: 1)
            ? '<1s elapsed'
            : '${_formatElapsed(elapsed)} elapsed',
      );
    }
    if (metrics.thinkingDuration >= const Duration(seconds: 1)) {
      parts.add('${_formatElapsed(metrics.thinkingDuration)} thinking');
    }
    if (metrics.subagents > 0) {
      parts.add(
        '${metrics.subagents} ${metrics.subagents == 1 ? 'subagent' : 'subagents'}',
      );
    }
    if (metrics.failures > 0) {
      parts.add(
        '${metrics.failures} ${metrics.failures == 1 ? 'failure' : 'failures'}',
      );
    }
    return parts.join(' · ');
  }

  Key _messageSliverKey(String rowKey) =>
      ValueKey<String>('message-row:${widget.sessionStorageKey ?? ''}:$rowKey');

  String _messageRowKey(ChatMessage msg) {
    final transcriptIdentity = transcriptMessageIdentity(msg);
    if (transcriptIdentity != null) {
      return '${msg.type.name}:entry:$transcriptIdentity';
    }
    final toolId = msg.toolUseId ?? '';
    final parentId = msg.parentToolUseId ?? '';
    return '${msg.type.name}:${msg.id}:$toolId:$parentId';
  }

  Widget _buildMessageContent(ChatMessage msg, String rowKey) {
    final content = _buildMessageCard(msg, rowKey);
    // Dividers separate conversation sections; they are not chat cards.
    if (msg.type == MessageType.runBoundary ||
        msg.type == MessageType.compactBoundary) {
      return content;
    }
    // These widgets put the timestamp beside their content themselves. Plans
    // can hide all their steps, so their footer follows that visibility too.
    if (msg.type == MessageType.text ||
        msg.type == MessageType.result ||
        msg.type == MessageType.codexPlan) {
      return content;
    }
    return TimestampedChatCard(timestamp: msg.timestamp, child: content);
  }

  Widget _buildMessageCard(ChatMessage msg, String rowKey) {
    switch (msg.type) {
      case MessageType.text:
        return MessageBubble(
          message: msg,
          sourceServerId: widget.serverId,
          onRewindConversation: widget.onRewindConversation,
          codexRewind: widget.codexRewind,
          onBranch: widget.onBranch,
          onRetractPending: widget.onRetractQueuedMessage,
          onReadAloud: widget.onReadAloud,
          onReport: widget.onReportAiResponse,
        );
      case MessageType.toolCall:
        if (msg.toolName == 'Workflow') {
          final embedded = msg.toolInput?['_workflow_state'];
          Map<String, dynamic>? state = embedded is Map
              ? Map<String, dynamic>.from(embedded)
              : null;
          if (state == null && msg.backgroundTaskId != null) {
            state = widget.workflowTasks[msg.backgroundTaskId];
          }
          if (state == null && msg.toolUseId != null) {
            for (final candidate in widget.workflowTasks.values) {
              if (candidate['toolUseId']?.toString() == msg.toolUseId) {
                state = candidate;
                break;
              }
            }
          }
          state ??= {
            'workflowName':
                msg.toolInput?['workflow_name']?.toString() ?? 'Workflow',
            'summary': msg.toolInput?['summary']?.toString() ?? '',
            'status': msg.toolStreaming ? 'running' : 'completed',
          };
          if (msg.toolUseId != null) {
            _taskRowKeyByToolUseId.putIfAbsent(msg.toolUseId!, () => rowKey);
            _taskKeys.putIfAbsent(rowKey, () => GlobalKey());
          }
          return Container(
            key: _taskKeys[rowKey],
            child: WorkflowCard(message: msg, state: state),
          );
        }
        if (msg.toolName == 'Monitor') {
          return MonitorToolCard(message: msg);
        }
        if (msg.toolName == 'Speak') {
          return SpeakCard(message: msg);
        }
        if (msg.toolName == 'SendFile') {
          return FileCard(message: msg);
        }
        if (msg.toolName == 'ScheduleReminder') {
          return ReminderCard(message: msg);
        }
        if (SocketAgentToolCard.supports(msg)) {
          return SocketAgentToolCard(message: msg);
        }
        if (CodexActivityCard.supports(msg)) {
          return CodexActivityCard(message: msg);
        }
        if (msg.toolName == 'DelegatedAgentResult') {
          return SubAgentCard(
            message: msg,
            childMessages: const [],
            isRunning: false,
            greenTheme: msg.toolInput?['_task_status'] == 'completed',
            sourceServerId: widget.serverId,
            onReadAloud: widget.onReadAloud,
          );
        }
        // Task tool calls get a dedicated SubAgentCard
        if ((msg.toolName == 'Task' || msg.toolName == 'Agent') &&
            msg.toolUseId != null &&
            widget.subagentTasks.containsKey(msg.toolUseId)) {
          final toolUseId = msg.toolUseId!;
          _taskRowKeyByToolUseId.putIfAbsent(toolUseId, () => rowKey);
          _taskKeys.putIfAbsent(rowKey, () => GlobalKey());
          final isRunning =
              widget.subagentTasks[toolUseId]?['status'] == 'running';
          final children =
              _childMessagesByParent[toolUseId] ?? const <ChatMessage>[];
          return SubAgentCard(
            message: msg,
            childMessages: children,
            isRunning: isRunning,
            scrollKey: _taskKeys[rowKey],
            sourceServerId: widget.serverId,
            onReadAloud: widget.onReadAloud,
            onBackgroundTask: widget.onBackgroundTask,
            // Codex has no per-agent stop.
            onStopTask: widget.subagentTasks[toolUseId]?['source'] == 'codex'
                ? null
                : widget.onStopTask,
          );
        }
        // Backgrounded bash — register key for scroll-to
        if (msg.isBackgrounded && msg.toolUseId != null) {
          _taskRowKeyByToolUseId.putIfAbsent(msg.toolUseId!, () => rowKey);
          _taskKeys.putIfAbsent(rowKey, () => GlobalKey());
          return Container(
            key: _taskKeys[rowKey],
            child: _buildToolOutputBlock(msg, inspectionId: rowKey),
          );
        }
        return _buildToolOutputBlock(msg, inspectionId: rowKey);
      case MessageType.toolResult:
        return _buildToolOutputBlock(msg, inspectionId: rowKey);
      case MessageType.question:
        if (msg.emailPreview != null) {
          return EmailPreviewCard(message: msg, onAnswer: widget.onAnswer);
        }
        if (msg.questionId?.startsWith('resume_context_') == true) {
          return ResumeContextCard(message: msg, onAnswer: widget.onAnswer);
        }
        return QuestionCard(
          message: msg,
          onAnswer: widget.onAnswer,
          sourceServerId: widget.serverId,
        );
      case MessageType.secureInput:
        return SecureInputCard(
          message: msg,
          onSubmit: widget.onSecureInputSubmit,
          onUseStored: widget.onSecureInputUseStored,
          onCancel: widget.onSecureInputCancel,
          availableSecrets: widget.availableSecrets,
        );
      case MessageType.browserSession:
        return BrowserSessionCard(message: msg, serverId: widget.serverId);
      case MessageType.result:
        return MessageBubble(
          message: msg,
          sourceServerId: widget.serverId,
          onReadAloud: widget.onReadAloud,
          onReport: widget.onReportAiResponse,
        );
      case MessageType.error:
        return _buildErrorWidget(msg);
      case MessageType.taskNotification:
        return _buildTaskNotification(msg, rowKey);
      case MessageType.compactBoundary:
        return _buildCompactBoundaryDivider(msg);
      case MessageType.outlookAuth:
        return OutlookAuthCard(message: msg, onAnswer: widget.onAnswer);
      case MessageType.ibsAuth:
        return IBSAuthCard(message: msg, onAnswer: widget.onAnswer);
      case MessageType.claudeAuth:
        return ClaudeAuthCard(message: msg);
      case MessageType.backendAuth:
        return BackendAuthCard(message: msg);
      case MessageType.toolSummary:
        return _buildToolSummary(msg);
      case MessageType.thinking:
        return ThinkingCard(message: msg);
      case MessageType.elicitationUrl:
        return ElicitationCard(message: msg, onAnswer: widget.onAnswer);
      case MessageType.monitorOutput:
        return MonitorCard(message: msg);
      case MessageType.skillInvocation:
        return _buildSkillInvocationCard(msg);
      case MessageType.codexPlan:
        return CodexPlanCard(msg: msg);
      case MessageType.codexCommand:
        return CodexCommandCard(message: msg);
      case MessageType.htmlPlan:
        return HtmlPlanCard(message: msg);
      case MessageType.workReview:
        return WorkReviewCard(message: msg);
      case MessageType.runBoundary:
        return _buildRunBoundaryDivider(msg);
      case MessageType.computerAccess:
        return ComputerAccessCard(message: msg);
    }
  }

  Widget _buildLoadMoreButton(BuildContext context) {
    return Center(
      child: SizedBox(
        height: 52,
        child: widget.isLoadingMore
            ? const Center(
                child: SizedBox(
                  width: 160,
                  child: LinearProgressIndicator(minHeight: 2),
                ),
              )
            : Center(
                child: TextButton.icon(
                  onPressed: widget.onLoadMore,
                  icon: const Icon(Icons.expand_less, size: 18),
                  label: const Text('Load earlier messages'),
                  style: TextButton.styleFrom(
                    foregroundColor: Theme.of(context).colorScheme.primary,
                    textStyle: const TextStyle(fontSize: 13),
                  ),
                ),
              ),
      ),
    );
  }

  /// The trailing row that says the agent is working or waiting.
  bool get _showsStatusRow => widget.isProcessing || widget.isWaitingOnAgent;

  Widget _buildThinkingIndicator(BuildContext context) {
    if (!widget.isProcessing) return _buildWaitingOnAgentRow(context);
    final theme = Theme.of(context);
    final startedAt = widget.processingStartedAt;
    final labelBase = widget.isCompacting ? 'Compacting context' : 'Working';
    Widget label(BuildContext context) {
      final elapsed = startedAt == null
          ? null
          : DateTime.now().difference(startedAt);
      return Text(
        elapsed == null
            ? '$labelBase...'
            : '$labelBase - ${_formatElapsed(elapsed)}',
        style: TextStyle(
          color: theme.colorScheme.onSurface.withAlpha(178),
          fontSize: 14,
          fontStyle: FontStyle.italic,
        ),
      );
    }

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
            RunningIndicator(size: 16, color: theme.colorScheme.primary),
            const SizedBox(width: 10),
            // Only the label rebuilds each second, not the chat.
            startedAt == null ? label(context) : EverySecond(builder: label),
          ],
        ),
      ),
    );
  }

  /// Static, so a long wait on delegated agents does not keep repainting.
  Widget _buildWaitingOnAgentRow(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurface.withAlpha(178);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 64, 8),
      child: Row(
        children: [
          Icon(Icons.hourglass_empty, size: 16, color: color),
          const SizedBox(width: 10),
          Text(
            'Waiting on agent',
            style: TextStyle(
              color: color,
              fontSize: 14,
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
      ),
    );
  }

  String _formatElapsed(Duration duration) {
    // A server start time can be slightly ahead of this device's clock.
    final totalSeconds = duration.isNegative ? 0 : duration.inSeconds;
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;
    final secondsText = seconds.toString().padLeft(2, '0');
    if (hours > 0) {
      final minutesText = minutes.toString().padLeft(2, '0');
      return '$hours:$minutesText:$secondsText';
    }
    return '$minutes:$secondsText';
  }

  Widget _buildTaskNotification(ChatMessage msg, String rowKey) {
    final theme = Theme.of(context);
    final status = msg.toolName ?? 'unknown'; // status stored in toolName
    final isSuccess = status == 'completed' || status == 'success';
    final isFailed = status == 'failed';
    final isCancelled = status == 'cancelled';
    final isUploaded = status == 'uploaded';
    final isTodoUpdate = status == 'todos_updated';
    final isPermissionMode = status == 'permission_mode';
    final isModelChange = status == 'model_change';
    final isOldModel = status == 'model_old';
    final originToolUseId = msg.originToolUseId ?? msg.parentToolUseId;
    final slashCommandId = originToolUseId ?? msg.toolUseId ?? '';
    final isSlashCommand = slashCommandId.startsWith('codex_slash_');

    // Todo updates get a dedicated card
    if (isTodoUpdate) {
      return _buildTodoUpdateCard(msg);
    }
    if (status == 'manual') {
      return NotificationReceiptCard(message: msg);
    }
    if (status == 'model_refusal') {
      return RefusalCard(message: msg.textContent);
    }

    // Background bash completion — render as a ToolOutputBlock mirroring the original card
    if ((isSuccess || isFailed) && originToolUseId != null) {
      final original = _toolCallsById[originToolUseId];
      if (original != null && original.toolOutput != null) {
        return _buildToolOutputBlock(
          original,
          greenTheme: true,
          inspectionId: rowKey,
        );
      }
    }

    final IconData icon;
    final Color color;
    final Color bgColor;

    if (isSlashCommand) {
      icon = Icons.terminal;
      color = theme.colorScheme.tertiary;
      bgColor = theme.colorScheme.tertiaryContainer.withAlpha(70);
    } else if (isPermissionMode) {
      icon = Icons.shield_outlined;
      color = context.palette.shade(Colors.cyan, 300);
      bgColor = Colors.cyan.shade900.withAlpha(40);
    } else if (isOldModel) {
      icon = Icons.warning_amber_rounded;
      color = context.palette.shade(Colors.amber, 300);
      bgColor = Colors.amber.shade900.withAlpha(50);
    } else if (isModelChange) {
      icon = Icons.smart_toy_outlined;
      color = context.palette.shade(Colors.cyan, 300);
      bgColor = Colors.cyan.shade900.withAlpha(40);
    } else if (isCancelled) {
      icon = Icons.cancel_outlined;
      color = context.palette.shade(Colors.red, 300);
      bgColor = Colors.red.shade900.withAlpha(40);
    } else if (isUploaded) {
      icon = Icons.upload_file;
      color = context.palette.shade(Colors.teal, 300);
      bgColor = Colors.teal.shade900.withAlpha(40);
    } else if (isSuccess) {
      icon = Icons.check_circle_outline;
      color = context.palette.shade(Colors.green, 300);
      bgColor = Colors.green.shade900.withAlpha(50);
    } else if (isFailed) {
      icon = Icons.error_outline;
      color = context.palette.shade(Colors.orange, 300);
      bgColor = Colors.orange.shade900.withAlpha(50);
    } else {
      icon = Icons.info_outline;
      color = context.palette.shade(Colors.blue, 300);
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
              ![
                'completed',
                'failed',
                'stopped',
                'cancelled',
                'uploaded',
                'success',
              ].contains(status) &&
              msg.toolUseId != null &&
              msg.toolUseId!.isNotEmpty)
            IconButton(
              onPressed: () {
                widget.onStopTask!(msg.toolUseId!);
              },
              icon: Icon(
                Icons.stop_circle_outlined,
                size: 18,
                color: context.palette.shade(Colors.red, 300),
              ),
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
              isSlashCommand && !isFailed
                  ? 'COMMAND'
                  : isPermissionMode
                  ? 'PERMISSION'
                  : isModelChange
                  ? 'MODEL'
                  : isOldModel
                  ? 'OLD MODEL'
                  : status.toUpperCase(),
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

  Widget _buildRunBoundaryDivider(ChatMessage msg) {
    final theme = Theme.of(context);
    final durationMs = (msg.toolInput?['runDurationMs'] as num?)?.toInt() ?? 0;
    final runNumber = (msg.toolInput?['runNumber'] as num?)?.toInt();
    final outcome = msg.textContent;
    final color = outcome == 'failed'
        ? theme.colorScheme.error
        : outcome == 'stopped'
        ? theme.colorScheme.tertiary
        : theme.colorScheme.primary;
    final runLabel = runNumber == null || runNumber <= 0
        ? 'Run'
        : 'Run $runNumber';
    final label = outcome == 'completed'
        ? '$runLabel · ${_formatElapsed(Duration(milliseconds: durationMs))}'
        : '${outcome[0].toUpperCase()}${outcome.substring(1)} · ${_formatElapsed(Duration(milliseconds: durationMs))}';
    return Semantics(
      label:
          '$outcome run duration ${_formatElapsed(Duration(milliseconds: durationMs))}',
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
        child: Row(
          children: [
            Expanded(child: Divider(color: color.withAlpha(65))),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              ),
            ),
            Expanded(child: Divider(color: color.withAlpha(65))),
          ],
        ),
      ),
    );
  }

  Widget _buildSkillInvocationCard(ChatMessage msg) {
    final theme = Theme.of(context);
    final name = msg.toolName ?? msg.toolInput?['name'] as String? ?? '';
    final args = (msg.toolInput?['args'] as String? ?? msg.textContent).trim();
    final description = (msg.toolInput?['description'] as String? ?? '').trim();
    final body = (msg.toolInput?['body'] as String? ?? '').trim();
    final preview = body.isNotEmpty ? body : description;

    return Align(
      alignment: Alignment.centerRight,
      child: Opacity(
        opacity: msg.isPending ? 0.5 : 1.0,
        child: Container(
          margin: const EdgeInsets.only(left: 48, right: 8, top: 4, bottom: 4),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: theme.colorScheme.primaryContainer,
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(12),
              topRight: Radius.circular(12),
              bottomLeft: Radius.circular(12),
              bottomRight: Radius.circular(4),
            ),
            border: Border.all(color: theme.colorScheme.primary.withAlpha(90)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.auto_fix_high,
                    size: 16,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '/$name',
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: theme.colorScheme.onPrimaryContainer,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary.withAlpha(28),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      'Skill',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ),
                ],
              ),
              if (preview.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  preview,
                  maxLines: 5,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.3,
                    color: theme.colorScheme.onPrimaryContainer.withAlpha(210),
                  ),
                ),
              ],
              if (args.isNotEmpty) ...[
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surface.withAlpha(90),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    args,
                    style: TextStyle(
                      fontSize: 12,
                      color: theme.colorScheme.onPrimaryContainer,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildToolSummary(ChatMessage msg) {
    // Check if this summary is for a subagent — if so, render a full completion card
    final precedingIds = msg.precedingToolUseIds ?? [];
    for (final toolUseId in precedingIds) {
      if (widget.subagentTasks.containsKey(toolUseId)) {
        // Find the original tool_call message
        final original = _toolCallsById[toolUseId];
        if (original != null && original != msg) {
          final children =
              _childMessagesByParent[toolUseId] ?? const <ChatMessage>[];
          return SubAgentCard(
            message: original,
            childMessages: children,
            isRunning: false,
            greenTheme: true,
            sourceServerId: widget.serverId,
            onReadAloud: widget.onReadAloud,
          );
        }
      }
    }

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: context.palette.panel,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: context.palette.outline),
      ),
      child: Row(
        children: [
          Icon(Icons.summarize, size: 14, color: context.palette.blue),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              msg.textContent,
              style: TextStyle(
                fontSize: 12,
                color: context.palette.textSecondary,
              ),
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
          'No raw events yet.\nSend a message to see the raw stream.',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Theme.of(context).colorScheme.outline,
            fontSize: 14,
          ),
        ),
      );
    }

    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.only(top: 4, bottom: 8),
      itemCount: items.length,
      itemBuilder: (context, index) => RawEventCard(item: items[index]),
    );
  }

  Widget _buildErrorWidget(ChatMessage msg) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.red.shade900.withAlpha(76),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: context.palette.shade(Colors.red, 300).withAlpha(76),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
              Icons.error_outline,
              size: 18,
              color: context.palette.shade(Colors.red, 300),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: switch (msg.trace) {
              null => _buildErrorText(msg.textContent),
              final trace => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildErrorText(msg.textContent),
                  ErrorTraceRow(trace: trace, onReport: widget.onReportError),
                ],
              ),
            },
          ),
        ],
      ),
    );
  }

  Widget _buildErrorText(String text) {
    final urlPattern = RegExp(r'(?:https?://|socketagent://)\S+');
    final style = TextStyle(
      color: context.palette.shade(Colors.red, 200),
      fontSize: 13,
    );
    final linkStyle = TextStyle(
      color: context.palette.shade(Colors.blue, 300),
      fontSize: 13,
      decoration: TextDecoration.underline,
    );
    final matches = urlPattern.allMatches(text).toList();
    if (matches.isEmpty) return Text(text, style: style);

    final spans = <TextSpan>[];
    int last = 0;
    for (final m in matches) {
      if (m.start > last) {
        spans.add(TextSpan(text: text.substring(last, m.start)));
      }
      // A URL wrapped in parentheses or ending a sentence keeps its closing
      // punctuation outside the link.
      final url = m.group(0)!.replaceFirst(RegExp(r'[).,;:]+$'), '');
      final end = m.start + url.length;
      spans.add(
        TextSpan(
          text: url,
          style: linkStyle,
          recognizer: TapGestureRecognizer()
            ..onTap = () => SocketAgentLinkRouter.open(
              context,
              url,
              sourceServerId: widget.serverId,
            ),
        ),
      );
      last = end;
    }
    if (last < text.length) spans.add(TextSpan(text: text.substring(last)));
    return RichText(
      text: TextSpan(style: style, children: spans),
    );
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
    final lines = widget.msg.textContent
        .split('\n')
        .where((l) => l.isNotEmpty)
        .toList();
    final baseColor = context.palette.blue;

    return GestureDetector(
      onTap: () => setState(() => _expanded = !_expanded),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: context.palette.panel,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: baseColor.withAlpha(40)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.checklist, size: 14, color: baseColor),
                const SizedBox(width: 8),
                Expanded(
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
                  color: context.palette.textMuted,
                ),
              ],
            ),
            if (_expanded) ...[
              const SizedBox(height: 6),
              ...lines.map((line) {
                final Color lineColor;
                final IconData lineIcon;
                if (line.startsWith('\u2713 ')) {
                  lineColor = context.palette.shade(Colors.green, 300);
                  lineIcon = Icons.check_circle;
                } else if (line.startsWith('\u25b6 ')) {
                  lineColor = context.palette.shade(Colors.yellow, 300);
                  lineIcon = Icons.play_circle_fill;
                } else if (line.startsWith('+ ')) {
                  lineColor = context.palette.textSecondary;
                  lineIcon = Icons.radio_button_unchecked;
                } else if (line.startsWith('- ')) {
                  lineColor = context.palette.shade(Colors.red, 300);
                  lineIcon = Icons.remove_circle_outline;
                } else if (line.startsWith('\u25cb ')) {
                  lineColor = context.palette.textFaint;
                  lineIcon = Icons.radio_button_unchecked;
                } else {
                  lineColor = context.palette.textSecondary;
                  lineIcon = Icons.info_outline;
                }

                final hasPrefix =
                    line.startsWith('\u2713 ') ||
                    line.startsWith('\u25b6 ') ||
                    line.startsWith('+ ') ||
                    line.startsWith('- ') ||
                    line.startsWith('\u25cb ');
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
                            decoration: line.startsWith('\u2713 ')
                                ? TextDecoration.lineThrough
                                : null,
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
