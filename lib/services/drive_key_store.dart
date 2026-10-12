import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// The account's master key as this app keeps it in the user's Google Drive
/// app data folder. Only this app, signed in as this user, can read it.
class DriveKeyFile {
  const DriveKeyFile({
    required this.id,
    required this.masterKey,
    required this.createdTime,
    this.rotatedBy,
  });

  final String id;
  final Uint8List masterKey;

  /// Drive's own creation time, which settles races between first devices.
  final DateTime createdTime;
  final String? rotatedBy;
}

/// Google refused the token. The user has to sign in again.
class DriveAuthFailed implements Exception {
  const DriveAuthFailed();

  @override
  String toString() => 'Google sign-in expired. Sign in again.';
}

class DriveRequestFailed implements Exception {
  const DriveRequestFailed(this.statusCode, this.detail);

  final int statusCode;
  final String detail;

  @override
  String toString() => 'Google Drive answered $statusCode $detail'.trim();
}

/// Reads and writes `socketagent-account-key.json` in `appDataFolder`
/// through the Drive v3 REST API with a bearer token from [accessToken].
class DriveKeyStore {
  DriveKeyStore({
    required Future<String> Function() accessToken,
    http.Client Function()? clientFactory,
    this.baseUrl = 'https://www.googleapis.com',
  }) : _accessToken = accessToken,
       _clientFactory = clientFactory ?? http.Client.new;

  static const fileName = 'socketagent-account-key.json';

  final Future<String> Function() _accessToken;
  final http.Client Function() _clientFactory;
  final String baseUrl;

  /// The key file, or null when the folder has none. When several exist
  /// (two first devices raced) the oldest wins and the rest are deleted.
  Future<DriveKeyFile?> read() async {
    final client = _clientFactory();
    try {
      final files = await _list(client);
      if (files.isEmpty) return null;
      final keep = files.first;
      for (final extra in files.skip(1)) {
        try {
          await _delete(client, extra.id);
        } catch (error) {
          debugPrint('[Drive] Extra key file kept: ${error.runtimeType}');
        }
      }
      return await _download(client, keep);
    } finally {
      client.close();
    }
  }

  /// Deletes every key file in the app data folder.
  Future<void> deleteAll() async {
    final client = _clientFactory();
    try {
      for (final file in await _list(client)) {
        await _delete(client, file.id);
      }
    } finally {
      client.close();
    }
  }

  /// Writes a new key file, then returns whichever file won: ours, or an
  /// older one another device wrote in the meantime.
  Future<DriveKeyFile> create(Uint8List masterKey, {required String by}) async {
    final client = _clientFactory();
    try {
      final boundary = 'sa${DateTime.now().microsecondsSinceEpoch}';
      final metadata = jsonEncode({
        'name': fileName,
        'parents': ['appDataFolder'],
      });
      final content = _content(masterKey, createdAt: _now, by: by);
      final body =
          '--$boundary\r\n'
          'Content-Type: application/json; charset=UTF-8\r\n\r\n'
          '$metadata\r\n'
          '--$boundary\r\n'
          'Content-Type: application/json\r\n\r\n'
          '$content\r\n'
          '--$boundary--';
      final response = await _send(
        client,
        'POST',
        '/upload/drive/v3/files?uploadType=multipart&fields=id',
        headers: {'Content-Type': 'multipart/related; boundary=$boundary'},
        body: body,
      );
      if (response.statusCode != 200) throw _failure(response);
    } finally {
      client.close();
    }
    final winner = await read();
    if (winner == null) throw const DriveRequestFailed(0, 'file vanished');
    return winner;
  }

  /// Replaces the key inside [fileId] after a device removal. The file's
  /// creation time stays, so it keeps winning any race.
  Future<DriveKeyFile> replace(
    String fileId,
    Uint8List masterKey, {
    required String by,
    required DateTime createdTime,
  }) async {
    final client = _clientFactory();
    try {
      final response = await _send(
        client,
        'PATCH',
        '/upload/drive/v3/files/$fileId?uploadType=media',
        headers: const {'Content-Type': 'application/json'},
        body: _content(
          masterKey,
          createdAt: createdTime.toUtc().toIso8601String(),
          by: by,
          rotated: true,
        ),
      );
      if (response.statusCode != 200) throw _failure(response);
      return DriveKeyFile(
        id: fileId,
        masterKey: masterKey,
        createdTime: createdTime,
        rotatedBy: by,
      );
    } finally {
      client.close();
    }
  }

  String get _now => DateTime.now().toUtc().toIso8601String();

  String _content(
    Uint8List masterKey, {
    required String createdAt,
    required String by,
    bool rotated = false,
  }) => jsonEncode({
    'v': 1,
    'masterKey': base64Encode(masterKey),
    'createdAt': createdAt,
    if (rotated) 'rotatedAt': _now,
    if (rotated) 'rotatedBy': by,
  });

  Future<List<({String id, DateTime createdTime})>> _list(
    http.Client client,
  ) async {
    final query = Uri(
      queryParameters: {
        'spaces': 'appDataFolder',
        'q': "name = '$fileName'",
        'fields': 'files(id,createdTime)',
        'pageSize': '10',
      },
    ).query;
    final response = await _send(client, 'GET', '/drive/v3/files?$query');
    if (response.statusCode != 200) throw _failure(response);
    final body = jsonDecode(response.body);
    final files = body is Map ? body['files'] : null;
    if (files is! List) throw const DriveRequestFailed(200, 'bad list');
    final out = <({String id, DateTime createdTime})>[];
    for (final file in files) {
      if (file is! Map) continue;
      final id = file['id'];
      final created = DateTime.tryParse(file['createdTime'] as String? ?? '');
      if (id is String && created != null) {
        out.add((id: id, createdTime: created));
      }
    }
    out.sort((a, b) {
      final byTime = a.createdTime.compareTo(b.createdTime);
      return byTime != 0 ? byTime : a.id.compareTo(b.id);
    });
    return out;
  }

  Future<DriveKeyFile> _download(
    http.Client client,
    ({String id, DateTime createdTime}) file,
  ) async {
    final response = await _send(
      client,
      'GET',
      '/drive/v3/files/${file.id}?alt=media',
    );
    if (response.statusCode != 200) throw _failure(response);
    final body = jsonDecode(response.body);
    final key = body is Map && body['v'] == 1 ? body['masterKey'] : null;
    final bytes = key is String ? base64Decode(key) : null;
    if (bytes == null || bytes.length != 32) {
      throw const DriveRequestFailed(200, 'unreadable key file');
    }
    return DriveKeyFile(
      id: file.id,
      masterKey: Uint8List.fromList(bytes),
      createdTime: file.createdTime,
      rotatedBy: body is Map ? body['rotatedBy'] as String? : null,
    );
  }

  Future<void> _delete(http.Client client, String id) async {
    final response = await _send(client, 'DELETE', '/drive/v3/files/$id');
    if (response.statusCode != 204 && response.statusCode != 404) {
      throw _failure(response);
    }
  }

  Future<http.Response> _send(
    http.Client client,
    String method,
    String pathAndQuery, {
    Map<String, String> headers = const {},
    String? body,
  }) async {
    final token = await _accessToken();
    final request = http.Request(method, Uri.parse('$baseUrl$pathAndQuery'))
      ..headers['Authorization'] = 'Bearer $token'
      ..headers.addAll(headers);
    if (body != null) request.body = body;
    final streamed = await client
        .send(request)
        .timeout(const Duration(seconds: 30));
    final response = await http.Response.fromStream(streamed);
    if (response.statusCode == 401) throw const DriveAuthFailed();
    return response;
  }

  static DriveRequestFailed _failure(http.Response response) {
    String detail = '';
    try {
      final body = jsonDecode(response.body);
      final error = body is Map ? body['error'] : null;
      detail = error is Map
          ? error['message'] as String? ?? ''
          : error?.toString() ?? '';
    } on FormatException {
      detail = '';
    }
    return DriveRequestFailed(response.statusCode, detail);
  }
}
