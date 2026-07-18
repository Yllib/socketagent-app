import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/html_plan.dart';
import '../services/chat_provider.dart';
import '../services/html_plan_export_service.dart';
import 'html_plan_viewer_screen.dart';

class HtmlPlanRevisionScreen extends StatefulWidget {
  const HtmlPlanRevisionScreen({super.key, required this.plan});

  final HtmlPlan plan;

  @override
  State<HtmlPlanRevisionScreen> createState() => _HtmlPlanRevisionScreenState();
}

class _HtmlPlanRevisionScreenState extends State<HtmlPlanRevisionScreen> {
  late Future<List<HtmlPlanRevisionSummary>> _future;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    _future = context.read<ChatProvider>().getHtmlPlanRevisions(widget.plan);
  }

  void _retry() => setState(_load);

  Future<void> _open(HtmlPlanRevisionSummary summary) async {
    final updated = await Navigator.of(context).push<HtmlPlan>(
      MaterialPageRoute(
        builder: (_) => HtmlPlanRevisionDetailScreen(
          plan: widget.plan,
          summary: summary,
        ),
      ),
    );
    if (updated != null && mounted) Navigator.of(context).pop(updated);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Revision history')),
      body: FutureBuilder<List<HtmlPlanRevisionSummary>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('${snapshot.error}', textAlign: TextAlign.center),
                    const SizedBox(height: 12),
                    FilledButton(onPressed: _retry, child: const Text('Retry')),
                  ],
                ),
              ),
            );
          }
          final revisions = snapshot.data ?? const [];
          return ListView.separated(
            itemCount: revisions.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final revision = revisions[index];
              final current = revision.revision == widget.plan.currentRevision;
              final original = revision.revision == 0;
              return ListTile(
                leading: CircleAvatar(
                  child: original
                      ? const Icon(Icons.add, size: 20)
                      : Text('${revision.revision}'),
                ),
                title: Row(
                  children: [
                    Expanded(
                      child: Text(
                        original ? 'Created' : 'Revision ${revision.revision}',
                      ),
                    ),
                    if (current)
                      const Chip(
                        label: Text('Current'),
                        visualDensity: VisualDensity.compact,
                      ),
                  ],
                ),
                subtitle: Text(
                  [
                    _formatDate(revision.createdAt),
                    _formatBytes(revision.byteSize),
                    if (revision.restoredFromRevision != null)
                      revision.restoredFromRevision == 0
                          ? 'Restored from original'
                          : 'Restored from revision ${revision.restoredFromRevision}',
                  ].join(' · '),
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _open(revision),
              );
            },
          );
        },
      ),
    );
  }
}

enum _RevisionView { changes, preview }

class HtmlPlanRevisionDetailScreen extends StatefulWidget {
  const HtmlPlanRevisionDetailScreen({
    super.key,
    required this.plan,
    required this.summary,
  });

  final HtmlPlan plan;
  final HtmlPlanRevisionSummary summary;

  @override
  State<HtmlPlanRevisionDetailScreen> createState() =>
      _HtmlPlanRevisionDetailScreenState();
}

class _HtmlPlanRevisionDetailScreenState
    extends State<HtmlPlanRevisionDetailScreen> {
  late Future<HtmlPlanRevisionDetail> _future;
  HtmlPlanRevisionDetail? _detail;
  _RevisionView _view = _RevisionView.changes;
  bool _rollingBack = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    _detail = null;
    _future = context
        .read<ChatProvider>()
        .getHtmlPlanRevision(widget.plan, widget.summary.revision)
        .then((detail) {
          if (mounted) setState(() => _detail = detail);
          return detail;
        });
  }

  Future<void> _export() async {
    final revision = _detail?.revision;
    if (revision == null) return;
    try {
      final path = await HtmlPlanExportService.export(
        title: revision.title,
        html: revision.html,
        revision: revision.revision,
      );
      if (path != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Exported revision ${revision.revision}')),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not export revision: $error')),
        );
      }
    }
  }

  Future<void> _share() async {
    final revision = _detail?.revision;
    if (revision == null) return;
    try {
      await HtmlPlanExportService.share(
        title: revision.title,
        html: revision.html,
        revision: revision.revision,
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not share revision: $error')),
        );
      }
    }
  }

  Future<void> _rollback() async {
    final revision = _detail?.revision;
    if (revision == null || revision.revision == widget.plan.currentRevision) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          revision.revision == 0
              ? 'Restore original plan?'
              : 'Restore revision ${revision.revision}?',
        ),
        content: const Text(
          'This keeps every existing revision and creates a new current revision from the selected version.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _rollingBack = true);
    try {
      final updated = await context.read<ChatProvider>().rollbackHtmlPlan(
        widget.plan,
        revision.revision,
      );
      if (mounted) Navigator.of(context).pop(updated);
    } catch (error) {
      if (mounted) {
        setState(() => _rollingBack = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not restore revision: $error')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.summary.revision == 0
              ? 'Created plan'
              : 'Revision ${widget.summary.revision}',
        ),
        actions: [
          IconButton(
            tooltip: 'Export HTML',
            onPressed: _detail == null ? null : _export,
            icon: const Icon(Icons.download_outlined),
          ),
          IconButton(
            tooltip: 'Share HTML',
            onPressed: _detail == null ? null : _share,
            icon: const Icon(Icons.share_outlined),
          ),
        ],
      ),
      body: FutureBuilder<HtmlPlanRevisionDetail>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError || !snapshot.hasData) {
            return Center(
              child: FilledButton(
                onPressed: () => setState(_load),
                child: Text('Retry: ${snapshot.error ?? 'revision unavailable'}'),
              ),
            );
          }
          final detail = snapshot.data!;
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
                child: SegmentedButton<_RevisionView>(
                  segments: const [
                    ButtonSegment(
                      value: _RevisionView.changes,
                      icon: Icon(Icons.difference_outlined),
                      label: Text('Changes'),
                    ),
                    ButtonSegment(
                      value: _RevisionView.preview,
                      icon: Icon(Icons.visibility_outlined),
                      label: Text('Preview'),
                    ),
                  ],
                  selected: {_view},
                  onSelectionChanged: (selection) =>
                      setState(() => _view = selection.first),
                ),
              ),
              Expanded(
                child: _view == _RevisionView.preview
                    ? HtmlPlanWebView(html: detail.revision.html)
                    : _DiffView(detail: detail),
              ),
              if (detail.revision.revision != widget.plan.currentRevision)
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _rollingBack ? null : _rollback,
                        icon: _rollingBack
                            ? const SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.restore),
                        label: Text(
                          _rollingBack
                              ? 'Restoring…'
                              : 'Restore as new revision',
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _DiffView extends StatelessWidget {
  const _DiffView({required this.detail});

  final HtmlPlanRevisionDetail detail;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            detail.baseRevision == null
                ? 'Original plan'
                : detail.baseRevision == 0
                ? 'Changes from original'
                : 'Changes from revision ${detail.baseRevision}',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(12),
            ),
            child: SelectableText.rich(
              TextSpan(
                children: detail.diff.map((segment) {
                  final added = segment.type == 'added';
                  final removed = segment.type == 'removed';
                  return TextSpan(
                    text: segment.text,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      backgroundColor: added
                          ? Colors.green.withValues(alpha: 0.28)
                          : removed
                          ? Colors.red.withValues(alpha: 0.28)
                          : Colors.transparent,
                      color: added
                          ? Colors.greenAccent.shade100
                          : removed
                          ? Colors.redAccent.shade100
                          : scheme.onSurfaceVariant,
                      decoration: removed ? TextDecoration.lineThrough : null,
                    ),
                  );
                }).toList(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _formatDate(DateTime value) {
  final local = value.toLocal();
  final hour = local.hour.toString().padLeft(2, '0');
  final minute = local.minute.toString().padLeft(2, '0');
  return '${local.month}/${local.day}/${local.year} $hour:$minute';
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  return '${(bytes / 1024).toStringAsFixed(1)} KB';
}
