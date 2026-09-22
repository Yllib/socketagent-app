import 'dart:io';
import '../services/desktop_composer_keys.dart';
import '../services/desktop_workspace_controller.dart';
import '../widgets/desktop_split_view.dart';
import '../widgets/adaptive_control_bar.dart';
import '../widgets/claude_account_usage.dart';
import '../widgets/context_window_breakdown.dart';
import '../widgets/codex_account_usage.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/session_panel_preferences.dart';
import '../services/pending_panel_hides.dart';
import '../widgets/panel_hide_notice.dart';
import '../main.dart' show assistVoiceTrigger;
import '../services/chat_provider.dart';
import '../services/tts_engine.dart';
import '../services/kokoro_server_engine.dart';
import '../services/websocket_service.dart';
import '../models/harness_rate_limit.dart';
import '../models/active_browser_session.dart';
import 'file_manager_screen.dart';
import 'browser_session_screen.dart';
import 'project_instructions_screen.dart';
import 'terminal_screen.dart';
import 'settings/voice_speech_screen.dart';
import '../widgets/chat_view.dart';
import '../widgets/conversation_rewind_notice.dart';
import '../widgets/active_tasks_pane.dart';
import '../widgets/active_browser_strip.dart';
import '../widgets/session_actions_sheet.dart';
import '../widgets/voice_button.dart';
import '../widgets/secret_manager_sheet.dart';
import '../widgets/html_plan_manager_sheet.dart';
import '../widgets/tts_playback_bar.dart';
import '../widgets/codex_goal_manager_sheet.dart';
import '../services/work_review_repository.dart';
import 'work_reviews_screen.dart';
import 'session_analytics_screen.dart';
import 'session_memory_screen.dart';

/// One row of the context dialog, optionally opening onto its own rows.
///
/// Used for both the legend (swatch and share of the fill) and the plain
/// rows under it. A category's breakdown belongs here, under the category,
/// rather than in a separate block further down repeating its name.
class _ContextRow extends StatefulWidget {
  const _ContextRow({
    required this.label,
    required this.value,
    this.color,
    this.share,
    this.children = const [],
  });

  final String label;
  final String value;

  /// Legend swatch, matching this category's segment in the bar.
  final Color? color;

  /// Percent of the bar's filled part, for legend rows.
  final double? share;

  final List<Widget> children;

  @override
  State<_ContextRow> createState() => _ContextRowState();
}

class _ContextRowState extends State<_ContextRow> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isLegend = widget.color != null;
    final canExpand = widget.children.isNotEmpty;

    final row = Padding(
      padding: EdgeInsets.symmetric(vertical: isLegend ? 3 : 2),
      child: Row(
        children: [
          SizedBox(
            width: 18,
            child: canExpand
                ? Icon(
                    _expanded
                        ? Icons.keyboard_arrow_down
                        : Icons.keyboard_arrow_right,
                    size: 16,
                    color: theme.colorScheme.onSurface.withAlpha(150),
                  )
                : null,
          ),
          if (isLegend) ...[
            Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                color: widget.color,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Text(
              widget.label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: isLegend ? 13 : 12,
                color: isLegend
                    ? theme.colorScheme.onSurface
                    : theme.colorScheme.onSurface.withAlpha(178),
              ),
            ),
          ),
          Text(
            widget.value,
            style: TextStyle(
              fontSize: isLegend ? 13 : 12,
              fontWeight: isLegend ? FontWeight.w500 : FontWeight.normal,
              color: theme.colorScheme.onSurface.withAlpha(isLegend ? 178 : 200),
            ),
          ),
          if (widget.share != null)
            SizedBox(
              width: 44,
              child: Text(
                '${widget.share!.toStringAsFixed(0)}%',
                textAlign: TextAlign.right,
                style: TextStyle(
                  fontSize: 13,
                  color: theme.colorScheme.onSurface.withAlpha(128),
                ),
              ),
            ),
        ],
      ),
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        canExpand
            ? InkWell(
                onTap: () => setState(() => _expanded = !_expanded),
                child: row,
              )
            : row,
        if (_expanded)
          Padding(
            padding: const EdgeInsets.only(left: 18, bottom: 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: widget.children,
            ),
          ),
      ],
    );
  }
}

/// A block of context rows behind its own header.
///
/// Collapsed by default: all three run long enough to bury the bar and the
/// legend, which are what the dialog is for. The header carries the block's
/// total so the useful number reads without opening it, and opening it leads
/// with a line saying what the block is, because the row names alone did not
/// say.
class _ContextSection extends StatefulWidget {
  const _ContextSection({
    required this.title,
    required this.total,
    required this.hint,
    required this.children,
  });

  final String title;
  final String total;
  final String hint;
  final List<Widget> children;

  @override
  State<_ContextSection> createState() => _ContextSectionState();
}

class _ContextSectionState extends State<_ContextSection> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                Icon(
                  _expanded
                      ? Icons.keyboard_arrow_down
                      : Icons.keyboard_arrow_right,
                  size: 18,
                  color: theme.colorScheme.onSurface.withAlpha(150),
                ),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    widget.title,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.onSurface.withAlpha(200),
                    ),
                  ),
                ),
                const Spacer(),
                Text(
                  widget.total,
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.onSurface.withAlpha(150),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_expanded)
          Padding(
            padding: const EdgeInsets.only(left: 22, bottom: 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    widget.hint,
                    style: TextStyle(
                      fontSize: 11,
                      height: 1.35,
                      color: theme.colorScheme.onSurface.withAlpha(140),
                    ),
                  ),
                ),
                ...widget.children,
              ],
            ),
          ),
      ],
    );
  }
}

Future<void> openConversation(
  BuildContext context, {
  bool autoStartVoice = false,
}) async {
  if (Platform.isWindows) {
    context.read<DesktopWorkspaceController>().openConversation();
    Navigator.of(context).popUntil((route) => route.isFirst);
    return;
  }
  await Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => HomeScreen(autoStartVoice: autoStartVoice),
    ),
  );
}

class HomeScreen extends StatefulWidget {
  final bool autoStartVoice;

  final bool embedded;
  final bool visible;
  final bool sidebarVisible;
  final VoidCallback? onToggleSidebar;
  const HomeScreen({
    super.key,
    this.autoStartVoice = false,
    this.embedded = false,
    this.visible = true,
    this.sidebarVisible = false,
    this.onToggleSidebar,
  });

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
  bool _followLatest = true;
  SessionPanelPreferences? _panelPreferences;
  final _pendingPanelHides = PendingPanelHides();

  void _panelHidesChanged() {
    if (mounted) setState(() {});
  }

  bool _panelHiding(ChatProvider provider, SessionPanel panel) =>
      _pendingPanelHides.contains(
        provider.activeSessionServerId,
        provider.activeSessionId,
        panel,
      );

  Widget? _panelHideNotice(
    ChatProvider provider,
    SessionPanel panel,
    String label,
  ) {
    final server = provider.activeSessionServerId;
    final session = provider.activeSessionId;
    if (!_pendingPanelHides.contains(server, session, panel)) return null;
    return PanelHideNotice(
      label: label,
      onCancel: () => _pendingPanelHides.cancel(server, session, panel),
    );
  }

  bool _panelHidden(ChatProvider provider, SessionPanel panel) =>
      _panelPreferences?.isHidden(
        provider.activeSessionServerId,
        provider.activeSessionId,
        panel,
      ) ??
      false;

  void _setPanelHidden(ChatProvider provider, SessionPanel panel, bool hidden) {
    final preferences = _panelPreferences;
    final server = provider.activeSessionServerId;
    final session = provider.activeSessionId;
    if (preferences == null || server == null || session == null) return;
    if (hidden) {
      _pendingPanelHides.request(server, session, panel, () {
        unawaited(preferences.setHidden(server, session, panel, true));
      });
      return;
    }
    _pendingPanelHides.cancel(server, session, panel);
    setState(() {
      unawaited(
        preferences.setHidden(
          provider.activeSessionServerId,
          provider.activeSessionId,
          panel,
          hidden,
        ),
      );
    });
  }

  Future<void> _openBrowserSession(ActiveBrowserSession browser) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => BrowserSessionScreen(
          profile: browser.profile,
          label: browser.label,
          initialUrl: browser.url,
          browserWidth: browser.width,
          browserHeight: browser.height,
          serverId: browser.serverId,
          initialRuntimeRequired: browser.runtimeRequired,
        ),
      ),
    );
  }

  Future<void> _openActiveBrowser(List<ActiveBrowserSession> browsers) async {
    if (browsers.isEmpty) return;
    if (browsers.length == 1) {
      await _openBrowserSession(browsers.single);
      return;
    }
    final selected = await showModalBottomSheet<ActiveBrowserSession>(
      context: context,
      backgroundColor: Colors.black,
      builder: (sheetContext) => SafeArea(
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: browsers.length,
          itemBuilder: (_, index) {
            final browser = browsers[index];
            return ListTile(
              leading: const Icon(Icons.public),
              title: Text(browser.label),
              subtitle: Text(
                browser.url,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => Navigator.pop(sheetContext, browser),
            );
          },
        ),
      ),
    );
    if (selected != null && mounted) await _openBrowserSession(selected);
  }

  @override
  void initState() {
    super.initState();
    _pendingPanelHides.addListener(_panelHidesChanged);
    SharedPreferences.getInstance().then((preferences) {
      if (!mounted) return;
      setState(() => _panelPreferences = SessionPanelPreferences(preferences));
    });
    final provider = context.read<ChatProvider>();
    if (Platform.isWindows) {
      _focusNode.onKeyEvent = (focus, event) => handleDesktopComposerKey(
        event,
        context: focus.context!,
        controller: _textController,
        onSend: () => _sendMessage(
          provider,
          priority: provider.isProcessing ? 'next' : null,
        ),
      );
    }

    // Listen to speech results and fill text field
    _speechSub = provider.speech.onResult.listen((text) {
      if (!widget.visible) return;
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
    provider.setViewingSession(
      provider.activeSessionId,
      chatScreenVisible: widget.visible,
    );

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
    if (!widget.visible) return;
    startVoiceInput();
  }

  @override
  void didUpdateWidget(covariant HomeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.visible != widget.visible) {
      final provider = context.read<ChatProvider>();
      provider.setViewingSession(
        provider.activeSessionId,
        chatScreenVisible: widget.visible,
      );
      if (!widget.visible) _focusNode.unfocus();
    }
  }

  @override
  void dispose() {
    _pendingPanelHides.removeListener(_panelHidesChanged);
    _pendingPanelHides.dispose();
    // Save draft before disposing
    final provider = context.read<ChatProvider>();
    provider.saveDraft(_textController.text.trim());
    provider.setViewingSession(null, chatScreenVisible: false);
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
    // Keep the submitted prompt and its Working row on screen immediately.
    if (!_followLatest) {
      setState(() => _followLatest = true);
    }
    provider.sendPrompt(text, priority: priority);
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
            title: const Text('Interrupt'),
            subtitle: const Text(
              'Stop the running tool right now',
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
            title: const Text('Next step'),
            subtitle: const Text(
              'When the current tool finishes (default)',
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
              'Not until the whole task is done',
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
                            child: Text('This computer'),
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

  Widget _conversationLayout(Widget child) =>
      Platform.isWindows ? DesktopConversationWidth(child: child) : child;

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
          _followLatest = true;
          provider.setViewingSession(
            currentSessionId,
            chatScreenVisible: widget.visible,
          );
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
        final notificationFocus = provider.notificationTranscriptFocus;
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
              toolbarHeight: 64,
              automaticallyImplyLeading: !widget.embedded,
              leading: widget.embedded
                  ? IconButton(
                      tooltip: widget.sidebarVisible
                          ? 'Hide sessions'
                          : 'Show sessions',
                      icon: const Icon(Icons.view_sidebar_outlined),
                      onPressed: widget.onToggleSidebar,
                    )
                  : null,
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
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            _sessionHeaderTitle(provider, isPlan: isPlan),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: sessionTheme?.textColor,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 1),
                    Row(
                      children: [
                        Expanded(
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Flexible(
                                child: Text(
                                  _activeComputerName(provider),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
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
                              ),
                              const SizedBox(width: 6),
                              _buildHarnessBadge(
                                provider.activeSessionBackend,
                                sessionTheme?.textColor,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        if (provider.lastUsage != null)
                          _buildUsageIndicator(provider.lastUsage!),
                        _buildConnectionIndicator(provider.connectionStatus),
                      ],
                    ),
                    const SizedBox(height: 1),
                    Row(
                      children: [
                        if (provider.activeSessionId != null ||
                            provider.isPendingNewSession)
                          GestureDetector(
                            onTap: () => _showPermissionModePicker(provider),
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
                        if (provider.activeSessionCwd != null)
                          Expanded(
                            child: Tooltip(
                              message: provider.activeSessionCwd!,
                              child: Text(
                                _compactCwd(provider.activeSessionCwd!),
                                textAlign: TextAlign.right,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11,
                                  fontFamily: 'monospace',
                                  color:
                                      (sessionTheme?.textColor ??
                                              Theme.of(
                                                context,
                                              ).colorScheme.onSurface)
                                          .withAlpha(178),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            body: ColoredBox(
              color: chatSurfaceColor,
              child: _conversationLayout(
                Column(
                  children: [
                    if (provider.weeklyRateLimit != null)
                      _buildRateLimitBanner(provider.weeklyRateLimit!),
                    if (provider.fiveHourRateLimit != null)
                      _buildRateLimitBanner(provider.fiveHourRateLimit!),
                    if (provider.conversationRewindStatus != null)
                      ConversationRewindNotice(
                        status: provider.conversationRewindStatus!,
                        onDismiss: provider.dismissConversationRewindNotice,
                      ),
                    if (provider.activeSessionId != null ||
                        provider.isPendingNewSession)
                      _buildControlChips(provider),
                    if (_panelPreferences != null &&
                        !_panelHidden(provider, SessionPanel.browser) &&
                        provider.activeBrowserSessions.isNotEmpty)
                      ActiveBrowserStrip(
                        browsers: provider.activeBrowserSessions,
                        hidingNotice: _panelHideNotice(
                          provider,
                          SessionPanel.browser,
                          'browser',
                        ),
                        onHide: () => _setPanelHidden(
                          provider,
                          SessionPanel.browser,
                          true,
                        ),
                        onOpen: () => unawaited(
                          _openActiveBrowser(provider.activeBrowserSessions),
                        ),
                      ),
                    if (provider.ttsPlaybackState.visible)
                      TtsPlaybackBar(
                        state: provider.ttsPlaybackState,
                        onPause: () => unawaited(provider.pauseReplaySpeak()),
                        onResume: () => unawaited(provider.resumeReplaySpeak()),
                        onRestart: () =>
                            unawaited(provider.restartReplaySpeak()),
                        onSeek: (fraction) =>
                            unawaited(provider.seekReplaySpeak(fraction)),
                        onClose: () => unawaited(provider.closeReplaySpeak()),
                        speed:
                            provider.ttsEngineMode == TtsEngineMode.elevenLabs
                            ? provider.elevenLabsSpeechRate
                            : null,
                        onSpeedChanged:
                            provider.ttsEngineMode == TtsEngineMode.elevenLabs
                            ? (speed) => unawaited(
                                provider.setElevenLabsSpeechRate(speed),
                              )
                            : null,
                      ),
                    if (provider.isRefreshingHistory)
                      const LinearProgressIndicator(minHeight: 2),
                    Expanded(
                      child: ChatView(
                        key: _chatViewKey,
                        messages: provider.filteredMessages,
                        serverId: provider.activeSessionServerId,
                        sessionStorageKey:
                            '${provider.activeServerId ?? ''}:${provider.activeSessionId ?? ''}',
                        isProcessing: provider.isProcessing,
                        followLatest: _followLatest,
                        condensedToolUsage: provider.condensedToolUsage,
                        onFollowLatestChanged: (follow) {
                          if (_followLatest != follow) {
                            setState(() => _followLatest = follow);
                          }
                        },
                        processingElapsed: provider.currentPromptElapsed,
                        isCompacting: provider.isCompacting,
                        isLoadingHistory: provider.isLoadingHistory,
                        isLoadingMore: provider.isLoadingMore,
                        hasMoreHistory: provider.hasMoreHistory,
                        historyWindowRevision: provider.historyWindowRevision,
                        targetEntryId: notificationFocus?.entryId,
                        targetSessionSeq: notificationFocus?.sessionSeq,
                        onTranscriptTargetReached: notificationFocus == null
                            ? null
                            : () => provider.clearNotificationTranscriptFocus(
                                notificationFocus,
                              ),
                        todos: provider.todos,
                        onAnswer: provider.answerQuestion,
                        onSecureInputSubmit: provider.submitSecureInput,
                        onSecureInputUseStored:
                            provider.submitStoredSecureInput,
                        onSecureInputCancel: provider.cancelSecureInput,
                        availableSecrets: provider.secretInventory,
                        onLoadMore: provider.loadMoreHistory,
                        onStopTask: provider.stopTask,
                        onDismissTodos: () =>
                            _setPanelHidden(provider, SessionPanel.tasks, true),
                        showTodos:
                            _panelPreferences != null &&
                            !_panelHidden(provider, SessionPanel.tasks),
                        tasksHidingNotice: _panelHideNotice(
                          provider,
                          SessionPanel.tasks,
                          'tasks',
                        ),
                        codexPlanHidingNotice: _panelHideNotice(
                          provider,
                          SessionPanel.codexPlan,
                          'plan',
                        ),
                        showCodexPlan:
                            _panelPreferences != null &&
                            !_panelHidden(provider, SessionPanel.codexPlan),
                        onDismissCodexPlan: () => _setPanelHidden(
                          provider,
                          SessionPanel.codexPlan,
                          true,
                        ),
                        onDismissTodo: provider.dismissTodo,
                        onRewindConversation: provider.rewindConversation,
                        codexRewind: provider.activeSessionBackend == 'codex',
                        onBranch: provider.activeSessionBackend == 'codex'
                            ? null
                            : provider.branchFromMessage,
                        onRetractQueuedMessage: (messageId) {
                          final text = provider.retractQueuedMessage(messageId);
                          if (text == null) return;
                          _textController.text = text;
                          _textController.selection =
                              TextSelection.fromPosition(
                                TextPosition(offset: text.length),
                              );
                          provider.saveDraft(text.trim());
                          _focusNode.requestFocus();
                        },
                        onReadAloud: provider.replaySpeak,
                        onReportAiResponse: provider.reportAiResponse,
                        rawMode: provider.rawMode,
                        rawItems: provider.rawItems,
                        subagentTasks: provider.subagentTasks,
                        workflowTasks: provider.workflowTasks,
                        allMessages: provider.messages,
                      ),
                    ),
                    if (provider.isRetrying) _buildRetryingBanner(),
                    if (provider.backendAuthRecoveryMessage != null)
                      _buildBackendRecoveryBanner(
                        provider.backendAuthRecoveryMessage!,
                      ),
                    if (provider.activeHookName != null)
                      _buildHookBanner(provider.activeHookName!),
                    if (provider.activePaneTasks.isNotEmpty &&
                        _panelPreferences != null &&
                        !_panelHidden(provider, SessionPanel.activity))
                      ActiveTasksPane(
                        key: ValueKey((
                          'activity',
                          provider.activeSessionServerId,
                          provider.activeSessionId,
                        )),
                        sessionId: provider.activeSessionId,
                        onHide: () => _setPanelHidden(
                          provider,
                          SessionPanel.activity,
                          true,
                        ),
                        hidingNotice: _panelHideNotice(
                          provider,
                          SessionPanel.activity,
                          'activity',
                        ),
                        backgroundTasks: provider.backgroundTasks,
                        subagentTasks: provider.subagentTasks,
                        workflowTasks: provider.workflowTasks,
                        messages: provider.messages,
                        sourceServerId: provider.activeSessionServerId,
                        onStopTask: provider.stopTask,
                        onScrollToTask: (toolUseId) {
                          _chatViewKey.currentState?.scrollToTask(toolUseId);
                        },
                        onReadAloud: provider.replaySpeak,
                      ),
                    _buildInputBar(provider),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  String _sessionHeaderTitle(ChatProvider provider, {required bool isPlan}) {
    final title = provider.activeSessionTitle;
    final hasTitle = title != null && title.isNotEmpty && title != 'Untitled';
    final flags = <String>[];
    if (provider.activeSessionBackend == 'codex' && provider.codexFastMode) {
      flags.add('FAST');
    }
    if (isPlan) {
      flags.add(provider.activeSessionBackend == 'codex' ? 'READ' : 'PLAN');
    }
    if (provider.rawMode) flags.add('RAW');
    final suffix = flags.isEmpty ? '' : ' [${flags.join('·')}]';
    return (hasTitle ? title : 'SocketAgent') + suffix;
  }

  String _activeComputerName(ChatProvider provider) {
    final id = provider.activeSessionServerId;
    return provider.serverConfigs
            .where((server) => server.id == id)
            .firstOrNull
            ?.name ??
        provider.connMgr.activeConfig?.name ??
        'Computer';
  }

  Widget _buildHarnessBadge(String? backend, Color? foreground) {
    final isCodex = backend == 'codex';
    final color = isCodex ? const Color(0xFF89B4FA) : const Color(0xFFCBA6F7);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withAlpha(38),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withAlpha(105)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isCodex ? Icons.code : Icons.psychology_alt,
            size: 10,
            color: foreground ?? color,
          ),
          const SizedBox(width: 3),
          Text(
            isCodex ? 'Codex' : 'Claude',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: foreground ?? color,
            ),
          ),
        ],
      ),
    );
  }

  String _compactCwd(String cwd) {
    const maxLength = 42;
    if (cwd.length <= maxLength) return cwd;
    return '…${cwd.substring(cwd.length - maxLength + 1)}';
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
        child: AdaptiveControlBar(
          hasModel:
              provider.supportedModels.isNotEmpty ||
              provider.isLoadingNewSessionModels,
          children: [
            if (provider.supportedModels.isNotEmpty)
              _buildModelChip(provider)
            else if (provider.isLoadingNewSessionModels)
              _buildLoadingModelChip(),
            _buildEffortChip(provider),
            if (provider.activeSessionBackend != 'codex')
              _buildThinkingChip(provider),
            if (provider.rawMode)
              _buildChipBody(
                Icons.code,
                'RAW',
                iconColor: Colors.orange.shade300,
                labelColor: Colors.orange.shade300,
              ),
            _buildFollowLatestChip(),
            _buildSessionMoreChip(provider),
          ],
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
  }) => AdaptiveControlChip(
    icon: icon,
    label: label,
    iconColor: iconColor,
    labelColor: labelColor,
    active: active,
  );

  Widget _buildFollowLatestChip() {
    final theme = Theme.of(context);
    final following = _followLatest;
    return Tooltip(
      message: following
          ? 'Auto-scroll is on. Tap to turn it off.'
          : 'Auto-scroll is off. Tap to jump to the bottom and turn it on.',
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => setState(() => _followLatest = !following),
        child: _buildChipBody(
          Icons.vertical_align_bottom,
          'AUTO',
          active: following,
          iconColor: following
              ? theme.colorScheme.onPrimaryContainer
              : theme.colorScheme.onSurfaceVariant,
          labelColor: following
              ? theme.colorScheme.onPrimaryContainer
              : theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _buildLoadingModelChip() => const Tooltip(
    message: 'Loading models',
    child: AdaptiveControlChip(
      icon: Icons.hourglass_empty,
      label: 'Loading models',
      leading: SizedBox(
        width: 14,
        height: 14,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
    ),
  );

  Widget _buildSessionMoreChip(ChatProvider provider) {
    Offset? pointer;
    return Builder(
      builder: (buttonContext) => Tooltip(
        message: 'Session actions',
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTapDown: (details) => pointer = details.globalPosition,
          onTapCancel: () => pointer = null,
          onTap: () {
            final box = buttonContext.findRenderObject()! as RenderBox;
            final anchor =
                pointer ?? box.localToGlobal(Offset(0, box.size.height));
            pointer = null;
            unawaited(
              _showSessionActions(
                provider,
                anchor: Platform.isWindows ? anchor : null,
              ),
            );
          },
          child: _buildChipBody(Icons.more_horiz, 'More'),
        ),
      ),
    );
  }

  Future<void> _showSessionActions(
    ChatProvider provider, {
    Offset? anchor,
  }) async {
    final sessionId = provider.activeSessionId;
    final serverId = provider.activeSessionServerId;
    if (provider.activeSessionBackend == 'codex') {
      provider.requestCodexCollaborationModes();
    }
    final value = await showSessionActionsMenu(
      context: context,
      anchor: anchor,
      builder: (_) => StatefulBuilder(
        builder: (_, updateSheet) => ListenableBuilder(
          listenable: Listenable.merge([provider, _pendingPanelHides]),
          builder: (_, _) => _sessionActions(
            provider,
            onSettingChanged: (action) {
              if (!mounted ||
                  sessionId != provider.activeSessionId ||
                  serverId != provider.activeSessionServerId) {
                return;
              }
              _handleSessionAction(provider, action);
              updateSheet(() {});
            },
          ),
        ),
      ),
    );
    if (!mounted ||
        value == null ||
        sessionId != provider.activeSessionId ||
        serverId != provider.activeSessionServerId) {
      return;
    }
    _handleSessionAction(provider, value);
  }

  Widget _sessionActions(
    ChatProvider provider, {
    ValueChanged<String>? onSettingChanged,
  }) {
    final projectPath = _projectFilesPath(provider);
    final hasProject = projectPath != null && projectPath.isNotEmpty;
    final hasSession = provider.activeSessionId != null;
    final codex = provider.activeSessionBackend == 'codex';
    final serverId = provider.activeSessionServerId;
    final reviews = context.read<WorkReviewRepository>();
    final supportsReviews =
        serverId != null && reviews.supportsServer(serverId);
    final reviewCount = serverId == null ? 0 : reviews.pendingCount(serverId);
    final browserHiding = _panelHiding(provider, SessionPanel.browser);
    final planHiding = _panelHiding(provider, SessionPanel.codexPlan);
    final tasksHiding = _panelHiding(provider, SessionPanel.tasks);
    final activityHiding = _panelHiding(provider, SessionPanel.activity);
    final activityHidden =
        _panelHidden(provider, SessionPanel.activity) || activityHiding;
    final browserHidden =
        _panelHidden(provider, SessionPanel.browser) || browserHiding;
    final planHidden =
        _panelHidden(provider, SessionPanel.codexPlan) || planHiding;
    final tasksHidden =
        _panelHidden(provider, SessionPanel.tasks) || tasksHiding;
    return SessionActionsSheet(
      onSettingChanged: onSettingChanged,
      quickActions: [
        SessionAction(
          'project_files',
          'Files',
          Icons.folder_open_outlined,
          enabled: hasProject,
        ),
        SessionAction(
          'terminal',
          'Terminal',
          Icons.terminal,
          enabled: serverId != null,
        ),
        if (provider.activeBrowserSessions.isNotEmpty)
          const SessionAction('open_browser', 'Browser', Icons.public),
      ],
      groups: [
        SessionActionGroup(
          'Project tools',
          'Instructions and secure credentials',
          Icons.folder_outlined,
          [
            SessionAction(
              'project_instructions',
              'Project instructions',
              Icons.description_outlined,
              subtitle: 'AGENTS.md and CLAUDE.md',
              enabled: hasProject,
            ),
            const SessionAction(
              'manage_secrets',
              'Manage secrets',
              Icons.password_outlined,
            ),
          ],
        ),
        SessionActionGroup(
          'Plans & progress',
          'Plans, reviews, memory and activity',
          Icons.fact_check_outlined,
          [
            SessionAction(
              'manage_html_plans',
              'HTML plans',
              Icons.view_quilt_outlined,
              enabled: hasSession,
            ),
            if (codex)
              SessionAction(
                'manage_codex_goal',
                'Goal',
                Icons.flag_outlined,
                enabled: hasSession && provider.activeServerSupportsCodexGoals,
                subtitle: provider.activeServerSupportsCodexGoals
                    ? null
                    : 'Requires an updated computer',
              ),
            SessionAction(
              'work_reviews',
              'Work reviews',
              Icons.fact_check_outlined,
              enabled: supportsReviews,
              subtitle: reviewCount > 0 ? '$reviewCount awaiting review' : null,
            ),
            if (codex)
              SessionAction(
                'session_memory',
                'Session memory',
                Icons.memory_outlined,
                enabled:
                    hasSession && provider.activeServerSupportsSessionMemory,
              ),
            SessionAction(
              'session_analytics',
              'Session analytics',
              Icons.insights_outlined,
              enabled: hasSession,
            ),
          ],
        ),
        SessionActionGroup(
          'Voice & notifications',
          'Speech, voice and session alerts',
          Icons.volume_up_outlined,
          [
            SessionAction(
              'tts_toggle',
              'Text to speech',
              Icons.volume_up_outlined,
              selected: provider.ttsEnabled,
              subtitle: provider.ttsEnabled ? 'On' : 'Off',
            ),
            SessionAction(
              'tts_voice',
              'Voice',
              Icons.record_voice_over_outlined,
              subtitle: _selectedVoiceLabel(provider),
            ),
            if (hasSession)
              SessionAction(
                'notifications_toggle',
                'Session notifications',
                Icons.notifications_outlined,
                selected: provider.isNotifEnabled(provider.activeSessionId!),
                subtitle: provider.isNotifEnabled(provider.activeSessionId!)
                    ? 'On'
                    : 'Muted',
              ),
          ],
        ),
        SessionActionGroup(
          'Session settings',
          'Visible panels and agent behavior',
          Icons.tune,
          [
            SessionAction(
              browserHidden ? 'show_browser_strip' : 'hide_browser_strip',
              'Browser strip',
              Icons.public,
              selected: !browserHidden,
              enabled: hasSession && _panelPreferences != null,
              subtitle: browserHiding
                  ? 'Hiding… Tap to cancel'
                  : browserHidden
                  ? 'Hidden. Tap to show'
                  : 'Shown when a browser is active. Tap to hide',
            ),
            if (codex)
              SessionAction(
                planHidden ? 'show_codex_plan' : 'hide_codex_plan',
                'Codex plan',
                Icons.fact_check_outlined,
                selected: !planHidden,
                enabled: hasSession && _panelPreferences != null,
                subtitle: planHiding
                    ? 'Hiding… Tap to cancel'
                    : planHidden
                    ? 'Hidden. Tap to show'
                    : 'Shown. Tap to hide',
              ),
            SessionAction(
              tasksHidden ? 'show_tasks' : 'hide_tasks',
              'Tasks panel',
              Icons.checklist,
              selected: !tasksHidden,
              enabled: hasSession && _panelPreferences != null,
              subtitle: tasksHiding
                  ? 'Hiding… Tap to cancel'
                  : tasksHidden
                  ? 'Hidden. Tap to show'
                  : 'Shown. Tap to hide',
            ),
            SessionAction(
              activityHidden ? 'show_activity' : 'hide_activity',
              'Activity panel',
              Icons.account_tree_outlined,
              selected: !activityHidden,
              enabled: hasSession && _panelPreferences != null,
              subtitle: activityHiding
                  ? 'Hiding… Tap to cancel'
                  : activityHidden
                  ? 'Hidden. Tap to show'
                  : 'Agents and background work. Tap to hide',
            ),
            if (codex)
              SessionAction(
                'codex_fast_mode',
                'Fast mode',
                Icons.flash_on_outlined,
                selected: provider.codexFastMode,
                subtitle: provider.codexFastMode ? 'On' : 'Off',
              ),
            if (!codex)
              SessionAction(
                'claude_auto_compact',
                'Auto compact',
                Icons.memory_outlined,
                selected: provider.claudeAutoCompactEnabled,
                subtitle: provider.claudeAutoCompactEnabled ? 'On' : 'Off',
              ),
            if (!codex)
              SessionAction(
                'claude_auto_compact_window',
                'Auto-compact window',
                Icons.straighten_outlined,
                subtitle: provider.claudeAutoCompactWindowOverride == null
                    ? provider.claudeAutoCompactWindowEffective == null
                          ? 'Inherit model default'
                          : 'Inherit computer: ${provider.claudeAutoCompactWindowEffective} tokens'
                    : 'Session override: ${provider.claudeAutoCompactWindowOverride} tokens',
              ),
            if (codex)
              for (final mode in provider.codexCollaborationModes)
                SessionAction(
                  'codex_mode:${mode['id'] as String? ?? 'default'}',
                  mode['name'] as String? ??
                      _formatModeName(mode['id'] as String? ?? 'default'),
                  Icons.groups_outlined,
                  subtitle: 'Codex collaboration mode',
                  selected:
                      (mode['id'] as String? ?? 'default') ==
                      provider.codexCollaborationMode,
                ),
          ],
        ),
      ],
    );
  }

  void _handleSessionAction(ChatProvider provider, String value) {
    final projectPath = _projectFilesPath(provider);
    final serverId = provider.activeSessionServerId;
    if (value.startsWith('codex_mode:')) {
      provider.setCodexCollaborationMode(value.substring('codex_mode:'.length));
      return;
    }
    switch (value) {
      case 'hide_activity':
        _setPanelHidden(provider, SessionPanel.activity, true);
        break;
      case 'show_activity':
        _setPanelHidden(provider, SessionPanel.activity, false);
        break;
      case 'hide_tasks':
        _setPanelHidden(provider, SessionPanel.tasks, true);
        break;
      case 'show_tasks':
        _setPanelHidden(provider, SessionPanel.tasks, false);
        break;
      case 'open_browser':
        unawaited(_openActiveBrowser(provider.activeBrowserSessions));
        break;
      case 'hide_browser_strip':
        _setPanelHidden(provider, SessionPanel.browser, true);
        break;
      case 'hide_codex_plan':
        _setPanelHidden(provider, SessionPanel.codexPlan, true);
        break;
      case 'show_browser_strip':
        _setPanelHidden(provider, SessionPanel.browser, false);
        break;
      case 'show_codex_plan':
        _setPanelHidden(provider, SessionPanel.codexPlan, false);
        break;
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
      case 'manage_codex_goal':
        Future.microtask(() {
          if (mounted) showCodexGoalManagerSheet(context, provider);
        });
        break;
      case 'session_analytics':
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const SessionAnalyticsScreen()),
        );
        break;
      case 'session_memory':
        Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const SessionMemoryScreen()));
        break;
      case 'work_reviews':
        if (serverId != null) {
          final config = provider.serverConfigs
              .where((item) => item.id == serverId)
              .firstOrNull;
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => WorkReviewsScreen(
                serverId: serverId,
                serverLabel: config?.name,
              ),
            ),
          );
        }
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
          } else if (provider.ttsEngineMode == TtsEngineMode.elevenLabs) {
            unawaited(_showElevenLabsVoicePicker(context, provider));
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
      case 'claude_auto_compact_window':
        Future.microtask(() {
          if (mounted) _showClaudeAutoCompactWindowDialog(provider);
        });
        break;
    }
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
    if (provider.ttsEngineMode == TtsEngineMode.elevenLabs) {
      return provider.selectedTtsEngineVoice?.name ?? 'ElevenLabs voice';
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

  Future<void> _showClaudeAutoCompactWindowDialog(ChatProvider provider) async {
    final inherited = provider.claudeAutoCompactWindowOverride == null;
    final controller = TextEditingController(
      text: provider.claudeAutoCompactWindowOverride?.toString() ?? '',
    );
    String? error;
    final selected = await showDialog<int?>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Session auto-compact window'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                inherited
                    ? provider.claudeAutoCompactWindowEffective == null
                          ? 'Currently inheriting the Claude SDK/model default.'
                          : 'Currently inheriting ${provider.claudeAutoCompactWindowEffective} tokens from the computer.'
                    : 'This session currently overrides the computer default.',
              ),
              const SizedBox(height: 16),
              TextField(
                controller: controller,
                autofocus: true,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: 'Override tokens',
                  hintText: '100000–1000000',
                  helperText: 'Leave blank to inherit the computer setting.',
                  errorText: error,
                  border: const OutlineInputBorder(),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final raw = controller.text.trim();
                if (raw.isEmpty) {
                  Navigator.pop(dialogContext, -1);
                  return;
                }
                final value = int.tryParse(raw);
                if (value == null || value < 100000 || value > 1000000) {
                  setDialogState(() {
                    error = 'Enter an integer from 100,000 to 1,000,000';
                  });
                  return;
                }
                Navigator.pop(dialogContext, value);
              },
              child: const Text('Apply'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    if (!mounted || selected == null) return;
    provider.setClaudeAutoCompactWindowOverride(
      selected == -1 ? null : selected,
    );
  }

  Future<void> _showContextDialog(Map<String, dynamic> usage) async {
    final provider = context.read<ChatProvider>();
    final accountSessionId = provider.activeSessionId;
    final accountServerId = provider.connMgr.activeServerId;
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
    // Started before the dialog so the panel fills in without blocking the
    // tap; a FutureBuilder below renders it when it lands.
    final claudeUsageFuture = provider.activeSessionBackend == 'codex'
        ? null
        : provider.requestClaudeUsage();
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
    final freeTokens = maxTokens > totalTokens ? maxTokens - totalTokens : 0;
    final model = ctx?['model'] as String?;

    // Split the window by what each row is. Only the `used` rows occupy it,
    // and they are the only ones the bar and the headline may count.
    var breakdown = classifyContextCategories(ctx?['categories']);
    if (breakdown.isEmpty) {
      // Codex and pre-SDK sessions report no categories, only raw counts.
      final fallback = <ContextCategory>[
        if (cacheRead > 0)
          ContextCategory('Cached', cacheRead, const Color(0xFF89B4FA)),
        if (cacheCreate > 0)
          ContextCategory('New cache', cacheCreate, const Color(0xFFA6E3A1)),
        if (inputTokens > 0)
          ContextCategory('Uncached', inputTokens, const Color(0xFFF9E2AF)),
      ];
      breakdown = ContextBreakdown(
        used: fallback,
        usedTokens: fallback.fold(0, (sum, c) => sum + c.tokens),
        bufferTokens: 0,
        freeTokens: freeTokens,
        deferredTokens: 0,
      );
    }
    // The headline reads off the same number the bar is drawn from, so the
    // two cannot disagree.
    final usedTokens = breakdown.isEmpty ? totalTokens : breakdown.usedTokens;
    final usedRatio = maxTokens > 0 ? usedTokens / maxTokens : 0.0;

    final autoCompactThreshold = (ctx?['autoCompactThreshold'] as num?)
        ?.toInt();
    final isAutoCompact = ctx?['isAutoCompactEnabled'] == true;

    final theme = Theme.of(context);

    showDialog(
      context: context,
      builder: (dlgCtx) => AlertDialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        titlePadding: const EdgeInsets.fromLTRB(16, 8, 4, 0),
        contentPadding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
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
            IconButton(
              tooltip: 'Close',
              onPressed: () => Navigator.pop(dlgCtx),
              icon: const Icon(Icons.close, size: 20),
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
                      ? '${(usedRatio * 100).toStringAsFixed(0)}% used'
                      : 'No context data',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w600,
                    color: usedRatio > 0.8
                        ? Colors.red.shade300
                        : usedRatio > 0.5
                        ? Colors.orange.shade300
                        : theme.colorScheme.onSurface,
                  ),
                ),
                if (maxTokens > 0) ...[
                  const SizedBox(height: 4),
                  Text(
                    '${_formatTokenCount(usedTokens)} / ${_formatTokenCount(maxTokens)} tokens',
                    style: TextStyle(
                      fontSize: 13,
                      color: theme.colorScheme.onSurface.withAlpha(178),
                    ),
                  ),
                ],
                const SizedBox(height: 10),
                if (maxTokens > 0)
                  ContextUsageBar(
                    breakdown: breakdown,
                    maxTokens: maxTokens,
                    autoCompactThreshold: isAutoCompact
                        ? autoCompactThreshold
                        : null,
                  ),
                if (isAutoCompact &&
                    autoCompactThreshold != null &&
                    maxTokens > 0) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Tick marks auto-compact at ${(autoCompactThreshold / maxTokens * 100).toStringAsFixed(0)}%',
                    style: TextStyle(
                      fontSize: 11,
                      color: theme.colorScheme.onSurface.withAlpha(128),
                    ),
                  ),
                ],
                const SizedBox(height: 14),
                // Legend for the bar above, in the same order and colours.
                // A category that has a breakdown opens to show it in place,
                // rather than repeating the category further down the dialog
                // under a heading of its own.
                ...breakdown.used.map(
                  (category) => _ContextRow(
                    label: category.name,
                    value: _formatTokenCount(category.tokens),
                    color: category.color,
                    share: usedTokens > 0
                        ? category.tokens / usedTokens * 100
                        : null,
                    children: _categoryDetail(category.name, ctx, theme),
                  ),
                ),

                // Inside the window but unoccupied, plus the tool schemas
                // held outside it. None of these have a legend row to nest
                // under, because none of them count toward the percentage.
                ..._contextReserveRows(
                  breakdown,
                  freeTokens,
                  usedRatio,
                  ctx,
                  theme,
                ),

                if (claudeUsageFuture != null)
                  FutureBuilder<Map<String, dynamic>?>(
                    future: claudeUsageFuture,
                    builder: (_, snap) => snap.data == null
                        ? const SizedBox.shrink()
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Divider(height: 20),
                              ClaudeAccountUsage(usage: snap.data!),
                            ],
                          ),
                  ),

                if (codexStatus != null) ...[
                  const Divider(height: 12),
                  CodexAccountUsage(
                    status: codexStatus,
                    consumeReset: provider.activeSessionBackend == 'codex'
                        ? (attemptId) => provider.consumeCodexReset(
                            attemptId,
                            sessionId: accountSessionId,
                            serverId: accountServerId,
                          )
                        : null,
                  ),
                ],

                // Metadata
                if (numTurns != null)
                  _contextDetailRow('Turns', '$numTurns', theme),
                // Last reply's output tokens. Not part of the window, which
                // is why it is here and no longer a legend row with a
                // colour that matched nothing in the bar.
                if (outputTokens > 0)
                  _contextDetailRow(
                    'Last output',
                    _formatTokenCount(outputTokens),
                    theme,
                  ),
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
      ),
    );
  }

  /// The parts of the window the percentage does not count.
  ///
  /// Deferred tools opens onto the MCP tools held outside the window, which
  /// is where nearly all of them live: they are listed but their schemas are
  /// not loaded, so they cost the session nothing until one is called.
  List<Widget> _contextReserveRows(
    ContextBreakdown breakdown,
    int fallbackFree,
    double usedRatio,
    Map<String, dynamic>? ctx,
    ThemeData theme,
  ) {
    final free = breakdown.freeTokens > 0 ? breakdown.freeTokens : fallbackFree;
    final rows = <(String, int, List<Widget>)>[
      if (free > 0) ('Free space', free, const <Widget>[]),
      if (breakdown.bufferTokens > 0)
        ('Compact buffer', breakdown.bufferTokens, const <Widget>[]),
      if (breakdown.deferredTokens > 0)
        (
          'Deferred tools',
          breakdown.deferredTokens,
          _tokenRows(_mcpTools(ctx, loaded: false), theme),
        ),
    ];
    if (rows.isEmpty) return const [];
    return [
      _ContextSection(
        title: "Not in the ${(usedRatio * 100).toStringAsFixed(0)}%",
        total: _formatTokenCount(rows.fold(0, (sum, row) => sum + row.$2)),
        hint:
            'Window space nothing is using, the amount held back to run a '
            'compaction, and tool definitions kept outside the window until '
            'something calls for them.',
        children: [
          for (final row in rows)
            _ContextRow(
              label: row.$1,
              value: _formatTokenCount(row.$2),
              children: row.$3,
            ),
        ],
      ),
    ];
  }

  /// What a legend category opens onto, or nothing when the payload carries
  /// no breakdown for it.
  ///
  /// System prompt and System tools have none: the SDK itemises those only at
  /// `detail: 'full'`, which token-counts every category over the API, and
  /// this runs on every session init.
  List<Widget> _categoryDetail(
    String name,
    Map<String, dynamic>? ctx,
    ThemeData theme,
  ) {
    switch (name) {
      case 'Messages':
        final breakdown = ctx?['messageBreakdown'] as Map<String, dynamic>?;
        return breakdown == null ? const [] : _msgBreakdownRows(breakdown, theme);
      case 'Skills':
        return _tokenRows(
          (ctx?['skills'] as Map?)?['skillFrontmatter'],
          theme,
        );
      case 'Memory files':
        return _tokenRows(ctx?['memoryFiles'], theme, labelKey: 'path');
      case 'MCP tools':
        return _tokenRows(_mcpTools(ctx, loaded: true), theme);
      case 'Agents':
        return _tokenRows(ctx?['agents'], theme, labelKey: 'agentType');
      default:
        return const [];
    }
  }

  /// The MCP tools whose schemas are loaded into the window, or the ones
  /// held back. Tools predating `isLoaded` count as loaded.
  List<dynamic> _mcpTools(Map<String, dynamic>? ctx, {required bool loaded}) {
    final tools = ctx?['mcpTools'];
    if (tools is! List) return const [];
    return tools
        .where((tool) => ((tool as Map?)?['isLoaded'] != false) == loaded)
        .toList();
  }

  /// `{name, tokens}` records as rows, largest first. Paths show their last
  /// segment, since the directories are identical and eat the width.
  List<Widget> _tokenRows(
    dynamic list,
    ThemeData theme, {
    String labelKey = 'name',
  }) {
    if (list is! List) return const [];
    final rows = list
        .whereType<Map>()
        .map(
          (entry) => (
            '${entry[labelKey] ?? entry['name'] ?? ''}'.split('/').last,
            (entry['tokens'] as num?)?.toInt() ?? 0,
          ),
        )
        .where((row) => row.$1.isNotEmpty && row.$2 > 0)
        .toList()
      ..sort((a, b) => b.$2.compareTo(a.$2));
    return [
      for (final row in rows)
        _contextDetailRow(row.$1, _formatTokenCount(row.$2), theme),
    ];
  }

  /// Non-zero slices of the Messages category, largest first.
  List<Widget> _msgBreakdownRows(
    Map<String, dynamic> breakdown,
    ThemeData theme,
  ) {
    const labels = {
      'userMessageTokens': 'User messages',
      'assistantMessageTokens': 'Assistant messages',
      'toolCallTokens': 'Tool calls',
      'toolResultTokens': 'Tool results',
      'attachmentTokens': 'Attachments',
      'redirectedContextTokens': 'Redirected context',
    };
    final rows = labels.entries
        .map((e) => (e.value, (breakdown[e.key] as num?)?.toInt() ?? 0))
        .where((row) => row.$2 > 0)
        .toList()
      ..sort((a, b) => b.$2.compareTo(a.$2));
    return [
      for (final row in rows)
        _contextDetailRow(row.$1, _formatTokenCount(row.$2), theme),
    ];
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

  Future<void> _showElevenLabsVoicePicker(
    BuildContext context,
    ChatProvider provider,
  ) async {
    if (!provider.hasElevenLabsApiKey) {
      await Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => const VoiceSpeechScreen()));
      return;
    }
    if (provider.elevenLabsVoices.length <= 1 &&
        !provider.elevenLabsVoicesLoading) {
      try {
        await provider.refreshElevenLabsVoices();
      } catch (_) {}
    }
    if (!context.mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => AnimatedBuilder(
        animation: provider,
        builder: (_, __) => DraggableScrollableSheet(
          initialChildSize: 0.55,
          minChildSize: 0.3,
          maxChildSize: 0.85,
          expand: false,
          builder: (_, scrollController) {
            final voices = provider.elevenLabsVoices;
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    'ElevenLabs Voice',
                    style: Theme.of(sheetContext).textTheme.titleMedium,
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: ListView.builder(
                    controller: scrollController,
                    itemCount: voices.length,
                    itemBuilder: (_, index) {
                      final voice = voices[index];
                      final selected =
                          provider.selectedElevenLabsVoice?.id == voice.id;
                      final loading =
                          provider.elevenLabsPreviewLoadingVoiceId == voice.id;
                      return ListTile(
                        title: Text(
                          voice.name,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: selected
                                ? FontWeight.bold
                                : FontWeight.normal,
                          ),
                        ),
                        trailing: loading
                            ? const SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : selected
                            ? Icon(
                                Icons.check,
                                color: Theme.of(
                                  sheetContext,
                                ).colorScheme.primary,
                              )
                            : null,
                        onTap: () {
                          provider.setElevenLabsVoice(voice);
                          Navigator.pop(sheetContext);
                        },
                        onLongPress: () => unawaited(
                          _previewElevenLabsVoice(
                            sheetContext,
                            provider,
                            voice,
                          ),
                        ),
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
                        sheetContext,
                      ).colorScheme.onSurface.withAlpha(128),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
    await provider.stopElevenLabsVoicePreview();
  }

  Future<void> _previewElevenLabsVoice(
    BuildContext context,
    ChatProvider provider,
    TtsEngineVoice voice,
  ) async {
    try {
      await provider.previewElevenLabsVoice(voice);
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$error'.replaceFirst('Exception: ', ''))),
      );
    }
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

  Widget _buildRateLimitBanner(HarnessRateLimit limit) {
    final theme = Theme.of(context);
    final background = limit.isRejected
        ? theme.colorScheme.errorContainer
        : theme.colorScheme.secondaryContainer;
    final foreground = limit.isRejected
        ? theme.colorScheme.onErrorContainer
        : theme.colorScheme.onSecondaryContainer;
    final utilization = limit.utilizationPercent;
    final usage = utilization == null
        ? ''
        : ' · ${utilization.toStringAsFixed(0)}% used';
    final reset = _formatRateLimitReset(limit.resetsAt);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: background,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            limit.window == HarnessRateLimitWindow.weekly
                ? Icons.calendar_view_week
                : Icons.schedule,
            size: 14,
            color: foreground,
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              '${limit.label} ${limit.isRejected ? 'reached' : 'warning'}'
              '$usage · $reset',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: foreground,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatRateLimitReset(DateTime? reset) {
    if (reset == null) return 'reset time unavailable';
    final local = reset.toLocal();
    final now = DateTime.now();
    final tomorrow = DateTime(now.year, now.month, now.day + 1);
    final date = DateTime(local.year, local.month, local.day);
    final String day;
    if (DateUtils.isSameDay(local, now)) {
      day = 'today';
    } else if (DateUtils.isSameDay(date, tomorrow)) {
      day = 'tomorrow';
    } else {
      const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
      const months = [
        'Jan',
        'Feb',
        'Mar',
        'Apr',
        'May',
        'Jun',
        'Jul',
        'Aug',
        'Sep',
        'Oct',
        'Nov',
        'Dec',
      ];
      day =
          '${weekdays[local.weekday - 1]}, '
          '${months[local.month - 1]} ${local.day}';
    }
    return 'resets $day at ${TimeOfDay.fromDateTime(local).format(context)}';
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

  Widget _buildBackendRecoveryBanner(String message) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: colors.secondaryContainer,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: colors.onSecondaryContainer,
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: colors.onSecondaryContainer,
              ),
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
