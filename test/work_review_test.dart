import 'dart:async';

import 'package:app/models/message.dart';
import 'package:app/models/work_review.dart';
import 'package:app/screens/work_review_workspace_screen.dart';
import 'package:app/services/work_review_repository.dart';
import 'package:app/widgets/work_review_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

class _MemoryTransport implements WorkReviewTransport {
  final controller = StreamController<WorkReviewServerEvent>.broadcast();
  final sent = <({String serverId, Map<String, dynamic> message})>[];
  bool connected = true;

  @override
  Stream<WorkReviewServerEvent> get events => controller.stream;

  @override
  bool send(String serverId, Map<String, dynamic> message) {
    if (!connected) return false;
    sent.add((serverId: serverId, message: message));
    return true;
  }

  Future<void> dispose() => controller.close();
}

class _MemoryCache implements WorkReviewCache {
  Map<String, dynamic>? value;

  @override
  Future<Map<String, dynamic>?> read() async => value;

  @override
  Future<void> write(Map<String, dynamic> value) async {
    this.value = value;
  }
}

Map<String, dynamic> _reviewJson({String reviewId = 'review-1'}) => {
  'reviewId': reviewId,
  'roundId': 'round-1',
  'sessionId': 'session-1',
  'title': 'Production checkout',
  'summary': 'Verify the new purchase flow.',
  'purpose': 'pre_deployment',
  'authorization': 'Approval authorizes deployment.',
  'status': 'open',
  'createdAt': '2026-07-29T12:00:00Z',
  'updatedAt': '2026-07-29T12:05:00Z',
  'items': [
    {
      'itemId': 'checkout',
      'title': 'Checkout',
      'instructions': 'Place a test order.',
      'primaryTarget': {
        'kind': 'url',
        'uri': 'https://sandbox.example.com/checkout',
        'environment': 'sandbox',
        'displayMode': 'embedded',
      },
    },
    {
      'itemId': 'receipt',
      'title': 'Receipt',
      'primaryTarget': {
        'kind': 'image',
        'uri': 'https://example.com/receipt.png',
        'environment': 'development',
      },
    },
  ],
};

void main() {
  test(
    'primary HTTPS targets embed even when legacy metadata says external',
    () {
      final target = WorkReviewTarget.fromJson({
        'kind': 'url',
        'uri': 'https://marinadev.jarofdirt.info/email/compose',
        'displayMode': 'external',
      });

      expect(target.isWeb, isTrue);
      expect(shouldEmbedWorkReviewTarget(target), isTrue);
    },
  );

  test(
    'work review parses generic targets and canonical draft wire fields',
    () {
      final review = WorkReview.fromJson(_reviewJson(), serverId: 'server-a');
      expect(review.id, 'review-1');
      expect(review.items, hasLength(2));
      expect(review.items.first.primaryTarget?.isWeb, isTrue);
      expect(review.items.last.primaryTarget?.kind, 'image');
      expect(review.authorization, 'Approval authorizes deployment.');

      final draft = WorkReviewDraft.fromJson(
        {
          'revision': 4,
          'overallNote': 'Ready after the copy fix.',
          'items': [
            {'itemId': 'checkout', 'status': 'approved', 'note': 'Looks good'},
            {'itemId': 'receipt', 'status': 'changes_requested'},
          ],
        },
        reviewId: review.id,
        roundId: review.roundId,
      );
      final wire = draft.toWireJson();
      expect(wire['overallNote'], 'Ready after the copy fix.');
      expect((wire['items'] as List).first, {
        'itemId': 'checkout',
        'status': 'approved',
        'note': 'Looks good',
      });
      expect((wire['items'] as List).last, {
        'itemId': 'receipt',
        'status': 'changes_requested',
      });
      expect(wire, isNot(contains('currentItemId')));
    },
  );

  test('full snapshot selects the authoritative current round', () {
    final review = WorkReview.fromJson({
      'reviewId': 'review-full',
      'originSessionId': 'origin-session',
      'currentRevision': 2,
      'createdAt': '2026-07-29T10:00:00Z',
      'updatedAt': '2026-07-29T11:00:00Z',
      'rounds': [
        {
          'roundId': 'round-1',
          'revision': 1,
          'title': 'First pass',
          'status': 'completed',
          'items': [],
        },
        {
          'roundId': 'round-2',
          'revision': 2,
          'title': 'Revised checkout',
          'approvalMeaning': 'Approval authorizes production deployment.',
          'status': 'in_review',
          'items': [
            {
              'itemId': 'current-item',
              'title': 'Current item',
              'primaryTarget': {
                'targetId': 'target-1',
                'kind': 'url',
                'uri': 'https://prod.example.com',
              },
            },
          ],
        },
      ],
    }, serverId: 'server-a');

    expect(review.sessionId, 'origin-session');
    expect(review.roundId, 'round-2');
    expect(review.title, 'Revised checkout');
    expect(review.status, WorkReviewStatus.open);
    expect(review.items.single.id, 'current-item');
    expect(review.authorization, contains('production deployment'));
  });

  test(
    'completed card and restart restore immutable published decisions',
    () async {
      final transport = _MemoryTransport();
      final cache = _MemoryCache();
      final completed = {
        ..._reviewJson(reviewId: 'completed-review'),
        'status': 'completed',
        'result': {
          'resultId': 'result-1',
          'draftRevision': 7,
          'publishedAt': '2026-07-29T13:00:00Z',
          'overallNote': 'Ready to deploy.',
          'itemResults': [
            {
              'itemId': 'checkout',
              'status': 'approved',
              'note': 'Test order passed.',
            },
            {'itemId': 'receipt', 'status': 'skipped'},
          ],
        },
      };
      final repository = WorkReviewRepository(
        transport: transport,
        cache: cache,
      );
      await repository.initialize();
      repository.handleServerMessage('server-a', {
        'type': 'work_review_card',
        'review': completed,
      });
      var draft = repository.draft('completed-review', serverId: 'server-a');
      expect(
        draft?.items['checkout']?.disposition,
        WorkReviewDisposition.approved,
      );
      expect(draft?.items['checkout']?.notes, 'Test order passed.');
      expect(draft?.overallNotes, 'Ready to deploy.');
      await Future<void>.delayed(Duration.zero);
      repository.dispose();

      final restored = WorkReviewRepository(transport: transport, cache: cache);
      await restored.initialize();
      draft = restored.draft('completed-review', serverId: 'server-a');
      expect(
        draft?.items['checkout']?.disposition,
        WorkReviewDisposition.approved,
      );
      expect(
        draft?.items['receipt']?.disposition,
        WorkReviewDisposition.skipped,
      );
      expect(draft?.overallNotes, 'Ready to deploy.');
      restored.dispose();
      await transport.dispose();
    },
  );

  test(
    'repository deduplicates snapshots and isolates reviews by server',
    () async {
      final transport = _MemoryTransport();
      final repository = WorkReviewRepository(
        transport: transport,
        cache: _MemoryCache(),
      );
      await repository.initialize();

      repository.handleServerMessage('server-a', {
        'type': 'work_review_card',
        'reviewId': 'review-1',
        'sessionId': 'session-1',
        'review': _reviewJson(),
      });
      repository.handleServerMessage('server-a', {
        'type': 'work_review_snapshot',
        'reviewId': 'review-1',
        'sessionId': 'session-1',
        'review': {..._reviewJson(), 'summary': 'Updated summary'},
      });
      repository.handleServerMessage('server-b', {
        'type': 'work_review_card',
        'reviewId': 'review-1',
        'review': _reviewJson(),
      });

      expect(repository.reviewsForServer('server-a'), hasLength(1));
      expect(
        repository.review('review-1', serverId: 'server-a')?.summary,
        'Updated summary',
      );
      expect(repository.reviewsForServer('server-b'), hasLength(1));
      repository.dispose();
      await transport.dispose();
    },
  );

  test('capability gates list requests and cached drafts recover', () async {
    final transport = _MemoryTransport();
    final cache = _MemoryCache();
    final repository = WorkReviewRepository(
      transport: transport,
      cache: cache,
      draftSyncDelay: const Duration(hours: 1),
    );
    await repository.initialize();
    repository.refresh(serverId: 'server-a');
    expect(transport.sent, isEmpty);
    repository.handleServerMessage('server-a', {
      'type': 'server_capabilities',
      'workReviews': {
        'version': 1,
        'privateDrafts': true,
        'atomicFinish': true,
      },
    });
    repository.refresh(serverId: 'server-a');
    expect(transport.sent.single.message['type'], 'work_review_list');
    repository.handleServerMessage('server-a', {
      'type': 'work_review_snapshot',
      'review': _reviewJson(),
    });
    final review = repository.review('review-1', serverId: 'server-a')!;
    repository.setItemNotes(review, 'checkout', 'Locally recoverable');
    await Future<void>.delayed(Duration.zero);
    repository.dispose();

    final restored = WorkReviewRepository(transport: transport, cache: cache);
    await restored.initialize();
    expect(
      restored
          .draft('review-1', serverId: 'server-a')
          ?.items['checkout']
          ?.notes,
      'Locally recoverable',
    );
    restored.dispose();
    await transport.dispose();
  });

  test('item edits debounce to one private full draft snapshot', () async {
    final transport = _MemoryTransport();
    final repository = WorkReviewRepository(
      transport: transport,
      cache: _MemoryCache(),
      draftSyncDelay: const Duration(milliseconds: 5),
    );
    await repository.initialize();
    repository.handleServerMessage('server-a', {
      'type': 'work_review_snapshot',
      'review': _reviewJson(),
    });
    final review = repository.review('review-1', serverId: 'server-a')!;

    repository.setDisposition(
      review,
      'checkout',
      WorkReviewDisposition.approved,
    );
    repository.setItemNotes(review, 'checkout', 'Verified with test card');
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(transport.sent, hasLength(1));
    final message = transport.sent.single.message;
    expect(message['type'], 'work_review_draft_update');
    expect(message, containsPair('baseRevision', 0));
    final items = (message['draft'] as Map)['items'] as List;
    expect(
      items.whereType<Map>().any(
        (item) =>
            item['itemId'] == 'checkout' &&
            item['status'] == 'approved' &&
            item['note'] == 'Verified with test card',
      ),
      isTrue,
    );
    expect(
      transport.sent.where(
        (entry) => entry.message['type'] == 'work_review_finish',
      ),
      isEmpty,
    );
    repository.dispose();
    await transport.dispose();
  });

  test(
    'serializes overlapping draft saves and publishes after the latest revision',
    () async {
      final transport = _MemoryTransport();
      final repository = WorkReviewRepository(
        transport: transport,
        cache: _MemoryCache(),
        draftSyncDelay: const Duration(milliseconds: 5),
      );
      await repository.initialize();
      repository.handleServerMessage('server-a', {
        'type': 'work_review_snapshot',
        'review': _reviewJson(),
      });
      final review = repository.review('review-1', serverId: 'server-a')!;

      repository.setDisposition(
        review,
        'checkout',
        WorkReviewDisposition.approved,
      );
      repository.setDisposition(
        review,
        'receipt',
        WorkReviewDisposition.changesRequested,
      );
      repository.setItemNotes(review, 'receipt', 'First note');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(transport.sent, hasLength(1));
      final firstSave = transport.sent.single.message;

      repository.setItemNotes(review, 'receipt', 'Newer note');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        transport.sent,
        hasLength(1),
        reason: 'a second private save must wait for the first acknowledgement',
      );

      final finish = repository.finishReview(review);
      await Future<void>.delayed(Duration.zero);
      expect(
        transport.sent.where(
          (entry) => entry.message['type'] == 'work_review_finish',
        ),
        isEmpty,
      );

      repository.handleServerMessage('server-a', {
        'type': 'work_review_operation_result',
        'requestId': firstSave['requestId'],
        'operation': 'draft_update',
        'reviewId': review.id,
        'roundId': review.roundId,
        'ok': true,
        'review': _reviewJson(),
        'draft': {'revision': 1, 'items': (firstSave['draft'] as Map)['items']},
      });

      expect(await finish, isTrue);
      final publish = transport.sent.singleWhere(
        (entry) => entry.message['type'] == 'work_review_finish',
      );
      expect(publish.message['baseRevision'], 1);
      expect(
        ((publish.message['draft'] as Map)['items'] as List)
            .whereType<Map>()
            .singleWhere((item) => item['itemId'] == 'receipt')['note'],
        'Newer note',
      );

      repository.dispose();
      await transport.dispose();
    },
  );

  test('finish publishes one consolidated result only when complete', () async {
    final transport = _MemoryTransport();
    final repository = WorkReviewRepository(
      transport: transport,
      cache: _MemoryCache(),
      draftSyncDelay: const Duration(hours: 1),
    );
    await repository.initialize();
    repository.handleServerMessage('server-a', {
      'type': 'work_review_snapshot',
      'review': _reviewJson(),
    });
    final review = repository.review('review-1', serverId: 'server-a')!;

    repository.setDisposition(
      review,
      'checkout',
      WorkReviewDisposition.approved,
    );
    expect(await repository.finishReview(review), isFalse);
    repository.setDisposition(
      review,
      'receipt',
      WorkReviewDisposition.changesRequested,
    );
    repository.setItemNotes(review, 'receipt', 'Increase contrast');

    expect(await repository.finishReview(review), isTrue);
    expect(await repository.finishReview(review), isFalse);
    final publishes = transport.sent.where(
      (entry) => entry.message['type'] == 'work_review_finish',
    );
    expect(publishes, hasLength(1));
    final draft = publishes.single.message['draft'] as Map;
    expect(draft['items'], hasLength(2));
    expect(
      (draft['items'] as List).whereType<Map>().any(
        (item) =>
            item['itemId'] == 'receipt' &&
            item['status'] == 'changes_requested' &&
            item['note'] == 'Increase contrast',
      ),
      isTrue,
    );
    repository.dispose();
    await transport.dispose();
  });

  testWidgets('durable work review card shows draft progress', (tester) async {
    final transport = _MemoryTransport();
    final repository = WorkReviewRepository(
      transport: transport,
      cache: _MemoryCache(),
      draftSyncDelay: const Duration(hours: 1),
    );
    await repository.initialize();
    repository.handleServerMessage('server-a', {
      'type': 'work_review_card',
      'review': _reviewJson(),
    });
    final review = repository.review('review-1', serverId: 'server-a')!;
    repository.setDisposition(
      review,
      'checkout',
      WorkReviewDisposition.approved,
    );
    final message = ChatMessage.workReview({
      'reviewId': review.id,
      'review': review.toJson(),
    }, serverId: review.serverId);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: repository,
        child: MaterialApp(
          home: Scaffold(body: WorkReviewCard(message: message)),
        ),
      ),
    );

    expect(find.text('Production checkout'), findsOneWidget);
    expect(find.textContaining('1 of 2 items reviewed'), findsOneWidget);
    expect(find.text('REVIEW'), findsOneWidget);
    repository.dispose();
    await transport.dispose();
  });
}
