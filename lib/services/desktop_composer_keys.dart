import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../models/message.dart';

/// The text of the newest prompt in [messages], for Up in an empty composer.
String? lastSentPrompt(List<ChatMessage> messages) => messages.reversed
    .where(
      (message) =>
          message.sender == MessageSender.user &&
          message.type == MessageType.text &&
          message.textContent.trim().isNotEmpty,
    )
    .firstOrNull
    ?.textContent;

/// Runs on the text field's focus node, before its multiline edit shortcuts.
/// Ctrl+V first offers the clipboard to [onPasteAttachments], which returns
/// true when it attached files or an image; otherwise text pastes as usual.
/// Up in an empty composer fills in [onRecallPrompt]'s text. Escape is
/// consumed when [onEscape] returns true, for example after stopping a run.
KeyEventResult handleDesktopComposerKey(
  KeyEvent event, {
  required BuildContext context,
  required TextEditingController controller,
  required VoidCallback onSend,
  Future<bool> Function()? onPasteAttachments,
  String? Function()? onRecallPrompt,
  bool Function()? onEscape,
}) {
  final keyboard = HardwareKeyboard.instance;
  final plain =
      !keyboard.isControlPressed &&
      !keyboard.isShiftPressed &&
      !keyboard.isAltPressed &&
      !keyboard.isMetaPressed;
  if (event is KeyDownEvent && plain) {
    if (event.logicalKey == LogicalKeyboardKey.escape &&
        (onEscape?.call() ?? false)) {
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp &&
        controller.text.isEmpty) {
      final prompt = onRecallPrompt?.call();
      if (prompt != null) {
        controller.value = TextEditingValue(
          text: prompt,
          selection: TextSelection.collapsed(offset: prompt.length),
        );
        return KeyEventResult.handled;
      }
    }
  }
  if (onPasteAttachments != null &&
      event.logicalKey == LogicalKeyboardKey.keyV &&
      keyboard.isControlPressed &&
      !keyboard.isShiftPressed &&
      !keyboard.isAltPressed) {
    if (event is KeyDownEvent) {
      onPasteAttachments().then((attached) {
        if (attached || !context.mounted) return;
        Actions.invoke(
          context,
          const PasteTextIntent(SelectionChangedCause.keyboard),
        );
      });
    }
    return KeyEventResult.handled;
  }
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
