import 'dart:async';

import 'package:flutter/material.dart';

import '../models/codex_goal.dart';
import '../services/chat_provider.dart';

Future<void> showCodexGoalManagerSheet(
  BuildContext context,
  ChatProvider provider,
) {
  return showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    backgroundColor: Colors.black,
    builder: (_) => CodexGoalManagerSheet(provider: provider),
  );
}

class CodexGoalManagerSheet extends StatefulWidget {
  const CodexGoalManagerSheet({super.key, required this.provider});

  final ChatProvider provider;

  @override
  State<CodexGoalManagerSheet> createState() =>
      _CodexGoalManagerSheetState();
}

class _CodexGoalManagerSheetState extends State<CodexGoalManagerSheet> {
  final _objectiveController = TextEditingController();
  final _budgetController = TextEditingController();
  bool _editing = false;
  bool _busy = false;
  String? _localError;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  @override
  void dispose() {
    _objectiveController.dispose();
    _budgetController.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    setState(() => _localError = null);
    try {
      final goal = await widget.provider.refreshCodexGoal();
      if (!mounted) return;
      _populateEditors(goal);
    } catch (error) {
      if (mounted) setState(() => _localError = _errorText(error));
    }
  }

  void _populateEditors(CodexGoal? goal) {
    _objectiveController.text = goal?.objective ?? '';
    _budgetController.text = goal?.tokenBudget?.toString() ?? '';
  }

  int? _readBudget() {
    final text = _budgetController.text.trim();
    if (text.isEmpty) return null;
    final value = int.tryParse(text);
    if (value == null || value <= 0) {
      throw const FormatException('Token budget must be a positive whole number');
    }
    return value;
  }

  Future<void> _save({required bool starting}) async {
    final objective = _objectiveController.text.trim();
    if (objective.isEmpty) {
      setState(() => _localError = 'Enter a goal objective.');
      return;
    }
    int? budget;
    try {
      budget = _readBudget();
    } catch (error) {
      setState(() => _localError = _errorText(error));
      return;
    }
    setState(() {
      _busy = true;
      _localError = null;
    });
    try {
      final goal = await widget.provider.updateCodexGoal(
        objective: objective,
        status: starting ? CodexGoalStatus.active : null,
        tokenBudget: budget,
        includeTokenBudget: true,
      );
      if (!mounted) return;
      _populateEditors(goal);
      setState(() => _editing = false);
    } catch (error) {
      if (mounted) setState(() => _localError = _errorText(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setStatus(CodexGoalStatus status) async {
    setState(() {
      _busy = true;
      _localError = null;
    });
    try {
      await widget.provider.updateCodexGoal(status: status);
    } catch (error) {
      if (mounted) setState(() => _localError = _errorText(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear this goal?'),
        content: const Text(
          'The goal and its progress will be removed from this Codex session.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear goal'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _busy = true;
      _localError = null;
    });
    try {
      await widget.provider.clearCodexGoal();
      if (!mounted) return;
      _populateEditors(null);
      setState(() => _editing = false);
    } catch (error) {
      if (mounted) setState(() => _localError = _errorText(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.provider,
      builder: (context, _) {
        final goal = widget.provider.activeCodexGoal;
        final loading = widget.provider.activeCodexGoalLoading;
        final error = _localError ?? widget.provider.activeCodexGoalError;
        return FractionallySizedBox(
          heightFactor: 0.82,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 8, 10),
                child: Row(
                  children: [
                    const Icon(Icons.flag_outlined),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Text(
                        'Codex goal',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
                  children: [
                    if (loading && !widget.provider.activeCodexGoalLoaded)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 24),
                        child: Row(
                          children: [
                            Icon(Icons.hourglass_top, size: 18),
                            SizedBox(width: 10),
                            Text('Loading goal…'),
                          ],
                        ),
                      )
                    else if (goal == null)
                      _buildEditor(starting: true)
                    else if (_editing)
                      _buildEditor(starting: false)
                    else
                      _buildGoal(goal),
                    if (error != null && error.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      Text(
                        error,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          onPressed: _busy ? null : _refresh,
                          icon: const Icon(Icons.refresh, size: 18),
                          label: const Text('Retry'),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildEditor({required bool starting}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          starting ? 'Start a durable goal' : 'Edit goal',
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 6),
        Text(
          starting
              ? 'Codex will keep returning to this objective until it is stopped, blocked, or completed.'
              : 'Editing keeps the current goal status and accumulated usage.',
          style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 18),
        TextField(
          controller: _objectiveController,
          enabled: !_busy,
          minLines: 3,
          maxLines: 7,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            labelText: 'Objective',
            alignLabelWithHint: true,
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _budgetController,
          enabled: !_busy,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Token budget (optional)',
            hintText: 'No limit',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 18),
        Row(
          children: [
            if (!starting) ...[
              Expanded(
                child: OutlinedButton(
                  onPressed: _busy
                      ? null
                      : () {
                          _populateEditors(widget.provider.activeCodexGoal);
                          setState(() => _editing = false);
                        },
                  child: const Text('Cancel'),
                ),
              ),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: FilledButton(
                onPressed: _busy ? null : () => _save(starting: starting),
                child: Text(
                  _busy ? 'Saving…' : starting ? 'Start goal' : 'Save',
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildGoal(CodexGoal goal) {
    final statusColor = switch (goal.status) {
      CodexGoalStatus.active => Colors.greenAccent,
      CodexGoalStatus.paused => Colors.amberAccent,
      CodexGoalStatus.complete => Colors.lightBlueAccent,
      _ => Colors.orangeAccent,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(
              _statusLabel(goal.status),
              style: TextStyle(
                color: statusColor,
                fontWeight: FontWeight.w600,
              ),
            ),
            const Spacer(),
            IconButton(
              tooltip: 'Refresh',
              onPressed: _busy ? null : _refresh,
              icon: const Icon(Icons.refresh, size: 20),
            ),
            IconButton(
              tooltip: 'Edit',
              onPressed: _busy
                  ? null
                  : () {
                      _populateEditors(goal);
                      setState(() => _editing = true);
                    },
              icon: const Icon(Icons.edit_outlined, size: 20),
            ),
          ],
        ),
        const SizedBox(height: 10),
        SelectableText(
          goal.objective,
          style: const TextStyle(fontSize: 17, height: 1.4),
        ),
        const SizedBox(height: 22),
        Wrap(
          spacing: 24,
          runSpacing: 12,
          children: [
            _stat('Tokens used', _formatNumber(goal.tokensUsed)),
            _stat('Time used', _formatDuration(goal.timeUsedSeconds)),
            _stat(
              'Token budget',
              goal.tokenBudget == null ? 'No limit' : _formatNumber(goal.tokenBudget!),
            ),
          ],
        ),
        const SizedBox(height: 26),
        if (goal.automaticallyContinues) ...[
          FilledButton.icon(
            onPressed: _busy ? null : () => _setStatus(CodexGoalStatus.paused),
            icon: const Icon(Icons.stop_circle_outlined),
            label: Text(_busy ? 'Stopping…' : 'Stop goal'),
          ),
          const SizedBox(height: 8),
          Text(
            'Stops automatic continuation but keeps the goal so it can be resumed.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ] else ...[
          FilledButton.icon(
            onPressed: _busy ? null : () => _setStatus(CodexGoalStatus.active),
            icon: const Icon(Icons.play_arrow),
            label: Text(_busy ? 'Resuming…' : 'Resume goal'),
          ),
        ],
        const SizedBox(height: 18),
        OutlinedButton.icon(
          onPressed: _busy ? null : _clear,
          icon: const Icon(Icons.delete_outline),
          label: const Text('Clear goal'),
          style: OutlinedButton.styleFrom(
            foregroundColor: Theme.of(context).colorScheme.error,
          ),
        ),
      ],
    );
  }

  Widget _stat(String label, String value) {
    return SizedBox(
      width: 112,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 2),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

String _statusLabel(CodexGoalStatus status) => switch (status) {
  CodexGoalStatus.active => 'Active · auto-continuing',
  CodexGoalStatus.paused => 'Stopped',
  CodexGoalStatus.blocked => 'Blocked',
  CodexGoalStatus.usageLimited => 'Usage limited',
  CodexGoalStatus.budgetLimited => 'Budget reached',
  CodexGoalStatus.complete => 'Complete',
};

String _formatNumber(int value) {
  final digits = value.toString();
  final output = StringBuffer();
  for (var index = 0; index < digits.length; index++) {
    if (index > 0 && (digits.length - index) % 3 == 0) output.write(',');
    output.write(digits[index]);
  }
  return output.toString();
}

String _formatDuration(int totalSeconds) {
  final duration = Duration(seconds: totalSeconds);
  if (duration.inHours > 0) {
    final minutes = duration.inMinutes.remainder(60);
    return '${duration.inHours}h ${minutes}m';
  }
  if (duration.inMinutes > 0) {
    return '${duration.inMinutes}m ${duration.inSeconds.remainder(60)}s';
  }
  return '${duration.inSeconds}s';
}

String _errorText(Object error) {
  final text = error.toString();
  return text
      .replaceFirst('Bad state: ', '')
      .replaceFirst('FormatException: ', '')
      .replaceFirst('TimeoutException: ', '');
}
