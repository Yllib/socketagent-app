import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/chat_provider.dart';
import '../services/websocket_service.dart';
import '../models/message.dart';
import '../models/server_config.dart';
import '../widgets/folder_browser_screen.dart';
import 'archive_screen.dart';
import 'home_screen.dart';
import 'main_shell_screen.dart';
import 'onboarding_screen.dart';
import 'settings/about_screen.dart';

class SessionsTab extends StatefulWidget {
  const SessionsTab({super.key});

  @override
  State<SessionsTab> createState() => _SessionsTabState();
}

class _SessionsTabState extends State<SessionsTab> {
  String? _openingSessionKey;
  String? _selectedServerFilterId;
  bool _connectedOnlyFilter = false;
  String? _backendFilter;
  bool _runningOnlyFilter = false;
  bool _searchOpen = false;
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<bool> _requireSubscription() async {
    final shell = context.findAncestorStateOfType<MainShellScreenState>();
    if (shell != null) return shell.requireSubscription();
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
        if (session != null && !provider.isSessionAvailable(session)) {
          _showOfflineSessionSnack(context, session);
          return;
        }
      }

      if (!await _requireSubscription()) return;
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

      await Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => const HomeScreen()));
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

            return SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                    child: Text(
                      'New Session',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  const Divider(height: 1),
                  if (showServers) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                      child: Text(
                        'Server',
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                    ),
                    ...provider.serverConfigs.map((config) {
                      final status = provider.connMgr.statusOf(config.id);
                      final isConnected = status == ConnectionStatus.connected;
                      return RadioListTile<String>(
                        value: config.id,
                        groupValue: selectedServer,
                        onChanged: isConnected
                            ? (v) => setState(() => selectedServer = v)
                            : null,
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
                          isConnected ? Icons.cloud_done : Icons.cloud_off,
                          color: isConnected ? Colors.green : Colors.grey,
                        ),
                        dense: true,
                      );
                    }),
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
                    ...supported.map(
                      (b) => RadioListTile<String>(
                        value: b,
                        groupValue: selectedBackend,
                        onChanged: (v) =>
                            setState(() => selectedBackend = v ?? b),
                        title: Text(_backendLabel(b)),
                        subtitle: Text(
                          _backendSubtitle(b),
                          style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurface.withAlpha(128),
                          ),
                        ),
                        dense: true,
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
              ),
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

    final create = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Directory not found'),
        content: Text('$path does not exist.\n\nCreate it?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to create $path')));
      }
    }
  }

  String? _serverIdForNewSession(ChatProvider provider) {
    final selected = _selectedServerFilterId;
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
    bool initialFetchDone = false;
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

            void fetchSdkSessions() {
              fetchDebounce?.cancel();
              final path = controller.text.trim();
              if (path.isEmpty) {
                setSheetState(() {
                  sdkSessions = [];
                  loadingSdkSessions = false;
                });
                return;
              }
              setSheetState(() => loadingSdkSessions = true);
              fetchDebounce = Timer(const Duration(milliseconds: 250), () {
                provider
                    .requestSdkSessions(path, serverId: selectedServerId)
                    .then((sessions) {
                      if (ctx.mounted) {
                        setSheetState(() {
                          sdkSessions = sessions;
                          loadingSdkSessions = false;
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
                tooltip: 'Switch server',
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
                          color: connected ? Colors.green : Colors.grey,
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
                    iconColor: isConnected ? Colors.green : Colors.grey,
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
                          children: [
                            if (serverChipWidget != null) serverChipWidget,
                            if (backendChipWidget != null) backendChipWidget,
                          ],
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
                            tooltip: 'Browse server filesystem',
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
                          separatorBuilder: (_, __) => const SizedBox(width: 6),
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
                              '${sdkSessions.length}',
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
                              itemCount: sdkSessions.length,
                              itemBuilder: (_, index) {
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
                                final timeDiff = DateTime.now().difference(
                                  lastActive,
                                );
                                String timeAgo;
                                if (timeDiff.inMinutes < 1) {
                                  timeAgo = 'just now';
                                } else if (timeDiff.inHours < 1) {
                                  timeAgo = '${timeDiff.inMinutes}m ago';
                                } else if (timeDiff.inDays < 1) {
                                  timeAgo = '${timeDiff.inHours}h ago';
                                } else {
                                  timeAgo = '${timeDiff.inDays}d ago';
                                }
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
                                      if (sessionBackend == 'codex') ...[
                                        const SizedBox(width: 6),
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 5,
                                            vertical: 1,
                                          ),
                                          decoration: BoxDecoration(
                                            color: Theme.of(context)
                                                .colorScheme
                                                .tertiaryContainer
                                                .withAlpha(170),
                                            borderRadius: BorderRadius.circular(
                                              4,
                                            ),
                                          ),
                                          child: Text(
                                            'CODEX',
                                            style: TextStyle(
                                              fontSize: 10,
                                              fontWeight: FontWeight.w600,
                                              letterSpacing: 0.5,
                                              color: Theme.of(
                                                context,
                                              ).colorScheme.onTertiaryContainer,
                                            ),
                                          ),
                                        ),
                                      ],
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
      final color = connectedCount == configs.length
          ? Colors.green
          : connectedCount > 0
          ? Colors.orange
          : Colors.grey;
      return Tooltip(
        message: '$connectedCount/${configs.length} servers connected',
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
                    if (color == Colors.green)
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
                '$connectedCount/${configs.length}',
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
              if (color == Colors.green)
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

  List<ServerConfig> _sortedServerConfigs(ChatProvider provider) {
    final sorted = [...provider.serverConfigs];
    sorted.sort((a, b) {
      final statusCmp = _serverStatusRank(
        provider.connMgr.statusOf(a.id),
      ).compareTo(_serverStatusRank(provider.connMgr.statusOf(b.id)));
      if (statusCmp != 0) return statusCmp;
      final orderCmp = a.sortOrder.compareTo(b.sortOrder);
      if (orderCmp != 0) return orderCmp;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return sorted;
  }

  int _serverStatusRank(ConnectionStatus status) {
    switch (status) {
      case ConnectionStatus.connected:
        return 0;
      case ConnectionStatus.connecting:
        return 1;
      case ConnectionStatus.disconnected:
      case ConnectionStatus.error:
        return 2;
    }
  }

  Color _serverStatusColor(ConnectionStatus status) {
    switch (status) {
      case ConnectionStatus.connected:
        return Colors.green;
      case ConnectionStatus.connecting:
        return Colors.orange;
      case ConnectionStatus.error:
        return Colors.red;
      case ConnectionStatus.disconnected:
        return Colors.grey;
    }
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
    if (_connectedOnlyFilter) return 'Connected only';
    final selected = _selectedServerFilterId;
    if (selected == null) return 'All servers';
    return provider.serverConfigs
            .where((config) => config.id == selected)
            .firstOrNull
            ?.name ??
        'All servers';
  }

  bool _matchesSessionFilters(ChatProvider provider, Session session) {
    if (_selectedServerFilterId != null &&
        session.serverId != _selectedServerFilterId) {
      return false;
    }
    if (_connectedOnlyFilter && !provider.isSessionAvailable(session)) {
      return false;
    }
    final backend = session.backend ?? 'claude';
    if (_backendFilter != null && backend != _backendFilter) return false;
    if (_runningOnlyFilter && !session.running) return false;

    final query = _searchQuery.trim().toLowerCase();
    if (query.isEmpty) return true;
    return session.title.toLowerCase().contains(query) ||
        session.cwd.toLowerCase().contains(query) ||
        session.messagePreview.toLowerCase().contains(query) ||
        session.serverName.toLowerCase().contains(query) ||
        backend.toLowerCase().contains(query);
  }

  List<Session> _filteredSessions(ChatProvider provider) {
    return provider.sessions
        .where((session) => _matchesSessionFilters(provider, session))
        .toList();
  }

  void _showServerFilterSheet(BuildContext context, ChatProvider provider) {
    final sortedServers = _sortedServerConfigs(provider);
    final sessions = provider.sessions;
    final connectedCount = provider.serverConfigs
        .where(
          (c) => provider.connMgr.statusOf(c.id) == ConnectionStatus.connected,
        )
        .length;

    int sessionCountFor(String serverId) =>
        sessions.where((session) => session.serverId == serverId).length;

    int runningCountFor(String serverId) => sessions
        .where((session) => session.serverId == serverId && session.running)
        .length;

    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              ListTile(
                leading: const Icon(Icons.all_inbox),
                title: const Text('All servers'),
                subtitle: Text('${sessions.length} sessions'),
                selected:
                    _selectedServerFilterId == null && !_connectedOnlyFilter,
                onTap: () {
                  setState(() {
                    _selectedServerFilterId = null;
                    _connectedOnlyFilter = false;
                  });
                  Navigator.pop(ctx);
                },
              ),
              ListTile(
                leading: const Icon(Icons.cloud_done),
                title: const Text('Connected only'),
                subtitle: Text(
                  '$connectedCount/${provider.serverConfigs.length} online',
                ),
                selected: _connectedOnlyFilter,
                onTap: () {
                  setState(() {
                    _selectedServerFilterId = null;
                    _connectedOnlyFilter = true;
                  });
                  Navigator.pop(ctx);
                },
              ),
              const Divider(height: 1),
              ...sortedServers.map((config) {
                final status = provider.connMgr.statusOf(config.id);
                final sessionCount = sessionCountFor(config.id);
                final runningCount = runningCountFor(config.id);
                final statusColor = _serverStatusColor(status);
                return ListTile(
                  leading: Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color: statusColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                  title: Text(config.name),
                  subtitle: Text(
                    [
                      _serverStatusLabel(status),
                      '$sessionCount session${sessionCount == 1 ? '' : 's'}',
                      if (runningCount > 0) '$runningCount running',
                    ].join(' · '),
                  ),
                  trailing: _selectedServerFilterId == config.id
                      ? const Icon(Icons.check)
                      : null,
                  selected: _selectedServerFilterId == config.id,
                  onTap: () {
                    setState(() {
                      _selectedServerFilterId = config.id;
                      _connectedOnlyFilter = false;
                    });
                    Navigator.pop(ctx);
                  },
                );
              }),
            ],
          ),
        );
      },
    );
  }

  Widget _buildFilterChipBar(BuildContext context, ChatProvider provider) {
    final theme = Theme.of(context);
    final activeFilters =
        _selectedServerFilterId != null ||
        _connectedOnlyFilter ||
        _backendFilter != null ||
        _runningOnlyFilter ||
        _searchQuery.trim().isNotEmpty;

    return Material(
      color: theme.colorScheme.surface,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
            child: Row(
              children: [
                ActionChip(
                  avatar: Icon(
                    _connectedOnlyFilter
                        ? Icons.cloud_done
                        : _selectedServerFilterId == null
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
                const SizedBox(width: 8),
                FilterChip(
                  avatar: const Icon(Icons.sync, size: 18),
                  label: const Text('Running'),
                  selected: _runningOnlyFilter,
                  onSelected: (selected) {
                    setState(() => _runningOnlyFilter = selected);
                  },
                ),
                const SizedBox(width: 4),
                IconButton(
                  icon: Icon(_searchOpen ? Icons.search_off : Icons.search),
                  tooltip: _searchOpen ? 'Hide search' : 'Search sessions',
                  onPressed: () {
                    setState(() {
                      _searchOpen = !_searchOpen;
                      if (!_searchOpen) {
                        _searchQuery = '';
                        _searchController.clear();
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
                        _selectedServerFilterId = null;
                        _connectedOnlyFilter = false;
                        _backendFilter = null;
                        _runningOnlyFilter = false;
                        _searchQuery = '';
                        _searchController.clear();
                      });
                    },
                  ),
              ],
            ),
          ),
          if (_searchOpen)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: TextField(
                controller: _searchController,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: 'Search title, path, preview, server...',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _searchQuery.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () {
                            setState(() {
                              _searchQuery = '';
                              _searchController.clear();
                            });
                          },
                        ),
                  isDense: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onChanged: (value) => setState(() => _searchQuery = value),
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
    List<Session> sessions,
  ) {
    if (sessions.isEmpty) {
      return Center(
        child: Text(
          provider.sessions.isEmpty
              ? 'No sessions yet'
              : 'No matching sessions',
          style: TextStyle(
            fontSize: 14,
            color: Theme.of(context).colorScheme.outline,
          ),
        ),
      );
    }

    final seen = <String>{};
    List<Session> take(bool Function(Session session) predicate) {
      final result = <Session>[];
      for (final session in sessions) {
        final key = _sessionKey(session);
        if (seen.contains(key) || !predicate(session)) continue;
        seen.add(key);
        result.add(session);
      }
      return result;
    }

    final working = take(
      (session) => session.running && provider.isSessionAvailable(session),
    );
    final pinned = take((session) => provider.isSessionPinned(session.id));
    final recent = take((session) => provider.isSessionAvailable(session));
    final offline = take((session) => !provider.isSessionAvailable(session));

    final children = <Widget>[];
    void addSection(String title, List<Session> sectionSessions) {
      if (sectionSessions.isEmpty) return;
      children.add(
        _buildSessionSectionHeader(context, title, sectionSessions.length),
      );
      for (var i = 0; i < sectionSessions.length; i++) {
        children.add(_buildSessionTile(context, sectionSessions[i]));
        if (i != sectionSessions.length - 1) {
          children.add(
            Divider(
              height: 1,
              indent: 48,
              color: Theme.of(context).colorScheme.outlineVariant.withAlpha(80),
            ),
          );
        }
      }
    }

    addSection('Working', working);
    addSection('Pinned', pinned);
    addSection('Recent', recent);
    addSection('Offline servers', offline);

    return ListView(
      padding: const EdgeInsets.only(bottom: 80),
      children: children,
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
    return Consumer<ChatProvider>(
      builder: (context, provider, _) {
        final configs = provider.serverConfigs;

        // No servers configured — show onboarding
        if (configs.isEmpty) {
          return const OnboardingScreen();
        }

        if (_selectedServerFilterId != null &&
            !configs.any((config) => config.id == _selectedServerFilterId)) {
          _selectedServerFilterId = null;
          _connectedOnlyFilter = false;
        }
        final filteredSessions = _filteredSessions(provider);

        return Scaffold(
          appBar: AppBar(
            title: const Text('Sessions'),
            actions: [
              IconButton(
                icon: const Icon(Icons.inventory_2_outlined),
                tooltip: 'Archived Sessions',
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const ArchiveScreen()),
                ),
              ),
              _buildConnectionIndicator(provider),
            ],
          ),
          body: Column(
            children: [
              _buildUpdateBanner(context),
              _buildFilterChipBar(context, provider),
              if (provider.sessions.isEmpty)
                Expanded(child: _buildEmptyState(context))
              else
                Expanded(
                  child: _buildSectionedSessionList(
                    context,
                    provider,
                    filteredSessions,
                  ),
                ),
            ],
          ),
          // Single entry point for new sessions: the CWD picker. The picker
          // also includes backend selection when the chosen server supports
          // both Claude and Codex, so it's a one-sheet flow.
          floatingActionButton: Material(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(20),
            child: InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: () => _showCwdPicker(
                context,
                initialServerId: _serverIdForNewSession(provider),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.folder_open,
                      size: 16,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'Choose directory...',
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildUpdateBanner(BuildContext context) {
    final shell = context.findAncestorStateOfType<MainShellScreenState>();
    if (shell == null ||
        !shell.updateService.updateAvailable ||
        shell.updateBannerDismissed) {
      return const SizedBox.shrink();
    }
    final info = shell.updateService.updateInfo!;
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
                'Update available: v${info.currentVersion} \u2192 v${info.latestVersion}',
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
              onPressed: () {
                shell.dismissUpdateBanner();
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => AboutScreen(
                      updateService: shell.updateService,
                      autoStartDownload: true,
                    ),
                  ),
                );
              },
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('Update', style: TextStyle(fontSize: 12)),
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
            'Choose a directory to start',
            style: TextStyle(
              fontSize: 14,
              color: Theme.of(context).colorScheme.outline.withAlpha(178),
            ),
          ),
        ],
      ),
    );
  }

  void _showSessionContextMenu(BuildContext context, Session session) {
    final provider = context.read<ChatProvider>();
    final notifEnabled = provider.isNotifEnabled(session.id);
    final isPinned = provider.isSessionPinned(session.id);
    final codexDriver =
        session.codexDriver ?? provider.codexDriverForServer(session.serverId);
    final canForkSession =
        session.backend != 'codex' || codexDriver == 'app-server';
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: Icon(
                  isPinned ? Icons.push_pin : Icons.push_pin_outlined,
                  color: isPinned
                      ? Theme.of(context).colorScheme.primary
                      : null,
                ),
                title: Text(isPinned ? 'Unpin Session' : 'Pin Session'),
                subtitle: Text(
                  isPinned ? 'Remove from pinned' : 'Keep at the top',
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  provider.toggleSessionPin(session.id);
                },
              ),
              ListTile(
                leading: Icon(
                  notifEnabled
                      ? Icons.notifications_active
                      : Icons.notifications_off_outlined,
                  color: notifEnabled
                      ? Theme.of(context).colorScheme.primary
                      : null,
                ),
                title: Text(
                  notifEnabled ? 'Notifications On' : 'Notifications Off',
                ),
                subtitle: Text(
                  notifEnabled ? 'Tap to disable' : 'Tap to enable',
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  provider.toggleSessionNotifications(session.id);
                },
              ),
              if (canForkSession)
                ListTile(
                  leading: const Icon(Icons.fork_right),
                  title: Text(
                    session.backend == 'codex' ? 'Fork Thread' : 'Fork Session',
                  ),
                  subtitle: Text(
                    session.backend == 'codex'
                        ? 'Create a copy of this Codex thread'
                        : 'Create a copy of this conversation',
                  ),
                  onTap: () {
                    Navigator.pop(ctx);
                    _forkSession(context, session);
                  },
                ),
              if (session.backend == 'codex' &&
                  codexDriver == 'app-server') ...[
                ListTile(
                  leading: const Icon(Icons.compress),
                  title: const Text('Compact Thread'),
                  subtitle: const Text('Ask Codex to compact this thread'),
                  onTap: () {
                    Navigator.pop(ctx);
                    provider.compactCodexThread(session.id);
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Codex compact requested')),
                    );
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.history),
                  title: const Text('Rollback Last Turn'),
                  subtitle: const Text('Drop the newest Codex turn'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _confirmCodexRollback(context, session);
                  },
                ),
              ],
              ListTile(
                leading: const Icon(Icons.refresh),
                title: const Text('Clear Context'),
                subtitle: const Text('Archive history and start fresh'),
                onTap: () {
                  Navigator.pop(ctx);
                  _confirmClearContext(context, session);
                },
              ),
              if (session.backend != 'codex')
                ListTile(
                  leading: const Icon(Icons.block),
                  title: const Text('Blocked Tools'),
                  subtitle: Text(() {
                    final blocked = provider.getDisallowedTools(session.id);
                    return blocked.isEmpty
                        ? 'None blocked'
                        : '${blocked.length} blocked';
                  }()),
                  onTap: () {
                    Navigator.pop(ctx);
                    _showBlockedToolsDialog(context, session);
                  },
                ),
              ListTile(
                leading: const Icon(Icons.description),
                title: Text(
                  session.backend == 'codex'
                      ? 'Additional Instructions'
                      : 'System Prompt',
                ),
                subtitle: Text(() {
                  final sp = provider.getSessionSystemPrompt(session.id);
                  if (sp.isNotEmpty) return 'Custom override set';
                  final effective = provider.getEffectiveSystemPrompt(
                    session.id,
                  );
                  return effective.isNotEmpty
                      ? 'Using server default'
                      : 'Not set';
                }()),
                onTap: () {
                  Navigator.pop(ctx);
                  _showSystemPromptDialog(context, session);
                },
              ),
              ListTile(
                leading: const Icon(Icons.edit),
                title: const Text('Rename Session'),
                subtitle: Text(
                  session.title == 'Untitled'
                      ? 'Set a display name'
                      : session.title,
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _showRenameDialog(context, session);
                },
              ),
              ListTile(
                leading: Icon(Icons.archive, color: Colors.orange.shade300),
                title: Text(
                  'Archive Session',
                  style: TextStyle(color: Colors.orange.shade300),
                ),
                subtitle: const Text('Remove from list, keep history'),
                onTap: () {
                  Navigator.pop(ctx);
                  _confirmArchiveSession(context, session);
                },
              ),
              ListTile(
                leading: Icon(Icons.delete, color: Colors.red.shade300),
                title: Text(
                  'Delete Session',
                  style: TextStyle(color: Colors.red.shade300),
                ),
                subtitle: const Text('Permanent — no archive'),
                onTap: () {
                  Navigator.pop(ctx);
                  _confirmDeleteSession(context, session);
                },
              ),
            ],
          ),
        );
      },
    );
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
                'Server default:',
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
                'Override for this session (leave empty to use server default):',
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
              context.read<ChatProvider>().archiveSession(session.id);
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
              context.read<ChatProvider>().deleteSession(session.id);
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
              ).showSnackBar(const SnackBar(content: Text('Context cleared')));
            },
            child: const Text('Clear'),
          ),
        ],
      ),
    );
  }

  Future<void> _forkSession(BuildContext context, Session session) async {
    if (!await _requireSubscription()) return;
    if (!context.mounted) return;

    final provider = context.read<ChatProvider>();
    provider.forkSession(session.id);
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const HomeScreen()));
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

  Widget _buildSessionTile(BuildContext context, Session session) {
    final theme = Theme.of(context);
    final provider = context.read<ChatProvider>();
    final status = provider.sessionServerStatus(session);
    final isAvailable = provider.isSessionAvailable(session);
    final openingThisSession =
        _openingSessionKey ==
        _openSessionKey(sessionId: session.id, serverId: session.serverId);
    final showRunning = session.running && isAvailable;
    final showBusy = showRunning || openingThisSession;
    final timeDiff = DateTime.now().difference(session.lastActive);
    String timeAgo;
    if (timeDiff.inMinutes < 1) {
      timeAgo = 'just now';
    } else if (timeDiff.inHours < 1) {
      timeAgo = '${timeDiff.inMinutes}m ago';
    } else if (timeDiff.inDays < 1) {
      timeAgo = '${timeDiff.inHours}h ago';
    } else {
      timeAgo = '${timeDiff.inDays}d ago';
    }

    String displayCwd = session.cwd;
    final homePattern = RegExp(r'^/home/[^/]+/');
    final homeExact = RegExp(r'^/home/[^/]+$');
    if (homePattern.hasMatch(displayCwd)) {
      displayCwd = '~/${displayCwd.replaceFirst(homePattern, '')}';
    } else if (homeExact.hasMatch(displayCwd)) {
      displayCwd = '~';
    }

    // Lead with recent conversation text; keep title/project as context.
    final hasTitle = session.title.isNotEmpty && session.title != 'Untitled';
    final previewText = session.messagePreview.trim();
    final titleOrProject = hasTitle
        ? session.title
        : _projectLabelForCwd(displayCwd);
    final primaryText = previewText.isNotEmpty ? previewText : titleOrProject;
    final secondaryText = previewText.isNotEmpty
        ? (hasTitle ? session.title : displayCwd)
        : '';
    final showSecondaryText =
        secondaryText.trim().isNotEmpty &&
        secondaryText.trim() != primaryText.trim();
    final statusText = openingThisSession
        ? 'Opening...'
        : showRunning
        ? 'Working...'
        : timeAgo;
    final turnCountText = session.turnCount > 0
        ? '${session.turnCount} turn${session.turnCount == 1 ? '' : 's'}'
        : '';
    final metaText = [
      if (turnCountText.isNotEmpty) turnCountText,
      statusText,
      if (displayCwd.isNotEmpty) displayCwd,
    ].join(' · ');

    return Dismissible(
      key: Key('${session.serverId}:${session.id}'),
      direction: isAvailable && _openingSessionKey == null
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
        onTap: isAvailable
            ? _openingSessionKey == null
                  ? () => _openSession(
                      context,
                      sessionId: session.id,
                      serverId: session.serverId,
                    )
                  : null
            : () => _showOfflineSessionSnack(context, session),
        onLongPress: isAvailable
            ? _openingSessionKey == null
                  ? () => _showSessionContextMenu(context, session)
                  : null
            : () => _showOfflineSessionSnack(context, session),
        child: Opacity(
          opacity: isAvailable ? 1 : 0.48,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2, right: 12),
                  child: showBusy
                      ? SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: theme.colorScheme.primary,
                          ),
                        )
                      : Icon(
                          provider.isSessionPinned(session.id)
                              ? Icons.push_pin
                              : isAvailable
                              ? Icons.terminal
                              : Icons.cloud_off_outlined,
                          size: 20,
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
                          fontWeight: FontWeight.w500,
                          fontSize: 14,
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                      if (showSecondaryText) ...[
                        const SizedBox(height: 3),
                        Text(
                          secondaryText,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: theme.colorScheme.onSurface.withAlpha(140),
                          ),
                        ),
                      ],
                      // Line 3: status/time, path, and compact badges.
                      const SizedBox(height: 3),
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
                                    : theme.colorScheme.onSurface.withAlpha(
                                        128,
                                      ),
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
                                      : theme.colorScheme.onPrimaryContainer,
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
                                color:
                                    theme.colorScheme.surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                _serverStatusLabel(status).toUpperCase(),
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: 0.5,
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ],
                          // Codex sessions get a small badge so mixed backend
                          // lists are easy to scan.
                          if (session.backend == 'codex') ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 5,
                                vertical: 1,
                              ),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.tertiaryContainer
                                    .withAlpha(170),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                'CODEX',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: 0.5,
                                  color: theme.colorScheme.onTertiaryContainer,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
                // Overflow menu icon (replaces notification bell)
                IconButton(
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
                            ? () => _showSessionContextMenu(context, session)
                            : null
                      : () => _showOfflineSessionSnack(context, session),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showOfflineSessionSnack(BuildContext context, Session session) {
    final server = session.serverName.isNotEmpty
        ? session.serverName
        : 'server';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$server is offline. Reconnect it to open this session.'),
      ),
    );
  }
}

/// Full-screen folder browser for navigating a server's filesystem.
// FolderBrowserScreen is now in widgets/folder_browser_screen.dart
