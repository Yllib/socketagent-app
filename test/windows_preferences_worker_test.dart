import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:app/services/windows_preferences_worker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_windows/path_provider_windows.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';
import 'package:shared_preferences_windows/shared_preferences_windows.dart';

class _TestPaths extends PathProviderWindows {
  _TestPaths(this.directory);
  final String directory;
  @override
  Future<String> getApplicationSupportPath() async => directory;
}

PreferencesStoreFactory _windowsStoreAt(String directory) =>
    () => openWindowsPreferences(Directory(directory));

class _SlowPreferences extends InMemorySharedPreferencesStore {
  _SlowPreferences() : super.empty();

  @override
  Future<bool> setValue(String valueType, String key, Object value) {
    // Reproduce a synchronous Windows file/scan wait inside the actual worker.
    if (key == 'flutter.slow') sleep(const Duration(milliseconds: 350));
    if (key == 'flutter.fail') throw const FileSystemException('Test failure');
    return super.setValue(valueType, key, value);
  }
}

SharedPreferencesStorePlatform _createStore() => _SlowPreferences();
SharedPreferencesStorePlatform _failStartup() =>
    throw StateError('Test startup failure');

void main() {
  test(
    'Windows settings remain compatible across worker and plugin restarts',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'sa-preferences-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/shared_preferences.json');
      await file.writeAsString(
        jsonEncode({
          'flutter.pinned_sessions': ['thread-a', 'thread-b'],
          'flutter.session_drafts': '{"thread-a":"Unsent text"}',
          'other.setting': 'retain',
        }),
      );
      final worker = WindowsPreferencesWorker(
        createStore: _windowsStoreAt(directory.path),
      );
      try {
        expect((await worker.getAll())['flutter.pinned_sessions'], [
          'thread-a',
          'thread-b',
        ]);
        await Future.wait([
          worker.setValue('Bool', 'flutter.voice', true),
          worker.setValue('String', 'flutter.engine', 'system'),
        ]);
      } finally {
        worker.dispose();
      }
      final reopened = WindowsPreferencesWorker(
        createStore: _windowsStoreAt(directory.path),
      );
      try {
        expect(await reopened.getAllWithPrefix(''), {
          'flutter.pinned_sessions': ['thread-a', 'thread-b'],
          'flutter.session_drafts': '{"thread-a":"Unsent text"}',
          'other.setting': 'retain',
          'flutter.voice': true,
          'flutter.engine': 'system',
        });
      } finally {
        reopened.dispose();
      }
      final originalPlugin = SharedPreferencesWindows()
        ..pathProvider = _TestPaths(directory.path);
      expect((await originalPlugin.getAll())['flutter.pinned_sessions'], [
        'thread-a',
        'thread-b',
      ]);
      expect((await originalPlugin.getAll())['flutter.voice'], isTrue);
    },
    skip: !Platform.isWindows,
  );

  test('failed atomic write retains the previous preferences file', () async {
    final directory = await Directory.systemTemp.createTemp(
      'sa-preferences-failure-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/shared_preferences.json');
    await file.writeAsString('{"flutter.pinned_sessions":["keep"]}');
    await Directory('${file.path}.tmp').create();
    final worker = WindowsPreferencesWorker(
      createStore: _windowsStoreAt(directory.path),
    );
    addTearDown(worker.dispose);
    await expectLater(
      worker.setValue('Bool', 'flutter.voice', true),
      throwsA(isA<FileSystemException>()),
    );
    expect(jsonDecode(await file.readAsString()), {
      'flutter.pinned_sessions': ['keep'],
    });
  });

  test(
    'blocking storage leaves the caller responsive and preserves write order',
    () async {
      final worker = WindowsPreferencesWorker(createStore: _createStore);
      addTearDown(worker.dispose);
      await worker.getAll();
      var finished = false;
      var ticks = 0;
      final timer = Timer.periodic(
        const Duration(milliseconds: 10),
        (_) => ticks++,
      );
      addTearDown(timer.cancel);
      final slow = worker
          .setValue('String', 'flutter.slow', 'saved')
          .then((_) => finished = true);
      final later = worker.setValue('String', 'flutter.after', 'later');
      final read = worker.getAll();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(finished, isFalse);
      expect(ticks, greaterThan(1));
      expect(await read, {'flutter.slow': 'saved', 'flutter.after': 'later'});
      await Future.wait([slow, later]);
    },
  );

  test(
    'keeps all preference types, prefixes and allow-list behavior',
    () async {
      final worker = WindowsPreferencesWorker(createStore: _createStore);
      addTearDown(worker.dispose);
      await Future.wait([
        worker.setValue('StringList', 'flutter.pins', ['a', 'b']),
        worker.setValue('Bool', 'flutter.voice', true),
        worker.setValue('Double', 'flutter.rate', 0.75),
        worker.setValue('Int', 'flutter.count', 4),
        worker.setValue('String', 'other.setting', 'keep'),
      ]);
      expect(await worker.getAll(), {
        'flutter.pins': ['a', 'b'],
        'flutter.voice': true,
        'flutter.rate': 0.75,
        'flutter.count': 4,
      });
      await worker.clearWithParameters(
        ClearParameters(
          filter: PreferencesFilter(
            prefix: 'flutter.',
            allowList: {'flutter.voice', 'other.setting'},
          ),
        ),
      );
      expect((await worker.getAll()).containsKey('flutter.voice'), isFalse);
      expect(await worker.getAllWithPrefix('other.'), {
        'other.setting': 'keep',
      });
      await worker.remove('flutter.count');
      expect((await worker.getAll()).containsKey('flutter.count'), isFalse);
      await worker.clear();
      expect(await worker.getAll(), isEmpty);
      expect(await worker.getAllWithPrefix('other.'), {
        'other.setting': 'keep',
      });
    },
  );

  test(
    'failed operations complete with errors and do not strand later requests',
    () async {
      final worker = WindowsPreferencesWorker(createStore: _createStore);
      addTearDown(worker.dispose);
      await expectLater(
        worker.setValue('String', 'flutter.fail', 'value'),
        throwsA(isA<FileSystemException>()),
      );
      await worker.setValue('String', 'flutter.ok', 'saved');
      expect(await worker.getAll(), {'flutter.ok': 'saved'});
    },
  );

  test('startup failure completes waiting callers', () async {
    final worker = WindowsPreferencesWorker(createStore: _failStartup);
    addTearDown(worker.dispose);
    await expectLater(worker.getAll(), throwsStateError);
    await expectLater(worker.getAll(), throwsStateError);
  });
}
