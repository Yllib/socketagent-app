import 'dart:convert';
import 'dart:io';

import 'package:app/services/background_json_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('background-json-');
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() => directory.delete(recursive: true));

  test(
    'migrates drafts and session lists without changing other preferences',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final drafts = {'thread': 'Unsent text \n日本語 🔧'};
      final sessions = {
        'server': [
          {'id': 'thread', 'title': 'Existing session'},
        ],
      };
      await prefs.setString('session_drafts', jsonEncode(drafts));
      await prefs.setString('cached_session_lists_v1', jsonEncode(sessions));
      await prefs.setStringList('pinned_session_ids', ['thread']);
      for (final item in [
        ('drafts', 'session_drafts', drafts),
        ('sessions', 'cached_session_lists_v1', sessions),
      ]) {
        final store = BackgroundJsonStore(item.$1, directory: directory);
        expect(
          await store.load(legacyPreferences: prefs, legacyKey: item.$2),
          item.$3,
        );
        expect(prefs.containsKey(item.$2), isFalse);
        expect(
          await BackgroundJsonStore(item.$1, directory: directory).load(),
          item.$3,
        );
      }
      expect(prefs.getStringList('pinned_session_ids'), ['thread']);
    },
  );

  test(
    'burst writes persist the newest snapshot and leave no partial file',
    () async {
      final store = BackgroundJsonStore('burst', directory: directory);
      final writes = [
        for (var i = 0; i < 80; i++)
          store.save({'revision': i, 'content': 'draft $i'}),
      ];
      await Future.wait(writes);
      expect(await BackgroundJsonStore('burst', directory: directory).load(), {
        'revision': 79,
        'content': 'draft 79',
      });
      expect(await File('${directory.path}/burst.json.tmp').exists(), isFalse);
      await store.save({'revision': 80});
      expect(await store.load(), {'revision': 80});
    },
  );

  test('failed migration preserves the original preferences copy', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('session_drafts', '{"thread":"keep me"}');
    await Directory('${directory.path}/blocked.json').create();
    final store = BackgroundJsonStore('blocked', directory: directory);
    await expectLater(
      store.load(legacyPreferences: prefs, legacyKey: 'session_drafts'),
      throwsA(isA<FileSystemException>()),
    );
    expect(prefs.getString('session_drafts'), '{"thread":"keep me"}');
  });
}
