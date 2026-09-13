import 'package:flutter/material.dart';

/// Desktop keeps the live, grouped actions next to the click. Mobile uses a sheet.
Future<String?> showSessionActionsMenu({
  required BuildContext context,
  required WidgetBuilder builder,
  Offset? anchor,
}) {
  if (anchor == null) {
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      constraints: const BoxConstraints(maxWidth: 560),
      builder: builder,
    );
  }
  final overlay =
      Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
  final position = overlay.globalToLocal(anchor);
  return showGeneralDialog<String>(
    context: context,
    useRootNavigator: false,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 120),
    pageBuilder: (context, animation, secondaryAnimation) =>
        CustomSingleChildLayout(
          delegate: _SessionMenuLayout(position),
          child: Material(
            key: const ValueKey('anchored-session-actions'),
            elevation: 8,
            borderRadius: BorderRadius.circular(12),
            clipBehavior: Clip.antiAlias,
            child: builder(context),
          ),
        ),
  );
}

class _SessionMenuLayout extends SingleChildLayoutDelegate {
  const _SessionMenuLayout(this.anchor);
  final Offset anchor;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints(
        maxWidth: (constraints.maxWidth - 16).clamp(0, 360),
        maxHeight: (constraints.maxHeight - 16).clamp(0, double.infinity),
      );

  @override
  Offset getPositionForChild(Size size, Size childSize) => Offset(
    anchor.dx.clamp(
      8,
      (size.width - childSize.width - 8).clamp(8, double.infinity),
    ),
    anchor.dy.clamp(
      8,
      (size.height - childSize.height - 8).clamp(8, double.infinity),
    ),
  );

  @override
  bool shouldRelayout(_SessionMenuLayout oldDelegate) =>
      anchor != oldDelegate.anchor;
}

class SessionAction {
  const SessionAction(
    this.id,
    this.label,
    this.icon, {
    this.subtitle,
    this.enabled = true,
    this.selected,
  });
  final String id;
  final String label;
  final IconData icon;
  final String? subtitle;
  final bool enabled;
  final bool? selected;
}

class SessionActionGroup {
  const SessionActionGroup(this.title, this.subtitle, this.icon, this.actions);
  final String title;
  final String subtitle;
  final IconData icon;
  final List<SessionAction> actions;
}

/// One bounded sheet with a short overview and one group visible at a time.
class SessionActionsSheet extends StatefulWidget {
  const SessionActionsSheet({
    super.key,
    required this.quickActions,
    required this.groups,
    this.onSettingChanged,
  });
  final List<SessionAction> quickActions;
  final List<SessionActionGroup> groups;
  final ValueChanged<String>? onSettingChanged;

  @override
  State<SessionActionsSheet> createState() => _SessionActionsSheetState();
}

class _SessionActionsSheetState extends State<SessionActionsSheet> {
  String? _groupTitle;

  @override
  Widget build(BuildContext context) {
    final group = widget.groups
        .where((g) => g.title == _groupTitle)
        .firstOrNull;
    return PopScope<String>(
      canPop: group == null,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) setState(() => _groupTitle = null);
      },
      child: SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * .8,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                child: Row(
                  children: [
                    if (group != null)
                      IconButton(
                        tooltip: 'Back to session actions',
                        onPressed: () => setState(() => _groupTitle = null),
                        icon: const Icon(Icons.arrow_back),
                      )
                    else
                      const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        group?.title ?? 'Session actions',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close session actions',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: ListView(
                  key: ValueKey(group?.title ?? 'overview'),
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
                  children: group != null
                      ? group.actions.map(_action).toList()
                      : [
                          ...widget.quickActions.map(_action),
                          const Divider(),
                          for (final entry in widget.groups)
                            ListTile(
                              dense: true,
                              leading: Icon(entry.icon, size: 22),
                              title: Text(entry.title),
                              subtitle: Text(
                                entry.subtitle,
                                style: const TextStyle(fontSize: 12),
                              ),
                              trailing: const Icon(
                                Icons.chevron_right,
                                size: 20,
                              ),
                              onTap: () =>
                                  setState(() => _groupTitle = entry.title),
                            ),
                        ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _action(SessionAction action) => ListTile(
    dense: true,
    enabled: action.enabled,
    leading: Icon(action.icon, size: 22),
    title: Text(action.label),
    subtitle: action.subtitle == null
        ? null
        : Text(action.subtitle!, style: const TextStyle(fontSize: 12)),
    trailing: action.selected == null
        ? null
        : Icon(
            action.selected!
                ? Icons.check_circle_outline
                : Icons.radio_button_unchecked,
            color: action.selected!
                ? Theme.of(context).colorScheme.primary
                : null,
            size: 22,
          ),
    onTap: !action.enabled
        ? null
        : () {
            if (action.selected != null && widget.onSettingChanged != null) {
              widget.onSettingChanged!(action.id);
            } else {
              Navigator.pop(context, action.id);
            }
          },
  );
}
