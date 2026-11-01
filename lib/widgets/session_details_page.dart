import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// One row on the session details page. A non-null [selected] makes it a
/// switch that toggles in place; otherwise tapping opens something.
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

class SessionDetailsSection {
  const SessionDetailsSection(this.title, this.actions);
  final String title;
  final List<SessionAction> actions;
}

/// A line of the details block. [copyable] values copy on tap.
class SessionDetailsFact {
  const SessionDetailsFact(this.label, this.value, {this.copyable = false});
  final String label;
  final String value;
  final bool copyable;
}

/// Opens the details page: a full page on phones, a panel along the right
/// edge on wide screens. The page stays open while its actions run, so
/// whatever an action opens returns here.
Future<void> showSessionDetails(BuildContext context, WidgetBuilder builder) {
  if (MediaQuery.sizeOf(context).width < 900) {
    return Navigator.of(context).push(MaterialPageRoute(builder: builder));
  }
  return showGeneralDialog<void>(
    context: context,
    useRootNavigator: false,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.black54,
    transitionDuration: const Duration(milliseconds: 150),
    pageBuilder: (context, _, _) => Align(
      alignment: Alignment.centerRight,
      child: SizedBox(
        key: const ValueKey('session-details-panel'),
        width: 420,
        height: double.infinity,
        child: Material(child: builder(context)),
      ),
    ),
    transitionBuilder: (context, animation, _, child) => SlideTransition(
      position: Tween(
        begin: const Offset(1, 0),
        end: Offset.zero,
      ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOut)),
      child: child,
    ),
  );
}

/// Everything about the open session that is not the conversation: what it
/// is, where to go from it, and its settings.
class SessionDetailsPage extends StatelessWidget {
  const SessionDetailsPage({
    super.key,
    required this.title,
    required this.facts,
    required this.quickActions,
    required this.sections,
    required this.onAction,
  });

  final String title;
  final List<SessionDetailsFact> facts;
  final List<SessionAction> quickActions;
  final List<SessionDetailsSection> sections;
  final ValueChanged<String> onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Session')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Text(
              title,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          for (final fact in facts) _fact(context, fact),
          if (quickActions.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 12, 8, 4),
              child: Row(
                children: [
                  for (final action in quickActions)
                    Expanded(child: _quickAction(context, action)),
                ],
              ),
            ),
          for (final section in sections)
            if (section.actions.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 2),
                child: Text(
                  section.title,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              for (final action in section.actions) _row(context, action),
            ],
        ],
      ),
    );
  }

  Widget _fact(BuildContext context, SessionDetailsFact fact) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 84,
            child: Text(
              fact.label,
              style: TextStyle(fontSize: 12, color: muted),
            ),
          ),
          Expanded(
            child: Text(fact.value, style: const TextStyle(fontSize: 12)),
          ),
          if (fact.copyable) Icon(Icons.copy, size: 14, color: muted),
        ],
      ),
    );
    if (!fact.copyable) return row;
    return InkWell(
      onTap: () {
        Clipboard.setData(ClipboardData(text: fact.value));
        ScaffoldMessenger.maybeOf(context)
          ?..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text('${fact.label} copied')));
      },
      child: row,
    );
  }

  Widget _quickAction(BuildContext context, SessionAction action) => InkWell(
    key: ValueKey('session-quick-${action.id}'),
    onTap: action.enabled ? () => onAction(action.id) : null,
    borderRadius: BorderRadius.circular(8),
    child: Opacity(
      opacity: action.enabled ? 1 : .4,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          children: [
            Icon(action.icon, size: 22),
            const SizedBox(height: 4),
            Text(
              action.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _row(BuildContext context, SessionAction action) {
    final selected = action.selected;
    return ListTile(
      key: ValueKey('session-action-${action.id}'),
      dense: true,
      enabled: action.enabled,
      leading: Icon(action.icon, size: 22),
      title: Text(action.label),
      subtitle: action.subtitle == null
          ? null
          : Text(action.subtitle!, style: const TextStyle(fontSize: 12)),
      trailing: selected == null
          ? null
          : Switch(
              value: selected,
              onChanged: action.enabled ? (_) => onAction(action.id) : null,
            ),
      onTap: action.enabled ? () => onAction(action.id) : null,
    );
  }
}
