import 'package:flutter/material.dart';

import '../model/actions.dart';
import '../model/board_model.dart';
import '../theme/ui_b_theme.dart';
import '../widgets/clock.dart';
import '../widgets/primitives.dart';

/// Computer, harness, folder, lifetime. The first message starts the session.
Future<void> showNewSessionSheet(
  BuildContext context,
  List<ComputerChip> computers,
  UiBActions actions, {
  String? serverId,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => uiBScoped(
      context,
      Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: NewSessionForm(
          computers: computers,
          actions: actions,
          initialServerId: serverId,
        ),
      ),
    ),
  );
}

class NewSessionForm extends StatefulWidget {
  const NewSessionForm({
    super.key,
    required this.computers,
    required this.actions,
    this.initialServerId,
  });
  final List<ComputerChip> computers;
  final UiBActions actions;
  final String? initialServerId;

  @override
  State<NewSessionForm> createState() => _NewSessionFormState();
}

class _NewSessionFormState extends State<NewSessionForm> {
  late String? _serverId =
      widget.initialServerId ??
      widget.computers.where((c) => c.online).firstOrNull?.id ??
      widget.computers.firstOrNull?.id;
  String? _harness;
  late final TextEditingController _cwd = TextEditingController(
    text: _computer?.defaultCwd ?? _computer?.recentCwds.firstOrNull ?? '',
  );
  bool _fleeting = false;

  ComputerChip? get _computer =>
      widget.computers.where((c) => c.id == _serverId).firstOrNull;

  @override
  void dispose() {
    _cwd.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = UiBTheme.of(context);
    final text = UiBText.of(context);
    final c = _computer;
    final backends = c?.backends ?? const ['claude'];
    final harness = backends.contains(_harness) ? _harness! : backends.first;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('NEW SESSION', style: text.micro),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final comp in widget.computers)
                _choice(
                  context,
                  comp.name,
                  on: comp.id == _serverId,
                  enabled: comp.online,
                  color: comp.color,
                  onTap: () => setState(() {
                    _serverId = comp.id;
                    _cwd.text =
                        comp.defaultCwd ?? comp.recentCwds.firstOrNull ?? '';
                  }),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              for (final b in backends) ...[
                _choice(
                  context,
                  b == 'codex' ? 'Codex' : 'Claude Code',
                  on: b == harness,
                  onTap: () => setState(() => _harness = b),
                ),
                const SizedBox(width: 6),
              ],
              const Spacer(),
              InkWell(
                onTap: () => setState(() => _fleeting = !_fleeting),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _fleeting
                          ? Icons.check_box_outlined
                          : Icons.check_box_outline_blank,
                      size: 16,
                      color: _fleeting ? t.accent : t.text3,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      'fleeting',
                      style: text.meta.copyWith(
                        color: _fleeting ? t.text : t.text2,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _cwd,
            style: text.code,
            decoration: const InputDecoration(
              hintText: 'Folder on the computer',
              isDense: true,
            ),
            onChanged: (_) => setState(() {}),
          ),
          if (c != null && c.recentCwds.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final cwd in c.recentCwds.take(8))
                    InkWell(
                      onTap: () => setState(() => _cwd.text = cwd),
                      child: Tag(
                        cwd.split('/').where((s) => s.isNotEmpty).lastOrNull ??
                            cwd,
                        color: cwd == _cwd.text ? t.accent : t.text3,
                      ),
                    ),
                ],
              ),
            ),
          const SizedBox(height: 12),
          Row(
            children: [
              Text(
                _fleeting
                    ? 'Deleted after a day idle'
                    : 'Kept until you archive it',
                style: text.meta,
              ),
              const Spacer(),
              FlatButton(
                'Start',
                primary: true,
                icon: Icons.arrow_forward,
                onPressed: c == null || !c.online
                    ? null
                    : () {
                        widget.actions.startNewSession(
                          serverId: c.id,
                          backend: harness,
                          cwd: _cwd.text.trim().isEmpty
                              ? null
                              : _cwd.text.trim(),
                          fleeting: _fleeting,
                        );
                        Navigator.of(context).maybePop();
                      },
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _choice(
    BuildContext context,
    String label, {
    required bool on,
    bool enabled = true,
    Color? color,
    required VoidCallback onTap,
  }) {
    final t = UiBTheme.of(context);
    final text = UiBText.of(context);
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(4),
      child: Container(
        padding: const EdgeInsets.fromLTRB(8, 5, 10, 5),
        decoration: BoxDecoration(
          color: on ? t.accent.withValues(alpha: 0.14) : t.raised,
          border: Border.all(color: on ? t.accent : t.line),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (color != null) ...[
              Container(
                width: 8,
                height: 8,
                color: enabled ? color : color.withValues(alpha: 0.4),
              ),
              const SizedBox(width: 6),
            ],
            Text(
              label,
              style: text.body.copyWith(
                color: enabled ? (on ? t.accent : t.text) : t.text3,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
