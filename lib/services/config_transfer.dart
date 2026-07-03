import 'dart:convert';
import 'dart:io';

import 'package:pinenacl/key_derivation.dart';
import 'package:pinenacl/x25519.dart';

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
  static const String prefix = 'SAX';
  static const String encryptedPrefix = 'SAXE';
  static const int version = 1;
  static const int encryptedVersion = 2;
  static const int _pbkdf2Iterations = 120000;

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

  /// Encode server configs + subscriber info into a legacy plaintext string.
  ///
  /// Kept for backwards compatibility with older exports. New UI should use
  /// [encodeEncrypted] because server configs include auth tokens.
  static String encode(
    List<Map<String, dynamic>> configs, {
    String subscriberToken = '',
    String subscriberEmail = '',
  }) {
    final payload = _compactPayload(
      configs,
      subscriberToken: subscriberToken,
      subscriberEmail: subscriberEmail,
    );
    final b64 = base64Encode(_compressPayload(payload));
    return '$prefix|$version|$b64';
  }

  /// Encode server configs + subscriber info into a passphrase-encrypted string.
  static String encodeEncrypted(
    List<Map<String, dynamic>> configs, {
    required String passphrase,
    String subscriberToken = '',
    String subscriberEmail = '',
  }) {
    final trimmedPassphrase = passphrase.trim();
    if (trimmedPassphrase.isEmpty) {
      throw const FormatException('Export passphrase is required');
    }

    final payload = _compactPayload(
      configs,
      subscriberToken: subscriberToken,
      subscriberEmail: subscriberEmail,
    );
    final plaintext = _compressPayload(payload);
    final salt = PineNaClUtils.randombytes(16);
    final key = _deriveExportKey(trimmedPassphrase, salt, _pbkdf2Iterations);
    final box = SecretBox(key);
    final encrypted = box.encrypt(plaintext);
    final packed = Uint8List.fromList(encrypted.asTypedList);

    return [
      encryptedPrefix,
      encryptedVersion.toString(),
      _pbkdf2Iterations.toString(),
      base64Encode(salt),
      base64Encode(packed),
    ].join('|');
  }

  static Map<String, dynamic> _compactPayload(
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
    return payload;
  }

  static Uint8List _compressPayload(Map<String, dynamic> payload) {
    final json = jsonEncode(payload);
    return Uint8List.fromList(gzip.encode(utf8.encode(json)));
  }

  static Uint8List _deriveExportKey(
    String passphrase,
    Uint8List salt,
    int iterations,
  ) {
    return PBKDF2.hmac_sha256(
      Uint8List.fromList(utf8.encode(passphrase)),
      salt,
      iterations,
      SecretBox.keyLength,
    );
  }

  /// Decode a QR string into an ExportPayload with servers + subscriber info.
  /// Throws [FormatException] on invalid format.
  static ExportPayload decode(String raw, {String? passphrase}) {
    final parts = raw.split('|');
    if (parts.isEmpty) {
      throw const FormatException('Invalid format');
    }

    late final List<int> compressed;
    if (parts[0] == encryptedPrefix) {
      if (parts.length != 5) {
        throw const FormatException(
          'Invalid encrypted format: expected SAXE|version|iterations|salt|data',
        );
      }
      final ver = int.tryParse(parts[1]);
      if (ver == null || ver > encryptedVersion) {
        throw FormatException('Unsupported encrypted version: ${parts[1]}');
      }
      final iterations = int.tryParse(parts[2]);
      if (iterations == null || iterations < 10000) {
        throw const FormatException('Invalid encrypted export parameters');
      }
      final trimmedPassphrase = passphrase?.trim() ?? '';
      if (trimmedPassphrase.isEmpty) {
        throw const FormatException('Passphrase is required');
      }
      try {
        final salt = Uint8List.fromList(base64Decode(parts[3]));
        final encrypted = EncryptedMessage.fromList(
          Uint8List.fromList(base64Decode(parts[4])),
        );
        final key = _deriveExportKey(trimmedPassphrase, salt, iterations);
        final decrypted = SecretBox(key).decrypt(encrypted);
        compressed = Uint8List.fromList(decrypted);
      } catch (_) {
        throw const FormatException(
          'Wrong passphrase or corrupted export data',
        );
      }
    } else if (parts[0] == prefix) {
      if (parts.length != 3) {
        throw const FormatException(
          'Invalid format: expected SAX|version|data',
        );
      }
      final ver = int.tryParse(parts[1]);
      if (ver == null || ver > version) {
        throw FormatException('Unsupported version: ${parts[1]}');
      }
      compressed = base64Decode(parts[2]);
    } else {
      throw const FormatException('Invalid format: expected SAXE| or SAX|');
    }

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

  /// Check if a string is an SAX config export payload.
  static bool isExportPayload(String raw) {
    return raw.startsWith('$prefix|') || raw.startsWith('$encryptedPrefix|');
  }

  static bool isEncryptedExportPayload(String raw) {
    return raw.startsWith('$encryptedPrefix|');
  }
}
