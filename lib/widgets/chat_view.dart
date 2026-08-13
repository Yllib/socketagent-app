import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import '../models/message.dart';
import '../models/condensed_chat_rows.dart';
import '../models/raw_event.dart';
import '../services/socketagent_link_router.dart';
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
  final String? serverId;
  final bool isProcessing;
  final bool followLatest;
  final bool condensedToolUsage;
  final ValueChanged<bool>? onFollowLatestChanged;
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
  final ValueChanged<String>? onReadAloud;
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
    this.followLatest = true,
    this.condensedToolUsage = false,
    this.onFollowLatestChanged,
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
    this.onReadAloud,
    this.rawMode = false,
    this.rawItems = const [],
    this.subagentTasks = const {},
    this.workflowTasks = const {},
    this.allMessages = const [],
  });

  @override
  State<ChatView> createState() => ChatViewState();
}

class _AutoFollowScrollController extends ScrollController {
  _AutoFollowScrollController({
    required this.shouldFollow,
    required this.prependAnchorCorrection,
  });

  final bool Function() shouldFollow;
  final double? Function() prependAnchorCorrection;
  bool _followRequested = false;
  double? _preservedEndDistance;
  double? _preservedPixels;

  void requestFollow() {
    _followRequested = true;
    for (final position in positions.whereType<_AutoFollowScrollPosition>()) {
      position.requestFollow();
    }
  }

  void cancelFollow() {
    _followRequested = false;
    for (final position in positions.whereType<_AutoFollowScrollPosition>()) {
      position.cancelFollow();
    }
  }

  void preserveCurrentEndDistance() {
    if (!hasClients) return;
    final current = position;
    _preservedPixels = current.pixels;
    _preservedEndDistance = current.maxScrollExtent - _preservedPixels!;
    for (final position in positions.whereType<_AutoFollowScrollPosition>()) {
      position.preserveEndDistance(
        _preservedEndDistance!,
        pixels: _preservedPixels!,
      );
    }
  }

  void rebasePreservedPosition() {
    if (!hasClients || _preservedEndDistance == null) return;
    final current = position;
    _preservedPixels = current.pixels;
    _preservedEndDistance = current.maxScrollExtent - current.pixels;
    for (final position in positions.whereType<_AutoFollowScrollPosition>()) {
      position.preserveEndDistance(
        _preservedEndDistance!,
        pixels: _preservedPixels!,
      );
    }
  }

  void finishPreservingEndDistance() {
    _preservedEndDistance = null;
    _preservedPixels = null;
    for (final position in positions.whereType<_AutoFollowScrollPosition>()) {
      position.finishPreservingEndDistance();
    }
  }

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) {
    return _AutoFollowScrollPosition(
      physics: physics,
      context: context,
      oldPosition: oldPosition,
      keepScrollOffset: keepScrollOffset,
      debugLabel: debugLabel,
      shouldFollow: shouldFollow,
      prependAnchorCorrection: prependAnchorCorrection,
      initiallyRequested: _followRequested,
      preservedEndDistance: _preservedEndDistance,
      preservedPixels: _preservedPixels,
      onRequestApplied: () => _followRequested = false,
    );
  }
}

class _AutoFollowScrollPosition extends ScrollPositionWithSingleContext {
  _AutoFollowScrollPosition({
    required super.physics,
    required super.context,
    required this.shouldFollow,
    required this.prependAnchorCorrection,
    required this.onRequestApplied,
    required bool initiallyRequested,
    required double? preservedEndDistance,
    required double? preservedPixels,
    super.keepScrollOffset,
    super.oldPosition,
    super.debugLabel,
  }) : _followRequested = initiallyRequested,
       _preservedEndDistance = preservedEndDistance,
       _preservedPixels = preservedPixels;

  final bool Function() shouldFollow;
  final double? Function() prependAnchorCorrection;
  final VoidCallback onRequestApplied;
  bool _followRequested;
  double? _preservedEndDistance;
  double? _preservedPixels;

  void requestFollow() => _followRequested = true;

  void cancelFollow() => _followRequested = false;

  void preserveEndDistance(double distance, {required double pixels}) {
    _preservedEndDistance = distance;
    _preservedPixels = pixels;
  }

  void finishPreservingEndDistance() {
    _preservedEndDistance = null;
    _preservedPixels = null;
  }

  @override
  bool applyContentDimensions(double minScrollExtent, double maxScrollExtent) {
    final previousMaxExtent = hasContentDimensions
        ? this.maxScrollExtent
        : null;
    final wasPinnedToBottom =
        previousMaxExtent != null &&
        hasPixels &&
        (pixels - previousMaxExtent).abs() < 1.0;
    final correctToBottom =
        shouldFollow() && (_followRequested || wasPinnedToBottom);
    final preservedEndDistance = shouldFollow() ? null : _preservedEndDistance;

    final accepted = super.applyContentDimensions(
      minScrollExtent,
      maxScrollExtent,
    );
    var corrected = false;
    if (correctToBottom && hasPixels) {
      if ((pixels - maxScrollExtent).abs() >= 0.5) {
        // applyContentDimensions runs during layout. Correcting here updates
        // the viewport before paint, unlike jumpTo after a frame, so history
        // reconciliation and lazy extent refinement cannot visibly teleport.
        correctPixels(maxScrollExtent);
        corrected = true;
      }
      _followRequested = false;
      onRequestApplied();
    } else if (preservedEndDistance != null && hasPixels) {
      final anchorCorrection = prependAnchorCorrection();
      final preservedPixels =
          (anchorCorrection == null
                  ? maxScrollExtent - preservedEndDistance
                  : (_preservedPixels ?? pixels) + anchorCorrection)
              .clamp(minScrollExtent, maxScrollExtent)
              .toDouble();
      if ((pixels - preservedPixels).abs() >= 0.5) {
        // Older rows were inserted ahead of the visible transcript. Preserve
        // the previous distance from the end while layout is still running so
        // the same rows remain under the user's finger without a painted jump.
        correctPixels(preservedPixels);
        corrected = true;
      }
    }
    // The sliver pass that calculated these dimensions used the old offset.
    // Ask the viewport for one immediate re-layout so it builds the actual
    // bottom children before paint; otherwise the corrected offset can point
    // at rows that were not laid out in this frame.
    return corrected ? false : accepted;
  }
}

class ChatViewState extends State<ChatView> with WidgetsBindingObserver {
  late final _AutoFollowScrollController _scrollController;
  final Set<String> _expandedImageCardIds = {};
  final Map<String, Set<String>> _expandedCondensedRowsBySession = {};
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
  bool _historyPrefetchScheduled = false;
  int _transcriptTargetGeneration = 0;
  int _transcriptTargetSeekAttempts = 0;
  bool _transcriptTargetLoadRequested = false;
  String? _lastTranscriptTargetIdentity;
  bool _followFallbackScheduled = false;
  int _prependPreservationGeneration = 0;
  String? _prependAnchorRowKey;
  double? _prependAnchorLayoutOffset;
  RenderBox? _prependAnchorBox;
  final Map<int, double> _activeViewportPointers = {};
  bool _userScrollInProgress = false;
  bool? _requestedFollowLatest;

  bool get _hasTranscriptTarget =>
      (widget.targetEntryId?.isNotEmpty ?? false) ||
      (widget.targetSessionSeq != null && widget.targetSessionSeq! > 0);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scrollController = _AutoFollowScrollController(
      shouldFollow: () =>
          mounted &&
          _effectiveFollowLatest &&
          !_userPointerDown &&
          !_userScrollInProgress &&
          !_hasTranscriptTarget,
      prependAnchorCorrection: _prependAnchorCorrection,
    );
    _reindexAllMessages(force: true);
    _scrollController.addListener(_onScroll);
    _scheduleTranscriptTargetSeek();
    if (_hasTranscriptTarget) {
      _disableFollowForTranscriptTarget();
    } else if (widget.followLatest) {
      _followToBottom();
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
    if (_scrollController.hasClients) {
      final position = _scrollController.position;
      _scrollController.jumpTo(
        position.pixels
            .clamp(position.minScrollExtent, position.maxScrollExtent)
            .toDouble(),
      );
    }
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
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
      return;
    }
    if (!widget.condensedToolUsage) return;
    final row = _renderRows(widget.messages).where((candidate) {
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
        (row) => _rowMatchesTranscriptTarget(row.content),
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

  bool _historyWasPrepended(ChatView oldWidget) {
    final added = widget.messages.length - oldWidget.messages.length;
    if (added <= 0 || oldWidget.messages.isEmpty) return false;
    return _messageRowKey(widget.messages[added]) ==
            _messageRowKey(oldWidget.messages.first) &&
        _messageRowKey(widget.messages.last) ==
            _messageRowKey(oldWidget.messages.last);
  }

  List<({CondensedChatRow content, String rowKey})> _renderRows(
    Iterable<ChatMessage> messages,
  ) {
    final occurrences = <String, int>{};
    final rows = buildCondensedChatRows(
      messages.where((message) => message.type != MessageType.codexPlan),
      messageKey: _messageRowKey,
      enabled: widget.condensedToolUsage,
      isProcessing: widget.isProcessing,
    );
    return [
      for (final row in rows)
        (content: row, rowKey: _collisionSafeRowKey(row.keySeed, occurrences)),
    ];
  }

  String _collisionSafeRowKey(String base, Map<String, int> occurrences) {
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

    if (_requestedFollowLatest == widget.followLatest) {
      _requestedFollowLatest = null;
    }
    if (!widget.followLatest) {
      _cancelFollowBottom();
    }

    final targetIdentity = _transcriptTargetIdentity();
    if (_lastTranscriptTargetIdentity != targetIdentity) {
      _lastTranscriptTargetIdentity = targetIdentity;
      _transcriptTargetSeekAttempts = 0;
      _transcriptTargetLoadRequested = false;
      _transcriptTargetGeneration++;
      _cancelFollowBottom();
      if (_hasTranscriptTarget) {
        _disableFollowForTranscriptTarget();
      }
    }
    if (oldWidget.isLoadingMore && !widget.isLoadingMore) {
      _transcriptTargetLoadRequested = false;
    }

    final historyWindowWasReplaced =
        widget.historyWindowRevision != oldWidget.historyWindowRevision;
    final newRows = _renderRows(widget.messages);
    final newRowKeys = newRows.map((row) => row.rowKey).toList();

    final activeRowKeys = newRowKeys.toSet();
    _messageRowKeys.removeWhere((rowKey, _) => !activeRowKeys.contains(rowKey));
    _taskKeys.removeWhere((rowKey, _) => !activeRowKeys.contains(rowKey));
    _taskRowKeyByToolUseId.removeWhere(
      (_, rowKey) => !activeRowKeys.contains(rowKey),
    );

    final historyLoadFinished =
        oldWidget.isLoadingMore && !widget.isLoadingMore;
    final historyWasPrepended = _historyWasPrepended(oldWidget);
    if (historyWasPrepended &&
        !_effectiveFollowLatest &&
        !_hasTranscriptTarget) {
      _preserveViewportAcrossPrepend();
    }
    if (historyLoadFinished || historyWasPrepended) {
      _transcriptTargetLoadRequested = false;
    }

    final sessionChanged =
        widget.sessionStorageKey != oldWidget.sessionStorageKey;
    if (sessionChanged) {
      _cancelFollowBottom();
      _finishPreservingPrepend();
      // A session ID can arrive after the cached chat has already painted.
      // Do not erase ownership of a gesture that began in that window.
      _userScrollInProgress = _userPointerDown;
      _requestedFollowLatest = null;
      _expandedImageCardIds.clear();
      _messageRowKeys.clear();
      _taskKeys.clear();
      _taskRowKeyByToolUseId.clear();
    }

    if (!oldWidget.followLatest && widget.followLatest) {
      _followToBottom();
      return;
    }

    if (sessionChanged && !_hasTranscriptTarget) {
      if (widget.followLatest) {
        _followToBottom();
      }
      return;
    }

    if (oldWidget.isLoadingHistory && !widget.isLoadingHistory) {
      if (_hasTranscriptTarget) {
        _scheduleTranscriptTargetSeek();
      } else if (widget.followLatest) {
        _followToBottom();
      }
      _maybeBackfillViewport();
      return;
    }

    if (historyWindowWasReplaced) {
      _cancelFollowBottom();
      if (_hasTranscriptTarget) {
        _scheduleTranscriptTargetSeek();
      } else if (widget.followLatest) {
        _followToBottom();
      }
      _maybeBackfillViewport();
      return;
    }

    if (historyLoadFinished || historyWasPrepended) {
      _cancelFollowBottom();
      if (_hasTranscriptTarget) {
        _scheduleTranscriptTargetSeek();
        return;
      }
      if (widget.followLatest) {
        _followToBottom();
      }
      _maybeBackfillViewport();
      _scheduleHistoryPrefetchIfNeeded();
      return;
    }

    // While a run is active, every provider update can represent an in-place
    // stream/card revision. Coalesce all such updates into one post-layout
    // bottom settle. Outside an active run, a row-count change is sufficient;
    // authoritative history replacement and session transitions are handled
    // explicitly above.
    if (widget.followLatest &&
        (widget.isProcessing ||
            oldWidget.isProcessing ||
            widget.condensedToolUsage != oldWidget.condensedToolUsage ||
            widget.messages.length != oldWidget.messages.length)) {
      _followToBottom();
    }

    if (_hasTranscriptTarget) {
      _scheduleTranscriptTargetSeek();
    }
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
    final changed = expanded
        ? _expandedImageCardIds.add(messageId)
        : _expandedImageCardIds.remove(messageId);
    if (changed && mounted) {
      setState(() {});
      if (widget.followLatest) {
        _followToBottom();
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

  void _cancelFollowBottom() {
    _scrollController.cancelFollow();
  }

  void _preserveViewportAcrossPrepend() {
    if (!_scrollController.hasClients) return;
    _capturePrependAnchor();
    final generation = ++_prependPreservationGeneration;
    _scrollController.preserveCurrentEndDistance();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _prependPreservationGeneration) return;
      _finishPreservingPrepend();
    });
  }

  void _finishPreservingPrepend() {
    _prependPreservationGeneration++;
    _scrollController.finishPreservingEndDistance();
    _prependAnchorRowKey = null;
    _prependAnchorLayoutOffset = null;
    _prependAnchorBox = null;
  }

  void _capturePrependAnchor() {
    final viewport =
        _scrollController.position.context.notificationContext
                ?.findRenderObject()
            as RenderBox?;
    if (viewport == null || !viewport.hasSize) return;
    final viewportTop = viewport.localToGlobal(Offset.zero).dy;
    final viewportBottom = viewportTop + viewport.size.height;
    String? selectedRowKey;
    double? selectedTop;
    RenderBox? selectedBox;

    for (final entry in _messageRowKeys.entries) {
      final box = entry.value.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) continue;
      final top = box.localToGlobal(Offset.zero).dy;
      final bottom = top + box.size.height;
      if (bottom <= viewportTop || top >= viewportBottom) continue;
      if (selectedTop == null || top < selectedTop) {
        selectedRowKey = entry.key;
        selectedTop = top;
        selectedBox = box;
      }
    }

    _prependAnchorRowKey = selectedRowKey;
    _prependAnchorBox = selectedBox;
    _prependAnchorLayoutOffset = selectedBox == null
        ? null
        : _sliverLayoutOffsetFor(selectedBox);
  }

  double? _prependAnchorCorrection() {
    final expectedOffset = _prependAnchorLayoutOffset;
    final box = _prependAnchorBox;
    if (_prependAnchorRowKey == null ||
        expectedOffset == null ||
        box == null ||
        !box.attached ||
        !box.hasSize) {
      return null;
    }
    final currentOffset = _sliverLayoutOffsetFor(box);
    return currentOffset == null ? null : currentOffset - expectedOffset;
  }

  double? _sliverLayoutOffsetFor(RenderObject anchor) {
    RenderObject child = anchor;
    RenderObject? parent = child.parent;
    while (parent != null) {
      if (parent is RenderSliverMultiBoxAdaptor) {
        final parentData = child.parentData;
        return parentData is SliverMultiBoxAdaptorParentData
            ? parentData.layoutOffset
            : null;
      }
      child = parent;
      parent = child.parent;
    }
    return null;
  }

  bool get _effectiveFollowLatest =>
      _requestedFollowLatest ?? widget.followLatest;

  bool get _userPointerDown => _activeViewportPointers.isNotEmpty;

  bool get _userOwnsViewport => _userPointerDown || _userScrollInProgress;

  void _handleViewportPointerDown(PointerDownEvent event) {
    _activeViewportPointers[event.pointer] = event.position.dy;
    // Pointer-down is the earliest reliable indication that the reader is
    // taking control. Cancel entry-time follow/prepend work before the drag
    // recognizer emits its first ScrollStartNotification.
    _cancelFollowBottom();
    // If a prepend was already queued, move its baseline to the exact offset
    // at which the finger took ownership instead of discarding the anchor.
    _scrollController.rebasePreservedPosition();
  }

  void _handleViewportPointerMove(PointerMoveEvent event) {
    final startY = _activeViewportPointers[event.pointer];
    if (startY == null || (event.position.dy - startY).abs() <= 2) return;
    // RawScrollbar drives the ScrollPosition directly and may not attach drag
    // details to its notifications. Pointer motion is the common ownership
    // signal for both a chat drag and an interactive thumb drag.
    if (_effectiveFollowLatest) _requestFollowLatest(false);
  }

  void _handleViewportPointerEnd(PointerEvent event) {
    _activeViewportPointers.remove(event.pointer);
  }

  void _disableFollowForTranscriptTarget() {
    final identity = _transcriptTargetIdentity();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !_hasTranscriptTarget ||
          _transcriptTargetIdentity() != identity) {
        return;
      }
      _requestFollowLatest(false);
    });
  }

  void _requestFollowLatest(bool follow) {
    if (_effectiveFollowLatest == follow) return;
    _requestedFollowLatest = follow;
    if (!follow) {
      _cancelFollowBottom();
    }
    widget.onFollowLatestChanged?.call(follow);
  }

  bool _handleUserScrollNotification(ScrollNotification notification) {
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      _userScrollInProgress = true;
      _cancelFollowBottom();
      _scrollController.rebasePreservedPosition();
    }

    if (_userScrollInProgress &&
        notification is ScrollUpdateNotification &&
        notification.dragDetails != null) {
      // A history page and a drag delta can land in adjacent layout passes.
      // Keep any pending anchor based on the latest user-owned pixels so its
      // correction adds only the prepended height, never a stale drag offset.
      _scrollController.rebasePreservedPosition();
    }

    if (_userScrollInProgress && _effectiveFollowLatest) {
      final movedByDrag =
          notification is ScrollUpdateNotification &&
          (notification.scrollDelta?.abs() ?? 0) > 0;
      final overscrollingAway =
          notification is OverscrollNotification &&
          notification.metrics.extentAfter > 2;
      if (movedByDrag || overscrollingAway) {
        // The first real drag delta transfers ownership immediately. Waiting
        // for extentAfter is racy while entry-time history is still changing
        // the content dimensions underneath the gesture.
        _requestFollowLatest(false);
      }
    }

    if (notification is ScrollEndNotification ||
        (notification is UserScrollNotification &&
            notification.direction == ScrollDirection.idle)) {
      final endedUserScroll = _userScrollInProgress;
      if (endedUserScroll &&
          !_effectiveFollowLatest &&
          notification.metrics.extentAfter <= 12) {
        _requestFollowLatest(true);
      }
      _userScrollInProgress = false;
      if (endedUserScroll && _effectiveFollowLatest) {
        _followToBottom();
      }
    }
    return false;
  }

  void _followToBottom() {
    // Never even queue a follow while the reader owns the viewport. Checking
    // only in the post-frame fallback is too late: applyContentDimensions can
    // consume the request during layout and visibly snap before that callback.
    if (_userOwnsViewport) return;
    _scrollController.requestFollow();
    if (_followFallbackScheduled) return;
    _followFallbackScheduled = true;
    final sessionStorageKey = widget.sessionStorageKey;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _followFallbackScheduled = false;
      if (!mounted ||
          !_effectiveFollowLatest ||
          _userScrollInProgress ||
          _hasTranscriptTarget ||
          widget.sessionStorageKey != sessionStorageKey ||
          !_scrollController.hasClients) {
        return;
      }
      final position = _scrollController.position;
      final maxExtent = position.maxScrollExtent;
      if ((position.pixels - maxExtent).abs() >= 0.5) {
        // Normally applyContentDimensions has already corrected the offset
        // before paint. This handles same-extent content replacements where
        // Flutter legitimately skips a viewport layout.
        position.jumpTo(maxExtent);
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
                child: Listener(
                  behavior: HitTestBehavior.translucent,
                  onPointerDown: _handleViewportPointerDown,
                  onPointerMove: _handleViewportPointerMove,
                  onPointerUp: _handleViewportPointerEnd,
                  onPointerCancel: _handleViewportPointerEnd,
                  child: RawScrollbar(
                    key: const ValueKey('chat-scrollbar'),
                    controller: _scrollController,
                    thumbVisibility: true,
                    trackVisibility: false,
                    interactive: true,
                    thickness: 3,
                    minThumbLength: 56,
                    radius: const Radius.circular(2),
                    mainAxisMargin: 4,
                    crossAxisMargin: 0,
                    scrollbarOrientation: ScrollbarOrientation.right,
                    thumbColor: Theme.of(
                      context,
                    ).colorScheme.onSurfaceVariant.withAlpha(145),
                    child: NotificationListener<ScrollNotification>(
                      onNotification: _handleUserScrollNotification,
                      child: ListView.builder(
                        key: ValueKey<String>(
                          'chat-list:${widget.sessionStorageKey ?? ''}',
                        ),
                        controller: _scrollController,
                        findChildIndexCallback: (key) =>
                            listIndexByMessageKey[key],
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
                            return _buildRenderRow(row.content, row.rowKey);
                          }
                          return _buildThinkingIndicator(context);
                        },
                      ),
                    ),
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
          CondensedVisibleRow(:final message) => _buildMessageContent(
            message,
            rowKey,
          ),
          CondensedWorkRow() => _buildCondensedWorkRow(row, rowKey),
        },
      ),
    );
  }

  Widget _buildCondensedWorkRow(CondensedWorkRow row, String rowKey) {
    final expanded = _expandedCondensedRows.contains(rowKey);
    final theme = Theme.of(context);
    final summary = _condensedSummary(row.metrics);
    final details = _condensedDetails(row.metrics);

    return Container(
      key: ValueKey<String>('condensed-work:$rowKey'),
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            button: true,
            expanded: expanded,
            label: '$summary. $details',
            child: InkWell(
              key: ValueKey<String>('condensed-work-toggle:$rowKey'),
              onTap: () {
                setState(() {
                  if (expanded) {
                    _expandedCondensedRows.remove(rowKey);
                  } else {
                    _expandedCondensedRows.add(rowKey);
                  }
                });
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 11,
                  vertical: 9,
                ),
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
                            key: ValueKey<String>(
                              'condensed-work-summary:$rowKey',
                            ),
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
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
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
      parts.add(
        '${_formatCompactCount(metrics.thinkingTokens)} thought tokens',
      );
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

  String _condensedDetails(CondensedWorkMetrics metrics) {
    final parts = <String>[];
    if (metrics.elapsed > Duration.zero) {
      parts.add(
        metrics.elapsed < const Duration(seconds: 1)
            ? '<1s elapsed'
            : '${_formatElapsed(metrics.elapsed)} elapsed',
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

  String _formatCompactCount(int value) {
    if (value >= 1000000) {
      final millions = value / 1000000;
      return '${millions.toStringAsFixed(millions >= 10 ? 0 : 1)}m';
    }
    if (value >= 1000) {
      final thousands = value / 1000;
      return '${thousands.toStringAsFixed(thousands >= 10 ? 0 : 1)}k';
    }
    return value.toString();
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
          sourceServerId: widget.serverId,
          onRewindConversation: widget.onRewindConversation,
          onBranch: widget.onBranch,
          onRetractPending: widget.onRetractQueuedMessage,
          onReadAloud: widget.onReadAloud,
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
      case MessageType.result:
        return MessageBubble(
          message: msg,
          sourceServerId: widget.serverId,
          onReadAloud: widget.onReadAloud,
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
    final urlPattern = RegExp(r'(?:https?://|socketagent://)\S+');
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
            ..onTap = () => SocketAgentLinkRouter.open(
              context,
              url,
              sourceServerId: widget.serverId,
            ),
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
