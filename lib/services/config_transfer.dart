import 'dart:convert';
import 'dart:io';

class ExportPayload {
  final List<Map<String, dynamic>> servers;
  final String subscriberToken;
  final String subscriberEmail;

  ExportPayload({
    required this.servers,
    this.subscriberToken = '',
    this.subscriberEmail = '',
  });
}

class ConfigTransfer {
  static const String prefix = 'SCX';
  static const int version = 1;

  // Short key mappings
  static const _shortKeys = {
    'name': 'n',
    'host': 'h',
    'port': 'p',
    'token': 't',
    'useRelay': 'r',
    'relayUrl': 'ru',
    'pairingToken': 'pt',
    'serverPubkey': 'sp',
    'defaultCwd': 'd',
    'colorValue': 'c',
  };

  static const _longKeys = {
    'n': 'name',
    'h': 'host',
    'p': 'port',
    't': 'token',
    'r': 'useRelay',
    'ru': 'relayUrl',
    'pt': 'pairingToken',
    'sp': 'serverPubkey',
    'd': 'defaultCwd',
    'c': 'colorValue',
  };

  /// Encode server configs + subscriber info into a QR-ready string.
  static String encode(
    List<Map<String, dynamic>> configs, {
    String subscriberToken = '',
    String subscriberEmail = '',
  }) {
    // Convert to compact format with short keys, omit empty/default values
    final compact = configs.map((c) {
      final m = <String, dynamic>{};
      for (final entry in c.entries) {
        final shortKey = _shortKeys[entry.key];
        if (shortKey == null) continue;
        final v = entry.value;
        // Skip empty/default values
        if (v == null) continue;
        if (v is String && v.isEmpty) continue;
        if (v is bool && !v) continue;
        if (entry.key == 'port' && v == 8085) continue;
        m[shortKey] = v;
      }
      return m;
    }).toList();

    final payload = <String, dynamic>{'s': compact};
    if (subscriberToken.isNotEmpty) payload['st'] = subscriberToken;
    if (subscriberEmail.isNotEmpty) payload['se'] = subscriberEmail;

    final json = jsonEncode(payload);
    final compressed = gzip.encode(utf8.encode(json));
    final b64 = base64Encode(compressed);
    return '$prefix|$version|$b64';
  }

  /// Decode a QR string into an ExportPayload with servers + subscriber info.
  /// Throws [FormatException] on invalid format.
  static ExportPayload decode(String raw) {
    final parts = raw.split('|');
    if (parts.length != 3 || parts[0] != prefix) {
      throw const FormatException('Invalid format: expected SCX|version|data');
    }
    final ver = int.tryParse(parts[1]);
    if (ver == null || ver > version) {
      throw FormatException('Unsupported version: ${parts[1]}');
    }
    final compressed = base64Decode(parts[2]);
    final json = utf8.decode(gzip.decode(compressed));
    final payload = jsonDecode(json) as Map<String, dynamic>;
    final servers = (payload['s'] as List).map((s) {
      final full = <String, dynamic>{};
      for (final entry in (s as Map<String, dynamic>).entries) {
        final longKey = _longKeys[entry.key] ?? entry.key;
        full[longKey] = entry.value;
      }
      return full;
    }).toList();

    return ExportPayload(
      servers: servers,
      subscriberToken: payload['st'] as String? ?? '',
      subscriberEmail: payload['se'] as String? ?? '',
    );
  }

  /// Check if a string is an SCX config export payload.
  static bool isExportPayload(String raw) {
    return raw.startsWith('$prefix|');
  }
}
