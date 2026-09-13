import 'package:app/services/desktop_composer_keys.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Enter sends once; Shift Enter edits a multiline draft', (
    tester,
  ) async {
    final controller = TextEditingController(text: 'First');
    var sends = 0;
    final node = FocusNode(
      onKeyEvent: (focus, event) => handleDesktopComposerKey(
        event,
        context: focus.context!,
        controller: controller,
        onSend: () => sends++,
      ),
    );
    addTearDown(controller.dispose);
    addTearDown(node.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TextField(
            controller: controller,
            focusNode: node,
            maxLines: 5,
            textInputAction: TextInputAction.newline,
          ),
        ),
      ),
    );
    await tester.tap(find.byType(TextField));
    controller.selection = const TextSelection.collapsed(offset: 5);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
    expect(sends, 1);
    expect(controller.text, 'First');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    expect(sends, 1);
    expect(controller.text, 'First\n');
    controller.selection = const TextSelection(baseOffset: 0, extentOffset: 5);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    expect(controller.text, '\n\n');
    await tester.sendKeyEvent(LogicalKeyboardKey.numpadEnter);
    expect(sends, 2);
    expect(controller.text, '\n\n');
  });

  testWidgets('blank newlines grow the composer and keep the caret visible', (
    tester,
  ) async {
    final controller = TextEditingController(text: 'First');
    final node = FocusNode(
      onKeyEvent: (focus, event) => handleDesktopComposerKey(
        event,
        context: focus.context!,
        controller: controller,
        onSend: () {},
      ),
    );
    addTearDown(controller.dispose);
    addTearDown(node.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TextField(
            controller: controller,
            focusNode: node,
            minLines: 1,
            maxLines: 5,
            textInputAction: TextInputAction.newline,
          ),
        ),
      ),
    );
    await tester.tap(find.byType(TextField));
    controller.selection = const TextSelection.collapsed(offset: 5);
    final initialHeight = tester.getSize(find.byType(TextField)).height;
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byType(TextField)).height,
      greaterThan(initialHeight),
    );
    for (var i = 0; i < 7; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
    }
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    final render = tester
        .state<EditableTextState>(find.byType(EditableText))
        .renderEditable;
    final caret = render.getLocalRectForCaret(controller.selection.extent);
    expect(caret.top, greaterThanOrEqualTo(0));
    expect(caret.bottom, lessThanOrEqualTo(render.size.height + 1));
    expect(controller.text, 'First\n\n\n\n\n\n\n\n');
  });

  testWidgets(
    'Enter during IME composition does not send or insert a newline',
    (tester) async {
      final controller = TextEditingController.fromValue(
        const TextEditingValue(
          text: 'candidate',
          selection: TextSelection.collapsed(offset: 9),
          composing: TextRange(start: 0, end: 9),
        ),
      );
      var sends = 0;
      final node = FocusNode(
        onKeyEvent: (focus, event) => handleDesktopComposerKey(
          event,
          context: focus.context!,
          controller: controller,
          onSend: () => sends++,
        ),
      );
      addTearDown(controller.dispose);
      addTearDown(node.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TextField(
              controller: controller,
              focusNode: node,
              maxLines: 5,
            ),
          ),
        ),
      );
      node.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(sends, 0);
      expect(controller.text, 'candidate');
    },
  );
}
