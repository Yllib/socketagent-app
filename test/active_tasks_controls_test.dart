import 'package:app/services/chat_provider.dart';
import 'package:app/widgets/active_tasks_pane.dart';
import 'package:app/widgets/panel_hide_notice.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('flutter_tts'),
          (_) async => null,
        );
  });

  testWidgets(
    'a reopened item is not dismissed and another session is not stopped',
    (tester) async {
      final provider = ChatProvider();
      var status = 'completed';
      var session = 'first';
      var stops = 0;
      late StateSetter update;
      await tester.pumpWidget(
        ChangeNotifierProvider<ChatProvider>(
          create: (_) => provider,
          child: MaterialApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder: (_, setState) {
                  update = setState;
                  return ActiveTasksPane(
                    sourceServerId: 'server',
                    sessionId: session,
                    backgroundTasks: {
                      'job': {'summary': 'Work', 'status': status},
                    },
                    subagentTasks: const {},
                    workflowTasks: const {},
                    messages: const [],
                    onStopTask: (_) => stops++,
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Dismiss finished item'));
      await tester.pump();
      expect(find.text('Dismissing 3'), findsOneWidget);
      update(() => status = 'running');
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
      expect(find.text('Work'), findsOneWidget);
      // Switching sessions cancels a countdown.
      update(() => status = 'completed');
      await tester.pump();
      await tester.tap(find.byTooltip('Dismiss finished item'));
      await tester.pump();
      update(() => session = 'second');
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
      expect(find.text('Work'), findsOneWidget);
      update(() {
        status = 'running';
        session = 'first';
      });
      await tester.pump();
      await tester.tap(find.byTooltip('Stop running work'));
      await tester.pump(const Duration(milliseconds: 300));
      update(() => session = 'second');
      await tester.pump();
      await tester.tap(find.text('Stop'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(stops, 0);
      expect(find.text('Work'), findsOneWidget);
    },
  );

  testWidgets(
    'hide does not stop work; stop confirms; finished items dismiss',
    (tester) async {
      final provider = ChatProvider();
      var hidden = false;
      var stopped = 0;
      Future<void> pump(String status, {bool notice = false}) async {
        await tester.pumpWidget(
          ChangeNotifierProvider<ChatProvider>(
            create: (_) => provider,
            child: MaterialApp(
              home: Scaffold(
                body: SizedBox(
                  width: 320,
                  child: ActiveTasksPane(
                    sourceServerId: 'server',
                    sessionId: 'session',
                    backgroundTasks: {
                      'job': {'status': status, 'summary': 'Example work'},
                    },
                    subagentTasks: const {},
                    workflowTasks: const {},
                    messages: const [],
                    onHide: () => hidden = true,
                    onStopTask: (_) => stopped++,
                    hidingNotice: notice
                        ? PanelHideNotice(
                            label: 'activity',
                            onCancel: () => hidden = false,
                          )
                        : null,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
      }

      await pump('running');
      expect(find.byTooltip('Dismiss finished item'), findsNothing);
      await tester.tap(find.byTooltip('Hide activity'));
      expect(hidden, isTrue);
      expect(stopped, 0);
      await pump('running', notice: true);
      expect(find.text('Hiding activity…'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      expect(hidden, isFalse);
      await pump('running');
      await tester.tap(find.byTooltip('Stop running work'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(stopped, 0);
      await tester.tap(find.text('Cancel'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(stopped, 0);
      await tester.tap(find.byTooltip('Stop running work'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Stop'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(stopped, 1);
      await pump('completed');
      expect(find.byTooltip('Stop running work'), findsNothing);
      await tester.tap(find.byTooltip('Dismiss finished item'));
      await tester.pump();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('Dismissing 3'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pump(const Duration(seconds: 4));
      expect(find.text('Example work'), findsOneWidget);
      await tester.tap(find.byTooltip('Dismiss finished item'));
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      expect(find.text('Example work'), findsNothing);
      await pump('running');
      expect(find.text('Example work'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('finished subagents and workflows share dismissal controls', (
    tester,
  ) async {
    final provider = ChatProvider();
    await tester.pumpWidget(
      ChangeNotifierProvider<ChatProvider>(
        create: (_) => provider,
        child: MaterialApp(
          home: Scaffold(
            body: ActiveTasksPane(
              sourceServerId: 'server',
              sessionId: 'session',
              backgroundTasks: const {},
              messages: const [],
              subagentTasks: const {
                'agent': {'description': 'Finished agent', 'status': 'failed'},
              },
              workflowTasks: const {
                'flow': {
                  'workflowName': 'Finished workflow',
                  'status': 'stopped',
                },
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byTooltip('Dismiss finished item'), findsNWidgets(2));
    await tester.tap(find.byTooltip('Dismiss finished item').first);
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(find.text('Finished agent'), findsNothing);
    expect(find.text('Finished workflow'), findsOneWidget);
  });

  testWidgets('Clear done counts down every finished item together', (
    tester,
  ) async {
    final provider = ChatProvider();
    await tester.pumpWidget(
      ChangeNotifierProvider<ChatProvider>(
        create: (_) => provider,
        child: MaterialApp(
          home: Scaffold(
            body: ActiveTasksPane(
              sourceServerId: 'server',
              sessionId: 'clear',
              backgroundTasks: const {
                'a': {'summary': 'Done one', 'status': 'completed'},
                'b': {'summary': 'Done two', 'status': 'failed'},
                'c': {'summary': 'Still going', 'status': 'running'},
              },
              subagentTasks: const {},
              workflowTasks: const {},
              messages: const [],
            ),
          ),
        ),
      ),
    );
    // A running row's spinner never settles.
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('Clear 2 done'));
    await tester.pump();
    expect(find.text('Dismissing 3'), findsNWidgets(2));
    await tester.tap(find.text('Cancel all'));
    await tester.pump(const Duration(seconds: 4));
    expect(find.text('Done one'), findsOneWidget);
    await tester.tap(find.text('Clear 2 done'));
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(find.text('Done one'), findsNothing);
    expect(find.text('Done two'), findsNothing);
    expect(find.text('Still going'), findsOneWidget);
  });
}
