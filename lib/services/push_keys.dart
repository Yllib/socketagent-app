import 'dart:convert';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/server_config.dart';
import 'nacl_cipher.dart';
import 'transport_v2.dart';

/// One key that opens sealed pushes, with the public tag of the pairing
/// secret it comes from.
typedef PushKey = ({String tag, String key});

/// The keys that open sealed pushes (wire spec 11.4): for each computer, the
/// key of its current pairing secret and of the one before it. A push key is
/// derived one way from the secret and opens nothing but pushes.
///
/// They are kept in SharedPreferences because the background push handler
/// runs with no provider and already reads its other state there. The app's
/// secure storage is only ever opened from the main isolate.
class PushKeys {
  static const _prefsKey = 'push_keys_v1';

  /// The stored keys after [configs] are saved, given the [held] ones. A
  /// computer whose secret changed keeps the key it had as the previous one.
  /// A computer with no pairing secret, or one that is gone, has no keys.
  static Map<String, List<PushKey>> next(
    Map<String, List<PushKey>> held,
    Iterable<ServerConfig> configs,
  ) {
    final result = <String, List<PushKey>>{};
    for (final config in configs) {
      final secret = decodeKey32(config.pairingSecret);
      if (secret == null) continue;
      final tag = tagForSecret(secret);
      final before = held[config.id] ?? const <PushKey>[];
      result[config.id] = before.isNotEmpty && before.first.tag == tag
          ? before
          : [
              (tag: tag, key: base64Encode(pushKeyForSecret(secret))),
              if (before.isNotEmpty) before.first,
            ];
    }
    return result;
  }

  /// Brings the stored keys in line with [configs]. Called whenever the
  /// computers are loaded or saved, which covers every way a pairing secret
  /// arrives: a scanned code, a carry-over, `pairing_update` and the vault.
  static Future<void> sync(Iterable<ServerConfig> configs) async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_prefsKey);
    final updated = _encode(next(_decode(stored), configs));
    if (updated != stored) await prefs.setString(_prefsKey, updated);
  }

  /// The plaintext map of a sealed push, with its `serverId` added, or null
  /// when no key held for that computer opens it. Reads storage and changes
  /// nothing.
  static Future<Map<String, dynamic>?> open(Map<String, dynamic> data) async {
    final serverId = data['serverId'];
    final sealed = data['sealed'];
    if (serverId is! String || sealed is! String) return null;
    final prefs = await SharedPreferences.getInstance();
    // The background isolate keeps its own copy of the preferences, which
    // may be older than the last key the app stored.
    await prefs.reload();
    final keys = _decode(prefs.getString(_prefsKey))[serverId];
    if (keys == null) return null;
    final opened = openSealed(sealed, keys);
    return opened == null ? null : {...opened, 'serverId': serverId};
  }

  /// Opens the first entry of [sealed] that one of [keys] fits. The layout
  /// is `tag.base64(nonce | box)` entries joined with commas.
  static Map<String, String>? openSealed(String sealed, List<PushKey> keys) {
    for (final entry in sealed.split(',')) {
      final dot = entry.indexOf('.');
      if (dot < 0) continue;
      final tag = entry.substring(0, dot);
      for (final held in keys) {
        if (held.tag != tag) continue;
        try {
          final bytes = base64Decode(entry.substring(dot + 1));
          final plain = NaclCipher.secret(base64Decode(held.key)).open(
            Uint8List.sublistView(bytes, 24),
            Uint8List.sublistView(bytes, 0, 24),
          );
          final map = jsonDecode(utf8.decode(plain));
          if (map is! Map) continue;
          // FCM data is a map of strings, and the rest of the push code
          // reads it as one.
          return {
            for (final MapEntry(:key, :value) in map.entries)
              if (key is String &&
                  (value is String || value is bool || value is num))
                key: value.toString(),
          };
        } catch (_) {
          // Not sealed under this key after all. Another entry may be.
        }
      }
    }
    return null;
  }

  static Map<String, List<PushKey>> _decode(String? stored) {
    if (stored == null) return {};
    try {
      final map = jsonDecode(stored) as Map<String, dynamic>;
      return {
        for (final MapEntry(key: id, value: keys) in map.entries)
          id: [
            for (final key in keys as List)
              (tag: key['tag'] as String, key: key['key'] as String),
          ],
      };
    } catch (_) {
      return {};
    }
  }

  static String _encode(Map<String, List<PushKey>> keys) => jsonEncode({
    for (final MapEntry(key: id, value: held) in keys.entries)
      id: [
        for (final key in held) {'tag': key.tag, 'key': key.key},
      ],
  });
}
