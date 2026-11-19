import 'dart:async';

import 'package:web/web.dart' as web;

const _lastActiveKey = 'sa.lastActive';
const _forgetKey = 'sa.forget';
const _aliveKey = 'sa.alive';

void start(Duration idleLimit) {
  final local = web.window.localStorage;
  final now = DateTime.now().millisecondsSinceEpoch;
  final last = int.tryParse(local.getItem(_lastActiveKey) ?? '');
  final idle = last != null && now - last > idleLimit.inMilliseconds;
  // Session storage outlives a reload but not the tab or the browser.
  final newSession = web.window.sessionStorage.getItem(_aliveKey) == null;
  if (idle || (!remember() && newSession)) _wipe(keepForget: true);
  web.window.sessionStorage.setItem(_aliveKey, '1');
  void touch() =>
      local.setItem(_lastActiveKey, '${DateTime.now().millisecondsSinceEpoch}');
  touch();
  Timer.periodic(const Duration(hours: 1), (_) => touch());
}

bool remember() => web.window.localStorage.getItem(_forgetKey) != '1';

void setRemember(bool value) {
  _wipe(keepForget: false);
  if (!value) web.window.localStorage.setItem(_forgetKey, '1');
  web.window.sessionStorage.setItem(_aliveKey, '1');
  web.window.location.reload();
}

/// Clears local and session storage (secure storage and preferences live
/// there) and the IndexedDB files WebKv writes.
void _wipe({required bool keepForget}) {
  final forget = web.window.localStorage.getItem(_forgetKey);
  web.window.localStorage.clear();
  web.window.sessionStorage.clear();
  web.window.indexedDB.deleteDatabase('socketagent');
  if (keepForget && forget != null) {
    web.window.localStorage.setItem(_forgetKey, forget);
  }
}
