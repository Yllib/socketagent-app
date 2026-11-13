import 'dart:convert';
import 'dart:io';

import 'package:app/models/server_config.dart';
import 'package:app/services/nacl_cipher.dart';
import 'package:app/services/push_keys.dart';
import 'package:app/services/push_notification_service.dart';
import 'package:app/services/transport_v2.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Sealed pushes, wire spec 11.3 and 11.4: opened under the push key of the
/// current pairing secret or the one before it, dropped otherwise, with the
/// plain pushes of a computer on the old transport handled as before.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Uint8List secret(int seed) =>
      Uint8List.fromList(List.generate(32, (i) => (i + seed) % 256));

  ServerConfig computer(int seed, {String id = 'computer'}) => ServerConfig(
    id: id,
    name: 'Computer',
    host: '',
    port: 8085,
    token: '',
    serverPubkey: base64Encode(Uint8List(32)),
    pairingToken: 'room',
    pairingSecret: base64Encode(secret(seed)),
    transport: 2,
  );

  /// One sealed entry, as the computer writes it for the secret of [seed].
  String entry(int seed, Map<String, Object?> push, {Uint8List? key}) {
    final sealed = NaclCipher.secret(
      key ?? pushKeyForSecret(secret(seed)),
    ).seal(utf8.encode(jsonEncode(push)));
    return '${tagForSecret(secret(seed))}.'
        '${base64Encode([...sealed.nonce, ...sealed.cipherText])}';
  }

  Map<String, dynamic> push(String sealed, {String serverId = 'computer'}) => {
    'v': '2',
    'serverId': serverId,
    'sealed': sealed,
  };

  const finished = {'title': 'Done', 'body': 'Tests pass', 'kind': 'alert'};

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('a sealed push opens under the current and the previous key', () async {
    await PushKeys.sync([computer(1)]);
    expect(await PushKeys.open(push(entry(1, finished))), {
      ...finished,
      'serverId': 'computer',
    });

    // The secret changes, as after pairing_update. Pushes sealed for a
    // device that has not heard yet still open.
    await PushKeys.sync([computer(2)]);
    expect(await PushKeys.open(push(entry(2, finished))), isNotNull);
    expect(await PushKeys.open(push(entry(1, finished))), isNotNull);
    // The computer seals one push for several secrets.
    expect(
      await PushKeys.open(push('${entry(9, finished)},${entry(1, finished)}')),
      isNotNull,
    );

    // Only one secret back is kept.
    await PushKeys.sync([computer(3)]);
    expect(await PushKeys.open(push(entry(2, finished))), isNotNull);
    expect(await PushKeys.open(push(entry(1, finished))), isNull);
  });

  test('a push that no held key opens is dropped', () async {
    await PushKeys.sync([computer(1), computer(5, id: 'other')]);
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString('push_keys_v1');

    // No entry with a tag this phone holds.
    expect(await PushKeys.open(push(entry(9, finished))), isNull);
    // The right tag over a box sealed with some other key.
    expect(
      await PushKeys.open(
        push(entry(1, finished, key: pushKeyForSecret(secret(9)))),
      ),
      isNull,
    );
    // Another computer's push under this computer's name.
    expect(await PushKeys.open(push(entry(5, finished))), isNull);
    // A computer this phone has no secret for.
    expect(
      await PushKeys.open(push(entry(1, finished), serverId: 'unknown')),
      isNull,
    );
    expect(await PushKeys.open(push('not sealed at all')), isNull);

    // A push only reads the keys.
    expect(prefs.getString('push_keys_v1'), stored);
  });

  test('a computer with no pairing secret has no push keys', () async {
    await PushKeys.sync([computer(1)]);
    await PushKeys.sync([
      ServerConfig(
        id: 'computer',
        name: 'Computer',
        host: '',
        port: 8085,
        token: '',
      ),
    ]);
    expect(await PushKeys.open(push(entry(1, finished))), isNull);
  });

  test(
    'the handler shows sealed and plain pushes and drops the rest',
    () async {
      if (Platform.isWindows) return;
      FlutterLocalNotificationsPlatform.instance =
          AndroidFlutterLocalNotificationsPlugin();
      const channel = MethodChannel(
        'dexterous.com/flutter/local_notifications',
      );
      final shown = <Map>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'getNotificationAppLaunchDetails') {
          return {'notificationLaunchedApp': false};
        }
        if (call.method == 'show') shown.add(call.arguments as Map);
        return true;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      await PushKeys.sync([computer(1)]);

      Future<void> deliver(String id, Map<String, dynamic> data) =>
          PushNotificationService.handleRemoteMessage(
            RemoteMessage(messageId: id, data: data),
            foreground: false,
          );

      // A plain push, from a computer still on the old transport.
      await deliver('m1', {...finished, 'serverId': 'old-computer'});
      expect(shown.single['title'], 'Done');

      await deliver('m2', push(entry(1, {...finished, 'title': 'Sealed'})));
      expect(shown.last['title'], 'Sealed');

      // Text beside a seal that does not open is not shown.
      await deliver('m3', {
        ...push(entry(9, finished)),
        'title': 'Outside the seal',
        'body': 'Not from the computer',
      });
      expect(shown, hasLength(2));
    },
  );
}
