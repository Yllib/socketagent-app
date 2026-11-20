import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

/// The event web/install-prompt.js saved from `beforeinstallprompt`.
extension type _InstallPrompt._(JSObject _) implements JSObject {
  external JSPromise<JSAny?> prompt();
  external JSPromise<_Choice> get userChoice;
}

extension type _Choice._(JSObject _) implements JSObject {
  external String get outcome;
}

const _slot = 'socketagentInstallPrompt';

_InstallPrompt? _saved() {
  final value = web.window.getProperty<JSAny?>(_slot.toJS);
  return value.isA<JSObject>() ? value as _InstallPrompt : null;
}

bool webAppInstalled() =>
    web.window.matchMedia('(display-mode: standalone)').matches;

bool webInstallPromptReady() => _saved() != null;

Future<bool> webInstallPrompt() async {
  final saved = _saved();
  if (saved == null) return false;
  await saved.prompt().toDart;
  final choice = await saved.userChoice.toDart;
  // A prompt shows once; the browser fires a fresh event if it can again.
  web.window.setProperty(_slot.toJS, null);
  return choice.outcome == 'accepted';
}
