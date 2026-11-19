import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../platform/app_platform.dart';
import '../platform/web_kv.dart';
import 'replace_file.dart';
import 'package:app/platform/off_main.dart';

/// Serializes bulk app data away from the UI isolate. Writes are atomic and
/// coalesced, so a slow disk cannot build an unbounded queue of stale snapshots.
/// The web build keeps the same JSON in IndexedDB under `json:<name>`.
class BackgroundJsonStore {
  BackgroundJsonStore(this.name, {Directory? directory})
    : _directory = directory;

  final String name;
  final Directory? _directory;
  Future<String>? _path;
  Map<String, dynamic>? _pending;
  Future<void>? _writing;

  Future<String> _resolvePath() => _path ??= () async {
    final directory = _directory ?? await getApplicationSupportDirectory();
    await directory.create(recursive: true);
    return '${directory.path}/$name.json';
  }();

  Future<Map<String, dynamic>?> load({
    SharedPreferences? legacyPreferences,
    String? legacyKey,
  }) async {
    if (AppPlatform.isWeb) return _decode(await WebKv.read('json:$name'));
    final path = await _resolvePath();
    final loaded = await runOffMain(() async {
      final file = File(path);
      if (!await file.exists()) return null;
      final value = jsonDecode(await file.readAsString());
      return value is Map<String, dynamic> ? value : null;
    });
    final legacy = legacyKey == null
        ? null
        : legacyPreferences?.getString(legacyKey);
    if (loaded != null) {
      if (legacy != null) await legacyPreferences!.remove(legacyKey!);
      return loaded;
    }
    if (legacy == null) return null;
    final decoded = await runOffMain(() => jsonDecode(legacy));
    if (decoded is! Map<String, dynamic>) return null;
    // Do not remove the old copy until the replacement is safely on disk.
    await save(decoded);
    await legacyPreferences!.remove(legacyKey!);
    return decoded;
  }

  Future<void> save(Map<String, dynamic> snapshot) {
    _pending = Map<String, dynamic>.from(snapshot);
    return _writing ??= _drain();
  }

  Future<void> _drain() async {
    try {
      if (AppPlatform.isWeb) {
        while (_pending != null) {
          final snapshot = _pending!;
          _pending = null;
          await WebKv.write('json:$name', jsonEncode(snapshot));
        }
        return;
      }
      final path = await _resolvePath();
      while (_pending != null) {
        final snapshot = _pending!;
        _pending = null;
        await runOffMain(() async {
          final temp = File('$path.tmp');
          await temp.writeAsString(jsonEncode(snapshot), flush: true);
          await replaceFile(temp, path);
        });
      }
    } finally {
      _writing = null;
    }
  }

  static Map<String, dynamic>? _decode(String? text) {
    if (text == null) return null;
    final value = jsonDecode(text);
    return value is Map<String, dynamic> ? value : null;
  }
}
