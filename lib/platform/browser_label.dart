import 'browser_label_native.dart'
    if (dart.library.js_interop) 'browser_label_web.dart';

/// How the account's browser list names this browser, like "Chrome on
/// Windows". Empty outside the web build.
String browserLabel() => describeUserAgent(currentUserAgent());

/// Reads the browser and system out of a user agent string. Order matters:
/// Edge and Opera also claim Chrome, and Chrome also claims Safari.
String describeUserAgent(String agent) {
  if (agent.isEmpty) return '';
  final browser = switch (agent) {
    _ when agent.contains('Edg/') => 'Edge',
    _ when agent.contains('OPR/') => 'Opera',
    _ when agent.contains('SamsungBrowser/') => 'Samsung Internet',
    _ when agent.contains('Firefox/') => 'Firefox',
    _ when agent.contains('Chrome/') => 'Chrome',
    _ when agent.contains('Safari/') => 'Safari',
    _ => 'A browser',
  };
  final system = switch (agent) {
    _ when agent.contains('Android') => 'Android',
    _ when agent.contains('iPhone') || agent.contains('iPad') => 'iOS',
    _ when agent.contains('Windows') => 'Windows',
    _ when agent.contains('Mac OS X') => 'macOS',
    _ when agent.contains('CrOS') => 'ChromeOS',
    _ when agent.contains('Linux') => 'Linux',
    _ => '',
  };
  return system.isEmpty ? browser : '$browser on $system';
}
