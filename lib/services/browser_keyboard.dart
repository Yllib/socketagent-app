import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show StringCharacters;

/// A key event as a remote browser session takes it: the DOM `code` of the
/// physical key, the DOM `key` it produced, and any text it typed.
typedef BrowserKey = ({String code, String key, String? text});

/// Converts a hardware key event into DOM terms, or null for keys a page has
/// no name for (volume, media, and other device keys stay with the phone).
///
/// [heldKey] is the `key` sent when this key went down, so its release
/// reports the same value even if Shift changed in between.
BrowserKey? browserKeyFor(KeyEvent event, {String? heldKey}) {
  final code =
      _codeForPhysical(event.physicalKey) ??
      _codeForLogical[event.logicalKey] ??
      '';
  final character = event.character;
  final typed =
      character != null && character.isNotEmpty && _isPrintable(character)
      ? character
      : null;
  final key =
      heldKey ??
      _namedKeys[event.logicalKey] ??
      typed ??
      _labelKey(event.logicalKey);
  if (code.isEmpty && key == null) return null;
  return (code: code, key: key ?? '', text: event is KeyUpEvent ? null : typed);
}

/// Modifier keys held right now, as the DOM bitmask: 1 Alt, 2 Ctrl, 4 Meta,
/// 8 Shift.
int browserModifiers() {
  final keyboard = HardwareKeyboard.instance;
  return (keyboard.isAltPressed ? 1 : 0) |
      (keyboard.isControlPressed ? 2 : 0) |
      (keyboard.isMetaPressed ? 4 : 0) |
      (keyboard.isShiftPressed ? 8 : 0);
}

/// What a phone keyboard changed in its text field, as the Backspace presses
/// and typing that make the same change at the end of the page's field.
///
/// Keyboards rewrite text in place for autocorrect and word suggestions, so
/// this compares whole values instead of trusting single keystrokes.
({int backspaces, String typed}) imeEdit(String previous, String next) {
  final limit = previous.length < next.length ? previous.length : next.length;
  var shared = 0;
  while (shared < limit &&
      previous.codeUnitAt(shared) == next.codeUnitAt(shared)) {
    shared++;
  }
  // Never split an emoji or other surrogate pair down the middle.
  if (shared > 0 && _isHighSurrogate(previous.codeUnitAt(shared - 1))) {
    shared--;
  }
  return (
    backspaces: previous.substring(shared).characters.length,
    typed: next.substring(shared),
  );
}

bool _isHighSurrogate(int unit) => unit >= 0xD800 && unit <= 0xDBFF;

bool _isPrintable(String character) {
  final unit = character.codeUnitAt(0);
  return unit >= 0x20 && unit != 0x7F;
}

/// A single-character label such as the "A" on Ctrl+A, cased by Shift.
String? _labelKey(LogicalKeyboardKey key) {
  final label = key.keyLabel;
  if (label.characters.length != 1) return null;
  return HardwareKeyboard.instance.isShiftPressed
      ? label.toUpperCase()
      : label.toLowerCase();
}

// USB HID usages, which Flutter's physical keys carry on every platform.
const _letterA = 0x00070004;
const _letterZ = 0x0007001d;
const _digit1 = 0x0007001e;
const _digit0 = 0x00070027;
const _f1 = 0x0007003a;
const _f12 = 0x00070045;
const _numpad1 = 0x00070059;
const _numpad0 = 0x00070062;

String? _codeForPhysical(PhysicalKeyboardKey key) {
  final usage = key.usbHidUsage;
  if (usage >= _letterA && usage <= _letterZ) {
    return 'Key${String.fromCharCode(0x41 + usage - _letterA)}';
  }
  if (usage >= _digit1 && usage < _digit0) return 'Digit${usage - _digit1 + 1}';
  if (usage == _digit0) return 'Digit0';
  if (usage >= _f1 && usage <= _f12) return 'F${usage - _f1 + 1}';
  if (usage >= _numpad1 && usage < _numpad0) {
    return 'Numpad${usage - _numpad1 + 1}';
  }
  if (usage == _numpad0) return 'Numpad0';
  return _physicalCodes[key];
}

final _physicalCodes = <PhysicalKeyboardKey, String>{
  PhysicalKeyboardKey.enter: 'Enter',
  PhysicalKeyboardKey.escape: 'Escape',
  PhysicalKeyboardKey.backspace: 'Backspace',
  PhysicalKeyboardKey.tab: 'Tab',
  PhysicalKeyboardKey.space: 'Space',
  PhysicalKeyboardKey.minus: 'Minus',
  PhysicalKeyboardKey.equal: 'Equal',
  PhysicalKeyboardKey.bracketLeft: 'BracketLeft',
  PhysicalKeyboardKey.bracketRight: 'BracketRight',
  PhysicalKeyboardKey.backslash: 'Backslash',
  PhysicalKeyboardKey.semicolon: 'Semicolon',
  PhysicalKeyboardKey.quote: 'Quote',
  PhysicalKeyboardKey.backquote: 'Backquote',
  PhysicalKeyboardKey.comma: 'Comma',
  PhysicalKeyboardKey.period: 'Period',
  PhysicalKeyboardKey.slash: 'Slash',
  PhysicalKeyboardKey.capsLock: 'CapsLock',
  PhysicalKeyboardKey.scrollLock: 'ScrollLock',
  PhysicalKeyboardKey.pause: 'Pause',
  PhysicalKeyboardKey.insert: 'Insert',
  PhysicalKeyboardKey.home: 'Home',
  PhysicalKeyboardKey.pageUp: 'PageUp',
  PhysicalKeyboardKey.delete: 'Delete',
  PhysicalKeyboardKey.end: 'End',
  PhysicalKeyboardKey.pageDown: 'PageDown',
  PhysicalKeyboardKey.arrowRight: 'ArrowRight',
  PhysicalKeyboardKey.arrowLeft: 'ArrowLeft',
  PhysicalKeyboardKey.arrowDown: 'ArrowDown',
  PhysicalKeyboardKey.arrowUp: 'ArrowUp',
  PhysicalKeyboardKey.numLock: 'NumLock',
  PhysicalKeyboardKey.numpadDivide: 'NumpadDivide',
  PhysicalKeyboardKey.numpadMultiply: 'NumpadMultiply',
  PhysicalKeyboardKey.numpadSubtract: 'NumpadSubtract',
  PhysicalKeyboardKey.numpadAdd: 'NumpadAdd',
  PhysicalKeyboardKey.numpadEnter: 'NumpadEnter',
  PhysicalKeyboardKey.numpadDecimal: 'NumpadDecimal',
  PhysicalKeyboardKey.contextMenu: 'ContextMenu',
  PhysicalKeyboardKey.controlLeft: 'ControlLeft',
  PhysicalKeyboardKey.shiftLeft: 'ShiftLeft',
  PhysicalKeyboardKey.altLeft: 'AltLeft',
  PhysicalKeyboardKey.metaLeft: 'MetaLeft',
  PhysicalKeyboardKey.controlRight: 'ControlRight',
  PhysicalKeyboardKey.shiftRight: 'ShiftRight',
  PhysicalKeyboardKey.altRight: 'AltRight',
  PhysicalKeyboardKey.metaRight: 'MetaRight',
};

/// Phone keyboards send Enter and Backspace without a physical key behind
/// them, so these fall back to the key's meaning.
final _codeForLogical = <LogicalKeyboardKey, String>{
  LogicalKeyboardKey.enter: 'Enter',
  LogicalKeyboardKey.backspace: 'Backspace',
  LogicalKeyboardKey.delete: 'Delete',
  LogicalKeyboardKey.tab: 'Tab',
  LogicalKeyboardKey.escape: 'Escape',
  LogicalKeyboardKey.space: 'Space',
  LogicalKeyboardKey.arrowLeft: 'ArrowLeft',
  LogicalKeyboardKey.arrowRight: 'ArrowRight',
  LogicalKeyboardKey.arrowUp: 'ArrowUp',
  LogicalKeyboardKey.arrowDown: 'ArrowDown',
};

/// DOM `key` values for keys that type nothing.
final _namedKeys = <LogicalKeyboardKey, String>{
  LogicalKeyboardKey.enter: 'Enter',
  LogicalKeyboardKey.numpadEnter: 'Enter',
  LogicalKeyboardKey.backspace: 'Backspace',
  LogicalKeyboardKey.tab: 'Tab',
  LogicalKeyboardKey.escape: 'Escape',
  LogicalKeyboardKey.delete: 'Delete',
  LogicalKeyboardKey.insert: 'Insert',
  LogicalKeyboardKey.home: 'Home',
  LogicalKeyboardKey.end: 'End',
  LogicalKeyboardKey.pageUp: 'PageUp',
  LogicalKeyboardKey.pageDown: 'PageDown',
  LogicalKeyboardKey.arrowLeft: 'ArrowLeft',
  LogicalKeyboardKey.arrowRight: 'ArrowRight',
  LogicalKeyboardKey.arrowUp: 'ArrowUp',
  LogicalKeyboardKey.arrowDown: 'ArrowDown',
  LogicalKeyboardKey.shiftLeft: 'Shift',
  LogicalKeyboardKey.shiftRight: 'Shift',
  LogicalKeyboardKey.controlLeft: 'Control',
  LogicalKeyboardKey.controlRight: 'Control',
  LogicalKeyboardKey.altLeft: 'Alt',
  LogicalKeyboardKey.altRight: 'Alt',
  LogicalKeyboardKey.metaLeft: 'Meta',
  LogicalKeyboardKey.metaRight: 'Meta',
  LogicalKeyboardKey.capsLock: 'CapsLock',
  LogicalKeyboardKey.numLock: 'NumLock',
  LogicalKeyboardKey.scrollLock: 'ScrollLock',
  LogicalKeyboardKey.pause: 'Pause',
  LogicalKeyboardKey.contextMenu: 'ContextMenu',
  LogicalKeyboardKey.f1: 'F1',
  LogicalKeyboardKey.f2: 'F2',
  LogicalKeyboardKey.f3: 'F3',
  LogicalKeyboardKey.f4: 'F4',
  LogicalKeyboardKey.f5: 'F5',
  LogicalKeyboardKey.f6: 'F6',
  LogicalKeyboardKey.f7: 'F7',
  LogicalKeyboardKey.f8: 'F8',
  LogicalKeyboardKey.f9: 'F9',
  LogicalKeyboardKey.f10: 'F10',
  LogicalKeyboardKey.f11: 'F11',
  LogicalKeyboardKey.f12: 'F12',
};
