import 'package:flutter/material.dart';

import '../../util/format.dart';
import '../model/board_model.dart';
import '../theme/ui_b_theme.dart';
import 'clock.dart';

/// Small filled circle in a state color.
class Dot extends StatelessWidget {
  const Dot(this.color, {super.key, this.size = 7, this.hollow = false});
  final Color color;
  final double size;
  final bool hollow;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: hollow ? Colors.transparent : color,
      border: hollow ? Border.all(color: color, width: 1.5) : null,
    ),
  );
}

Color activityColor(UiBTheme t, SessionActivity a) => switch (a) {
  SessionActivity.running || SessionActivity.compacting => t.running,
  SessionActivity.waitingOnUser => t.waiting,
  SessionActivity.waitingOnAgent => t.info,
  SessionActivity.offline => t.text3,
  SessionActivity.idle => t.text3,
};

String activityLabel(SessionActivity a) => switch (a) {
  SessionActivity.running => 'running',
  SessionActivity.compacting => 'compacting',
  SessionActivity.waitingOnUser => 'waiting on you',
  SessionActivity.waitingOnAgent => 'waiting on agents',
  SessionActivity.offline => 'offline',
  SessionActivity.idle => 'idle',
};

/// The harness mark: a two-letter tag in the harness color.
class HarnessMark extends StatelessWidget {
  const HarnessMark(this.harness, {super.key});
  final String harness;

  @override
  Widget build(BuildContext context) {
    final t = UiBTheme.of(context);
    final text = UiBText.of(context);
    final codex = harness == 'codex';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        border: Border.all(color: t.harness(harness).withValues(alpha: 0.6)),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        codex ? 'CX' : 'CL',
        style: text.micro.copyWith(color: t.harness(harness)),
      ),
    );
  }
}

/// Computer identity: a 3px bar in the computer color plus its name.
class ComputerTag extends StatelessWidget {
  const ComputerTag(this.name, {super.key, this.color, this.dim = false});
  final String name;
  final Color? color;
  final bool dim;

  @override
  Widget build(BuildContext context) {
    final t = UiBTheme.of(context);
    final text = UiBText.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 3,
          height: 10,
          decoration: BoxDecoration(
            color: color ?? t.text3,
            borderRadius: BorderRadius.circular(1),
          ),
        ),
        const SizedBox(width: 4),
        Text(
          name,
          style: text.meta.copyWith(color: dim ? t.text3 : t.text2),
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}

/// Flat tag with optional color. Used for counts, states and kinds.
class Tag extends StatelessWidget {
  const Tag(this.label, {super.key, this.color, this.filled = false});
  final String label;
  final Color? color;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final t = UiBTheme.of(context);
    final text = UiBText.of(context);
    final c = color ?? t.text3;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
      decoration: BoxDecoration(
        color: filled ? c : c.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        label,
        style: text.micro.copyWith(color: filled ? t.onAccent : c),
      ),
    );
  }
}

/// Marks a control that looks finished but does nothing yet.
class StubBadge extends StatelessWidget {
  const StubBadge({super.key});

  @override
  Widget build(BuildContext context) {
    final t = UiBTheme.of(context);
    final text = UiBText.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        border: Border.all(color: t.text3, style: BorderStyle.solid),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        'NOT WIRED',
        style: text.micro.copyWith(color: t.text3, fontSize: 9),
      ),
    );
  }
}

/// Lane or section header: label, count, optional trailing control.
class SectionHeader extends StatelessWidget {
  const SectionHeader(
    this.label, {
    super.key,
    this.count,
    this.color,
    this.trailing,
    this.onTap,
  });
  final String label;
  final int? count;
  final Color? color;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = UiBTheme.of(context);
    final text = UiBText.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 4),
        child: Row(
          children: [
            if (color case final c?) ...[
              Dot(c, size: 6),
              const SizedBox(width: 6),
            ],
            Text(
              label.toUpperCase(),
              style: text.micro.copyWith(color: color ?? t.text3),
            ),
            if (count != null) ...[
              const SizedBox(width: 6),
              Text('$count', style: text.micro.copyWith(color: t.text2)),
            ],
            const Spacer(),
            ?trailing,
          ],
        ),
      ),
    );
  }
}

/// Ticking elapsed label for a running thing. Subscribes to the clock.
class ElapsedText extends StatelessWidget {
  const ElapsedText(this.since, {super.key, this.style});
  final DateTime since;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final now = UiBClockScope.now(context);
    return Text(
      formatElapsed(now.difference(since)),
      style: style ?? UiBText.of(context).meta,
    );
  }
}

/// "5m ago" style label. Reads the clock without ticking.
class AgoText extends StatelessWidget {
  const AgoText(this.time, {super.key, this.style});
  final DateTime time;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final now = UiBClockScope.read(context);
    return Text(
      formatTimeAgo(time, now: now),
      style: style ?? UiBText.of(context).meta,
    );
  }
}

/// Dense flat button: text, optional icon, accent when primary.
class FlatButton extends StatelessWidget {
  const FlatButton(
    this.label, {
    super.key,
    this.onPressed,
    this.icon,
    this.primary = false,
    this.danger = false,
    this.compact = false,
  });
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool primary;
  final bool danger;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final t = UiBTheme.of(context);
    final text = UiBText.of(context);
    final fg = onPressed == null
        ? t.text3
        : danger
        ? t.failed
        : primary
        ? t.onAccent
        : t.text;
    final bg = primary && onPressed != null ? t.accent : t.raised;
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(5),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(5),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 8 : 12,
            vertical: compact ? 5 : 8,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 14, color: fg),
                const SizedBox(width: 5),
              ],
              Text(
                label,
                style: text.body.copyWith(
                  color: fg,
                  fontWeight: FontWeight.w600,
                  fontSize: (compact ? 12 : 13) * text.scale,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Icon-only button sized for a thumb, drawn without chrome.
class IconBtn extends StatelessWidget {
  const IconBtn(
    this.icon, {
    super.key,
    this.onPressed,
    this.tooltip,
    this.color,
    this.size = 18,
    this.box = 36,
  });
  final IconData icon;
  final VoidCallback? onPressed;
  final String? tooltip;
  final Color? color;
  final double size;
  final double box;

  @override
  Widget build(BuildContext context) {
    final t = UiBTheme.of(context);
    final button = InkResponse(
      onTap: onPressed,
      radius: box / 2,
      child: SizedBox(
        width: box,
        height: box,
        child: Center(
          child: Icon(
            icon,
            size: size,
            color: onPressed == null ? t.text3 : (color ?? t.text2),
          ),
        ),
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}

/// Hairline divider in the theme line color.
class Hairline extends StatelessWidget {
  const Hairline({super.key, this.indent = 0});
  final double indent;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(left: indent),
    child: Container(height: 1, color: UiBTheme.of(context).line),
  );
}

/// Label and value on one line, for detail panels.
class KV extends StatelessWidget {
  const KV(this.label, this.value, {super.key, this.valueColor});
  final String label;
  final String value;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    final text = UiBText.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 92, child: Text(label, style: text.meta)),
          Expanded(
            child: Text(
              value,
              style: text.body2.copyWith(
                color: valueColor,
                fontSize: 12 * text.scale,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Empty-state line, centered and quiet.
class EmptyLine extends StatelessWidget {
  const EmptyLine(this.label, {super.key});
  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    child: Text(label, style: UiBText.of(context).meta),
  );
}
