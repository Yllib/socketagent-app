import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/chat_provider.dart';
import '../services/session_teleport.dart';
import '../services/websocket_service.dart';
import '../models/message.dart';
import '../models/session_grouping.dart';
import '../models/session_list_filter.dart';
import '../util/format.dart';
import '../widgets/extra_folders_dialog.dart';
import '../widgets/adaptive_action_sheet.dart';
import '../widgets/transfer_history_dialog.dart';
import '../widgets/computer_filter_dialog.dart';
import '../widgets/session_backend_watermark.dart';
import '../widgets/session_compaction_notice.dart';
import '../widgets/folder_browser_screen.dart';
import 'archive_screen.dart';
import 'home_screen.dart';
import 'main_shell_screen.dart';
import 'onboarding_screen.dart';
import 'session_browser_screen.dart';
import '../config/app_palette.dart';
import '../widgets/light_backdrop.dart';

/// Teleport asks before sending a transcript at least this large, uncompressed.
const _largeTranscriptBytes = 100 * 1024 * 1024;

enum _SessionMenuAction {
  pin,
  notifications,
  rename,
  fork,
  teleport,
  startFresh,
  tools,
  archive,
  delete,
}

/// "None" or "2 folders", for an extra folders menu entry.
String _folderCount(int count) => switch (count) {
  0 => 'None',
  1 => '1 folder',
  _ => '$count folders',
};

enum _SessionToolsAction {
  compact,
  rollback,
  clearContext,
  blockedTools,
  extraFolders,
  instructions,
}

class SessionsTab extends StatefulWidget {
  const SessionsTab({super.key, this.sidebar = false});

  final bool sidebar;

  @override
  State<SessionsTab> createState() => _SessionsTabState();
}

class _SessionsTabState extends State<SessionsTab> {
  String? _openingSessionKey;
  final Set<String> _selectedServerFilterIds = {};
  bool _connectedOnlyFilter = false;
  String? _backendFilter;
  bool _searchOpen = false;
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();
  final Set<String> _collapsedDelegatedParents = {};
  final Set<String> _selectedSessionKeys = {};
  bool _selectionMode = false;
  Timer? _globalSearchDebounce;
  int _globalSearchGeneration = 0;
  bool _globalSearchLoading = false;
  List<Map<String, dynamic>> _globalSearchResults = const [];
  bool _filtersChanged = false;

  @override
  void initState() {
    super.initState();
    SessionListFilter.load().then((saved) {
      // A filter picked while this loaded wins over the saved one.
      if (!mounted || _filtersChanged) return;
      setState(() {
        _selectedServerFilterIds.addAll(saved.computerIds);
        _connectedOnlyFilter = saved.connectedOnly;
        _backendFilter = saved.backend;
      });
    });
  }

  /// Call after any filter change, inside or after its setState.
  void _saveFilters() {
    _filtersChanged = true;
    SessionListFilter(
      computerIds: {..._selectedServerFilterIds},
      connectedOnly: _connectedOnlyFilter,
      backend: _backendFilter,
    ).save();
  }

  @override
  void dispose() {
    _globalSearchDebounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _showSessionActionMenu(
    BuildContext context,
    ChatProvider provider,
  ) async {
    final mode = await showAdaptiveActionSheet<SessionBrowserMode>(
      context: context,
      sections: const [
        AdaptiveSheetSection([
          AdaptiveSheetAction(
            value: SessionBrowserMode.create,
            label: 'New session',
            subtitle: 'Choose a computer and working folder',
            icon: Icons.add_comment_outlined,
            trailing: Icon(Icons.chevron_right),
          ),
          AdaptiveSheetAction(
            value: SessionBrowserMode.resume,
            label: 'Resume session',
            subtitle: 'Browse Claude and Codex history',
            icon: Icons.history,
            trailing: Icon(Icons.chevron_right),
          ),
        ]),
      ],
    );
    if (mode == null || !context.mounted) return;

    final result = await Navigator.of(context).push<SessionBrowserResult>(
      MaterialPageRoute(
        builder: (_) => SessionBrowserScreen(
          mode: mode,
          initialServerId: _serverIdForNewSession(provider),
        ),
      ),
    );
    if (result == null || !context.mounted) return;

    if (mode == SessionBrowserMode.resume && result.sessionId != null) {
      await _openSession(
        context,
        sessionId: result.sessionId,
        cwd: result.cwd,
        serverId: result.serverId,
        backend: result.backend,
        sdkSession: !result.tracked,
      );
      return;
    }

    final supported = provider.backendsForServer(result.serverId);
    String backend = provider.preferredBackendForServer(result.serverId);
    if (supported.length > 1) {
      final selection = await _pickServerAndBackend(
        context,
        provider,
        presetServerId: result.serverId,
      );
      if (selection == null || !context.mounted) return;
      backend = selection.backend;
    }
    await _openSession(
      context,
      cwd: result.cwd,
      serverId: result.serverId,
      backend: backend,
    );
  }

  void _handleSearchChanged(String value) {
    setState(() => _searchQuery = value);
    _globalSearchDebounce?.cancel();
    if (value.trim().isEmpty) {
      setState(() {
        _globalSearchLoading = false;
        _globalSearchResults = const [];
      });
      return;
    }
    _globalSearchDebounce = Timer(
      const Duration(milliseconds: 280),
      () => unawaited(_runGlobalSearch(value.trim())),
    );
  }

  Future<void> _runGlobalSearch(String query) async {
    final provider = context.read<ChatProvider>();
    final generation = ++_globalSearchGeneration;
    setState(() => _globalSearchLoading = true);
    final connected = provider.serverConfigs.where(
      (server) =>
          provider.connMgr.statusOf(server.id) == ConnectionStatus.connected,
    );
    final batches = await Future.wait(
      connected.map((server) async {
        try {
          final computerMatches = server.name.toLowerCase().contains(
            query.toLowerCase(),
          );
          final page = await provider.requestSdkSessions(
            '',
            serverId: server.id,
            all: true,
            query: computerMatches ? '' : query,
            limit: 500,
          );
          return page.sessions
              .map(
                (session) => <String, dynamic>{
                  ...session,
                  '_serverId': server.id,
                  '_serverName': server.name,
                },
              )
              .toList();
        } catch (_) {
          return <Map<String, dynamic>>[];
        }
      }),
    );
    if (!mounted || generation != _globalSearchGeneration) return;
    final deduped = <String, Map<String, dynamic>>{};
    for (final session in batches.expand((batch) => batch)) {
      final key = [
        session['_serverId'],
        session['backend'] ?? 'claude',
        session['sessionId'],
      ].join(':');
      deduped[key] = session;
    }
    final results = deduped.values.toList()
      ..sort(
        (left, right) => (right['lastActive']?.toString() ?? '').compareTo(
          left['lastActive']?.toString() ?? '',
        ),
      );
    setState(() {
      _globalSearchResults = results;
      _globalSearchLoading = false;
    });
  }

  Future<bool> _requireSubscription({String? serverId}) async {
    final shell = context.findAncestorStateOfType<MainShellScreenState>();
    if (shell != null) {
      return shell.requireSubscription(serverId: serverId);
    }
    return true;
  }

  Future<void> _openSession(
    BuildContext context, {
    String? sessionId,
    String? cwd,
    String? serverId,
    String? backend,
    bool sdkSession = false,
  }) async {
    final openKey = _openSessionKey(
      sessionId: sessionId,
      cwd: cwd,
      serverId: serverId,
      backend: backend,
      sdkSession: sdkSession,
    );
    if (_openingSessionKey != null) return;
    setState(() => _openingSessionKey = openKey);
    final provider = context.read<ChatProvider>();
    var accessServerId = serverId;
    try {
      if (sessionId != null) {
        final session = provider.sessions
            .where(
              (session) =>
                  session.id == sessionId &&
                  (serverId == null ||
                      serverId.isEmpty ||
                      session.serverId == serverId),
            )
            .firstOrNull;
        accessServerId ??= session?.serverId;
      }

      if (!await _requireSubscription(serverId: accessServerId)) return;
      if (!context.mounted) return;

      if (sdkSession && sessionId != null && cwd != null) {
        provider.resumeSdkSession(
          sessionId,
          cwd,
          serverId: serverId,
          backend: backend,
        );
      } else if (sessionId != null) {
        provider.resumeSession(sessionId, serverId: serverId);
      } else {
        // The CWD picker now collects server + backend + cwd in one sheet,
        // so backend usually arrives already chosen. Only show the fallback
        // picker if backend is unset AND the upstream caller didn't pick
        // (e.g., a code path that bypasses the CWD picker).
        String? effectiveBackend = backend;
        if (effectiveBackend == null) {
          final needsServerPick =
              serverId == null && provider.serverConfigs.length > 1;
          final initialServer =
              serverId ?? provider.serverConfigs.firstOrNull?.id;
          final initialBackends = provider.backendsForServer(initialServer);
          final needsBackendPick =
              needsServerPick || initialBackends.length > 1;
          if (needsBackendPick) {
            final result = await _pickServerAndBackend(
              context,
              provider,
              presetServerId: serverId,
            );
            if (result == null || !context.mounted) return;
            serverId = result.serverId;
            effectiveBackend = result.backend;
          } else if (initialBackends.isNotEmpty) {
            effectiveBackend = provider.preferredBackendForServer(
              initialServer,
            );
          }
        }
        provider.createNewSession(
          cwd: cwd,
          serverId: serverId,
          backend: effectiveBackend,
        );
      }

      await openConversation(context);
    } finally {
      if (mounted && _openingSessionKey == openKey) {
        setState(() => _openingSessionKey = null);
      }
    }
  }

  String _openSessionKey({
    String? sessionId,
    String? cwd,
    String? serverId,
    String? backend,
    bool sdkSession = false,
  }) {
    if (sessionId != null && sessionId.isNotEmpty) {
      return 'session:${serverId ?? ''}:$sessionId';
    }
    return 'new:${serverId ?? ''}:${backend ?? ''}:${cwd ?? ''}:$sdkSession';
  }

  /// Combined server + backend picker. Server section is hidden when there's
  /// only one server. Backend section is hidden when the chosen server only
  /// supports one backend (so claude-only servers feel exactly like before).
  Future<({String? serverId, String backend})?> _pickServerAndBackend(
    BuildContext context,
    ChatProvider provider, {
    String? presetServerId,
  }) async {
    final connectedServers = provider.serverConfigs
        .where(
          (c) => provider.connMgr.statusOf(c.id) == ConnectionStatus.connected,
        )
        .toList();
    String? selectedServer =
        presetServerId ??
        (connectedServers.isNotEmpty
            ? connectedServers.first.id
            : provider.serverConfigs.firstOrNull?.id);
    String selectedBackend = provider.preferredBackendForServer(selectedServer);

    return showModalBottomSheet<({String? serverId, String backend})>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      constraints: adaptiveActionSheetConstraints,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setState) {
            final supported = provider.backendsForServer(selectedServer);
            // Snap back to a valid choice if the user just changed servers.
            if (!supported.contains(selectedBackend)) {
              selectedBackend = provider.preferredBackendForServer(
                selectedServer,
              );
            }
            // Hide the server radio when a server was preselected upstream
            // (e.g., in the CWD picker) — re-asking would be confusing.
            final showServers =
                provider.serverConfigs.length > 1 && presetServerId == null;
            final showBackends = supported.length > 1;

            return AdaptiveSheetBody(
              title: 'New session',
              children: [
                if (showServers) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: Text(
                      'Computer',
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ),
                  RadioGroup<String>(
                    groupValue: selectedServer,
                    onChanged: (value) {
                      if (value != null) {
                        setState(() => selectedServer = value);
                      }
                    },
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final config in provider.serverConfigs)
                          Builder(
                            builder: (context) {
                              final status = provider.connMgr.statusOf(
                                config.id,
                              );
                              final isConnected =
                                  status == ConnectionStatus.connected;
                              return RadioListTile<String>(
                                value: config.id,
                                enabled: isConnected,
                                title: Text(config.name),
                                subtitle: Text(
                                  config.useRelay
                                      ? 'Relay'
                                      : '${config.host}:${config.port}',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurface.withAlpha(128),
                                  ),
                                ),
                                secondary: Icon(
                                  isConnected
                                      ? Icons.cloud_done
                                      : Icons.cloud_off,
                                  color: isConnected
                                      ? context.palette.success
                                      : Colors.grey,
                                ),
                                dense: true,
                              );
                            },
                          ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                ],
                if (showBackends) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: Text(
                      'Backend',
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ),
                  RadioGroup<String>(
                    groupValue: selectedBackend,
                    onChanged: (value) {
                      if (value != null) {
                        setState(() => selectedBackend = value);
                      }
                    },
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final backend in supported)
                          RadioListTile<String>(
                            value: backend,
                            title: Text(_backendLabel(backend)),
                            subtitle: Text(
                              _backendSubtitle(backend),
                              style: TextStyle(
                                fontSize: 12,
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurface.withAlpha(128),
                              ),
                            ),
                            dense: true,
                          ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                ],
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('Cancel'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: selectedServer == null
                            ? null
                            : () => Navigator.pop(ctx, (
                                serverId: selectedServer,
                                backend: selectedBackend,
                              )),
                        child: const Text('Create'),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  String _backendLabel(String b) => b == 'codex' ? 'Codex (ChatGPT)' : 'Claude';
  String _backendSubtitle(String b) => b == 'codex'
      ? 'OpenAI Codex CLI — billed via your ChatGPT subscription'
      : 'Anthropic Claude Agent SDK — billed via your Claude subscription';

  Future<void> _validateAndOpen(
    BuildContext context,
    String path, {
    String? serverId,
    String? backend,
  }) async {
    final provider = context.read<ChatProvider>();
    final exists = await provider.checkCwd(path, serverId: serverId);
    if (!context.mounted) return;

    if (exists) {
      _openSession(context, cwd: path, serverId: serverId, backend: backend);
      return;
    }

    final canCreate = _canCreateCwd(provider.lastCwdCheck);
    final create = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Directory not found'),
        content: SingleChildScrollView(
          child: Text(_formatCwdCheckFailure(provider, path, serverId)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: canCreate ? () => Navigator.pop(ctx, true) : null,
            child: const Text('Create'),
          ),
        ],
      ),
    );

    if (create == true && context.mounted) {
      final created = await provider.createCwd(path, serverId: serverId);
      if (!context.mounted) return;
      if (created) {
        _openSession(context, cwd: path, serverId: serverId, backend: backend);
      } else {
        final detail = _shortCwdFailure(provider.lastCwdCheck);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to create $path$detail')),
        );
      }
    }
  }

  String _formatCwdCheckFailure(
    ChatProvider provider,
    String path,
    String? serverId,
  ) {
    final check = provider.lastCwdCheck;
    final exists = check?['exists'] == true;
    final isDirectory = check?['isDirectory'] == true;
    final timedOut = check?['error'] == 'Timed out waiting for computer';
    final firstLine = timedOut
        ? '$path could not be checked.'
        : exists && !isDirectory
        ? '$path exists, but it is not a directory.'
        : '$path does not exist.';
    final lines = <String>[firstLine];
    final server = provider.serverConfigs
        .where((config) => config.id == serverId)
        .firstOrNull;
    final serverName = server?.name ?? provider.connMgr.activeConfig?.name;
    if (serverName != null && serverName.isNotEmpty) {
      lines.add('');
      lines.add('Computer: $serverName');
    }
    if (check != null) {
      final resolved = check['resolvedPath'] as String?;
      final expanded = check['expandedPath'] as String?;
      final user = check['user'] as String?;
      final home = check['home'] as String?;
      final platform = check['platform'] as String?;
      final errorCode = check['errorCode'] as String?;
      final error = check['error'] as String?;

      if (resolved != null && resolved.isNotEmpty && resolved != path) {
        lines.add('Resolved: $resolved');
      }
      if (expanded != null &&
          expanded.isNotEmpty &&
          expanded != path &&
          expanded != resolved) {
        lines.add('Expanded: $expanded');
      }
      if (user != null && user.isNotEmpty) lines.add('Computer user: $user');
      if (home != null && home.isNotEmpty) lines.add('Computer home: $home');
      if (platform != null && platform.isNotEmpty) {
        lines.add('Platform: $platform');
      }
      if ((errorCode != null && errorCode.isNotEmpty) ||
          (error != null && error.isNotEmpty)) {
        lines.add(
          'Error: ${[if (errorCode != null && errorCode.isNotEmpty) errorCode, if (error != null && error.isNotEmpty) error].join(' - ')}',
        );
      }
    }
    lines.add('');
    lines.add(
      _canCreateCwd(check) ? 'Create it?' : 'Choose another directory.',
    );
    return lines.join('\n');
  }

  bool _canCreateCwd(Map<String, dynamic>? check) {
    if (check == null) return true;
    return check['exists'] != true;
  }

  String _shortCwdFailure(Map<String, dynamic>? check) {
    if (check == null) return '';
    final errorCode = check['errorCode'] as String?;
    final error = check['error'] as String?;
    final detail = [
      if (errorCode != null && errorCode.isNotEmpty) errorCode,
      if (error != null && error.isNotEmpty) error,
    ].join(': ');
    return detail.isEmpty ? '' : ': $detail';
  }

  String? _serverIdForNewSession(ChatProvider provider) {
    final selected = _selectedServerFilterIds.length == 1
        ? _selectedServerFilterIds.single
        : null;
    if (selected != null &&
        provider.serverConfigs.any((c) => c.id == selected)) {
      return selected;
    }

    final activeServerId = provider.activeServerId;
    if (activeServerId != null &&
        provider.serverConfigs.any((c) => c.id == activeServerId)) {
      return activeServerId;
    }

    final connected = provider.serverConfigs
        .where(
          (c) => provider.connMgr.statusOf(c.id) == ConnectionStatus.connected,
        )
        .toList();
    if (connected.isNotEmpty) return connected.first.id;
    return provider.serverConfigs.firstOrNull?.id;
  }

  String? _initialCwdPickerServerId(
    ChatProvider provider,
    String? preferredServerId,
  ) {
    if (preferredServerId != null &&
        provider.serverConfigs.any((c) => c.id == preferredServerId)) {
      return preferredServerId;
    }

    final connected = provider.serverConfigs
        .where(
          (c) => provider.connMgr.statusOf(c.id) == ConnectionStatus.connected,
        )
        .toList();
    if (connected.isNotEmpty) return connected.first.id;
    return provider.serverConfigs.firstOrNull?.id;
  }

  String _defaultCwdForServer(ChatProvider provider, String? serverId) {
    final config = serverId == null
        ? null
        : provider.serverConfigs.where((c) => c.id == serverId).firstOrNull;
    final serverDefault = config?.defaultCwd.trim();
    if (serverDefault != null && serverDefault.isNotEmpty) {
      return serverDefault;
    }

    final globalDefault = provider.defaultCwd.trim();
    if (globalDefault.isNotEmpty &&
        (serverId == null ||
            serverId == provider.serverConfigs.firstOrNull?.id)) {
      return globalDefault;
    }
    return '';
  }

  /// Resume-prominent picker: a tall bottom sheet where past sessions in the
  /// chosen folder dominate the available space. Server + backend live as
  /// compact chips at the top (only visible when there's a real choice to
  /// make), recent paths collapse into a horizontal chip strip, and "Start
  /// new session here" is a single FilledButton CTA — so the user can either
  /// pick from past sessions or create a new one with one tap each.
  // Kept temporarily as a compatibility fallback while the new full-screen
  // launcher rolls out to older server versions.
  // ignore: unused_element
  void _showCwdPicker(BuildContext context, {String? initialServerId}) {
    final provider = context.read<ChatProvider>();
    final hasMultipleServers = provider.serverConfigs.length > 1;
    String? selectedServerId = _initialCwdPickerServerId(
      provider,
      initialServerId,
    );

    final controller = TextEditingController(
      text: _defaultCwdForServer(provider, selectedServerId),
    );
    List<Map<String, dynamic>> sdkSessions = [];
    bool loadingSdkSessions = false;
    bool loadingMoreSdkSessions = false;
    bool hasMoreSdkSessions = false;
    int sdkSessionTotal = 0;
    int sdkSessionLimit = 30;
    bool initialFetchDone = false;
    int sdkSessionsFetchGeneration = 0;
    Timer? fetchDebounce;
    String selectedBackend = provider.preferredBackendForServer(
      selectedServerId,
    );

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            final recentCwds = provider.getRecentCwds(
              serverId: selectedServerId,
            );
            final supportedBackends = provider.backendsForServer(
              selectedServerId,
            );
            final showBackendChip = supportedBackends.length > 1;

            void fetchSdkSessions({bool loadMore = false}) {
              fetchDebounce?.cancel();
              final generation = ++sdkSessionsFetchGeneration;
              final path = controller.text.trim();
              final requestServerId = selectedServerId;
              if (!loadMore) sdkSessionLimit = 30;
              if (path.isEmpty) {
                setSheetState(() {
                  sdkSessions = [];
                  loadingSdkSessions = false;
                  loadingMoreSdkSessions = false;
                  hasMoreSdkSessions = false;
                  sdkSessionTotal = 0;
                });
                return;
              }
              setSheetState(() {
                if (loadMore) {
                  loadingMoreSdkSessions = true;
                } else {
                  loadingSdkSessions = true;
                }
              });
              fetchDebounce = Timer(const Duration(milliseconds: 250), () {
                provider
                    .requestSdkSessions(
                      path,
                      serverId: requestServerId,
                      limit: sdkSessionLimit,
                    )
                    .then((page) {
                      if (ctx.mounted &&
                          generation == sdkSessionsFetchGeneration &&
                          controller.text.trim() == path &&
                          selectedServerId == requestServerId) {
                        setSheetState(() {
                          sdkSessions = page.sessions;
                          sdkSessionTotal = page.total;
                          hasMoreSdkSessions = page.hasMore;
                          loadingSdkSessions = false;
                          loadingMoreSdkSessions = false;
                        });
                      }
                    });
              });
            }

            if (!initialFetchDone) {
              initialFetchDone = true;
              WidgetsBinding.instance.addPostFrameCallback(
                (_) => fetchSdkSessions(),
              );
            }

            // Compact tappable chip used for server + backend selection.
            Widget miniChip({
              required IconData icon,
              Color? iconColor,
              required String label,
              required VoidCallback onTap,
            }) {
              return InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: onTap,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: Theme.of(context).colorScheme.outlineVariant,
                      width: 1,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(icon, size: 14, color: iconColor),
                      const SizedBox(width: 6),
                      Text(label, style: const TextStyle(fontSize: 12)),
                      const SizedBox(width: 2),
                      Icon(
                        Icons.arrow_drop_down,
                        size: 16,
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withAlpha(140),
                      ),
                    ],
                  ),
                ),
              );
            }

            // Build server chip (only when there's a choice to make).
            Widget? serverChipWidget;
            if (hasMultipleServers && selectedServerId != null) {
              final config = provider.serverConfigs.firstWhere(
                (c) => c.id == selectedServerId,
              );
              final isConnected =
                  provider.connMgr.statusOf(config.id) ==
                  ConnectionStatus.connected;
              serverChipWidget = PopupMenuButton<String>(
                initialValue: selectedServerId,
                tooltip: 'Switch computer',
                position: PopupMenuPosition.under,
                onSelected: (id) {
                  final previousDefault = _defaultCwdForServer(
                    provider,
                    selectedServerId,
                  );
                  final currentPath = controller.text.trim();
                  setSheetState(() {
                    selectedServerId = id;
                    final supported = provider.backendsForServer(id);
                    if (!supported.contains(selectedBackend) &&
                        supported.isNotEmpty) {
                      selectedBackend = provider.preferredBackendForServer(id);
                    }
                    if (currentPath.isEmpty || currentPath == previousDefault) {
                      final nextDefault = _defaultCwdForServer(provider, id);
                      controller.text = nextDefault;
                      controller.selection = TextSelection.fromPosition(
                        TextPosition(offset: nextDefault.length),
                      );
                    }
                  });
                  fetchSdkSessions();
                },
                itemBuilder: (_) => provider.serverConfigs.map((c) {
                  final connected =
                      provider.connMgr.statusOf(c.id) ==
                      ConnectionStatus.connected;
                  return PopupMenuItem(
                    value: c.id,
                    enabled: connected,
                    child: Row(
                      children: [
                        Icon(
                          connected ? Icons.cloud_done : Icons.cloud_off,
                          size: 16,
                          color: connected
                              ? context.palette.success
                              : Colors.grey,
                        ),
                        const SizedBox(width: 8),
                        Text(c.name),
                      ],
                    ),
                  );
                }).toList(),
                child: AbsorbPointer(
                  child: miniChip(
                    icon: isConnected ? Icons.cloud_done : Icons.cloud_off,
                    iconColor: isConnected
                        ? context.palette.success
                        : Colors.grey,
                    label: config.name,
                    onTap: () {},
                  ),
                ),
              );
            }

            // Build backend chip (only when the chosen server supports more
            // than one backend — claude-only servers stay clean).
            Widget? backendChipWidget;
            if (showBackendChip) {
              backendChipWidget = PopupMenuButton<String>(
                initialValue: selectedBackend,
                tooltip: 'Switch backend',
                position: PopupMenuPosition.under,
                onSelected: (b) => setSheetState(() => selectedBackend = b),
                itemBuilder: (_) => supportedBackends
                    .map(
                      (b) => PopupMenuItem(
                        value: b,
                        child: Row(
                          children: [
                            Icon(
                              b == 'codex' ? Icons.code : Icons.psychology_alt,
                              size: 16,
                            ),
                            const SizedBox(width: 8),
                            Text(_backendLabel(b)),
                          ],
                        ),
                      ),
                    )
                    .toList(),
                child: AbsorbPointer(
                  child: miniChip(
                    icon: selectedBackend == 'codex'
                        ? Icons.code
                        : Icons.psychology_alt,
                    label: _backendLabel(selectedBackend),
                    onTap: () {},
                  ),
                ),
              );
            }

            void startNewSession() {
              final path = controller.text.trim();
              if (path.isEmpty) return;
              Navigator.pop(ctx);
              _validateAndOpen(
                context,
                path,
                serverId: selectedServerId,
                backend: selectedBackend,
              );
            }

            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(ctx).viewInsets.bottom,
              ),
              child: SizedBox(
                height: MediaQuery.of(ctx).size.height * 0.85,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Drag handle
                    Center(
                      child: Container(
                        margin: const EdgeInsets.symmetric(vertical: 8),
                        width: 36,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.outlineVariant,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    // Compact server + backend chips, only when there's a real choice.
                    if (serverChipWidget != null || backendChipWidget != null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [?serverChipWidget, ?backendChipWidget],
                        ),
                      ),
                    // Path field + browse icon button.
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: controller,
                              decoration: InputDecoration(
                                hintText: '/path/to/project',
                                prefixIcon: const Icon(
                                  Icons.folder_open,
                                  size: 18,
                                ),
                                filled: true,
                                fillColor: Theme.of(
                                  context,
                                ).colorScheme.surfaceContainerHighest,
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: BorderSide.none,
                                ),
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 10,
                                ),
                                isDense: true,
                              ),
                              style: const TextStyle(fontSize: 14),
                              textInputAction: TextInputAction.search,
                              onChanged: (_) => fetchSdkSessions(),
                              onSubmitted: (_) => fetchSdkSessions(),
                            ),
                          ),
                          const SizedBox(width: 8),
                          IconButton(
                            icon: const Icon(Icons.account_tree_outlined),
                            tooltip: 'Browse computer filesystem',
                            onPressed: () async {
                              final picked = await _showFolderBrowser(
                                context,
                                provider,
                                serverId: selectedServerId,
                              );
                              if (picked != null && ctx.mounted) {
                                controller.text = picked;
                                controller.selection =
                                    TextSelection.fromPosition(
                                      TextPosition(offset: picked.length),
                                    );
                                fetchSdkSessions();
                              }
                            },
                          ),
                        ],
                      ),
                    ),
                    // Recent CWDs as a single horizontal chip strip.
                    if (recentCwds.isNotEmpty)
                      SizedBox(
                        height: 40,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          itemCount: recentCwds.length,
                          separatorBuilder: (_, _) => const SizedBox(width: 6),
                          itemBuilder: (_, i) {
                            final cwd = recentCwds[i];
                            // Show the trailing path component for compactness;
                            // the full path is in the tooltip and the field itself
                            // when tapped.
                            final shortLabel =
                                cwd
                                    .split('/')
                                    .where((s) => s.isNotEmpty)
                                    .lastOrNull ??
                                cwd;
                            return InputChip(
                              label: Text(
                                shortLabel,
                                style: const TextStyle(fontSize: 12),
                              ),
                              tooltip: cwd,
                              visualDensity: VisualDensity.compact,
                              materialTapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                              onPressed: () {
                                controller.text = cwd;
                                controller.selection =
                                    TextSelection.fromPosition(
                                      TextPosition(offset: cwd.length),
                                    );
                                fetchSdkSessions();
                              },
                              onDeleted: () {
                                provider.removeRecentCwd(
                                  cwd,
                                  serverId: selectedServerId,
                                );
                                setSheetState(() {});
                              },
                              deleteIconColor: Theme.of(
                                context,
                              ).colorScheme.onSurface.withAlpha(120),
                            );
                          },
                        ),
                      ),
                    // Single primary CTA — "start new session here".
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                      child: SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: controller.text.trim().isEmpty
                              ? null
                              : startNewSession,
                          icon: const Icon(Icons.add, size: 18),
                          label: Text(
                            showBackendChip
                                ? 'Start new ${_backendLabel(selectedBackend)} session'
                                : 'Start new session here',
                          ),
                        ),
                      ),
                    ),
                    const Divider(height: 1),
                    // Past sessions header with count.
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                      child: Row(
                        children: [
                          Text(
                            'Past sessions in this folder',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurface.withAlpha(140),
                            ),
                          ),
                          const Spacer(),
                          if (!loadingSdkSessions && sdkSessions.isNotEmpty)
                            Text(
                              sdkSessions.length < sdkSessionTotal
                                  ? '${sdkSessions.length} of $sdkSessionTotal'
                                  : '$sdkSessionTotal',
                              style: TextStyle(
                                fontSize: 12,
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurface.withAlpha(100),
                              ),
                            ),
                        ],
                      ),
                    ),
                    // Past sessions list — fills the remaining space.
                    Expanded(
                      child: loadingSdkSessions
                          ? const Center(
                              child: SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            )
                          : sdkSessions.isEmpty
                          ? Center(
                              child: Padding(
                                padding: const EdgeInsets.all(16),
                                child: Text(
                                  controller.text.trim().isEmpty
                                      ? 'Type or pick a path to see past sessions'
                                      : 'No past sessions in this folder',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurface.withAlpha(120),
                                  ),
                                ),
                              ),
                            )
                          : ListView.builder(
                              padding: const EdgeInsets.only(bottom: 16),
                              itemCount:
                                  sdkSessions.length +
                                  (hasMoreSdkSessions ? 1 : 0),
                              itemBuilder: (_, index) {
                                if (index == sdkSessions.length) {
                                  return Center(
                                    child: TextButton.icon(
                                      onPressed: loadingMoreSdkSessions
                                          ? null
                                          : () {
                                              sdkSessionLimit =
                                                  (sdkSessionLimit + 30).clamp(
                                                    1,
                                                    2000,
                                                  );
                                              fetchSdkSessions(loadMore: true);
                                            },
                                      icon: loadingMoreSdkSessions
                                          ? const SizedBox(
                                              width: 16,
                                              height: 16,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                              ),
                                            )
                                          : const Icon(Icons.expand_more),
                                      label: const Text('View more'),
                                    ),
                                  );
                                }
                                final session = sdkSessions[index];
                                final preview =
                                    session['firstMessage'] as String? ?? '';
                                final sessionBackend =
                                    session['backend'] as String?;
                                final lastActive =
                                    DateTime.tryParse(
                                      session['lastActive'] as String? ?? '',
                                    ) ??
                                    DateTime.now();
                                final timeAgo = formatTimeAgo(lastActive);
                                return ListTile(
                                  dense: true,
                                  leading: Icon(
                                    Icons.history,
                                    size: 20,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.secondary,
                                  ),
                                  title: Text(
                                    preview,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 13),
                                  ),
                                  subtitle: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        timeAgo,
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: Theme.of(context)
                                              .colorScheme
                                              .onSurface
                                              .withAlpha(128),
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      Text(
                                        _backendLabel(
                                          sessionBackend ?? 'claude',
                                        ),
                                      ),
                                    ],
                                  ),
                                  onTap: () {
                                    Navigator.pop(ctx);
                                    final isTracked =
                                        session['tracked'] == true;
                                    _openSession(
                                      context,
                                      sessionId: session['sessionId'] as String,
                                      cwd: controller.text.trim(),
                                      serverId: selectedServerId,
                                      sdkSession: !isTracked,
                                      backend: sessionBackend,
                                    );
                                  },
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    ).then((_) {
      fetchDebounce?.cancel();
      controller.dispose();
    });
  }

  Future<String?> _showFolderBrowser(
    BuildContext context,
    ChatProvider provider, {
    String? serverId,
  }) async {
    return Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) =>
            FolderBrowserScreen(provider: provider, serverId: serverId),
      ),
    );
  }

  Widget _buildConnectionIndicator(ChatProvider provider) {
    final configs = provider.serverConfigs;
    if (configs.length > 1) {
      final connectedCount = configs
          .where(
            (c) =>
                provider.connMgr.statusOf(c.id) == ConnectionStatus.connected,
          )
          .length;
      final expectedOfflineCount = configs
          .where(
            (c) =>
                c.expectedOnline &&
                provider.connMgr.statusOf(c.id) != ConnectionStatus.connected,
          )
          .length;
      final color = expectedOfflineCount > 0
          ? context.palette.warning
          : connectedCount > 0
          ? context.palette.success
          : Colors.grey;
      final tooltip = expectedOfflineCount > 0
          ? '$connectedCount online · $expectedOfflineCount expected offline'
          : '$connectedCount online';
      return Tooltip(
        message: tooltip,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: color,
                  boxShadow: [
                    if (color == context.palette.success)
                      BoxShadow(
                        color: color.withAlpha(100),
                        blurRadius: 4,
                        spreadRadius: 1,
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              Text(
                '$connectedCount online',
                style: TextStyle(
                  fontSize: 11,
                  color: color,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      );
    }

    Color color;
    String tooltip;
    switch (provider.connectionStatus) {
      case ConnectionStatus.connected:
        color = context.palette.success;
        tooltip = 'Connected';
        break;
      case ConnectionStatus.connecting:
        color = context.palette.warning;
        tooltip = 'Connecting...';
        break;
      case ConnectionStatus.disconnected:
        color = Colors.grey;
        tooltip = 'Disconnected';
        break;
      case ConnectionStatus.error:
        color = context.palette.danger;
        tooltip = 'Connection error';
        break;
    }
    return Tooltip(
      message: tooltip,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color,
            boxShadow: [
              if (color == context.palette.success)
                BoxShadow(
                  color: color.withAlpha(100),
                  blurRadius: 4,
                  spreadRadius: 1,
                ),
            ],
          ),
        ),
      ),
    );
  }

  String _serverStatusLabel(ConnectionStatus status) {
    switch (status) {
      case ConnectionStatus.connected:
        return 'Connected';
      case ConnectionStatus.connecting:
        return 'Connecting';
      case ConnectionStatus.error:
        return 'Connection error';
      case ConnectionStatus.disconnected:
        return 'Offline';
    }
  }

  String _sessionKey(Session session) => '${session.serverId}:${session.id}';

  List<Session> _selectedSessions(ChatProvider provider) => provider.sessions
      .where((session) => _selectedSessionKeys.contains(_sessionKey(session)))
      .toList();

  void _enterSelection(Session session) {
    setState(() {
      _selectionMode = true;
      _selectedSessionKeys.add(_sessionKey(session));
    });
  }

  void _toggleSessionSelection(Session session) {
    setState(() {
      final key = _sessionKey(session);
      if (!_selectedSessionKeys.add(key)) {
        _selectedSessionKeys.remove(key);
      }
    });
  }

  void _exitSelection() {
    setState(() {
      _selectionMode = false;
      _selectedSessionKeys.clear();
    });
  }

  void _selectAllVisible(ChatProvider provider) {
    final visible = provider.sessions.where(
      (session) =>
          _matchesSessionFilters(provider, session) &&
          provider.isSessionAvailable(session),
    );
    setState(() {
      _selectedSessionKeys.addAll(visible.map(_sessionKey));
    });
  }

  Future<void> _archiveSelectedSessions(ChatProvider provider) async {
    final selected = _selectedSessions(provider);
    if (selected.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          'Archive ${selected.length} session${selected.length == 1 ? '' : 's'}?',
        ),
        content: const Text(
          'They will leave the session list but remain available in Archive.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.orange.shade700,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Archive'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    for (final session in selected) {
      provider.archiveSession(session.id, serverId: session.serverId);
    }
    _exitSelection();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${selected.length} sessions archived')),
    );
  }

  Future<void> _deleteSelectedSessions(ChatProvider provider) async {
    final selected = _selectedSessions(provider);
    if (selected.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          'Delete ${selected.length} session${selected.length == 1 ? '' : 's'}?',
        ),
        content: const Text('This permanently deletes their saved history.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    for (final session in selected) {
      provider.deleteSession(session.id, serverId: session.serverId);
    }
    _exitSelection();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${selected.length} sessions deleted')),
    );
  }

  String _projectLabelForCwd(String cwd) {
    final parts = cwd
        .split(RegExp(r'[\\/]'))
        .where((part) => part.isNotEmpty)
        .toList();
    if (parts.isEmpty) return cwd.isEmpty ? 'Untitled' : cwd;
    return parts.last;
  }

  String _backendLabelForFilter(String? backend) {
    if (backend == null) return 'All backends';
    return _backendLabel(backend);
  }

  String _serverFilterLabel(ChatProvider provider) {
    final selected = _selectedServerFilterIds;
    final label = selected.isEmpty
        ? 'All computers'
        : selected.length == 1
        ? provider.serverConfigs
                  .where((c) => selected.contains(c.id))
                  .firstOrNull
                  ?.name ??
              'All computers'
        : '${selected.length} computers';
    return _connectedOnlyFilter ? '$label · Connected' : label;
  }

  bool _matchesComputerFilter(ChatProvider provider, String serverId) =>
      ComputerFilterSelection(
        _selectedServerFilterIds,
        _connectedOnlyFilter,
      ).includes(
        serverId,
        connected:
            provider.connMgr.statusOf(serverId) == ConnectionStatus.connected,
      );

  bool _matchesSessionFilters(ChatProvider provider, Session session) {
    if (!_matchesComputerFilter(provider, session.serverId)) return false;
    final backend = session.backend ?? 'claude';
    if (_backendFilter != null && backend != _backendFilter) return false;

    final query = _searchQuery.trim().toLowerCase();
    if (query.isEmpty) return true;
    return session.title.toLowerCase().contains(query) ||
        session.cwd.toLowerCase().contains(query) ||
        session.messagePreview.toLowerCase().contains(query) ||
        session.serverName.toLowerCase().contains(query) ||
        backend.toLowerCase().contains(query);
  }

  Future<void> _showServerFilterSheet(
    BuildContext context,
    ChatProvider provider,
  ) async {
    final counts = <String, int>{};
    for (final session in provider.sessions) {
      counts.update(session.serverId, (count) => count + 1, ifAbsent: () => 1);
    }
    final selected = await showDialog<ComputerFilterSelection>(
      context: context,
      builder: (_) => ComputerFilterDialog(
        computers: [
          for (final config in provider.serverConfigs)
            ComputerFilterOption(
              id: config.id,
              name: config.name,
              sessionCount: counts[config.id] ?? 0,
              connected:
                  provider.connMgr.statusOf(config.id) ==
                  ConnectionStatus.connected,
            ),
        ],
        selection: ComputerFilterSelection({
          ..._selectedServerFilterIds,
        }, _connectedOnlyFilter),
      ),
    );
    if (selected == null || !mounted) return;
    setState(() {
      _selectedServerFilterIds
        ..clear()
        ..addAll(selected.ids);
      _connectedOnlyFilter = selected.connectedOnly;
    });
    _saveFilters();
  }

  Widget _desktopFilters(BuildContext context, ChatProvider provider) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton(
              onPressed: () => _showServerFilterSheet(context, provider),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
              child: Text(
                _serverFilterLabel(provider),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: PopupMenuButton<String>(
              tooltip: 'Backend filter',
              initialValue: _backendFilter ?? 'all',
              onSelected: (value) {
                setState(() => _backendFilter = value == 'all' ? null : value);
                _saveFilters();
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'all', child: Text('All backends')),
                PopupMenuItem(value: 'codex', child: Text('Codex')),
                PopupMenuItem(value: 'claude', child: Text('Claude')),
              ],
              child: Container(
                height: 36,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                decoration: BoxDecoration(
                  border: Border.all(
                    color: Theme.of(context).colorScheme.outline,
                  ),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Center(
                  child: Text(
                    _backendLabelForFilter(_backendFilter),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterChipBar(BuildContext context, ChatProvider provider) {
    final theme = Theme.of(context);
    final activeFilters =
        _selectedServerFilterIds.isNotEmpty ||
        _connectedOnlyFilter ||
        _backendFilter != null ||
        _searchQuery.trim().isNotEmpty;

    return Material(
      color: theme.colorScheme.surface,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.sidebar)
            _desktopFilters(context, provider)
          else
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
              child: Row(
                children: [
                  ActionChip(
                    avatar: Icon(
                      _connectedOnlyFilter
                          ? Icons.cloud_done
                          : _selectedServerFilterIds.isEmpty
                          ? Icons.all_inbox
                          : Icons.dns,
                      size: 18,
                    ),
                    label: Text(_serverFilterLabel(provider)),
                    onPressed: () => _showServerFilterSheet(context, provider),
                  ),
                  const SizedBox(width: 8),
                  PopupMenuButton<String>(
                    tooltip: 'Backend filter',
                    initialValue: _backendFilter ?? 'all',
                    onSelected: (value) {
                      setState(() {
                        _backendFilter = value == 'all' ? null : value;
                      });
                      _saveFilters();
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'all', child: Text('All backends')),
                      PopupMenuItem(value: 'codex', child: Text('Codex')),
                      PopupMenuItem(value: 'claude', child: Text('Claude')),
                    ],
                    child: Chip(
                      avatar: Icon(
                        _backendFilter == 'codex'
                            ? Icons.code
                            : _backendFilter == 'claude'
                            ? Icons.psychology_alt
                            : Icons.hub,
                        size: 18,
                      ),
                      label: Text(_backendLabelForFilter(_backendFilter)),
                    ),
                  ),
                  const SizedBox(width: 4),
                  if (!widget.sidebar)
                    IconButton(
                      icon: Icon(_searchOpen ? Icons.search_off : Icons.search),
                      tooltip: _searchOpen ? 'Hide search' : 'Search sessions',
                      onPressed: () {
                        setState(() {
                          _searchOpen = !_searchOpen;
                          if (!_searchOpen) {
                            _searchQuery = '';
                            _searchController.clear();
                            _globalSearchDebounce?.cancel();
                            _globalSearchGeneration++;
                            _globalSearchLoading = false;
                            _globalSearchResults = const [];
                          }
                        });
                      },
                    ),
                  if (activeFilters)
                    IconButton(
                      icon: const Icon(Icons.clear_all),
                      tooltip: 'Clear filters',
                      onPressed: () {
                        setState(() {
                          _selectedServerFilterIds.clear();
                          _connectedOnlyFilter = false;
                          _backendFilter = null;
                          _searchQuery = '';
                          _searchController.clear();
                          _globalSearchDebounce?.cancel();
                          _globalSearchGeneration++;
                          _globalSearchLoading = false;
                          _globalSearchResults = const [];
                        });
                        _saveFilters();
                      },
                    ),
                ],
              ),
            ),
          if (_searchOpen || widget.sidebar)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: TextField(
                controller: _searchController,
                autofocus: !widget.sidebar,
                decoration: InputDecoration(
                  hintText: widget.sidebar
                      ? 'Search sessions'
                      : 'Search every computer and session...',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _searchQuery.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () {
                            setState(() {
                              _searchQuery = '';
                              _searchController.clear();
                              _globalSearchDebounce?.cancel();
                              _globalSearchGeneration++;
                              _globalSearchLoading = false;
                              _globalSearchResults = const [];
                            });
                          },
                        ),
                  isDense: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onChanged: _handleSearchChanged,
              ),
            ),
          Divider(
            height: 1,
            color: theme.colorScheme.outlineVariant.withAlpha(80),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionedSessionList(
    BuildContext context,
    ChatProvider provider,
  ) {
    final forest = filterSessionForest(
      buildSessionForest(provider.sessions),
      (session) => _matchesSessionFilters(provider, session),
    );
    if (forest.isEmpty) {
      return Center(
        child: Text(
          provider.sessions.isEmpty
              ? (provider.isLoadingSessionCache
                    ? 'Loading sessions…'
                    : 'No sessions yet')
              : 'No matching sessions',
          style: TextStyle(
            fontSize: 14,
            color: Theme.of(context).colorScheme.outline,
          ),
        ),
      );
    }

    final seen = <String>{};
    List<SessionTreeNode> take(bool Function(SessionTreeNode node) predicate) {
      final result = <SessionTreeNode>[];
      for (final node in forest) {
        final key = _sessionKey(node.session);
        if (seen.contains(key) || !predicate(node)) continue;
        seen.add(key);
        result.add(node);
      }
      return result;
    }

    final working = take((node) => node.isRunning);
    working.sort(compareWorkingSessionTreesByStart);
    final pinned = take(
      (node) =>
          node.sessions.any((session) => provider.isSessionPinned(session.id)),
    );
    final recent = take((node) => true)
      ..sort(
        (left, right) =>
            sessionTreeLastActive(right).compareTo(sessionTreeLastActive(left)),
      );

    final children = <({Key key, Widget Function() build})>[];
    void addSection(String title, List<SessionTreeNode> sectionRoots) {
      if (sectionRoots.isEmpty) return;
      final sessionCount = sectionRoots.fold<int>(
        0,
        (total, node) => total + node.sessionCount,
      );
      children.add((
        key: ValueKey('section-$title'),
        build: () => _buildSessionSectionHeader(context, title, sessionCount),
      ));
      for (var i = 0; i < sectionRoots.length; i++) {
        final node = sectionRoots[i];
        children.add((
          key: ValueKey('session-${_sessionKey(node.session)}'),
          build: () => _buildSessionTreeNode(context, node),
        ));
        if (i != sectionRoots.length - 1) {
          children.add((
            key: ValueKey('divider-${_sessionKey(node.session)}'),
            build: () => Divider(
              height: 1,
              indent: 48,
              color: Theme.of(context).colorScheme.outlineVariant.withAlpha(80),
            ),
          ));
        }
      }
    }

    addSection('Working', working);
    addSection('Pinned', pinned);
    addSection('Recent', recent);

    final indices = {
      for (var i = 0; i < children.length; i++) children[i].key: i,
    };
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 80),
      itemCount: children.length,
      findChildIndexCallback: (key) => indices[key],
      itemBuilder: (context, index) => KeyedSubtree(
        key: children[index].key,
        child: children[index].build(),
      ),
    );
  }

  Widget _buildGlobalSearchResults(
    BuildContext context,
    ChatProvider provider,
  ) {
    final visible = _globalSearchResults.where((session) {
      if (!_matchesComputerFilter(
        provider,
        session['_serverId'] as String? ?? '',
      )) {
        return false;
      }
      if (_backendFilter != null &&
          (session['backend'] ?? 'claude') != _backendFilter) {
        return false;
      }
      return true;
    }).toList();
    if (_globalSearchLoading && visible.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (visible.isEmpty) {
      return Center(
        child: Text(
          'No matching sessions on connected computers',
          style: TextStyle(color: Theme.of(context).colorScheme.outline),
        ),
      );
    }
    return Column(
      children: [
        if (_globalSearchLoading) const LinearProgressIndicator(minHeight: 2),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.only(bottom: 80),
            itemCount: visible.length,
            separatorBuilder: (_, _) => const Divider(height: 1, indent: 56),
            itemBuilder: (context, index) {
              final session = visible[index];
              final backend = session['backend']?.toString() ?? 'claude';
              final title = session['title']?.toString().trim();
              final preview = session['firstMessage']?.toString() ?? '';
              final cwd = session['cwd']?.toString() ?? '';
              final serverId = session['_serverId']?.toString() ?? '';
              final serverName = session['_serverName']?.toString() ?? '';
              return ListTile(
                leading: CircleAvatar(
                  child: Icon(
                    backend == 'codex' ? Icons.code : Icons.psychology_alt,
                    size: 18,
                  ),
                ),
                title: Text(
                  title != null && title.isNotEmpty ? title : preview,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  [
                    serverName,
                    _backendLabel(backend),
                    if (cwd.isNotEmpty) _projectLabelForCwd(cwd),
                    if (DateTime.tryParse(
                          session['lastActive']?.toString() ?? '',
                        )
                        case final lastActive?)
                      formatTimeAgo(lastActive),
                  ].where((part) => part.isNotEmpty).join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _openSession(
                  context,
                  sessionId: session['sessionId']?.toString(),
                  cwd: cwd,
                  serverId: serverId,
                  backend: backend,
                  sdkSession: session['tracked'] != true,
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildSessionSectionHeader(
    BuildContext context,
    String title,
    int count,
  ) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
      child: Row(
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
              color: theme.colorScheme.onSurface.withAlpha(140),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '$count',
            style: TextStyle(
              fontSize: 11,
              color: theme.colorScheme.onSurface.withAlpha(100),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Selector<ChatProvider, List<Object?>>(
      selector: (context, provider) => [
        provider.activeSessionId,
        provider.activeSessionServerId,
        provider.activeServerId,
        provider.connectionStatus,
        provider.isLoadingSessionCache,
        for (final config in provider.serverConfigs) ...[
          config,
          provider.connMgr.statusOf(config.id),
          [...provider.backendsForServer(config.id)],
        ],
        for (final session in provider.sessions)
          (
            session,
            provider.isSessionPinned(session.id),
            provider.isNotifEnabled(session.id),
          ),
      ],
      builder: (context, selection, _) {
        final provider = context.read<ChatProvider>();
        final configs = provider.serverConfigs;

        // No servers configured — show onboarding
        if (configs.isEmpty) {
          return const OnboardingScreen();
        }

        _selectedServerFilterIds.retainAll(configs.map((config) => config.id));
        return Scaffold(
          appBar: AppBar(
            automaticallyImplyLeading: false,
            toolbarHeight: widget.sidebar ? 56 : null,
            titleTextStyle: widget.sidebar
                ? Theme.of(context).textTheme.titleMedium
                : null,
            leading: _selectionMode
                ? IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: 'Cancel selection',
                    onPressed: _exitSelection,
                  )
                : null,
            title: Text(
              _selectionMode
                  ? '${_selectedSessions(provider).length} selected'
                  : 'Sessions',
            ),
            actions: _selectionMode
                ? [
                    IconButton(
                      icon: const Icon(Icons.select_all),
                      tooltip: 'Select all visible',
                      onPressed: () => _selectAllVisible(provider),
                    ),
                    IconButton(
                      icon: const Icon(Icons.archive_outlined),
                      tooltip: 'Archive selected',
                      onPressed: _selectedSessions(provider).isEmpty
                          ? null
                          : () => _archiveSelectedSessions(provider),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline),
                      tooltip: 'Delete selected',
                      onPressed: _selectedSessions(provider).isEmpty
                          ? null
                          : () => _deleteSelectedSessions(provider),
                    ),
                  ]
                : [
                    IconButton(
                      icon: const Icon(Icons.checklist),
                      tooltip: 'Select sessions',
                      onPressed: () => setState(() {
                        _selectionMode = true;
                        _searchOpen = false;
                        _searchQuery = '';
                        _searchController.clear();
                        _globalSearchDebounce?.cancel();
                        _globalSearchGeneration++;
                        _globalSearchLoading = false;
                        _globalSearchResults = const [];
                      }),
                    ),
                    IconButton(
                      icon: const Icon(Icons.inventory_2_outlined),
                      tooltip: 'Archived Sessions',
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const ArchiveScreen(),
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.swap_horiz),
                      tooltip: 'Transfers',
                      onPressed: () => _showTeleportHistory(context),
                    ),
                    _buildConnectionIndicator(provider),
                  ],
          ),
          body: LightBackdrop(
            child: Column(
              children: [
                _buildUpdateBanner(context),
                if (widget.sidebar && !_selectionMode)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: () =>
                            _showSessionActionMenu(context, provider),
                        icon: const Icon(Icons.add, size: 18),
                        label: const Text('New session'),
                      ),
                    ),
                  ),
                _buildFilterChipBar(context, provider),
                if (_searchQuery.trim().isNotEmpty)
                  Expanded(child: _buildGlobalSearchResults(context, provider))
                else if (provider.sessions.isEmpty)
                  Expanded(child: _buildEmptyState(context))
                else
                  Expanded(
                    child: _buildSectionedSessionList(context, provider),
                  ),
              ],
            ),
          ),
          floatingActionButton: _selectionMode || widget.sidebar
              ? null
              : FloatingActionButton.extended(
                  onPressed: () => _showSessionActionMenu(context, provider),
                  icon: const Icon(Icons.add),
                  label: const Text('Session'),
                ),
        );
      },
    );
  }

  Widget _buildUpdateBanner(BuildContext context) {
    final shell = context.findAncestorStateOfType<MainShellScreenState>();
    if (shell == null) {
      return const SizedBox.shrink();
    }
    // This tab is a const child of the shell, so the shell rebuilding on update
    // progress never reaches it. Listen here so a click shows progress at once.
    return ListenableBuilder(
      listenable: Listenable.merge([
        shell.updateService,
        shell.updateBannerDismissed,
      ]),
      builder: (context, _) => _updateBannerContent(context, shell),
    );
  }

  Widget _updateBannerContent(
    BuildContext context,
    MainShellScreenState shell,
  ) {
    if (!shell.updateService.updateAvailable ||
        shell.updateBannerDismissed.value) {
      return const SizedBox.shrink();
    }
    final info = shell.updateService.updateInfo!;
    final updateService = shell.updateService;
    final downloading = updateService.isDownloading;
    final downloaded = updateService.hasDownloadedUpdate;
    final openingInstaller = updateService.isOpeningInstaller;
    final progress = updateService.downloadProgress;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            Theme.of(context).colorScheme.primary.withAlpha(40),
            Theme.of(context).colorScheme.primary.withAlpha(20),
          ],
        ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: Theme.of(context).colorScheme.primary.withAlpha(80),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Icon(
              Icons.system_update,
              size: 20,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                info.fromPlay
                    ? 'Update available on Google Play'
                    : 'Update available: v${info.currentVersion} \u2192 v${info.latestVersion}',
                style: const TextStyle(fontSize: 13),
              ),
            ),
            TextButton(
              onPressed: shell.dismissUpdateBanner,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('Later', style: TextStyle(fontSize: 12)),
            ),
            const SizedBox(width: 4),
            FilledButton(
              onPressed: downloading || openingInstaller
                  ? null
                  : downloaded
                  ? updateService.installDownloaded
                  : () => unawaited(updateService.downloadUpdate()),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: openingInstaller
                  ? const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox.square(
                          dimension: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        SizedBox(width: 6),
                        Text('Opening', style: TextStyle(fontSize: 12)),
                      ],
                    )
                  : downloading
                  ? Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox.square(
                          dimension: 14,
                          child: CircularProgressIndicator(
                            value: progress,
                            strokeWidth: 2,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          progress == null
                              ? 'Downloading'
                              : '${(progress * 100).round()}%',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ],
                    )
                  : Text(
                      downloaded
                          ? updateService.isDesktopUpdate
                                ? 'Install & restart'
                                : 'Install'
                          : 'Download',
                      style: const TextStyle(fontSize: 12),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.chat_bubble_outline,
            size: 64,
            color: Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(height: 16),
          Text(
            'No sessions yet',
            style: TextStyle(
              fontSize: 18,
              color: Theme.of(context).colorScheme.outline,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Start a new session or resume an existing one',
            style: TextStyle(
              fontSize: 14,
              color: Theme.of(context).colorScheme.outline.withAlpha(178),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showSessionContextMenu(
    BuildContext context,
    Session session, {
    Rect? anchor,
  }) async {
    final provider = context.read<ChatProvider>();
    final notifEnabled = provider.isNotifEnabled(session.id);
    final isPinned = provider.isSessionPinned(session.id);
    final theme = Theme.of(context);
    final action = await showAdaptiveActionSheet<_SessionMenuAction>(
      context: context,
      anchor: anchor,
      title: session.title,
      subtitle: session.backend == 'codex' ? 'Codex session' : 'Claude session',
      sections: [
        AdaptiveSheetSection([
          AdaptiveSheetAction(
            value: _SessionMenuAction.pin,
            label: isPinned ? 'Unpin' : 'Pin',
            icon: isPinned ? Icons.push_pin : Icons.push_pin_outlined,
            iconColor: isPinned ? theme.colorScheme.primary : null,
          ),
          AdaptiveSheetAction(
            value: _SessionMenuAction.notifications,
            label: notifEnabled
                ? 'Turn notifications off'
                : 'Turn notifications on',
            icon: notifEnabled
                ? Icons.notifications_active
                : Icons.notifications_off_outlined,
            iconColor: notifEnabled ? theme.colorScheme.primary : null,
          ),
          const AdaptiveSheetAction(
            value: _SessionMenuAction.rename,
            label: 'Rename',
            icon: Icons.edit_outlined,
          ),
        ]),
        AdaptiveSheetSection([
          AdaptiveSheetAction(
            value: _SessionMenuAction.fork,
            label: session.backend == 'codex' ? 'Fork thread' : 'Fork session',
            icon: Icons.fork_right,
          ),
          const AdaptiveSheetAction(
            value: _SessionMenuAction.teleport,
            label: 'Teleport session',
            icon: Icons.move_up_outlined,
          ),
          if (session.backend == 'codex')
            AdaptiveSheetAction(
              value: _SessionMenuAction.startFresh,
              label: session.freshThreadPending
                  ? 'Fresh thread ready'
                  : 'Start fresh thread',
              icon: session.freshThreadPending
                  ? Icons.check_circle_outline
                  : Icons.change_circle_outlined,
              enabled: !session.freshThreadPending,
            ),
          AdaptiveSheetAction(
            value: _SessionMenuAction.tools,
            label: session.backend == 'codex'
                ? 'Thread tools'
                : 'Session tools',
            icon: Icons.tune,
            trailing: const Icon(Icons.chevron_right),
          ),
        ]),
        AdaptiveSheetSection([
          AdaptiveSheetAction(
            value: _SessionMenuAction.archive,
            label: 'Archive',
            icon: Icons.archive_outlined,
            iconColor: context.palette.shade(Colors.orange, 300),
            textColor: context.palette.shade(Colors.orange, 300),
          ),
          AdaptiveSheetAction(
            value: _SessionMenuAction.delete,
            label: 'Delete',
            icon: Icons.delete_outline,
            iconColor: context.palette.shade(Colors.red, 300),
            textColor: context.palette.shade(Colors.red, 300),
          ),
        ]),
      ],
    );
    if (action == null || !context.mounted) return;

    switch (action) {
      case _SessionMenuAction.pin:
        provider.toggleSessionPin(session.id);
      case _SessionMenuAction.notifications:
        provider.toggleSessionNotifications(session.id);
      case _SessionMenuAction.rename:
        _showRenameDialog(context, session);
      case _SessionMenuAction.fork:
        await _forkSession(context, session);
      case _SessionMenuAction.teleport:
        _showTeleportSessionSheet(context, session);
      case _SessionMenuAction.startFresh:
        await _confirmStartFreshThread(context, session);
      case _SessionMenuAction.tools:
        await _showSessionToolsMenu(context, session, anchor: anchor);
      case _SessionMenuAction.archive:
        await _confirmArchiveSession(context, session);
      case _SessionMenuAction.delete:
        await _confirmDeleteSession(context, session);
    }
  }

  Future<void> _showSessionToolsMenu(
    BuildContext context,
    Session session, {
    Rect? anchor,
  }) async {
    final provider = context.read<ChatProvider>();
    final action = await showAdaptiveActionSheet<_SessionToolsAction>(
      context: context,
      anchor: anchor,
      title: session.backend == 'codex' ? 'Thread tools' : 'Session tools',
      sections: [
        AdaptiveSheetSection([
          if (session.backend == 'codex') ...[
            const AdaptiveSheetAction(
              value: _SessionToolsAction.compact,
              label: 'Compact thread',
              icon: Icons.compress,
            ),
            const AdaptiveSheetAction(
              value: _SessionToolsAction.rollback,
              label: 'Rollback last turn',
              icon: Icons.history,
            ),
          ],
          const AdaptiveSheetAction(
            value: _SessionToolsAction.clearContext,
            label: 'Clear context',
            icon: Icons.refresh,
          ),
          if (session.backend != 'codex')
            AdaptiveSheetAction(
              value: _SessionToolsAction.blockedTools,
              label: 'Blocked tools',
              subtitle: () {
                final blocked = provider.getDisallowedTools(session.id);
                return blocked.isEmpty
                    ? 'None blocked'
                    : '${blocked.length} blocked';
              }(),
              icon: Icons.block,
            ),
          if (session.backend != 'codex' &&
              provider.supportsAdditionalDirectories(session.serverId))
            AdaptiveSheetAction(
              value: _SessionToolsAction.extraFolders,
              label: 'Extra folders',
              subtitle: _folderCount(
                provider.getAdditionalDirectories(session.id).length,
              ),
              icon: Icons.create_new_folder_outlined,
            ),
          AdaptiveSheetAction(
            value: _SessionToolsAction.instructions,
            label: session.backend == 'codex'
                ? 'Additional instructions'
                : 'System prompt',
            icon: Icons.description_outlined,
          ),
        ]),
      ],
    );
    if (action == null || !context.mounted) return;

    switch (action) {
      case _SessionToolsAction.compact:
        provider.compactCodexThread(session.id);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Codex compact requested')),
        );
      case _SessionToolsAction.rollback:
        await _confirmCodexRollback(context, session);
      case _SessionToolsAction.clearContext:
        await _confirmClearContext(context, session);
      case _SessionToolsAction.blockedTools:
        _showBlockedToolsDialog(context, session);
      case _SessionToolsAction.extraFolders:
        await showExtraFoldersDialog(
          context,
          provider: provider,
          sessionId: session.id,
          serverId: session.serverId,
        );
      case _SessionToolsAction.instructions:
        _showSystemPromptDialog(context, session);
    }
  }

  void _showTeleportHistory(BuildContext context) {
    final provider = context.read<ChatProvider>();
    showDialog<void>(
      context: context,
      builder: (dialogContext) => TransferHistoryDialog(
        load: provider.sessionTeleportHistory,
        itemBuilder: (context, job) {
          final completed = job['phase'] == 'completed';
          final result = job['result'] as Map?;
          final session = result?['session'] as Map?;
          final destination = job['destinationServerId'] as String?;
          final source = provider.sessions
              .where(
                (s) =>
                    s.serverId == job['serverId'] && s.id == job['sessionId'],
              )
              .firstOrNull;
          final progress = teleportProgress(job);
          final label = switch (job['phase']) {
            'completed' => 'Complete',
            'failed' => 'Paused',
            'preparing' => 'Preparing',
            'importing' => 'Restoring session',
            'finalizing' => 'Finishing',
            'transferring' => 'Transferring',
            _ => 'Waiting for connection',
          };
          return ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(
              session?['title'] as String? ??
                  source?.title ??
                  'Session transfer',
            ),
            subtitle: Text(
              '${job['serverName']} → ${job['destinationServerName'] ?? 'Destination'}\n$label${progress.total > 0 && !completed ? ' · ${(progress.done / progress.total * 100).round()}%' : ''}${job['warning'] != null ? '\n${job['warning']}' : ''}${job['error'] != null ? '\n${job['error']}' : ''}',
            ),
            trailing: destination == null
                ? null
                : TextButton(
                    onPressed: completed && session != null
                        ? () {
                            Navigator.pop(dialogContext);
                            _openSession(
                              this.context,
                              sessionId: session['id'] as String,
                              serverId: destination,
                            );
                          }
                        : source == null
                        ? null
                        : () {
                            Navigator.pop(dialogContext);
                            _showTeleportSessionSheet(
                              this.context,
                              source,
                              resume: job,
                            );
                          },
                    child: Text(completed ? 'Open' : 'Resume'),
                  ),
          );
        },
      ),
    );
  }

  String _sessionTransferStageLabel(SessionTransferStage stage) {
    return switch (stage) {
      SessionTransferStage.exporting => 'Packing session history…',
      SessionTransferStage.waiting => 'Waiting for connection…',
      SessionTransferStage.transferring => 'Transferring between computers…',
      SessionTransferStage.importing => 'Restoring session…',
      SessionTransferStage.finalizing => 'Finishing transfer…',
    };
  }

  /// Asks how to transfer a very large transcript. Returns true to truncate,
  /// false to keep it whole, and null to cancel.
  Future<bool?> _confirmLargeTranscript(
    BuildContext context, {
    required int fullBytes,
    required int truncatedBytes,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Large transcript'),
        content: Text(
          'Full: ${formatBytes(fullBytes)}\n'
          'Truncated: ${formatBytes(truncatedBytes)}\n\n'
          'Truncating keeps the first 1 KB of each large tool output. '
          'Remember search finds the same results, but those outputs '
          'can no longer be read in full.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Truncate'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Keep full'),
          ),
        ],
      ),
    );
  }

  void _showTeleportSessionSheet(
    BuildContext context,
    Session session, {
    Map<String, dynamic>? resume,
  }) {
    final provider = context.read<ChatProvider>();
    final connectedServers = provider.serverConfigs
        .where(
          (server) =>
              provider.connMgr.statusOf(server.id) ==
              ConnectionStatus.connected,
        )
        .toList();
    if (connectedServers.isEmpty || session.serverId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'The source computer must be connected to transfer this session',
          ),
        ),
      );
      return;
    }

    var destinationServerId =
        connectedServers
            .where((server) => server.id != session.serverId)
            .firstOrNull
            ?.id ??
        connectedServers
            .where((server) => server.id == session.serverId)
            .firstOrNull
            ?.id ??
        connectedServers.first.id;

    String initialBackendFor(String serverId) {
      final backends = provider.backendsForServer(serverId);
      final sourceBackend = session.backend ?? 'claude';
      if (serverId == session.serverId && backends.length > 1) {
        return backends.firstWhere(
          (backend) => backend != sourceBackend,
          orElse: () => sourceBackend,
        );
      }
      return backends.contains(sourceBackend)
          ? sourceBackend
          : backends.firstOrNull ?? 'claude';
    }

    String initialCwdFor(String serverId) {
      if (serverId == session.serverId) return session.cwd;
      final configured = connectedServers
          .where((server) => server.id == serverId)
          .firstOrNull
          ?.defaultCwd;
      return configured?.isNotEmpty == true ? configured! : session.cwd;
    }

    destinationServerId =
        resume?['destinationServerId'] as String? ?? destinationServerId;
    var destinationBackend =
        resume?['targetBackend'] as String? ??
        initialBackendFor(destinationServerId);
    var move = resume == null || resume['mode'] == 'move';
    var transferring = false;
    SessionTransferStage? stage;
    var progressDone = 0;
    var progressTotal = 0;
    String? error;
    final cwdController = TextEditingController(
      text:
          resume?['targetCwd'] as String? ?? initialCwdFor(destinationServerId),
    );

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (sheetContext, setSheetState) {
            final destinationBackends = provider.backendsForServer(
              destinationServerId,
            );
            if (!destinationBackends.contains(destinationBackend)) {
              destinationBackend = destinationBackends.firstOrNull ?? 'claude';
            }
            final sameNativeTarget =
                destinationServerId == session.serverId &&
                destinationBackend == (session.backend ?? 'claude');
            final exactClaudeMove =
                move &&
                destinationServerId != session.serverId &&
                (session.backend ?? 'claude') == 'claude' &&
                destinationBackend == 'claude';

            Future<void> startTransfer() async {
              if (cwdController.text.trim().isEmpty) {
                setSheetState(() => error = 'Choose a destination folder.');
                return;
              }
              if (move && sameNativeTarget) {
                setSheetState(
                  () => error =
                      'A move on the same computer must switch harnesses. '
                      'Choose Clone to duplicate it instead.',
                );
                return;
              }
              setSheetState(() {
                transferring = true;
                error = null;
                stage = SessionTransferStage.exporting;
              });
              try {
                // A resumed job keeps the choice it was started with.
                var truncateTranscript = resume?['transcript'] == 'truncated';
                if (resume == null) {
                  final size = await provider.estimateSessionTransfer(session);
                  if (size.fullBytes >= _largeTranscriptBytes &&
                      size.truncatedBytes < size.fullBytes) {
                    if (!sheetContext.mounted) return;
                    final truncate = await _confirmLargeTranscript(
                      sheetContext,
                      fullBytes: size.fullBytes,
                      truncatedBytes: size.truncatedBytes,
                    );
                    if (!sheetContext.mounted) return;
                    if (truncate == null) {
                      setSheetState(() {
                        transferring = false;
                        stage = null;
                      });
                      return;
                    }
                    truncateTranscript = truncate;
                  }
                }
                final result = await provider.transferSession(
                  source: session,
                  destinationServerId: destinationServerId,
                  destinationCwd: cwdController.text,
                  destinationBackend: destinationBackend,
                  move: move,
                  truncateTranscript: truncateTranscript,
                  resumeJobId: resume?['jobId'] as String?,
                  keepWatching: () => sheetContext.mounted,
                  onProgress: (done, total) {
                    if (!sheetContext.mounted) return;
                    setSheetState(() {
                      progressDone = done;
                      progressTotal = total;
                    });
                  },
                  onStage: (next) {
                    if (!sheetContext.mounted) return;
                    setSheetState(() => stage = next);
                  },
                );
                if (!sheetContext.mounted || result == null) return;
                Navigator.pop(sheetContext);
                final verb = move ? 'moved' : 'cloned';
                final resumeDescription = result.exactNativeResume
                    ? 'with its native Claude thread'
                    : 'with a new ${destinationBackend == 'codex' ? 'Codex' : 'Claude'} thread';
                if (!context.mounted) return;
                showDialog<void>(
                  context: context,
                  builder: (dialogContext) => AlertDialog(
                    title: Text('Session $verb'),
                    content: Text(
                      result.warning ?? 'Ready $resumeDescription.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(dialogContext),
                        child: const Text('Done'),
                      ),
                      FilledButton(
                        onPressed: () {
                          Navigator.pop(dialogContext);
                          _openSession(
                            context,
                            sessionId: result.session.id,
                            serverId: result.session.serverId,
                          );
                        },
                        child: const Text('Open session'),
                      ),
                    ],
                  ),
                );
              } catch (transferError) {
                if (!sheetContext.mounted) return;
                setSheetState(() {
                  transferring = false;
                  stage = null;
                  error = transferError.toString().replaceFirst(
                    RegExp(r'^(Bad state|StateError):\s*'),
                    '',
                  );
                });
              }
            }

            return Padding(
              padding: EdgeInsets.fromLTRB(
                20,
                12,
                20,
                20 + MediaQuery.viewInsetsOf(sheetContext).bottom,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.move_up_outlined),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Teleport Session',
                                style: TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              Text(
                                session.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(
                                  sheetContext,
                                ).textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    SegmentedButton<bool>(
                      segments: const [
                        ButtonSegment(
                          value: true,
                          icon: Icon(Icons.drive_file_move_outline),
                          label: Text('Move'),
                        ),
                        ButtonSegment(
                          value: false,
                          icon: Icon(Icons.copy_outlined),
                          label: Text('Clone'),
                        ),
                      ],
                      selected: {move},
                      onSelectionChanged:
                          transferring || resume != null || resume != null
                          ? null
                          : (selection) {
                              setSheetState(() {
                                move = selection.first;
                                error = null;
                              });
                            },
                    ),
                    const SizedBox(height: 16),
                    DropdownButtonFormField<String>(
                      key: ValueKey('teleport-server-$destinationServerId'),
                      initialValue: destinationServerId,
                      decoration: const InputDecoration(
                        labelText: 'Destination computer',
                        border: OutlineInputBorder(),
                      ),
                      items: connectedServers
                          .map(
                            (server) => DropdownMenuItem(
                              value: server.id,
                              child: Text(server.name),
                            ),
                          )
                          .toList(),
                      onChanged: transferring || resume != null
                          ? null
                          : (serverId) {
                              if (serverId == null) return;
                              setSheetState(() {
                                destinationServerId = serverId;
                                destinationBackend = initialBackendFor(
                                  serverId,
                                );
                                cwdController.text = initialCwdFor(serverId);
                                error = null;
                              });
                            },
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      key: ValueKey(
                        'teleport-backend-$destinationServerId-$destinationBackend',
                      ),
                      initialValue: destinationBackend,
                      decoration: const InputDecoration(
                        labelText: 'Harness',
                        border: OutlineInputBorder(),
                      ),
                      items: destinationBackends
                          .map(
                            (backend) => DropdownMenuItem(
                              value: backend,
                              child: Text(
                                backend == 'codex' ? 'Codex' : 'Claude',
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: transferring || resume != null
                          ? null
                          : (backend) {
                              if (backend == null) return;
                              setSheetState(() {
                                destinationBackend = backend;
                                error = null;
                              });
                            },
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: cwdController,
                      enabled: !transferring && resume == null,
                      decoration: InputDecoration(
                        labelText: 'Destination project folder',
                        border: const OutlineInputBorder(),
                        suffixIcon: IconButton(
                          tooltip: 'Browse',
                          onPressed: transferring
                              ? null
                              : () async {
                                  final selected = await _showFolderBrowser(
                                    sheetContext,
                                    provider,
                                    serverId: destinationServerId,
                                  );
                                  if (selected == null ||
                                      !sheetContext.mounted) {
                                    return;
                                  }
                                  setSheetState(() {
                                    cwdController.text = selected;
                                    error = null;
                                  });
                                },
                          icon: const Icon(Icons.folder_open),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Theme.of(
                          sheetContext,
                        ).colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        exactClaudeMove
                            ? 'The native Claude thread, SocketAgent history, '
                                  'tasks, and plans will resume intact.'
                            : 'SocketAgent history, tasks, and plans will move '
                                  'intact. The destination harness starts a new '
                                  'native thread with handoff context.',
                        style: Theme.of(sheetContext).textTheme.bodySmall,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Project files are not copied. The destination folder '
                      'must already contain the project checkout and any files '
                      'the session needs.',
                      style: Theme.of(sheetContext).textTheme.bodySmall,
                    ),
                    if (error != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        error!,
                        style: TextStyle(
                          color: Theme.of(sheetContext).colorScheme.error,
                        ),
                      ),
                    ],
                    if (transferring && stage != null) ...[
                      const SizedBox(height: 16),
                      Text(_sessionTransferStageLabel(stage!)),
                      if (progressTotal > 0) ...[
                        const SizedBox(height: 8),
                        LinearProgressIndicator(
                          value: (progressDone / progressTotal).clamp(0, 1),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${(progressDone / progressTotal * 100).round()}%',
                        ),
                      ],
                      const SizedBox(height: 8),
                      const Text(
                        'You can close this view. The computers will keep transferring, even if your phone disconnects.',
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(sheetContext),
                        child: const Text('Close'),
                      ),
                    ],
                    const SizedBox(height: 20),
                    FilledButton.icon(
                      onPressed: transferring ? null : startTransfer,
                      icon: Icon(move ? Icons.move_up : Icons.copy_outlined),
                      label: Text(
                        resume != null
                            ? 'Resume transfer'
                            : move
                            ? 'Move session'
                            : 'Clone session',
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    ).whenComplete(cwdController.dispose);
  }

  void _showBlockedToolsDialog(BuildContext context, Session session) {
    final provider = context.read<ChatProvider>();
    final allTools = provider.availableTools;
    final currentBlocked = Set<String>.from(
      provider.getDisallowedTools(session.id),
    );

    if (allTools.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'No tools available yet — open the session first to load the tools list',
          ),
        ),
      );
      return;
    }

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          return AlertDialog(
            title: const Text('Blocked Tools'),
            content: SizedBox(
              width: double.maxFinite,
              height: 400,
              child: ListView.builder(
                itemCount: allTools.length,
                itemBuilder: (_, index) {
                  final tool = allTools[index];
                  final isBlocked = currentBlocked.contains(tool);
                  return CheckboxListTile(
                    dense: true,
                    title: Text(tool, style: const TextStyle(fontSize: 13)),
                    value: isBlocked,
                    onChanged: (val) {
                      setDialogState(() {
                        if (val == true) {
                          currentBlocked.add(tool);
                        } else {
                          currentBlocked.remove(tool);
                        }
                      });
                    },
                  );
                },
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              if (currentBlocked.isNotEmpty)
                TextButton(
                  onPressed: () {
                    setDialogState(() => currentBlocked.clear());
                  },
                  child: const Text('Clear All'),
                ),
              TextButton(
                onPressed: () {
                  provider.setDisallowedTools(
                    session.id,
                    currentBlocked.toList(),
                  );
                  Navigator.pop(ctx);
                },
                child: const Text('Save'),
              ),
            ],
          );
        },
      ),
    );
  }

  void _showSystemPromptDialog(BuildContext context, Session session) {
    final provider = context.read<ChatProvider>();
    final sessionPrompt = provider.getSessionSystemPrompt(session.id);
    final serverDefault = provider.getEffectiveSystemPrompt(session.id);
    final controller = TextEditingController(text: sessionPrompt);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          session.backend == 'codex'
              ? 'Additional Instructions'
              : 'System Prompt',
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (serverDefault.isNotEmpty && sessionPrompt.isEmpty) ...[
              Text(
                'Computer default:',
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).colorScheme.onSurface.withAlpha(128),
                ),
              ),
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  serverDefault.length > 200
                      ? '${serverDefault.substring(0, 200)}...'
                      : serverDefault,
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withAlpha(178),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Override for this session (leave empty to use computer default):',
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).colorScheme.onSurface.withAlpha(128),
                ),
              ),
              const SizedBox(height: 4),
            ] else ...[
              Text(
                session.backend == 'codex'
                    ? 'Developer instructions sent to Codex for this session:'
                    : 'Extra instructions appended to the default agent prompt:',
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).colorScheme.onSurface.withAlpha(128),
                ),
              ),
              const SizedBox(height: 8),
            ],
            TextField(
              controller: controller,
              maxLines: 6,
              decoration: InputDecoration(
                hintText: 'e.g. Always respond in Spanish...',
                border: const OutlineInputBorder(),
                filled: true,
                fillColor: Theme.of(
                  context,
                ).colorScheme.surfaceContainerHighest,
              ),
              style: const TextStyle(fontSize: 13),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          if (sessionPrompt.isNotEmpty)
            TextButton(
              onPressed: () {
                provider.setSessionSystemPrompt(session.id, '');
                Navigator.pop(ctx);
              },
              child: const Text('Clear Override'),
            ),
          TextButton(
            onPressed: () {
              provider.setSessionSystemPrompt(
                session.id,
                controller.text.trim(),
              );
              Navigator.pop(ctx);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _showRenameDialog(BuildContext context, Session session) {
    final controller = TextEditingController(
      text: session.title == 'Untitled' ? '' : session.title,
    );
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename Session'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Session name'),
          onSubmitted: (value) {
            final name = value.trim();
            if (name.isNotEmpty) {
              context.read<ChatProvider>().renameSession(session.id, name);
            }
            Navigator.pop(ctx);
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              final name = controller.text.trim();
              if (name.isNotEmpty) {
                context.read<ChatProvider>().renameSession(session.id, name);
              }
              Navigator.pop(ctx);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<bool> _confirmArchiveSession(
    BuildContext context,
    Session session,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Archive Session'),
        content: Text(
          'Archive "${session.title}"? Removes it from the list and stores history in the archive. You can restore it from the Archive screen.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.orange.shade700,
            ),
            onPressed: () {
              Navigator.pop(ctx, true);
              context.read<ChatProvider>().archiveSession(
                session.id,
                serverId: session.serverId,
              );
            },
            child: const Text('Archive'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  Future<bool> _confirmDeleteSession(
    BuildContext context,
    Session session,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Session'),
        content: Text('Delete "${session.title}"? This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),
            onPressed: () {
              Navigator.pop(ctx, true);
              context.read<ChatProvider>().deleteSession(
                session.id,
                serverId: session.serverId,
              );
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  Future<void> _confirmClearContext(
    BuildContext context,
    Session session,
  ) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear Context'),
        content: const Text(
          'This will archive the conversation history and start fresh. '
          'The session will be kept but the agent will have no memory of previous messages.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              context.read<ChatProvider>().clearSessionContext(session.id);
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(const SnackBar(content: Text('Clearing context')));
            },
            child: const Text('Clear'),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmStartFreshThread(
    BuildContext context,
    Session session,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Start a new thread?'),
        content: const Text(
          'Continue this session with less context. Its name, pin, and chat history stay here. '
          'The agent can use Remember to look up earlier transcripts.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Start new thread'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    try {
      await context.read<ChatProvider>().requestSessionMemoryRollover(
        sessionId: session.id,
        serverId: session.serverId,
      );
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Fresh thread ready')));
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not queue fresh thread: $error')),
      );
    }
  }

  Future<void> _forkSession(BuildContext context, Session session) async {
    if (!await _requireSubscription(serverId: session.serverId)) return;
    if (!context.mounted) return;

    final provider = context.read<ChatProvider>();
    provider.forkSession(session.id);
    openConversation(context);
  }

  Future<void> _confirmCodexRollback(
    BuildContext context,
    Session session,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rollback Codex Turn?'),
        content: const Text(
          'This asks Codex to remove the latest turn from the native thread. It does not restore files.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Rollback'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    context.read<ChatProvider>().rollbackCodexThread(session.id);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Codex rollback requested')));
  }

  Widget _buildSessionTreeNode(
    BuildContext context,
    SessionTreeNode node, {
    int depth = 0,
  }) {
    final tile = _buildSessionTile(
      context,
      node.session,
      compact: depth > 0,
      delegated: depth > 0,
    );
    if (node.children.isEmpty) return tile;

    final groupKey = _sessionKey(node.session);
    final collapsed = _collapsedDelegatedParents.contains(groupKey);
    final descendantCount = node.sessionCount - 1;
    final runningCount = node.sessions
        .skip(1)
        .where((session) => session.running)
        .length;
    final theme = Theme.of(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        tile,
        InkWell(
          key: Key('delegated-group-$groupKey'),
          onTap: () {
            setState(() {
              if (collapsed) {
                _collapsedDelegatedParents.remove(groupKey);
              } else {
                _collapsedDelegatedParents.add(groupKey);
              }
            });
          },
          child: Padding(
            padding: EdgeInsets.fromLTRB(20.0 + (depth * 16), 2, 12, 6),
            child: Row(
              children: [
                Icon(
                  Icons.account_tree_outlined,
                  size: 16,
                  color: theme.colorScheme.primary.withAlpha(180),
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    '$descendantCount agent session'
                    '${descendantCount == 1 ? '' : 's'}'
                    '${runningCount > 0 ? ' · $runningCount working' : ''}',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: runningCount > 0
                          ? theme.colorScheme.primary
                          : theme.colorScheme.onSurface.withAlpha(145),
                    ),
                  ),
                ),
                Icon(
                  collapsed ? Icons.expand_more : Icons.expand_less,
                  size: 19,
                  color: theme.colorScheme.onSurface.withAlpha(130),
                ),
              ],
            ),
          ),
        ),
        if (!collapsed)
          Container(
            margin: EdgeInsets.only(left: 20.0 + (depth * 16)),
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(
                  color: theme.colorScheme.primary.withAlpha(75),
                  width: 2,
                ),
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < node.children.length; i++) ...[
                  _buildSessionTreeNode(
                    context,
                    node.children[i],
                    depth: depth + 1,
                  ),
                  if (i != node.children.length - 1)
                    Divider(
                      height: 1,
                      indent: 40,
                      color: theme.colorScheme.outlineVariant.withAlpha(65),
                    ),
                ],
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildSessionTile(
    BuildContext context,
    Session session, {
    bool compact = false,
    bool delegated = false,
  }) {
    // Accents in the row take the backend's brand color.
    final theme = backendTheme(context, session.backend);
    final provider = context.read<ChatProvider>();
    final status = provider.sessionServerStatus(session);
    final isAvailable = provider.isSessionAvailable(session);
    final openingThisSession =
        _openingSessionKey ==
        _openSessionKey(sessionId: session.id, serverId: session.serverId);
    final showRunning = session.running && isAvailable;
    final showBusy = showRunning || openingThisSession;
    final selected = _selectedSessionKeys.contains(_sessionKey(session));
    final active =
        widget.sidebar &&
        session.id == provider.activeSessionId &&
        session.serverId == provider.activeSessionServerId;
    compact = compact || widget.sidebar;
    final timeAgo = formatTimeAgo(session.lastActive);

    String displayCwd = session.cwd;
    final homePattern = RegExp(r'^/home/[^/]+/');
    final homeExact = RegExp(r'^/home/[^/]+$');
    if (homePattern.hasMatch(displayCwd)) {
      displayCwd = '~/${displayCwd.replaceFirst(homePattern, '')}';
    } else if (homeExact.hasMatch(displayCwd)) {
      displayCwd = '~';
    }

    // Lead with the stable session name; keep recent conversation text as context.
    final hasTitle = session.title.isNotEmpty && session.title != 'Untitled';
    final previewText = session.messagePreview.trim();
    final titleOrProject = hasTitle
        ? session.title
        : _projectLabelForCwd(displayCwd);
    final primaryText = titleOrProject;
    final secondaryText = previewText;
    final showSecondaryText =
        secondaryText.trim().isNotEmpty &&
        secondaryText.trim() != primaryText.trim();
    final statusText = openingThisSession
        ? 'Opening...'
        : showRunning
        ? provider.isSessionWaitingOnAgent(session)
              ? 'Waiting on agent'
              : 'Working...'
        : timeAgo;
    final turnCountText = session.turnCount > 0
        ? '${session.turnCount} turn${session.turnCount == 1 ? '' : 's'}'
        : '';
    final metaText = [
      if (turnCountText.isNotEmpty) turnCountText,
      statusText,
      if (displayCwd.isNotEmpty) displayCwd,
    ].join(' · ');

    return Theme(
      data: theme,
      child: Dismissible(
        key: Key('${session.serverId}:${session.id}'),
        direction: !_selectionMode && isAvailable && _openingSessionKey == null
            ? DismissDirection.horizontal
            : DismissDirection.none,
        background: Container(
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.only(left: 20),
          color: Colors.blue.shade700,
          child: const Icon(Icons.cleaning_services, color: Colors.white),
        ),
        secondaryBackground: Container(
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.only(right: 20),
          color: Colors.orange.shade700,
          child: const Icon(Icons.archive, color: Colors.white),
        ),
        confirmDismiss: (dir) async {
          if (!isAvailable) {
            _showOfflineSessionSnack(context, session);
            return false;
          }
          if (dir == DismissDirection.endToStart) {
            return _confirmArchiveSession(context, session);
          }
          await _confirmClearContext(context, session);
          return false;
        },
        child: InkWell(
          onSecondaryTapUp:
              Platform.isWindows &&
                  !_selectionMode &&
                  _openingSessionKey == null
              ? (details) {
                  if (isAvailable) {
                    _showSessionContextMenu(
                      context,
                      session,
                      anchor: details.globalPosition & Size.zero,
                    );
                  } else {
                    _showOfflineSessionSnack(context, session);
                  }
                }
              : null,
          onTap: _selectionMode
              ? isAvailable
                    ? () => _toggleSessionSelection(session)
                    : () => _showOfflineSessionSnack(context, session)
              // Offline sessions open read-only on the phone's cached copy.
              : _openingSessionKey == null
              ? () => _openSession(
                  context,
                  sessionId: session.id,
                  serverId: session.serverId,
                )
              : null,
          onLongPress: isAvailable
              ? _openingSessionKey == null
                    ? () => _enterSelection(session)
                    : null
              : () => _showOfflineSessionSnack(context, session),
          child: Opacity(
            opacity: isAvailable ? 1 : 0.48,
            child: SessionBackendWatermark(
              backend: session.backend ?? 'claude',
              compact: compact,
              child: Container(
                decoration: BoxDecoration(
                  color: selected || active
                      ? theme.colorScheme.primary.withAlpha(28)
                      : null,
                  gradient: selected || active
                      ? null
                      : LinearGradient(
                          colors: [
                            theme.colorScheme.primary.withAlpha(30),
                            theme.colorScheme.primary.withAlpha(0),
                          ],
                          stops: const [0, .7],
                        ),
                  borderRadius: BorderRadius.circular(widget.sidebar ? 8 : 0),
                  border: active
                      ? Border.all(
                          color: theme.colorScheme.primary.withAlpha(90),
                        )
                      : null,
                ),
                margin: widget.sidebar
                    ? const EdgeInsets.symmetric(horizontal: 6, vertical: 2)
                    : null,
                padding: EdgeInsets.fromLTRB(
                  compact ? 10 : 16,
                  compact ? 8 : 12,
                  compact ? 8 : 16,
                  compact ? 8 : 12,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: EdgeInsets.only(top: 2, right: compact ? 8 : 12),
                      child: _selectionMode
                          ? Checkbox(
                              value: selected,
                              onChanged: isAvailable
                                  ? (_) => _toggleSessionSelection(session)
                                  : null,
                              visualDensity: VisualDensity.compact,
                              materialTapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                            )
                          : showBusy
                          ? SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: theme.colorScheme.primary,
                              ),
                            )
                          : Icon(
                              delegated
                                  ? Icons.subdirectory_arrow_right
                                  : provider.isSessionPinned(session.id)
                                  ? Icons.push_pin
                                  : isAvailable
                                  ? Icons.terminal
                                  : Icons.cloud_off_outlined,
                              size: compact ? 18 : 20,
                              color: provider.isSessionPinned(session.id)
                                  ? theme.colorScheme.primary.withAlpha(180)
                                  : theme.colorScheme.onSurface.withAlpha(128),
                            ),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Line 1: title, or project folder if no title.
                          Text(
                            primaryText,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: compact ? 13.5 : 15.5,
                              color: Color.lerp(
                                theme.colorScheme.onSurface,
                                theme.colorScheme.primary,
                                0.18,
                              ),
                            ),
                          ),
                          if (showSecondaryText) ...[
                            const SizedBox(height: 3),
                            Text(
                              secondaryText,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11.5,
                                color: theme.palette.text,
                              ),
                            ),
                          ],
                          // Line 3: status/time, path, and compact badges.
                          const SizedBox(height: 3),
                          if (widget.sidebar)
                            Wrap(
                              spacing: 6,
                              runSpacing: 3,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                Text(
                                  statusText,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: theme.palette.text,
                                  ),
                                ),
                                if (provider.serverConfigs.length > 1)
                                  ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      maxWidth: 130,
                                    ),
                                    child: Text(
                                      session.serverName,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: theme.palette.text,
                                      ),
                                    ),
                                  ),
                                if (!isAvailable)
                                  Text(
                                    _serverStatusLabel(status),
                                    style: const TextStyle(fontSize: 11),
                                  ),
                                if (delegated)
                                  const Text(
                                    'AGENT',
                                    style: TextStyle(fontSize: 10),
                                  ),
                              ],
                            )
                          else
                            Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    metaText,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: showBusy
                                          ? theme.colorScheme.primary
                                          : theme.palette.text,
                                    ),
                                  ),
                                ),
                                if (session.serverName.isNotEmpty &&
                                    provider.serverConfigs.length > 1) ...[
                                  const SizedBox(width: 6),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 5,
                                      vertical: 1,
                                    ),
                                    decoration: BoxDecoration(
                                      color: session.serverColor != null
                                          ? Color(
                                              session.serverColor!,
                                            ).withAlpha(showBusy ? 200 : 140)
                                          : theme.colorScheme.primaryContainer
                                                .withAlpha(120),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      session.serverName,
                                      style: TextStyle(
                                        fontSize: 10,
                                        fontWeight: session.serverColor != null
                                            ? FontWeight.w500
                                            : null,
                                        color: session.serverColor != null
                                            ? Colors.white
                                            : theme
                                                  .colorScheme
                                                  .onPrimaryContainer,
                                      ),
                                    ),
                                  ),
                                ],
                                if (!isAvailable) ...[
                                  const SizedBox(width: 6),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 5,
                                      vertical: 1,
                                    ),
                                    decoration: BoxDecoration(
                                      color: theme
                                          .colorScheme
                                          .surfaceContainerHighest,
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      _serverStatusLabel(status).toUpperCase(),
                                      style: TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.w600,
                                        letterSpacing: 0.5,
                                        color: theme.palette.text,
                                      ),
                                    ),
                                  ),
                                ],
                                if (delegated) ...[
                                  const SizedBox(width: 6),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 5,
                                      vertical: 1,
                                    ),
                                    decoration: BoxDecoration(
                                      color: theme
                                          .colorScheme
                                          .secondaryContainer
                                          .withAlpha(170),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      'AGENT',
                                      style: TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.w600,
                                        letterSpacing: 0.5,
                                        color: theme
                                            .colorScheme
                                            .onSecondaryContainer,
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          if (session.backend == 'codex' &&
                              session.freshThreadPending) ...[
                            const SizedBox(height: 7),
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 6,
                              ),
                              decoration: BoxDecoration(
                                border: Border.all(
                                  color: theme.colorScheme.primary.withAlpha(
                                    150,
                                  ),
                                ),
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.check_circle_outline,
                                    size: 16,
                                    color: theme.colorScheme.primary,
                                  ),
                                  const SizedBox(width: 7),
                                  Text(
                                    'Fresh thread ready',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: theme.colorScheme.primary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ] else if (session.backend == 'codex' &&
                              session.compactionsSinceRollover > 10)
                            SessionCompactionNotice(
                              key: ValueKey(
                                'compaction-${_sessionKey(session)}',
                              ),
                              serverId: session.serverId,
                              sessionId: session.id,
                              compactions: session.compactionsSinceRollover,
                              onStartFresh: isAvailable && !_selectionMode
                                  ? () => _confirmStartFreshThread(
                                      context,
                                      session,
                                    )
                                  : null,
                            ),
                        ],
                      ),
                    ),
                    if (!_selectionMode)
                      Builder(
                        builder: (buttonContext) => IconButton(
                          tooltip: 'Session actions',
                          icon: Icon(
                            Icons.more_vert,
                            size: 18,
                            color: theme.colorScheme.onSurface.withAlpha(128),
                          ),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                            minWidth: 32,
                            minHeight: 32,
                          ),
                          onPressed: isAvailable
                              ? _openingSessionKey == null
                                    ? () {
                                        final box =
                                            buttonContext.findRenderObject()!
                                                as RenderBox;
                                        _showSessionContextMenu(
                                          context,
                                          session,
                                          anchor: Platform.isWindows
                                              ? box.localToGlobal(
                                                      Offset(
                                                        0,
                                                        box.size.height,
                                                      ),
                                                    ) &
                                                    Size(box.size.width, 0)
                                              : null,
                                        );
                                      }
                                    : null
                              : () =>
                                    _showOfflineSessionSnack(context, session),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _showOfflineSessionSnack(BuildContext context, Session session) {
    final server = session.serverName.isNotEmpty
        ? session.serverName
        : 'computer';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '$server is offline. Reconnect it to change this session.',
        ),
      ),
    );
  }
}

/// Full-screen folder browser for navigating a server's filesystem.
// FolderBrowserScreen is now in widgets/folder_browser_screen.dart
