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
import 'elicitation_card.dart';
import 'monitor_card.dart';
import 'monitor_tool_card.dart';
import 'codex_plan_card.dart';
import 'codex_command_card.dart';
import 'secure_input_card.dart';
import 'html_plan_card.dart';
import 'work_review_card.dart';
import 'workflow_card.dart';
import 'codex_activity_card.dart';
import 'notification_receipt_card.dart';
import 'socketagent_tool_card.dart';
import '../models/composer_attachment.dart';

class ChatView extends StatefulWidget {
  final List<ChatMessage> messages;
  final String? sessionStorageKey;
  final bool isProcessing;
  final bool followLatest;
  final Duration? processingElapsed;
  final bool isCompacting;
  final bool isLoadingHistory;
  final bool isLoadingMore;
  final bool hasMoreHistory;
  final int historyWindowRevision;
  final String? targetEntryId;
  final int? targetSessionSeq;
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
  final VoidCallback? onDismissTodos;
  final void Function(Map<String, dynamic> todo)? onDismissTodo;
  final void Function(String uuid, {bool rewindFiles})? onRewindConversation;
  final void Function(String uuid)? onBranch;
  final void Function(String messageId)? onRetractQueuedMessage;
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
    required this.isProcessing,
    this.followLatest = true,
    this.processingElapsed,
    this.isCompacting = false,
    this.isLoadingHistory = false,
    this.isLoadingMore = false,
    this.hasMoreHistory = false,
    this.historyWindowRevision = 0,
    this.targetEntryId,
    this.targetSessionSeq,
    this.onTranscriptTargetReached,
    required this.todos,
    required this.onAnswer,
    required this.onSecureInputSubmit,
    required this.onSecureInputUseStored,
    required this.onSecureInputCancel,
    this.availableSecrets = const [],
    this.onLoadMore,
    this.onStopTask,
    this.onDismissTodos,
    this.onDismissTodo,
    this.onRewindConversation,
    this.onBranch,
    this.onRetractQueuedMessage,
    this.rawMode = false,
    this.rawItems = const [],
    this.subagentTasks = const {},
    this.workflowTasks = const {},
    this.allMessages = const [],
  });

  @override
  State<ChatView> createState() => ChatViewState();
}

class ChatViewState extends State<ChatView> with WidgetsBindingObserver {
  late final ScrollController _scrollController;
  final Set<String> _expandedImageCardIds = {};
  int _lastKnownMessageCount = 0;
  String _lastKnownText = '';
  bool _lastKnownProcessing = false;
  final GlobalKey _scrollViewportKey = GlobalKey();
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
  ({double pixels, double maxExtent})? _historyLoadAnchor;
  bool _historyPrefetchScheduled = false;
  int _readerAnchorGeneration = 0;
  int _transcriptTargetGeneration = 0;
  int _transcriptTargetSeekAttempts = 0;
  bool _transcriptTargetLoadRequested = false;
  String? _lastTranscriptTargetIdentity;

  bool get _hasTranscriptTarget =>
      (widget.targetEntryId?.isNotEmpty ?? false) ||
      (widget.targetSessionSeq != null && widget.targetSessionSeq! > 0);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scrollController = ScrollController();
    _reindexAllMessages(force: true);
    _scrollController.addListener(_onScroll);
    _scheduleTranscriptTargetSeek();
    if (widget.followLatest && !_hasTranscriptTarget) {
      _jumpToBottom(settleLazyLayout: true);
    }
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
    _readerAnchorGeneration++;
    _scrollPending = false;
    if (_scrollController.hasClients) {
      final position = _scrollController.position;
      _scrollController.jumpTo(
        position.pixels
            .clamp(position.minScrollExtent, position.maxScrollExtent)
            .toDouble(),
      );
    }
  }

  ({
    String rowKey,
    double screenY,
    double viewportScreenY,
    double scrollPixels,
  })?
  _captureVisibleReaderAnchor() {
    if (widget.followLatest ||
        widget.isLoadingHistory ||
        widget.isLoadingMore ||
        !_scrollController.hasClients) {
      return null;
    }
    final viewportBox =
        _scrollViewportKey.currentContext?.findRenderObject() as RenderBox?;
    if (viewportBox == null || !viewportBox.hasSize) return null;
    final viewportTop = viewportBox.localToGlobal(Offset.zero).dy;
    final viewportBottom = viewportTop + viewportBox.size.height;

    String? bestKey;
    double? bestTop;
    double bestScore = double.infinity;
    for (final entry in _messageRowKeys.entries) {
      final rowBox =
          entry.value.currentContext?.findRenderObject() as RenderBox?;
      if (rowBox == null || !rowBox.hasSize) continue;
      final rowTop = rowBox.localToGlobal(Offset.zero).dy;
      final rowBottom = rowTop + rowBox.size.height;
      if (rowBottom <= viewportTop || rowTop >= viewportBottom) continue;
      // Prefer the first row whose top is actually visible. A row with only a
      // sub-pixel sliver showing can be legitimately virtualized after an
      // otherwise exact correction, which makes it a poor durable anchor.
      final score = rowTop >= viewportTop
          ? rowTop - viewportTop
          : viewportBox.size.height + (viewportTop - rowTop);
      if (score < bestScore) {
        bestScore = score;
        bestKey = entry.key;
        bestTop = rowTop - viewportTop;
      }
    }
    if (bestKey == null || bestTop == null) return null;
    return (
      rowKey: bestKey,
      screenY: bestTop + viewportTop,
      viewportScreenY: viewportTop,
      scrollPixels: _scrollController.position.pixels,
    );
  }

  void _restoreVisibleReaderAnchor(
    ({
      String rowKey,
      double screenY,
      double viewportScreenY,
      double scrollPixels,
    })
    anchor,
  ) {
    final generation = ++_readerAnchorGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          generation != _readerAnchorGeneration ||
          widget.followLatest ||
          widget.isLoadingHistory ||
          widget.isLoadingMore ||
          !_scrollController.hasClients) {
        return;
      }
      final viewportBox =
          _scrollViewportKey.currentContext?.findRenderObject() as RenderBox?;
      final rowBox =
          _messageRowKeys[anchor.rowKey]?.currentContext?.findRenderObject()
              as RenderBox?;
      if (viewportBox == null || !viewportBox.hasSize) {
        return;
      }
      final position = _scrollController.position;
      final target = rowBox != null && rowBox.hasSize
          ? position.pixels +
                (rowBox.localToGlobal(Offset.zero).dy - anchor.screenY)
          : anchor.scrollPixels +
                (viewportBox.localToGlobal(Offset.zero).dy -
                    anchor.viewportScreenY);
      final clampedTarget = target
          .clamp(position.minScrollExtent, position.maxScrollExtent)
          .toDouble();
      if ((clampedTarget - position.pixels).abs() >= 0.5) {
        _scrollController.jumpTo(clampedTarget);
      }
    });
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    if (widget.isLoadingMore) {
      final position = _scrollController.position;
      _historyLoadAnchor = (
        pixels: position.pixels,
        maxExtent: position.maxScrollExtent,
      );
    }
    _scheduleHistoryPrefetchIfNeeded();
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
    }
  }

  String _transcriptTargetIdentity() =>
      '${widget.sessionStorageKey ?? ''}\u0001'
      '${widget.targetEntryId ?? ''}\u0001'
      '${widget.targetSessionSeq ?? ''}';

  bool _matchesTranscriptTarget(ChatMessage message) {
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
      _transcriptTargetLoadRequested = false;
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
      final rows = _renderRows(widget.messages);
      final messageIndex = rows.indexWhere(
        (row) => _matchesTranscriptTarget(row.message),
      );
      if (messageIndex < 0) {
        if (widget.hasMoreHistory &&
            widget.onLoadMore != null &&
            !_transcriptTargetLoadRequested) {
          _transcriptTargetLoadRequested = true;
          widget.onLoadMore!();
          return;
        }
        if (!widget.hasMoreHistory) {
          widget.onTranscriptTargetReached?.call();
        }
        return;
      }

      final rowKey = rows[messageIndex].rowKey;
      final listIndex = messageIndex + (widget.hasMoreHistory ? 1 : 0);
      final listItemCount =
          rows.length +
          (widget.isProcessing ? 1 : 0) +
          (widget.hasMoreHistory ? 1 : 0);
      _seekMountedTranscriptRow(
        rowKey: rowKey,
        targetListIndex: listIndex,
        listItemCount: listItemCount,
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
      _readerAnchorGeneration++;
      _historyLoadAnchor = null;
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
    if (!_scrollController.hasClients) {
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

    _transcriptTargetSeekAttempts++;
    final position = _scrollController.position;
    final rows = _renderRows(widget.messages);
    final listIndexByRowKey = <String, int>{};
    for (var index = 0; index < rows.length; index++) {
      listIndexByRowKey[rows[index].rowKey] =
          index + (widget.hasMoreHistory ? 1 : 0);
    }
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
      targetPixels = position.maxScrollExtent * targetListIndex / denominator;
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

  /// A prompt submitted from this phone must be visible immediately. Passive
  /// stream updates preserve a reader's viewport, but carrying that same rule
  /// across a local send can strand the new prompt below the viewport. It can
  /// also let a pending older-history anchor move the chat away again after
  /// the prompt was appended.
  void revealLatestUserPrompt() {
    if (!widget.followLatest) return;
    _readerAnchorGeneration++;
    _historyLoadAnchor = null;
    _scrollPending = false;
    _jumpToBottom(settleLazyLayout: true);
  }

  bool _historyWasPrepended(ChatView oldWidget) {
    final added = widget.messages.length - oldWidget.messages.length;
    if (added <= 0 || oldWidget.messages.isEmpty) return false;
    return _messageRowKey(widget.messages[added]) ==
            _messageRowKey(oldWidget.messages.first) &&
        _messageRowKey(widget.messages.last) ==
            _messageRowKey(oldWidget.messages.last);
  }

  List<({ChatMessage message, String rowKey})> _renderRows(
    Iterable<ChatMessage> messages,
  ) {
    final occurrences = <String, int>{};
    return [
      for (final message in messages)
        (message: message, rowKey: _collisionSafeRowKey(message, occurrences)),
    ];
  }

  String _collisionSafeRowKey(
    ChatMessage message,
    Map<String, int> occurrences,
  ) {
    final base = _messageRowKey(message);
    final occurrence = occurrences.update(
      base,
      (current) => current + 1,
      ifAbsent: () => 0,
    );
    return occurrence == 0 ? base : '$base#duplicate:$occurrence';
  }

  @override
  void didUpdateWidget(ChatView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _reindexAllMessages();

    final targetIdentity = _transcriptTargetIdentity();
    if (_lastTranscriptTargetIdentity != targetIdentity) {
      _lastTranscriptTargetIdentity = targetIdentity;
      _transcriptTargetSeekAttempts = 0;
      _transcriptTargetLoadRequested = false;
      _transcriptTargetGeneration++;
    }
    if (oldWidget.isLoadingMore && !widget.isLoadingMore) {
      _transcriptTargetLoadRequested = false;
    }

    final historyWindowWasReplaced =
        widget.historyWindowRevision != oldWidget.historyWindowRevision;
    final newRows = _renderRows(widget.messages);
    final newRowKeys = newRows.map((row) => row.rowKey).toList();
    // HOLD has one invariant: a visible transcript row keeps the same screen
    // coordinate across every rebuild. This covers structural inserts as well
    // as height changes in images, task panels, plans, and outer banners.
    final visibleReaderAnchor = !widget.followLatest
        ? _captureVisibleReaderAnchor()
        : null;

    final activeRowKeys = newRowKeys.toSet();
    _messageRowKeys.removeWhere((rowKey, _) => !activeRowKeys.contains(rowKey));
    _taskKeys.removeWhere((rowKey, _) => !activeRowKeys.contains(rowKey));
    _taskRowKeyByToolUseId.removeWhere(
      (_, rowKey) => !activeRowKeys.contains(rowKey),
    );

    final historyLoadFinished =
        oldWidget.isLoadingMore && !widget.isLoadingMore;
    final historyLoadStarted = !oldWidget.isLoadingMore && widget.isLoadingMore;
    final historyWasPrepended = _historyWasPrepended(oldWidget);
    if (historyLoadFinished || historyWasPrepended) {
      _transcriptTargetLoadRequested = false;
    }

    if (historyLoadStarted && _scrollController.hasClients) {
      final position = _scrollController.position;
      _historyLoadAnchor = (
        pixels: position.pixels,
        maxExtent: position.maxScrollExtent,
      );
    } else if (historyWasPrepended && _historyLoadAnchor == null) {
      if (_scrollController.hasClients) {
        final position = _scrollController.position;
        _historyLoadAnchor = (
          pixels: position.pixels,
          maxExtent: position.maxScrollExtent,
        );
      }
    }

    final sessionChanged =
        widget.sessionStorageKey != oldWidget.sessionStorageKey;
    if (sessionChanged) {
      _expandedImageCardIds.clear();
      _messageRowKeys.clear();
      _taskKeys.clear();
      _taskRowKeyByToolUseId.clear();
      _historyLoadAnchor = null;
      _readerAnchorGeneration++;
    }

    if (!oldWidget.followLatest && widget.followLatest) {
      _readerAnchorGeneration++;
      _historyLoadAnchor = null;
      _jumpToBottom(settleLazyLayout: true);
      _rememberCurrentTail();
      return;
    }

    if (sessionChanged && !_hasTranscriptTarget) {
      _rememberCurrentTail();
      if (widget.followLatest) {
        _jumpToBottom(settleLazyLayout: true);
      }
      return;
    }

    if (oldWidget.isLoadingHistory && !widget.isLoadingHistory) {
      _rememberCurrentTail();
      if (_hasTranscriptTarget) {
        _scheduleTranscriptTargetSeek();
      } else if (widget.followLatest) {
        _jumpToBottom(settleLazyLayout: true);
      }
      _maybeBackfillViewport();
      return;
    }

    if (historyWindowWasReplaced) {
      _readerAnchorGeneration++;
      _historyLoadAnchor = null;
      _rememberCurrentTail();
      if (_hasTranscriptTarget) {
        _scheduleTranscriptTargetSeek();
      } else if (widget.followLatest) {
        _jumpToBottom(settleLazyLayout: true);
      } else if (visibleReaderAnchor != null) {
        _restoreVisibleReaderAnchor(visibleReaderAnchor);
      }
      _maybeBackfillViewport();
      return;
    }

    if (historyLoadFinished || historyWasPrepended) {
      _rememberCurrentTail();
      final anchor = _historyLoadAnchor;
      _historyLoadAnchor = null;
      if (_hasTranscriptTarget) {
        _scheduleTranscriptTargetSeek();
        return;
      }
      if (anchor != null) {
        _restorePrependAnchor(anchor, readerAnchor: visibleReaderAnchor);
      } else if (!widget.followLatest && visibleReaderAnchor != null) {
        _restoreVisibleReaderAnchor(visibleReaderAnchor);
      }
      _maybeBackfillViewport();
      _scheduleHistoryPrefetchIfNeeded();
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

    if (_hasTranscriptTarget) {
      _scheduleTranscriptTargetSeek();
      return;
    }

    if (!widget.followLatest && visibleReaderAnchor != null) {
      _restoreVisibleReaderAnchor(visibleReaderAnchor);
    }

    if (hasNewContent && widget.followLatest) {
      _scrollToBottom();
    }
  }

  void _rememberCurrentTail() {
    _lastKnownMessageCount = widget.messages.length;
    _lastKnownText = widget.messages.isNotEmpty
        ? widget.messages.last.textContent
        : '';
    _lastKnownProcessing = widget.isProcessing;
  }

  void _restorePrependAnchor(
    ({double pixels, double maxExtent}) anchor, {
    ({
      String rowKey,
      double screenY,
      double viewportScreenY,
      double scrollPixels,
    })?
    readerAnchor,
  }) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients || _hasTranscriptTarget) {
        return;
      }
      final position = _scrollController.position;
      final addedExtent = position.maxScrollExtent - anchor.maxExtent;
      final target = (anchor.pixels + addedExtent)
          .clamp(position.minScrollExtent, position.maxScrollExtent)
          .toDouble();
      position.jumpTo(target);
      // The extent delta keeps the same lazy-list neighborhood mounted. A
      // row-key correction then removes any small error from unequal row
      // heights. This path runs once per explicit older-page prepend only.
      if (readerAnchor != null && !widget.followLatest) {
        _restoreVisibleReaderAnchor(readerAnchor);
      }
    });
  }

  void _maybeBackfillViewport() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !_scrollController.hasClients ||
          widget.isLoadingHistory ||
          widget.isLoadingMore ||
          !widget.hasMoreHistory ||
          widget.onLoadMore == null) {
        return;
      }
      final position = _scrollController.position;
      // Keep at least a page of scrollback beyond the current viewport. The
      // provider may continue farther to reach the latest user prompt.
      if (position.maxScrollExtent < position.viewportDimension) {
        widget.onLoadMore!();
      }
    });
  }

  void _scheduleHistoryPrefetchIfNeeded() {
    if (_historyPrefetchScheduled ||
        widget.isLoadingHistory ||
        widget.isLoadingMore ||
        !widget.hasMoreHistory ||
        widget.onLoadMore == null) {
      return;
    }
    _historyPrefetchScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _historyPrefetchScheduled = false;
      if (!mounted ||
          !_scrollController.hasClients ||
          widget.isLoadingHistory ||
          widget.isLoadingMore ||
          !widget.hasMoreHistory ||
          widget.onLoadMore == null) {
        return;
      }
      final position = _scrollController.position;
      final distanceFromOldestLoaded =
          position.pixels - position.minScrollExtent;
      final prefetchDistance = position.viewportDimension * 1.25;
      if (distanceFromOldestLoaded <= prefetchDistance) {
        widget.onLoadMore!();
      }
    });
  }

  void _handleToolExpansionChanged(
    String messageId,
    bool expanded, {
    required bool hasImage,
  }) {
    if (!hasImage) return;
    final readerAnchor = _captureVisibleReaderAnchor();
    final changed = expanded
        ? _expandedImageCardIds.add(messageId)
        : _expandedImageCardIds.remove(messageId);
    if (changed && mounted) {
      setState(() {});
      if (readerAnchor != null) {
        _restoreVisibleReaderAnchor(readerAnchor);
      }
    }
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
    );
  }

  void _jumpToBottom({
    bool settleLazyLayout = false,
    int attempt = 0,
    double? previousMaxExtent,
  }) {
    _readerAnchorGeneration++;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_scrollController.hasClients) {
        final position = _scrollController.position;
        final maxExtent = position.maxScrollExtent;
        if ((position.pixels - maxExtent).abs() >= 0.5) {
          position.jumpTo(maxExtent);
        }
        final extentIsStable =
            previousMaxExtent != null &&
            (previousMaxExtent - maxExtent).abs() < 0.5;
        if (settleLazyLayout &&
            !extentIsStable &&
            attempt < 8 &&
            widget.followLatest) {
          _jumpToBottom(
            settleLazyLayout: true,
            attempt: attempt + 1,
            previousMaxExtent: maxExtent,
          );
        }
      }
    });
  }

  bool _scrollPending = false;

  void _scrollToBottom({int settleAttempt = 0, double? previousMaxExtent}) {
    if (_scrollPending) return;
    _scrollPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollPending = false;
      if (!_scrollController.hasClients || !widget.followLatest) return;
      final position = _scrollController.position;
      final target = position.maxScrollExtent;
      final distance = target - position.pixels;
      if (distance > 0) {
        position.jumpTo(target);
      }
      final extentIsStable =
          previousMaxExtent != null && (previousMaxExtent - target).abs() < 0.5;
      if (!extentIsStable && settleAttempt < 8) {
        _scrollToBottom(
          settleAttempt: settleAttempt + 1,
          previousMaxExtent: target,
        );
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final chatSurfaceColor = Theme.of(context).colorScheme.surface;
    if (widget.isLoadingHistory) {
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
    final visibleMessages = widget.messages
        .where((m) => m.type != MessageType.codexPlan)
        .toList();
    final visibleRows = _renderRows(visibleMessages);

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

    final hasLoadMore = widget.hasMoreHistory;
    final itemCount =
        (hasLoadMore ? 1 : 0) +
        visibleRows.length +
        (widget.isProcessing ? 1 : 0);
    final listIndexByMessageKey = <Key, int>{};
    for (
      var messageIndex = 0;
      messageIndex < visibleRows.length;
      messageIndex++
    ) {
      final listIndex = messageIndex + (hasLoadMore ? 1 : 0);
      listIndexByMessageKey[_messageSliverKey(
            visibleRows[messageIndex].rowKey,
          )] =
          listIndex;
    }

    return ColoredBox(
      key: const ValueKey('chat-surface'),
      color: chatSurfaceColor,
      child: Column(
        children: [
          if (widget.todos.isNotEmpty)
            TodoListCard(
              todos: widget.todos,
              onDismiss: widget.onDismissTodos,
              onDismissTodo: widget.onDismissTodo,
            ),
          if (activeCodexPlan != null)
            CodexPlanCard(
              key: ValueKey(activeCodexPlan.id),
              msg: activeCodexPlan,
            ),
          Expanded(
            child: ColoredBox(
              key: const ValueKey('chat-scroll-surface'),
              color: chatSurfaceColor,
              child: SizedBox.expand(
                key: _scrollViewportKey,
                child: ListView.builder(
                  key: ValueKey<String>(
                    'chat-list:${widget.sessionStorageKey ?? ''}',
                  ),
                  controller: _scrollController,
                  findChildIndexCallback: (key) => listIndexByMessageKey[key],
                  padding: const EdgeInsets.only(top: 8, bottom: 8),
                  itemCount: itemCount,
                  itemBuilder: (context, index) {
                    var messageIndex = index;
                    if (hasLoadMore) {
                      if (messageIndex == 0) {
                        return _buildLoadMoreButton(context);
                      }
                      messageIndex--;
                    }
                    if (messageIndex < visibleRows.length) {
                      final row = visibleRows[messageIndex];
                      return _buildMessageWidget(row.message, row.rowKey);
                    }
                    return _buildThinkingIndicator(context);
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageWidget(ChatMessage msg, String rowKey) {
    return KeyedSubtree(
      key: _messageSliverKey(rowKey),
      child: KeyedSubtree(
        key: _messageRowKeys.putIfAbsent(rowKey, () => GlobalKey()),
        child: _buildMessageContent(msg, rowKey),
      ),
    );
  }

  Key _messageSliverKey(String rowKey) =>
      ValueKey<String>('message-row:${widget.sessionStorageKey ?? ''}:$rowKey');

  String _messageRowKey(ChatMessage msg) {
    final entryId = msg.entryId;
    if (entryId != null && entryId.isNotEmpty) {
      return '${msg.type.name}:entry:$entryId';
    }
    final toolId = msg.toolUseId ?? '';
    final parentId = msg.parentToolUseId ?? '';
    return '${msg.type.name}:${msg.id}:$toolId:$parentId';
  }

  Widget _buildMessageContent(ChatMessage msg, String rowKey) {
    switch (msg.type) {
      case MessageType.text:
        return MessageBubble(
          message: msg,
          onRewindConversation: widget.onRewindConversation,
          onBranch: widget.onBranch,
          onRetractPending: widget.onRetractQueuedMessage,
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
        return QuestionCard(message: msg, onAnswer: widget.onAnswer);
      case MessageType.secureInput:
        return SecureInputCard(
          message: msg,
          onSubmit: widget.onSecureInputSubmit,
          onUseStored: widget.onSecureInputUseStored,
          onCancel: widget.onSecureInputCancel,
          availableSecrets: widget.availableSecrets,
        );
      case MessageType.result:
        return MessageBubble(message: msg);
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

  Widget _buildThinkingIndicator(BuildContext context) {
    final theme = Theme.of(context);
    final elapsed = widget.processingElapsed;
    final labelBase = widget.isCompacting ? 'Compacting context' : 'Working';
    final label = elapsed == null
        ? '$labelBase...'
        : '$labelBase - ${_formatElapsed(elapsed)}';

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
              label,
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

  String _formatElapsed(Duration duration) {
    final totalSeconds = duration.inSeconds;
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
      color = Colors.cyan.shade300;
      bgColor = Colors.cyan.shade900.withAlpha(40);
    } else if (isCancelled) {
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
                color: Colors.red.shade300,
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
          );
        }
      }
    }

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
      controller: _scrollController,
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
        border: Border.all(color: Colors.red.shade300.withAlpha(76)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
              Icons.error_outline,
              size: 18,
              color: Colors.red.shade300,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(child: _buildErrorText(msg.textContent)),
        ],
      ),
    );
  }

  Widget _buildErrorText(String text) {
    final urlPattern = RegExp(r'https?://\S+');
    final style = TextStyle(color: Colors.red.shade200, fontSize: 13);
    final linkStyle = TextStyle(
      color: Colors.blue.shade300,
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
      final url = m.group(0)!;
      spans.add(
        TextSpan(
          text: 'Open login page',
          style: linkStyle,
          recognizer: TapGestureRecognizer()
            ..onTap = () => launchUrl(Uri.parse(url)),
        ),
      );
      last = m.end;
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
