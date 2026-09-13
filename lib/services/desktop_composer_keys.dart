import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Runs on the text field's focus node, before its multiline edit shortcuts.
KeyEventResult handleDesktopComposerKey(
  KeyEvent event, {
  required BuildContext context,
  required TextEditingController controller,
  required VoidCallback onSend,
}) {
  if (event.logicalKey != LogicalKeyboardKey.enter &&
      event.logicalKey != LogicalKeyboardKey.numpadEnter) {
    return KeyEventResult.ignored;
  }
  final composing = controller.value.composing;
  if (composing.isValid && !composing.isCollapsed) {
    // Let the input method confirm its candidate without submitting a prompt
    // or running Flutter's newline shortcut.
    return KeyEventResult.skipRemainingHandlers;
  }
  final keyboard = HardwareKeyboard.instance;
  if (keyboard.isControlPressed ||
      keyboard.isAltPressed ||
      keyboard.isMetaPressed) {
    return KeyEventResult.ignored;
  }
  if (event is KeyDownEvent) {
    if (keyboard.isShiftPressed) {
      final value = controller.value;
      final selection = value.selection.isValid
          ? value.selection
          : TextSelection.collapsed(offset: value.text.length);
      // Go through EditableText so a blank line also reveals the caret and
      // participates in normal user editing, formatting, and undo handling.
      Actions.invoke(
        context,
        ReplaceTextIntent(
          value,
          '\n',
          selection,
          SelectionChangedCause.keyboard,
        ),
      );
    } else {
      onSend();
    }
  }
  // Consume repeats and key-up too: holding Enter must never submit twice.
  return KeyEventResult.handled;
}
