import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../ui_variant.dart';
import 'bits.dart';
import 'data.dart';
import 'theme.dart';

/// Everything outside a session: interface and theme, computers,
/// automations, and the tools that act on a computer directly.
class Station extends StatelessWidget {
  const Station({super.key, required this.themes, this.onClose});

  final TowerThemeController themes;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final p = Tw.of(context);
    final data = context.watch<TowerData>();
    final variants = context.watch<UiVariantController>();
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: Column(
          children: [
            Container(
              height: 54,
              decoration: BoxDecoration(border: Border(bottom: BorderSide(color: p.line))),
              child: Row(
                children: [
                  IconButton(
                    onPressed: onClose ?? () => Navigator.maybePop(context),
                    icon: Icon(Icons.arrow_back, size: 20, color: p.text),
                  ),
                  Text('Station', style: Ts.title(p).copyWith(fontSize: 16)),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.only(bottom: 32),
                children: [
                  const SectionLabel('Interface'),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    child: Row(
                      children: [
                        for (final v in UiVariant.values)
                          Expanded(
                            child: InkWell(
                              onTap: () => variants.setVariant(v),
                              child: Container(
                                height: 40,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: variants.variant == v ? p.accent : null,
                                  border: Border.all(color: variants.variant == v ? p.accent : p.line),
                                ),
                                child: Text(
                                  uiVariantLabel(v),
                                  style: TextStyle(
                                    fontWeight: FontWeight.w700,
                                    color: variants.variant == v ? p.bg : p.text,
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SectionLabel('Theme'),
                  _ThemePicker(themes: themes),
                  SectionLabel('Computers', count: data.computers.length),
                  for (final c in data.computers) _ComputerRow(computer: c),
                  _StubRow(icon: Icons.add, label: 'Add a computer', page: _stubPairing),
                  SectionLabel(
                    'Automations',
                    count: data.scheduledTasks.length,
                    color: data.unreadScheduledTaskCount > 0 ? p.done : null,
                    trailing: data.unreadScheduledTaskCount > 0
                        ? Text('${data.unreadScheduledTaskCount} new', style: Ts.mono(p, color: p.done, size: 11))
                        : null,
                  ),
                  for (final t in data.scheduledTasks.take(30)) _TaskRow(task: t),
                  _StubRow(icon: Icons.add_alarm, label: 'Schedule a task', page: _stubSchedule),
                  if (data.pendingDevices.isNotEmpty) ...[
                    SectionLabel('Devices waiting', count: data.pendingDevices.length, color: p.wait),
                    for (final d in data.pendingDevices)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
                        child: Row(
                          children: [
                            Expanded(child: Text('${d.name}  ${d.code}', style: Ts.body(p))),
                            Act('Deny', dense: true, color: p.fail, onTap: () => data.denyDevice(d)),
                            const SizedBox(width: 6),
                            Act('Approve', dense: true, filled: true, color: p.wait, onTap: () => data.approveDevice(d)),
                          ],
                        ),
                      ),
                  ],
                  const SectionLabel('On a computer'),
                  _StubRow(icon: Icons.folder_outlined, label: 'Files', page: _stubFiles),
                  _StubRow(icon: Icons.web_asset, label: 'Browser windows', page: _stubBrowser),
                  _StubRow(icon: Icons.terminal, label: 'Terminal', page: _stubTerminal),
                  _StubRow(icon: Icons.key, label: 'Secrets', page: _stubSecrets),
                  _StubRow(icon: Icons.fact_check_outlined, label: 'Work reviews', page: _stubReviews),
                  _StubRow(icon: Icons.download_outlined, label: 'Received files', page: _stubReceived),
                  _StubRow(icon: Icons.archive_outlined, label: 'Archived sessions', page: _stubArchive),
                  _StubRow(icon: Icons.history, label: 'Native harness history', page: _stubArchive),
                  _StubRow(icon: Icons.extension_outlined, label: 'Skills and plugins', page: _stubSkills),
                  _StubRow(icon: Icons.settings_applications_outlined, label: 'Config files', page: _stubConfig),
                  _StubRow(icon: Icons.shield_outlined, label: 'Protected files', page: _stubConfig),
                  const SectionLabel('This device'),
                  _StubRow(icon: Icons.notifications_none, label: 'Alerts per computer', page: _stubAlerts),
                  _StubRow(icon: Icons.mic_none, label: 'Voice and dictation', page: _stubVoice),
                  _StubRow(icon: Icons.link, label: 'Linked computers', page: _stubLinks),
                  _StubRow(icon: Icons.hub_outlined, label: 'AI connector', page: _stubLinks),
                  _StubRow(icon: Icons.devices_other, label: 'Devices', page: _stubDevices),
                  _StubRow(icon: Icons.account_circle_outlined, label: 'Account and relay', page: _stubAccount),
                  _StubRow(icon: Icons.send_to_mobile_outlined, label: 'Move to another device', page: _stubAccount),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ThemePicker extends StatelessWidget {
  const _ThemePicker({required this.themes});
  final TowerThemeController themes;

  @override
  Widget build(BuildContext context) {
    final p = Tw.of(context);
    return ListenableBuilder(
      listenable: themes,
      builder: (context, _) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Row(
          children: [
            for (final t in towerPalettes)
              Expanded(
                child: InkWell(
                  onTap: () => themes.select(t),
                  child: Container(
                    height: 64,
                    margin: const EdgeInsets.only(right: 6),
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: t.bg,
                      border: Border.all(
                        color: themes.palette.id == t.id ? p.accent : p.line,
                        width: themes.palette.id == t.id ? 2 : 1,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(t.name, style: TextStyle(color: t.text, fontWeight: FontWeight.w600, fontSize: 12)),
                        const Spacer(),
                        Row(
                          children: [
                            for (final c in [t.run, t.wait, t.done, t.accent])
                              Container(width: 10, height: 10, margin: const EdgeInsets.only(right: 3), color: c),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ComputerRow extends StatelessWidget {
  const _ComputerRow({required this.computer});
  final TowerComputer computer;

  @override
  Widget build(BuildContext context) {
    final p = Tw.of(context);
    final data = context.watch<TowerData>();
    final c = computer;
    final running = data.sessions.where((s) => s.serverId == c.id && data.liveOf(s) != Live.idle).length;
    final total = data.sessions.where((s) => s.serverId == c.id).length;
    final status = switch (c.status) {
      ConnectionStatus.connected => c.relay ? 'relay' : 'direct',
      ConnectionStatus.connecting => 'connecting',
      ConnectionStatus.error => 'error',
      ConnectionStatus.disconnected => c.expectedOnline ? 'offline, expected online' : 'offline',
    };
    final warn = !c.online && c.expectedOnline;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 9, 14, 9),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: p.line))),
      child: Row(
        children: [
          LiveMark(color: c.online ? computerColor(p, c.color) : (warn ? p.wait : p.muted), hollow: !c.online),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(c.name, style: Ts.title(p)),
                const SizedBox(height: 2),
                Text(
                  [status, '$total sessions', c.pushRegistered ? 'alerts on' : 'alerts off'].join('  '),
                  style: Ts.mono(p, color: warn ? p.wait : p.muted, size: 11),
                ),
              ],
            ),
          ),
          if (running > 0) Text('$running live', style: Ts.mono(p, color: p.run, size: 12)),
        ],
      ),
    );
  }
}

class _TaskRow extends StatelessWidget {
  const _TaskRow({required this.task});
  final Map<String, dynamic> task;

  @override
  Widget build(BuildContext context) {
    final p = Tw.of(context);
    final data = context.read<TowerData>();
    final id = (task['id'] ?? task['taskId'] ?? '').toString();
    final name = (task['name'] ?? task['prompt'] ?? 'Task').toString();
    final status = (task['status'] ?? '').toString();
    final recurrence = (task['recurrence'] is Map ? (task['recurrence'] as Map)['type'] : task['recurrence'])?.toString() ?? 'once';
    final runs = (task['runCount'] as num?)?.toInt();
    final unread = task['lastRunAt'] != null &&
        (task['lastReadAt'] == null ||
            (task['lastReadAt'].toString().compareTo(task['lastRunAt'].toString()) < 0));
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(color: unread ? p.done : Colors.transparent, width: 3),
          bottom: BorderSide(color: p.line),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: Ts.title(p).copyWith(fontWeight: unread ? FontWeight.w700 : FontWeight.w500)),
                const SizedBox(height: 2),
                Text(
                  [recurrence, status, if (runs != null) '$runs runs'].where((s) => s.isNotEmpty).join('  '),
                  style: Ts.mono(p, size: 11),
                ),
              ],
            ),
          ),
          if (unread)
            IconButton(
              tooltip: 'Mark read',
              onPressed: id.isEmpty ? null : () => data.markScheduledTaskRead(id),
              icon: Icon(Icons.done, size: 17, color: p.done),
            ),
          IconButton(
            tooltip: 'Run now',
            onPressed: id.isEmpty ? null : () => data.runScheduledTask(id),
            icon: Icon(Icons.play_arrow, size: 18, color: p.accent),
          ),
        ],
      ),
    );
  }
}

class _StubRow extends StatelessWidget {
  const _StubRow({required this.icon, required this.label, required this.page});
  final IconData icon;
  final String label;
  final StubSpec page;

  @override
  Widget build(BuildContext context) {
    final p = Tw.of(context);
    return InkWell(
      onTap: () => pushTower<void>(context, StubPage(title: label, spec: page)),
      child: Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: p.line))),
        child: Row(
          children: [
            Icon(icon, size: 18, color: p.muted),
            const SizedBox(width: 12),
            Expanded(child: Text(label, style: Ts.body(p))),
            const NotWired(),
            const SizedBox(width: 6),
            Icon(Icons.chevron_right, size: 16, color: p.muted),
          ],
        ),
      ),
    );
  }
}

/// Sample content for a not-yet-wired screen: rows of (label, meta, tag).
class StubSpec {
  const StubSpec(this.rows, {this.actions = const []});
  final List<(String, String, String)> rows;
  final List<String> actions;
}

const _stubFiles = StubSpec([
  ('..', 'parent', ''),
  ('lib', 'folder  42 items', 'Oct 30'),
  ('server', 'folder  18 items', 'Oct 31'),
  ('pubspec.yaml', '3.1 KB', 'Oct 29'),
  ('README.md', '8.4 KB  protected', 'Oct 12'),
  ('release.apk', '61 MB', 'Oct 31'),
], actions: ['Upload', 'New folder', 'Show hidden']);
const _stubBrowser = StubSpec([
  ('Play Console', 'play.google.com  profile play-console', 'watching'),
  ('Cloudflare', 'dash.cloudflare.com  profile cloudflare', 'idle'),
  ('QuickBooks', 'app.qbo.intuit.com  profile qbo', 'closed'),
], actions: ['New window', 'Profiles']);
const _stubTerminal = StubSpec([
  (r'$ git status', 'mac-mini  ~/agents/socketagent', ''),
  ('On branch master', '', ''),
], actions: ['Ctrl', 'Esc', 'Tab', '↑', '↓']);
const _stubSecrets = StubSpec([
  ('GITHUB_TOKEN', 'project  socketagent', 'Oct 2'),
  ('CLOUDFLARE_API_KEY', 'computer', 'Sep 18'),
  ('PLAY_SERVICE_JSON', 'project  app', 'Aug 30'),
], actions: ['Add secret']);
const _stubReviews = StubSpec([
  ('Release 1.0.299 checklist', '4 of 9 decided', 'open'),
  ('Relay pricing copy', '6 of 6', 'completed'),
]);
const _stubReceived = StubSpec([
  ('app-release.apk', '61 MB  from Release build', 'downloaded'),
  ('report.pdf', '1.2 MB  from Invoices', 'on computer'),
]);
const _stubArchive = StubSpec([
  ('Fix relay reconnect', 'mac-mini  codex  412 messages', 'Oct 20'),
  ('Invoice export', 'win-desk  claude  88 messages', 'Oct 11'),
], actions: ['Newest', 'Oldest', 'Most messages']);
const _stubSkills = StubSpec([
  ('deploy', 'skill  user', 'claude'),
  ('review', 'command  project', 'codex'),
], actions: ['New skill', 'Marketplaces']);
const _stubConfig = StubSpec([
  ('~/.claude/settings.json', 'json  2.1 KB', 'claude'),
  ('~/.codex/config.toml', 'toml  0.8 KB', 'codex'),
]);
const _stubAlerts = StubSpec([
  ('mac-mini', 'relay  registered', 'on'),
  ('win-desk', 'direct  token missing', 'retry'),
]);
const _stubVoice = StubSpec([
  ('Dictation model', 'moonshine base  58 MB', 'downloaded'),
  ('Read replies aloud', 'device voice  1.0x', 'off'),
  ('Live call with Codex', 'voice alloy', ''),
]);
const _stubLinks = StubSpec([
  ('win-desk', 'read  commands  agents  ask each time', 'online'),
  ('nas', 'read', 'offline'),
], actions: ['Link a computer']);
const _stubDevices = StubSpec([
  ('Pixel 9', 'phone  this device', 'online'),
  ('ThinkPad', 'desktop', 'last seen 2h'),
], actions: ['Reset pairing code']);
const _stubAccount = StubSpec([
  ('Relay', 'active  renews Nov 30', ''),
  ('Vault sync', 'synced 4m ago', ''),
  ('Recovery key', 'confirmed', ''),
]);
const _stubPairing = StubSpec([
  ('Linux / macOS', 'curl -fsSL https://socketagent.dev/install | sh', 'copy'),
  ('Windows', 'irm https://socketagent.dev/install.ps1 | iex', 'copy'),
], actions: ['Scan code', 'Paste code', 'Direct address']);
const _stubSchedule = StubSpec([
  ('Name', 'Nightly health check', ''),
  ('When', 'daily 06:00', ''),
  ('Computer', 'mac-mini  codex', ''),
  ('Notify', 'on completion', ''),
], actions: ['Save']);

/// A finished-looking screen with sample rows and inert controls, clearly
/// marked as not wired.
class StubPage extends StatelessWidget {
  const StubPage({super.key, required this.title, required this.spec});
  final String title;
  final StubSpec spec;

  @override
  Widget build(BuildContext context) {
    final p = Tw.of(context);
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              height: 54,
              decoration: BoxDecoration(border: Border(bottom: BorderSide(color: p.line))),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.maybePop(context),
                    icon: Icon(Icons.arrow_back, size: 20, color: p.text),
                  ),
                  Expanded(child: Text(title, style: Ts.title(p).copyWith(fontSize: 16))),
                  const NotWired(),
                  const SizedBox(width: 14),
                ],
              ),
            ),
            Expanded(
              child: IgnorePointer(
                child: Opacity(
                  opacity: 0.6,
                  child: ListView(
                    children: [
                      if (spec.actions.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [for (final a in spec.actions) Act(a, dense: true, onTap: () {})],
                          ),
                        ),
                      for (final r in spec.rows)
                        Container(
                          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: p.line))),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(r.$1, style: Ts.title(p)),
                                    if (r.$2.isNotEmpty) Text(r.$2, style: Ts.mono(p, size: 11)),
                                  ],
                                ),
                              ),
                              Text(r.$3, style: Ts.mono(p, size: 11.5)),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
