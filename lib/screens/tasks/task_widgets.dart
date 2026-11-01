import 'package:flutter/material.dart';

import '../../config/app_palette.dart';
import '../../widgets/copy_button.dart';
import 'task_model.dart';

/// A section title inside the detail pane and the editor: white, small,
/// bold, with no hairline or muted caption around it.
class TaskSectionLabel extends StatelessWidget {
  const TaskSectionLabel(this.text, {super.key, this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 14, bottom: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// A one-line explanation under a control. [warn] colours it as a caution.
class TaskNote extends StatelessWidget {
  const TaskNote(this.text, {super.key, this.warn = false, this.error = false});

  final String text;
  final bool warn;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          height: 1.3,
          color: error
              ? palette.danger
              : warn
              ? palette.warning
              : Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// A label and value on one line, label in a fixed column.
class TaskFactRow extends StatelessWidget {
  const TaskFactRow(this.label, this.value, {super.key, this.onTap});

  final String label;
  final String value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Text(
      value,
      style: TextStyle(
        fontSize: 13,
        color: onTap == null ? scheme.onSurface : context.palette.blue,
        decoration: onTap == null ? null : TextDecoration.underline,
        decorationColor: context.palette.blue,
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 92,
            child: Text(
              label,
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
            ),
          ),
          Expanded(
            child: onTap == null
                ? text
                : InkWell(
                    onTap: onTap,
                    child: Align(alignment: Alignment.centerLeft, child: text),
                  ),
          ),
        ],
      ),
    );
  }
}

/// Long text such as a prompt or a run result: a capped excerpt with a
/// Show all toggle and a copy button. Selectable so results can be lifted
/// out without opening the session.
class TaskLongText extends StatefulWidget {
  const TaskLongText(
    this.text, {
    super.key,
    this.collapsedLines = 6,
    this.monospace = false,
  });

  final String text;
  final int collapsedLines;
  final bool monospace;

  @override
  State<TaskLongText> createState() => _TaskLongTextState();
}

class _TaskLongTextState extends State<TaskLongText> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final lines = widget.text.split('\n').length;
    final long =
        lines > widget.collapsedLines ||
        widget.text.length > widget.collapsedLines * 110;
    final style = TextStyle(
      fontSize: 13,
      height: 1.35,
      color: scheme.onSurface,
      fontFamily: widget.monospace ? 'monospace' : null,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Stack(
          children: [
            Padding(
              padding: const EdgeInsets.only(right: 32),
              child: _expanded || !long
                  ? SelectableText(widget.text, style: style)
                  : Text(
                      widget.text,
                      style: style,
                      maxLines: widget.collapsedLines,
                      overflow: TextOverflow.ellipsis,
                    ),
            ),
            Positioned(
              right: 0,
              top: -6,
              child: CopyButton(text: widget.text),
            ),
          ],
        ),
        if (long)
          TextButton(
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              minimumSize: const Size(0, 28),
              visualDensity: VisualDensity.compact,
            ),
            onPressed: () => setState(() => _expanded = !_expanded),
            child: Text(
              _expanded
                  ? 'Show less'
                  : 'Show all · ${widget.text.length} chars',
              style: const TextStyle(fontSize: 12),
            ),
          ),
      ],
    );
  }
}

/// The glyph for a task's state. Running draws the shared stepping wheel,
/// which only repaints twelve times a second.
class TaskStatusIcon extends StatelessWidget {
  const TaskStatusIcon(this.task, {super.key, this.size = 16});

  final ScheduledTaskView task;
  final double size;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final scheme = Theme.of(context).colorScheme;
    if (task.isArchived) {
      return Icon(Icons.archive_outlined, size: size, color: palette.textMuted);
    }
    return switch (task.status) {
      TaskStatus.running => Icon(
        Icons.play_circle_fill,
        size: size,
        color: palette.success,
      ),
      TaskStatus.pending => Icon(
        task.isRecurring ? Icons.repeat : Icons.schedule,
        size: size,
        color: scheme.onSurfaceVariant,
      ),
      TaskStatus.completed => Icon(
        Icons.check_circle_outline,
        size: size,
        color: palette.success,
      ),
      TaskStatus.failed => Icon(
        Icons.error_outline,
        size: size,
        color: palette.danger,
      ),
      TaskStatus.cancelled => Icon(
        Icons.pause_circle_outline,
        size: size,
        color: palette.textMuted,
      ),
    };
  }
}

/// The colour the state's label and glyph share.
Color taskStatusColor(BuildContext context, ScheduledTaskView task) {
  final palette = context.palette;
  if (task.isArchived) return palette.textMuted;
  return switch (task.status) {
    TaskStatus.running || TaskStatus.completed => palette.success,
    TaskStatus.failed => palette.danger,
    TaskStatus.cancelled => palette.textMuted,
    TaskStatus.pending => Theme.of(context).colorScheme.onSurfaceVariant,
  };
}

/// Dense flat text button used for the action bars.
class TaskActionButton extends StatelessWidget {
  const TaskActionButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.danger = false,
    this.tooltip,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool danger;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final color = danger
        ? context.palette.danger
        : Theme.of(context).colorScheme.onSurface;
    final button = TextButton.icon(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: color,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        minimumSize: const Size(0, 32),
        visualDensity: VisualDensity.compact,
        textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(
          fontSize: 13,
          fontWeight: FontWeight.w500,
        ),
      ),
      icon: Icon(icon, size: 16),
      label: Text(label),
    );
    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}

/// What the rows and the detail pane need to know about the fleet without
/// holding the provider: names and reachability of computers, session titles
/// and whether more than one computer is configured.
class TaskFleetInfo {
  const TaskFleetInfo({
    required this.multiComputer,
    required this.computerName,
    required this.computerOnline,
    required this.sessionTitle,
  });

  final bool multiComputer;
  final String Function(String serverId) computerName;
  final bool Function(String serverId) computerOnline;

  /// Null when the session is not in the list, for example after deletion.
  final String? Function(String serverId, String sessionId) sessionTitle;
}
