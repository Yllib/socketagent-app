import 'package:app/models/memory_card.dart';
import 'package:app/models/message.dart';
import 'package:app/widgets/memory_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final live = {
    'type': 'memory_card',
    'sessionId': 's1',
    'entryId': 'e1',
    'sessionSeq': 7,
    'revision': 1,
    'memory': {
      'path': '/home/u/.claude/projects/-home-u-proj/memory/push-rules.md',
      'name': 'push-rules',
      'description': 'Push only on an explicit ship request',
      'memoryType': 'feedback',
      'body': 'Pushing master deploys everywhere.\n\n**Why:** auto-update.',
      'change': 'created',
    },
  };

  test('a live card and its history entry parse to the same memory', () {
    final fromLive = MemoryCard.fromJson(live)!;
    expect(fromLive.fileName, 'push-rules.md');
    expect(fromLive.sessionId, 's1');
    expect(fromLive.statusLabel, 'New memory');
    expect(fromLive.deleted, isFalse);

    final history = {
      'role': 'memory',
      'content': 'Saved memory: push-rules',
      'entryId': 'e1',
      'memory': live['memory'],
    };
    expect(MemoryCard.fromJson(history)!.toJson(), {
      ...fromLive.toJson(),
      'sessionId': '',
    });

    final message = ChatMessage.memory(fromLive, entryId: 'e1');
    expect(message.type, MessageType.memory);
    expect(message.id, 'memory_e1');
    expect(MemoryCard.fromJson(message.toolInput)!.name, 'push-rules');
    expect(
      MemoryCard.fromJson({
        'memory': {'name': 'no path'},
      }),
      isNull,
    );
  });

  test('user actions take precedence in the status label', () {
    final edited = MemoryCard.fromJson({
      ...live,
      'memory': {...live['memory']! as Map, 'userChange': 'edited'},
    })!;
    expect(edited.statusLabel, 'Edited by you');
    expect(edited.deleted, isFalse);
    final deleted = MemoryCard.fromJson({
      ...live,
      'memory': {...live['memory']! as Map, 'userChange': 'deleted'},
    })!;
    expect(deleted.statusLabel, 'Deleted by you');
    expect(deleted.deleted, isTrue);
    expect(deleted.toJson()['userChange'], 'deleted');
    expect(
      MemoryCard.fromJson({
        ...live,
        'memory': {...live['memory']! as Map, 'change': 'deleted'},
      })!.statusLabel,
      'Memory deleted',
    );
  });

  test('previous rides along, and a restore undoes a delete', () {
    final edited = MemoryCard.fromJson({
      ...live,
      'memory': {
        ...live['memory']! as Map,
        'body': 'The user rewrote this.',
        'userChange': 'edited',
        'previous': {
          'name': 'push-rules',
          'description': 'Push only on an explicit ship request',
          'memoryType': 'feedback',
          'body': 'Pushing master deploys everywhere.',
        },
      },
    })!;
    expect(edited.body, 'The user rewrote this.');
    expect(edited.previous!.body, 'Pushing master deploys everywhere.');
    expect(
      MemoryCard.fromJson(edited.toJson())!.previous!.toJson(),
      edited.previous!.toJson(),
    );
    expect(MemoryCard.fromJson(live)!.previous, isNull);
    expect(
      MemoryCard.fromJson(live)!.toJson().containsKey('previous'),
      isFalse,
    );

    final restored = MemoryCard.fromJson({
      ...live,
      'memory': {
        ...live['memory']! as Map,
        'change': 'deleted',
        'userChange': 'restored',
      },
    })!;
    expect(restored.deleted, isFalse);
    expect(restored.statusLabel, 'Restored by you');
  });

  Widget host(ChatMessage message) => MaterialApp(
    theme: ThemeData.dark(),
    home: Scaffold(body: MemoryCardView(message: message)),
  );

  testWidgets('a saved memory shows its fields and offers edit and delete', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(ChatMessage.memory(MemoryCard.fromJson(live)!, entryId: 'e1')),
    );
    expect(find.text('push-rules'), findsOneWidget);
    expect(find.text('New memory'), findsOneWidget);
    expect(find.text('Push only on an explicit ship request'), findsOneWidget);
    expect(find.text('feedback · push-rules.md'), findsOneWidget);
    expect(find.textContaining('Pushing master deploys'), findsOneWidget);
    expect(find.text('Edit'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);
  });

  testWidgets('delete asks first, and a deleted memory loses its buttons', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(ChatMessage.memory(MemoryCard.fromJson(live)!, entryId: 'e1')),
    );
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Delete push-rules?'), findsOneWidget);
    expect(
      find.text('push-rules.md and its line in MEMORY.md will be removed.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Delete push-rules?'), findsNothing);

    final deleted = MemoryCard.fromJson({
      ...live,
      'memory': {...live['memory']! as Map, 'userChange': 'deleted'},
    })!;
    await tester.pumpWidget(host(ChatMessage.memory(deleted, entryId: 'e1')));
    expect(find.text('Deleted by you'), findsOneWidget);
    expect(find.text('Edit'), findsNothing);
    expect(find.text('Delete'), findsNothing);
    expect(find.text('Restore'), findsOneWidget);
  });

  testWidgets('an edited card shows the new text and reveals the previous', (
    tester,
  ) async {
    final edited = MemoryCard.fromJson({
      ...live,
      'memory': {
        ...live['memory']! as Map,
        'body': 'The user rewrote this.',
        'userChange': 'edited',
        'previous': {
          'name': 'push-rules',
          'description': 'Push only on an explicit ship request',
          'memoryType': 'feedback',
          'body': 'Pushing master deploys everywhere.',
        },
      },
    })!;
    await tester.pumpWidget(host(ChatMessage.memory(edited, entryId: 'e1')));
    expect(find.text('Edited by you'), findsOneWidget);
    expect(find.text('The user rewrote this.'), findsOneWidget);
    expect(find.text('Pushing master deploys everywhere.'), findsNothing);
    await tester.tap(find.text('Show previous'));
    await tester.pump();
    expect(find.text('Before your edit'), findsOneWidget);
    expect(find.text('Pushing master deploys everywhere.'), findsOneWidget);
    await tester.tap(find.text('Hide previous'));
    await tester.pump();
    expect(find.text('Pushing master deploys everywhere.'), findsNothing);
  });
}
