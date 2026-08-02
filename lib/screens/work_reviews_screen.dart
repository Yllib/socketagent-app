import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/work_review.dart';
import '../services/work_review_repository.dart';
import 'work_review_workspace_screen.dart';

class WorkReviewsScreen extends StatefulWidget {
  const WorkReviewsScreen({
    super.key,
    required this.serverId,
    this.sessionId,
    this.serverLabel,
  });

  final String serverId;
  final String? sessionId;
  final String? serverLabel;

  @override
  State<WorkReviewsScreen> createState() => _WorkReviewsScreenState();
}

class _WorkReviewsScreenState extends State<WorkReviewsScreen> {
  final Set<String> _loadingReviewIds = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<WorkReviewRepository>().refresh(
        serverId: widget.serverId,
        sessionId: widget.sessionId,
        includeArchived: true,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Work Reviews'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: () => context.read<WorkReviewRepository>().refresh(
              serverId: widget.serverId,
              sessionId: widget.sessionId,
              includeArchived: true,
            ),
          ),
        ],
        bottom: widget.serverLabel == null
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(24),
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    widget.serverLabel!,
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
      ),
      body: Consumer<WorkReviewRepository>(
        builder: (context, repository, _) {
          final reviews = repository.reviewsForServer(
            widget.serverId,
            includeArchived: true,
          );
          final activeReviews = reviews
              .where((review) => review.status != WorkReviewStatus.archived)
              .toList();
          final archivedReviews = reviews
              .where((review) => review.status == WorkReviewStatus.archived)
              .toList();
          if (reviews.isEmpty) {
            return RefreshIndicator(
              onRefresh: () async => repository.refresh(
                serverId: widget.serverId,
                sessionId: widget.sessionId,
                includeArchived: true,
              ),
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: const [
                  SizedBox(height: 120),
                  Icon(Icons.fact_check_outlined, size: 52),
                  SizedBox(height: 16),
                  Center(child: Text('No work reviews on this server')),
                ],
              ),
            );
          }
          return RefreshIndicator(
            onRefresh: () async => repository.refresh(
              serverId: widget.serverId,
              sessionId: widget.sessionId,
              includeArchived: true,
            ),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 28),
              children: [
                for (final review in activeReviews) ...[
                  _buildReviewCard(repository, review),
                  const SizedBox(height: 8),
                ],
                if (archivedReviews.isNotEmpty)
                  Card(
                    child: ExpansionTile(
                      leading: const Icon(Icons.archive_outlined),
                      title: const Text('Archived'),
                      subtitle: Text(
                        '${archivedReviews.length} review${archivedReviews.length == 1 ? '' : 's'}',
                      ),
                      children: [
                        for (final review in archivedReviews)
                          _buildArchivedTile(repository, review),
                      ],
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildReviewCard(WorkReviewRepository repository, WorkReview review) {
    final draft = repository.draft(review.id, serverId: review.serverId);
    final decided =
        draft?.items.values.where((item) => item.disposition != null).length ??
        0;
    final changing = repository.isChangingLifecycle(review);
    final card = Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: Icon(_statusIcon(review.status)),
        title: Text(review.title),
        subtitle: Text(
          review.status == WorkReviewStatus.open
              ? review.items.isEmpty
                    ? 'Open • ${review.itemCount} items'
                    : '$decided of ${review.items.length} reviewed'
              : review.status == WorkReviewStatus.cancelled
              ? 'Cancelled • Nothing sent to agent'
              : 'Completed',
        ),
        trailing: changing || _loadingReviewIds.contains(review.id)
            ? const SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : !repository.supportsSilentLifecycle(review.serverId)
            ? const Icon(Icons.chevron_right)
            : PopupMenuButton<String>(
                tooltip: 'Review actions',
                onSelected: (action) {
                  if (action == 'cancel') {
                    _confirmCancel(repository, review);
                  } else if (action == 'archive') {
                    _archiveReview(repository, review);
                  }
                },
                itemBuilder: (_) => [
                  if (review.status == WorkReviewStatus.open)
                    const PopupMenuItem(
                      value: 'cancel',
                      child: ListTile(
                        leading: Icon(Icons.cancel_outlined),
                        title: Text('Cancel review'),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  const PopupMenuItem(
                    value: 'archive',
                    child: ListTile(
                      leading: Icon(Icons.archive_outlined),
                      title: Text('Archive'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                ],
              ),
        onTap: changing || _loadingReviewIds.contains(review.id)
            ? null
            : () => _openReview(repository, review),
      ),
    );
    if (!repository.supportsSilentLifecycle(review.serverId)) return card;
    return Dismissible(
      key: ValueKey('work-review-${review.serverId}-${review.id}'),
      direction: DismissDirection.endToStart,
      confirmDismiss: (_) => _archiveReview(repository, review),
      background: Container(
        padding: const EdgeInsets.only(right: 24),
        alignment: Alignment.centerRight,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.secondaryContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Icon(Icons.archive_outlined),
      ),
      child: card,
    );
  }

  Widget _buildArchivedTile(
    WorkReviewRepository repository,
    WorkReview review,
  ) {
    final changing = repository.isChangingLifecycle(review);
    return ListTile(
      leading: const Icon(Icons.inventory_2_outlined),
      title: Text(review.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: const Text('Archived • No agent notification'),
      trailing: changing
          ? const SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : !repository.supportsSilentLifecycle(review.serverId)
          ? null
          : IconButton(
              tooltip: 'Restore review',
              icon: const Icon(Icons.unarchive_outlined),
              onPressed: () => _restoreReview(repository, review),
            ),
      onTap: changing ? null : () => _openReview(repository, review),
    );
  }

  IconData _statusIcon(WorkReviewStatus status) => switch (status) {
    WorkReviewStatus.open => Icons.fact_check_outlined,
    WorkReviewStatus.completed => Icons.task_alt,
    WorkReviewStatus.cancelled => Icons.cancel_outlined,
    WorkReviewStatus.archived => Icons.archive_outlined,
  };

  Future<bool> _archiveReview(
    WorkReviewRepository repository,
    WorkReview review,
  ) async {
    final archived = await repository.archiveReview(review);
    if (!mounted) return archived;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          archived
              ? 'Review archived. Nothing was sent to the agent.'
              : repository.errorFor(review) ?? 'Could not archive review',
        ),
        action: archived
            ? SnackBarAction(
                label: 'Undo',
                onPressed: () => repository.restoreReview(review),
              )
            : null,
      ),
    );
    return archived;
  }

  Future<void> _restoreReview(
    WorkReviewRepository repository,
    WorkReview review,
  ) async {
    final restored = await repository.restoreReview(review);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          restored
              ? 'Review restored'
              : repository.errorFor(review) ?? 'Could not restore review',
        ),
      ),
    );
  }

  Future<void> _confirmCancel(
    WorkReviewRepository repository,
    WorkReview review,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cancel this review?'),
        content: const Text(
          'This closes the review and discards its private draft. '
          'No decisions, notes, or cancellation message will be sent to the agent.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep reviewing'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Cancel review'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final cancelled = await repository.cancelReview(review);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          cancelled
              ? 'Review cancelled. Nothing was sent to the agent.'
              : repository.errorFor(review) ?? 'Could not cancel review',
        ),
      ),
    );
  }

  Future<void> _openReview(
    WorkReviewRepository repository,
    WorkReview summary,
  ) async {
    var review = summary;
    if (review.items.isEmpty && review.itemCount > 0) {
      setState(() => _loadingReviewIds.add(review.id));
      final fetched = await repository.fetch(review);
      if (!mounted) return;
      setState(() => _loadingReviewIds.remove(review.id));
      if (fetched == null || fetched.items.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not load review details')),
        );
        return;
      }
      review = fetched;
    }
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => WorkReviewWorkspaceScreen(review: review),
      ),
    );
  }
}
