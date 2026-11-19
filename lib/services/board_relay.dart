import 'dart:convert';

import 'package:crypto/crypto.dart' as hashes;
import 'package:http/http.dart' as http;
import 'package:pinenacl/ed25519.dart';
import 'package:pinenacl/x25519.dart';

import 'account_crypto.dart';

/// The keys one board derives from its secret. The relay sees only the
/// board ID (the Ed25519 public key), signatures, and sealed records.
/// See docs/project-boards.md in the server repo for the wire contract.
class BoardKeys {
  BoardKeys._(this.boardKey, this.signingKey, this.boxKey);

  final Uint8List boardKey;
  final SigningKey signingKey;

  /// The X25519 key outside services seal intake items to. Only its public
  /// half leaves the device, inside an intake token.
  final PrivateKey boxKey;

  /// [secret] is standard base64 of 32 bytes.
  factory BoardKeys.fromSecret(String secret) {
    final raw = base64Decode(secret);
    if (raw.length != 32) throw ArgumentError('A board secret is 32 bytes');
    return BoardKeys._(
      _derive('socketagent-board-key-v1', raw),
      SigningKey(seed: _derive('socketagent-board-auth-v1', raw)),
      PrivateKey(_derive('socketagent-board-box-v1', raw)),
    );
  }

  /// A new random secret, standard base64.
  static String newSecret() => base64Encode(PineNaClUtils.randombytes(32));

  static Uint8List _derive(String info, List<int> secret) {
    final digest = hashes.sha512.convert([...utf8.encode(info), ...secret]);
    return Uint8List.fromList(digest.bytes.sublist(0, 32));
  }

  String get boardId =>
      base64UrlNoPad(Uint8List.fromList(signingKey.verifyKey.asTypedList));

  /// Base64 of nonce || secretbox(JSON of [record]).
  String seal(Map<String, Object?> record) {
    final sealed = SecretBox(
      boardKey,
    ).encrypt(Uint8List.fromList(utf8.encode(jsonEncode(record))));
    return base64Encode(sealed.asTypedList);
  }

  /// The record inside [ciphertext], or null when it doesn't open or isn't
  /// a JSON object.
  Map<String, Object?>? open(String ciphertext) {
    try {
      final packed = EncryptedMessage.fromList(
        Uint8List.fromList(base64Decode(ciphertext)),
      );
      final value = jsonDecode(
        utf8.decode(SecretBox(boardKey).decrypt(packed)),
      );
      return value is Map<String, Object?> ? value : null;
    } catch (_) {
      return null;
    }
  }

  /// A new intake key: its relay ID, and the token the user pastes into
  /// the outside service. The token holds the key's seed, so it is shown
  /// once and never stored.
  ({String id, String token}) newIntake(String relayUrl) {
    final seed = PineNaClUtils.randombytes(32);
    final id = base64UrlNoPad(
      Uint8List.fromList(SigningKey(seed: seed).verifyKey.asTypedList),
    );
    final payload = jsonEncode({
      'relay': relayUrl,
      'seed': base64Encode(seed),
      'boxKey': base64Encode(boxKey.publicKey.asTypedList),
    });
    return (
      id: id,
      token:
          'sa-intake-v1.${base64UrlNoPad(Uint8List.fromList(utf8.encode(payload)))}',
    );
  }

  Map<String, String> sign(String method, String path, List<int> body) {
    final time = DateTime.now().millisecondsSinceEpoch.toString();
    final message = [
      'socketagent-board-v1',
      method,
      path,
      time,
      hashes.sha256.convert(body).toString(),
    ].join('\n');
    final signature = signingKey.sign(Uint8List.fromList(utf8.encode(message)));
    return {
      'X-SA-Board': boardId,
      'X-SA-Time': time,
      'X-SA-Signature': base64Encode(signature.signature.asTypedList),
    };
  }
}

/// One sealed record as the relay returns it.
typedef RemoteRecord = ({String id, int version, int seq, String ciphertext});

sealed class BoardWrite {}

class BoardWritten extends BoardWrite {
  BoardWritten(this.version);
  final int version;
}

/// Someone else wrote the record first. [version] is the relay's current.
class BoardConflict extends BoardWrite {
  BoardConflict(this.version);
  final int version;
}

/// The board was deleted. Nothing will be stored for it again.
class BoardGone extends BoardWrite {}

/// The relay refused the record for good (too large, board full).
class BoardRejected extends BoardWrite {
  BoardRejected(this.reason);
  final String reason;
}

/// A network failure or a relay that isn't ready. Retry later.
class BoardRelayDown implements Exception {
  BoardRelayDown(this.reason);
  final String reason;
  @override
  String toString() => 'Board relay unavailable: $reason';
}

/// The board deleted on the relay.
class BoardDeleted implements Exception {}

/// The relay's board record API, for one board.
class BoardRelay {
  BoardRelay(this.baseUrl, this.keys, {http.Client? client})
    : _client = client ?? http.Client();

  /// The relay's HTTPS origin, for example https://relay.example.
  final String baseUrl;
  final BoardKeys keys;
  final http.Client _client;

  static const _timeout = Duration(seconds: 20);

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri.parse(baseUrl).replace(path: path, queryParameters: query);

  /// Records changed after [since], and the board's newest seq.
  Future<({int seq, List<RemoteRecord> records})> pull(int since) async {
    const path = '/api/board/records';
    final response = await _send(
      () => _client.get(
        _uri(path, {'since': '$since'}),
        headers: keys.sign('GET', path, const []),
      ),
    );
    if (response.statusCode == 410) throw BoardDeleted();
    if (response.statusCode != 200) {
      throw BoardRelayDown('HTTP ${response.statusCode}');
    }
    final body = jsonDecode(response.body);
    if (body is! Map) throw BoardRelayDown('bad reply');
    final seq = body['seq'];
    final list = body['records'];
    return (
      seq: seq is int ? seq : since,
      records: [
        if (list is List)
          for (final r in list)
            if (r case {
              'id': final String id,
              'version': final int version,
              'seq': final int seq,
              'ciphertext': final String ciphertext,
            })
              (id: id, version: version, seq: seq, ciphertext: ciphertext),
      ],
    );
  }

  /// Writes [record] as [id] if the relay still holds [expectedVersion]
  /// (0 for a new record).
  Future<BoardWrite> put(
    String id,
    int expectedVersion,
    Map<String, Object?> record,
  ) async {
    final path = '/api/board/records/$id';
    final body = utf8.encode(
      jsonEncode({
        'expectedVersion': expectedVersion,
        'ciphertext': keys.seal(record),
      }),
    );
    final response = await _send(
      () => _client.put(
        _uri(path),
        headers: {
          ...keys.sign('PUT', path, body),
          'Content-Type': 'application/json',
        },
        body: body,
      ),
    );
    final reply = _json(response.body);
    switch (response.statusCode) {
      case 200:
        final version = reply?['version'];
        if (version is int) return BoardWritten(version);
        throw BoardRelayDown('bad reply');
      case 409 when reply?['error'] == 'conflict':
        final version = reply?['version'];
        return BoardConflict(version is int ? version : 0);
      case 409 || 413:
        return BoardRejected('${reply?['error'] ?? response.statusCode}');
      case 410:
        return BoardGone();
      default:
        throw BoardRelayDown('HTTP ${response.statusCode}');
    }
  }

  /// Lets the intake key [intakeId] add items to this board.
  Future<void> addIntake(String intakeId) async {
    final path = '/api/board/intake-keys/$intakeId';
    final body = utf8.encode('{}');
    final response = await _send(
      () => _client.put(
        _uri(path),
        headers: {
          ...keys.sign('PUT', path, body),
          'Content-Type': 'application/json',
        },
        body: body,
      ),
    );
    switch (response.statusCode) {
      case 204 || 200:
        return;
      case 409:
        throw BoardRelayDown('This board has the most intake keys it can');
      case 410:
        throw BoardDeleted();
      default:
        throw BoardRelayDown('HTTP ${response.statusCode}');
    }
  }

  /// Stops the intake key [intakeId] from adding items. A key already gone
  /// counts.
  Future<void> removeIntake(String intakeId) async {
    final path = '/api/board/intake-keys/$intakeId';
    final response = await _send(
      () => _client.delete(
        _uri(path),
        headers: keys.sign('DELETE', path, const []),
      ),
    );
    if (response.statusCode != 204 &&
        response.statusCode != 200 &&
        response.statusCode != 410) {
      throw BoardRelayDown('HTTP ${response.statusCode}');
    }
  }

  /// Deletes the board and everything in it. A board already gone counts.
  Future<void> delete() async {
    const path = '/api/board';
    final response = await _send(
      () => _client.delete(
        _uri(path),
        headers: keys.sign('DELETE', path, const []),
      ),
    );
    if (response.statusCode != 204 && response.statusCode != 410) {
      throw BoardRelayDown('HTTP ${response.statusCode}');
    }
  }

  Future<http.Response> _send(Future<http.Response> Function() call) async {
    try {
      return await call().timeout(_timeout);
    } catch (error) {
      throw BoardRelayDown('$error');
    }
  }

  static Map<String, Object?>? _json(String text) {
    try {
      final value = jsonDecode(text);
      return value is Map<String, Object?> ? value : null;
    } catch (_) {
      return null;
    }
  }
}
