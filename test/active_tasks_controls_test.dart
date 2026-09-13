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
    'confirmation cannot dismiss a reopened item or stop another session',
    (tester) async {
      final provider = ChatProvider();
      addTearDown(provider.dispose);
      var status = 'completed';
      var session = 'first';
      var stops = 0;
      late StateSetter update;
      await tester.pumpWidget(
        ChangeNotifierProvider<ChatProvider>.value(
          value: provider,
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
      await tester.pumpAndSettle();
      update(() => status = 'running');
      await tester.pump();
      await tester.tap(find.text('Dismiss'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Work'), findsOneWidget);
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
      addTearDown(provider.dispose);
      var hidden = false;
      var stopped = 0;
      Future<void> pump(String status, {bool notice = false}) async {
        await tester.pumpWidget(
          ChangeNotifierProvider<ChatProvider>.value(
            value: provider,
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
      await tester.pumpAndSettle();
      expect(find.text('Dismiss finished item?'), findsOneWidget);
      await tester.tap(find.text('Dismiss'));
      await tester.pumpAndSettle();
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
    addTearDown(provider.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider<ChatProvider>.value(
        value: provider,
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
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dismiss'));
    await tester.pumpAndSettle();
    expect(find.text('Finished agent'), findsNothing);
    expect(find.text('Finished workflow'), findsOneWidget);
  });
}
