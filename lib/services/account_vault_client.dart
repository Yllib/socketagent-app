import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'account_crypto.dart';

/// What the relay says about an account's PIN record. Nothing in it is
/// secret.
class RelayPin {
  const RelayPin({
    required this.id,
    required this.triesLeft,
    required this.wrongTotal,
    required this.lastWrongAt,
    required this.lastUnlockAt,
  });

  /// Names the PIN, as the vault and the Drive file do.
  final String id;

  /// Wrong tries a new device has left, counting the ones that came back.
  final int triesLeft;

  /// Every wrong try since the account's first PIN. No call clears it.
  final int wrongTotal;

  /// Unix ms, or 0 for never.
  final int lastWrongAt;

  /// Unix ms of the last right PIN from a new device, or 0 for never.
  final int lastUnlockAt;

  static RelayPin? _fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    if (id is! String) return null;
    int number(String field) => (raw[field] as num?)?.toInt() ?? 0;
    return RelayPin(
      id: id,
      triesLeft: number('triesLeft'),
      wrongTotal: number('wrongTotal'),
      lastWrongAt: number('lastWrongAt'),
      lastUnlockAt: number('lastUnlockAt'),
    );
  }
}

/// The relay's answer to a read of an account's vault.
sealed class VaultReply {
  const VaultReply();
}

/// The account is in use: ciphertext the relay cannot read and a version
/// for compare-and-swap.
final class VaultLive extends VaultReply {
  const VaultLive({
    required this.version,
    required this.ciphertext,
    required this.updatedAt,
    required this.pin,
  });

  final int version;
  final String ciphertext;

  /// Unix ms, set by the relay.
  final int updatedAt;

  /// Null when the account has no PIN record.
  final RelayPin? pin;
}

/// The account's master key changed and its record is frozen. The relay
/// does not say where it went. [wrapped] holds a handover box for each
/// device that stayed, by device public key, and [ciphertext] the device
/// list as the change left it, sealed with this account's vault key.
final class VaultMoved extends VaultReply {
  const VaultMoved({
    required this.version,
    required this.ciphertext,
    required this.wrapped,
  });

  final int version;
  final String ciphertext;
  final Map<String, String> wrapped;
}

/// The account was deleted. The relay keeps the record so it stays deleted.
final class VaultGone extends VaultReply {
  const VaultGone();
}

/// The relay has no record of the account.
final class VaultMissing extends VaultReply {
  const VaultMissing();
}

/// A PUT lost the compare-and-swap: re-read at [version] and merge again.
/// [rotated] means the account has moved and takes no more writes.
class VaultConflict implements Exception {
  const VaultConflict(this.version, {this.rotated = false});

  final int version;
  final bool rotated;
}

/// A PIN write named the wrong current PIN. [currentId] is the one the
/// relay holds, or null for none.
class PinConflict implements Exception {
  const PinConflict(this.currentId);

  final String? currentId;
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

/// The relay's answer to a PIN try from a device with no account.
sealed class UnlockReply {
  const UnlockReply();
}

/// The PIN was right. [relayKey] is the relay's half of the PIN key.
final class UnlockOpened extends UnlockReply {
  const UnlockOpened(this.relayKey);

  final Uint8List relayKey;
}

/// The PIN was wrong and the try was counted.
final class UnlockWrong extends UnlockReply {
  const UnlockWrong({required this.triesLeft, required this.retryAt});

  final int triesLeft;

  /// Unix ms when the next try comes back.
  final int retryAt;
}

/// No tries are left until [retryAt], unix ms. Nothing was counted.
final class UnlockLocked extends UnlockReply {
  const UnlockLocked(this.retryAt);

  final int retryAt;
}

/// The account moved or was deleted, or its PIN is no longer the one the
/// Drive file names. Nothing was counted.
final class UnlockChanged extends UnlockReply {
  const UnlockChanged();
}

/// The relay has no PIN record for the account.
final class UnlockNoPin extends UnlockReply {
  const UnlockNoPin();
}

/// HTTP calls for the account vault and its PIN. Every request but
/// [unlock] carries an Ed25519 signature over method, path, time and body
/// hash; the relay only ever learns the account's public key.
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
  static const _pinPath = '/api/account/pin';

  void close() {
    if (_ownsClient) _client.close();
  }

  /// Reads the account. A 404 the relay does not explain throws, so an
  /// answer this build does not know is never taken for a deleted account.
  Future<VaultReply> get(AccountKeys keys) async {
    final response = await _send(keys, 'GET', _vaultPath, null);
    final body = _json(response);
    if (response.statusCode == 404) {
      switch (body?['error']) {
        case 'not_found':
          return const VaultMissing();
        case 'gone':
          return const VaultGone();
        case 'moved':
          final ciphertext = body?['ciphertext'];
          final wrapped = body?['wrapped'];
          if (ciphertext is! String || wrapped is! Map) break;
          return VaultMoved(
            version: (body?['version'] as num?)?.toInt() ?? 0,
            ciphertext: ciphertext,
            wrapped: {
              for (final entry in wrapped.entries)
                if (entry.key case final String device)
                  if (entry.value case final String box) device: box,
            },
          );
      }
      throw _failure(response);
    }
    if (response.statusCode != 200) throw _failure(response);
    final ciphertext = body?['ciphertext'];
    if (ciphertext is! String) {
      throw const VaultRequestFailed(200, 'invalid_reply');
    }
    return VaultLive(
      version: (body?['version'] as num?)?.toInt() ?? 0,
      ciphertext: ciphertext,
      updatedAt: (body?['updatedAt'] as num?)?.toInt() ?? 0,
      pin: RelayPin._fromJson(body?['pin']),
    );
  }

  /// Returns the new version. Throws [VaultConflict] on 409. With
  /// [newAccountId] and [wrapped] the write freezes the account and leaves
  /// a handover box for each device in [wrapped].
  Future<int> put(
    AccountKeys keys, {
    required int expectedVersion,
    required String ciphertext,
    String? newAccountId,
    Map<String, String>? wrapped,
  }) async {
    final response = await _send(
      keys,
      'PUT',
      _vaultPath,
      _body({
        'expectedVersion': expectedVersion,
        'ciphertext': ciphertext,
        if (newAccountId != null)
          'rotation': {'newAccountId': newAccountId, 'wrapped': wrapped},
      }),
    );
    final reply = _json(response);
    if (response.statusCode == 409) {
      throw VaultConflict(
        (reply?['version'] as num?)?.toInt() ?? 0,
        rotated: reply?['rotated'] == true,
      );
    }
    if (response.statusCode != 200) throw _failure(response);
    return (reply?['version'] as num?)?.toInt() ?? 0;
  }

  /// Deletes the account. A missing or already deleted account succeeds.
  Future<void> delete(AccountKeys keys) async {
    final response = await _send(keys, 'DELETE', _accountPath, null);
    if (response.statusCode != 204 && response.statusCode != 404) {
      throw _failure(response);
    }
  }

  /// Sets the account's PIN record. [expectedId] is the PIN the relay
  /// holds now, or null for none. Throws [PinConflict] when it is not.
  Future<void> putPin(
    AccountKeys keys, {
    required String? expectedId,
    required String id,
    required Uint8List authKey,
    required Uint8List relayKey,
  }) async {
    final response = await _send(
      keys,
      'PUT',
      _pinPath,
      _body({
        'expectedId': expectedId,
        'id': id,
        'authKey': base64Encode(authKey),
        'relayKey': base64Encode(relayKey),
      }),
    );
    if (response.statusCode == 409) {
      final current = _json(response)?['id'];
      throw PinConflict(current is String ? current : null);
    }
    if (response.statusCode != 200) throw _failure(response);
  }

  /// Gives a new device its ten tries back. The relay allows one reset in
  /// 24 hours and answers 429 `too_soon` for another.
  Future<void> resetPin(AccountKeys keys) async {
    final response = await _send(keys, 'POST', '$_pinPath/reset', null);
    if (response.statusCode != 204) throw _failure(response);
  }

  /// Signed by the account a change moved to. Brings the PIN record, or its
  /// counts, over from [from], the account it left. Returns whether the
  /// account now has a PIN record. Safe to repeat.
  Future<bool> claimPin(AccountKeys keys, {required String from}) async {
    final response = await _send(
      keys,
      'POST',
      '$_pinPath/claim',
      _body({'from': from}),
    );
    if (response.statusCode != 200) throw _failure(response);
    return _json(response)?['pin'] == true;
  }

  /// One PIN try from a device that holds no account key, so nothing signs
  /// it. [id] names the PIN the Drive file was sealed for.
  Future<UnlockReply> unlock({
    required String account,
    required String id,
    required Uint8List authKey,
  }) async {
    final request =
        http.Request('POST', Uri.parse('$relayHttpUrl$_pinPath/unlock'))
          ..headers['Content-Type'] = 'application/json'
          ..bodyBytes = _body({
            'account': account,
            'id': id,
            'authKey': base64Encode(authKey),
          });
    final response = await http.Response.fromStream(
      await _client.send(request).timeout(const Duration(seconds: 20)),
    );
    final reply = _json(response);
    int number(String field) => (reply?[field] as num?)?.toInt() ?? 0;
    switch ((response.statusCode, reply?['error'])) {
      case (200, _):
        final relayKey = reply?['relayKey'];
        if (relayKey is! String) break;
        final bytes = base64Decode(relayKey);
        if (bytes.length != 32) break;
        return UnlockOpened(bytes);
      case (403, 'wrong_pin'):
        return UnlockWrong(
          triesLeft: number('triesLeft'),
          retryAt: number('retryAt'),
        );
      case (429, 'locked'):
        return UnlockLocked(number('retryAt'));
      case (409, 'changed'):
        return const UnlockChanged();
      case (404, 'no_pin'):
        return const UnlockNoPin();
    }
    if (response.statusCode == 200) {
      throw const VaultRequestFailed(200, 'invalid_reply');
    }
    throw _failure(response);
  }

  static Uint8List _body(Map<String, Object?> fields) =>
      utf8.encode(jsonEncode(fields));

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

  Map<String, Object?>? _json(http.Response response) {
    try {
      final decoded = jsonDecode(response.body);
      return decoded is Map ? Map<String, Object?>.from(decoded) : null;
    } catch (_) {
      return null;
    }
  }

  /// A 5xx is the relay being down, not an answer: it becomes an
  /// [HttpException], which callers treat like no network.
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
