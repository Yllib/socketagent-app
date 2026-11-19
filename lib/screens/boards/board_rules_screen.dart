import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../config/app_palette.dart';
import '../../models/project_board.dart';
import '../../services/board_relay.dart';
import '../../services/board_store.dart';
import '../../widgets/light_backdrop.dart';
import 'board_style.dart';

/// The board's statuses, its rules text and its intake keys. Every chat in
/// the project follows the statuses and rules; agents can only propose
/// changes to them.
class BoardRulesScreen extends StatefulWidget {
  const BoardRulesScreen({super.key, required this.projectId});
  final String projectId;

  @override
  State<BoardRulesScreen> createState() => _BoardRulesScreenState();
}

class _BoardRulesScreenState extends State<BoardRulesScreen> {
  final _store = BoardStore.shared;
  late final _rules = TextEditingController(
    text: _store.board(widget.projectId)?.rules,
  );

  @override
  void dispose() {
    _rules.dispose();
    super.dispose();
  }

  void _setStatuses(List<BoardStatus> statuses) =>
      _store.setConfig(widget.projectId, statuses: statuses);

  Future<void> _edit(ProjectBoard board, BoardStatus? status) async {
    final result = await showDialog<BoardStatus>(
      context: context,
      builder: (_) => _StatusDialog(status: status),
    );
    if (result == null) return;
    final list = [...board.statuses];
    final at = list.indexWhere((s) => s.key == result.key);
    if (at < 0) {
      list.add(result);
    } else {
      list[at] = result;
    }
    _setStatuses(list);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Board settings'),
        actions: [
          IconButton(
            tooltip: 'Add status',
            icon: const Icon(Icons.add),
            onPressed: () {
              final board = _store.board(widget.projectId);
              if (board != null) _edit(board, null);
            },
          ),
        ],
      ),
      body: LightBackdrop(
        child: ListenableBuilder(
          listenable: _store,
          builder: (context, _) {
            final board = _store.board(widget.projectId);
            if (board == null) return const SizedBox.shrink();
            return CustomScrollView(
              slivers: [
                for (final proposal in board.openProposals)
                  SliverToBoxAdapter(
                    child: _ProposalBlock(
                      proposal: proposal,
                      board: board,
                      onDecide: (approve) {
                        _store.decideProposal(
                          widget.projectId,
                          proposal.id,
                          approve,
                        );
                        if (approve && proposal.rules != null) {
                          _rules.text = proposal.rules!;
                        }
                      },
                    ),
                  ),
                SliverReorderableList(
                  itemCount: board.statuses.length,
                  onReorderItem: (from, to) {
                    final list = [...board.statuses];
                    list.insert(to, list.removeAt(from));
                    _setStatuses(list);
                  },
                  itemBuilder: (context, i) {
                    final s = board.statuses[i];
                    final used = board.cards.any((c) => c.status == s.key);
                    return ReorderableDelayedDragStartListener(
                      key: ValueKey(s.key),
                      index: i,
                      child: Material(
                        type: MaterialType.transparency,
                        child: ListTile(
                          onTap: () => _edit(board, s),
                          leading: Icon(s.kind.icon, color: s.kind.color(p)),
                          title: Text(
                            s.name,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          subtitle: Text(
                            s.meaning.isEmpty ? s.kind.label : s.meaning,
                            style: TextStyle(color: p.textMuted),
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (!used && board.statuses.length > 1)
                                IconButton(
                                  tooltip: 'Delete status',
                                  icon: const Icon(Icons.close, size: 18),
                                  onPressed: () => _setStatuses(
                                    board.statuses
                                        .where((x) => x.key != s.key)
                                        .toList(),
                                  ),
                                ),
                              ReorderableDragStartListener(
                                index: i,
                                child: Icon(
                                  Icons.drag_indicator,
                                  color: p.textFaint,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
                  sliver: SliverList.list(
                    children: [
                      Text(
                        'Rules',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: p.text,
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _rules,
                        minLines: 6,
                        maxLines: null,
                        onChanged: (text) => _store.setConfig(
                          widget.projectId,
                          rules: text.trim(),
                        ),
                        decoration: InputDecoration(
                          hintText:
                              'When to make a card, when to move it, and what '
                              'a good card says. Every chat in this project '
                              'reads this.',
                          filled: true,
                          fillColor: p.panelLow,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: BorderSide(color: p.border),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: BorderSide(color: p.border),
                          ),
                        ),
                      ),
                      const SizedBox(height: 28),
                      _IntakeSection(projectId: widget.projectId, board: board),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// The board's intake keys: outside services such as the Feedback Hub use
/// one to add items that agents turn into cards. A new key's token shows
/// once.
class _IntakeSection extends StatefulWidget {
  const _IntakeSection({required this.projectId, required this.board});
  final String projectId;
  final ProjectBoard board;

  @override
  State<_IntakeSection> createState() => _IntakeSectionState();
}

class _IntakeSectionState extends State<_IntakeSection> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } on BoardRelayDown catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.reason)));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _add() async {
    final label = await showDialog<String>(
      context: context,
      builder: (_) => const _IntakeLabelDialog(),
    );
    if (label == null || !mounted) return;
    await _run(() async {
      final token = await BoardStore.shared.addIntake(widget.projectId, label);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => _IntakeTokenDialog(token: token),
      );
    });
  }

  Future<void> _revoke(BoardIntake intake) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Revoke ${intake.label}?'),
        content: const Text('Whatever uses this key stops adding cards.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const ValueKey('intake-revoke-confirm'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Revoke'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _run(
      () => BoardStore.shared.removeIntake(widget.projectId, intake.id),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Intake keys',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: p.text,
                ),
              ),
            ),
            TextButton.icon(
              key: const ValueKey('intake-add'),
              onPressed: _busy ? null : _add,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('New key'),
            ),
          ],
        ),
        Text(
          'Lets a service like the Feedback Hub add cards without reading the board.',
          style: TextStyle(color: p.textMuted, fontSize: 13),
        ),
        for (final intake in widget.board.intakes)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.vpn_key_outlined, color: p.textMuted),
            title: Text(intake.label.isEmpty ? 'Unnamed key' : intake.label),
            subtitle: Text(
              'Made ${MaterialLocalizations.of(context).formatMediumDate(intake.createdAt)}',
              style: TextStyle(color: p.textMuted),
            ),
            trailing: IconButton(
              key: ValueKey('intake-revoke-${intake.id}'),
              tooltip: 'Revoke',
              icon: const Icon(Icons.close, size: 18),
              onPressed: _busy ? null : () => _revoke(intake),
            ),
          ),
      ],
    );
  }
}

class _IntakeLabelDialog extends StatefulWidget {
  const _IntakeLabelDialog();

  @override
  State<_IntakeLabelDialog> createState() => _IntakeLabelDialogState();
}

class _IntakeLabelDialogState extends State<_IntakeLabelDialog> {
  final _label = TextEditingController(text: 'Feedback Hub');

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  void _done() {
    final label = _label.text.trim();
    if (label.isNotEmpty) Navigator.pop(context, label);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('New intake key'),
    content: TextField(
      key: const ValueKey('intake-label'),
      controller: _label,
      autofocus: true,
      decoration: const InputDecoration(labelText: 'What will use it'),
      onSubmitted: (_) => _done(),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      TextButton(
        key: const ValueKey('intake-create'),
        onPressed: _done,
        child: const Text('Create'),
      ),
    ],
  );
}

class _IntakeTokenDialog extends StatelessWidget {
  const _IntakeTokenDialog({required this.token});
  final String token;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return AlertDialog(
      title: const Text('Intake key'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Paste this into the service. It shows only now; if you lose it, '
            'revoke it and make another.',
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: p.panelLow,
              border: Border.all(color: p.border),
              borderRadius: BorderRadius.circular(6),
            ),
            child: SelectableText(
              token,
              key: const ValueKey('intake-token'),
              maxLines: 4,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Clipboard.setData(ClipboardData(text: token)),
          child: const Text('Copy'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Done'),
        ),
      ],
    );
  }
}

class _StatusDialog extends StatefulWidget {
  const _StatusDialog({this.status});
  final BoardStatus? status;

  @override
  State<_StatusDialog> createState() => _StatusDialogState();
}

class _StatusDialogState extends State<_StatusDialog> {
  late final _name = TextEditingController(text: widget.status?.name);
  late final _meaning = TextEditingController(text: widget.status?.meaning);
  late StatusKind _kind = widget.status?.kind ?? StatusKind.active;

  @override
  void dispose() {
    _name.dispose();
    _meaning.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return AlertDialog(
      title: Text(widget.status == null ? 'New status' : 'Edit status'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _name,
              autofocus: true,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _meaning,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'When a card belongs here',
              ),
            ),
            const SizedBox(height: 16),
            RadioGroup<StatusKind>(
              groupValue: _kind,
              onChanged: (k) => setState(() => _kind = k ?? _kind),
              child: Column(
                children: [
                  for (final kind in StatusKind.values)
                    RadioListTile<StatusKind>(
                      value: kind,
                      contentPadding: EdgeInsets.zero,
                      title: Row(
                        children: [
                          StatusDot(kind.color(p)),
                          const SizedBox(width: 10),
                          Text(kind.label),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _name.text.trim().isEmpty
              ? null
              : () {
                  final name = _name.text.trim();
                  final existing = widget.status;
                  Navigator.pop(
                    context,
                    existing?.copyWith(
                          name: name,
                          kind: _kind,
                          meaning: _meaning.text.trim(),
                        ) ??
                        BoardStatus(
                          key:
                              '${name.toLowerCase().replaceAll(RegExp('[^a-z0-9]+'), '_')}'
                              '_${DateTime.now().millisecondsSinceEpoch % 100000}',
                          name: name,
                          kind: _kind,
                          meaning: _meaning.text.trim(),
                        ),
                  );
                },
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// An agent's suggested statuses and rules, shown against the current
/// ones, with Approve and Decline.
class _ProposalBlock extends StatelessWidget {
  const _ProposalBlock({
    required this.proposal,
    required this.board,
    required this.onDecide,
  });

  final BoardProposal proposal;
  final ProjectBoard board;
  final void Function(bool approve) onDecide;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final statuses = proposal.statuses;
    final rules = proposal.rules;
    final label = TextStyle(
      fontSize: 12.5,
      fontWeight: FontWeight.w600,
      color: p.textMuted,
    );
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
      decoration: BoxDecoration(
        color: p.panel,
        borderRadius: BorderRadius.circular(10),
        border: Border(left: BorderSide(color: p.mauve, width: 3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '${proposal.by.isEmpty ? 'An agent' : proposal.by} suggests',
            style: TextStyle(
              fontSize: 14.5,
              fontWeight: FontWeight.w600,
              color: p.text,
            ),
          ),
          if (proposal.why.isNotEmpty) ...[
            const SizedBox(height: 4),
            SelectableText(
              proposal.why,
              style: TextStyle(
                fontSize: 13.5,
                height: 1.45,
                color: p.textSecondary,
              ),
            ),
          ],
          if (statuses != null) ...[
            const SizedBox(height: 10),
            Text('Statuses', style: label),
            const SizedBox(height: 4),
            for (final s in statuses)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Icon(
                        s.kind.icon,
                        size: 15,
                        color: s.kind.color(p),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: s.name,
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                color: board.status(s.key) == null
                                    ? p.green
                                    : p.text,
                              ),
                            ),
                            if (s.meaning.isNotEmpty)
                              TextSpan(
                                text: '  ${s.meaning}',
                                style: TextStyle(color: p.textMuted),
                              ),
                          ],
                        ),
                        style: const TextStyle(fontSize: 13.5, height: 1.4),
                      ),
                    ),
                  ],
                ),
              ),
            for (final s in board.statuses)
              if (!statuses.any((x) => x.key == s.key))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(
                    'Removes ${s.name}',
                    style: TextStyle(fontSize: 13.5, color: p.red),
                  ),
                ),
          ],
          if (rules != null && rules != board.rules) ...[
            const SizedBox(height: 10),
            Text('Rules', style: label),
            const SizedBox(height: 4),
            SelectableText(
              rules,
              style: TextStyle(fontSize: 13.5, height: 1.45, color: p.text),
            ),
          ],
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => onDecide(false),
                style: TextButton.styleFrom(foregroundColor: p.textSecondary),
                child: const Text('Decline'),
              ),
              const SizedBox(width: 4),
              FilledButton(
                key: Key('proposal-approve-${proposal.id}'),
                onPressed: () => onDecide(true),
                child: const Text('Approve'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
