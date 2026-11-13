import 'dart:convert';

import 'package:app/services/account_crypto.dart';
import 'package:app/services/account_key_file.dart';
import 'package:app/services/account_pin.dart';
import 'package:app/services/drive_key_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pinenacl/x25519.dart';

// The account PIN's side of the Drive store: read every file and say what
// it is, write one file over whatever is there, and cut copies down to one.

/// The app data folder: files by id with Drive's creation time, and a log
/// of every request that changed or fetched one.
class _FakeDrive {
  final files = <String, ({String body, DateTime created})>{};
  final log = <String>[];

  /// Sizes the listing reports in place of each body's own length.
  final listedSizes = <String, int>{};

  /// Ids whose download answers 404 though the listing still has them.
  final vanished = <String>{};
  var _nextFile = 1;
  var _nextMinute = 0;

  String add(String body, {String? id}) {
    final fileId = id ?? 'file${_nextFile++}';
    files[fileId] = (
      body: body,
      created: DateTime.utc(2026, 11, 1, 0, _nextMinute++),
    );
    return fileId;
  }

  DriveKeyStore store() => DriveKeyStore(
    accessToken: () async => 'token',
    clientFactory: () => MockClient(_handle),
    baseUrl: 'https://drive.test',
  );

  Future<http.Response> _handle(http.Request request) async {
    expect(request.headers['Authorization'], 'Bearer token');
    final path = request.url.path;
    if (request.method == 'GET' && path == '/drive/v3/files') {
      expect(request.url.queryParameters['spaces'], 'appDataFolder');
      expect(
        request.url.queryParameters['q'],
        "name = 'socketagent-account-key.json'",
      );
      return http.Response(
        jsonEncode({
          'files': [
            // Newest first, so the store has to sort.
            for (final entry in files.entries.toList().reversed)
              {
                'id': entry.key,
                'createdTime': entry.value.created.toIso8601String(),
                'size':
                    '${listedSizes[entry.key] ?? utf8.encode(entry.value.body).length}',
              },
          ],
        }),
        200,
      );
    }
    if (request.method == 'POST' && path == '/upload/drive/v3/files') {
      expect(request.body, contains('"parents":["appDataFolder"]'));
      expect(request.body, contains('"name":"socketagent-account-key.json"'));
      final id = add(request.body.split('\r\n\r\n')[2].split('\r\n').first);
      log.add('create $id');
      return http.Response('{"id":"$id"}', 200);
    }
    final id = path.split('/').last;
    final file = files[id];
    if (file == null || vanished.contains(id)) {
      return http.Response('{"error":{"message":"File not found"}}', 404);
    }
    if (request.method == 'GET') {
      expect(request.url.queryParameters['alt'], 'media');
      log.add('get $id');
      return http.Response(file.body, 200);
    }
    if (request.method == 'DELETE') {
      files.remove(id);
      log.add('delete $id');
      return http.Response('', 204);
    }
    return http.Response('{"error":{"message":"unexpected"}}', 400);
  }
}

String _pinFile(AccountKeys keys) => encodeKeyFile(
  keys,
  pinId: Uint8List(16),
  salt: Uint8List(16),
  box: sealKeyBox(keys.masterKey, PrivateKey.generate().publicKey),
);

void main() {
  final keys = AccountKeys.generate();
  final plain = jsonEncode({'v': 1, 'masterKey': base64Encode(Uint8List(32))});

  test('readAll lists every file oldest first and says what each is', () async {
    final drive = _FakeDrive();
    final good = _pinFile(keys);
    drive
      ..add(plain)
      ..add(good)
      ..add('not a key file');

    final files = await drive.store().readAll();

    expect(files.map((file) => file.id), ['file1', 'file2', 'file3']);
    expect(files[0].content, isA<PlainKeyFile>());
    expect(
      files[1].content,
      isA<PinKeyFile>().having(
        (file) => file.account,
        'account',
        keys.accountId,
      ),
    );
    expect(files[2].content, isA<InvalidKeyFile>());
    expect(files[0].createdTime.isBefore(files[1].createdTime), isTrue);
    expect(drive.files, hasLength(3), reason: 'reading deletes nothing');
    expect(drive.log, ['get file1', 'get file2', 'get file3']);
  });

  test('readAll does not download a file listed as over 64 KB', () async {
    final drive = _FakeDrive();
    final id = drive.add(_pinFile(keys));
    drive.listedSizes[id] = keyFileMaxBytes + 1;

    final files = await drive.store().readAll();

    expect(files.single.content, isA<InvalidKeyFile>());
    expect(drive.log, isEmpty);
  });

  test('readAll fails when a listed file is gone', () {
    final drive = _FakeDrive();
    drive.vanished.add(drive.add(_pinFile(keys)));

    expect(
      drive.store().readAll(),
      throwsA(
        isA<DriveRequestFailed>().having(
          (error) => error.statusCode,
          'status',
          404,
        ),
      ),
    );
  });

  test('write deletes every file, then creates the one file left', () async {
    final drive = _FakeDrive();
    drive
      ..add(plain)
      ..add('not a key file');
    final content = _pinFile(keys);

    await drive.store().write(content);

    expect(drive.log, ['delete file1', 'delete file2', 'create file3']);
    expect(drive.files.values.single.body, content);
    final files = await drive.store().readAll();
    expect(files.single.content, isA<PinKeyFile>());
  });

  test('write into an empty folder creates the file', () async {
    final drive = _FakeDrive();

    await drive.store().write(_pinFile(keys));

    expect(drive.log, ['create file1']);
  });

  test('keepOldest deletes every copy but the oldest', () async {
    final drive = _FakeDrive();
    final content = _pinFile(keys);
    drive
      ..add(content)
      ..add(content)
      ..add(content);
    final store = drive.store();
    final files = await store.readAll();
    drive.log.clear();

    await store.keepOldest(files);

    expect(drive.log, ['delete file2', 'delete file3']);
    expect(drive.files.keys, ['file1']);
  });
}
