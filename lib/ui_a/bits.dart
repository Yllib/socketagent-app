import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'clock.dart';
import 'data.dart';

export 'clock.dart';
import 'theme.dart';

/// "4s", "3:12", "1:04:09".
String clockText(Duration d) {
  final s = d.inSeconds.abs();
  if (s < 60) return '${s}s';
  final h = s ~/ 3600;
  final m = (s % 3600) ~/ 60;
  final sec = (s % 60).toString().padLeft(2, '0');
  if (h == 0) return '$m:$sec';
  return '$h:${m.toString().padLeft(2, '0')}:$sec';
}

/// "now", "4m", "3h", "2d", "Oct 3".
String agoText(DateTime t, [DateTime? now]) {
  final d = (now ?? SecondClock.now()).difference(t);
  if (d.inSeconds < 45) return 'now';
  if (d.inMinutes < 60) return '${d.inMinutes}m';
  if (d.inHours < 24) return '${d.inHours}h';
  if (d.inDays < 7) return '${d.inDays}d';
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  return '${months[t.month - 1]} ${t.day}';
}

/// Time until [until] in its largest unit: "5h", "40m".
String leftText(DateTime until) {
  final d = until.difference(SecondClock.now());
  if (d.isNegative) return '0m';
  if (d.inHours > 0) return '${d.inHours}h';
  return '${d.inMinutes}m';
}

/// Shortens a path to its last two segments, with ~ for a home folder.
String shortPath(String path) {
  if (path.isEmpty) return '';
  var p = path.replaceAll('\\', '/');
  p = p.replaceFirst(RegExp(r'^/(home|Users)/[^/]+'), '~');
  p = p.replaceFirst(
    RegExp(r'^[A-Za-z]:/Users/[^/]+', caseSensitive: false),
    '~',
  );
  final parts = p.split('/').where((s) => s.isNotEmpty).toList();
  if (parts.length <= 2) return p;
  return '…/${parts.sublist(parts.length - 2).join('/')}';
}

String harnessLabel(String? backend) => backend == 'codex' ? 'codex' : 'claude';

/// Ticking elapsed time since [start]. Repaints once a second, alone.
class Elapsed extends StatelessWidget {
  const Elapsed(this.start, {super.key, this.style});

  final DateTime? start;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final from = start;
    if (from == null) return const SizedBox.shrink();
    return RepaintBoundary(
      child: ListenableBuilder(
        listenable: SecondClock.instance,
        builder: (context, _) =>
            Text(clockText(SecondClock.now().difference(from)), style: style),
      ),
    );
  }
}

/// Countdown to [until], or "expired".
class Countdown extends StatelessWidget {
  const Countdown(this.until, {super.key, this.style});

  final DateTime until;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: ListenableBuilder(
        listenable: SecondClock.instance,
        builder: (context, _) {
          final left = until.difference(SecondClock.now());
          return Text(
            left.isNegative ? 'expired' : '${clockText(left)} left',
            style: style,
          );
        },
      ),
    );
  }
}

/// Color for a computer badge, or the accent when it has none.
Color computerColor(TowerPalette p, int? value) =>
    value == null ? p.accent : Color(value);

/// Uppercase section label with an optional count, drawn in [color].
class SectionLabel extends StatelessWidget {
  const SectionLabel(
    this.text, {
    super.key,
    this.count,
    this.color,
    this.trailing,
    this.padding = const EdgeInsets.fromLTRB(14, 14, 10, 6),
  });

  final String text;
  final int? count;
  final Color? color;
  final Widget? trailing;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final p = Tw.of(context);
    return Padding(
      padding: padding,
      child: Row(
        children: [
          Text(text.toUpperCase(), style: Ts.label(p, color)),
          if (count != null) ...[
            const SizedBox(width: 6),
            Text('$count', style: Ts.label(p, color ?? p.accent)),
          ],
          const Spacer(),
          ?trailing,
        ],
      ),
    );
  }
}

/// Small flat text button used for dense inline actions.
class Act extends StatelessWidget {
  const Act(
    this.label, {
    super.key,
    required this.onTap,
    this.color,
    this.filled = false,
    this.icon,
    this.dense = false,
  });

  final String label;
  final VoidCallback? onTap;
  final Color? color;
  final bool filled;
  final IconData? icon;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final p = Tw.of(context);
    final c = onTap == null ? p.muted : (color ?? p.accent);
    return Semantics(
      button: true,
      label: label,
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: BoxConstraints(minHeight: dense ? 28 : 36),
          padding: EdgeInsets.symmetric(horizontal: dense ? 8 : 12),
          decoration: BoxDecoration(
            color: filled ? c : null,
            border: Border.all(color: filled ? c : c.withValues(alpha: 0.55)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 15, color: filled ? p.bg : c),
                const SizedBox(width: 6),
              ],
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: filled ? p.bg : c,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Marks a control or screen that looks finished but does nothing yet.
class NotWired extends StatelessWidget {
  const NotWired({super.key});

  @override
  Widget build(BuildContext context) {
    final p = Tw.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(border: Border.all(color: p.wait)),
      child: Text(
        'NOT WIRED',
        style: Ts.label(p, p.wait).copyWith(fontSize: 9),
      ),
    );
  }
}

/// Wraps a stub control: drawn at reduced strength, taps blocked, badge on.
class Stubbed extends StatelessWidget {
  const Stubbed({super.key, required this.child, this.badge = true});

  final Widget child;
  final bool badge;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: IgnorePointer(child: Opacity(opacity: 0.55, child: child)),
        ),
        if (badge) ...[const SizedBox(width: 6), const NotWired()],
      ],
    );
  }
}

/// Square state mark used on strips and headers.
class LiveMark extends StatelessWidget {
  const LiveMark({super.key, required this.color, this.hollow = false});

  final Color color;
  final bool hollow;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        color: hollow ? null : color,
        border: Border.all(color: color, width: 1.5),
      ),
    );
  }
}

/// Color for an agent state.
Color liveColor(TowerPalette p, Live live) => switch (live) {
  Live.running => p.run,
  Live.compacting => p.accent,
  Live.idle => p.muted,
};

/// A thin rule.
class Hair extends StatelessWidget {
  const Hair({super.key, this.indent = 0});
  final double indent;

  @override
  Widget build(BuildContext context) => Container(
    height: 1,
    margin: EdgeInsets.only(left: indent),
    color: Tw.of(context).line,
  );
}

/// Carries the palette and [TowerData] into a new route, which builds
/// outside the subtree that provides them.
Widget Function(Widget) _carry(BuildContext context) {
  final palette = Tw.of(context);
  final data = context.read<TowerData>();
  return (child) => ChangeNotifierProvider<TowerData>.value(
    value: data,
    child: Tw.wrap(palette, child),
  );
}

/// Pushes [page] as a full route wrapped in the current Tower palette.
Future<T?> pushTower<T>(BuildContext context, Widget page) {
  final carry = _carry(context);
  return Navigator.of(
    context,
  ).push<T>(MaterialPageRoute(builder: (_) => carry(page)));
}

/// Shows a bottom sheet in the Tower palette.
Future<T?> sheetTower<T>(
  BuildContext context,
  WidgetBuilder builder, {
  bool scroll = true,
}) {
  final carry = _carry(context);
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: scroll,
    useSafeArea: true,
    builder: (ctx) => carry(Builder(builder: builder)),
  );
}

/// Asks to confirm a destructive action. Resolves true only on confirm.
Future<bool> confirmTower(
  BuildContext context, {
  required String title,
  required String action,
  String body = '',
}) async {
  final p = Tw.of(context);
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => Tw.wrap(
      p,
      AlertDialog(
        title: Text(title, style: Ts.title(p)),
        content: body.isEmpty ? null : Text(body, style: Ts.body(p)),
        actions: [
          Act('Cancel', onTap: () => Navigator.pop(ctx, false), color: p.muted),
          Act(action, onTap: () => Navigator.pop(ctx, true), color: p.fail),
        ],
      ),
    ),
  );
  return ok ?? false;
}

/// Prompts for one line of text.
Future<String?> askText(
  BuildContext context, {
  required String title,
  String initial = '',
  String action = 'Save',
}) {
  final p = Tw.of(context);
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => Tw.wrap(
      p,
      AlertDialog(
        title: Text(title, style: Ts.title(p)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: Ts.body(p),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          Act('Cancel', onTap: () => Navigator.pop(ctx), color: p.muted),
          Act(action, onTap: () => Navigator.pop(ctx, controller.text)),
        ],
      ),
    ),
  );
}
