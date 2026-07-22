import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/message.dart';
import '../models/message_reconciliation.dart';
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
import '../models/composer_attachment.dart';

class ChatView extends StatefulWidget {
  final List<ChatMessage> messages;
  final String? sessionStorageKey;
  final bool isProcessing;
  final Duration? processingElapsed;
  final bool isCompacting;
  final bool isLoadingHistory;
  final bool isLoadingMore;
  final bool hasMoreHistory;
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
  final void Function(String uuid, {bool rewindFiles})? onRewindConversation;
  final void Function(String uuid)? onBranch;
  final void Function(String messageId)? onRetractQueuedMessage;
  final bool rawMode;
  final List<SdkItem> rawItems;
  // For SubAgentCard: tracked subagent tasks and full message list for child lookup
  final Map<String, Map<String, dynamic>> subagentTasks;
  final List<ChatMessage> allMessages;

  const ChatView({
    super.key,
    required this.messages,
    this.sessionStorageKey,
    required this.isProcessing,
    this.processingElapsed,
    this.isCompacting = false,
    this.isLoadingHistory = false,
    this.isLoadingMore = false,
    this.hasMoreHistory = false,
    required this.todos,
    required this.onAnswer,
    required this.onSecureInputSubmit,
    required this.onSecureInputUseStored,
    required this.onSecureInputCancel,
    this.availableSecrets = const [],
    this.onLoadMore,
    this.onStopTask,
    this.onDismissTodos,
    this.onRewindConversation,
    this.onBranch,
    this.onRetractQueuedMessage,
    this.rawMode = false,
    this.rawItems = const [],
    this.subagentTasks = const {},
    this.allMessages = const [],
  });

  @override
  State<ChatView> createState() => ChatViewState();
}

class ChatViewState extends State<ChatView> {
  static const double _bottomFollowTolerance = 4;

  late final ScrollController _scrollController;
  bool _userScrolledUp = false;
  bool _isAutoScrolling = false;
  bool _userTouching = false;
  bool _scrollMotionActive = false;
  bool _autoScrollHeldForInspection = false;
  bool _imageInspectionActive = false;
  final Set<String> _expandedImageCardIds = {};
  final Map<String, GlobalKey> _imageCardKeys = {};
  final Map<String, int> _imageCollapseSignals = {};
  final Map<String, DateTime> _imageCardMissingSince = {};
  int _autoScrollGeneration = 0;
  int _lastKnownMessageCount = 0;
  String _lastKnownText = '';
  bool _lastKnownProcessing = false;
  Set<String> _knownPendingInteractionKeys = {};
  final GlobalKey _scrollViewportKey = GlobalKey();
  final Map<String, GlobalKey> _messageRowKeys = {};
  final Map<String, GlobalKey> _taskKeys = {};
  double? _historyLoadAnchorPixels;
  bool _historyLoadUserInteracted = false;
  bool _historyPrefetchScheduled = false;
  bool _readerAnchoringSuspended = false;
  int _readerAnchorGeneration = 0;

  bool get _hasActiveImageInspection =>
      _imageInspectionActive || _expandedImageCardIds.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    _knownPendingInteractionKeys = pendingInteractionKeys(widget.messages);
    _scrollController.addListener(_onScroll);
  }

  void _syncReaderViewportMode() {
    if (_isAutoScrolling ||
        _userTouching ||
        _scrollMotionActive ||
        _readerAnchoringSuspended ||
        widget.isLoadingHistory ||
        widget.isLoadingMore) {
      _readerAnchorGeneration++;
    }
  }

  ({String rowKey, double viewportY})? _captureVisibleReaderAnchor() {
    if (!_userScrolledUp ||
        _isAutoScrolling ||
        _userTouching ||
        _scrollMotionActive ||
        _readerAnchoringSuspended ||
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
      final score = rowTop <= viewportTop ? 0.0 : rowTop - viewportTop;
      if (score < bestScore) {
        bestScore = score;
        bestKey = entry.key;
        bestTop = rowTop - viewportTop;
      }
    }
    if (bestKey == null || bestTop == null) return null;
    return (rowKey: bestKey, viewportY: bestTop);
  }

  void _restoreVisibleReaderAnchor(({String rowKey, double viewportY}) anchor) {
    final generation = ++_readerAnchorGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          generation != _readerAnchorGeneration ||
          _isAutoScrolling ||
          _userTouching ||
          _scrollMotionActive ||
          _readerAnchoringSuspended ||
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
      if (viewportBox == null ||
          !viewportBox.hasSize ||
          rowBox == null ||
          !rowBox.hasSize) {
        return;
      }
      final viewportTop = viewportBox.localToGlobal(Offset.zero).dy;
      final currentY = rowBox.localToGlobal(Offset.zero).dy - viewportTop;
      final correction = anchor.viewportY - currentY;
      if (correction.abs() < 0.5) return;
      final position = _scrollController.position;
      final target = (position.pixels + correction)
          .clamp(position.minScrollExtent, position.maxScrollExtent)
          .toDouble();
      if ((target - position.pixels).abs() >= 0.5) {
        _scrollController.jumpTo(target);
      }
    });
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    if (notification is ScrollStartNotification) {
      _scrollMotionActive = true;
      _syncReaderViewportMode();
    } else if (notification is ScrollEndNotification) {
      _scrollMotionActive = false;
      _syncReaderViewportMode();
    }
    return false;
  }

  void _onScroll() {
    if (!_scrollController.hasClients || _isAutoScrolling) return;
    final pos = _scrollController.position;
    final distanceFromBottom = pos.pixels - pos.minScrollExtent;
    _userScrolledUp = distanceFromBottom > _bottomFollowTolerance;
    _syncReaderViewportMode();
    _collapseExpandedImagesFarFromViewport();
    if (distanceFromBottom <= 80 && !_hasActiveImageInspection) {
      _autoScrollHeldForInspection = false;
    }
    _scheduleHistoryPrefetchIfNeeded();
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

  bool _historyWasPrepended(ChatView oldWidget) {
    final added = widget.messages.length - oldWidget.messages.length;
    if (added <= 0 || oldWidget.messages.isEmpty) return false;
    return _messageRowKey(widget.messages[added]) ==
            _messageRowKey(oldWidget.messages.first) &&
        _messageRowKey(widget.messages.last) ==
            _messageRowKey(oldWidget.messages.last);
  }

  @override
  void didUpdateWidget(ChatView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final visibleReaderAnchor = _captureVisibleReaderAnchor();
    final activeRowKeys = widget.messages.map(_messageRowKey).toSet();
    _messageRowKeys.removeWhere((rowKey, _) => !activeRowKeys.contains(rowKey));
    final historyLoadFinished =
        oldWidget.isLoadingMore && !widget.isLoadingMore;
    final historyLoadStarted = !oldWidget.isLoadingMore && widget.isLoadingMore;
    final historyWasPrepended = _historyWasPrepended(oldWidget);
    if (historyLoadStarted || historyLoadFinished || historyWasPrepended) {
      _readerAnchoringSuspended = true;
      _readerAnchorGeneration++;
    }
    if (historyWasPrepended && _historyLoadAnchorPixels == null) {
      _historyLoadAnchorPixels = _scrollController.hasClients
          ? _scrollController.position.pixels
          : null;
    }
    final currentPendingInteractionKeys = pendingInteractionKeys(
      widget.messages,
    );
    final hasNewPendingInteraction = currentPendingInteractionKeys
        .difference(_knownPendingInteractionKeys)
        .isNotEmpty;
    _knownPendingInteractionKeys = currentPendingInteractionKeys;
    if (widget.sessionStorageKey != oldWidget.sessionStorageKey) {
      // Expansion is temporary reading state. Restoring it after switching
      // sessions can resurrect a large image body before its history bytes
      // reload, leaving a blank slab above the current transcript.
      _expandedImageCardIds.clear();
      _imageCardKeys.clear();
      _imageCollapseSignals.clear();
      _imageCardMissingSince.clear();
      _imageInspectionActive = false;
      _autoScrollHeldForInspection = false;
    }

    // Resync _userScrolledUp from the current scroll position. _onScroll
    // only fires when the user actively scrolls — if content grew below
    // the viewport without the user touching anything (e.g., they expanded
    // an inline image card, pushing maxScrollExtent down by ~300px with no
    // accompanying scroll event), the flag would stay stale at `false`
    // and the next state update would auto-scroll past where they're
    // looking, landing them right back on the card. Symptom: "I can never
    // scroll away from the expanded image."
    if (_scrollController.hasClients && !_isAutoScrolling) {
      final pos = _scrollController.position;
      final distanceFromBottom = pos.pixels - pos.minScrollExtent;
      _userScrolledUp = distanceFromBottom > _bottomFollowTolerance;
      _syncReaderViewportMode();
      if (distanceFromBottom <= 80 && !_hasActiveImageInspection) {
        _autoScrollHeldForInspection = false;
      }
    }

    // History just finished loading — jump to bottom unconditionally
    if (oldWidget.isLoadingHistory && !widget.isLoadingHistory) {
      _lastKnownMessageCount = widget.messages.length;
      _lastKnownText = widget.messages.isNotEmpty
          ? widget.messages.last.textContent
          : '';
      _lastKnownProcessing = widget.isProcessing;
      _userScrolledUp = false;
      _syncReaderViewportMode();
      _jumpToBottom();
      _maybeBackfillViewport();
      return;
    }

    if (historyLoadStarted) {
      _historyLoadAnchorPixels = _scrollController.hasClients
          ? _scrollController.position.pixels
          : null;
      _historyLoadUserInteracted = false;
    }

    // "Load more" just finished — restore the exact reverse-list offset.
    // Prepending should be stationary, but lazy row measurement and swapping
    // the loading control can otherwise nudge the viewport after layout.
    if (historyLoadFinished) {
      _lastKnownMessageCount = widget.messages.length;
      final anchor = _historyLoadAnchorPixels;
      _historyLoadAnchorPixels = null;
      if (anchor != null && !_historyLoadUserInteracted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!_scrollController.hasClients) {
            _readerAnchoringSuspended = false;
            _syncReaderViewportMode();
            return;
          }
          final position = _scrollController.position;
          _scrollController.jumpTo(
            anchor
                .clamp(position.minScrollExtent, position.maxScrollExtent)
                .toDouble(),
          );
          _maybeBackfillViewport();
          _scheduleHistoryPrefetchIfNeeded();
          _readerAnchoringSuspended = false;
          _syncReaderViewportMode();
        });
      } else {
        _maybeBackfillViewport();
        _scheduleHistoryPrefetchIfNeeded();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _readerAnchoringSuspended = false;
          _syncReaderViewportMode();
        });
      }
      return;
    }

    // A fast cache/provider can prepend and clear isLoadingMore within one
    // parent frame. Stable message identities still reveal that layout change,
    // so preserve the same reverse-list offset without relying on the flag.
    if (historyWasPrepended) {
      _lastKnownMessageCount = widget.messages.length;
      final anchor = _historyLoadAnchorPixels;
      _historyLoadAnchorPixels = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (anchor != null && _scrollController.hasClients) {
          final position = _scrollController.position;
          _scrollController.jumpTo(
            anchor
                .clamp(position.minScrollExtent, position.maxScrollExtent)
                .toDouble(),
          );
        }
        _readerAnchoringSuspended = false;
        _syncReaderViewportMode();
        _maybeBackfillViewport();
        _scheduleHistoryPrefetchIfNeeded();
      });
      return;
    }

    // Questions and secure-input requests are blocking interactions. Always
    // bring a newly arrived one into view, even if streaming output made the
    // scroll controller think the user had moved away from the bottom.
    if (hasNewPendingInteraction) {
      _userScrolledUp = false;
      _autoScrollHeldForInspection = false;
      _syncReaderViewportMode();
      _jumpToBottom();
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
    _syncReaderViewportMode();

    if (visibleReaderAnchor != null && _userScrolledUp) {
      _restoreVisibleReaderAnchor(visibleReaderAnchor);
    }

    if (hasNewContent &&
        !_userScrolledUp &&
        !_userTouching &&
        !_autoScrollHeldForInspection) {
      _scrollToBottom();
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
          position.maxScrollExtent - position.pixels;
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
    if (expanded) {
      _imageCardMissingSince.remove(messageId);
    }
    if (expanded) {
      _holdAutoScrollForInspection();
    } else {
      _releaseInspectionHoldIfIdle();
    }
    if (changed && mounted) {
      setState(() {});
    }
  }

  void _handleImageInspectionChanged(bool active) {
    _imageInspectionActive = active;
    if (active) {
      _holdAutoScrollForInspection();
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _releaseInspectionHoldIfIdle();
    });
  }

  void _holdAutoScrollForInspection() {
    _autoScrollHeldForInspection = true;
    _userScrolledUp = true;
    _syncReaderViewportMode();
    _cancelAutoScroll();
  }

  void _releaseInspectionHoldIfIdle() {
    if (_hasActiveImageInspection || !_scrollController.hasClients) return;
    final pos = _scrollController.position;
    final distanceFromBottom = pos.pixels - pos.minScrollExtent;
    _autoScrollHeldForInspection = false;
    _userScrolledUp = distanceFromBottom > _bottomFollowTolerance;
    _syncReaderViewportMode();
  }

  GlobalKey _imageCardKeyFor(String inspectionId) {
    return _imageCardKeys.putIfAbsent(inspectionId, () => GlobalKey());
  }

  int _imageCollapseSignalFor(String inspectionId) {
    return _imageCollapseSignals[inspectionId] ?? 0;
  }

  void _collapseExpandedImagesFarFromViewport() {
    if (_expandedImageCardIds.isEmpty) return;
    final viewportBox =
        _scrollViewportKey.currentContext?.findRenderObject() as RenderBox?;
    if (viewportBox == null || !viewportBox.hasSize) return;

    final viewportTop = viewportBox.localToGlobal(Offset.zero).dy;
    final viewportBottom = viewportTop + viewportBox.size.height;
    const collapseDistance = 96.0;
    final idsToCollapse = <String>[];

    for (final inspectionId in _expandedImageCardIds) {
      final cardBox =
          _imageCardKeys[inspectionId]?.currentContext?.findRenderObject()
              as RenderBox?;
      if (cardBox == null || !cardBox.hasSize) {
        _confirmMissingImageCardBeforeCollapse(inspectionId);
        continue;
      }
      _imageCardMissingSince.remove(inspectionId);

      final cardTop = cardBox.localToGlobal(Offset.zero).dy;
      final cardBottom = cardTop + cardBox.size.height;
      final isFarAbove = cardBottom < viewportTop - collapseDistance;
      final isFarBelow = cardTop > viewportBottom + collapseDistance;
      if (isFarAbove || isFarBelow) {
        idsToCollapse.add(inspectionId);
      }
    }

    if (idsToCollapse.isEmpty) return;
    setState(() {
      for (final inspectionId in idsToCollapse) {
        _expandedImageCardIds.remove(inspectionId);
        _imageCollapseSignals[inspectionId] =
            (_imageCollapseSignals[inspectionId] ?? 0) + 1;
      }
    });
    _releaseInspectionHoldIfIdle();
  }

  void _confirmMissingImageCardBeforeCollapse(String inspectionId) {
    _imageCardMissingSince.putIfAbsent(inspectionId, DateTime.now);
    Future.delayed(const Duration(milliseconds: 500), () {
      if (!mounted || !_expandedImageCardIds.contains(inspectionId)) return;
      final missingSince = _imageCardMissingSince[inspectionId];
      if (missingSince == null) return;
      if (DateTime.now().difference(missingSince) <
          const Duration(milliseconds: 500)) {
        return;
      }
      final cardBox =
          _imageCardKeys[inspectionId]?.currentContext?.findRenderObject()
              as RenderBox?;
      if (cardBox != null && cardBox.hasSize) {
        _imageCardMissingSince.remove(inspectionId);
        return;
      }
      setState(() {
        _expandedImageCardIds.remove(inspectionId);
        _imageCollapseSignals[inspectionId] =
            (_imageCollapseSignals[inspectionId] ?? 0) + 1;
        _imageCardMissingSince.remove(inspectionId);
      });
      _releaseInspectionHoldIfIdle();
    });
  }

  Widget _buildToolOutputBlock(
    ChatMessage msg, {
    bool greenTheme = false,
    String? inspectionId,
  }) {
    final id = inspectionId ?? msg.id;
    return Container(
      key: _imageCardKeyFor(id),
      child: ToolOutputBlock(
        message: msg,
        greenTheme: greenTheme,
        expanded: _expandedImageCardIds.contains(id) ? true : null,
        collapseSignal: _imageCollapseSignalFor(id),
        onExpansionChanged: (expanded, {required hasImage}) =>
            _handleToolExpansionChanged(id, expanded, hasImage: hasImage),
        onImageInspectionChanged: _handleImageInspectionChanged,
      ),
    );
  }

  void _cancelAutoScroll() {
    _autoScrollGeneration++;
    _isAutoScrolling = false;
    _syncReaderViewportMode();
    if (_scrollController.hasClients) {
      _scrollController.jumpTo(_scrollController.position.pixels);
    }
  }

  /// The reverse-anchored list keeps the newest transcript at offset zero, so
  /// one post-frame jump is sufficient even while older rows remain lazy.
  void _jumpToBottom() {
    _readerAnchorGeneration++;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.jumpTo(_scrollController.position.minScrollExtent);
    });
  }

  bool _scrollPending = false;

  void _scrollToBottom({bool jump = false}) {
    if (_scrollPending) return;
    _scrollPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollPending = false;
      if (!_scrollController.hasClients) return;
      final target = _scrollController.position.minScrollExtent;
      final distance = _scrollController.position.pixels - target;
      if (distance <= 0) return;

      if (jump || distance > 2000) {
        // Large jump (history load) — instant, no animation
        _scrollController.jumpTo(target);
      } else {
        final duration = distance < 200
            ? const Duration(milliseconds: 80)
            : const Duration(milliseconds: 180);

        _isAutoScrolling = true;
        _readerAnchorGeneration++;
        final generation = ++_autoScrollGeneration;
        _scrollController
            .animateTo(target, duration: duration, curve: Curves.easeOut)
            .then((_) {
              if (generation != _autoScrollGeneration) return;
              _isAutoScrolling = false;
              _syncReaderViewportMode();
            })
            .catchError((_) {
              if (generation != _autoScrollGeneration) return;
              _isAutoScrolling = false;
              _syncReaderViewportMode();
            });
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

    final codexPlanMessages = widget.messages
        .where((m) => m.type == MessageType.codexPlan)
        .toList();
    final activeCodexPlan = codexPlanMessages.isEmpty
        ? null
        : codexPlanMessages.last;
    final visibleMessages = widget.messages
        .where((m) => m.type != MessageType.codexPlan)
        .toList();

    if (visibleMessages.isEmpty && activeCodexPlan == null) {
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
    final itemCount =
        (hasLoadMore ? 1 : 0) +
        visibleMessages.length +
        (widget.isProcessing ? 1 : 0);

    return Column(
      children: [
        if (widget.todos.isNotEmpty)
          TodoListCard(todos: widget.todos, onDismiss: widget.onDismissTodos),
        if (activeCodexPlan != null)
          CodexPlanCard(
            key: ValueKey(activeCodexPlan.id),
            msg: activeCodexPlan,
          ),
        Expanded(
          child: Listener(
            key: _scrollViewportKey,
            onPointerDown: (_) {
              _userTouching = true;
              _syncReaderViewportMode();
              if (widget.isLoadingMore) {
                _historyLoadUserInteracted = true;
              }
            },
            onPointerUp: (_) {
              _userTouching = false;
              _syncReaderViewportMode();
            },
            onPointerCancel: (_) {
              _userTouching = false;
              _syncReaderViewportMode();
            },
            child: NotificationListener<ScrollNotification>(
              onNotification: _handleScrollNotification,
              child: ListView.builder(
                controller: _scrollController,
                reverse: true,
                padding: const EdgeInsets.only(top: 8, bottom: 8),
                itemCount: itemCount,
                itemBuilder: (context, index) {
                  var reverseIndex = index;
                  // In a reverse list index zero is the visual bottom.
                  if (widget.isProcessing) {
                    if (reverseIndex == 0) {
                      return _buildThinkingIndicator(context);
                    }
                    reverseIndex--;
                  }
                  if (reverseIndex < visibleMessages.length) {
                    final msgIndex = visibleMessages.length - 1 - reverseIndex;
                    return _buildMessageWidget(visibleMessages[msgIndex]);
                  }
                  // The final reverse-list item is the visual top.
                  return _buildLoadMoreButton(context);
                },
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMessageWidget(ChatMessage msg) {
    final rowKey = _messageRowKey(msg);
    return KeyedSubtree(
      key: _messageRowKeys.putIfAbsent(rowKey, () => GlobalKey()),
      child: _buildMessageContent(msg),
    );
  }

  String _messageRowKey(ChatMessage msg) {
    final toolId = msg.toolUseId ?? '';
    final parentId = msg.parentToolUseId ?? '';
    return '${msg.type.name}:${msg.id}:$toolId:$parentId';
  }

  Widget _buildMessageContent(ChatMessage msg) {
    switch (msg.type) {
      case MessageType.text:
        return MessageBubble(
          message: msg,
          onRewindConversation: widget.onRewindConversation,
          onBranch: widget.onBranch,
          onRetractPending: widget.onRetractQueuedMessage,
        );
      case MessageType.toolCall:
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
        // Task tool calls get a dedicated SubAgentCard
        if ((msg.toolName == 'Task' || msg.toolName == 'Agent') &&
            msg.toolUseId != null &&
            widget.subagentTasks.containsKey(msg.toolUseId)) {
          final toolUseId = msg.toolUseId!;
          _taskKeys.putIfAbsent(toolUseId, () => GlobalKey());
          final isRunning =
              widget.subagentTasks[toolUseId]?['status'] == 'running';
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
            child: _buildToolOutputBlock(msg),
          );
        }
        return _buildToolOutputBlock(msg);
      case MessageType.toolResult:
        return _buildToolOutputBlock(msg);
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
        return _buildTaskNotification(msg);
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

  Widget _buildTaskNotification(ChatMessage msg) {
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

    // Background bash completion — render as a ToolOutputBlock mirroring the original card
    if ((isSuccess || isFailed) && originToolUseId != null) {
      final original = widget.allMessages.cast<ChatMessage?>().firstWhere(
        (m) =>
            m!.type == MessageType.toolCall && m.toolUseId == originToolUseId,
        orElse: () => null,
      );
      if (original != null && original.toolOutput != null) {
        return _buildToolOutputBlock(
          original,
          greenTheme: true,
          inspectionId: '${original.id}:${msg.id}',
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
        final original = widget.allMessages.firstWhere(
          (m) => m.type == MessageType.toolCall && m.toolUseId == toolUseId,
          orElse: () => msg,
        );
        if (original != msg) {
          final children = widget.allMessages
              .where((m) => m.parentToolUseId == toolUseId)
              .toList();
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
