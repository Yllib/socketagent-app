import 'package:app/models/project_board.dart';
import 'package:app/screens/boards/board_card.dart';
import 'package:app/screens/boards/board_actions.dart';
import 'package:app/services/board_store.dart';
import 'package:app/services/chat_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'support/fake_computers.dart';

BoardCard _card(String id, String status, {CardAsk? ask}) {
  final at = DateTime(2026, 11, 1);
  return BoardCard(
    id: id,
    title: 'Card $id',
    status: status,
    ask: ask,
    createdAt: at,
    updatedAt: at,
    history: [CardMove(at: at, by: 'Agent', to: status)],
  );
}

void main() {
  test('a card survives the relay record round trip', () {
    final card =
        _card(
          'a',
          'needs_you',
          ask: const CardAsk(AskKind.send, 'Send it?', sessionId: 's1'),
        ).copyWith(
          detail: '# Draft\n\nHi Dana,',
          waitingOn: () => const WaitingOn(WaitingKind.person, 'Dana'),
          links: const [
            CardLink(LinkKind.url, 'https://example.com', label: 'Thread'),
          ],
        );
    final record = {...card.toJson(), 'futureField': 3};

    final board = ProjectBoard.fromRecords('p_1', {
      'card.a': record,
      'card.b': {'v': 1, 'id': 'b', 'deleted': true, 'updatedAt': 0},
      'proposal.x': {
        'v': 1,
        'id': 'x',
        'byName': 'Release agent',
        'why': 'Add a review step',
        'config': {'rules': 'Review first.'},
        'state': 'open',
        'at': 5,
      },
    });

    expect(
      board.statuses.map((s) => s.key),
      BoardStatus.defaults.map((s) => s.key),
    );
    final copy = board.cards.single;
    expect(copy.ask?.sessionId, 's1');
    expect(copy.detail, startsWith('# Draft'));
    expect(copy.waitingOn?.name, 'Dana');
    expect(copy.links.single.label, 'Thread');
    expect(copy.toJson()['futureField'], 3);
    final proposal = board.openProposals.single;
    expect(proposal.by, 'Release agent');
    expect(proposal.rules, 'Review first.');
    expect(proposal.statuses, isNull);
  });

  test('moving a card records the move and updates Needs you', () {
    final store = BoardStore()..enable('p_1');
    store.putCard('p_1', _card('a', 'inbox'));
    expect(store.needsYouCount('p_1'), 0);

    store.moveCard('p_1', 'a', 'needs_you', why: 'Draft ready');

    final card = store.board('p_1')!.cards.single;
    expect(card.status, 'needs_you');
    expect(card.history.last.from, 'inbox');
    expect(card.history.last.why, 'Draft ready');
    expect(store.needsYouCount('p_1'), 1);
  });

  test('a card whose status was deleted shows under the first status', () {
    final board = ProjectBoard(projectId: 'p_1', cards: [_card('a', 'gone')]);
    expect(board.cardsIn('inbox').single.id, 'a');
  });

  test('done cards drop out of lists after 30 days', () {
    final board = ProjectBoard(projectId: 'p_1', cards: [_card('a', 'done')]);
    expect(board.cardsIn('done', now: DateTime(2026, 11, 20)), hasLength(1));
    expect(board.cardsIn('done', now: DateTime(2026, 12, 5)), isEmpty);
  });

  group('card view', () {
    setUp(mockProviderChannels);
    tearDown(unmockProviderChannels);

    testWidgets('opens in place and Done moves it to the done status', (
      tester,
    ) async {
      final store = BoardStore()..enable('p_1');
      store.putCard(
        'p_1',
        _card('a', 'doing').copyWith(notes: 'Halfway there'),
      );
      final provider = FakeComputersProvider(configs: const []);

      await tester.pumpWidget(
        ChangeNotifierProvider<ChatProvider>(
          create: (_) => provider,
          lazy: false,
          child: MaterialApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, setState) {
                  final open = <String>{};
                  return ListenableBuilder(
                    listenable: store,
                    builder: (context, _) {
                      final board = store.board('p_1')!;
                      final card = board.cards.single;
                      return StatefulBuilder(
                        builder: (context, setLocal) => BoardCardView(
                          card: card,
                          board: board,
                          actions: BoardActions(context, 'p_1', store: store),
                          expanded: open.contains(card.id),
                          onToggle: () => setLocal(() => open.add(card.id)),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ),
        ),
      );

      expect(find.text('Done'), findsNothing);
      await tester.tap(find.text('Card a'));
      await tester.pumpAndSettle();
      expect(find.text('Halfway there'), findsOneWidget);

      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(store.board('p_1')!.cards.single.status, 'done');
      await tester.pumpWidget(const SizedBox());
    });
  });
}
