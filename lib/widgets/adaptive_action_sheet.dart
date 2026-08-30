import 'package:flutter/material.dart';

const BoxConstraints adaptiveActionSheetConstraints = BoxConstraints(
  maxWidth: 560,
);

class AdaptiveSheetAction<T> {
  const AdaptiveSheetAction({
    required this.value,
    required this.label,
    required this.icon,
    this.subtitle,
    this.iconColor,
    this.textColor,
    this.trailing,
    this.enabled = true,
    this.key,
  });

  final T value;
  final String label;
  final String? subtitle;
  final IconData icon;
  final Color? iconColor;
  final Color? textColor;
  final Widget? trailing;
  final bool enabled;
  final Key? key;
}

class AdaptiveSheetSection<T> {
  const AdaptiveSheetSection(this.actions);

  final List<AdaptiveSheetAction<T>> actions;
}

Future<T?> showAdaptiveActionSheet<T>({
  required BuildContext context,
  required List<AdaptiveSheetSection<T>> sections,
  String? title,
  String? subtitle,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    constraints: adaptiveActionSheetConstraints,
    builder: (sheetContext) => AdaptiveSheetBody(
      title: title,
      subtitle: subtitle,
      children: [
        for (
          var sectionIndex = 0;
          sectionIndex < sections.length;
          sectionIndex++
        ) ...[
          if (sectionIndex > 0) const Divider(height: 1),
          for (final action in sections[sectionIndex].actions)
            ListTile(
              key: action.key,
              enabled: action.enabled,
              leading: Icon(action.icon, color: action.iconColor),
              title: Text(
                action.label,
                style: action.textColor == null
                    ? null
                    : TextStyle(color: action.textColor),
              ),
              subtitle: action.subtitle == null
                  ? null
                  : Text(
                      action.subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
              trailing: action.trailing,
              onTap: action.enabled
                  ? () => Navigator.pop(sheetContext, action.value)
                  : null,
            ),
        ],
      ],
    ),
  );
}

/// Height-capped, naturally sized content for action-oriented bottom sheets.
/// Short lists keep their intrinsic height. Long lists scroll above the
/// system navigation area instead of extending off-screen.
class AdaptiveSheetBody extends StatelessWidget {
  const AdaptiveSheetBody({
    super.key,
    required this.children,
    this.title,
    this.subtitle,
    this.bottom,
    this.maxHeightFraction = 0.88,
  });

  final List<Widget> children;
  final String? title;
  final String? subtitle;
  final Widget? bottom;
  final double maxHeightFraction;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final maxHeight = media.size.height * maxHeightFraction;
    final theme = Theme.of(context);

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: SafeArea(
        top: false,
        child: ListTileTheme(
          data: const ListTileThemeData(
            dense: true,
            minVerticalPadding: 6,
            contentPadding: EdgeInsets.symmetric(horizontal: 16),
            visualDensity: VisualDensity(horizontal: 0, vertical: -2),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (title != null || subtitle != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (title != null)
                        Text(
                          title!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      if (subtitle != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          subtitle!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              Flexible(
                fit: FlexFit.loose,
                child: ListView(
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  children: children,
                ),
              ),
              if (bottom != null) ...[const Divider(height: 1), bottom!],
            ],
          ),
        ),
      ),
    );
  }
}
