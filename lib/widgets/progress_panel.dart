import 'package:flutter/material.dart';

class ProgressPanelEntry {
  const ProgressPanelEntry({
    required this.text,
    required this.status,
    this.onDismiss,
    this.dismissKey,
    this.strikeCompleted = false,
    this.itemLabel = 'task',
    this.confirmDismiss = true,
    this.replacement,
  });
  final String text;
  final String status;
  final VoidCallback? onDismiss;
  final Key? dismissKey;
  final bool strikeCompleted;
  final String itemLabel;
  final bool confirmDismiss;
  final Widget? replacement;
}

/// Shared geometry and typography for task lists and agent plans.
class ProgressPanel extends StatefulWidget {
  const ProgressPanel({
    super.key,
    required this.label,
    required this.icon,
    required this.accent,
    required this.entries,
    this.explanation = '',
    this.onDismiss,
    this.dismissTooltip,
    this.hidingNotice,
    this.completedCount,
    this.totalCount,
  });
  final String label;
  final IconData icon;
  final Color accent;
  final List<ProgressPanelEntry> entries;
  final String explanation;
  final VoidCallback? onDismiss;
  final String? dismissTooltip;
  final Widget? hidingNotice;
  final int? completedCount;
  final int? totalCount;

  @override
  State<ProgressPanel> createState() => _ProgressPanelState();
}

class _ProgressPanelState extends State<ProgressPanel> {
  bool _expanded = false;
  final _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.hidingNotice != null) return widget.hidingNotice!;
    final completed =
        widget.completedCount ??
        widget.entries.where((e) => e.status == 'completed').length;
    final total = widget.totalCount ?? widget.entries.length;
    final active = widget.entries
        .where((e) => e.status == 'in_progress' || e.status == 'inProgress')
        .firstOrNull;
    final radius = BorderRadius.circular(_expanded ? 12 : 8);
    final progress = total == 0 ? 0.0 : completed / total;
    return Container(
      margin: EdgeInsets.symmetric(horizontal: 8, vertical: _expanded ? 4 : 2),
      child: Material(
        color: const Color(0xFF1E1E2E),
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(color: widget.accent.withAlpha(65)),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Tooltip(
              message:
                  '${_expanded ? 'Collapse' : 'Expand'} ${widget.label.toLowerCase()}',
              child: InkWell(
                onTap: () => setState(() => _expanded = !_expanded),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
                  child: Row(
                    children: [
                      Icon(widget.icon, size: 16, color: widget.accent),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(
                                text: widget.label,
                                style: TextStyle(
                                  color: widget.accent,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              TextSpan(text: '  $completed/$total'),
                              if (!_expanded && active != null)
                                TextSpan(text: '  ·  ${active.text}'),
                            ],
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 11,
                            height: 1.4,
                            color: Color(0xFFA6ADC8),
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 24,
                        height: 24,
                        child: Icon(
                          _expanded ? Icons.expand_less : Icons.expand_more,
                          size: 18,
                          color: const Color(0xFF6C7086),
                        ),
                      ),
                      if (widget.onDismiss != null)
                        IconButton(
                          tooltip:
                              widget.dismissTooltip ??
                              'Hide ${widget.label.toLowerCase()}',
                          onPressed: widget.onDismiss,
                          padding: EdgeInsets.zero,
                          style: IconButton.styleFrom(
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            minimumSize: const Size(24, 24),
                            maximumSize: const Size(24, 24),
                          ),
                          constraints: const BoxConstraints.tightFor(
                            width: 24,
                            height: 24,
                          ),
                          icon: const Icon(
                            Icons.visibility_off_outlined,
                            size: 16,
                            color: Color(0xFF6C7086),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            if (_expanded) ...[
              if (total > 0)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: progress,
                      minHeight: 3,
                      backgroundColor: const Color(0xFF313244),
                      color: widget.accent,
                    ),
                  ),
                ),
              const SizedBox(height: 6),
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: (MediaQuery.sizeOf(context).height * .34).clamp(
                    120.0,
                    320.0,
                  ),
                ),
                child: Scrollbar(
                  controller: _scrollController,
                  thumbVisibility: widget.entries.length > 6,
                  child: ListView(
                    controller: _scrollController,
                    primary: false,
                    shrinkWrap: true,
                    padding: EdgeInsets.zero,
                    children: [
                      if (widget.explanation.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                          child: Text(
                            widget.explanation,
                            style: const TextStyle(
                              fontSize: 12,
                              height: 1.4,
                              color: Color(0xFFA6ADC8),
                            ),
                          ),
                        ),
                      for (final (index, entry) in widget.entries.indexed)
                        ProgressPanelRow(
                          key: ValueKey((index, entry.dismissKey, entry.text)),
                          entry: entry,
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 6),
            ],
          ],
        ),
      ),
    );
  }
}

class ProgressPanelRow extends StatefulWidget {
  const ProgressPanelRow({super.key, required this.entry});
  final ProgressPanelEntry entry;

  @override
  State<ProgressPanelRow> createState() => _ProgressPanelRowState();
}

class _ProgressPanelRowState extends State<ProgressPanelRow> {
  bool _confirming = false;
  ProgressPanelEntry get entry => widget.entry;

  Future<void> _confirmDismiss() async {
    if (_confirming || entry.onDismiss == null) return;
    _confirming = true;
    final targetKey = entry.dismissKey;
    final targetText = entry.text;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Dismiss completed ${entry.itemLabel}?'),
        content: SingleChildScrollView(
          child: Text(
            'Dismiss "$targetText" from this list? Its history and completed work are kept.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Dismiss'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    _confirming = false;
    if (confirmed == true &&
        entry.status == 'completed' &&
        entry.dismissKey == targetKey &&
        entry.text == targetText) {
      entry.onDismiss?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (entry.replacement != null) return entry.replacement!;
    final completed = entry.status == 'completed';
    final active =
        entry.status == 'in_progress' || entry.status == 'inProgress';
    final icon = completed
        ? Icons.check_circle
        : active
        ? Icons.play_circle_fill
        : Icons.radio_button_unchecked;
    final color = completed
        ? const Color(0xFFA6E3A1)
        : active
        ? const Color(0xFFF9E2AF)
        : const Color(0xFF6C7086);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 24),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(icon, size: 16, color: color),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                entry.text,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.4,
                  color: completed
                      ? const Color(0xFFA6ADC8)
                      : const Color(0xFFCDD6F4),
                  fontWeight: active ? FontWeight.w600 : FontWeight.normal,
                  decoration: completed && entry.strikeCompleted
                      ? TextDecoration.lineThrough
                      : null,
                ),
              ),
            ),
            SizedBox(
              width: 24,
              height: 24,
              child: entry.onDismiss == null
                  ? null
                  : IconButton(
                      key: entry.dismissKey,
                      tooltip: 'Dismiss completed ${entry.itemLabel}',
                      onPressed: entry.confirmDismiss
                          ? _confirmDismiss
                          : entry.onDismiss,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints.tightFor(
                        width: 24,
                        height: 24,
                      ),
                      icon: const Icon(
                        Icons.close,
                        size: 14,
                        color: Color(0xFF6C7086),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
