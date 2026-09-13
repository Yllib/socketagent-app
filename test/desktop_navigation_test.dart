import 'dart:io';
import 'package:app/screens/home_screen.dart';
import 'package:app/services/desktop_workspace_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

void main() {
  testWidgets(
    'desktop session links return to the workspace without stacking chats',
    (tester) async {
      final controller = DesktopWorkspaceController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: controller,
          child: MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: Column(
                  children: [
                    const Text('Workspace'),
                    TextButton(
                      onPressed: () => openConversation(context),
                      child: const Text('Open chat'),
                    ),
                    TextButton(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (context) => Scaffold(
                            body: TextButton(
                              onPressed: () => openConversation(context),
                              child: const Text('Session link'),
                            ),
                          ),
                        ),
                      ),
                      child: const Text('Details'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open chat'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open chat'));
      await tester.pumpAndSettle();
      expect(controller.revision, 2);
      expect(find.byType(HomeScreen), findsNothing);
      await tester.tap(find.text('Details'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Session link'));
      await tester.pumpAndSettle();
      expect(find.text('Workspace'), findsOneWidget);
      expect(find.text('Session link'), findsNothing);
      expect(controller.revision, 3);
      expect(tester.takeException(), isNull);
    },
    skip: !Platform.isWindows,
  );
}
