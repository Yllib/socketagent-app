import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/chat_provider.dart';
import '../services/websocket_service.dart';
import '../models/message.dart';
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

class _SessionsTabState extends State<SessionsTab> with TickerProviderStateMixin {
  TabController? _tabController;
  int _lastServerCount = 0;

  @override
  void dispose() {
    _tabController?.dispose();
    super.dispose();
  }

  void _ensureTabController(int serverCount) {
    if (serverCount <= 1) {
      // Single server — no tabs needed
      _tabController?.dispose();
      _tabController = null;
      _lastServerCount = serverCount;
      return;
    }
    if (_tabController == null || _lastServerCount != serverCount) {
      _tabController?.dispose();
      _tabController = TabController(length: 1 + serverCount, vsync: this);
      _lastServerCount = serverCount;
    }
  }

  Future<bool> _requireSubscription() async {
    final shell = context.findAncestorStateOfType<MainShellScreenState>();
    if (shell != null) return shell.requireSubscription();
    return true;
  }

  Future<void> _openSession(BuildContext context, {String? sessionId, String? cwd, String? serverId, String? backend, bool sdkSession = false}) async {
    if (!await _requireSubscription()) return;
    if (!context.mounted) return;

    final provider = context.read<ChatProvider>();

    if (sdkSession && sessionId != null && cwd != null) {
      provider.resumeSdkSession(sessionId, cwd, serverId: serverId, backend: backend);
    } else if (sessionId != null) {
      provider.resumeSession(sessionId);
    } else {
      // The CWD picker now collects server + backend + cwd in one sheet,
      // so backend usually arrives already chosen. Only show the fallback
      // picker if backend is unset AND the upstream caller didn't pick
      // (e.g., a code path that bypasses the CWD picker).
      String? effectiveBackend = backend;
      if (effectiveBackend == null) {
        final needsServerPick = serverId == null && provider.serverConfigs.length > 1;
        final initialServer = serverId ?? provider.serverConfigs.firstOrNull?.id;
        final initialBackends = provider.backendsForServer(initialServer);
        final needsBackendPick = needsServerPick || initialBackends.length > 1;
        if (needsBackendPick) {
          final result = await _pickServerAndBackend(
            context, provider,
            presetServerId: serverId,
          );
          if (result == null || !context.mounted) return;
          serverId = result.serverId;
          effectiveBackend = result.backend;
        } else if (initialBackends.isNotEmpty) {
          effectiveBackend = initialBackends.first;
        }
      }
      provider.createNewSession(cwd: cwd, serverId: serverId, backend: effectiveBackend);
    }

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const HomeScreen(),
      ),
    );
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
        .where((c) => provider.connMgr.statusOf(c.id) == ConnectionStatus.connected)
        .toList();
    String? selectedServer = presetServerId
        ?? (connectedServers.isNotEmpty
            ? connectedServers.first.id
            : provider.serverConfigs.firstOrNull?.id);
    String selectedBackend = provider.backendsForServer(selectedServer).firstOrNull ?? 'claude';

    return showModalBottomSheet<({String? serverId, String backend})>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(builder: (ctx, setState) {
          final supported = provider.backendsForServer(selectedServer);
          // Snap back to a valid choice if the user just changed servers.
          if (!supported.contains(selectedBackend)) {
            selectedBackend = supported.first;
          }
          // Hide the server radio when a server was preselected upstream
          // (e.g., in the CWD picker) — re-asking would be confusing.
          final showServers = provider.serverConfigs.length > 1 && presetServerId == null;
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
                        config.useRelay ? 'Relay' : '${config.host}:${config.port}',
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.onSurface.withAlpha(128),
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
                  ...supported.map((b) => RadioListTile<String>(
                        value: b,
                        groupValue: selectedBackend,
                        onChanged: (v) => setState(() => selectedBackend = v ?? b),
                        title: Text(_backendLabel(b)),
                        subtitle: Text(_backendSubtitle(b),
                            style: TextStyle(
                                fontSize: 12,
                                color: Theme.of(context).colorScheme.onSurface.withAlpha(128))),
                        dense: true,
                      )),
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
        });
      },
    );
  }

  String _backendLabel(String b) => b == 'codex' ? 'Codex (ChatGPT)' : 'Claude';
  String _backendSubtitle(String b) => b == 'codex'
      ? 'OpenAI Codex CLI — billed via your ChatGPT subscription'
      : 'Anthropic Claude Agent SDK — billed via your Claude subscription';

  Future<void> _validateAndOpen(BuildContext context, String path, {String? serverId, String? backend}) async {
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to create $path')),
        );
      }
    }
  }

  void _showCwdPicker(BuildContext context) {
    final provider = context.read<ChatProvider>();
    final hasMultipleServers = provider.serverConfigs.length > 1;
    String? selectedServerId;
    if (hasMultipleServers) {
      final connected = provider.serverConfigs
          .where((c) => provider.connMgr.statusOf(c.id) == ConnectionStatus.connected)
          .toList();
      selectedServerId = connected.isNotEmpty ? connected.first.id : provider.serverConfigs.first.id;
    }

    final controller = TextEditingController(text: provider.defaultCwd);
    List<Map<String, dynamic>> sdkSessions = [];
    bool loadingSdkSessions = false;
    bool initialFetchDone = false;
    // Default backend = first supported by the chosen server (claude if
    // capabilities haven't arrived yet). Snaps back to a valid choice when
    // the user switches servers below.
    String selectedBackend = provider.backendsForServer(selectedServerId).firstOrNull ?? 'claude';

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            final recentCwds = provider.getRecentCwds(serverId: selectedServerId);

            void fetchSdkSessions() {
              final path = controller.text.trim();
              if (path.isEmpty) {
                setSheetState(() {
                  sdkSessions = [];
                  loadingSdkSessions = false;
                });
                return;
              }
              setSheetState(() => loadingSdkSessions = true);
              provider.requestSdkSessions(path, serverId: selectedServerId).then((sessions) {
                if (ctx.mounted) {
                  setSheetState(() {
                    sdkSessions = sessions;
                    loadingSdkSessions = false;
                  });
                }
              });
            }

            if (!initialFetchDone) {
              initialFetchDone = true;
              WidgetsBinding.instance.addPostFrameCallback((_) => fetchSdkSessions());
            }

            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(ctx).viewInsets.bottom,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                    child: Text(
                      'Working Directory',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  if (hasMultipleServers) ...[
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: SizedBox(
                        width: double.infinity,
                        child: SegmentedButton<String>(
                          segments: provider.serverConfigs.map((config) {
                            final isConnected = provider.connMgr.statusOf(config.id) == ConnectionStatus.connected;
                            return ButtonSegment(
                              value: config.id,
                              label: Text(
                                config.name,
                                style: const TextStyle(fontSize: 12),
                                overflow: TextOverflow.ellipsis,
                              ),
                              icon: Icon(
                                isConnected ? Icons.cloud_done : Icons.cloud_off,
                                size: 14,
                                color: isConnected ? Colors.green : Colors.grey,
                              ),
                            );
                          }).toList(),
                          selected: {if (selectedServerId != null) selectedServerId!},
                          onSelectionChanged: (v) {
                            setSheetState(() {
                              selectedServerId = v.first;
                              // Snap backend to a valid choice for the new server.
                              final supported = provider.backendsForServer(selectedServerId);
                              if (!supported.contains(selectedBackend) && supported.isNotEmpty) {
                                selectedBackend = supported.first;
                              }
                            });
                          },
                          style: ButtonStyle(
                            visualDensity: VisualDensity.compact,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  // Backend selector — only visible when the chosen server
                  // supports more than one. claude-only servers stay clean.
                  if (provider.backendsForServer(selectedServerId).length > 1) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: SizedBox(
                        width: double.infinity,
                        child: SegmentedButton<String>(
                          segments: provider.backendsForServer(selectedServerId).map((b) {
                            return ButtonSegment(
                              value: b,
                              label: Text(_backendLabel(b),
                                style: const TextStyle(fontSize: 12),
                                overflow: TextOverflow.ellipsis),
                              icon: Icon(
                                b == 'codex' ? Icons.code : Icons.psychology_alt,
                                size: 14,
                              ),
                            );
                          }).toList(),
                          selected: {selectedBackend},
                          onSelectionChanged: (v) {
                            setSheetState(() => selectedBackend = v.first);
                          },
                          style: ButtonStyle(
                            visualDensity: VisualDensity.compact,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                      ),
                    ),
                  ],
                  const Divider(height: 1),
                  if (recentCwds.isNotEmpty) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                      child: Text(
                        'Recent',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: Theme.of(context).colorScheme.onSurface.withAlpha(128),
                        ),
                      ),
                    ),
                    ...recentCwds.map((cwd) => ListTile(
                      dense: true,
                      leading: Icon(Icons.folder_outlined, size: 20,
                        color: Theme.of(context).colorScheme.primary),
                      title: Text(cwd, style: const TextStyle(fontSize: 14)),
                      trailing: IconButton(
                        icon: Icon(Icons.close, size: 18,
                          color: Theme.of(context).colorScheme.onSurface.withAlpha(100)),
                        onPressed: () {
                          provider.removeRecentCwd(cwd, serverId: selectedServerId);
                          setSheetState(() {});
                        },
                      ),
                      onTap: () {
                        controller.text = cwd;
                        controller.selection = TextSelection.fromPosition(
                          TextPosition(offset: cwd.length),
                        );
                        fetchSdkSessions();
                      },
                    )),
                    const Divider(height: 1),
                  ],
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () async {
                          final picked = await _showFolderBrowser(
                            context, provider,
                            serverId: selectedServerId,
                          );
                          if (picked != null && ctx.mounted) {
                            controller.text = picked;
                            controller.selection = TextSelection.fromPosition(
                              TextPosition(offset: picked.length),
                            );
                            fetchSdkSessions();
                          }
                        },
                        icon: const Icon(Icons.folder_open, size: 18),
                        label: const Text('Browse Server'),
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                    child: Text(
                      'Or type a path',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: Theme.of(context).colorScheme.onSurface.withAlpha(128),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: controller,
                            decoration: InputDecoration(
                              hintText: '/path/to/project',
                              filled: true,
                              fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: BorderSide.none,
                              ),
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 10,
                              ),
                              isDense: true,
                            ),
                            style: const TextStyle(fontSize: 14),
                            onSubmitted: (val) {
                              final path = val.trim();
                              if (path.isNotEmpty) {
                                Navigator.pop(ctx);
                                _validateAndOpen(context, path, serverId: selectedServerId, backend: selectedBackend);
                              }
                            },
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          icon: Icon(Icons.arrow_forward,
                            color: Theme.of(context).colorScheme.primary),
                          onPressed: () {
                            final path = controller.text.trim();
                            if (path.isNotEmpty) {
                              Navigator.pop(ctx);
                              _validateAndOpen(context, path, serverId: selectedServerId);
                            }
                          },
                        ),
                      ],
                    ),
                  ),
                  if (loadingSdkSessions)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 16),
                      child: Center(child: SizedBox(
                        width: 20, height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )),
                    )
                  else if (sdkSessions.isNotEmpty) ...[
                    const Divider(height: 1),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                      child: Text(
                        'Resume existing session',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: Theme.of(context).colorScheme.onSurface.withAlpha(128),
                        ),
                      ),
                    ),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 200),
                      child: ListView.builder(
                        shrinkWrap: true,
                        padding: const EdgeInsets.only(bottom: 8),
                        itemCount: sdkSessions.length,
                        itemBuilder: (_, index) {
                          final session = sdkSessions[index];
                          final preview = session['firstMessage'] as String? ?? '';
                          final sessionBackend = session['backend'] as String?;
                          final lastActive = DateTime.tryParse(
                            session['lastActive'] as String? ?? '',
                          ) ?? DateTime.now();
                          final timeDiff = DateTime.now().difference(lastActive);
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
                            leading: Icon(Icons.history, size: 20,
                              color: Theme.of(context).colorScheme.secondary),
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
                                    color: Theme.of(context).colorScheme.onSurface.withAlpha(128),
                                  ),
                                ),
                                // Codex sessions get a small badge so the user
                                // can tell them apart from claude in this list;
                                // claude is implicit (no badge), matching the
                                // main session list rendering.
                                if (sessionBackend == 'codex') ...[
                                  const SizedBox(width: 6),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                    decoration: BoxDecoration(
                                      color: Theme.of(context).colorScheme.tertiaryContainer.withAlpha(170),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      'CODEX',
                                      style: TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.w600,
                                        letterSpacing: 0.5,
                                        color: Theme.of(context).colorScheme.onTertiaryContainer,
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                            onTap: () {
                              Navigator.pop(ctx);
                              final isTracked = session['tracked'] == true;
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
                  ] else ...[
                    const SizedBox(height: 8),
                  ],
                ],
              ),
            );
          },
        );
      },
    ).then((_) => controller.dispose());
  }

  Future<String?> _showFolderBrowser(BuildContext context, ChatProvider provider, {String? serverId}) async {
    return Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => FolderBrowserScreen(provider: provider, serverId: serverId),
      ),
    );
  }

  Widget _buildConnectionIndicator(ChatProvider provider) {
    final configs = provider.serverConfigs;
    if (configs.length > 1) {
      final connectedCount = configs
          .where((c) => provider.connMgr.statusOf(c.id) == ConnectionStatus.connected)
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

  @override
  Widget build(BuildContext context) {
    return Consumer<ChatProvider>(
      builder: (context, provider, _) {
        final configs = provider.serverConfigs;

        // No servers configured — show onboarding
        if (configs.isEmpty) {
          return const OnboardingScreen();
        }

        final multiServer = configs.length > 1;
        _ensureTabController(configs.length);

        final pinned = provider.pinnedSessions;
        final unpinned = provider.unpinnedSessions;

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
            bottom: multiServer && _tabController != null
                ? TabBar(
                    controller: _tabController,
                    isScrollable: true,
                    tabAlignment: TabAlignment.start,
                    tabs: [
                      const Tab(text: 'All'),
                      ...configs.map((c) => Tab(text: c.name)),
                    ],
                  )
                : null,
          ),
          body: Column(
            children: [
              _buildUpdateBanner(context),
              if (provider.sessions.isEmpty)
                Expanded(child: _buildEmptyState(context))
              else ...[
                if (pinned.isNotEmpty)
                  _buildPinnedSection(context, provider, pinned),
                Expanded(
                  child: multiServer && _tabController != null
                      ? TabBarView(
                          controller: _tabController,
                          children: [
                            _buildFilteredSessionList(context, provider, unpinned),
                            ...configs.map((c) {
                              final serverSessions = unpinned
                                  .where((s) => s.serverId == c.id)
                                  .toList();
                              return _buildFilteredSessionList(
                                  context, provider, serverSessions);
                            }),
                          ],
                        )
                      : _buildFilteredSessionList(context, provider, unpinned),
                ),
              ],
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
              onTap: () => _showCwdPicker(context),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.folder_open, size: 16,
                      color: Theme.of(context).colorScheme.onSurfaceVariant),
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
    if (shell == null || !shell.updateService.updateAvailable || shell.updateBannerDismissed) {
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
            Icon(Icons.system_update, size: 20, color: Theme.of(context).colorScheme.primary),
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
                  MaterialPageRoute(builder: (_) => const AboutScreen()),
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
            'Tap "New Session" to start',
            style: TextStyle(
              fontSize: 14,
              color: Theme.of(context).colorScheme.outline.withAlpha(178),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPinnedSection(BuildContext context, ChatProvider provider, List<Session> pinned) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        border: Border(
          bottom: BorderSide(
            color: theme.colorScheme.outlineVariant.withAlpha(80),
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(
              children: [
                Icon(Icons.push_pin, size: 14,
                    color: theme.colorScheme.onSurface.withAlpha(128)),
                const SizedBox(width: 4),
                Text(
                  'Pinned',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onSurface.withAlpha(128),
                    letterSpacing: 0.5,
                  ),
                ),
              ],
            ),
          ),
          ...pinned.map((session) => _buildSessionTile(context, session)),
        ],
      ),
    );
  }

  Widget _buildFilteredSessionList(BuildContext context, ChatProvider provider, List<Session> sessions) {
    if (sessions.isEmpty) {
      return Center(
        child: Text(
          'No sessions',
          style: TextStyle(
            fontSize: 14,
            color: Theme.of(context).colorScheme.outline,
          ),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.only(bottom: 80),
      itemCount: sessions.length,
      separatorBuilder: (_, __) => Divider(
        height: 1,
        indent: 48,
        color: Theme.of(context).colorScheme.outlineVariant.withAlpha(80),
      ),
      itemBuilder: (context, index) {
        return _buildSessionTile(context, sessions[index]);
      },
    );
  }

  void _showSessionContextMenu(BuildContext context, Session session) {
    final provider = context.read<ChatProvider>();
    final notifEnabled = provider.isNotifEnabled(session.id);
    final isPinned = provider.isSessionPinned(session.id);
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
                  color: isPinned ? Theme.of(context).colorScheme.primary : null,
                ),
                title: Text(isPinned ? 'Unpin Session' : 'Pin Session'),
                subtitle: Text(isPinned ? 'Remove from pinned' : 'Keep at the top'),
                onTap: () {
                  Navigator.pop(ctx);
                  provider.toggleSessionPin(session.id);
                },
              ),
              ListTile(
                leading: Icon(
                  notifEnabled ? Icons.notifications_active : Icons.notifications_off_outlined,
                  color: notifEnabled ? Theme.of(context).colorScheme.primary : null,
                ),
                title: Text(notifEnabled ? 'Notifications On' : 'Notifications Off'),
                subtitle: Text(notifEnabled ? 'Tap to disable' : 'Tap to enable'),
                onTap: () {
                  Navigator.pop(ctx);
                  provider.toggleSessionNotifications(session.id);
                },
              ),
              ListTile(
                leading: const Icon(Icons.fork_right),
                title: const Text('Fork Session'),
                subtitle: const Text('Create a copy of this conversation'),
                onTap: () {
                  Navigator.pop(ctx);
                  _forkSession(context, session);
                },
              ),
              ListTile(
                leading: const Icon(Icons.refresh),
                title: const Text('Clear Context'),
                subtitle: const Text('Archive history and start fresh'),
                onTap: () {
                  Navigator.pop(ctx);
                  _confirmClearContext(context, session);
                },
              ),
              ListTile(
                leading: const Icon(Icons.block),
                title: const Text('Blocked Tools'),
                subtitle: Text(() {
                  final blocked = provider.getDisallowedTools(session.id);
                  return blocked.isEmpty ? 'None blocked' : '${blocked.length} blocked';
                }()),
                onTap: () {
                  Navigator.pop(ctx);
                  _showBlockedToolsDialog(context, session);
                },
              ),
              ListTile(
                leading: const Icon(Icons.description),
                title: const Text('System Prompt'),
                subtitle: Text(() {
                  final sp = provider.getSessionSystemPrompt(session.id);
                  if (sp.isNotEmpty) return 'Custom override set';
                  final effective = provider.getEffectiveSystemPrompt(session.id);
                  return effective.isNotEmpty ? 'Using server default' : 'Not set';
                }()),
                onTap: () {
                  Navigator.pop(ctx);
                  _showSystemPromptDialog(context, session);
                },
              ),
              ListTile(
                leading: const Icon(Icons.edit),
                title: const Text('Rename Session'),
                subtitle: Text(session.title == 'Untitled' ? 'Set a display name' : session.title),
                onTap: () {
                  Navigator.pop(ctx);
                  _showRenameDialog(context, session);
                },
              ),
              ListTile(
                leading: Icon(Icons.archive, color: Colors.orange.shade300),
                title: Text('Archive Session',
                    style: TextStyle(color: Colors.orange.shade300)),
                subtitle: const Text('Remove from list, keep history'),
                onTap: () {
                  Navigator.pop(ctx);
                  _confirmArchiveSession(context, session);
                },
              ),
              ListTile(
                leading: Icon(Icons.delete, color: Colors.red.shade300),
                title: Text('Delete Session',
                    style: TextStyle(color: Colors.red.shade300)),
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
    final currentBlocked = Set<String>.from(provider.getDisallowedTools(session.id));

    if (allTools.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No tools available yet — open the session first to load the tools list')),
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
                  provider.setDisallowedTools(session.id, currentBlocked.toList());
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
        title: const Text('System Prompt'),
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
                  serverDefault.length > 200 ? '${serverDefault.substring(0, 200)}...' : serverDefault,
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurface.withAlpha(178),
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
                'Extra instructions appended to the default Claude Code prompt:',
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
                fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
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
              provider.setSessionSystemPrompt(session.id, controller.text.trim());
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
          decoration: const InputDecoration(
            hintText: 'Session name',
          ),
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

  Future<bool> _confirmArchiveSession(BuildContext context, Session session) async {
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
            style: FilledButton.styleFrom(backgroundColor: Colors.orange.shade700),
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

  Future<bool> _confirmDeleteSession(BuildContext context, Session session) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Session'),
        content: Text(
          'Delete "${session.title}"? This cannot be undone.',
        ),
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

  Future<void> _confirmClearContext(BuildContext context, Session session) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear Context'),
        content: const Text(
          'This will archive the conversation history and start fresh. '
          'The session will be kept but Claude will have no memory of previous messages.',
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
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Context cleared')),
              );
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
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const HomeScreen(),
      ),
    );
  }

  Widget _buildSessionTile(BuildContext context, Session session) {
    final theme = Theme.of(context);
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

    // Use title as primary, fall back to CWD if title is empty/Untitled
    final hasTitle = session.title.isNotEmpty && session.title != 'Untitled';
    final primaryText = hasTitle ? session.title : displayCwd;

    return Dismissible(
      key: Key(session.id),
      direction: DismissDirection.horizontal,
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
        if (dir == DismissDirection.endToStart) {
          return _confirmArchiveSession(context, session);
        }
        await _confirmClearContext(context, session);
        return false;
      },
      child: InkWell(
        onTap: () => _openSession(context, sessionId: session.id),
        onLongPress: () => _showSessionContextMenu(context, session),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2, right: 12),
                child: session.running
                    ? SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: theme.colorScheme.primary,
                        ),
                      )
                    : Icon(
                        context.read<ChatProvider>().isSessionPinned(session.id)
                            ? Icons.push_pin
                            : Icons.terminal,
                        size: 20,
                        color: context.read<ChatProvider>().isSessionPinned(session.id)
                            ? theme.colorScheme.primary.withAlpha(180)
                            : theme.colorScheme.onSurface.withAlpha(128),
                      ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Line 1: Title (or CWD if no title)
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
                    // Line 2: CWD (if title was shown) or message preview
                    if (hasTitle) ...[
                      const SizedBox(height: 3),
                      Text(
                        displayCwd,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: theme.colorScheme.onSurface.withAlpha(140),
                        ),
                      ),
                    ] else if (session.messagePreview.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        session.messagePreview,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          color: theme.colorScheme.onSurface.withAlpha(178),
                        ),
                      ),
                    ],
                    // Line 3: Time ago + server badge
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        Text(
                          session.running ? 'Working... · $timeAgo' : timeAgo,
                          style: TextStyle(
                            fontSize: 11,
                            color: session.running
                                ? theme.colorScheme.primary
                                : theme.colorScheme.onSurface.withAlpha(128),
                          ),
                        ),
                        if (session.serverName.isNotEmpty &&
                            context.read<ChatProvider>().serverConfigs.length > 1) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                            decoration: BoxDecoration(
                              color: session.serverColor != null
                                  ? Color(session.serverColor!).withAlpha(session.running ? 200 : 140)
                                  : theme.colorScheme.primaryContainer.withAlpha(120),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              session.serverName,
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: session.serverColor != null ? FontWeight.w500 : null,
                                color: session.serverColor != null
                                    ? Colors.white
                                    : theme.colorScheme.onPrimaryContainer,
                              ),
                            ),
                          ),
                        ],
                        // Codex sessions get a small badge so the user can
                        // tell them apart from claude in the list. Claude is
                        // implicit (no badge) since most sessions are claude.
                        if (session.backend == 'codex') ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.tertiaryContainer.withAlpha(170),
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
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                onPressed: () => _showSessionContextMenu(context, session),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Full-screen folder browser for navigating a server's filesystem.
// FolderBrowserScreen is now in widgets/folder_browser_screen.dart
