import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/session_memory.dart';
import '../services/chat_provider.dart';

class SessionMemoryScreen extends StatefulWidget {
  const SessionMemoryScreen({super.key});

  @override
  State<SessionMemoryScreen> createState() => _SessionMemoryScreenState();
}

class _SessionMemoryScreenState extends State<SessionMemoryScreen> {
  @override
  void initState() {
    super.initState();
    unawaited(
      Future.microtask(() => context.read<ChatProvider>().refreshSessionMemory()),
    );
  }

  String _count(int value) {
    if (value >= 1000000) return '${(value / 1000000).toStringAsFixed(1)}m';
    if (value >= 1000) return '${(value / 1000).round()}k';
    return '$value';
  }

  String _time(DateTime value) {
    final local = value.toLocal();
    final now = DateTime.now();
    final sameDay = local.year == now.year &&
        local.month == now.month &&
        local.day == now.day;
    final minute = local.minute.toString().padLeft(2, '0');
    if (sameDay) return '${local.hour}:$minute';
    return '${local.month}/${local.day}/${local.year} ${local.hour}:$minute';
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<ChatProvider>();
    final state = provider.activeSessionMemory;
    final loading = provider.activeSessionMemoryLoading;
    final error = provider.activeSessionMemoryError;
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Session memory'),
          actions: [
            IconButton(
              tooltip: 'Refresh',
              onPressed: loading
                  ? null
                  : () => unawaited(provider.refreshSessionMemory()),
              icon: loading
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
            ),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Memory'),
              Tab(text: 'Thread history'),
              Tab(text: 'Settings'),
            ],
          ),
        ),
        body: state == null
            ? _InitialState(loading: loading, error: error)
            : TabBarView(
                children: [
                  _memoryTab(context, provider, state, error),
                  _threadHistoryTab(context, state),
                  _settingsTab(context, provider, state),
                ],
              ),
      ),
    );
  }

  Widget _memoryTab(
    BuildContext context,
    ChatProvider provider,
    SessionMemoryState state,
    String? error,
  ) {
    final theme = Theme.of(context);
    final active = state.entries.where((entry) => entry.active).toList()
      ..sort((left, right) {
        if (left.pinned != right.pinned) return left.pinned ? -1 : 1;
        return right.updatedAt.compareTo(left.updatedAt);
      });
    final grouped = <SessionMemoryKind, List<SessionMemoryEntry>>{};
    for (final entry in active) {
      grouped.putIfAbsent(entry.kind, () => []).add(entry);
    }
    final percent = state.contextWindow <= 0
        ? 0.0
        : (state.currentTokens / state.contextWindow).clamp(0.0, 1.0);
    final currentEpoch = state.epochs.isEmpty ? null : state.epochs.last;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 32),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Working context',
                style: theme.textTheme.titleSmall,
              ),
            ),
            Text(
              '${_count(state.currentTokens)} / ${_count(state.contextWindow)}',
              style: theme.textTheme.labelMedium,
            ),
          ],
        ),
        const SizedBox(height: 8),
        LinearProgressIndicator(value: percent),
        const SizedBox(height: 8),
        Text(
          'Epoch ${currentEpoch?.number ?? 1} · '
          '${state.compactionsSinceRollover} of '
          '${state.settings.maxCompactions} compactions',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        if (state.rolloverPending) ...[
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              border: Border.all(color: theme.colorScheme.tertiary),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.change_circle_outlined,
                  size: 20,
                  color: theme.colorScheme.tertiary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'The next user prompt will start a fresh Codex thread. '
                    '${state.rolloverReason ?? ''}',
                  ),
                ),
              ],
            ),
          ),
        ],
        if (error != null) ...[
          const SizedBox(height: 12),
          Text(error, style: TextStyle(color: theme.colorScheme.error)),
        ],
        const SizedBox(height: 22),
        if (active.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 34),
            child: Column(
              children: [
                Icon(
                  Icons.memory_outlined,
                  size: 34,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(height: 12),
                const Text('No durable memories saved'),
                const SizedBox(height: 5),
                Text(
                  'Recent runs still carry forward automatically.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          )
        else
          for (final kind in SessionMemoryKind.values)
            if (grouped[kind]?.isNotEmpty == true) ...[
              _SectionHeader(label: kind.label),
              for (final entry in grouped[kind]!)
                _MemoryRow(
                  entry: entry,
                  time: _time(entry.updatedAt),
                  onEdit: () => _editEntry(context, provider, entry),
                  onTogglePin: () => unawaited(
                    provider.upsertSessionMemory(
                      entryId: entry.id,
                      kind: entry.kind,
                      text: entry.text,
                      pinned: !entry.pinned,
                      status: entry.status,
                      sourceSessionSeq: entry.sourceSessionSeq,
                      sourceEntryId: entry.sourceEntryId,
                    ),
                  ),
                  onSupersede: () => unawaited(
                    provider.upsertSessionMemory(
                      entryId: entry.id,
                      kind: entry.kind,
                      text: entry.text,
                      pinned: entry.pinned,
                      status: 'superseded',
                      sourceSessionSeq: entry.sourceSessionSeq,
                      sourceEntryId: entry.sourceEntryId,
                    ),
                  ),
                  onDelete: () => _deleteEntry(context, provider, entry),
                ),
              const SizedBox(height: 14),
            ],
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: () => _editEntry(context, provider, null),
          icon: const Icon(Icons.add),
          label: const Text('Add memory'),
        ),
      ],
    );
  }

  Widget _threadHistoryTab(
    BuildContext context,
    SessionMemoryState state,
  ) {
    final theme = Theme.of(context);
    final epochs = state.epochs.reversed.toList(growable: false);
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 32),
      itemCount: epochs.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final epoch = epochs[index];
        final active = epoch.endedAt == null;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    active ? Icons.radio_button_checked : Icons.circle_outlined,
                    size: 17,
                    color: active
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      'Epoch ${epoch.number}${active ? ' · active' : ''}',
                      style: theme.textTheme.titleSmall,
                    ),
                  ),
                  Text(
                    '${epoch.compactions} compactions',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              SelectableText(
                epoch.nativeSessionId,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                epoch.endedAt == null
                    ? 'Started ${_time(epoch.startedAt)}'
                    : '${_time(epoch.startedAt)} to ${_time(epoch.endedAt!)}',
                style: theme.textTheme.bodySmall,
              ),
              if (epoch.endingTokens != null)
                Text(
                  'Ended at ${_count(epoch.endingTokens!)} context tokens',
                  style: theme.textTheme.bodySmall,
                ),
              if (epoch.rolloverReason?.isNotEmpty == true) ...[
                const SizedBox(height: 5),
                Text(epoch.rolloverReason!),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _settingsTab(
    BuildContext context,
    ChatProvider provider,
    SessionMemoryState state,
  ) {
    final settings = state.settings;
    return ListView(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 32),
      children: [
        SwitchListTile(
          title: const Text('Automatic rollover'),
          subtitle: const Text(
            'Start a fresh Codex thread when the current one becomes expensive.',
          ),
          value: settings.autoRollover,
          onChanged: (value) => unawaited(
            provider.updateSessionMemorySettings(autoRollover: value),
          ),
        ),
        const Divider(height: 1),
        ListTile(
          title: const Text('Compactions per thread'),
          subtitle: const Text('Rollover happens before the next user prompt.'),
          trailing: Text('${settings.maxCompactions}'),
          onTap: () => _chooseNumber(
            context,
            title: 'Compactions per thread',
            values: List.generate(10, (index) => index + 1),
            selected: settings.maxCompactions,
            onSelected: (value) => provider.updateSessionMemorySettings(
              maxCompactions: value,
            ),
          ),
        ),
        const Divider(height: 1),
        ListTile(
          title: const Text('Post-compaction token limit'),
          subtitle: const Text(
            'Rollover if context stays this large immediately after compaction.',
          ),
          trailing: Text(_count(settings.maxPostCompactionTokens)),
          onTap: () => _chooseNumber(
            context,
            title: 'Post-compaction token limit',
            values: const [50000, 70000, 90000, 110000, 130000, 160000],
            selected: settings.maxPostCompactionTokens,
            label: _count,
            onSelected: (value) => provider.updateSessionMemorySettings(
              maxPostCompactionTokens: value,
            ),
          ),
        ),
        const Divider(height: 1),
        ListTile(
          title: const Text('Recent runs carried forward'),
          subtitle: const Text('Older history stays searchable with Remember.'),
          trailing: Text('${settings.recentRuns}'),
          onTap: () => _chooseNumber(
            context,
            title: 'Recent runs carried forward',
            values: List.generate(6, (index) => index + 1),
            selected: settings.recentRuns,
            onSelected: (value) => provider.updateSessionMemorySettings(
              recentRuns: value,
            ),
          ),
        ),
        const SizedBox(height: 24),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: OutlinedButton.icon(
            onPressed: state.rolloverPending
                ? null
                : () => _requestRollover(context, provider),
            icon: const Icon(Icons.change_circle_outlined),
            label: Text(
              state.rolloverPending
                  ? 'Rollover queued'
                  : 'Roll over before next prompt',
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _editEntry(
    BuildContext context,
    ChatProvider provider,
    SessionMemoryEntry? entry,
  ) async {
    var kind = entry?.kind ?? SessionMemoryKind.decision;
    var pinned = entry?.pinned ?? false;
    final controller = TextEditingController(text: entry?.text ?? '');
    final result = await showDialog<({SessionMemoryKind kind, String text, bool pinned})>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(entry == null ? 'Add memory' : 'Edit memory'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<SessionMemoryKind>(
                  initialValue: kind,
                  decoration: const InputDecoration(labelText: 'Type'),
                  items: [
                    for (final value in SessionMemoryKind.values)
                      DropdownMenuItem(value: value, child: Text(value.label)),
                  ],
                  onChanged: (value) {
                    if (value != null) setDialogState(() => kind = value);
                  },
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: controller,
                  autofocus: entry == null,
                  minLines: 4,
                  maxLines: 10,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                    labelText: 'Memory',
                    alignLabelWithHint: true,
                    border: OutlineInputBorder(),
                  ),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Pin permanently'),
                  value: pinned,
                  onChanged: (value) => setDialogState(() => pinned = value),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final text = controller.text.trim();
                if (text.isEmpty) return;
                Navigator.pop(dialogContext, (kind: kind, text: text, pinned: pinned));
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    if (result == null || !mounted) return;
    await provider.upsertSessionMemory(
      entryId: entry?.id,
      kind: result.kind,
      text: result.text,
      pinned: result.pinned,
      status: entry?.status ?? 'active',
      sourceSessionSeq: entry?.sourceSessionSeq,
      sourceEntryId: entry?.sourceEntryId,
    );
  }

  Future<void> _deleteEntry(
    BuildContext context,
    ChatProvider provider,
    SessionMemoryEntry entry,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this memory?'),
        content: const Text('The source transcript entry will not be deleted.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) await provider.deleteSessionMemory(entry.id);
  }

  Future<void> _requestRollover(
    BuildContext context,
    ChatProvider provider,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Roll over this Codex thread?'),
        content: const Text(
          'The next prompt will start a fresh native thread with durable memory '
          'and recent runs. The visible session history stays intact.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Queue rollover'),
          ),
        ],
      ),
    );
    if (confirmed == true) await provider.requestSessionMemoryRollover();
  }

  Future<void> _chooseNumber(
    BuildContext context, {
    required String title,
    required List<int> values,
    required int selected,
    required Future<SessionMemoryState> Function(int value) onSelected,
    String Function(int value)? label,
  }) async {
    final value = await showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(title),
        children: [
          for (final value in values)
            RadioListTile<int>(
              value: value,
              groupValue: selected,
              title: Text(label?.call(value) ?? '$value'),
              onChanged: (choice) => Navigator.pop(context, choice),
            ),
        ],
      ),
    );
    if (value != null) await onSelected(value);
  }
}

class _InitialState extends StatelessWidget {
  const _InitialState({required this.loading, required this.error});

  final bool loading;
  final String? error;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: loading
            ? const CircularProgressIndicator()
            : Text(
                error ?? 'Session memory is unavailable.',
                textAlign: TextAlign.center,
              ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Text(
        label.toUpperCase(),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}

class _MemoryRow extends StatelessWidget {
  const _MemoryRow({
    required this.entry,
    required this.time,
    required this.onEdit,
    required this.onTogglePin,
    required this.onSupersede,
    required this.onDelete,
  });

  final SessionMemoryEntry entry;
  final String time;
  final VoidCallback onEdit;
  final VoidCallback onTogglePin;
  final VoidCallback onSupersede;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onEdit,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 11),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: Color(0xFF242424))),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              entry.pinned ? Icons.star : Icons.star_border,
              size: 18,
              color: entry.pinned
                  ? theme.colorScheme.tertiary
                  : theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(entry.text),
                  const SizedBox(height: 5),
                  Text(
                    [
                      if (entry.sourceSessionSeq != null)
                        'Source #${entry.sourceSessionSeq}',
                      'Updated $time',
                    ].join(' · '),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            PopupMenuButton<String>(
              onSelected: (value) {
                switch (value) {
                  case 'edit':
                    onEdit();
                    break;
                  case 'pin':
                    onTogglePin();
                    break;
                  case 'supersede':
                    onSupersede();
                    break;
                  case 'delete':
                    onDelete();
                    break;
                }
              },
              itemBuilder: (context) => [
                const PopupMenuItem(value: 'edit', child: Text('Edit')),
                PopupMenuItem(
                  value: 'pin',
                  child: Text(entry.pinned ? 'Unpin' : 'Pin'),
                ),
                const PopupMenuItem(
                  value: 'supersede',
                  child: Text('Mark superseded'),
                ),
                const PopupMenuDivider(),
                const PopupMenuItem(value: 'delete', child: Text('Delete')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
