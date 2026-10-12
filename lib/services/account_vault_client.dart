import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'account_crypto.dart';

/// What the relay stores for an account: ciphertext it can't read and a
/// version for compare-and-swap.
class VaultRecord {
  const VaultRecord({
    required this.version,
    required this.ciphertext,
    required this.updatedAt,
  });

  final int version;
  final String ciphertext;

  /// Unix ms, set by the relay.
  final int updatedAt;
}

/// A PUT lost the compare-and-swap: re-read at [version] and merge again.
class VaultConflict implements Exception {
  const VaultConflict(this.version);

  final int version;
}

/// The relay refused the request for a reason other than a conflict.
class VaultRequestFailed implements Exception {
  const VaultRequestFailed(this.statusCode, this.error);

  final int statusCode;
  final String error;

  @override
  String toString() =>
      'Relay answered $statusCode${error.isEmpty ? '' : ' ($error)'}';
}

/// Signed HTTP calls for the account vault. Every request carries an
/// Ed25519 signature over method, path, time and body hash; the relay only
/// ever learns the account's public key.
class AccountVaultClient {
  AccountVaultClient(this.relayHttpUrl, {http.Client? client})
    : _client = client ?? http.Client(),
      _ownsClient = client == null;

  final String relayHttpUrl;
  final http.Client _client;
  final bool _ownsClient;

  /// Milliseconds to add to the phone clock, learned from a `stale_time`
  /// reply so a wrong clock doesn't lock the account out.
  int _clockOffsetMs = 0;

  static const _vaultPath = '/api/account/vault';
  static const _accountPath = '/api/account';

  void close() {
    if (_ownsClient) _client.close();
  }

  Future<VaultRecord?> get(AccountKeys keys) async {
    final response = await _send(keys, 'GET', _vaultPath, null);
    if (response.statusCode == 404) return null;
    if (response.statusCode != 200) throw _failure(response);
    final body = jsonDecode(response.body);
    if (body is! Map) throw const VaultRequestFailed(200, 'invalid_reply');
    final ciphertext = body['ciphertext'];
    if (ciphertext is! String) {
      throw const VaultRequestFailed(200, 'invalid_reply');
    }
    return VaultRecord(
      version: (body['version'] as num?)?.toInt() ?? 0,
      ciphertext: ciphertext,
      updatedAt: (body['updatedAt'] as num?)?.toInt() ?? 0,
    );
  }

  /// Returns the new version. Throws [VaultConflict] on 409.
  Future<int> put(
    AccountKeys keys, {
    required int expectedVersion,
    required String ciphertext,
  }) async {
    final body = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'expectedVersion': expectedVersion,
          'ciphertext': ciphertext,
        }),
      ),
    );
    final response = await _send(keys, 'PUT', _vaultPath, body);
    final reply = _json(response);
    if (response.statusCode == 409) {
      throw VaultConflict((reply?['version'] as num?)?.toInt() ?? 0);
    }
    if (response.statusCode != 200) throw _failure(response);
    return (reply?['version'] as num?)?.toInt() ?? 0;
  }

  Future<void> delete(AccountKeys keys) async {
    final response = await _send(keys, 'DELETE', _accountPath, null);
    if (response.statusCode != 204 && response.statusCode != 404) {
      throw _failure(response);
    }
  }

  Future<http.Response> _send(
    AccountKeys keys,
    String method,
    String path,
    Uint8List? body, {
    bool retried = false,
  }) async {
    final now = DateTime.now().add(Duration(milliseconds: _clockOffsetMs));
    final headers = keys.signRequest(
      method: method,
      path: path,
      body: body ?? Uint8List(0),
      now: now,
    );
    if (body != null) headers['Content-Type'] = 'application/json';
    final request = http.Request(method, Uri.parse('$relayHttpUrl$path'))
      ..headers.addAll(headers);
    if (body != null) request.bodyBytes = body;
    final response = await http.Response.fromStream(
      await _client.send(request).timeout(const Duration(seconds: 20)),
    );
    if (response.statusCode == 401 && !retried) {
      final reply = _json(response);
      final serverTime = reply?['serverTime'];
      if (reply?['error'] == 'stale_time' && serverTime is num) {
        _clockOffsetMs =
            serverTime.toInt() - DateTime.now().millisecondsSinceEpoch;
        return _send(keys, method, path, body, retried: true);
      }
    }
    return response;
  }

  Map<String, dynamic>? _json(http.Response response) {
    try {
      final decoded = jsonDecode(response.body);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } catch (_) {
      return null;
    }
  }

  Exception _failure(http.Response response) {
    final error = _json(response)?['error'];
    if (response.statusCode >= 500 || response.statusCode == 0) {
      return HttpException('Relay answered ${response.statusCode}');
    }
    return VaultRequestFailed(
      response.statusCode,
      error is String ? error : '',
    );
  }
}
