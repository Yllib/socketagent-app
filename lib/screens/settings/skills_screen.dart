import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/server_config.dart';
import '../../services/chat_provider.dart';
import '../../services/connection_manager.dart';
import '../../services/websocket_service.dart';
import 'skill_edit_screen.dart';

/// A skill entry tagged with which server it came from.
class _ServerSkill {
  final Map<String, dynamic> skill;
  final ServerConfig server;
  final String? projectCwd;

  _ServerSkill({required this.skill, required this.server, this.projectCwd});

  String get name => skill['name'] as String? ?? '';
  String get description => skill['description'] as String? ?? '';
  String get scope => skill['scope'] as String? ?? '';
  String get format => skill['format'] as String? ?? 'command';
  String get agent => skill['agent'] as String? ?? 'claude';
  String? get pluginName => skill['pluginName'] as String?;
  bool get isPlugin => scope == 'plugin';
}

class SkillsScreen extends StatefulWidget {
  const SkillsScreen({super.key});

  @override
  State<SkillsScreen> createState() => _SkillsScreenState();
}

class _SkillsScreenState extends State<SkillsScreen> {
  /// Skills grouped by server ID.
  final Map<String, List<_ServerSkill>> _byServer = {};

  /// Errors returned by specific servers.
  final Map<String, String> _serverErrors = {};
  bool _loading = true;
  String? _error;

  /// Track which expansion tiles are open (by key string).
  final Set<String> _expanded = {};
  StreamSubscription<ServerMessage>? _msgSub;

  /// Marketplace plugins grouped by server ID.
  final Map<String, List<Map<String, dynamic>>> _pluginsByServer = {};

  /// Track which plugins are being toggled.
  final Set<String> _toggling = {};

  /// Marketplaces grouped by server ID.
  final Map<String, List<Map<String, dynamic>>> _marketplacesByServer = {};

  /// Track pending marketplace operations (serverId:name or serverId:__adding__).
  final Set<String> _mpPending = {};

  @override
  void initState() {
    super.initState();
    final connMgr = context.read<ChatProvider>().connMgr;
    _msgSub = connMgr.messages.listen(_onMessage);
    _fetchAll();
  }

  @override
  void dispose() {
    _msgSub?.cancel();
    super.dispose();
  }

  ConnectionManager get _connMgr => context.read<ChatProvider>().connMgr;

  void _onMessage(ServerMessage sm) {
    if (sm.data['type'] == 'skills_list') {
      final serverId = sm.serverId;
      final config = _connMgr.configs.firstWhere(
        (c) => c.id == serverId,
        orElse: () => ServerConfig(
          id: serverId,
          name: serverId,
          host: '',
          port: 0,
          token: '',
        ),
      );
      final serverError = sm.data['error'] as String?;
      final projectCwd = sm.data['projectCwd'] as String?;
      final skills = (sm.data['skills'] as List? ?? [])
          .map(
            (e) => _ServerSkill(
              skill: Map<String, dynamic>.from(e as Map),
              server: config,
              projectCwd: projectCwd,
            ),
          )
          .toList();

      if (mounted) {
        setState(() {
          _byServer[serverId] = skills;
          if (serverError != null) {
            _serverErrors[serverId] = serverError;
          } else {
            _serverErrors.remove(serverId);
          }
          _loading = false;
          _error = null;
        });
      }
    } else if (sm.data['type'] == 'skills_save_result' ||
        sm.data['type'] == 'skills_delete_result') {
      if (sm.data['ok'] == true) {
        // Refresh that server's skills
        _connMgr.sendToServer(sm.serverId, {'type': 'skills_list'});
      }
    } else if (sm.data['type'] == 'plugins_list') {
      final plugins = (sm.data['plugins'] as List? ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      if (mounted) {
        setState(() => _pluginsByServer[sm.serverId] = plugins);
      }
    } else if (sm.data['type'] != null &&
        (sm.data['type'] as String).startsWith('plugins_') &&
        (sm.data['type'] as String).endsWith('_result')) {
      final pluginId = sm.data['pluginId'] as String?;
      if (pluginId != null) _toggling.remove('${sm.serverId}:$pluginId');
      if (sm.data['ok'] == true) {
        final plugins = (sm.data['plugins'] as List? ?? [])
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
        if (mounted) setState(() => _pluginsByServer[sm.serverId] = plugins);
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(sm.data['error'] as String? ?? 'Action failed'),
            backgroundColor: Colors.red.shade700,
          ),
        );
        setState(() {});
      }
    } else if (sm.data['type'] == 'marketplaces_list') {
      final mps = (sm.data['marketplaces'] as List? ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      if (mounted) setState(() => _marketplacesByServer[sm.serverId] = mps);
    } else if (sm.data['type'] != null &&
        (sm.data['type'] as String).startsWith('marketplaces_') &&
        (sm.data['type'] as String).endsWith('_result')) {
      // Clear any pending state for this server
      _mpPending.removeWhere((k) => k.startsWith('${sm.serverId}:'));
      if (sm.data['ok'] == true) {
        final mps = (sm.data['marketplaces'] as List? ?? [])
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
        if (mounted) {
          setState(() => _marketplacesByServer[sm.serverId] = mps);
          // Refresh plugins list since marketplaces changed
          _connMgr.sendToServer(sm.serverId, {'type': 'plugins_list'});
        }
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              sm.data['error'] as String? ?? 'Marketplace action failed',
            ),
            backgroundColor: Colors.red.shade700,
          ),
        );
        setState(() {});
      }
    }
  }

  void _pluginAction(String serverId, String pluginId, String action) {
    setState(() => _toggling.add('$serverId:$pluginId'));
    _connMgr.sendToServer(serverId, {
      'type': 'plugins_$action',
      'pluginId': pluginId,
    });
  }

  void _fetchAll() {
    setState(() {
      _loading = true;
      _error = null;
      _serverErrors.clear();
      _byServer.clear();
      _pluginsByServer.clear();
      _marketplacesByServer.clear();
    });

    final configs = _connMgr.configs;
    bool anySent = false;
    for (final config in configs) {
      final status = _connMgr.statusOf(config.id);
      if (status == ConnectionStatus.connected) {
        _connMgr.sendToServer(config.id, {'type': 'skills_list'});
        _connMgr.sendToServer(config.id, {'type': 'plugins_list'});
        _connMgr.sendToServer(config.id, {'type': 'marketplaces_list'});
        anySent = true;
      }
    }

    if (!anySent) {
      setState(() {
        _loading = false;
        _error = 'No servers connected';
      });
    }

    // Timeout fallback
    Future.delayed(const Duration(seconds: 8), () {
      if (mounted && _loading) {
        setState(() {
          _loading = false;
          _error = _byServer.isEmpty ? 'Timed out waiting for servers' : null;
        });
      }
    });

    // Retry non-responding servers after 5s
    Future.delayed(const Duration(seconds: 5), () {
      if (!mounted) return;
      final respondedIds = _byServer.keys.toSet();
      for (final config in configs) {
        if (_connMgr.statusOf(config.id) == ConnectionStatus.connected &&
            !respondedIds.contains(config.id)) {
          _connMgr.sendToServer(config.id, {'type': 'skills_list'});
        }
      }
    });
  }

  void _deleteSkill(_ServerSkill ss) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Skill?'),
        content: Text('Delete "/${ss.name}"?\nThis cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    _connMgr.sendToServer(ss.server.id, {
      'type': 'skills_delete',
      'filePath': ss.skill['filePath'],
    });
  }

  void _duplicateSkill(_ServerSkill ss) {
    final newName = '${ss.name}-copy';
    final fm = Map<String, dynamic>.from(
      (ss.skill['frontmatter'] as Map?) ?? {},
    );
    fm['description'] = fm['description'] ?? '';

    _connMgr.sendToServer(ss.server.id, {
      'type': 'skills_save',
      'name': newName,
      'scope': 'user',
      'format': ss.format,
      'agent': ss.agent,
      'frontmatter': fm,
      'body': ss.skill['body'] ?? '',
    });
  }

  void _openEditor({_ServerSkill? existing, ServerConfig? targetServer}) async {
    final server = existing?.server ?? targetServer ?? _connMgr.configs.first;
    final projectCwd = existing?.projectCwd;

    // For the edit screen, we still need HTTP for saving (it uses PUT).
    // Build the base URL from the server config — for relay servers we pass
    // the server config so the edit screen can use WS instead.
    final baseUrl = server.useRelay
        ? '' // relay servers can't use HTTP
        : 'http://${server.host}:${server.port}';

    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => SkillEditScreen(
          baseUrl: baseUrl,
          token: server.token,
          existing: existing?.skill,
          projectCwd: projectCwd,
          serverConfig: server,
        ),
      ),
    );
    if (result == true) {
      // Refresh that server
      _connMgr.sendToServer(server.id, {'type': 'skills_list'});
    }
  }

  void _showNewSkillServerPicker() {
    final connected = _connMgr.configs
        .where((c) => _connMgr.statusOf(c.id) == ConnectionStatus.connected)
        .toList();
    if (connected.isEmpty) return;
    if (connected.length == 1) {
      _openEditor(targetServer: connected.first);
      return;
    }
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Create on which server?',
                style: Theme.of(ctx).textTheme.titleSmall,
              ),
            ),
            ...connected.map(
              (s) => ListTile(
                leading: Icon(
                  Icons.dns,
                  color: s.colorValue != null ? Color(s.colorValue!) : null,
                ),
                title: Text(s.name),
                onTap: () {
                  Navigator.pop(ctx);
                  _openEditor(targetServer: s);
                },
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Skills & Commands'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _fetchAll,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.small(
        onPressed: _showNewSkillServerPicker,
        child: const Icon(Icons.add),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.error_outline,
                    size: 48,
                    color: theme.colorScheme.error.withAlpha(180),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Failed to load skills',
                    style: TextStyle(
                      color: theme.colorScheme.onSurface.withAlpha(180),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: Text(
                      _error!,
                      style: TextStyle(
                        fontSize: 12,
                        color: theme.colorScheme.onSurface.withAlpha(100),
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: _fetchAll,
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('Retry'),
                  ),
                ],
              ),
            )
          : _buildBody(),
    );
  }

  Widget _buildBody() {
    final allSkills = _byServer.values.expand((v) => v).toList();
    final allPlugins = _pluginsByServer.values.expand((v) => v).toList();
    if (allSkills.isEmpty && allPlugins.isEmpty) {
      final theme = Theme.of(context);
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.auto_fix_high,
              size: 48,
              color: theme.colorScheme.onSurface.withAlpha(80),
            ),
            const SizedBox(height: 12),
            Text(
              'No skills or commands',
              style: TextStyle(
                color: theme.colorScheme.onSurface.withAlpha(128),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Tap + to create a skill or command.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                color: theme.colorScheme.onSurface.withAlpha(100),
              ),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () async => _fetchAll(),
      child: ListView(
        padding: const EdgeInsets.only(bottom: 80),
        children: _buildSections(),
      ),
    );
  }

  List<Widget> _buildSections() {
    final sections = <Widget>[];
    final theme = Theme.of(context);
    final allConfigs = _connMgr.configs;

    // Show server errors
    for (final entry in _serverErrors.entries) {
      final config = allConfigs.where((c) => c.id == entry.key).firstOrNull;
      final name = config?.name ?? entry.key;
      sections.add(
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Text(
            '$name: ${entry.value}',
            style: TextStyle(fontSize: 11, color: Colors.red.shade300),
          ),
        ),
      );
    }

    // Check for non-responding servers
    final respondedIds = _byServer.keys.toSet();
    final nonResponding = allConfigs
        .where(
          (c) =>
              _connMgr.statusOf(c.id) == ConnectionStatus.connected &&
              !respondedIds.contains(c.id),
        )
        .toList();
    if (nonResponding.isNotEmpty) {
      final names = nonResponding.map((c) => c.name).join(', ');
      sections.add(
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Text(
            'No response: $names',
            style: TextStyle(fontSize: 11, color: Colors.orange.shade300),
          ),
        ),
      );
    }

    final allSkills = _byServer.values.expand((v) => v).toList();
    final codexSkills = <_ServerSkill>[];
    final claudeLocalSkills = <_ServerSkill>[];
    final groupedClaudePluginSkills =
        <String, Map<String, List<_ServerSkill>>>{};

    for (final s in allSkills) {
      if (s.agent == 'codex') {
        codexSkills.add(s);
      } else if (s.scope == 'plugin') {
        final plugin = s.pluginName ?? 'other';
        groupedClaudePluginSkills.putIfAbsent(plugin, () => {});
        groupedClaudePluginSkills[plugin]!.putIfAbsent(s.name, () => []).add(s);
      } else {
        claudeLocalSkills.add(s);
      }
    }

    int skillSort(_ServerSkill a, _ServerSkill b) {
      final scopeCmp = a.scope.compareTo(b.scope);
      if (scopeCmp != 0) return scopeCmp;
      return a.name.compareTo(b.name);
    }

    codexSkills.sort(skillSort);
    claudeLocalSkills.sort(skillSort);

    if (codexSkills.isNotEmpty) {
      sections.add(
        _buildGroup(
          key: 'agent_codex_skills',
          title: 'Codex Skills',
          icon: Icons.terminal,
          color: Colors.green,
          items: codexSkills,
        ),
      );
    }

    if (claudeLocalSkills.isNotEmpty) {
      sections.add(
        _buildGroup(
          key: 'agent_claude_local',
          title: 'Claude Skills & Commands',
          icon: Icons.auto_awesome,
          color: Colors.deepPurple,
          items: claudeLocalSkills,
        ),
      );
    }

    // Build plugin lookup: pluginName -> [(serverId, pluginData)]
    final pluginByName =
        <String, List<MapEntry<String, Map<String, dynamic>>>>{};
    for (final entry in _pluginsByServer.entries) {
      for (final p in entry.value) {
        final name = p['name'] as String? ?? '';
        if (name.isNotEmpty) {
          pluginByName.putIfAbsent(name, () => []).add(MapEntry(entry.key, p));
        }
      }
    }

    // Fill in missing servers on every plugin
    final respondedServerIds = _pluginsByServer.keys.toSet();
    for (final pluginName in pluginByName.keys.toList()) {
      final entries = pluginByName[pluginName]!;
      final existingServerIds = entries.map((e) => e.key).toSet();
      final first = entries.first.value;
      for (final serverId in respondedServerIds) {
        if (!existingServerIds.contains(serverId)) {
          entries.add(
            MapEntry(serverId, <String, dynamic>{
              'id': first['id'] ?? '$pluginName@unknown',
              'name': pluginName,
              'description': first['description'] ?? '',
              'category': first['category'] ?? '',
              'marketplace': first['marketplace'] ?? '',
              'installed': false,
              'enabled': false,
              'readme': '',
              'homepage': first['homepage'] ?? '',
            }),
          );
        }
      }
    }

    // Group plugins by marketplace name
    final pluginsByMarketplace = <String, List<String>>{};
    for (final entry in pluginByName.entries) {
      final mp = entry.value.first.value['marketplace'] as String? ?? '';
      pluginsByMarketplace.putIfAbsent(mp, () => []).add(entry.key);
    }

    // Build marketplace info lookup
    final mpInfoByName =
        <String, List<MapEntry<String, Map<String, dynamic>>>>{};
    for (final entry in _marketplacesByServer.entries) {
      for (final mp in entry.value) {
        final name = mp['name'] as String? ?? '';
        if (name.isNotEmpty) {
          mpInfoByName.putIfAbsent(name, () => []).add(MapEntry(entry.key, mp));
        }
      }
    }

    // ── Claude marketplace plugin sections ──
    // Collect all known marketplace names (from marketplace info + plugin data)
    final allMpNames = <String>{
      ...mpInfoByName.keys,
      ...pluginsByMarketplace.keys,
    };
    allMpNames.remove(''); // exclude plugins with no marketplace

    final sortedMpNames = allMpNames.toList()..sort();
    for (final mpName in sortedMpNames) {
      final mpInfo = mpInfoByName[mpName];
      final description = mpInfo?.first.value['description'] as String? ?? '';
      final owner = mpInfo?.first.value['owner'] as String? ?? '';
      final mpPluginNames = pluginsByMarketplace[mpName] ?? [];

      final isExpanded = _expanded.contains('mp_$mpName');
      final children = <Widget>[];

      for (final pluginName in mpPluginNames) {
        final pluginEntries = pluginByName[pluginName]!;
        final pluginSkills = groupedClaudePluginSkills[pluginName];

        if (pluginSkills != null && pluginSkills.isNotEmpty) {
          // Installed plugin with skills — show as expandable group
          final deduped = pluginSkills.values
              .map((list) => list.first)
              .toList();
          children.add(
            _buildGroup(
              key: 'claude_plugin_${mpName}_$pluginName',
              title: pluginName,
              icon: Icons.extension_outlined,
              color: Colors.deepPurple,
              items: deduped,
              pluginServerEntries: pluginEntries,
            ),
          );
        } else {
          // No skills yet — show as a toggle row
          children.add(_buildPluginToggleRow(pluginEntries));
        }
      }

      sections.add(
        ExpansionTile(
          key: PageStorageKey('mp_$mpName'),
          initiallyExpanded: isExpanded,
          onExpansionChanged: (expanded) {
            setState(() {
              if (expanded) {
                _expanded.add('mp_$mpName');
              } else {
                _expanded.remove('mp_$mpName');
              }
            });
          },
          tilePadding: const EdgeInsets.symmetric(horizontal: 16),
          childrenPadding: EdgeInsets.zero,
          dense: true,
          visualDensity: VisualDensity.compact,
          leading: Icon(
            Icons.store_outlined,
            size: 18,
            color: Colors.deepPurple.withAlpha(180),
          ),
          subtitle:
              [
                if (owner.isNotEmpty) 'by $owner',
                if (description.isNotEmpty) description,
              ].isNotEmpty
              ? Text(
                  [
                    if (owner.isNotEmpty) 'by $owner',
                    if (description.isNotEmpty) description,
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: theme.colorScheme.onSurface.withAlpha(100),
                  ),
                )
              : null,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildAgentBadge('claude'),
              const SizedBox(width: 6),
              _buildCountBadge(mpPluginNames.length, Colors.deepPurple),
              if (mpInfo != null)
                SizedBox(
                  width: 28,
                  height: 32,
                  child: PopupMenuButton<String>(
                    padding: EdgeInsets.zero,
                    iconSize: 16,
                    icon: Icon(
                      Icons.more_vert,
                      size: 16,
                      color: theme.colorScheme.onSurface.withAlpha(100),
                    ),
                    onSelected: (action) =>
                        _marketplaceAction(mpName, action, mpInfo),
                    itemBuilder: (ctx) => [
                      const PopupMenuItem(
                        value: 'update',
                        height: 36,
                        child: Text('Update', style: TextStyle(fontSize: 13)),
                      ),
                      const PopupMenuItem(
                        value: 'remove',
                        height: 36,
                        child: Text(
                          'Remove',
                          style: TextStyle(fontSize: 13, color: Colors.red),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          title: Text(
            '$mpName Plugins',
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: theme.colorScheme.onSurface.withAlpha(220),
            ),
          ),
          children: children,
        ),
      );
    }

    // ── Add Claude marketplace button ──
    sections.add(
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: OutlinedButton.icon(
          onPressed: _showAddMarketplaceDialog,
          icon: const Icon(Icons.add, size: 16),
          label: const Text(
            'Add Claude Marketplace',
            style: TextStyle(fontSize: 13),
          ),
          style: OutlinedButton.styleFrom(
            visualDensity: VisualDensity.compact,
            side: BorderSide(color: Colors.deepPurple.withAlpha(80)),
          ),
        ),
      ),
    );

    return sections;
  }

  Widget _buildCountBadge(int count, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 0),
      decoration: BoxDecoration(
        color: color.withAlpha(25),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        '$count',
        style: TextStyle(
          fontSize: 10,
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _buildAgentBadge(String agent) {
    final isCodex = agent == 'codex';
    final color = isCodex ? Colors.green : Colors.deepPurple;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: color.withAlpha(24),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withAlpha(70)),
      ),
      child: Text(
        isCodex ? 'Codex' : 'Claude',
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w600,
          color: color.withAlpha(220),
        ),
      ),
    );
  }

  Widget _buildScopeBadge(String scope) {
    final color = switch (scope) {
      'project' => Colors.blueGrey,
      'plugin' => Colors.deepPurple,
      _ => Colors.grey,
    };
    final label = switch (scope) {
      'project' => 'Project',
      'plugin' => 'Plugin',
      _ => 'User',
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: color.withAlpha(20),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withAlpha(60)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w600,
          color: color.withAlpha(220),
        ),
      ),
    );
  }

  Widget _buildSkillServerBadge(ServerConfig server) {
    final color = server.colorValue != null
        ? Color(server.colorValue!)
        : Theme.of(context).colorScheme.outline;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: color.withAlpha(20),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withAlpha(60)),
      ),
      child: Text(
        server.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w600,
          color: color.withAlpha(220),
        ),
      ),
    );
  }

  void _showAddMarketplaceDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add Claude Marketplace'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'https://github.com/user/marketplace.git',
            labelText: 'Git URL',
          ),
          onSubmitted: (_) {
            Navigator.pop(ctx);
            _addMarketplace(controller.text.trim());
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _addMarketplace(controller.text.trim());
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }

  void _addMarketplace(String url) {
    if (url.isEmpty) return;
    // Send to all connected servers
    final configs = _connMgr.configs;
    for (final config in configs) {
      if (_connMgr.statusOf(config.id) == ConnectionStatus.connected) {
        setState(() => _mpPending.add('${config.id}:__adding__'));
        _connMgr.sendToServer(config.id, {
          'type': 'marketplaces_add',
          'url': url,
        });
      }
    }
  }

  void _marketplaceAction(
    String name,
    String action,
    List<MapEntry<String, Map<String, dynamic>>> serverEntries,
  ) {
    if (action == 'remove') {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Remove Marketplace?'),
          content: Text(
            'Remove "$name" from all servers?\nPlugins from this marketplace will no longer appear.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                for (final entry in serverEntries) {
                  setState(() => _mpPending.add('${entry.key}:$name'));
                  _connMgr.sendToServer(entry.key, {
                    'type': 'marketplaces_remove',
                    'name': name,
                  });
                }
              },
              child: const Text('Remove', style: TextStyle(color: Colors.red)),
            ),
          ],
        ),
      );
    } else if (action == 'update') {
      for (final entry in serverEntries) {
        setState(() => _mpPending.add('${entry.key}:$name'));
        _connMgr.sendToServer(entry.key, {
          'type': 'marketplaces_update',
          'name': name,
        });
      }
    }
  }

  Widget _buildGroup({
    required String key,
    required String title,
    required IconData icon,
    required Color color,
    required List<_ServerSkill> items,
    List<MapEntry<String, Map<String, dynamic>>>? pluginServerEntries,
  }) {
    final theme = Theme.of(context);
    final isExpanded = _expanded.contains(key);
    final hasPlugin =
        pluginServerEntries != null && pluginServerEntries.isNotEmpty;
    final pluginDescription = hasPlugin
        ? pluginServerEntries.first.value['description'] as String? ?? ''
        : '';

    return ExpansionTile(
      key: PageStorageKey(key),
      initiallyExpanded: isExpanded,
      onExpansionChanged: (expanded) {
        setState(() {
          if (expanded) {
            _expanded.add(key);
          } else {
            _expanded.remove(key);
          }
        });
      },
      tilePadding: const EdgeInsets.symmetric(horizontal: 20),
      childrenPadding: const EdgeInsets.only(left: 16),
      dense: true,
      visualDensity: VisualDensity.compact,
      leading: Icon(icon, size: 16, color: color.withAlpha(180)),
      subtitle: pluginDescription.isNotEmpty
          ? Text(
              pluginDescription,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                color: theme.colorScheme.onSurface.withAlpha(100),
              ),
            )
          : null,
      trailing: hasPlugin ? _buildPluginActions(pluginServerEntries) : null,
      title: Row(
        children: [
          Flexible(
            child: Text(
              title,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: theme.colorScheme.onSurface.withAlpha(220),
              ),
            ),
          ),
          if (items.isNotEmpty) ...[
            const SizedBox(width: 6),
            if (hasPlugin) ...[
              _buildAgentBadge('claude'),
              const SizedBox(width: 6),
            ],
            _buildCountBadge(items.length, color),
          ],
        ],
      ),
      children: items.map((s) => _buildSkillRow(s)).toList(),
    );
  }

  Widget _buildSkillRow(_ServerSkill ss) {
    final theme = Theme.of(context);

    return InkWell(
      onTap: () => _openEditor(existing: ss),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
        child: Row(
          children: [
            Icon(
              ss.format == 'skill' ? Icons.auto_fix_high : Icons.terminal,
              size: 15,
              color: theme.colorScheme.onSurface.withAlpha(100),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '/${ss.name}',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      fontFamily: 'monospace',
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      _buildAgentBadge(ss.agent),
                      const SizedBox(width: 4),
                      _buildScopeBadge(ss.scope),
                      const SizedBox(width: 4),
                      Flexible(child: _buildSkillServerBadge(ss.server)),
                    ],
                  ),
                  if (ss.description.isNotEmpty)
                    Text(
                      ss.description,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: theme.colorScheme.onSurface.withAlpha(120),
                      ),
                    ),
                ],
              ),
            ),
            SizedBox(
              width: 32,
              height: 32,
              child: PopupMenuButton<String>(
                padding: EdgeInsets.zero,
                iconSize: 16,
                icon: Icon(
                  Icons.more_vert,
                  size: 16,
                  color: theme.colorScheme.onSurface.withAlpha(100),
                ),
                onSelected: (action) {
                  switch (action) {
                    case 'duplicate':
                      _duplicateSkill(ss);
                      break;
                    case 'delete':
                      _deleteSkill(ss);
                      break;
                  }
                },
                itemBuilder: (ctx) => [
                  const PopupMenuItem(
                    value: 'duplicate',
                    height: 36,
                    child: Text('Duplicate', style: TextStyle(fontSize: 13)),
                  ),
                  if (!ss.isPlugin)
                    const PopupMenuItem(
                      value: 'delete',
                      height: 36,
                      child: Text(
                        'Delete',
                        style: TextStyle(fontSize: 13, color: Colors.red),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _openPluginReadme(String serverId, Map<String, dynamic> plugin) {
    final name = plugin['name'] as String? ?? '';
    final description = plugin['description'] as String? ?? '';
    final readme = plugin['readme'] as String? ?? '';
    if (readme.isEmpty && description.isEmpty) return;

    final config = _connMgr.configs.firstWhere(
      (c) => c.id == serverId,
      orElse: () => ServerConfig(
        id: serverId,
        name: serverId,
        host: '',
        port: 0,
        token: '',
      ),
    );
    final baseUrl = config.useRelay
        ? ''
        : 'http://${config.host}:${config.port}';

    // Construct a fake skill entry so the editor opens in read-only plugin mode
    final fakeSkill = <String, dynamic>{
      'name': name,
      'description': description,
      'scope': 'plugin',
      'pluginName': name,
      'format': 'skill',
      'agent': 'claude',
      'frontmatter': <String, dynamic>{'description': description},
      'body': readme,
    };

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SkillEditScreen(
          baseUrl: baseUrl,
          token: config.token,
          existing: fakeSkill,
          serverConfig: config,
        ),
      ),
    );
  }

  /// Flat list tile for marketplace plugins — shows per-server status badges
  /// and routes actions through the server picker when multiple servers.
  Widget _buildPluginToggleRow(
    List<MapEntry<String, Map<String, dynamic>>> serverEntries,
  ) {
    final theme = Theme.of(context);
    final first = serverEntries.first.value;
    final name = first['name'] as String? ?? '';
    final description = first['description'] as String? ?? '';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: ListTile(
        dense: true,
        visualDensity: VisualDensity.compact,
        onTap: () => _openPluginReadme(serverEntries.first.key, first),
        leading: Icon(
          Icons.extension_outlined,
          size: 18,
          color: Colors.orange.withAlpha(180),
        ),
        title: Row(
          children: [
            Flexible(
              child: Text(
                name,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: theme.colorScheme.onSurface.withAlpha(220),
                ),
              ),
            ),
            const SizedBox(width: 6),
            _buildAgentBadge('claude'),
          ],
        ),
        subtitle: description.isNotEmpty
            ? Text(
                description,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  color: theme.colorScheme.onSurface.withAlpha(100),
                ),
              )
            : null,
        trailing: _buildPluginActions(serverEntries),
      ),
    );
  }

  /// Builds the trailing action widget for a marketplace plugin across servers.
  /// Always shows per-server badges with state. Tap opens server picker for actions.
  Widget _buildPluginActions(
    List<MapEntry<String, Map<String, dynamic>>> serverEntries,
  ) {
    return GestureDetector(
      onTap: () => _showPluginServerPicker(serverEntries),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: serverEntries.map((entry) {
          final serverId = entry.key;
          final installed = entry.value['installed'] as bool? ?? false;
          final enabled = entry.value['enabled'] as bool? ?? false;
          final config = _connMgr.configs
              .where((c) => c.id == serverId)
              .firstOrNull;
          if (config == null) return const SizedBox.shrink();
          return Padding(
            padding: const EdgeInsets.only(left: 2),
            child: _buildServerPluginBadge(config, installed, enabled),
          );
        }).toList(),
      ),
    );
  }

  /// Inline action widget for a single server's plugin state.
  /// [onAction] is called after triggering an action so the caller can rebuild.
  Widget _buildSingleServerAction(
    String serverId,
    String pluginId,
    bool installed,
    bool enabled, {
    VoidCallback? onAction,
  }) {
    final isToggling = _toggling.contains('$serverId:$pluginId');

    void act(String action) {
      _pluginAction(serverId, pluginId, action);
      onAction?.call();
    }

    if (!installed) {
      return SizedBox(
        height: 32,
        child: TextButton(
          onPressed: isToggling ? null : () => act('install'),
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: isToggling
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Install', style: TextStyle(fontSize: 12)),
        ),
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: 32,
          child: FittedBox(
            child: Switch(
              value: enabled,
              onChanged: isToggling
                  ? null
                  : (val) => act(val ? 'enable' : 'disable'),
            ),
          ),
        ),
        SizedBox(
          width: 24,
          height: 32,
          child: PopupMenuButton<String>(
            padding: EdgeInsets.zero,
            iconSize: 14,
            icon: Icon(
              Icons.more_vert,
              size: 14,
              color: Theme.of(context).colorScheme.onSurface.withAlpha(100),
            ),
            onSelected: (action) {
              if (action == 'uninstall') act('uninstall');
            },
            itemBuilder: (ctx) => [
              const PopupMenuItem(
                value: 'uninstall',
                height: 36,
                child: Text(
                  'Uninstall',
                  style: TextStyle(fontSize: 13, color: Colors.red),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Server badge with install/enable state coloring.
  Widget _buildServerPluginBadge(
    ServerConfig server,
    bool installed,
    bool enabled,
  ) {
    final c = server.colorValue != null
        ? Color(server.colorValue!)
        : Theme.of(context).colorScheme.primary;
    final alpha = !installed ? 40 : (enabled ? 200 : 100);
    final bgAlpha = !installed ? 8 : (enabled ? 30 : 15);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: c.withAlpha(bgAlpha),
        borderRadius: BorderRadius.circular(5),
        border: !installed
            ? Border.all(color: c.withAlpha(30), width: 0.5)
            : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (installed && enabled)
            Padding(
              padding: const EdgeInsets.only(right: 2),
              child: Icon(Icons.check, size: 7, color: c.withAlpha(alpha)),
            ),
          Text(
            server.name,
            style: TextStyle(
              fontSize: 8,
              fontWeight: FontWeight.w500,
              color: c.withAlpha(alpha),
            ),
          ),
        ],
      ),
    );
  }

  /// Bottom sheet showing per-server plugin state with action buttons.
  /// Uses StatefulBuilder + stream subscription so the sheet updates live
  /// when install/enable/disable results arrive.
  void _showPluginServerPicker(
    List<MapEntry<String, Map<String, dynamic>>> serverEntries,
  ) {
    final pluginName = serverEntries.first.value['name'] as String? ?? '';

    // Subscribe to message stream so the sheet rebuilds on plugin results.
    StateSetter? setSheetState;
    final sub = _connMgr.messages.listen((sm) {
      final type = sm.data['type'] as String?;
      if (type != null &&
          type.startsWith('plugins_') &&
          type.endsWith('_result')) {
        setSheetState?.call(() {});
      }
    });

    showModalBottomSheet(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, sheetSetState) {
          setSheetState = sheetSetState;

          // Rebuild entries from current _pluginsByServer state each time.
          // Include stub "not installed" entries for servers that responded
          // but don't have this plugin, so all servers appear in the sheet.
          final currentEntries = <MapEntry<String, Map<String, dynamic>>>[];
          final seenServerIds = <String>{};
          final firstData = serverEntries.first.value;
          for (final entry in _pluginsByServer.entries) {
            seenServerIds.add(entry.key);
            final match = entry.value
                .where((p) => p['name'] == pluginName)
                .firstOrNull;
            currentEntries.add(
              MapEntry(
                entry.key,
                match ??
                    <String, dynamic>{
                      'id': firstData['id'] ?? '$pluginName@unknown',
                      'name': pluginName,
                      'description': firstData['description'] ?? '',
                      'category': firstData['category'] ?? '',
                      'installed': false,
                      'enabled': false,
                    },
              ),
            );
          }
          final entries = currentEntries.isNotEmpty
              ? currentEntries
              : serverEntries;

          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    pluginName,
                    style: Theme.of(ctx).textTheme.titleSmall,
                  ),
                ),
                ...entries.map((entry) {
                  final serverId = entry.key;
                  final pluginId = entry.value['id'] as String? ?? '';
                  final installed = entry.value['installed'] as bool? ?? false;
                  final enabled = entry.value['enabled'] as bool? ?? false;
                  final config = _connMgr.configs
                      .where((c) => c.id == serverId)
                      .firstOrNull;
                  if (config == null) return const SizedBox.shrink();

                  final serverColor = config.colorValue != null
                      ? Color(config.colorValue!)
                      : Theme.of(ctx).colorScheme.primary;

                  String statusText;
                  if (_toggling.contains('$serverId:$pluginId')) {
                    statusText = 'Updating...';
                  } else if (!installed) {
                    statusText = 'Not installed';
                  } else if (enabled) {
                    statusText = 'Installed, enabled';
                  } else {
                    statusText = 'Installed, disabled';
                  }

                  return ListTile(
                    leading: Icon(Icons.dns, color: serverColor),
                    title: Text(config.name),
                    subtitle: Text(
                      statusText,
                      style: const TextStyle(fontSize: 12),
                    ),
                    trailing: _buildSingleServerAction(
                      serverId,
                      pluginId,
                      installed,
                      enabled,
                      onAction: () => sheetSetState(() {}),
                    ),
                  );
                }),
                const SizedBox(height: 8),
              ],
            ),
          );
        },
      ),
    ).whenComplete(() => sub.cancel());
  }
}
