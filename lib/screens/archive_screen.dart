import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/archive_entry.dart';
import '../models/message.dart';
import '../services/chat_provider.dart';
import '../widgets/codex_command_card.dart';
import '../widgets/codex_plan_card.dart';
import '../widgets/file_card.dart';
import '../widgets/message_bubble.dart';
import '../widgets/reminder_card.dart';
import '../widgets/speak_card.dart';
import '../widgets/tool_output_block.dart';

class ArchiveScreen extends StatefulWidget {
  const ArchiveScreen({super.key});

  @override
  State<ArchiveScreen> createState() => _ArchiveScreenState();
}

enum _ArchiveSort { newestFirst, oldestFirst, titleAZ, mostMessages }

const List<String> _monthNames = [
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

String _formatRelative(String iso) {
  try {
    final dt = DateTime.parse(iso).toLocal();
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inSeconds < 45) return 'just now';
    if (diff.inMinutes < 1) return '${diff.inSeconds}s ago';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    if (dt.year == now.year) {
      return '${_monthNames[dt.month - 1]} ${dt.day}';
    }
    return '${_monthNames[dt.month - 1]} ${dt.day}, ${dt.year}';
  } catch (_) {
    return iso;
  }
}

String _formatAbsolute(String iso) {
  try {
    final dt = DateTime.parse(iso).toLocal();
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    return '${_monthNames[dt.month - 1]} ${dt.day}, ${dt.year} at $hh:$mm';
  } catch (_) {
    return iso;
  }
}

class _ArchiveScreenState extends State<ArchiveScreen>
    with TickerProviderStateMixin {
  bool _loading = true;
  bool _searching = false;
  StreamSubscription<String>? _feedbackSub;
  _ArchiveSort _sort = _ArchiveSort.newestFirst;
  TabController? _tabController;
  int _lastServerCount = -1;
  final TextEditingController _searchController = TextEditingController();
  Timer? _searchDebounce;
  int _searchGeneration = 0;
  final Set<String> _historyMatchedKeys = {};
  final Map<String, String> _historySearchCache = {};

  @override
  void initState() {
    super.initState();
    _refresh();
    _feedbackSub = context.read<ChatProvider>().archiveFeedback.listen((msg) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    });
  }

  @override
  void dispose() {
    _feedbackSub?.cancel();
    _tabController?.dispose();
    _searchDebounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    await context.read<ChatProvider>().fetchArchives();
    if (!mounted) return;
    setState(() => _loading = false);
    _scheduleSearch(context.read<ChatProvider>(), immediate: true);
  }

  void _ensureTabController(int serverCount) {
    if (_tabController != null && _lastServerCount == serverCount) return;
    _tabController?.dispose();
    _tabController = serverCount > 0
        ? TabController(length: 1 + serverCount, vsync: this)
        : null;
    _lastServerCount = serverCount;
  }

  String _displayCwd(String cwd) {
    final homePattern = RegExp(r'^/home/[^/]+/');
    final homeExact = RegExp(r'^/home/[^/]+$');
    if (homePattern.hasMatch(cwd)) {
      return '~/${cwd.replaceFirst(homePattern, '')}';
    }
    if (homeExact.hasMatch(cwd)) return '~';
    return cwd;
  }

  String _backendLabel(String? backend) {
    return backend == 'codex' ? 'Codex' : 'Claude';
  }

  IconData _backendIcon(String? backend) {
    return backend == 'codex' ? Icons.terminal : Icons.auto_awesome;
  }

  List<ArchiveEntry> _sortedArchives(List<ArchiveEntry> xs) {
    final list = [...xs];
    switch (_sort) {
      case _ArchiveSort.newestFirst:
        list.sort((a, b) => b.clearedAt.compareTo(a.clearedAt));
        break;
      case _ArchiveSort.oldestFirst:
        list.sort((a, b) => a.clearedAt.compareTo(b.clearedAt));
        break;
      case _ArchiveSort.titleAZ:
        list.sort((a, b) {
          final at = a.title.trim().toLowerCase();
          final bt = b.title.trim().toLowerCase();
          if (at.isEmpty && bt.isNotEmpty) return 1;
          if (bt.isEmpty && at.isNotEmpty) return -1;
          return at.compareTo(bt);
        });
        break;
      case _ArchiveSort.mostMessages:
        list.sort((a, b) => b.messageCount.compareTo(a.messageCount));
        break;
    }
    return list;
  }

  String _sortLabel(_ArchiveSort s) {
    switch (s) {
      case _ArchiveSort.newestFirst:
        return 'Newest first';
      case _ArchiveSort.oldestFirst:
        return 'Oldest first';
      case _ArchiveSort.titleAZ:
        return 'Title (A–Z)';
      case _ArchiveSort.mostMessages:
        return 'Most messages';
    }
  }

  IconData _sortIcon(_ArchiveSort s) {
    switch (s) {
      case _ArchiveSort.newestFirst:
        return Icons.arrow_downward;
      case _ArchiveSort.oldestFirst:
        return Icons.arrow_upward;
      case _ArchiveSort.titleAZ:
        return Icons.sort_by_alpha;
      case _ArchiveSort.mostMessages:
        return Icons.format_list_numbered;
    }
  }

  String get _searchQuery => _searchController.text.trim().toLowerCase();

  String _entryKey(ArchiveEntry entry) =>
      '${entry.serverId}_${entry.sid}_${entry.ts}';

  bool _metadataMatches(ArchiveEntry entry, String query) {
    if (query.isEmpty) return true;
    final haystack = [
      entry.title,
      entry.cwd,
      entry.messagePreview,
      entry.serverName,
      entry.backend ?? '',
      _backendLabel(entry.backend),
      entry.createdAt,
      entry.clearedAt,
    ].join('\n').toLowerCase();
    return haystack.contains(query);
  }

  bool _belongsToServer(
    ArchiveEntry entry,
    String serverId,
    ChatProvider provider,
  ) {
    if (entry.serverId == serverId) return true;
    return entry.serverId.isEmpty &&
        provider.serverConfigs.length == 1 &&
        provider.serverConfigs.first.id == serverId;
  }

  List<ArchiveEntry> _filteredArchives(
    ChatProvider provider,
    String? serverId,
  ) {
    final query = _searchQuery;
    final scoped = provider.archives.where((entry) {
      if (serverId == null) return true;
      return _belongsToServer(entry, serverId, provider);
    }).toList();
    final searched = query.isEmpty
        ? scoped
        : scoped.where((entry) {
            return _metadataMatches(entry, query) ||
                _historyMatchedKeys.contains(_entryKey(entry));
          }).toList();
    return _sortedArchives(searched);
  }

  void _scheduleSearch(ChatProvider provider, {bool immediate = false}) {
    _searchDebounce?.cancel();
    if (_searchQuery.isEmpty) {
      setState(() {
        _searching = false;
        _historyMatchedKeys.clear();
      });
      return;
    }
    if (immediate) {
      _runSearch(provider);
    } else {
      _searchDebounce = Timer(const Duration(milliseconds: 300), () {
        _runSearch(provider);
      });
    }
  }

  Future<void> _runSearch(ChatProvider provider) async {
    final query = _searchQuery;
    final generation = ++_searchGeneration;
    if (query.isEmpty) return;
    setState(() => _searching = true);

    final matches = <String>{};
    for (final entry in provider.archives) {
      final key = _entryKey(entry);
      if (_metadataMatches(entry, query)) {
        matches.add(key);
        continue;
      }
      var historyText = _historySearchCache[key];
      if (historyText == null) {
        final raw = await provider.fetchArchiveHistory(
          entry.sid,
          entry.ts,
          serverId: entry.serverId.isNotEmpty ? entry.serverId : null,
        );
        historyText = _archiveHistorySearchText(raw);
        _historySearchCache[key] = historyText;
      }
      if (historyText.contains(query)) matches.add(key);
      if (!mounted || generation != _searchGeneration) return;
    }

    if (!mounted || generation != _searchGeneration) return;
    setState(() {
      _historyMatchedKeys
        ..clear()
        ..addAll(matches);
      _searching = false;
    });
  }

  String _archiveHistorySearchText(List<dynamic> entries) {
    final parts = <String>[];
    for (final raw in entries) {
      if (raw is! Map) continue;
      final entry = Map<String, dynamic>.from(raw);
      for (final key in const [
        'role',
        'content',
        'toolName',
        'toolOutput',
        'filePath',
      ]) {
        final value = entry[key];
        if (value is String && value.isNotEmpty) parts.add(value);
      }
      final input = entry['toolInput'];
      if (input is Map || input is List) {
        try {
          parts.add(jsonEncode(input));
        } catch (_) {}
      }
    }
    return parts.join('\n').toLowerCase();
  }

  Future<void> _confirmDelete(ArchiveEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Archive'),
        content: Text(
          'Permanently delete "${entry.title}" and its history. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      context.read<ChatProvider>().deleteArchive(
        entry.sid,
        entry.ts,
        serverId: entry.serverId.isNotEmpty ? entry.serverId : null,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Consumer<ChatProvider>(
      builder: (context, provider, _) {
        final configs = provider.serverConfigs;
        _ensureTabController(configs.length);
        return Scaffold(
          appBar: AppBar(
            title: const Text('Archived Sessions'),
            actions: [
              PopupMenuButton<_ArchiveSort>(
                icon: const Icon(Icons.sort),
                tooltip: 'Sort: ${_sortLabel(_sort)}',
                onSelected: (v) => setState(() => _sort = v),
                itemBuilder: (_) => _ArchiveSort.values.map((s) {
                  final selected = s == _sort;
                  return PopupMenuItem<_ArchiveSort>(
                    value: s,
                    child: Row(
                      children: [
                        Icon(
                          _sortIcon(s),
                          size: 18,
                          color: selected ? theme.colorScheme.primary : null,
                        ),
                        const SizedBox(width: 10),
                        Text(
                          _sortLabel(s),
                          style: TextStyle(
                            fontWeight: selected
                                ? FontWeight.w600
                                : FontWeight.normal,
                            color: selected ? theme.colorScheme.primary : null,
                          ),
                        ),
                      ],
                    ),
                  );
                }).toList(),
              ),
              IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: 'Refresh',
                onPressed: _refresh,
              ),
            ],
            bottom: configs.isNotEmpty && _tabController != null
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
          body: _loading && provider.archives.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : provider.archives.isEmpty
              ? _buildEmptyState(theme)
              : Column(
                  children: [
                    _buildSearchField(provider),
                    if (_searching) const LinearProgressIndicator(minHeight: 2),
                    Expanded(
                      child: configs.isNotEmpty && _tabController != null
                          ? TabBarView(
                              controller: _tabController,
                              children: [
                                _buildArchiveList(context, provider, null),
                                ...configs.map(
                                  (config) => _buildArchiveList(
                                    context,
                                    provider,
                                    config.id,
                                  ),
                                ),
                              ],
                            )
                          : _buildArchiveList(context, provider, null),
                    ),
                  ],
                ),
        );
      },
    );
  }

  Widget _buildEmptyState(ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.inventory_2_outlined,
              size: 64,
              color: theme.colorScheme.onSurface.withAlpha(90),
            ),
            const SizedBox(height: 16),
            Text(
              'No archived sessions',
              style: TextStyle(
                fontSize: 16,
                color: theme.colorScheme.onSurface.withAlpha(140),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Clearing a session\'s context archives its history here.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: theme.colorScheme.onSurface.withAlpha(110),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchField(ChatProvider provider) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      child: TextField(
        controller: _searchController,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          hintText: 'Search archives',
          prefixIcon: const Icon(Icons.search),
          suffixIcon: _searchController.text.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.clear),
                  tooltip: 'Clear search',
                  onPressed: () {
                    _searchController.clear();
                    _scheduleSearch(provider, immediate: true);
                  },
                ),
          isDense: true,
          filled: true,
          fillColor: theme.colorScheme.surfaceContainerHighest.withAlpha(120),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide.none,
          ),
        ),
        onChanged: (_) {
          setState(() {});
          _scheduleSearch(provider);
        },
      ),
    );
  }

  Widget _buildArchiveList(
    BuildContext context,
    ChatProvider provider,
    String? serverId,
  ) {
    final theme = Theme.of(context);
    final archives = _filteredArchives(provider, serverId);
    if (archives.isEmpty) {
      return RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          children: [
            SizedBox(height: MediaQuery.of(context).size.height * 0.22),
            Icon(
              Icons.search_off,
              size: 48,
              color: theme.colorScheme.onSurface.withAlpha(90),
            ),
            const SizedBox(height: 12),
            Text(
              _searchQuery.isEmpty
                  ? 'No archives on this server'
                  : 'No matches',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: theme.colorScheme.onSurface.withAlpha(140),
              ),
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView.separated(
        itemCount: archives.length,
        separatorBuilder: (_, __) =>
            Divider(height: 1, color: theme.colorScheme.outline.withAlpha(40)),
        itemBuilder: (context, idx) => _buildArchiveRow(archives[idx]),
      ),
    );
  }

  Widget _buildArchiveRow(ArchiveEntry e) {
    final theme = Theme.of(context);
    final canDelete = !e.isNativeCodexArchive;
    return Dismissible(
      key: Key('archive_${e.serverId}_${e.sid}_${e.ts}'),
      direction: canDelete
          ? DismissDirection.endToStart
          : DismissDirection.none,
      background: canDelete
          ? Container(
              alignment: Alignment.centerRight,
              padding: const EdgeInsets.only(right: 20),
              color: Colors.red,
              child: const Icon(Icons.delete, color: Colors.white),
            )
          : null,
      confirmDismiss: (_) async {
        if (!canDelete) return false;
        await _confirmDelete(e);
        return false;
      },
      child: ListTile(
        leading: Icon(
          e.hasJsonl ? _backendIcon(e.backend) : Icons.description_outlined,
          color: theme.colorScheme.primary.withAlpha(180),
        ),
        title: Text(
          e.title.isNotEmpty ? e.title : 'Untitled',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (e.cwd.isNotEmpty)
              Text(
                _displayCwd(e.cwd),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12),
              ),
            Wrap(
              spacing: 8,
              runSpacing: 2,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _backendIcon(e.backend),
                      size: 12,
                      color: theme.colorScheme.onSurface.withAlpha(130),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      _backendLabel(e.backend),
                      style: TextStyle(
                        fontSize: 11,
                        color: theme.colorScheme.onSurface.withAlpha(130),
                      ),
                    ),
                  ],
                ),
                if (e.serverName.isNotEmpty)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.dns_outlined,
                        size: 12,
                        color: theme.colorScheme.onSurface.withAlpha(130),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        e.serverName,
                        style: TextStyle(
                          fontSize: 11,
                          color: theme.colorScheme.onSurface.withAlpha(130),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
            Tooltip(
              message: _formatAbsolute(e.clearedAt),
              child: Text(
                'Cleared ${_formatRelative(e.clearedAt)} · ${e.messageCount} msg${e.messageCount == 1 ? '' : 's'}',
                style: TextStyle(
                  fontSize: 11,
                  color: theme.colorScheme.onSurface.withAlpha(130),
                ),
              ),
            ),
          ],
        ),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => ArchiveDetailScreen(entry: e)),
        ),
      ),
    );
  }
}

class ArchiveDetailScreen extends StatefulWidget {
  final ArchiveEntry entry;
  const ArchiveDetailScreen({super.key, required this.entry});

  @override
  State<ArchiveDetailScreen> createState() => _ArchiveDetailScreenState();
}

class _ArchiveDetailScreenState extends State<ArchiveDetailScreen> {
  List<ChatMessage>? _messages;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final provider = context.read<ChatProvider>();
    final rawMessages = await provider.fetchArchiveHistory(
      widget.entry.sid,
      widget.entry.ts,
      serverId: widget.entry.serverId.isNotEmpty ? widget.entry.serverId : null,
    );
    final messages = _historyToMessages(rawMessages);
    await _fetchArchiveImages(provider, messages);
    if (!mounted) return;
    setState(() {
      _messages = messages;
      _loading = false;
    });
  }

  List<ChatMessage> _historyToMessages(List<dynamic> entries) {
    final loaded = <ChatMessage>[];
    for (final raw in entries) {
      if (raw is! Map) continue;
      final entry = Map<String, dynamic>.from(raw);
      final role = entry['role'] as String? ?? '';
      final content = entry['content'] as String? ?? '';
      switch (role) {
        case 'user':
          loaded.add(
            ChatMessage(
              id: 'archive_user_${loaded.length}',
              sender: MessageSender.user,
              type: MessageType.text,
              timestamp: _entryTimestamp(entry),
              textContent: content,
            ),
          );
          break;
        case 'assistant':
          loaded.add(
            ChatMessage(
              id: 'archive_assistant_${loaded.length}',
              sender: MessageSender.assistant,
              type: MessageType.text,
              timestamp: _entryTimestamp(entry),
              textContent: content,
            ),
          );
          break;
        case 'tool_call':
          final toolName = normalizeSocketAgentToolName(
            entry['toolName'] as String? ?? 'Tool',
          );
          final toolInput = Map<String, dynamic>.from(
            (entry['toolInput'] as Map?) ?? const {},
          );
          loaded.add(
            ChatMessage.toolCall(
              tool: toolName,
              input: toolInput,
              toolUseId: entry['toolUseId'] as String? ?? '',
            )..toolStreaming = false,
          );
          break;
        case 'tool_result':
          final toolUseId = entry['toolUseId'] as String? ?? '';
          final output = entry['toolOutput'] as String? ?? content;
          final idx = loaded.lastIndexWhere(
            (m) => m.type == MessageType.toolCall && m.toolUseId == toolUseId,
          );
          if (idx >= 0) {
            loaded[idx].toolOutput = output;
            loaded[idx].toolStreaming = false;
          } else {
            loaded.add(
              ChatMessage.toolResult(toolUseId: toolUseId, output: output),
            );
          }
          break;
        case 'tool_image':
          final toolUseId = entry['toolUseId'] as String? ?? '';
          final filePath = entry['filePath'] as String? ?? '';
          final mimeType = entry['mimeType'] as String? ?? 'image/png';
          final idx = loaded.lastIndexWhere(
            (m) => m.type == MessageType.toolCall && m.toolUseId == toolUseId,
          );
          if (idx >= 0) {
            loaded[idx].toolImageFilePath = filePath;
            loaded[idx].toolImageMimeType = mimeType;
          }
          break;
        case 'codex_plan':
          final turnId = entry['toolUseId'] as String? ?? '';
          final input = Map<String, dynamic>.from(
            (entry['toolInput'] as Map?) ?? const {},
          );
          final explanation = input['explanation'] as String? ?? content;
          final rawSteps = input['steps'] as List? ?? const [];
          final steps = rawSteps
              .whereType<Map>()
              .map((step) => Map<String, dynamic>.from(step))
              .toList();
          if (steps.isNotEmpty || explanation.trim().isNotEmpty) {
            loaded.add(
              ChatMessage.codexPlan(
                turnId: turnId,
                explanation: explanation,
                steps: steps,
              ),
            );
          }
          break;
        case 'notification':
          final commandName = entry['commandName'] as String?;
          final commandPayload = entry['commandPayload'] is Map
              ? Map<String, dynamic>.from(entry['commandPayload'] as Map)
              : null;
          if (commandName != null && commandPayload != null) {
            loaded.add(
              ChatMessage.codexCommand(
                command: commandName,
                summary: content,
                status: entry['status'] as String? ?? 'completed',
                payload: commandPayload,
              ),
            );
          } else if (content.trim().isNotEmpty) {
            loaded.add(
              ChatMessage(
                id: 'archive_system_${loaded.length}',
                sender: MessageSender.system,
                type: MessageType.text,
                timestamp: _entryTimestamp(entry),
                textContent: content,
              ),
            );
          }
          break;
        default:
          if (content.trim().isNotEmpty || role.isNotEmpty) {
            loaded.add(
              ChatMessage(
                id: 'archive_system_${loaded.length}',
                sender: MessageSender.system,
                type: MessageType.text,
                timestamp: _entryTimestamp(entry),
                textContent: content.trim().isNotEmpty ? content : role,
              ),
            );
          }
      }
    }
    for (final message in loaded) {
      if (message.type == MessageType.toolCall && message.toolOutput == null) {
        message.toolOutput = '';
        message.toolStreaming = false;
      }
    }
    return loaded;
  }

  DateTime _entryTimestamp(Map<String, dynamic> entry) {
    return DateTime.tryParse(entry['timestamp'] as String? ?? '') ??
        DateTime.now();
  }

  Future<void> _fetchArchiveImages(
    ChatProvider provider,
    List<ChatMessage> messages,
  ) async {
    for (final message in messages) {
      final filePath = message.toolImageFilePath;
      if (message.type != MessageType.toolCall ||
          filePath == null ||
          filePath.isEmpty ||
          message.toolImageData != null) {
        continue;
      }
      try {
        final data = await provider.fetchServerFileBase64(
          filePath,
          serverId: widget.entry.serverId.isNotEmpty
              ? widget.entry.serverId
              : null,
        );
        if (data != null && data.isNotEmpty) {
          message.toolImageData = data;
        }
      } catch (_) {
        // Leave the image placeholder visible if the archived file is gone.
      }
    }
  }

  Future<void> _confirmRestore() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Restore Session'),
        content: Text(
          'Put back "${widget.entry.title}" and its history. '
          '${widget.entry.backend == 'codex' ? 'Codex' : 'Claude'} will resume with full prior context.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      context.read<ChatProvider>().restoreArchive(
        widget.entry.sid,
        widget.entry.ts,
        serverId: widget.entry.serverId.isNotEmpty
            ? widget.entry.serverId
            : null,
      );
      if (!mounted) return;
      Navigator.of(context).pop();
    }
  }

  Future<void> _confirmDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Archive'),
        content: Text(
          'Permanently delete "${widget.entry.title}" and its history. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      context.read<ChatProvider>().deleteArchive(
        widget.entry.sid,
        widget.entry.ts,
        serverId: widget.entry.serverId.isNotEmpty
            ? widget.entry.serverId
            : null,
      );
      if (!mounted) return;
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.entry.title.isNotEmpty
              ? widget.entry.title
              : 'Archived Session',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.restore),
            tooltip: 'Restore',
            onPressed: _confirmRestore,
          ),
          if (!widget.entry.isNativeCodexArchive)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Delete',
              onPressed: _confirmDelete,
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Container(
                  width: double.infinity,
                  color: theme.colorScheme.surfaceContainerHigh,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (widget.entry.cwd.isNotEmpty)
                        Text(
                          'cwd: ${widget.entry.cwd}',
                          style: const TextStyle(fontSize: 12),
                        ),
                      Text(
                        '${widget.entry.backend == 'codex' ? 'Codex' : 'Claude'}'
                        '${widget.entry.serverName.isNotEmpty ? ' · ${widget.entry.serverName}' : ''}'
                        ' · ${widget.entry.messageCount} messages · cleared ${_formatAbsolute(widget.entry.clearedAt)}',
                        style: TextStyle(
                          fontSize: 11,
                          color: theme.colorScheme.onSurface.withAlpha(140),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: _messages == null || _messages!.isEmpty
                      ? const Center(child: Text('No messages in this archive'))
                      : ListView.builder(
                          padding: const EdgeInsets.all(12),
                          itemCount: _messages!.length,
                          itemBuilder: (_, idx) {
                            return _ArchiveChatMessageTile(
                              message: _messages![idx],
                            );
                          },
                        ),
                ),
              ],
            ),
    );
  }
}

class _ArchiveChatMessageTile extends StatelessWidget {
  final ChatMessage message;
  const _ArchiveChatMessageTile({required this.message});

  @override
  Widget build(BuildContext context) {
    switch (message.type) {
      case MessageType.text:
        return MessageBubble(message: message);
      case MessageType.toolCall:
        if (message.toolName == 'Speak') return SpeakCard(message: message);
        if (message.toolName == 'SendFile') return FileCard(message: message);
        if (message.toolName == 'ScheduleReminder') {
          return ReminderCard(message: message);
        }
        return ToolOutputBlock(message: message);
      case MessageType.toolResult:
        return ToolOutputBlock(message: message);
      case MessageType.codexPlan:
        return CodexPlanCard(msg: message);
      case MessageType.codexCommand:
        return CodexCommandCard(message: message);
      default:
        if (message.textContent.trim().isEmpty) return const SizedBox.shrink();
        return MessageBubble(message: message);
    }
  }
}
