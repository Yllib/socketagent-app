import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Keep every control on screen. The model gets twice the label space.
class AdaptiveControlBar extends StatelessWidget {
  const AdaptiveControlBar({
    super.key,
    required this.children,
    this.hasModel = true,
  });
  final List<Widget> children;
  final bool hasModel;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 8),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (final (index, child) in children.indexed) ...[
          if (index > 0) const SizedBox(width: 4),
          Flexible(
            flex: index == 0 && hasModel ? 2 : 1,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: index == 0 && hasModel ? 220 : 110,
              ),
              child: child,
            ),
          ),
        ],
      ],
    ),
  );
}

class AdaptiveControlChip extends StatelessWidget {
  const AdaptiveControlChip({
    super.key,
    required this.icon,
    required this.label,
    this.iconColor,
    this.labelColor,
    this.active = false,
    this.leading,
  });
  final IconData icon;
  final String label;
  final Color? iconColor;
  final Color? labelColor;
  final bool active;
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        // On narrow buttons, prioritize the setting's text over its icon.
        final showIcon = constraints.maxWidth >= 76;
        final horizontalPadding = constraints.maxWidth < 48 ? 3.0 : 6.0;
        final labelWidth = math.max(
          0.0,
          constraints.maxWidth - horizontalPadding * 2 - (showIcon ? 18 : 0),
        );
        final scaler = MediaQuery.textScalerOf(context);
        final style = TextStyle(
          fontSize: 12,
          color: labelColor ?? theme.colorScheme.onSurfaceVariant,
        );
        final painter = TextPainter(
          text: TextSpan(text: label, style: style),
          textDirection: Directionality.of(context),
          textScaler: scaler,
          maxLines: 1,
        )..layout();
        final fontSize = painter.width > labelWidth && painter.width > 0
            ? (12 * labelWidth / painter.width).clamp(10.0, 12.0)
            : 12.0;
        painter.dispose();
        return Semantics(
          label: label,
          excludeSemantics: true,
          child: Container(
            constraints: const BoxConstraints(minHeight: 36),
            padding: EdgeInsets.symmetric(
              horizontal: horizontalPadding,
              vertical: 6,
            ),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              color: active
                  ? theme.colorScheme.primaryContainer.withAlpha(180)
                  : theme.colorScheme.surfaceContainerHighest,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (showIcon) ...[
                  leading ??
                      Icon(
                        icon,
                        size: 14,
                        color: iconColor ?? theme.colorScheme.onSurfaceVariant,
                      ),
                  const SizedBox(width: 4),
                ],
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                    style: style.copyWith(fontSize: fontSize),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
