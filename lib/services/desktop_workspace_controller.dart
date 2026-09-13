import 'package:flutter/foundation.dart';

/// Selects the desktop conversation pane without adding a full-screen route.
class DesktopWorkspaceController extends ChangeNotifier {
  int _revision = 0;
  int get revision => _revision;
  bool get hasConversation => _revision > 0;

  void openConversation() {
    _revision++;
    notifyListeners();
  }
}
