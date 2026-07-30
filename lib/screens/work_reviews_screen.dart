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
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 28),
              itemCount: reviews.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final review = reviews[index];
                final draft = repository.draft(
                  review.id,
                  serverId: review.serverId,
                );
                final decided =
                    draft?.items.values
                        .where((item) => item.disposition != null)
                        .length ??
                    0;
                return Card(
                  clipBehavior: Clip.antiAlias,
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    leading: Icon(
                      review.status == WorkReviewStatus.completed
                          ? Icons.task_alt
                          : Icons.fact_check_outlined,
                    ),
                    title: Text(review.title),
                    subtitle: Text(
                      review.status == WorkReviewStatus.open
                          ? review.items.isEmpty
                                ? 'Open • ${review.itemCount} items'
                                : '$decided of ${review.items.length} reviewed'
                          : review.status.name,
                    ),
                    trailing: _loadingReviewIds.contains(review.id)
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.chevron_right),
                    onTap: _loadingReviewIds.contains(review.id)
                        ? null
                        : () => _openReview(repository, review),
                  ),
                );
              },
            ),
          );
        },
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
