import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Wrapper around flutter_secure_storage for managing sensitive credentials.
/// Uses Android Keystore (hardware-backed when available) for encryption.
class SecureStorageService {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(
      // Use Android Keystore for key storage
      resetOnError: true,
    ),
  );

  // ────────── Credentials ──────────

  /// Auth token for direct server connections
  Future<String?> getAuthToken() => _storage.read(key: 'auth_token');
  Future<void> setAuthToken(String value) =>
      _storage.write(key: 'auth_token', value: value);
  Future<void> deleteAuthToken() => _storage.delete(key: 'auth_token');

  /// Subscriber token for relay access
  Future<String?> getSubscriberToken() =>
      _storage.read(key: 'subscriber_token');
  Future<void> setSubscriberToken(String value) =>
      _storage.write(key: 'subscriber_token', value: value);
  Future<void> deleteSubscriberToken() =>
      _storage.delete(key: 'subscriber_token');

  /// Subscriber email
  Future<String?> getSubscriberEmail() =>
      _storage.read(key: 'subscriber_email');
  Future<void> setSubscriberEmail(String value) =>
      _storage.write(key: 'subscriber_email', value: value);
  Future<void> deleteSubscriberEmail() =>
      _storage.delete(key: 'subscriber_email');

  /// Server configurations (JSON string containing all server configs with their tokens)
  Future<String?> getServerConfigs() => _storage.read(key: 'server_configs');
  Future<void> setServerConfigs(String json) =>
      _storage.write(key: 'server_configs', value: json);

  /// User-provided ElevenLabs key for on-device BYOK TTS requests.
  Future<String?> getElevenLabsApiKey() =>
      _storage.read(key: 'elevenlabs_api_key');
  Future<void> setElevenLabsApiKey(String value) =>
      _storage.write(key: 'elevenlabs_api_key', value: value);
  Future<void> deleteElevenLabsApiKey() =>
      _storage.delete(key: 'elevenlabs_api_key');

  // ────────── NaCl Keys (E2E Encryption) ──────────

  /// NaCl secret key (base64) for relay E2E encryption
  Future<String?> getRelaySecretKey() => _storage.read(key: 'relay_secret_key');
  Future<void> setRelaySecretKey(String value) =>
      _storage.write(key: 'relay_secret_key', value: value);
  Future<void> deleteRelaySecretKey() =>
      _storage.delete(key: 'relay_secret_key');

  /// NaCl public key (base64)
  Future<String?> getRelayPublicKey() => _storage.read(key: 'relay_public_key');
  Future<void> setRelayPublicKey(String value) =>
      _storage.write(key: 'relay_public_key', value: value);
  Future<void> deleteRelayPublicKey() =>
      _storage.delete(key: 'relay_public_key');

  // ────────── Migration Helpers ──────────

  /// Check if we've migrated from SharedPreferences to SecureStorage
  Future<bool> isMigrated() async {
    final flag = await _storage.read(key: '_migration_complete');
    return flag == 'true';
  }

  /// Mark migration as complete
  Future<void> markMigrationComplete() =>
      _storage.write(key: '_migration_complete', value: 'true');

  /// Clear all secure storage (for testing or signout)
  Future<void> clearAll() => _storage.deleteAll();
}
