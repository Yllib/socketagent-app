import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../main.dart' show assistVoiceTrigger;
import '../services/chat_provider.dart';
import '../services/tts_engine.dart';
import '../services/kokoro_server_engine.dart';
import '../services/websocket_service.dart';
import 'file_manager_screen.dart';
import 'project_instructions_screen.dart';
import 'terminal_screen.dart';
import 'settings/voice_speech_screen.dart';
import '../widgets/chat_view.dart';
import '../widgets/active_tasks_pane.dart';
import '../widgets/voice_button.dart';
import '../widgets/secret_manager_sheet.dart';
import '../widgets/html_plan_manager_sheet.dart';

class _BarSegment {
  final String label;
  final int tokens;
  final Color color;
  const _BarSegment(this.label, this.tokens, this.color);
}

class HomeScreen extends StatefulWidget {
  final bool autoStartVoice;

  const HomeScreen({super.key, this.autoStartVoice = false});

  @override
  State<HomeScreen> createState() => HomeScreenState();
}

class HomeScreenState extends State<HomeScreen> {
  final TextEditingController _textController = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  final GlobalKey<ChatViewState> _chatViewKey = GlobalKey();
  StreamSubscription? _speechSub;
  String? _trackedSessionId;
  bool _showCommandPicker = false;
  String _commandFilter = '';
  bool _pttPressed = false;
  bool _pttStartChecking = false;

  @override
  void initState() {
    super.initState();
    final provider = context.read<ChatProvider>();

    // Listen to speech results and fill text field
    _speechSub = provider.speech.onResult.listen((text) {
      _textController.text = text;
      _textController.selection = TextSelection.fromPosition(
        TextPosition(offset: text.length),
      );
    });

    // Sync text field edits back to STT isolate and save draft on every change
    _textController.addListener(() {
      if (provider.isListening) {
        provider.speech.onTextFieldChanged(_textController.text);
      }
      provider.saveDraft(_textController.text.trim());
      // Show/hide slash command picker.
      final text = _textController.text;
      final shouldShow = _isSlashCommandPrefix(text);
      if (shouldShow && provider.slashCommands.isEmpty) {
        provider.requestActiveSkills();
      }
      final filter = shouldShow ? text.substring(1).toLowerCase() : '';
      if (shouldShow != _showCommandPicker || filter != _commandFilter) {
        setState(() {
          _showCommandPicker = shouldShow;
          _commandFilter = filter;
        });
      }
    });

    // Track active session for draft swapping and notifications
    _trackedSessionId = provider.activeSessionId;
    provider.setViewingSession(provider.activeSessionId);

    // Restore saved draft for this session
    final draft = provider.getDraft();
    if (draft.isNotEmpty) {
      _textController.text = draft;
      _textController.selection = TextSelection.fromPosition(
        TextPosition(offset: draft.length),
      );
    }

    // Listen for assist button presses while already on this screen
    assistVoiceTrigger.addListener(_onAssistVoiceTrigger);

    if (widget.autoStartVoice) {
      Future.delayed(const Duration(milliseconds: 500), () {
        if (mounted) {
          provider.toggleListening(existingText: _textController.text);
        }
      });
    }
  }

  void _onAssistVoiceTrigger() {
    startVoiceInput();
  }

  @override
  void dispose() {
    // Save draft before disposing
    final provider = context.read<ChatProvider>();
    provider.saveDraft(_textController.text.trim());
    provider.setViewingSession(null);
    assistVoiceTrigger.removeListener(_onAssistVoiceTrigger);
    _speechSub?.cancel();
    _textController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  /// Start voice input — callable from outside via GlobalKey or assistVoiceTrigger
  void startVoiceInput() {
    final provider = context.read<ChatProvider>();
    if (!provider.isListening) {
      provider.toggleListening(existingText: _textController.text);
    }
  }

  Future<void> _startPushToTalk(ChatProvider provider) async {
    _pttPressed = true;
    if (_pttStartChecking) return;
    _pttStartChecking = true;
    try {
      final installed = await provider.asrModelManager.isModelInstalled();
      if (!mounted || !_pttPressed) return;
      if (!installed) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Download the speech model to use voice input'),
            action: SnackBarAction(
              label: 'Open',
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const VoiceSpeechScreen()),
                );
              },
            ),
          ),
        );
        return;
      }
      await provider.startListening(existingText: _textController.text);
    } finally {
      _pttStartChecking = false;
    }
  }

  void _stopPushToTalk(ChatProvider provider) {
    _pttPressed = false;
    provider.stopListening();
  }

  bool _isSlashCommandPrefix(String text) {
    if (!text.startsWith('/')) return false;
    final query = text.substring(1);
    return !query.contains(RegExp(r'\s'));
  }

  String _slashName(dynamic command) {
    if (command is Map) return (command['name'] ?? '').toString();
    return command.toString();
  }

  String _slashDescription(dynamic command) {
    if (command is Map) {
      return (command['description'] ?? '').toString();
    }
    return '';
  }

  String _slashArgumentHint(dynamic command) {
    if (command is Map) {
      return (command['argumentHint'] ?? command['argument-hint'] ?? '')
          .toString();
    }
    return '';
  }

  String _slashKind(dynamic command) {
    if (command is Map) return (command['kind'] ?? 'command').toString();
    return 'command';
  }

  String _slashAgent(dynamic command) {
    if (command is Map) return (command['agent'] ?? 'claude').toString();
    return 'claude';
  }

  void _insertSlashCommand(dynamic command) {
    final name = _slashName(command);
    if (name.isEmpty) return;
    _textController.text = '/$name ';
    _textController.selection = TextSelection.fromPosition(
      TextPosition(offset: _textController.text.length),
    );
    setState(() {
      _showCommandPicker = false;
      _commandFilter = '';
    });
    _focusNode.requestFocus();
  }

  void _sendMessage(ChatProvider provider, {String? priority}) {
    var text = _textController.text.trim();
    // If empty and there's a prompt suggestion, send the suggestion — but
    // only when there's no attachment, otherwise sending a file with no
    // typed text would silently bring along the suggestion the user never
    // asked to send.
    if (text.isEmpty &&
        !provider.hasAttachment &&
        provider.promptSuggestions.isNotEmpty) {
      text = provider.promptSuggestions.first;
      provider.clearPromptSuggestions();
    }
    if (text.isEmpty && !provider.hasAttachment) return;
    provider.sendPrompt(text, priority: priority);
    // A locally submitted prompt is different from passive streaming output:
    // it must always become visible even if reader/history anchoring currently
    // thinks the viewport should stay put.
    _chatViewKey.currentState?.revealLatestUserPrompt();
    _textController.clear();
    provider.saveDraft(''); // Clear draft on send
    _focusNode.requestFocus();
  }

  void _showPriorityMenu(
    BuildContext context,
    Offset position,
    ChatProvider provider,
    ThemeData theme,
  ) {
    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx - 150,
        position.dy - 160,
        position.dx,
        position.dy,
      ),
      items: [
        PopupMenuItem(
          value: 'now',
          child: ListTile(
            leading: Icon(
              Icons.flash_on,
              color: theme.colorScheme.primary,
              size: 20,
            ),
            title: const Text('Now'),
            subtitle: const Text(
              'Interrupt current tool',
              style: TextStyle(fontSize: 11),
            ),
            dense: true,
            contentPadding: EdgeInsets.zero,
          ),
        ),
        PopupMenuItem(
          value: 'next',
          child: ListTile(
            leading: Icon(
              Icons.arrow_forward,
              color: theme.colorScheme.secondary,
              size: 20,
            ),
            title: const Text('Next'),
            subtitle: const Text(
              'Between turns',
              style: TextStyle(fontSize: 11),
            ),
            dense: true,
            contentPadding: EdgeInsets.zero,
          ),
        ),
        PopupMenuItem(
          value: 'later',
          child: ListTile(
            leading: Icon(
              Icons.schedule,
              color: theme.colorScheme.tertiary,
              size: 20,
            ),
            title: const Text('Later'),
            subtitle: const Text(
              'After current task',
              style: TextStyle(fontSize: 11),
            ),
            dense: true,
            contentPadding: EdgeInsets.zero,
          ),
        ),
      ],
    ).then((value) {
      if (value != null) {
        _sendMessage(provider, priority: value);
      }
    });
  }

  void _showAttachmentMenu(ChatProvider provider) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.photo_library_outlined),
                title: const Text('Photos'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  provider.pickFiles(imagesOnly: true);
                },
              ),
              ListTile(
                leading: const Icon(Icons.attach_file),
                title: const Text('Files'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  provider.pickFiles();
                },
              ),
              ListTile(
                leading: const Icon(Icons.lock_outline),
                title: const Text('Secure value'),
                subtitle: const Text('Attach to your next message'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _showSecureInputDialog(provider);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _showSecureInputDialog(ChatProvider provider) async {
    final labelController = TextEditingController();
    final envController = TextEditingController();
    final valueController = TextEditingController();
    String scope = 'session';
    bool obscure = true;

    try {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) {
          return StatefulBuilder(
            builder: (context, setDialogState) {
              return AlertDialog(
                title: const Row(
                  children: [
                    Icon(Icons.lock_outline, size: 20),
                    SizedBox(width: 8),
                    Text('Secure input'),
                  ],
                ),
                content: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        'This value stays in the composer until you send your next message.',
                        style: TextStyle(fontSize: 12),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: labelController,
                        decoration: const InputDecoration(
                          labelText: 'Label',
                          hintText: 'OPENAI_API_KEY',
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: envController,
                        decoration: const InputDecoration(
                          labelText: 'Env var hint',
                          hintText: 'OPENAI_API_KEY',
                        ),
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        initialValue: scope,
                        decoration: const InputDecoration(labelText: 'Scope'),
                        items: const [
                          DropdownMenuItem(
                            value: 'session',
                            child: Text('Current session'),
                          ),
                          DropdownMenuItem(
                            value: 'project',
                            child: Text('Current project'),
                          ),
                          DropdownMenuItem(
                            value: 'global',
                            child: Text('This server'),
                          ),
                        ],
                        onChanged: (value) {
                          if (value == null) return;
                          setDialogState(() => scope = value);
                        },
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: valueController,
                        obscureText: obscure,
                        enableSuggestions: false,
                        autocorrect: false,
                        decoration: InputDecoration(
                          labelText: 'Secret value',
                          suffixIcon: IconButton(
                            tooltip: obscure ? 'Show' : 'Hide',
                            icon: Icon(
                              obscure
                                  ? Icons.visibility_outlined
                                  : Icons.visibility_off_outlined,
                            ),
                            onPressed: () {
                              setDialogState(() => obscure = !obscure);
                            },
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(dialogContext).pop(),
                    child: const Text('Cancel'),
                  ),
                  FilledButton.icon(
                    icon: const Icon(Icons.lock_outline, size: 18),
                    label: const Text('Attach'),
                    onPressed: () {
                      final label = labelController.text.trim();
                      final value = valueController.text;
                      if (label.isEmpty || value.isEmpty) return;
                      provider.queueSecureAttachment(
                        label: label,
                        value: value,
                        scope: scope,
                        envHint: envController.text,
                      );
                      valueController.clear();
                      Navigator.of(dialogContext).pop();
                    },
                  ),
                ],
              );
            },
          );
        },
      );
    } finally {
      labelController.dispose();
      envController.dispose();
      valueController.dispose();
    }
  }

  Future<void> _showSecretManager(ChatProvider provider) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => SecretManagerSheet(provider: provider),
    );
  }

  Future<void> _showHtmlPlanManager(ChatProvider provider) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => HtmlPlanManagerSheet(provider: provider),
    );
  }

  Widget _buildComposerAttachments(ChatProvider provider) {
    final attachments = <Widget>[
      for (final attachment in provider.pendingFileAttachments)
        InputChip(
          avatar: Icon(
            attachment.isImage
                ? Icons.image_outlined
                : Icons.insert_drive_file_outlined,
            size: 16,
          ),
          label: Text(attachment.name, overflow: TextOverflow.ellipsis),
          onDeleted: () => provider.removeFileAttachment(attachment.id),
        ),
      for (final attachment in provider.pendingSecretAttachments)
        InputChip(
          avatar: const Icon(Icons.lock_outline, size: 16),
          label: Text(
            '${attachment.label} (${attachment.scope})',
            overflow: TextOverflow.ellipsis,
          ),
          onDeleted: () => provider.removeSecretAttachment(attachment.id),
        ),
    ];
    return SizedBox(
      height: 42,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        scrollDirection: Axis.horizontal,
        itemCount: attachments.length,
        separatorBuilder: (_, _) => const SizedBox(width: 6),
        itemBuilder: (_, index) => ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 220),
          child: attachments[index],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ChatProvider>(
      builder: (context, provider, _) {
        // Swap drafts when active session changes
        final currentSessionId = provider.activeSessionId;
        if (currentSessionId != _trackedSessionId) {
          // Save draft for the old session
          if (_trackedSessionId != null) {
            provider.saveDraft(_textController.text.trim(), _trackedSessionId);
          }
          _trackedSessionId = currentSessionId;
          provider.setViewingSession(currentSessionId);
          // Restore draft for the new session
          final draft = provider.getDraft();
          if (draft != _textController.text.trim()) {
            _textController.text = draft;
            _textController.selection = TextSelection.fromPosition(
              TextPosition(offset: draft.length),
            );
          }
        }
        final permMode = provider.permissionMode ?? 'bypassPermissions';
        final displayPermMode = _displayPermissionMode(
          permMode,
          provider.activeSessionBackend,
        );
        final isPlan = permMode == 'plan';
        final sessionTheme =
            provider.activeSessionBackend == 'codex' && provider.codexFastMode
            ? _fastModeTheme()
            : _permissionModeTheme(displayPermMode);
        final chatSurfaceColor = Theme.of(context).colorScheme.surface;
        return Theme(
          data: sessionTheme != null
              ? Theme.of(context).copyWith(
                  appBarTheme: AppBarTheme(
                    backgroundColor: sessionTheme.barColor,
                    foregroundColor: sessionTheme.textColor,
                  ),
                )
              : Theme.of(context),
          child: Scaffold(
            backgroundColor: chatSurfaceColor,
            resizeToAvoidBottomInset: true,
            appBar: AppBar(
              title: GestureDetector(
                onLongPress: () {
                  provider.toggleRawMode();
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        provider.rawMode ? 'Raw mode ON' : 'Raw mode OFF',
                      ),
                      duration: const Duration(seconds: 1),
                    ),
                  );
                },
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      () {
                        final title = provider.activeSessionTitle;
                        final hasTitle =
                            title != null &&
                            title.isNotEmpty &&
                            title != 'Untitled';
                        final flags = <String>[];
                        if (provider.activeSessionBackend == 'codex') {
                          flags.add('CODEX');
                        }
                        if (provider.activeSessionBackend == 'codex' &&
                            provider.codexFastMode) {
                          flags.add('FAST');
                        }
                        if (isPlan) {
                          flags.add(
                            provider.activeSessionBackend == 'codex'
                                ? 'READ'
                                : 'PLAN',
                          );
                        }
                        if (provider.rawMode) flags.add('RAW');
                        final suffix = flags.isEmpty
                            ? ''
                            : ' [${flags.join('·')}]';
                        return (hasTitle ? title : 'SocketAgent') + suffix;
                      }(),
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: sessionTheme?.textColor,
                      ),
                    ),
                    if (provider.activeSessionCwd != null)
                      Text(
                        provider.serverConfigs.length > 1 &&
                                provider.connMgr.activeConfig != null
                            ? '${provider.connMgr.activeConfig!.name} · ${provider.activeSessionCwd!}'
                            : provider.activeSessionCwd!,
                        style: TextStyle(
                          fontSize: 11,
                          color:
                              (sessionTheme?.textColor ??
                                      Theme.of(context).colorScheme.onSurface)
                                  .withAlpha(178),
                        ),
                      ),
                    if (provider.activeSessionId != null ||
                        provider.isPendingNewSession)
                      GestureDetector(
                        onTap: () => _showPermissionModePicker(provider),
                        child: Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                _permissionModeIcon(displayPermMode),
                                size: 11,
                                color:
                                    (sessionTheme?.textColor ??
                                            Theme.of(
                                              context,
                                            ).colorScheme.onSurface)
                                        .withAlpha(178),
                              ),
                              const SizedBox(width: 4),
                              Text(
                                _permissionModeLabel(
                                  displayPermMode,
                                  backend: provider.activeSessionBackend,
                                ),
                                style: TextStyle(
                                  fontSize: 11,
                                  color:
                                      (sessionTheme?.textColor ??
                                              Theme.of(
                                                context,
                                              ).colorScheme.onSurface)
                                          .withAlpha(178),
                                ),
                              ),
                              Icon(
                                Icons.arrow_drop_down,
                                size: 14,
                                color:
                                    (sessionTheme?.textColor ??
                                            Theme.of(
                                              context,
                                            ).colorScheme.onSurface)
                                        .withAlpha(128),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              actions: [
                if (provider.lastUsage != null)
                  _buildUsageIndicator(provider.lastUsage!),
                _buildConnectionIndicator(provider.connectionStatus),
              ],
            ),
            body: ColoredBox(
              color: chatSurfaceColor,
              child: Column(
                children: [
                  if (provider.activeSessionId != null ||
                      provider.isPendingNewSession)
                    _buildControlChips(provider),
                  if (provider.isRefreshingHistory)
                    const LinearProgressIndicator(minHeight: 2),
                  Expanded(
                    child: ChatView(
                      key: _chatViewKey,
                      messages: provider.filteredMessages,
                      sessionStorageKey:
                          '${provider.activeServerId ?? ''}:${provider.activeSessionId ?? ''}',
                      isProcessing: provider.isProcessing,
                      processingElapsed: provider.currentPromptElapsed,
                      isCompacting: provider.isCompacting,
                      isLoadingHistory: provider.isLoadingHistory,
                      isLoadingMore: provider.isLoadingMore,
                      hasMoreHistory: provider.hasMoreHistory,
                      historyWindowRevision: provider.historyWindowRevision,
                      todos: provider.todos,
                      onAnswer: provider.answerQuestion,
                      onSecureInputSubmit: provider.submitSecureInput,
                      onSecureInputUseStored: provider.submitStoredSecureInput,
                      onSecureInputCancel: provider.cancelSecureInput,
                      availableSecrets: provider.secretInventory,
                      onLoadMore: provider.loadMoreHistory,
                      onStopTask: provider.stopTask,
                      onDismissTodos: provider.dismissTodos,
                      onRewindConversation:
                          provider.activeSessionBackend == 'codex'
                          ? null
                          : provider.rewindConversation,
                      onBranch: provider.activeSessionBackend == 'codex'
                          ? null
                          : provider.branchFromMessage,
                      onRetractQueuedMessage: (messageId) {
                        final text = provider.retractQueuedMessage(messageId);
                        if (text == null) return;
                        _textController.text = text;
                        _textController.selection = TextSelection.fromPosition(
                          TextPosition(offset: text.length),
                        );
                        provider.saveDraft(text.trim());
                        _focusNode.requestFocus();
                      },
                      rawMode: provider.rawMode,
                      rawItems: provider.rawItems,
                      subagentTasks: provider.subagentTasks,
                      allMessages: provider.messages,
                    ),
                  ),
                  if (provider.isCompacting) _buildCompactingBanner(),
                  if (provider.isRateLimited) _buildRateLimitBanner(provider),
                  if (provider.isRetrying) _buildRetryingBanner(),
                  if (provider.activeHookName != null)
                    _buildHookBanner(provider.activeHookName!),
                  if (provider.activePaneTasks.isNotEmpty)
                    ActiveTasksPane(
                      backgroundTasks: provider.backgroundTasks,
                      subagentTasks: provider.subagentTasks,
                      messages: provider.messages,
                      onStopTask: provider.stopTask,
                      onScrollToTask: (toolUseId) {
                        _chatViewKey.currentState?.scrollToTask(toolUseId);
                      },
                      onDismissSubagent: provider.dismissSubagent,
                    ),
                  _buildInputBar(provider),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildControlChips(ChatProvider provider) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        border: Border(
          bottom: BorderSide(
            color: theme.colorScheme.outlineVariant.withAlpha(60),
          ),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Center(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (provider.supportedModels.isNotEmpty)
                  _buildModelChip(provider)
                else if (provider.isLoadingNewSessionModels)
                  _buildLoadingModelChip(),
                const SizedBox(width: 6),
                _buildEffortChip(provider),
                const SizedBox(width: 6),
                if (provider.activeSessionBackend != 'codex') ...[
                  _buildThinkingChip(provider),
                  const SizedBox(width: 6),
                ],
                if (provider.rawMode) ...[
                  const SizedBox(width: 6),
                  _buildChipBody(
                    Icons.code,
                    'RAW',
                    iconColor: Colors.orange.shade300,
                    labelColor: Colors.orange.shade300,
                  ),
                ],
                const SizedBox(width: 6),
                _buildSessionMoreChip(provider),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildChipBody(
    IconData icon,
    String label, {
    Color? iconColor,
    Color? labelColor,
    bool active = false,
  }) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: active
            ? theme.colorScheme.primaryContainer.withAlpha(180)
            : theme.colorScheme.surfaceContainerHighest,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 14,
            color: iconColor ?? theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: labelColor ?? theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLoadingModelChip() {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: theme.colorScheme.surfaceContainerHighest,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            'Loading models',
            style: TextStyle(
              fontSize: 12,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSessionMoreChip(ChatProvider provider) {
    final projectPath = _projectFilesPath(provider);
    final showCodexMode = provider.activeSessionBackend == 'codex';
    return PopupMenuButton<String>(
      onOpened: () {
        if (showCodexMode) {
          provider.requestCodexCollaborationModes();
        }
      },
      onSelected: (value) {
        if (value.startsWith('codex_mode:')) {
          provider.setCodexCollaborationMode(
            value.substring('codex_mode:'.length),
          );
          return;
        }
        switch (value) {
          case 'project_files':
            _openProjectFiles(provider, projectPath);
            break;
          case 'project_instructions':
            _openProjectInstructions(provider, projectPath);
            break;
          case 'manage_secrets':
            Future.microtask(() {
              if (mounted) _showSecretManager(provider);
            });
            break;
          case 'manage_html_plans':
            Future.microtask(() {
              if (mounted) _showHtmlPlanManager(provider);
            });
            break;
          case 'terminal':
            _openTerminal(provider, projectPath);
            break;
          case 'tts_toggle':
            provider.setTtsEnabled(!provider.ttsEnabled);
            break;
          case 'tts_voice':
            Future.microtask(() {
              if (!mounted) return;
              if (provider.ttsEngineMode == TtsEngineMode.kokoroServer ||
                  provider.ttsEngineMode == TtsEngineMode.kokoroDevice) {
                _showKokoroVoicePicker(context, provider);
              } else {
                _showVoicePicker(context, provider);
              }
            });
            break;
          case 'notifications_toggle':
            final sessionId = provider.activeSessionId;
            if (sessionId != null) {
              provider.toggleSessionNotifications(sessionId);
            }
            break;
          case 'codex_fast_mode':
            provider.setCodexFastMode(!provider.codexFastMode);
            break;
          case 'claude_auto_compact':
            provider.setClaudeAutoCompactEnabled(
              !provider.claudeAutoCompactEnabled,
            );
            break;
        }
      },
      tooltip: 'Session options',
      padding: EdgeInsets.zero,
      position: PopupMenuPosition.under,
      child: _buildChipBody(Icons.more_horiz, 'More'),
      itemBuilder: (context) => [
        PopupMenuItem(
          value: 'project_files',
          enabled: projectPath != null && projectPath.isNotEmpty,
          child: Row(
            children: [
              const Icon(Icons.folder_open_outlined, size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Project files'),
                    if (projectPath != null && projectPath.isNotEmpty)
                      Text(
                        projectPath,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withAlpha(140),
                        ),
                      )
                    else
                      Text(
                        'No project directory available',
                        style: TextStyle(
                          fontSize: 11,
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withAlpha(140),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'project_instructions',
          enabled: projectPath != null && projectPath.isNotEmpty,
          child: const Row(
            children: [
              Icon(Icons.description_outlined, size: 18),
              SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Project instructions'),
                    Text(
                      'View or edit AGENTS.md and CLAUDE.md',
                      style: TextStyle(fontSize: 11),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'manage_secrets',
          child: const Row(
            children: [
              Icon(Icons.password_outlined, size: 18),
              SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Manage secrets'),
                    Text(
                      'Browse, create, replace, or delete',
                      style: TextStyle(fontSize: 11),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'manage_html_plans',
          enabled: provider.activeSessionId != null,
          child: const Row(
            children: [
              Icon(Icons.view_quilt_outlined, size: 18),
              SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('HTML plans'),
                    Text(
                      'View, rename, or delete session plans',
                      style: TextStyle(fontSize: 11),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'terminal',
          enabled: provider.activeServerId != null,
          child: Row(
            children: [
              const Icon(Icons.terminal, size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Open terminal'),
                    Text(
                      projectPath != null && projectPath.isNotEmpty
                          ? projectPath
                          : 'Active server shell',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withAlpha(140),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'tts_toggle',
          child: Row(
            children: [
              Icon(
                provider.ttsEnabled ? Icons.volume_up : Icons.volume_off,
                size: 18,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Text to speech'),
                    Text(
                      provider.ttsEnabled ? 'On' : 'Off',
                      style: TextStyle(
                        fontSize: 11,
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withAlpha(140),
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                provider.ttsEnabled
                    ? Icons.toggle_on_outlined
                    : Icons.toggle_off_outlined,
                size: 34,
                color: provider.ttsEnabled
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'tts_voice',
          child: Row(
            children: [
              const Icon(Icons.record_voice_over_outlined, size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Voice'),
                    Text(
                      _selectedVoiceLabel(provider),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withAlpha(140),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (provider.activeSessionId != null)
          PopupMenuItem(
            value: 'notifications_toggle',
            child: Row(
              children: [
                Icon(
                  provider.isNotifEnabled(provider.activeSessionId!)
                      ? Icons.notifications_active
                      : Icons.notifications_off_outlined,
                  size: 18,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('Notifications'),
                      Text(
                        provider.isNotifEnabled(provider.activeSessionId!)
                            ? 'On for this session'
                            : 'Muted for this session',
                        style: TextStyle(
                          fontSize: 11,
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withAlpha(140),
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  provider.isNotifEnabled(provider.activeSessionId!)
                      ? Icons.toggle_on_outlined
                      : Icons.toggle_off_outlined,
                  size: 34,
                  color: provider.isNotifEnabled(provider.activeSessionId!)
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        if (provider.activeSessionBackend == 'codex')
          PopupMenuItem(
            value: 'codex_fast_mode',
            child: Row(
              children: [
                Icon(
                  provider.codexFastMode
                      ? Icons.flash_on_outlined
                      : Icons.flash_off_outlined,
                  size: 18,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('Fast mode'),
                      Text(
                        provider.codexFastMode
                            ? 'On for this Codex session'
                            : 'Off for this Codex session',
                        style: TextStyle(
                          fontSize: 11,
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withAlpha(140),
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  provider.codexFastMode
                      ? Icons.toggle_on_outlined
                      : Icons.toggle_off_outlined,
                  size: 34,
                  color: provider.codexFastMode
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        if (provider.activeSessionBackend != 'codex')
          PopupMenuItem(
            value: 'claude_auto_compact',
            child: Row(
              children: [
                Icon(
                  provider.claudeAutoCompactEnabled
                      ? Icons.memory_outlined
                      : Icons.memory,
                  size: 18,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('Auto compact'),
                      Text(
                        provider.claudeAutoCompactEnabled
                            ? 'On for this Claude session'
                            : 'Off for this Claude session',
                        style: TextStyle(
                          fontSize: 11,
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withAlpha(140),
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  provider.claudeAutoCompactEnabled
                      ? Icons.toggle_on_outlined
                      : Icons.toggle_off_outlined,
                  size: 34,
                  color: provider.claudeAutoCompactEnabled
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        if (showCodexMode) ...[
          const PopupMenuDivider(),
          PopupMenuItem(
            enabled: false,
            child: Text(
              'Codex mode',
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.onSurface.withAlpha(140),
              ),
            ),
          ),
          for (final mode in provider.codexCollaborationModes)
            PopupMenuItem(
              value: 'codex_mode:${mode['id'] as String? ?? 'default'}',
              child: Row(
                children: [
                  if ((mode['id'] as String? ?? 'default') ==
                      provider.codexCollaborationMode)
                    Icon(
                      Icons.check,
                      size: 16,
                      color: Theme.of(context).colorScheme.primary,
                    )
                  else
                    const SizedBox(width: 16),
                  const SizedBox(width: 8),
                  const Icon(Icons.groups_outlined, size: 18),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      mode['name'] as String? ??
                          _formatModeName(mode['id'] as String? ?? 'default'),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ],
    );
  }

  String? _projectFilesPath(ChatProvider provider) {
    final sessionCwd = provider.activeSessionCwd?.trim();
    if (sessionCwd != null && sessionCwd.isNotEmpty) return sessionCwd;

    final activeDefault = provider.connMgr.activeConfig?.defaultCwd.trim();
    if (activeDefault != null && activeDefault.isNotEmpty) {
      return activeDefault;
    }

    final defaultCwd = provider.defaultCwd.trim();
    if (defaultCwd.isNotEmpty) return defaultCwd;
    return null;
  }

  void _openProjectFiles(ChatProvider provider, String? projectPath) {
    if (projectPath == null || projectPath.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => FileManagerScreen(
          serverId: provider.activeServerId,
          initialPath: projectPath,
        ),
      ),
    );
  }

  void _openProjectInstructions(ChatProvider provider, String? projectPath) {
    final serverId = provider.activeServerId;
    if (serverId == null || projectPath == null || projectPath.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ProjectInstructionsScreen(
          serverId: serverId,
          projectPath: projectPath,
        ),
      ),
    );
  }

  void _openTerminal(ChatProvider provider, String? projectPath) {
    final serverId = provider.activeServerId;
    if (serverId == null) return;
    final serverName = provider.connMgr.activeConfig?.name;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TerminalScreen(
          serverId: serverId,
          serverName: serverName,
          initialCwd: projectPath,
        ),
      ),
    );
  }

  Widget _buildModelChip(ChatProvider provider) {
    final currentModel = provider.sessionModel ?? '';
    final name = currentModel.isEmpty
        ? 'Model'
        : _modelDisplayName(provider, currentModel);

    return PopupMenuButton<String>(
      onSelected: (value) => provider.setModel(value),
      tooltip: 'Model: $name',
      padding: EdgeInsets.zero,
      position: PopupMenuPosition.under,
      child: _buildChipBody(Icons.smart_toy, name),
      itemBuilder: (context) => provider.supportedModels.map((model) {
        final value = (model['value'] ?? model['id'] ?? '').toString();
        final modelName = _modelDisplayNameForEntry(model, value);
        final description = model['description'] as String? ?? '';
        final isSelected = value == currentModel;
        return PopupMenuItem(
          value: value,
          child: Row(
            children: [
              if (isSelected)
                Icon(
                  Icons.check,
                  size: 16,
                  color: Theme.of(context).colorScheme.primary,
                )
              else
                const SizedBox(width: 16),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      modelName,
                      style: TextStyle(
                        fontWeight: isSelected
                            ? FontWeight.bold
                            : FontWeight.normal,
                      ),
                    ),
                    if (description.isNotEmpty)
                      Text(
                        description,
                        style: TextStyle(
                          fontSize: 11,
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withAlpha(128),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  String _selectedVoiceLabel(ChatProvider provider) {
    if (provider.ttsEngineMode == TtsEngineMode.kokoroServer ||
        provider.ttsEngineMode == TtsEngineMode.kokoroDevice) {
      return provider.selectedTtsEngineVoice?.name ?? 'Default voice';
    }
    return provider.selectedTtsVoice?.name ?? 'System voice';
  }

  String _modelDisplayName(ChatProvider provider, String modelId) {
    for (final model in provider.supportedModels) {
      final value = (model['value'] ?? model['id'] ?? '').toString();
      if (value == modelId) return _modelDisplayNameForEntry(model, modelId);
    }
    return _modelName(modelId);
  }

  String _modelDisplayNameForEntry(Map<String, dynamic> model, String value) {
    final displayName = model['displayName'] ?? model['label'] ?? model['name'];
    final text = displayName?.toString().trim() ?? '';
    return text.isNotEmpty ? text : _modelName(value);
  }

  Widget _buildEffortChip(ChatProvider provider) {
    final isCodex = provider.activeSessionBackend == 'codex';
    IconData icon;
    Color color;
    switch (provider.effort) {
      case 'minimal':
        icon = Icons.remove_circle_outline;
        color = Theme.of(context).colorScheme.onSurfaceVariant;
        break;
      case 'low':
        icon = Icons.bolt;
        color = Colors.blue.shade300;
        break;
      case 'medium':
        icon = Icons.speed;
        color = Theme.of(context).colorScheme.onSurfaceVariant;
        break;
      case 'max':
      case 'xhigh':
      case 'ultra':
        icon = Icons.whatshot;
        color = Colors.orange.shade300;
        break;
      default: // high
        icon = Icons.auto_awesome;
        color = Theme.of(context).colorScheme.primary;
    }
    final label = _effortLabel(provider.effort);
    final options = provider.selectedModelEffortLevels;

    return PopupMenuButton<String>(
      onSelected: (value) => provider.setEffort(value),
      tooltip: isCodex ? 'Reasoning effort: $label' : 'Effort: $label',
      padding: EdgeInsets.zero,
      position: PopupMenuPosition.under,
      child: _buildChipBody(icon, label, iconColor: color),
      itemBuilder: (context) => [
        for (final e in options)
          PopupMenuItem(
            value: e,
            child: Row(
              children: [
                if (e == provider.effort)
                  Icon(
                    Icons.check,
                    size: 16,
                    color: Theme.of(context).colorScheme.primary,
                  )
                else
                  const SizedBox(width: 16),
                const SizedBox(width: 8),
                Text(_effortLabel(e)),
              ],
            ),
          ),
      ],
    );
  }

  String _effortLabel(String effort) {
    switch (effort) {
      case 'minimal':
        return 'Minimal';
      case 'xhigh':
        return 'XHigh';
      case 'ultra':
        return 'Ultra';
      default:
        if (effort.isEmpty) return 'Default';
        return effort[0].toUpperCase() + effort.substring(1);
    }
  }

  String _formatModeName(String mode) {
    if (mode.isEmpty) return 'Default';
    return mode
        .split(RegExp(r'[-_\s]+'))
        .where((part) => part.isNotEmpty)
        .map((part) => part[0].toUpperCase() + part.substring(1))
        .join(' ');
  }

  static const _permModes = [
    ('bypassPermissions', 'Yolo', 'Auto-approve everything', Icons.speed),
    (
      'auto',
      'Smart Auto',
      'AI classifier approves safe actions',
      Icons.smart_toy,
    ),
    (
      'acceptEdits',
      'Auto-Edit',
      'Auto-approve edits, ask for commands',
      Icons.edit,
    ),
    ('default', 'Ask', 'Ask before risky actions', Icons.shield_outlined),
    ('plan', 'Plan', 'Plan only, no execution', Icons.edit_note),
  ];

  List<(String, String, String, IconData)> _permissionModesForBackend(
    String? backend,
  ) {
    if (backend == 'codex') {
      return const [
        (
          'bypassPermissions',
          'Yolo',
          'Auto-approve except protected files',
          Icons.speed,
        ),
        ('superYolo', 'Super Yolo', 'Auto-approve everything', Icons.flash_on),
        (
          'default',
          'Ask',
          'Ask before commands and file changes',
          Icons.shield_outlined,
        ),
        ('plan', 'Read Only', 'No commands or file writes', Icons.visibility),
      ];
    }
    return _permModes;
  }

  String _displayPermissionMode(String mode, String? backend) {
    if (backend == 'codex' && (mode == 'auto' || mode == 'acceptEdits')) {
      return 'default';
    }
    return mode;
  }

  _PermTheme? _permissionModeTheme(String mode) {
    switch (mode) {
      case 'plan':
        return const _PermTheme(Color(0xFF1A4D2E), Color(0xFFB8E6C8));
      case 'auto':
        return const _PermTheme(Color(0xFF1A3D4D), Color(0xFFA0D5E6));
      case 'acceptEdits':
        return const _PermTheme(Color(0xFF4D3D1A), Color(0xFFE6D5A0));
      case 'default':
        return const _PermTheme(Color(0xFF4D2A1A), Color(0xFFE6C0A0));
      case 'superYolo':
        return const _PermTheme(Color(0xFF4D1A3A), Color(0xFFE6A0C8));
      default:
        return null; // bypassPermissions — default theme
    }
  }

  _PermTheme _fastModeTheme() {
    return const _PermTheme(Color(0xFF641E1E), Color(0xFFFFC9C9));
  }

  IconData _permissionModeIcon(String mode) {
    for (final m in _permModes) {
      if (m.$1 == mode) return m.$4;
    }
    return Icons.speed;
  }

  String _permissionModeLabel(String mode, {String? backend}) {
    for (final m in _permissionModesForBackend(backend)) {
      if (m.$1 == mode) return m.$2;
    }
    return 'Yolo';
  }

  void _showPermissionModePicker(ChatProvider provider) {
    final mode = provider.permissionMode ?? 'bypassPermissions';
    final modes = _permissionModesForBackend(provider.activeSessionBackend);
    final displayMode = _displayPermissionMode(
      mode,
      provider.activeSessionBackend,
    );
    final RenderBox button = context.findRenderObject() as RenderBox;

    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        0,
        kToolbarHeight + MediaQuery.of(context).padding.top,
        button.size.width,
        0,
      ),
      items: [
        for (final entry in modes)
          PopupMenuItem(
            value: entry.$1,
            child: Row(
              children: [
                if (entry.$1 == displayMode)
                  Icon(
                    Icons.check,
                    size: 16,
                    color: Theme.of(context).colorScheme.primary,
                  )
                else
                  const SizedBox(width: 16),
                const SizedBox(width: 8),
                Icon(entry.$4, size: 16),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(entry.$2),
                      Text(
                        entry.$3,
                        style: TextStyle(
                          fontSize: 11,
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withAlpha(128),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    ).then((value) {
      if (value != null) provider.setPermissionMode(value);
    });
  }

  Widget _buildThinkingChip(ChatProvider provider) {
    final thinkingType = provider.thinking['type'] as String? ?? 'adaptive';
    IconData icon;
    Color color;
    String label;
    switch (thinkingType) {
      case 'enabled':
        icon = Icons.psychology_alt;
        color = Colors.purple.shade300;
        final budget = provider.thinking['budgetTokens'] as int?;
        label = budget != null ? 'Think ${(budget / 1000).round()}k' : 'Think';
        break;
      case 'disabled':
        icon = Icons.psychology_outlined;
        color = Theme.of(context).colorScheme.onSurfaceVariant;
        label = 'No Think';
        break;
      default: // adaptive
        icon = Icons.psychology;
        color = Theme.of(context).colorScheme.primary;
        label = 'Adaptive';
    }

    return PopupMenuButton<Map<String, dynamic>>(
      onSelected: (value) => provider.setThinking(value),
      tooltip: 'Thinking: $label',
      padding: EdgeInsets.zero,
      position: PopupMenuPosition.under,
      child: _buildChipBody(icon, label, iconColor: color),
      itemBuilder: (context) {
        final options = <MapEntry<String, Map<String, dynamic>>>[
          MapEntry('Adaptive', {'type': 'adaptive'}),
          MapEntry('Extended (10k)', {
            'type': 'enabled',
            'budgetTokens': 10000,
          }),
          MapEntry('Extended (50k)', {
            'type': 'enabled',
            'budgetTokens': 50000,
          }),
          MapEntry('Disabled', {'type': 'disabled'}),
        ];
        return options.map((opt) {
          final isSelected =
              opt.value['type'] == thinkingType &&
              (opt.value['type'] != 'enabled' ||
                  opt.value['budgetTokens'] ==
                      provider.thinking['budgetTokens']);
          return PopupMenuItem(
            value: opt.value,
            child: Row(
              children: [
                if (isSelected)
                  Icon(
                    Icons.check,
                    size: 16,
                    color: Theme.of(context).colorScheme.primary,
                  )
                else
                  const SizedBox(width: 16),
                const SizedBox(width: 8),
                Text(opt.key),
              ],
            ),
          );
        }).toList();
      },
    );
  }

  String _formatTokenCount(int tokens) {
    if (tokens >= 1000000) return '${(tokens / 1000000).toStringAsFixed(1)}M';
    if (tokens >= 1000) return '${(tokens / 1000).toStringAsFixed(1)}k';
    return tokens.toString();
  }

  Widget _buildUsageIndicator(Map<String, dynamic> usage) {
    final inputTokens = (usage['inputTokens'] as num?)?.toInt() ?? 0;
    final outputTokens = (usage['outputTokens'] as num?)?.toInt() ?? 0;
    final cacheRead = (usage['cacheReadTokens'] as num?)?.toInt() ?? 0;
    final cacheCreate = (usage['cacheCreateTokens'] as num?)?.toInt() ?? 0;
    final contextWindow = (usage['contextWindow'] as num?)?.toInt() ?? 0;
    // Total context = uncached input + cache read + cache create (what was sent to the API)
    final totalContext = inputTokens + cacheRead + cacheCreate;

    // Context fill ratio
    final fillRatio = contextWindow > 0 ? totalContext / contextWindow : 0.0;
    final fillColor = fillRatio > 0.8
        ? Colors.red.shade300
        : fillRatio > 0.5
        ? Colors.orange.shade300
        : Theme.of(context).colorScheme.onSurface.withAlpha(178);

    return GestureDetector(
      onTap: () => _showContextDialog(usage),
      child: Padding(
        padding: const EdgeInsets.only(right: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.token, size: 14, color: fillColor),
            const SizedBox(width: 3),
            Text(
              _formatTokenCount(totalContext),
              style: TextStyle(fontSize: 11, color: fillColor),
            ),
            if (contextWindow > 0) ...[
              Text(
                ' / ${_formatTokenCount(contextWindow)}',
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).colorScheme.onSurface.withAlpha(102),
                ),
              ),
            ],
            if (outputTokens > 0) ...[
              const SizedBox(width: 6),
              Icon(
                Icons.arrow_upward,
                size: 10,
                color: const Color(0xFFCBA6F7),
              ),
              Text(
                _formatTokenCount(outputTokens),
                style: const TextStyle(fontSize: 11, color: Color(0xFFCBA6F7)),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _showContextDialog(Map<String, dynamic> usage) async {
    final provider = context.read<ChatProvider>();
    Map<String, dynamic>? codexStatus = provider.codexStatus;
    if (provider.activeSessionBackend == 'codex') {
      final navigator = Navigator.of(context, rootNavigator: true);
      var loadingOpen = true;
      unawaited(
        showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (dlgCtx) => AlertDialog(
            content: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 14),
                Flexible(
                  child: Text(
                    'Loading Codex status...',
                    style: TextStyle(
                      color: Theme.of(dlgCtx).colorScheme.onSurface,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ).whenComplete(() => loadingOpen = false),
      );
      codexStatus = await provider.requestCodexStatus() ?? codexStatus;
      if (!mounted) return;
      if (loadingOpen) {
        navigator.pop();
      }
    }
    final ctx = provider.contextUsage;
    final inputTokens = (usage['inputTokens'] as num?)?.toInt() ?? 0;
    final outputTokens = (usage['outputTokens'] as num?)?.toInt() ?? 0;
    final cacheRead = (usage['cacheReadTokens'] as num?)?.toInt() ?? 0;
    final cacheCreate = (usage['cacheCreateTokens'] as num?)?.toInt() ?? 0;
    final numTurns = (usage['numTurns'] as num?)?.toInt();
    final stopReason = usage['stopReason'] as String?;
    final resultSubtype = usage['resultSubtype'] as String?;

    // Use SDK context usage if available, fall back to basic usage data
    final totalTokens =
        (ctx?['totalTokens'] as num?)?.toInt() ??
        (inputTokens + cacheRead + cacheCreate);
    final maxTokens =
        (ctx?['maxTokens'] as num?)?.toInt() ??
        (usage['contextWindow'] as num?)?.toInt() ??
        0;
    final fillRatio = maxTokens > 0 ? totalTokens / maxTokens : 0.0;
    final freeTokens = maxTokens > totalTokens ? maxTokens - totalTokens : 0;
    final model = ctx?['model'] as String?;

    // Build segments from SDK categories if available, else basic breakdown
    final segments = <_BarSegment>[];
    final categories = ctx?['categories'] as List?;
    if (categories != null && categories.isNotEmpty) {
      for (final cat in categories) {
        final name = cat['name'] as String? ?? '';
        final tokens = (cat['tokens'] as num?)?.toInt() ?? 0;
        final colorHex = cat['color'] as String? ?? '#888888';
        if (tokens <= 0) continue;
        // Parse hex color
        final colorVal =
            int.tryParse(colorHex.replaceFirst('#', 'FF'), radix: 16) ??
            0xFF888888;
        segments.add(_BarSegment(name, tokens, Color(colorVal)));
      }
    } else {
      if (cacheRead > 0) {
        segments.add(_BarSegment('Cached', cacheRead, const Color(0xFF89B4FA)));
      }
      if (cacheCreate > 0) {
        segments.add(
          _BarSegment('New cache', cacheCreate, const Color(0xFFA6E3A1)),
        );
      }
      if (inputTokens > 0) {
        segments.add(
          _BarSegment('Uncached', inputTokens, const Color(0xFFF9E2AF)),
        );
      }
    }
    if (freeTokens > 0) {
      segments.add(_BarSegment('Free', freeTokens, Colors.transparent));
    }

    // Message breakdown from SDK
    final msgBreakdown = ctx?['messageBreakdown'] as Map<String, dynamic>?;
    final autoCompactThreshold = (ctx?['autoCompactThreshold'] as num?)
        ?.toInt();
    final isAutoCompact = ctx?['isAutoCompactEnabled'] == true;

    final theme = Theme.of(context);

    showDialog(
      context: context,
      builder: (dlgCtx) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.donut_small, size: 20, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                model != null ? 'Context ($model)' : 'Context Window',
                style: const TextStyle(fontSize: 16),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Fill percentage headline
                Text(
                  maxTokens > 0
                      ? '${(fillRatio * 100).toStringAsFixed(0)}% used'
                      : 'No context data',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w600,
                    color: fillRatio > 0.8
                        ? Colors.red.shade300
                        : fillRatio > 0.5
                        ? Colors.orange.shade300
                        : theme.colorScheme.onSurface,
                  ),
                ),
                if (maxTokens > 0) ...[
                  const SizedBox(height: 4),
                  Text(
                    '${_formatTokenCount(totalTokens)} / ${_formatTokenCount(maxTokens)} tokens',
                    style: TextStyle(
                      fontSize: 13,
                      color: theme.colorScheme.onSurface.withAlpha(178),
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                // Stacked context bar
                if (maxTokens > 0)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: SizedBox(
                      height: 24,
                      child: Row(
                        children: segments.map((seg) {
                          final ratio = seg.tokens / maxTokens;
                          if (ratio <= 0) return const SizedBox.shrink();
                          return Expanded(
                            flex: (ratio * 1000).round().clamp(1, 1000),
                            child: Container(
                              color: seg.color == Colors.transparent
                                  ? theme.colorScheme.surfaceContainerHighest
                                  : seg.color,
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                  ),
                // Auto-compact threshold indicator
                if (isAutoCompact &&
                    autoCompactThreshold != null &&
                    maxTokens > 0) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Auto-compact at ${(autoCompactThreshold / maxTokens * 100).toStringAsFixed(0)}%',
                    style: TextStyle(
                      fontSize: 11,
                      color: theme.colorScheme.onSurface.withAlpha(128),
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                // Category legend
                ...segments
                    .where((s) => s.color != Colors.transparent)
                    .map(
                      (seg) => _contextLegendRow(
                        seg.label,
                        seg.tokens,
                        seg.color,
                        theme,
                      ),
                    ),
                // Output tokens
                _contextLegendRow(
                  'Output',
                  outputTokens,
                  const Color(0xFFCBA6F7),
                  theme,
                ),
                // Free space
                if (freeTokens > 0)
                  _contextLegendRow('Free', freeTokens, null, theme),

                // Message breakdown (from SDK detailed context)
                if (msgBreakdown != null) ...[
                  const Divider(height: 24),
                  Text(
                    'Message Breakdown',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.onSurface.withAlpha(200),
                    ),
                  ),
                  const SizedBox(height: 8),
                  if ((msgBreakdown['userMessageTokens'] as num?)?.toInt() !=
                      null)
                    _contextDetailRow(
                      'User messages',
                      _formatTokenCount(
                        (msgBreakdown['userMessageTokens'] as num).toInt(),
                      ),
                      theme,
                    ),
                  if ((msgBreakdown['assistantMessageTokens'] as num?)
                          ?.toInt() !=
                      null)
                    _contextDetailRow(
                      'Assistant messages',
                      _formatTokenCount(
                        (msgBreakdown['assistantMessageTokens'] as num).toInt(),
                      ),
                      theme,
                    ),
                  if ((msgBreakdown['toolCallTokens'] as num?)?.toInt() != null)
                    _contextDetailRow(
                      'Tool calls',
                      _formatTokenCount(
                        (msgBreakdown['toolCallTokens'] as num).toInt(),
                      ),
                      theme,
                    ),
                  if ((msgBreakdown['toolResultTokens'] as num?)?.toInt() !=
                      null)
                    _contextDetailRow(
                      'Tool results',
                      _formatTokenCount(
                        (msgBreakdown['toolResultTokens'] as num).toInt(),
                      ),
                      theme,
                    ),
                  if ((msgBreakdown['attachmentTokens'] as num?)?.toInt() !=
                          null &&
                      (msgBreakdown['attachmentTokens'] as num).toInt() > 0)
                    _contextDetailRow(
                      'Attachments',
                      _formatTokenCount(
                        (msgBreakdown['attachmentTokens'] as num).toInt(),
                      ),
                      theme,
                    ),
                ],

                // MCP tools
                if (ctx?['mcpTools'] != null &&
                    (ctx!['mcpTools'] as List).isNotEmpty) ...[
                  const Divider(height: 24),
                  Text(
                    'MCP Tools',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.onSurface.withAlpha(200),
                    ),
                  ),
                  const SizedBox(height: 8),
                  ...(ctx['mcpTools'] as List)
                      .where((t) => ((t['tokens'] as num?)?.toInt() ?? 0) > 0)
                      .map(
                        (tool) => _contextDetailRow(
                          '${tool['serverName']}: ${tool['name']}',
                          _formatTokenCount((tool['tokens'] as num).toInt()),
                          theme,
                        ),
                      ),
                ],

                if (codexStatus != null) ...[
                  const Divider(height: 24),
                  _buildCodexStatusContextSection(codexStatus, theme),
                ],

                const Divider(height: 24),
                // Metadata
                if (numTurns != null)
                  _contextDetailRow('Turns', '$numTurns', theme),
                if (stopReason != null)
                  _contextDetailRow('Stop reason', stopReason, theme),
                if (resultSubtype != null && resultSubtype.startsWith('error_'))
                  _contextDetailRow(
                    'Result',
                    resultSubtype.replaceAll('_', ' '),
                    theme,
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dlgCtx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Widget _contextLegendRow(
    String label,
    int tokens,
    Color? color,
    ThemeData theme,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              color: color ?? theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(2),
              border: color == null
                  ? Border.all(
                      color: theme.colorScheme.outlineVariant,
                      width: 1,
                    )
                  : null,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(label, style: const TextStyle(fontSize: 13))),
          Text(
            _formatTokenCount(tokens),
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: theme.colorScheme.onSurface.withAlpha(178),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCodexStatusContextSection(
    Map<String, dynamic> status,
    ThemeData theme,
  ) {
    final config = status['config'] is Map
        ? Map<String, dynamic>.from(status['config'] as Map)
        : <String, dynamic>{};
    final limits = status['limits'] is List
        ? status['limits'] as List
        : const [];
    final usage = status['usage'] is Map
        ? Map<String, dynamic>.from(status['usage'] as Map)
        : <String, dynamic>{};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Codex Account',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: theme.colorScheme.onSurface.withAlpha(200),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _contextPill(
              'Model',
              config['model']?.toString() ?? 'default',
              theme,
            ),
            _contextPill(
              'Effort',
              config['effort']?.toString() ?? 'default',
              theme,
            ),
            if ((config['serviceTier']?.toString() ?? '').isNotEmpty)
              _contextPill('Tier', config['serviceTier'].toString(), theme),
          ],
        ),
        if (limits.isNotEmpty) ...[
          const SizedBox(height: 12),
          ...limits.map(
            (limit) => _contextLimitBlock(
              Map<String, dynamic>.from(limit as Map),
              theme,
            ),
          ),
        ],
        if (usage.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _contextPill(
                'Today',
                _formatContextNumber(usage['todayTokens']),
                theme,
              ),
              _contextPill(
                'Lifetime',
                _formatContextNumber(usage['lifetimeTokens']),
                theme,
              ),
              _contextPill(
                'Peak day',
                _formatContextNumber(usage['peakDailyTokens']),
                theme,
              ),
              _contextPill(
                'Streak',
                '${usage['currentStreakDays'] ?? 'unknown'}d',
                theme,
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _contextLimitBlock(Map<String, dynamic> limit, ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            limit['label']?.toString() ?? 'Codex',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 4),
          _contextLimitBar('5h', limit['primary'], theme),
          const SizedBox(height: 4),
          _contextLimitBar('Weekly', limit['secondary'], theme),
        ],
      ),
    );
  }

  Widget _contextLimitBar(String label, dynamic raw, ThemeData theme) {
    if (raw is! Map) return const SizedBox.shrink();
    final data = Map<String, dynamic>.from(raw);
    final pct = (data['usedPercent'] as num?)?.toDouble();
    final value = pct == null ? 0.0 : (pct / 100).clamp(0.0, 1.0);
    final reset = data['resetLabel']?.toString() ?? '';
    final window = data['window']?.toString() ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              '$label ${pct?.round() ?? 0}%',
              style: TextStyle(
                fontSize: 11,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const Spacer(),
            Flexible(
              child: Text(
                [window, if (reset.isNotEmpty) 'resets $reset'].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: TextStyle(
                  fontSize: 10,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 3),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: value,
            minHeight: 6,
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
            valueColor: AlwaysStoppedAnimation<Color>(
              value >= 0.85
                  ? theme.colorScheme.error
                  : theme.colorScheme.tertiary,
            ),
          ),
        ),
      ],
    );
  }

  Widget _contextPill(String label, String value, ThemeData theme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        '$label: $value',
        style: TextStyle(
          fontSize: 11,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  String _formatContextNumber(dynamic value) {
    final n = value is num
        ? value.toDouble()
        : double.tryParse(value?.toString() ?? '');
    if (n == null || n.isNaN) return 'unknown';
    if (n >= 1000000000) return '${(n / 1000000000).toStringAsFixed(1)}B';
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}K';
    return n.round().toString();
  }

  Widget _contextDetailRow(String label, String value, ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: theme.colorScheme.onSurface.withAlpha(128),
            ),
          ),
          const Spacer(),
          Text(value, style: const TextStyle(fontSize: 12)),
        ],
      ),
    );
  }

  Widget _buildConnectionIndicator(ConnectionStatus status) {
    Color color;
    String tooltip;
    switch (status) {
      case ConnectionStatus.connected:
        color = Colors.green;
        tooltip = 'Connected';
        break;
      case ConnectionStatus.connecting:
        color = Colors.orange;
        tooltip = 'Connecting...';
        break;
      case ConnectionStatus.disconnected:
        color = Colors.grey;
        tooltip = 'Disconnected';
        break;
      case ConnectionStatus.error:
        color = Colors.red;
        tooltip = 'Connection error';
        break;
    }

    return Padding(
      padding: const EdgeInsets.only(right: 12),
      child: Tooltip(
        message: tooltip,
        child: Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
      ),
    );
  }

  Future<void> _showVoicePicker(
    BuildContext context,
    ChatProvider provider,
  ) async {
    // Ensure voices are loaded
    await provider.initTtsVoices();
    if (!context.mounted) return;

    final voices = provider.ttsVoices;
    if (voices.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No voices available on this device')),
      );
      return;
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return DraggableScrollableSheet(
          initialChildSize: 0.5,
          minChildSize: 0.3,
          maxChildSize: 0.8,
          expand: false,
          builder: (_, scrollController) {
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    'Select Voice',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: ListView.builder(
                    controller: scrollController,
                    itemCount: voices.length,
                    itemBuilder: (_, i) {
                      final voice = voices[i];
                      final isSelected = voice == provider.selectedTtsVoice;
                      return ListTile(
                        title: Text(
                          voice.name,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: isSelected
                                ? FontWeight.bold
                                : FontWeight.normal,
                          ),
                        ),
                        subtitle: Text(
                          voice.locale,
                          style: const TextStyle(fontSize: 12),
                        ),
                        trailing: isSelected
                            ? Icon(
                                Icons.check,
                                color: Theme.of(context).colorScheme.primary,
                              )
                            : null,
                        onTap: () {
                          provider.setTtsVoice(voice);
                          Navigator.pop(ctx);
                        },
                        onLongPress: () {
                          provider.previewTtsVoice(voice);
                        },
                      );
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    'Long-press a voice to preview',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurface.withAlpha(128),
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _showKokoroVoicePicker(BuildContext context, ChatProvider provider) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Kokoro Voice',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            const Divider(height: 1),
            ...kokoroVoices.map((voice) {
              final isSelected =
                  provider.selectedTtsEngineVoice?.id == voice.id;
              return ListTile(
                title: Text(
                  voice.name,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: isSelected
                        ? FontWeight.bold
                        : FontWeight.normal,
                  ),
                ),
                trailing: isSelected
                    ? Icon(
                        Icons.check,
                        color: Theme.of(context).colorScheme.primary,
                      )
                    : null,
                onTap: () {
                  provider.setKokoroVoice(voice);
                  Navigator.pop(ctx);
                },
                onLongPress: () => provider.previewKokoroVoice(voice),
              );
            }),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                'Long-press a voice to preview',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurface.withAlpha(128),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// Derive a friendly model name from the model ID value.
  /// e.g. "claude-sonnet-4-5-20250929" -> "Sonnet 4.5"
  ///      "claude-opus-4-6" -> "Opus 4.6"
  ///      "claude-haiku-4-5-20251001" -> "Haiku 4.5"
  String _modelName(String modelId) {
    // Strip "claude-" prefix
    var s = modelId.replaceFirst(RegExp(r'^claude-'), '');
    // Strip date suffix (e.g. "-20250929")
    s = s.replaceFirst(RegExp(r'-\d{8}$'), '');
    // Parse family and version: "sonnet-4-5" -> family=sonnet, major=4, minor=5
    final match = RegExp(r'^(\w+)-(\d+)-(\d+)').firstMatch(s);
    if (match != null) {
      final family = match.group(1)!;
      final major = match.group(2)!;
      final minor = match.group(3)!;
      return '${family[0].toUpperCase()}${family.substring(1)} $major.$minor';
    }
    // Fallback: just capitalize
    if (s.isNotEmpty) return s[0].toUpperCase() + s.substring(1);
    return modelId;
  }

  Widget _buildCompactingBanner() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: Theme.of(context).colorScheme.tertiaryContainer,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Theme.of(context).colorScheme.onTertiaryContainer,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            'Compacting context...',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: Theme.of(context).colorScheme.onTertiaryContainer,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRateLimitBanner(ChatProvider provider) {
    final util = provider.rateLimitUtilization;
    final pct = util != null ? ' (${(util * 100).toStringAsFixed(0)}%)' : '';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: Theme.of(context).colorScheme.errorContainer,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.speed,
            size: 14,
            color: Theme.of(context).colorScheme.onErrorContainer,
          ),
          const SizedBox(width: 8),
          Text(
            'Rate limited$pct',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: Theme.of(context).colorScheme.onErrorContainer,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRetryingBanner() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: Theme.of(context).colorScheme.secondaryContainer,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Theme.of(context).colorScheme.onSecondaryContainer,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            'Retrying API call...',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: Theme.of(context).colorScheme.onSecondaryContainer,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHookBanner(String hookName) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: Theme.of(context).colorScheme.tertiaryContainer,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Theme.of(context).colorScheme.onTertiaryContainer,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            'Running hook: $hookName',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: Theme.of(context).colorScheme.onTertiaryContainer,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCommandPicker(ChatProvider provider, ThemeData theme) {
    final commands = provider.slashCommands;
    final filtered = _commandFilter.isEmpty
        ? commands
        : commands.where((c) {
            final name = _slashName(c).toLowerCase();
            final desc = _slashDescription(c).toLowerCase();
            return name.contains(_commandFilter) ||
                desc.contains(_commandFilter);
          }).toList();

    if (filtered.isEmpty) return const SizedBox.shrink();

    return Container(
      constraints: const BoxConstraints(maxHeight: 200),
      margin: const EdgeInsets.only(bottom: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withAlpha(76),
        ),
      ),
      child: ListView.builder(
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(vertical: 4),
        itemCount: filtered.length,
        itemBuilder: (context, index) {
          final cmd = filtered[index];
          final name = _slashName(cmd);
          final desc = _slashDescription(cmd);
          final argHint = _slashArgumentHint(cmd);
          final agent = _slashAgent(cmd);
          final kind = _slashKind(cmd);
          final isSkill = kind == 'skill';
          final badgeColor = isSkill
              ? Colors.green
              : agent == 'codex'
              ? theme.colorScheme.tertiary
              : theme.colorScheme.primary;
          return InkWell(
            onTap: () => _insertSlashCommand(cmd),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(
                children: [
                  Text(
                    '/$name',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                      color: theme.colorScheme.primary,
                      fontFamily: 'monospace',
                    ),
                  ),
                  if (argHint.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    Text(
                      argHint,
                      style: TextStyle(
                        fontSize: 11,
                        color: theme.colorScheme.onSurface.withAlpha(128),
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ],
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      desc,
                      style: TextStyle(
                        fontSize: 11,
                        color: theme.colorScheme.onSurface.withAlpha(178),
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: badgeColor.withAlpha(22),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      isSkill ? 'Skill' : 'Command',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: badgeColor.withAlpha(220),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildInputBar(ChatProvider provider) {
    final theme = Theme.of(context);

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
          top: BorderSide(
            color: theme.colorScheme.outlineVariant.withAlpha(76),
          ),
        ),
      ),
      padding: EdgeInsets.only(
        left: 8,
        right: 8,
        top: 8,
        bottom: MediaQuery.of(context).viewInsets.bottom > 0
            ? 8
            : MediaQuery.of(context).padding.bottom + 8,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (provider.hasAttachment) _buildComposerAttachments(provider),
          // Slash command picker
          if (_showCommandPicker && provider.slashCommands.isNotEmpty)
            _buildCommandPicker(provider, theme),
          // Prompt suggestions shown as hint text (see TextField hintText below)
          // Input area
          // In PTT mode with keyboard hidden: large centered mic button above input row
          if (provider.pushToTalk &&
              MediaQuery.of(context).viewInsets.bottom == 0) ...[
            Center(
              child: Listener(
                onPointerDown: (_) {
                  _startPushToTalk(provider);
                },
                onPointerUp: (_) {
                  _stopPushToTalk(provider);
                },
                onPointerCancel: (_) {
                  _stopPushToTalk(provider);
                },
                child: Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: provider.isListening
                        ? Colors.red
                        : theme.colorScheme.primaryContainer,
                  ),
                  child: Icon(
                    provider.isListening ? Icons.mic : Icons.mic_none,
                    size: 36,
                    color: provider.isListening
                        ? Colors.white
                        : theme.colorScheme.onPrimaryContainer,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
          ],
          // Input row — always shown, with inline PTT button when keyboard is up
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (provider.pushToTalk &&
                  MediaQuery.of(context).viewInsets.bottom > 0)
                // Inline PTT button when keyboard is showing
                SizedBox(
                  height: 48,
                  child: Center(
                    child: Listener(
                      onPointerDown: (_) {
                        _startPushToTalk(provider);
                      },
                      onPointerUp: (_) {
                        _stopPushToTalk(provider);
                      },
                      onPointerCancel: (_) {
                        _stopPushToTalk(provider);
                      },
                      child: Container(
                        width: 40,
                        height: 40,
                        margin: const EdgeInsets.only(right: 4),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: provider.isListening
                              ? Colors.red
                              : theme.colorScheme.primaryContainer,
                        ),
                        child: Icon(
                          provider.isListening ? Icons.mic : Icons.mic_none,
                          size: 20,
                          color: provider.isListening
                              ? Colors.white
                              : theme.colorScheme.onPrimaryContainer,
                        ),
                      ),
                    ),
                  ),
                )
              else if (!provider.pushToTalk)
                SizedBox(
                  height: 48,
                  child: Center(
                    child: VoiceButton(
                      isListening: provider.isListening,
                      onPressed: () => provider.toggleListening(
                        existingText: _textController.text,
                      ),
                    ),
                  ),
                ),
              SizedBox(
                height: 48,
                child: Center(
                  child: IconButton(
                    icon: Icon(
                      Icons.attach_file,
                      color: theme.colorScheme.onSurface.withAlpha(178),
                      size: 22,
                    ),
                    onPressed: () => _showAttachmentMenu(provider),
                    padding: const EdgeInsets.all(8),
                    constraints: const BoxConstraints(
                      minWidth: 40,
                      minHeight: 40,
                    ),
                  ),
                ),
              ),
              Expanded(
                child: TextField(
                  controller: _textController,
                  focusNode: _focusNode,
                  decoration: InputDecoration(
                    hintText: provider.promptSuggestions.isNotEmpty
                        ? provider.promptSuggestions.first
                        : 'Type a message...',
                    hintMaxLines: 2,
                    filled: true,
                    fillColor: theme.colorScheme.surfaceContainerHighest,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
                    isDense: true,
                  ),
                  maxLines: 5,
                  minLines: 1,
                  textInputAction: TextInputAction.newline,
                ),
              ),
              const SizedBox(width: 4),
              if (provider.isProcessing) ...[
                // Send with priority: tap = next, long-press = popup menu
                SizedBox(
                  height: 48,
                  child: Center(
                    child: GestureDetector(
                      onTap: () => _sendMessage(provider, priority: 'next'),
                      onLongPressStart: (details) {
                        _showPriorityMenu(
                          context,
                          details.globalPosition,
                          provider,
                          theme,
                        );
                      },
                      child: Container(
                        width: 40,
                        height: 40,
                        alignment: Alignment.center,
                        child: Icon(
                          Icons.send,
                          color: theme.colorScheme.secondary,
                        ),
                      ),
                    ),
                  ),
                ),
                SizedBox(
                  height: 48,
                  child: Center(
                    child: IconButton(
                      icon: Icon(
                        Icons.stop_circle,
                        color: theme.colorScheme.error,
                      ),
                      onPressed: () => provider.abortQuery(),
                      padding: const EdgeInsets.all(8),
                      constraints: const BoxConstraints(
                        minWidth: 40,
                        minHeight: 40,
                      ),
                    ),
                  ),
                ),
              ] else
                SizedBox(
                  height: 48,
                  child: Center(
                    child: IconButton(
                      icon: Icon(Icons.send, color: theme.colorScheme.primary),
                      onPressed: () => _sendMessage(provider),
                      padding: const EdgeInsets.all(8),
                      constraints: const BoxConstraints(
                        minWidth: 40,
                        minHeight: 40,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PermTheme {
  final Color barColor;
  final Color textColor;
  const _PermTheme(this.barColor, this.textColor);
}
