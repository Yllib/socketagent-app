import 'dart:convert';

import 'package:http/http.dart' as http;

import 'account_key_file.dart';

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

/// What Drive's listing says about one file under the name.
typedef _ListedFile = ({String id, DateTime createdTime, int? size});

/// Reads and writes `socketagent-account-key.json` in `appDataFolder`
/// through the Drive v3 REST API with a bearer token from [accessToken].
///
/// The store treats the files as sealed text and never sees a key. A
/// version 1 file, which holds a master key in the clear, is listed and
/// deleted like any other and its key is never read.
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

  /// Every file under the name, oldest first, with what each one is.
  /// Deletes nothing. A file Drive lists as larger than a key file can be is
  /// not downloaded. Throws when a listed file cannot be fetched, so a file
  /// that vanished mid-read is never taken for no file at all.
  Future<List<StoredKeyFile>> readAll() async {
    final client = _clientFactory();
    try {
      final files = <StoredKeyFile>[];
      for (final file in await _list(client)) {
        files.add((
          id: file.id,
          createdTime: file.createdTime,
          content: await _classify(client, file),
        ));
      }
      return files;
    } finally {
      client.close();
    }
  }

  /// Leaves one file under the name, holding [content]: deletes every file
  /// there, then creates one. Created first, the new file would be the
  /// newest of two, and an app from before the PIN deletes all but the
  /// oldest when it reads. If the create fails Drive holds no file until
  /// the next write.
  Future<void> write(String content) async {
    final client = _clientFactory();
    try {
      for (final file in await _list(client)) {
        await _delete(client, file.id);
      }
      await _create(client, content);
    } finally {
      client.close();
    }
  }

  /// Deletes every file in [files] but the first, which is the oldest. For
  /// a listing where each file is a copy of the current one, as two devices
  /// writing at once leave behind.
  Future<void> keepOldest(List<StoredKeyFile> files) async {
    final client = _clientFactory();
    try {
      for (final extra in files.skip(1)) {
        await _delete(client, extra.id);
      }
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

  /// Creates one file under the name holding [content], which is JSON.
  Future<void> _create(http.Client client, String content) async {
    final boundary = 'sa${DateTime.now().microsecondsSinceEpoch}';
    final metadata = jsonEncode({
      'name': fileName,
      'parents': ['appDataFolder'],
    });
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
  }

  /// Up to 100 files under the name, oldest first. Files with one creation
  /// time are ordered by id, so every device agrees on the oldest.
  Future<List<_ListedFile>> _list(http.Client client) async {
    final query = Uri(
      queryParameters: {
        'spaces': 'appDataFolder',
        'q': "name = '$fileName'",
        'fields': 'files(id,createdTime,size)',
        'pageSize': '100',
      },
    ).query;
    final response = await _send(client, 'GET', '/drive/v3/files?$query');
    if (response.statusCode != 200) throw _failure(response);
    final body = jsonDecode(response.body);
    final files = body is Map ? body['files'] : null;
    if (files is! List) throw const DriveRequestFailed(200, 'bad list');
    final out = <_ListedFile>[];
    for (final file in files) {
      if (file is! Map) continue;
      final id = file['id'];
      final created = DateTime.tryParse(file['createdTime'] as String? ?? '');
      // Drive sends the size as a decimal string.
      final size = file['size'];
      if (id is String && created != null) {
        out.add((
          id: id,
          createdTime: created,
          size: size is String ? int.tryParse(size) : null,
        ));
      }
    }
    out.sort((a, b) {
      final byTime = a.createdTime.compareTo(b.createdTime);
      return byTime != 0 ? byTime : a.id.compareTo(b.id);
    });
    return out;
  }

  /// Fetches [file] and says what it is, without the download when Drive
  /// already lists it as too large.
  Future<KeyFileContent> _classify(http.Client client, _ListedFile file) async {
    final size = file.size;
    if (size != null && size > keyFileMaxBytes) return const InvalidKeyFile();
    final response = await _send(
      client,
      'GET',
      '/drive/v3/files/${file.id}?alt=media',
    );
    if (response.statusCode != 200) throw _failure(response);
    return readKeyFile(response.bodyBytes);
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
