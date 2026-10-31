import 'package:flutter/material.dart';

import '../../models/message.dart';
import '../state/ui_c_store.dart';

/// The phone's four places. Desktop shows board, sessions and the open
/// session side by side, so only [more] and [session] matter there.
enum UiCTab { board, sessions, session, more }

/// Pages under More. Wired ones read live data; the rest are visual stubs.
enum MorePage {
  home('More', Icons.grid_view_outlined),
  automations('Automations', Icons.schedule),
  reviews('Work reviews', Icons.rule),
  secrets('Secrets', Icons.key_outlined),
  computers('Computers', Icons.computer),
  files('Received files', Icons.download_outlined),
  browsers('Browser windows', Icons.web_asset),
  plans('HTML plans', Icons.article_outlined),
  terminal('Terminal', Icons.terminal),
  memories('Memories', Icons.psychology_outlined),
  settings('Settings', Icons.tune);

  const MorePage(this.label, this.icon);
  final String label;
  final IconData icon;
}

/// Which screen is up, and the one path to open a session so every entry
/// point (row tap, inbox item, notification, shortcut) behaves the same.
class UiCNav extends ChangeNotifier {
  UiCNav(this.store);

  final UiCStore store;
  UiCTab _tab = UiCTab.board;
  UiCTab get tab => _tab;

  /// Bumped when a session should scroll to a given entry.
  final ValueNotifier<String?> jumpToEntry = ValueNotifier(null);

  /// Set when the sessions list should take keyboard focus for quick switch.
  final ValueNotifier<int> focusSearch = ValueNotifier(0);

  /// Set when the open session should show its find bar.
  final ValueNotifier<int> findInSession = ValueNotifier(0);

  /// The page open under More.
  final ValueNotifier<MorePage> morePage = ValueNotifier(MorePage.home);

  void openMore(MorePage page) {
    morePage.value = page;
    go(UiCTab.more);
  }

  void go(UiCTab tab) {
    if (tab == _tab) return;
    if (_tab == UiCTab.session && tab != UiCTab.session) store.leaveSession();
    _tab = tab;
    notifyListeners();
  }

  void openSession(Session session) {
    store.openSession(session);
    _tab = UiCTab.session;
    notifyListeners();
  }

  void openSessionById(String sessionId, {String? serverId, String? entryId}) {
    store.openSessionById(sessionId, serverId: serverId);
    _tab = UiCTab.session;
    if (entryId != null) jumpToEntry.value = entryId;
    notifyListeners();
  }

  /// Shows the session ChatProvider already made current (a notification tap).
  void showCurrentSession() {
    final id = store.activeSessionId;
    if (id != null) {
      store.openSessionById(id, serverId: store.activeServerId);
    }
    _tab = UiCTab.session;
    notifyListeners();
  }

  void newSession({
    String? serverId,
    String? cwd,
    String? backend,
    bool fleeting = false,
  }) {
    store.newSession(
      serverId: serverId,
      cwd: cwd,
      backend: backend,
      fleeting: fleeting,
    );
    _tab = UiCTab.session;
    notifyListeners();
  }

  /// Opens the session after or before the open one in the list.
  void stepSession(int direction) {
    final list = store.sessions;
    if (list.isEmpty) return;
    final index = list.indexWhere(
      (s) =>
          s.id == store.activeSessionId && s.serverId == store.activeServerId,
    );
    final next = index < 0 ? 0 : (index + direction) % list.length;
    openSession(list[next < 0 ? list.length - 1 : next]);
  }

  @override
  void dispose() {
    jumpToEntry.dispose();
    focusSearch.dispose();
    findInSession.dispose();
    morePage.dispose();
    super.dispose();
  }
}
