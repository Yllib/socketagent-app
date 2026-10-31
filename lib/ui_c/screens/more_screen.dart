import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/device_registry.dart';
import '../../models/scheduled_task_unread.dart';
import '../../models/work_review.dart';
import '../shell/ui_c_nav.dart';
import '../shell/ui_c_shell.dart';
import '../state/ui_c_models.dart';
import '../state/ui_c_store.dart';
import '../theme/ui_c_theme.dart';
import '../widgets/primitives.dart';

export '../shell/ui_c_nav.dart' show MorePage;

void openMore(BuildContext context, MorePage page) =>
    context.read<UiCNav>().openMore(page);

/// Everything that is not the board, the list or a session. Automations,
/// reviews, secrets and computers read live data. The rest are drawn where
/// they will live and marked as not wired.
class MoreScreen extends StatelessWidget {
  const MoreScreen({super.key, this.desktop = false});

  final bool desktop;

  @override
  Widget build(BuildContext context) {
    final nav = context.watch<UiCNav>();
    return ValueListenableBuilder<MorePage>(
      valueListenable: nav.morePage,
      builder: (context, page, _) {
        if (desktop) {
          return Row(
            children: [
              SizedBox(width: 220, child: _Index(current: page)),
              Container(width: 1, color: context.c.line),
              Expanded(
                child: _Page(
                  page: page == MorePage.home ? MorePage.settings : page,
                ),
              ),
            ],
          );
        }
        if (page == MorePage.home) return _Index(current: page);
        return Column(
          children: [
            Container(
              height: 40,
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: context.c.line)),
              ),
              child: Row(
                children: [
                  IconTap(
                    Icons.arrow_back,
                    onTap: () => nav.morePage.value = MorePage.home,
                  ),
                  Text(
                    page.label,
                    style: UiCFonts.condensed(
                      size: 15,
                      weight: FontWeight.w700,
                      color: context.c.text,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(child: _Page(page: page)),
          ],
        );
      },
    );
  }
}

const _wired = {
  MorePage.automations,
  MorePage.reviews,
  MorePage.secrets,
  MorePage.computers,
  MorePage.settings,
};

class _Index extends StatelessWidget {
  const _Index({required this.current});
  final MorePage current;

  @override
  Widget build(BuildContext context) {
    final nav = context.read<UiCNav>();
    final store = context.watch<UiCStore>();
    final c = context.c;
    int? badge(MorePage page) => switch (page) {
      MorePage.automations => store.unreadAutomationResults,
      MorePage.reviews => store.openReviews,
      MorePage.secrets => store.secrets.length,
      MorePage.computers => store.computers.length,
      _ => null,
    };
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        for (final page in MorePage.values)
          if (page != MorePage.home)
            HairRow(
              selected: page == current,
              onTap: () => nav.morePage.value = page,
              child: Row(
                children: [
                  Icon(page.icon, size: 17, color: c.textDim),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      page.label,
                      style: UiCFonts.condensed(size: 14, color: c.text),
                    ),
                  ),
                  if (badge(page) case final count? when count > 0)
                    Text(
                      '$count',
                      style: UiCFonts.mono(size: 11.5, color: c.textDim),
                    ),
                  if (!_wired.contains(page)) ...[
                    const SizedBox(width: 8),
                    const StubBadge(),
                  ],
                  const SizedBox(width: 4),
                  Icon(Icons.chevron_right, size: 16, color: c.textFaint),
                ],
              ),
            ),
        const SizedBox(height: 16),
        const SectionHead('Interface'),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 12),
          child: InterfaceSwitch(expanded: true),
        ),
      ],
    );
  }
}

class _Page extends StatelessWidget {
  const _Page({required this.page});
  final MorePage page;

  @override
  Widget build(BuildContext context) => switch (page) {
    MorePage.automations => const _Automations(),
    MorePage.reviews => const _Reviews(),
    MorePage.secrets => const _Secrets(),
    MorePage.computers => const _Computers(),
    MorePage.settings => const _Settings(),
    MorePage.files => const _StubList(
      title: 'Received files',
      lines: [
        'app-release.apk  48.2 MB  Build v1.0.299  2h ago',
        'report.pdf  1.1 MB  Weekly digest  yesterday',
      ],
      actions: ['Open', 'Reveal', 'Re-download'],
    ),
    MorePage.browsers => const _StubList(
      title: 'Browser windows',
      lines: [
        'Play Console  profile play-console  Release review',
        'Cloudflare  profile cloudflare  DNS cleanup',
      ],
      actions: ['Watch', 'Take over', 'Close'],
    ),
    MorePage.plans => const _StubList(
      title: 'HTML plans',
      lines: [
        'Forms map view  3 revisions  Oct 28',
        'Billing redesign  7 revisions  Oct 12',
      ],
      actions: ['Read', 'Diff', 'Export'],
    ),
    MorePage.terminal => const _StubList(
      title: 'Terminal',
      lines: ['agent-dev  bash  attached 0 sessions'],
      actions: ['Open shell'],
    ),
    MorePage.memories => const _StubList(
      title: 'Memories',
      lines: [
        'feedback  prefer-plain-prose  edited Oct 20',
        'project  release-cadence  created Oct 3',
      ],
      actions: ['Edit', 'Restore'],
    ),
    MorePage.home => const SizedBox.shrink(),
  };
}

class _StubList extends StatelessWidget {
  const _StubList({
    required this.title,
    required this.lines,
    required this.actions,
  });
  final String title;
  final List<String> lines;
  final List<String> actions;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Column(
      children: [
        const StubNotice(),
        Expanded(
          child: ListView(
            children: [
              SectionHead(title, count: lines.length),
              for (final line in lines)
                HairRow(
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          line,
                          style: UiCFonts.mono(size: 12, color: c.textDim),
                        ),
                      ),
                      for (final action in actions)
                        Padding(
                          padding: const EdgeInsets.only(left: 4),
                          child: Tag(action.toUpperCase(), color: c.textFaint),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Automations extends StatelessWidget {
  const _Automations();

  @override
  Widget build(BuildContext context) {
    final store = context.watch<UiCStore>();
    final nav = context.read<UiCNav>();
    final c = context.c;
    final tasks = store.scheduledTasks
        .where((t) => !scheduledTaskIsArchived(t))
        .toList();
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        SectionHead(
          'Scheduled tasks',
          count: tasks.length,
          trailing: Row(
            children: [
              Tag('NEW TASK', color: c.textFaint),
              const SizedBox(width: 4),
              const StubBadge(),
            ],
          ),
        ),
        if (tasks.isEmpty) const EmptyLine('No scheduled tasks'),
        for (final task in tasks) _TaskRow(task: task, store: store, nav: nav),
      ],
    );
  }
}

class _TaskRow extends StatelessWidget {
  const _TaskRow({required this.task, required this.store, required this.nav});
  final Map<String, dynamic> task;
  final UiCStore store;
  final UiCNav nav;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final unread = scheduledTaskHasUnreadResult(task);
    final recurrence = task['recurrence'];
    final recurrenceLabel = recurrence is Map
        ? (recurrence['type']?.toString() ?? 'once')
        : 'once';
    final status = task['status']?.toString() ?? '';
    final runCount = (task['runCount'] as num?)?.toInt() ?? 0;
    final lastRun = DateTime.tryParse(task['lastRunAt']?.toString() ?? '');
    final nextRun = DateTime.tryParse(
      (task['nextRunAt'] ?? task['scheduledAt'] ?? task['runAt'])?.toString() ??
          '',
    );
    final computer = store.computer(
      task['_serverId']?.toString() ?? task['serverId']?.toString() ?? '',
    );
    final sessionId = task['sessionId']?.toString() ?? '';
    final summary =
        (task['lastResultSummary'] ??
                task['resultSummary'] ??
                task['summary'] ??
                '')
            .toString();
    return HairRow(
      bar: unread ? c.ok : null,
      onTap: () {
        if (unread) store.markTaskRead(task);
        if (sessionId.isNotEmpty) {
          nav.openSessionById(sessionId, serverId: computer?.id);
        }
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  task['name']?.toString() ?? 'Task',
                  style: UiCFonts.prose(
                    size: 13.5,
                    weight: unread ? FontWeight.w600 : FontWeight.w400,
                    color: c.text,
                  ),
                ),
              ),
              Tag(recurrenceLabel.toUpperCase(), color: c.textDim),
              const SizedBox(width: 4),
              Tag(
                status.toUpperCase(),
                color: switch (status) {
                  'failed' => c.danger,
                  'running' => c.accent,
                  'completed' => c.ok,
                  _ => c.textFaint,
                },
              ),
            ],
          ),
          const SizedBox(height: 3),
          Row(
            children: [
              if (computer != null) ...[
                ComputerMark(
                  name: computer.name,
                  color: computer.color,
                  connected: computer.isConnected,
                ),
                const SizedBox(width: 8),
              ],
              Text(
                '$runCount runs'
                '${lastRun != null ? '  last ${relativeTime(lastRun)}' : ''}'
                '${nextRun != null && nextRun.isAfter(DateTime.now()) ? '  next ${relativeTime(nextRun)}' : ''}',
                style: UiCFonts.condensed(size: 11.5, color: c.textDim),
              ),
              const Spacer(),
              if (unread) Tag('UNREAD', color: c.ok),
            ],
          ),
          if (summary.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(
                summary,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: UiCFonts.prose(size: 12, color: c.textDim),
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
              children: [
                if (sessionId.isNotEmpty)
                  CButton(
                    'Open result',
                    dense: true,
                    onTap: () {
                      store.markTaskRead(task);
                      nav.openSessionById(sessionId, serverId: computer?.id);
                    },
                  ),
                const SizedBox(width: 6),
                Tag('RUN NOW', color: c.textFaint),
                const SizedBox(width: 4),
                Tag('EDIT', color: c.textFaint),
                const SizedBox(width: 4),
                const StubBadge(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Reviews extends StatelessWidget {
  const _Reviews();

  @override
  Widget build(BuildContext context) {
    final store = context.watch<UiCStore>();
    final nav = context.read<UiCNav>();
    final c = context.c;
    final reviews = store.reviews;
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        SectionHead('Work reviews', count: reviews.length),
        if (reviews.isEmpty) const EmptyLine('No reviews'),
        for (final review in reviews)
          HairRow(
            bar: review.status == WorkReviewStatus.open ? c.warn : null,
            onTap: () => _openReview(context, review),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        review.title,
                        style: UiCFonts.prose(
                          size: 13.5,
                          weight: FontWeight.w500,
                          color: c.text,
                        ),
                      ),
                    ),
                    Tag(
                      review.status.name.toUpperCase(),
                      color: review.status == WorkReviewStatus.open
                          ? c.warn
                          : c.textFaint,
                    ),
                  ],
                ),
                if (review.summary.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      review.summary,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: UiCFonts.prose(size: 12, color: c.textDim),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Row(
                    children: [
                      if (store.computer(review.serverId) case final computer?)
                        ComputerMark(
                          name: computer.name,
                          color: computer.color,
                          connected: computer.isConnected,
                        ),
                      const SizedBox(width: 8),
                      Text(
                        '${review.items.length} items  ${relativeTime(review.updatedAt)}',
                        style: UiCFonts.condensed(size: 11.5, color: c.textDim),
                      ),
                      const Spacer(),
                      if (review.sessionId.isNotEmpty)
                        Tag(
                          'SESSION',
                          color: c.textDim,
                          onTap: () => nav.openSessionById(
                            review.sessionId,
                            serverId: review.serverId,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  void _openReview(BuildContext context, WorkReview review) {
    final c = context.c;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const StubNotice(
              text: 'Review items, decisions and finish are not wired yet.',
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    review.title,
                    style: UiCFonts.condensed(
                      size: 15,
                      weight: FontWeight.w700,
                      color: c.text,
                    ),
                  ),
                  if (review.summary.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      review.summary,
                      style: UiCFonts.prose(size: 13, color: c.textDim),
                    ),
                  ],
                  const SizedBox(height: 10),
                  for (final item in review.items.take(8))
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(
                        children: [
                          Icon(
                            Icons.check_box_outline_blank,
                            size: 14,
                            color: c.textFaint,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              item.title,
                              style: UiCFonts.prose(size: 13, color: c.text),
                            ),
                          ),
                          Tag('APPROVE', color: c.textFaint),
                          const SizedBox(width: 4),
                          Tag('CHANGES', color: c.textFaint),
                        ],
                      ),
                    ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const StubBadge(),
                      const Spacer(),
                      Tag('FINISH REVIEW', color: c.textFaint),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Secrets extends StatelessWidget {
  const _Secrets();

  @override
  Widget build(BuildContext context) {
    final store = context.watch<UiCStore>();
    final c = context.c;
    final secrets = store.secrets;
    final scopes = ['session', 'project', 'global'];
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
          child: Text(
            'Values never show here. Each row is a label, a scope and the variable the agent reads it from.',
            style: UiCFonts.condensed(size: 12, color: c.textDim),
          ),
        ),
        for (final scope in scopes) ...[
          SectionHead(
            switch (scope) {
              'session' => 'This session',
              'project' => 'This project',
              _ => 'Whole computer',
            },
            count: secrets.where((s) => s.scope == scope).length,
            trailing: scope == 'session'
                ? Row(
                    children: [
                      Tag('ADD', color: c.textFaint),
                      const SizedBox(width: 4),
                      const StubBadge(),
                    ],
                  )
                : null,
          ),
          if (secrets.where((s) => s.scope == scope).isEmpty)
            const EmptyLine('None'),
          for (final secret in secrets.where((s) => s.scope == scope))
            HairRow(
              child: Row(
                children: [
                  Icon(Icons.key_outlined, size: 15, color: c.textDim),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          secret.label,
                          style: UiCFonts.prose(size: 13.5, color: c.text),
                        ),
                        Text(
                          '${secret.envHint.isNotEmpty ? '${secret.envHint}  ' : ''}'
                          'added ${relativeTime(secret.createdAt)}',
                          style: UiCFonts.mono(size: 10.5, color: c.textFaint),
                        ),
                      ],
                    ),
                  ),
                  CButton(
                    'Attach',
                    dense: true,
                    onTap: () => store.attachSecret(secret),
                  ),
                  const SizedBox(width: 4),
                  Tag('REPLACE', color: c.textFaint),
                  const SizedBox(width: 4),
                  Tag('DELETE', color: c.textFaint),
                ],
              ),
            ),
        ],
      ],
    );
  }
}

class _Computers extends StatelessWidget {
  const _Computers();

  @override
  Widget build(BuildContext context) {
    final store = context.watch<UiCStore>();
    final c = context.c;
    final devices = store.inbox
        .where((item) => item.kind == InboxKind.device)
        .toList();
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        SectionHead(
          'Computers',
          count: store.computers.length,
          trailing: Row(
            children: [
              Tag('ADD COMPUTER', color: c.textFaint),
              const SizedBox(width: 4),
              const StubBadge(),
            ],
          ),
        ),
        for (final computer in store.computers)
          HairRow(
            bar: computer.color,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        computer.name,
                        style: UiCFonts.condensed(
                          size: 14,
                          weight: FontWeight.w700,
                          color: c.text,
                        ),
                      ),
                    ),
                    Tag(
                      switch (computer.link) {
                        LinkState.connected => 'CONNECTED',
                        LinkState.connecting => 'CONNECTING',
                        LinkState.error => 'ERROR',
                        LinkState.offline => 'OFFLINE',
                      },
                      color: switch (computer.link) {
                        LinkState.connected => c.ok,
                        LinkState.connecting => c.accent,
                        LinkState.error => c.danger,
                        LinkState.offline =>
                          computer.expectedOnline ? c.danger : c.textFaint,
                      },
                      filled: computer.isConnected,
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    for (final harness in computer.harnesses)
                      Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: HarnessTag(harness),
                      ),
                    if (computer.version.isNotEmpty)
                      Text(
                        'v${computer.version}',
                        style: UiCFonts.mono(size: 11, color: c.textFaint),
                      ),
                    const SizedBox(width: 8),
                    Text(
                      '${computer.running} running',
                      style: UiCFonts.condensed(
                        size: 11.5,
                        color: computer.running > 0 ? c.accent : c.textFaint,
                      ),
                    ),
                    if (computer.issues > 0) ...[
                      const SizedBox(width: 8),
                      Tag('${computer.issues} ISSUES', color: c.warn),
                    ],
                  ],
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  children: [
                    for (final label in [
                      'DEVICES',
                      'LINKS',
                      'ALERTS',
                      'HEALTH',
                      'FILES',
                      'SETTINGS',
                    ])
                      Tag(label, color: c.textFaint),
                    const StubBadge(),
                  ],
                ),
              ],
            ),
          ),
        if (devices.isNotEmpty) ...[
          SectionHead(
            'Devices waiting to pair',
            count: devices.length,
            color: c.warn,
          ),
          for (final item in devices)
            HairRow(
              bar: c.warn,
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.title,
                          style: UiCFonts.prose(size: 13.5, color: c.text),
                        ),
                        Text(
                          item.detail,
                          style: UiCFonts.mono(size: 11, color: c.textDim),
                        ),
                      ],
                    ),
                  ),
                  if (item.payload case final PendingDevice device) ...[
                    CButton(
                      'Approve',
                      dense: true,
                      primary: true,
                      onTap: () => store.approveDevice(device),
                    ),
                    const SizedBox(width: 4),
                    CButton(
                      'Deny',
                      dense: true,
                      danger: true,
                      onTap: () => store.denyDevice(device),
                    ),
                  ],
                ],
              ),
            ),
        ],
      ],
    );
  }
}

class _Settings extends StatelessWidget {
  const _Settings();

  @override
  Widget build(BuildContext context) {
    final store = context.watch<UiCStore>();
    final themes = context.watch<UiCThemeController>();
    final c = context.c;
    Widget setting(
      String label,
      String hint,
      Widget control, {
      bool stub = false,
    }) => HairRow(
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: UiCFonts.prose(size: 13.5, color: c.text)),
                if (hint.isNotEmpty)
                  Text(
                    hint,
                    style: UiCFonts.condensed(size: 11.5, color: c.textDim),
                  ),
              ],
            ),
          ),
          control,
          if (stub) ...[const SizedBox(width: 6), const StubBadge()],
        ],
      ),
    );
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        const SectionHead('Look'),
        setting(
          'Theme',
          'Phosphor and Ice sit on black. Paper is light.',
          Wrap(
            spacing: 4,
            children: [
              for (final id in UiCThemeId.values)
                Tag(
                  id.label.toUpperCase(),
                  color: id == themes.id ? c.accent : c.textDim,
                  filled: id == themes.id,
                  onTap: () => themes.set(id),
                ),
            ],
          ),
        ),
        setting(
          'Interface',
          'Classic or one of the redesigns',
          const InterfaceSwitch(expanded: true),
        ),
        const SectionHead('Transcript'),
        setting(
          'Fold tool activity',
          'Runs of tool calls collapse to one line',
          Tag(
            store.condensedTools ? 'ON' : 'OFF',
            color: store.condensedTools ? c.accent : c.textDim,
            filled: store.condensedTools,
            onTap: () => store.setCondensedTools(!store.condensedTools),
          ),
        ),
        setting(
          'Sound when a run finishes',
          '',
          Tag('OFF', color: c.textFaint),
          stub: true,
        ),
        setting(
          'Cached transcripts',
          'Sessions kept on this device for offline reading',
          Tag('20', color: c.textFaint),
          stub: true,
        ),
        const SectionHead('Voice'),
        setting(
          'Dictation model',
          'On-device recognition',
          Tag('NONE', color: c.textFaint),
          stub: true,
        ),
        setting(
          'Read replies aloud',
          '',
          Tag('OFF', color: c.textFaint),
          stub: true,
        ),
        const SectionHead('Account'),
        setting(
          'Relay access',
          'Reach computers away from home',
          Tag('ACTIVE', color: c.textFaint),
          stub: true,
        ),
        setting(
          'Sync',
          'Computers, pins and projects across devices',
          Tag('SIGN IN', color: c.textFaint),
          stub: true,
        ),
        const SectionHead('Desktop'),
        setting(
          'Text size',
          'Ctrl + and Ctrl -',
          Tag('100%', color: c.textFaint),
          stub: true,
        ),
        setting('Hide to tray', '', Tag('OFF', color: c.textFaint), stub: true),
      ],
    );
  }
}
