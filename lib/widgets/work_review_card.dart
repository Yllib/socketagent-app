import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/message.dart';
import '../models/work_review.dart';
import '../screens/work_review_workspace_screen.dart';
import '../services/work_review_repository.dart';

class WorkReviewCard extends StatelessWidget {
  const WorkReviewCard({super.key, required this.message});

  final ChatMessage message;

  WorkReview? _resolveReview(WorkReviewRepository repository) {
    final payload = message.toolInput ?? const <String, dynamic>{};
    final reviewId = payload['reviewId']?.toString() ?? message.toolUseId ?? '';
    final serverId = payload['_serverId']?.toString();
    final stored = repository.review(reviewId, serverId: serverId);
    if (stored != null) return stored;
    final nested = payload['review'];
    if (nested is! Map) return null;
    final map = Map<String, dynamic>.from(nested);
    map.putIfAbsent('reviewId', () => reviewId);
    if (payload['sessionId'] != null) {
      map.putIfAbsent('sessionId', () => payload['sessionId']);
    }
    return WorkReview.fromJson(map, serverId: serverId ?? '');
  }

  @override
  Widget build(BuildContext context) {
    final repository = context.watch<WorkReviewRepository>();
    final review = _resolveReview(repository);
    if (review == null) return const SizedBox.shrink();
    final draft = repository.draft(review.id, serverId: review.serverId);
    final decided =
        draft?.items.values.where((item) => item.disposition != null).length ??
        0;
    final complete = review.status == WorkReviewStatus.completed;
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => WorkReviewWorkspaceScreen(review: review),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: complete
                      ? theme.colorScheme.secondaryContainer
                      : theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  complete ? Icons.task_alt : Icons.fact_check_outlined,
                  color: complete
                      ? theme.colorScheme.onSecondaryContainer
                      : theme.colorScheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            review.title,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        _StatusPill(complete: complete),
                      ],
                    ),
                    if (review.summary.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        review.summary,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                    const SizedBox(height: 9),
                    Text(
                      complete
                          ? '${review.items.length} items · Review published'
                          : '$decided of ${review.items.length} items reviewed · Tap to continue',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ],
                ),
              ),
              const Padding(
                padding: EdgeInsets.only(top: 11, left: 6),
                child: Icon(Icons.open_in_full, size: 18),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.complete});

  final bool complete;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: complete ? colors.secondaryContainer : colors.tertiaryContainer,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        complete ? 'FINISHED' : 'REVIEW',
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          fontSize: 9,
          fontWeight: FontWeight.w800,
          color: complete
              ? colors.onSecondaryContainer
              : colors.onTertiaryContainer,
        ),
      ),
    );
  }
}
