import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../models/work_review.dart';
import '../services/chat_provider.dart';
import '../services/html_plan_export_service.dart';
import '../services/work_review_repository.dart';
import 'file_manager_screen.dart';
import 'home_screen.dart';

bool shouldEmbedWorkReviewTarget(WorkReviewTarget? target) {
  if (target == null) return false;
  if (target.isWeb) return true;
  if (target.kind != 'html') return false;
  if (target.html != null || target.uri.trimLeft().startsWith('<')) return true;
  final uri = Uri.tryParse(target.uri);
  return uri != null &&
      (uri.scheme == 'data' ||
          uri.scheme == 'about' ||
          uri.scheme == 'http' ||
          uri.scheme == 'https');
}

class WorkReviewWorkspaceScreen extends StatefulWidget {
  const WorkReviewWorkspaceScreen({super.key, required this.review});

  final WorkReview review;

  @override
  State<WorkReviewWorkspaceScreen> createState() =>
      _WorkReviewWorkspaceScreenState();
}

class _WorkReviewWorkspaceScreenState extends State<WorkReviewWorkspaceScreen> {
  final GlobalKey<_ReviewTargetStackState> _targetKey = GlobalKey();
  late final TextEditingController _notesController;
  late int _itemIndex;
  bool _panelCollapsed = false;
  double _portraitPanelFraction = .48;
  double _widePanelWidth = 390;

  WorkReviewRepository get _repository => context.read<WorkReviewRepository>();

  WorkReview get _review =>
      _repository.review(widget.review.id, serverId: widget.review.serverId) ??
      widget.review;

  @override
  void initState() {
    super.initState();
    final draft = context.read<WorkReviewRepository>().ensureDraft(
      widget.review,
    );
    final savedIndex = widget.review.items.indexWhere(
      (item) => item.id == draft.currentItemId,
    );
    _itemIndex = savedIndex < 0 ? 0 : savedIndex;
    final itemId = widget.review.items.isEmpty
        ? null
        : widget.review.items[_itemIndex].id;
    _notesController = TextEditingController(
      text: itemId == null ? '' : draft.items[itemId]?.notes ?? '',
    );
  }

  @override
  void dispose() {
    _notesController.dispose();
    super.dispose();
  }

  void _moveTo(int index) {
    final review = _review;
    if (review.items.isEmpty) return;
    final next = index.clamp(0, review.items.length - 1);
    if (next == _itemIndex) return;
    setState(() => _itemIndex = next);
    final item = review.items[next];
    _repository.setCurrentItem(review, item.id);
    final draft = _repository.ensureDraft(review);
    _notesController.text = draft.items[item.id]?.notes ?? '';
  }

  String _targetTitle(WorkReviewTarget? target) {
    if (target == null) return 'No target';
    if (target.label.isNotEmpty) return target.label;
    final uri = Uri.tryParse(target.uri);
    if (uri?.host.isNotEmpty == true) return uri!.host;
    return target.kind.toUpperCase();
  }

  Future<void> _confirmFinish() async {
    final review = _review;
    final draft = _repository.ensureDraft(review);
    final undecided = review.items
        .where((item) => draft.items[item.id]?.disposition == null)
        .length;
    if (undecided > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Choose a decision for all items ($undecided remaining)',
          ),
        ),
      );
      return;
    }
    final counts = <WorkReviewDisposition, int>{
      for (final disposition in WorkReviewDisposition.values) disposition: 0,
    };
    for (final item in draft.items.values) {
      if (item.disposition != null) {
        counts[item.disposition!] = counts[item.disposition!]! + 1;
      }
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Finish this review?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'This publishes one consolidated result to the agent. '
              'Your draft decisions and notes have not been exposed yet.',
            ),
            const SizedBox(height: 14),
            for (final entry in counts.entries)
              if (entry.value > 0) Text('${entry.key.label}: ${entry.value}'),
            if (review.authorization.isNotEmpty) ...[
              const SizedBox(height: 14),
              Text(
                review.authorization,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep reviewing'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Publish result'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final sent = await _repository.finishReview(review);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          sent
              ? 'Review published and sent to the agent'
              : _repository.errorFor(review) ?? 'Could not publish review',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<WorkReviewRepository>(
      builder: (context, repository, _) {
        final review = _review;
        if (review.items.isNotEmpty && _itemIndex >= review.items.length) {
          _itemIndex = review.items.length - 1;
        }
        final item = review.items.isEmpty ? null : review.items[_itemIndex];
        final target = item?.primaryTarget;
        final host = Uri.tryParse(target?.uri ?? '')?.host ?? '';
        return Scaffold(
          appBar: AppBar(
            titleSpacing: 4,
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _targetTitle(target),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 16),
                ),
                if (target != null)
                  Text(
                    [
                      if (host.isNotEmpty) host,
                      target.environment.toUpperCase(),
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
            actions: [
              IconButton(
                tooltip: 'Back in target',
                onPressed: () => _targetKey.currentState?.goBack(),
                icon: const Icon(Icons.arrow_back, size: 20),
              ),
              IconButton(
                tooltip: 'Forward in target',
                onPressed: () => _targetKey.currentState?.goForward(),
                icon: const Icon(Icons.arrow_forward, size: 20),
              ),
              IconButton(
                tooltip: 'Reload target',
                onPressed: () => _targetKey.currentState?.reload(),
                icon: const Icon(Icons.refresh, size: 20),
              ),
              IconButton(
                tooltip: 'Open externally',
                onPressed: target == null
                    ? null
                    : () => _targetKey.currentState?.openExternal(),
                icon: const Icon(Icons.open_in_new, size: 20),
              ),
            ],
          ),
          body: LayoutBuilder(
            builder: (context, constraints) {
              final targetStack = _ReviewTargetStack(
                key: _targetKey,
                items: review.items,
                activeIndex: _itemIndex,
                serverId: review.serverId,
              );
              if (constraints.maxWidth >= 800) {
                return _buildWide(
                  constraints,
                  targetStack,
                  repository,
                  review,
                  item,
                );
              }
              return _buildPortrait(
                constraints,
                targetStack,
                repository,
                review,
                item,
              );
            },
          ),
        );
      },
    );
  }

  Widget _buildPortrait(
    BoxConstraints constraints,
    Widget targetStack,
    WorkReviewRepository repository,
    WorkReview review,
    WorkReviewItem? item,
  ) {
    final maxHeight = constraints.maxHeight;
    final panelHeight = _panelCollapsed
        ? 62.0
        : (maxHeight * _portraitPanelFraction).clamp(230.0, maxHeight * .9);
    return Stack(
      children: [
        Positioned.fill(child: targetStack),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: panelHeight,
          child: Material(
            elevation: 16,
            color: Theme.of(context).colorScheme.surfaceContainer,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onVerticalDragUpdate: _panelCollapsed
                      ? null
                      : (details) => setState(() {
                          _portraitPanelFraction =
                              (_portraitPanelFraction -
                                      details.delta.dy / maxHeight)
                                  .clamp(.28, .9);
                        }),
                  child: _PanelHeader(
                    review: review,
                    itemIndex: _itemIndex,
                    collapsed: _panelCollapsed,
                    onToggle: () =>
                        setState(() => _panelCollapsed = !_panelCollapsed),
                  ),
                ),
                if (!_panelCollapsed)
                  Expanded(
                    child: _ReviewPanel(
                      review: review,
                      item: item,
                      itemIndex: _itemIndex,
                      notesController: _notesController,
                      repository: repository,
                      onPrevious: _itemIndex == 0
                          ? null
                          : () => _moveTo(_itemIndex - 1),
                      onNext: _itemIndex >= review.items.length - 1
                          ? null
                          : () => _moveTo(_itemIndex + 1),
                      onFinish: _confirmFinish,
                      onOpenTarget: _openSupportingTarget,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildWide(
    BoxConstraints constraints,
    Widget targetStack,
    WorkReviewRepository repository,
    WorkReview review,
    WorkReviewItem? item,
  ) {
    final panelWidth = _panelCollapsed
        ? 58.0
        : _widePanelWidth.clamp(320.0, constraints.maxWidth * .62);
    return Row(
      children: [
        Expanded(child: targetStack),
        if (!_panelCollapsed)
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragUpdate: (details) => setState(() {
              _widePanelWidth = (_widePanelWidth - details.delta.dx).clamp(
                320,
                constraints.maxWidth * .62,
              );
            }),
            child: Container(
              width: 8,
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: const Center(
                child: VerticalDivider(width: 1, thickness: 1),
              ),
            ),
          ),
        SizedBox(
          width: panelWidth,
          child: Material(
            color: Theme.of(context).colorScheme.surfaceContainer,
            child: _panelCollapsed
                ? Align(
                    alignment: Alignment.topCenter,
                    child: IconButton(
                      tooltip: 'Expand review panel',
                      onPressed: () => setState(() => _panelCollapsed = false),
                      icon: const Icon(Icons.chevron_left),
                    ),
                  )
                : Column(
                    children: [
                      _PanelHeader(
                        review: review,
                        itemIndex: _itemIndex,
                        collapsed: false,
                        onToggle: () => setState(() => _panelCollapsed = true),
                        wide: true,
                      ),
                      Expanded(
                        child: _ReviewPanel(
                          review: review,
                          item: item,
                          itemIndex: _itemIndex,
                          notesController: _notesController,
                          repository: repository,
                          onPrevious: _itemIndex == 0
                              ? null
                              : () => _moveTo(_itemIndex - 1),
                          onNext: _itemIndex >= review.items.length - 1
                              ? null
                              : () => _moveTo(_itemIndex + 1),
                          onFinish: _confirmFinish,
                          onOpenTarget: _openSupportingTarget,
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ],
    );
  }

  Future<void> _openSupportingTarget(WorkReviewTarget target) async {
    final uri = Uri.tryParse(target.uri);
    if ((target.kind == 'file' ||
            target.kind == 'image' ||
            target.kind == 'diff' ||
            target.kind == 'html') &&
        uri?.hasScheme != true) {
      final slash = target.uri.lastIndexOf('/');
      final parent = slash > 0 ? target.uri.substring(0, slash) : '';
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => FileManagerScreen(
            serverId: _review.serverId,
            initialPath: parent,
            highlightPath: target.uri,
            initialAction: 'view',
          ),
        ),
      );
      return;
    }
    if (target.kind == 'session' && target.uri.isNotEmpty) {
      context.read<ChatProvider>().resumeSession(
        target.uri,
        serverId: _review.serverId,
      );
      await Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => const HomeScreen()));
      return;
    }
    if (uri != null) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }
}

class _PanelHeader extends StatelessWidget {
  const _PanelHeader({
    required this.review,
    required this.itemIndex,
    required this.collapsed,
    required this.onToggle,
    this.wide = false,
  });

  final WorkReview review;
  final int itemIndex;
  final bool collapsed;
  final VoidCallback onToggle;
  final bool wide;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 62,
    child: Row(
      children: [
        if (!wide)
          const Padding(
            padding: EdgeInsets.only(left: 12),
            child: Icon(Icons.drag_handle),
          ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                review.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
              ),
              Text(
                review.items.isEmpty
                    ? 'No review items'
                    : 'Item ${itemIndex + 1} of ${review.items.length}',
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ],
          ),
        ),
        IconButton(
          tooltip: collapsed ? 'Expand review panel' : 'Collapse review panel',
          onPressed: onToggle,
          icon: Icon(
            collapsed
                ? Icons.keyboard_arrow_up
                : wide
                ? Icons.chevron_right
                : Icons.keyboard_arrow_down,
          ),
        ),
      ],
    ),
  );
}

class _ReviewPanel extends StatelessWidget {
  const _ReviewPanel({
    required this.review,
    required this.item,
    required this.itemIndex,
    required this.notesController,
    required this.repository,
    required this.onPrevious,
    required this.onNext,
    required this.onFinish,
    required this.onOpenTarget,
  });

  final WorkReview review;
  final WorkReviewItem? item;
  final int itemIndex;
  final TextEditingController notesController;
  final WorkReviewRepository repository;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final VoidCallback onFinish;
  final ValueChanged<WorkReviewTarget> onOpenTarget;

  @override
  Widget build(BuildContext context) {
    if (item == null) {
      return const Center(child: Text('This review has no items'));
    }
    final draft = repository.ensureDraft(review);
    final itemDraft =
        draft.items[item!.id] ?? WorkReviewItemDraft(itemId: item!.id);
    final publishing = repository.isPublishing(review);
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            children: [
              Text(
                item!.title,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              if (review.status == WorkReviewStatus.completed &&
                  draft.overallNotes.isNotEmpty) ...[
                const SizedBox(height: 10),
                Card(
                  margin: EdgeInsets.zero,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Overall note',
                          style: Theme.of(context).textTheme.labelLarge
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 4),
                        Text(draft.overallNotes),
                      ],
                    ),
                  ),
                ),
              ],
              if (item!.description.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(item!.description),
              ],
              if (itemIndex == 0 && review.instructions.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  'Review instructions',
                  style: Theme.of(
                    context,
                  ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(review.instructions),
              ],
              if (item!.instructions.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  'What to inspect',
                  style: Theme.of(
                    context,
                  ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(item!.instructions),
              ],
              const SizedBox(height: 16),
              if (item!.supportingTargets.isNotEmpty) ...[
                Text(
                  'Supporting links',
                  style: Theme.of(
                    context,
                  ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                for (final target in item!.supportingTargets)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      target.kind == 'url'
                          ? Icons.link
                          : Icons.insert_drive_file_outlined,
                      size: 20,
                    ),
                    title: Text(
                      target.label.isNotEmpty ? target.label : target.uri,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: target.label.isEmpty
                        ? null
                        : Text(
                            target.uri,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                    trailing: const Icon(Icons.open_in_new, size: 17),
                    onTap: () => onOpenTarget(target),
                  ),
                const SizedBox(height: 8),
              ],
              Text(
                'Decision',
                style: Theme.of(
                  context,
                ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 7),
              Wrap(
                spacing: 7,
                runSpacing: 7,
                children: [
                  for (final disposition in WorkReviewDisposition.values)
                    ChoiceChip(
                      selected: itemDraft.disposition == disposition,
                      onSelected: review.status == WorkReviewStatus.open
                          ? (_) => repository.setDisposition(
                              review,
                              item!.id,
                              disposition,
                            )
                          : null,
                      avatar: Icon(_iconFor(disposition), size: 17),
                      label: Text(disposition.label),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              TextField(
                controller: notesController,
                minLines: 3,
                maxLines: 8,
                enabled: review.status == WorkReviewStatus.open,
                onChanged: (value) =>
                    repository.setItemNotes(review, item!.id, value),
                decoration: const InputDecoration(
                  labelText: 'Notes',
                  hintText: 'What worked, what should change, or why',
                  alignLabelWithHint: true,
                  border: OutlineInputBorder(),
                ),
              ),
              if (repository.errorFor(review) case final error?) ...[
                const SizedBox(height: 10),
                Text(
                  error,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontSize: 12,
                  ),
                ),
              ],
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
            child: Row(
              children: [
                IconButton(
                  tooltip: 'Previous item',
                  onPressed: onPrevious,
                  icon: const Icon(Icons.chevron_left),
                ),
                Expanded(
                  child: onNext != null
                      ? FilledButton.icon(
                          onPressed: onNext,
                          icon: const Icon(Icons.save_outlined),
                          label: const Text('Save & next'),
                        )
                      : FilledButton.icon(
                          onPressed:
                              review.status == WorkReviewStatus.open &&
                                  !publishing
                              ? onFinish
                              : null,
                          icon: publishing
                              ? const SizedBox(
                                  width: 17,
                                  height: 17,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.send_outlined),
                          label: Text(
                            publishing
                                ? 'Publishing…'
                                : review.status == WorkReviewStatus.completed
                                ? 'Review published'
                                : 'Finish review',
                          ),
                        ),
                ),
                IconButton(
                  tooltip: 'Next item',
                  onPressed: onNext,
                  icon: const Icon(Icons.chevron_right),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  IconData _iconFor(WorkReviewDisposition disposition) => switch (disposition) {
    WorkReviewDisposition.approved => Icons.check_circle_outline,
    WorkReviewDisposition.changesRequested => Icons.edit_note,
    WorkReviewDisposition.rejected => Icons.cancel_outlined,
    WorkReviewDisposition.skipped => Icons.skip_next,
  };
}

class _ReviewTargetStack extends StatefulWidget {
  const _ReviewTargetStack({
    super.key,
    required this.items,
    required this.activeIndex,
    required this.serverId,
  });

  final List<WorkReviewItem> items;
  final int activeIndex;
  final String serverId;

  @override
  State<_ReviewTargetStack> createState() => _ReviewTargetStackState();
}

class _ReviewTargetStackState extends State<_ReviewTargetStack> {
  static const _maxCachedTargets = 5;
  final Map<String, GlobalKey<_WorkReviewTargetViewState>> _keys = {};
  final LinkedHashSet<String> _visited = LinkedHashSet();

  @override
  void initState() {
    super.initState();
    _visitActive();
  }

  @override
  void didUpdateWidget(covariant _ReviewTargetStack oldWidget) {
    super.didUpdateWidget(oldWidget);
    _visitActive();
  }

  void _visitActive() {
    if (widget.items.isEmpty) return;
    final id = widget.items[widget.activeIndex].id;
    _visited.remove(id);
    _visited.add(id);
    _keys.putIfAbsent(id, () => GlobalKey<_WorkReviewTargetViewState>());
    while (_visited.length > _maxCachedTargets) {
      final oldest = _visited.first;
      _visited.remove(oldest);
      _keys.remove(oldest);
    }
  }

  _WorkReviewTargetViewState? get _active {
    if (widget.items.isEmpty) return null;
    return _keys[widget.items[widget.activeIndex].id]?.currentState;
  }

  void goBack() => _active?.goBack();
  void goForward() => _active?.goForward();
  void reload() => _active?.reload();
  void openExternal() => _active?.openExternal();

  @override
  Widget build(BuildContext context) {
    if (widget.items.isEmpty) {
      return const ColoredBox(
        color: Colors.black12,
        child: Center(child: Text('No work target provided')),
      );
    }
    final activeId = widget.items[widget.activeIndex].id;
    return Stack(
      fit: StackFit.expand,
      children: [
        for (final item in widget.items)
          if (_visited.contains(item.id))
            Offstage(
              offstage: item.id != activeId,
              child: TickerMode(
                enabled: item.id == activeId,
                child: _WorkReviewTargetView(
                  key: _keys[item.id],
                  target: item.primaryTarget,
                  serverId: widget.serverId,
                ),
              ),
            ),
      ],
    );
  }
}

class _WorkReviewTargetView extends StatefulWidget {
  const _WorkReviewTargetView({
    super.key,
    required this.target,
    required this.serverId,
  });

  final WorkReviewTarget? target;
  final String serverId;

  @override
  State<_WorkReviewTargetView> createState() => _WorkReviewTargetViewState();
}

class _WorkReviewTargetViewState extends State<_WorkReviewTargetView> {
  WebViewController? _webController;
  int _progress = 0;

  @override
  void initState() {
    super.initState();
    final target = widget.target;
    final inlineHtml =
        target?.html ??
        (target?.uri.trimLeft().startsWith('<') == true ? target!.uri : null);
    // The primary target is the review workspace, not a launcher card. Every
    // HTTP(S) target is embedded so the review panel remains over the live
    // site. "Open externally" in the toolbar is the explicit escape hatch.
    final canEmbed = shouldEmbedWorkReviewTarget(target);
    if (canEmbed) {
      final controller = WebViewController()
        ..setJavaScriptMode(
          target?.kind == 'html'
              ? JavaScriptMode.disabled
              : JavaScriptMode.unrestricted,
        )
        ..setBackgroundColor(Colors.white)
        ..setNavigationDelegate(
          NavigationDelegate(
            onProgress: (progress) {
              if (mounted) setState(() => _progress = progress);
            },
          ),
        );
      if (target?.kind == 'html' && inlineHtml != null) {
        controller.loadHtmlString(
          HtmlPlanExportService.buildViewerDocument(inlineHtml),
        );
      } else {
        controller.loadRequest(Uri.parse(target!.uri));
      }
      _webController = controller;
    }
  }

  Future<void> goBack() async {
    final controller = _webController;
    if (controller != null && await controller.canGoBack()) {
      await controller.goBack();
    }
  }

  Future<void> goForward() async {
    final controller = _webController;
    if (controller != null && await controller.canGoForward()) {
      await controller.goForward();
    }
  }

  void reload() => _webController?.reload();

  Future<void> openExternal() async {
    final target = widget.target;
    if (target == null) return;
    final uri = Uri.tryParse(target.uri);
    if ((target.kind == 'file' ||
            target.kind == 'image' ||
            target.kind == 'diff' ||
            target.kind == 'html') &&
        uri?.hasScheme != true) {
      final slash = target.uri.lastIndexOf('/');
      final parent = slash > 0 ? target.uri.substring(0, slash) : '';
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => FileManagerScreen(
            serverId: widget.serverId,
            initialPath: parent,
            highlightPath: target.uri,
            initialAction: 'view',
          ),
        ),
      );
      return;
    }
    if (target.kind == 'session' && target.uri.isNotEmpty) {
      context.read<ChatProvider>().resumeSession(
        target.uri,
        serverId: widget.serverId,
      );
      await Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => const HomeScreen()));
      return;
    }
    if (uri != null) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    final target = widget.target;
    if (_webController case final controller?) {
      return Stack(
        children: [
          Positioned.fill(child: WebViewWidget(controller: controller)),
          if (_progress < 100)
            Align(
              alignment: Alignment.topCenter,
              child: LinearProgressIndicator(value: _progress / 100),
            ),
        ],
      );
    }
    final isImage = target?.kind == 'image';
    return ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerLowest,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isImage ? Icons.image_outlined : Icons.open_in_new,
                size: 56,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 18),
              Text(
                target?.label.isNotEmpty == true
                    ? target!.label
                    : 'Open ${target?.kind ?? 'target'}',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              if (target?.uri.isNotEmpty == true) ...[
                const SizedBox(height: 8),
                Text(
                  target!.uri,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed: openExternal,
                icon: const Icon(Icons.open_in_new),
                label: const Text('Open externally'),
              ),
              const SizedBox(height: 8),
              const Text(
                'This target cannot be embedded in the review workspace.',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
