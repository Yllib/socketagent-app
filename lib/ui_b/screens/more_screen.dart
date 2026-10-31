import 'package:flutter/material.dart';

import '../../ui_variant.dart';
import '../model/actions.dart';
import '../theme/ui_b_theme.dart';
import '../widgets/primitives.dart';

/// Theme, text size, the interface switch, and the doors to everything this
/// interface has not wired yet. Each stub sits where it will live.
class MoreScreen extends StatelessWidget {
  const MoreScreen({
    super.key,
    required this.themes,
    required this.actions,
    this.header,
    this.counts = const {},
  });
  final UiBThemeController themes;
  final UiBActions actions;
  final Widget? header;

  /// Badge counts for stub rows, by label.
  final Map<String, int> counts;

  @override
  Widget build(BuildContext context) {
    final t = UiBTheme.of(context);
    final text = UiBText.of(context);
    return ListView(
      padding: const EdgeInsets.only(bottom: 80),
      children: [
        ?header,
        const SectionHeader('Theme'),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
          child: Row(
            children: [
              for (final id in UiBThemeId.values) ...[
                _swatch(
                  context,
                  UiBTheme.byId(id),
                  on: themes.theme.id == id,
                  onTap: () => themes.setTheme(id),
                ),
                const SizedBox(width: 8),
              ],
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
          child: Row(
            children: [
              Text('text size', style: text.meta),
              const SizedBox(width: 10),
              for (final s in const [0.9, 1.0, 1.15, 1.3]) ...[
                InkWell(
                  onTap: () => themes.setTextScale(s),
                  borderRadius: BorderRadius.circular(4),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: (themes.textScale - s).abs() < 0.01
                          ? t.accent.withValues(alpha: 0.18)
                          : null,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      '${(s * 100).round()}%',
                      style: text.meta.copyWith(
                        color: (themes.textScale - s).abs() < 0.01
                            ? t.accent
                            : t.text2,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 2),
              ],
            ],
          ),
        ),
        const SectionHeader('Interface'),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
          child: Row(
            children: [
              for (final v in UiVariant.values) ...[
                FlatButton(
                  uiVariantLabel(v),
                  compact: true,
                  primary: v == UiVariant.b,
                  onPressed: v == UiVariant.b
                      ? null
                      : () => actions.setVariant(v),
                ),
                const SizedBox(width: 6),
              ],
              const Spacer(),
              Text('B is this one', style: text.meta),
            ],
          ),
        ),
        const SectionHeader('Not wired in B yet'),
        for (final (icon, label, hint) in const [
          (
            Icons.folder_outlined,
            'Files',
            'Browse and download files from a computer',
          ),
          (
            Icons.web,
            'Browser windows',
            'Watch and take over agent browser sessions',
          ),
          (Icons.article_outlined, 'Plans', 'HTML plans the agents wrote'),
          (
            Icons.rate_review_outlined,
            'Work reviews',
            'Approve or comment on finished work',
          ),
          (
            Icons.bookmark_border,
            'Memories',
            'What the agents remember about you',
          ),
          (Icons.mic_none, 'Voice', 'Wake word, dictation and read-aloud'),
          (
            Icons.qr_code_scanner,
            'Pair a computer',
            'Scan the code the server prints',
          ),
          (
            Icons.extension_outlined,
            'MCP servers',
            'Sign in to tools the agents use',
          ),
          (
            Icons.notifications_none,
            'Notifications',
            'Which sessions and events ping the phone',
          ),
          (
            Icons.manage_accounts_outlined,
            'Account',
            'Subscription, email and devices',
          ),
        ])
          InkWell(
            onTap: () {},
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 7, 12, 7),
              child: Row(
                children: [
                  Icon(icon, size: 16, color: t.text2),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          label,
                          style: text.body.copyWith(
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        Text(hint, style: text.meta),
                      ],
                    ),
                  ),
                  if ((counts[label] ?? 0) > 0) ...[
                    Text(
                      '${counts[label]}',
                      style: text.meta.copyWith(color: t.accent),
                    ),
                    const SizedBox(width: 8),
                  ],
                  const StubBadge(),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _swatch(
    BuildContext context,
    UiBTheme th, {
    required bool on,
    required VoidCallback onTap,
  }) {
    final t = UiBTheme.of(context);
    final text = UiBText.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(5),
      child: Container(
        width: 68,
        padding: const EdgeInsets.all(5),
        decoration: BoxDecoration(
          color: th.bg,
          border: Border.all(color: on ? t.accent : t.line, width: on ? 2 : 1),
          borderRadius: BorderRadius.circular(5),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(width: 10, height: 10, color: th.accent),
                const SizedBox(width: 3),
                Container(width: 10, height: 10, color: th.running),
                const SizedBox(width: 3),
                Container(width: 10, height: 10, color: th.waiting),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              uiBThemeLabel(th.id),
              style: text.meta.copyWith(color: th.text),
            ),
          ],
        ),
      ),
    );
  }
}
