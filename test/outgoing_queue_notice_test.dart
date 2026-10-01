import 'package:app/widgets/outgoing_queue_notice.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'multi_client_prompt_test.dart' show withSession;

void main() {
  testWidgets(
    'ordinary sends stay in transcript; only current delivery failures show above it',
    (tester) async {
      FlutterLocalNotificationsPlatform.instance =
          AndroidFlutterLocalNotificationsPlugin();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('dexterous.com/flutter/local_notifications'),
            (call) async => call.method == 'initialize' ? true : null,
          );
      await tester.runAsync(
        () => withSession((provider, send) async {
          await provider.sendPrompt('Pending prompt');
          final request = provider.pendingOutgoing.single;
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: ListenableBuilder(
                  listenable: provider,
                  builder: (_, _) => OutgoingQueueNotice(provider: provider),
                ),
              ),
            ),
          );
          await tester.pump();
          expect(
            provider.messages.where((m) => m.id == request.id).single.isPending,
            isTrue,
          );
          expect(find.text('View'), findsNothing);

          await send({
            'type': 'command_receipt',
            'commandId': request.id,
            'status': 'uncertain',
            'message': 'Check the conversation first.',
          });
          await tester.pump();
          expect(find.text('Delivery needs attention'), findsOneWidget);
          await tester.tap(find.text('View'));
          await tester.pumpAndSettle();
          expect(find.text('Pending prompt'), findsOneWidget);
          expect(find.text('Copy text'), findsOneWidget);
          expect(find.text('Remove'), findsOneWidget);
          await tester.tap(find.text('Close'));
          await tester.pumpAndSettle();

          provider.resumeSession(
            'another-session',
            serverId: 'multi-client-server',
          );
          await tester.pump();
          expect(provider.pendingOutgoing, hasLength(1));
          expect(provider.activeDeliveryProblems, isEmpty);
          expect(find.text('View'), findsNothing);

          // Device-wide storage errors remain visible even without a failed request here.
          provider.outgoingQueueError = 'Saved requests could not be loaded.';
          provider.notifyListeners();
          await tester.pump();
          expect(
            find.text('Saved requests could not be loaded.'),
            findsOneWidget,
          );
          await provider.discardOutgoing(request.id);
          await tester.pumpWidget(const SizedBox());
          await Future<void>.delayed(const Duration(milliseconds: 900));
        }),
      );
    },
  );
}
