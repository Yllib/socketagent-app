import 'dart:async';

import 'package:flutter/foundation.dart';

import 'desktop_shortcuts.dart';

/// Selects the desktop conversation pane without adding a full-screen route,
/// and passes keyboard shortcuts to the pane that handles them.
class DesktopWorkspaceController extends ChangeNotifier {
  int _revision = 0;
  int get revision => _revision;
  bool get hasConversation => _revision > 0;

  final _shortcuts = StreamController<DesktopShortcut>.broadcast();

  /// Session shortcuts go to the sidebar, find to the open chat.
  Stream<DesktopShortcut> get shortcuts => _shortcuts.stream;

  void openConversation() {
    _revision++;
    notifyListeners();
  }

  void sendShortcut(DesktopShortcut shortcut) => _shortcuts.add(shortcut);

  @override
  void dispose() {
    _shortcuts.close();
    super.dispose();
  }
}
