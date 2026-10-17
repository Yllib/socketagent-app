import 'package:flutter/material.dart';
import '../config/app_palette.dart';
import 'dismiss_countdown.dart';

class ProgressPanelEntry {
  const ProgressPanelEntry({
    required this.text,
    required this.status,
    this.dismissId,
    this.strikeCompleted = false,
    this.itemLabel = 'task',
  });
  final String text;
  final String status;

  /// Set on completed entries the user may dismiss. Passed back through
  /// [ProgressPanel.onDismissItems].
  final String? dismissId;
  final bool strikeCompleted;
  final String itemLabel;

  Key get dismissButtonKey =>
      ValueKey('dismiss-${itemLabel.replaceAll(' ', '-')}-$dismissId');
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
    this.onDismissItems,
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

  /// Hides the whole panel.
  final VoidCallback? onDismiss;

  /// Removes entries by [ProgressPanelEntry.dismissId], after a countdown the
  /// user can cancel.
  final void Function(List<String> ids)? onDismissItems;
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
  late final _countdown = DismissCountdown<String>(
    onChanged: () {
      if (mounted) setState(() {});
    },
    onExpire: _expire,
  );

  /// Dismisses what is still completed when the countdown ends; a task the
  /// agent reopened meanwhile stays.
  void _expire(List<String> ids) {
    final still = _dismissibleIds.toSet();
    final valid = ids.where(still.contains).toList();
    if (mounted && valid.isNotEmpty) widget.onDismissItems?.call(valid);
  }

  Iterable<String> get _dismissibleIds => widget.onDismissItems == null
      ? const []
      : widget.entries
            .where((e) => e.dismissId != null && e.status == 'completed')
            .map((e) => e.dismissId!);

  @override
  void dispose() {
    _countdown.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Widget _headerButton(String label, Key key, VoidCallback onPressed) =>
      TextButton(
        key: key,
        onPressed: onPressed,
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          minimumSize: const Size(0, 24),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: VisualDensity.compact,
        ),
        child: Text(label, style: const TextStyle(fontSize: 11)),
      );

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
    final clearable = _dismissibleIds
        .where((id) => _countdown.remaining(id) == null)
        .toList();
    final dismissing = _dismissibleIds
        .where((id) => _countdown.remaining(id) != null)
        .length;
    final radius = BorderRadius.circular(_expanded ? 12 : 8);
    final progress = total == 0 ? 0.0 : completed / total;
    return Container(
      margin: EdgeInsets.symmetric(horizontal: 8, vertical: _expanded ? 4 : 2),
      child: Material(
        color: context.palette.panel,
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
                          style: TextStyle(
                            fontSize: 11,
                            height: 1.4,
                            color: context.palette.textSecondary,
                          ),
                        ),
                      ),
                      if (dismissing > 1)
                        _headerButton(
                          'Cancel all',
                          const ValueKey('cancel-dismiss-all'),
                          _countdown.cancelAll,
                        )
                      else if (clearable.length > 1)
                        _headerButton(
                          'Clear ${clearable.length} done',
                          const ValueKey('clear-done'),
                          () {
                            setState(() => _expanded = true);
                            _countdown.start(clearable);
                          },
                        ),
                      SizedBox(
                        width: 24,
                        height: 24,
                        child: Icon(
                          _expanded ? Icons.expand_less : Icons.expand_more,
                          size: 18,
                          color: context.palette.textMuted,
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
                          icon: Icon(
                            Icons.visibility_off_outlined,
                            size: 16,
                            color: context.palette.textMuted,
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
                      backgroundColor: context.palette.border,
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
                            style: TextStyle(
                              fontSize: 12,
                              height: 1.4,
                              color: context.palette.textSecondary,
                            ),
                          ),
                        ),
                      for (final (index, entry) in widget.entries.indexed)
                        ProgressPanelRow(
                          key: ValueKey((index, entry.dismissId, entry.text)),
                          entry: entry,
                          remaining: entry.dismissId == null
                              ? null
                              : _countdown.remaining(entry.dismissId!),
                          onDismiss:
                              entry.dismissId != null &&
                                  entry.status == 'completed' &&
                                  widget.onDismissItems != null
                              ? () => _countdown.start([entry.dismissId!])
                              : null,
                          onCancel: () => _countdown.cancel([entry.dismissId!]),
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

/// One entry. While [remaining] is set the row counts down to dismissal.
class ProgressPanelRow extends StatelessWidget {
  const ProgressPanelRow({
    super.key,
    required this.entry,
    this.remaining,
    this.onDismiss,
    this.onCancel,
  });
  final ProgressPanelEntry entry;
  final int? remaining;
  final VoidCallback? onDismiss;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final completed = entry.status == 'completed';
    final active =
        entry.status == 'in_progress' || entry.status == 'inProgress';
    final icon = completed
        ? Icons.check_circle
        : active
        ? Icons.play_circle_fill
        : Icons.radio_button_unchecked;
    final color = completed
        ? context.palette.green
        : active
        ? context.palette.yellow
        : context.palette.textMuted;
    final remaining = this.remaining;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: DismissingFrame(
        active: remaining != null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
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
                          ? context.palette.textSecondary
                          : context.palette.text,
                      fontWeight: active ? FontWeight.w600 : FontWeight.normal,
                      decoration: completed && entry.strikeCompleted
                          ? TextDecoration.lineThrough
                          : null,
                    ),
                  ),
                ),
                if (remaining != null && onCancel != null)
                  DismissingControls(remaining: remaining, onCancel: onCancel!)
                else
                  SizedBox(
                    width: 24,
                    height: 24,
                    child: onDismiss == null
                        ? null
                        : IconButton(
                            key: entry.dismissButtonKey,
                            tooltip: 'Dismiss completed ${entry.itemLabel}',
                            onPressed: onDismiss,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints.tightFor(
                              width: 24,
                              height: 24,
                            ),
                            icon: Icon(
                              Icons.close,
                              size: 14,
                              color: context.palette.textMuted,
                            ),
                          ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
