import 'dart:async';

import 'package:flutter/material.dart';

import '../../util/format.dart';
import '../state/ui_c_models.dart';
import '../theme/ui_c_theme.dart';

/// "4m 12s", "1h 03m", "2d 4h". Compact enough for a row.
String formatElapsed(Duration d) {
  if (d.isNegative) return '0s';
  if (d.inDays >= 1) return '${d.inDays}d ${d.inHours % 24}h';
  if (d.inHours >= 1) {
    return '${d.inHours}h ${(d.inMinutes % 60).toString().padLeft(2, '0')}m';
  }
  if (d.inMinutes >= 1) {
    return '${d.inMinutes}m ${(d.inSeconds % 60).toString().padLeft(2, '0')}s';
  }
  return '${d.inSeconds}s';
}

String relativeTime(DateTime time) => formatTimeAgo(time.toLocal());

/// Condensed caps label that opens a section: "NEEDS YOU  3".
class SectionHead extends StatelessWidget {
  const SectionHead(
    this.label, {
    super.key,
    this.count,
    this.color,
    this.trailing,
    this.padding = const EdgeInsets.fromLTRB(12, 14, 12, 4),
  });

  final String label;
  final int? count;
  final Color? color;
  final Widget? trailing;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final tone = color ?? c.textDim;
    return Padding(
      padding: padding,
      child: Row(
        children: [
          Text(
            label.toUpperCase(),
            style: UiCFonts.condensed(
              size: 11,
              weight: FontWeight.w600,
              color: tone,
              letterSpacing: 1.2,
            ),
          ),
          if (count != null) ...[
            const SizedBox(width: 6),
            Text(
              '$count',
              style: UiCFonts.condensed(
                size: 11,
                weight: FontWeight.w700,
                color: tone,
              ),
            ),
          ],
          const Spacer(),
          ?trailing,
        ],
      ),
    );
  }
}

/// A small square that says what a session is doing. Shape and fill carry
/// the meaning so color alone never has to.
class StateSquare extends StatelessWidget {
  const StateSquare(this.phase, {super.key, this.size = 8});

  final SessionPhase phase;
  final double size;

  static Color colorFor(UiCTheme c, SessionPhase phase) => switch (phase) {
    SessionPhase.waitingOnUser => c.warn,
    SessionPhase.running => c.accent,
    SessionPhase.compacting => c.info,
    SessionPhase.waitingOnAgent => c.accent,
    SessionPhase.unreadFinished => c.ok,
    SessionPhase.idle => c.textFaint,
    SessionPhase.offline => c.textFaint,
  };

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final color = colorFor(c, phase);
    final filled = switch (phase) {
      SessionPhase.waitingOnUser ||
      SessionPhase.running ||
      SessionPhase.compacting ||
      SessionPhase.unreadFinished => true,
      _ => false,
    };
    Widget square = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: filled ? color : null,
        border: Border.all(color: color, width: 1.2),
        borderRadius: BorderRadius.circular(1.5),
      ),
    );
    if (phase == SessionPhase.waitingOnAgent) {
      // Half filled: this agent is idle, its children are not.
      square = Stack(
        children: [
          square,
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: size / 2,
            child: Container(color: color),
          ),
        ],
      );
    }
    if (phase == SessionPhase.offline) {
      square = CustomPaint(
        foregroundPainter: _SlashPainter(color),
        child: square,
      );
    }
    return SizedBox(width: size, height: size, child: square);
  }
}

class _SlashPainter extends CustomPainter {
  const _SlashPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawLine(
      Offset(0, size.height),
      Offset(size.width, 0),
      Paint()
        ..color = color
        ..strokeWidth = 1.2,
    );
  }

  @override
  bool shouldRepaint(_SlashPainter old) => old.color != color;
}

String phaseLabel(SessionPhase phase) => switch (phase) {
  SessionPhase.waitingOnUser => 'Needs you',
  SessionPhase.running => 'Running',
  SessionPhase.compacting => 'Compacting',
  SessionPhase.waitingOnAgent => 'Children working',
  SessionPhase.unreadFinished => 'Finished',
  SessionPhase.idle => 'Idle',
  SessionPhase.offline => 'Offline',
};

/// Small bordered label. Filled when it marks the current choice.
class Tag extends StatelessWidget {
  const Tag(
    this.text, {
    super.key,
    this.color,
    this.filled = false,
    this.mono = false,
    this.onTap,
  });

  final String text;
  final Color? color;
  final bool filled;
  final bool mono;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final tone = color ?? c.textDim;
    final style = mono
        ? UiCFonts.mono(size: 10.5, color: filled ? c.bg : tone)
        : UiCFonts.condensed(
            size: 10.5,
            weight: FontWeight.w600,
            color: filled ? c.bg : tone,
            letterSpacing: .4,
          );
    final child = Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
      decoration: BoxDecoration(
        color: filled ? tone : null,
        border: Border.all(color: tone.withValues(alpha: filled ? 1 : .7)),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(text, style: style),
    );
    if (onTap == null) return child;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(3),
      child: child,
    );
  }
}

class HarnessTag extends StatelessWidget {
  const HarnessTag(this.backend, {super.key, this.filled = false});

  final String? backend;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final codex = backend == 'codex';
    return Tag(
      codex ? 'CODEX' : 'CLAUDE',
      color: c.harness(backend),
      filled: filled,
    );
  }
}

/// Colored square plus name. The square alone identifies a computer in
/// tight rows; the name joins it where there is room.
class ComputerMark extends StatelessWidget {
  const ComputerMark({
    super.key,
    required this.name,
    required this.color,
    this.connected = true,
    this.showName = true,
    this.size = 9,
  });

  final String name;
  final Color color;
  final bool connected;
  final bool showName;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: connected ? color : null,
            border: Border.all(color: color, width: 1.2),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        if (showName) ...[
          const SizedBox(width: 5),
          Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: UiCFonts.condensed(
              size: 11.5,
              weight: FontWeight.w600,
              color: connected ? c.textDim : c.textFaint,
            ),
          ),
        ],
      ],
    );
  }
}

/// Elapsed time since [since], ticking once a second while mounted. Only
/// running rows mount one, so an idle screen repaints nothing.
class Elapsed extends StatefulWidget {
  const Elapsed(this.since, {super.key, this.style, this.prefix = ''});

  final DateTime since;
  final TextStyle? style;
  final String prefix;

  @override
  State<Elapsed> createState() => _ElapsedState();
}

class _ElapsedState extends State<Elapsed> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final style =
        widget.style ?? UiCFonts.mono(size: 11, color: context.c.accent);
    return Text(
      '${widget.prefix}${formatElapsed(DateTime.now().difference(widget.since))}',
      style: style,
    );
  }
}

/// Flat bordered button. Primary fills with the accent; danger outlines red.
class CButton extends StatelessWidget {
  const CButton(
    this.label, {
    super.key,
    this.onTap,
    this.primary = false,
    this.danger = false,
    this.icon,
    this.dense = false,
    this.color,
  });

  final String label;
  final VoidCallback? onTap;
  final bool primary;
  final bool danger;
  final IconData? icon;
  final bool dense;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final enabled = onTap != null;
    final tone =
        color ??
        (danger
            ? c.danger
            : primary
            ? c.accent
            : c.text);
    final fg = primary ? c.onAccent : tone;
    final body = Container(
      padding: EdgeInsets.symmetric(
        horizontal: dense ? 8 : 12,
        vertical: dense ? 4 : 7,
      ),
      decoration: BoxDecoration(
        color: primary ? tone : null,
        border: Border.all(color: primary ? tone : tone.withValues(alpha: .55)),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: dense ? 13 : 15, color: fg),
            const SizedBox(width: 5),
          ],
          Text(
            label,
            style: UiCFonts.condensed(
              size: dense ? 12 : 13,
              weight: FontWeight.w600,
              color: fg,
              letterSpacing: .3,
            ),
          ),
        ],
      ),
    );
    return Opacity(
      opacity: enabled ? 1 : .4,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: body,
      ),
    );
  }
}

class IconTap extends StatelessWidget {
  const IconTap(
    this.icon, {
    super.key,
    required this.onTap,
    this.tooltip,
    this.color,
    this.size = 18,
    this.pad = 8,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final String? tooltip;
  final Color? color;
  final double size;
  final double pad;

  @override
  Widget build(BuildContext context) {
    final child = InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: EdgeInsets.all(pad),
        child: Icon(icon, size: size, color: color ?? context.c.textDim),
      ),
    );
    if (tooltip == null) return child;
    return Tooltip(message: tooltip!, child: child);
  }
}

/// Keyboard hint, shown only where a keyboard is likely.
class Kbd extends StatelessWidget {
  const Kbd(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        border: Border.all(color: c.lineStrong),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(text, style: UiCFonts.mono(size: 10, color: c.textFaint)),
    );
  }
}

/// Marks a control that is drawn but not connected yet.
class StubBadge extends StatelessWidget {
  const StubBadge({super.key});

  @override
  Widget build(BuildContext context) => Tag('NOT WIRED', color: context.c.warn);
}

/// Banner across the top of a stubbed screen. Nothing below it acts.
class StubNotice extends StatelessWidget {
  const StubNotice({
    super.key,
    this.text = 'Visual stub. Nothing here acts yet.',
  });

  final String text;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: c.warn.withValues(alpha: .08),
        border: Border(bottom: BorderSide(color: c.warn.withValues(alpha: .5))),
      ),
      child: Row(
        children: [
          Icon(Icons.construction, size: 14, color: c.warn),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: UiCFonts.condensed(
                size: 12,
                color: c.warn,
                weight: FontWeight.w600,
              ),
            ),
          ),
          const StubBadge(),
        ],
      ),
    );
  }
}

/// A list row with a hairline below and an optional color bar on the left.
class HairRow extends StatelessWidget {
  const HairRow({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.selected = false,
    this.bar,
    this.padding = const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool selected;
  final Color? bar;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Material(
      color: selected ? c.accentWash : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Container(
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: c.line),
              left: bar != null
                  ? BorderSide(color: bar!, width: 3)
                  : BorderSide.none,
            ),
          ),
          padding: padding,
          child: child,
        ),
      ),
    );
  }
}

class EmptyLine extends StatelessWidget {
  const EmptyLine(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
    child: Text(
      text,
      style: UiCFonts.condensed(size: 12, color: context.c.textFaint),
    ),
  );
}

/// Thin progress line for context and limits. Static; no animation.
class Meter extends StatelessWidget {
  const Meter(
    this.fraction, {
    super.key,
    this.color,
    this.height = 3,
    this.width,
  });

  final double fraction;
  final Color? color;
  final double height;
  final double? width;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final tone =
        color ??
        (fraction > .85
            ? c.danger
            : fraction > .65
            ? c.warn
            : c.accent);
    return SizedBox(
      width: width,
      height: height,
      child: LayoutBuilder(
        builder: (context, constraints) => Stack(
          children: [
            Container(color: c.lineStrong),
            Container(
              width: constraints.maxWidth * fraction.clamp(0, 1),
              color: tone,
            ),
          ],
        ),
      ),
    );
  }
}
