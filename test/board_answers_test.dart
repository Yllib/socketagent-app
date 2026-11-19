// Answers saved on board cards: they wait on the card until the user sends
// them, and each chat gets one message with all of its answers.
import 'package:app/models/project_board.dart';
import 'package:app/models/session_projects.dart';
import 'package:app/screens/boards/board_view.dart';
import 'package:app/services/board_store.dart';
import 'package:app/services/chat_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'support/fake_computers.dart';

class _Provider extends FakeComputersProvider {
  _Provider()
    : super(
        configs: [fakeConfig('tower', 'tower', host: '10.0.0.4')],
        fakeSessions: [fakeSession('s1', 'tower'), fakeSession('s2', 'tower')],
      );

  final sent = <(String, String)>[];
  final _projects = SessionProjects();

  @override
  SessionProjects get sessionProjects => _projects;

  @override
  Future<bool> sendToSession(String sessionId, String text) async {
    sent.add((sessionId, text));
    return true;
  }
}

BoardCard _card(String id, String title, CardAsk ask, {CardReply? reply}) {
  final at = DateTime(2026, 11, 18);
  return BoardCard(
    id: id,
    title: title,
    status: 'needs_you',
    ask: ask,
    reply: reply,
    history: [CardMove(at: at, by: 'Agent', to: 'needs_you')],
    createdAt: at,
    updatedAt: at,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('one message lists every card with its question and answer', () {
    final at = DateTime(2026);
    final message = boardAnswersMessage('Wakespeed', [
      _card(
        'c_1',
        'Website release',
        const CardAsk(AskKind.approve, 'Deploy tonight?'),
        reply: CardReply(text: 'After 6pm', at: at, approved: true),
      ),
      _card(
        'c_2',
        'Reply to Ashlyn',
        const CardAsk(AskKind.send, 'Send this reply?'),
        reply: CardReply(text: '', at: at, approved: false),
      ),
      _card(
        'c_3',
        'Promotion pricing',
        const CardAsk(AskKind.decide, 'Which price list?'),
        reply: CardReply(text: 'MSRP\nnot dealer cost', at: at),
      ),
    ]);
    expect(
      message,
      'Answers from the Wakespeed board:\n'
      '\n'
      '1. Approved: Website release (card c_1)\n'
      '   Question: Deploy tonight?\n'
      '   Note: After 6pm\n'
      '\n'
      "2. Don't send: Reply to Ashlyn (card c_2)\n"
      '   Question: Send this reply?\n'
      '\n'
      '3. Answered: Promotion pricing (card c_3)\n'
      '   Question: Which price list?\n'
      '   Answer: MSRP\n'
      '   not dealer cost',
    );
  });

  test(
    'a reply round-trips, needs its ask, and a sent one leaves Needs you',
    () {
      final reply = CardReply(
        text: 'ok',
        at: DateTime.fromMillisecondsSinceEpoch(5),
        approved: true,
      );
      final card = _card(
        'c_1',
        'One',
        const CardAsk(AskKind.approve, 'Go?'),
      ).copyWith(reply: () => reply);
      final back = BoardCard.fromJson(card.toJson())!;
      expect(back.reply?.toJson(), reply.toJson());
      expect(back.extra.containsKey('reply'), isFalse);
      expect(
        card.copyWith(ask: () => null).toJson().containsKey('reply'),
        isFalse,
      );

      final board = ProjectBoard(
        projectId: 'p_app',
        cards: [
          card,
          card.copyWith(reply: () => reply.markSent(DateTime(2026))),
        ],
      );
      expect(board.needsYou, hasLength(1));
    },
  );

  group('board screen', () {
    late _Provider provider;
    late BoardStore store;

    setUp(() {
      mockProviderChannels();
      provider = _Provider();
      provider.sessionProjects.names['p_app'] = 'Mobile app';
      store = BoardStore()..enable('p_app');
      store.putCard(
        'p_app',
        _card(
          'c_ship',
          'Ship 2.4',
          const CardAsk(AskKind.approve, 'Publish 2.4?', sessionId: 's1'),
        ),
      );
      store.putCard(
        'p_app',
        _card(
          'c_notes',
          'Release notes',
          const CardAsk(AskKind.approve, 'Use these notes?', sessionId: 's1'),
        ),
      );
      BoardStore.shared = store;
    });

    tearDown(unmockProviderChannels);

    Future<void> openBoard(WidgetTester tester) async {
      tester.view.physicalSize = const Size(412, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider<ChatProvider>.value(
          value: provider,
          child: MaterialApp(
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () => BoardScreen.open(context, 'p_app'),
                child: const Text('open board'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open board'));
      await tester.pumpAndSettle();
    }

    Future<void> approve(WidgetTester tester, String title, String id) async {
      await tester.tap(find.text(title));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('reply-yes-$id')));
      await tester.pumpAndSettle();
    }

    CardReply? replyOf(String id) =>
        store.board('p_app')!.cards.firstWhere((c) => c.id == id).reply;

    testWidgets('answers stay saved until Send all, as one message', (
      tester,
    ) async {
      await openBoard(tester);
      await approve(tester, 'Ship 2.4', 'c_ship');
      await approve(tester, 'Release notes', 'c_notes');
      expect(
        find.text('Approved  saved, not sent', findRichText: true),
        findsWidgets,
      );
      expect(find.text('2 answers saved, not sent'), findsOneWidget);
      expect(provider.sent, isEmpty);

      await tester.tap(find.byKey(const Key('board-send-all')));
      await tester.pumpAndSettle();
      expect(provider.sent, hasLength(1));
      expect(provider.sent.single.$1, 's1');
      expect(
        provider.sent.single.$2,
        contains('Approved: Ship 2.4 (card c_ship)'),
      );
      expect(
        provider.sent.single.$2,
        contains('Approved: Release notes (card c_notes)'),
      );
      expect(replyOf('c_ship')?.sent, isTrue);
      expect(find.byKey(const Key('board-send-all')), findsNothing);

      // Nothing left from this visit, so leaving doesn't ask.
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('open board'), findsOneWidget);
    });

    testWidgets('leaving asks; Not now keeps the answer saved, Send sends', (
      tester,
    ) async {
      await openBoard(tester);
      await approve(tester, 'Ship 2.4', 'c_ship');
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('Send 1 answer?'), findsOneWidget);
      await tester.tap(find.byKey(const Key('board-leave-keep')));
      await tester.pumpAndSettle();
      expect(find.text('open board'), findsOneWidget);
      expect(provider.sent, isEmpty);
      expect(replyOf('c_ship')?.sent, isFalse);

      // An answer from an earlier visit shows on the bar but doesn't ask.
      await tester.tap(find.text('open board'));
      await tester.pumpAndSettle();
      expect(find.text('1 answer saved, not sent'), findsOneWidget);
      await approve(tester, 'Release notes', 'c_notes');
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('Send 2 answers?'), findsOneWidget);
      await tester.tap(find.byKey(const Key('board-leave-send')));
      await tester.pumpAndSettle();
      expect(find.text('open board'), findsOneWidget);
      expect(provider.sent, hasLength(1));
      expect(replyOf('c_ship')?.sent, isTrue);
      expect(replyOf('c_notes')?.sent, isTrue);
    });
  });
}
