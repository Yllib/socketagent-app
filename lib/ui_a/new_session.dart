import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'bits.dart';
import 'data.dart';
import 'theme.dart';

/// Picks computer, harness, folder and lifetime, then opens an empty
/// session. Nothing exists on the computer until the first message.
class NewSession extends StatefulWidget {
  const NewSession({super.key, required this.onStarted});

  final VoidCallback onStarted;

  @override
  State<NewSession> createState() => _NewSessionState();
}

class _NewSessionState extends State<NewSession> {
  String? _server;
  String? _backend;
  final _folder = TextEditingController();
  bool _fleeting = false;

  @override
  void initState() {
    super.initState();
    final data = context.read<TowerData>();
    final online = data.computers.where((c) => c.online).toList();
    _server =
        online.where((c) => c.id == data.openServerId).firstOrNull?.id ??
        online.firstOrNull?.id ??
        data.computers.firstOrNull?.id;
    _select(data, _server);
  }

  @override
  void dispose() {
    _folder.dispose();
    super.dispose();
  }

  void _select(TowerData data, String? server) {
    _server = server;
    if (server == null) return;
    data.refreshFolders(server);
    final backends = data.backendsFor(server);
    _backend = backends.contains(_backend) ? _backend : backends.firstOrNull;
    _folder.text = data.defaultFolder(server);
  }

  @override
  Widget build(BuildContext context) {
    final p = Tw.of(context);
    final data = context.watch<TowerData>();
    final computers = [...data.computers]
      ..sort((a, b) => (b.online ? 1 : 0).compareTo(a.online ? 1 : 0));
    final server = _server;
    final backends = server == null
        ? const <String>[]
        : data.backendsFor(server);
    final folders = server == null
        ? const <String>[]
        : data.recentFolders(server);
    final canStart =
        server != null &&
        _backend != null &&
        (data.computers.where((c) => c.id == server).firstOrNull?.online ??
            false);

    Widget choice(String label, bool on, VoidCallback? onTap, {Widget? lead}) =>
        InkWell(
          onTap: onTap,
          child: Container(
            height: 36,
            margin: const EdgeInsets.only(right: 6, bottom: 6),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: on ? p.accent.withValues(alpha: 0.15) : null,
              border: Border.all(color: on ? p.accent : p.line),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (lead != null) ...[lead, const SizedBox(width: 6)],
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    color: onTap == null ? p.muted : p.text,
                  ),
                ),
              ],
            ),
          ),
        );

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            const SectionLabel('Computer'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Wrap(
                children: [
                  for (final c in computers)
                    choice(
                      c.name,
                      c.id == server,
                      c.online
                          ? () => setState(() => _select(data, c.id))
                          : null,
                      lead: LiveMark(
                        color: c.online ? computerColor(p, c.color) : p.muted,
                        hollow: !c.online,
                      ),
                    ),
                ],
              ),
            ),
            const SectionLabel('Harness'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Wrap(
                children: [
                  for (final b in backends)
                    choice(
                      b,
                      b == _backend,
                      () => setState(() => _backend = b),
                    ),
                ],
              ),
            ),
            const SectionLabel('Folder'),
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 14),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(border: Border.all(color: p.line)),
              child: TextField(
                controller: _folder,
                style: Ts.mono(p, color: p.text, size: 13),
                decoration: const InputDecoration(
                  hintText: 'Computer default',
                  contentPadding: EdgeInsets.symmetric(vertical: 11),
                ),
              ),
            ),
            for (final f in folders.take(6))
              InkWell(
                onTap: () => setState(() => _folder.text = f),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: Row(
                    children: [
                      Icon(Icons.folder_outlined, size: 15, color: p.muted),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          f,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Ts.mono(
                            p,
                            color: _folder.text == f ? p.accent : p.muted,
                            size: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 4, 14, 0),
              child: Stubbed(
                child: Act('Browse folders', dense: true, onTap: () {}),
              ),
            ),
            const SectionLabel('Lifetime'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Row(
                children: [
                  choice(
                    'Permanent',
                    !_fleeting,
                    () => setState(() => _fleeting = false),
                  ),
                  choice(
                    'Fleeting, 6h idle',
                    _fleeting,
                    () => setState(() => _fleeting = true),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Act(
                'Open session',
                filled: true,
                onTap: canStart
                    ? () {
                        final folder = _folder.text.trim();
                        data.startDraft(
                          serverId: server,
                          backend: _backend!,
                          cwd: folder.isEmpty ? null : folder,
                          fleeting: _fleeting,
                        );
                        widget.onStarted();
                      }
                    : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
