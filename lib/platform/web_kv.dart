import 'web_kv_native.dart' if (dart.library.js_interop) 'web_kv_web.dart';

/// A string key-value store in the browser's IndexedDB. The web build keeps
/// the app's files here: what native builds write under the app support
/// folder. Only call it when AppPlatform.isWeb; native builds throw.
abstract final class WebKv {
  static Future<String?> read(String key) => webKvRead(key);
  static Future<void> write(String key, String value) => webKvWrite(key, value);
  static Future<void> delete(String key) => webKvDelete(key);

  /// Every key that starts with [prefix].
  static Future<List<String>> keys(String prefix) => webKvKeys(prefix);
}
