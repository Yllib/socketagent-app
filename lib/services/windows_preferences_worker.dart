import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:path_provider_windows/path_provider_windows.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';

import 'background_json_store.dart';

typedef PreferencesStoreFactory =
    FutureOr<SharedPreferencesStorePlatform> Function();

Future<SharedPreferencesStorePlatform> _windowsStore() async {
  final path = await PathProviderWindows().getApplicationSupportPath();
  if (path == null) {
    throw StateError('Windows settings directory is unavailable');
  }
  return openWindowsPreferences(Directory(path));
}

/// Keep the Windows plugin's existing filename, key prefixes and JSON format.
/// Atomic replacement also protects settings if Desktop exits during a write.
Future<SharedPreferencesStorePlatform> openWindowsPreferences(
  Directory directory,
) async {
  final disk = BackgroundJsonStore('shared_preferences', directory: directory);
  final stored = await disk.load();
  return _AtomicPreferences(disk, Map<String, Object>.from(stored ?? {}));
}

class _AtomicPreferences extends InMemorySharedPreferencesStore {
  _AtomicPreferences(this.disk, Map<String, Object> values)
    : super.withData(values);
  final BackgroundJsonStore disk;

  Future<bool> _save() async {
    await disk.save(await super.getAllWithPrefix(''));
    return true;
  }

  @override
  Future<bool> setValue(String type, String key, Object value) async {
    await super.setValue(type, key, value);
    return _save();
  }

  @override
  Future<bool> remove(String key) async {
    await super.remove(key);
    return _save();
  }

  @override
  Future<bool> clearWithParameters(ClearParameters parameters) async {
    await super.clearWithParameters(parameters);
    return _save();
  }
}

/// The Windows plugin performs synchronous file I/O. Keep its existing format,
/// paths and filtering, but run storage on one worker so disk scanning cannot freeze
/// the window. One store processes requests in order, including read-after-write.
class WindowsPreferencesWorker extends SharedPreferencesStorePlatform {
  WindowsPreferencesWorker({
    PreferencesStoreFactory createStore = _windowsStore,
  }) : _createStore = createStore;

  final PreferencesStoreFactory _createStore;
  final _pending = <int, Completer<Object?>>{};
  Completer<SendPort>? _ready;
  ReceivePort? _responses;
  Isolate? _worker;
  int _nextId = 0;
  bool _disposed = false;

  Future<SendPort> _start() {
    if (_ready case final ready?) return ready.future;
    final ready = _ready = Completer<SendPort>();
    final responses = _responses = ReceivePort();
    responses.listen((message) {
      if (message is SendPort) {
        if (!ready.isCompleted) ready.complete(message);
      } else if (message is _Reply) {
        final pending = _pending.remove(message.id);
        if (message.error case final error?) {
          pending?.completeError(error, message.stack);
        } else {
          pending?.complete(message.value);
        }
      } else {
        _fail(StateError('Preferences worker stopped unexpectedly'));
      }
    });
    Isolate.spawn(
      _servePreferences,
      (_createStore, responses.sendPort),
      onError: responses.sendPort,
      onExit: responses.sendPort,
      debugName: 'Windows preferences',
    ).then((worker) {
      _worker = worker;
      if (_disposed) worker.kill(priority: Isolate.immediate);
    }, onError: (Object error, StackTrace stack) => _fail(error, stack));
    return ready.future;
  }

  Future<Object?> _request(_Request request) async {
    if (_disposed) throw StateError('Preferences worker is disposed');
    final port = await _start();
    if (_disposed) throw StateError('Preferences worker is disposed');
    final result = Completer<Object?>();
    _pending[request.id] = result;
    port.send(request);
    return result.future;
  }

  void _fail(Object error, [StackTrace? stack]) {
    if (_ready case final ready? when !ready.isCompleted) {
      ready.completeError(error, stack);
    }
    for (final pending in _pending.values) {
      pending.completeError(error, stack);
    }
    _pending.clear();
    _disposed = true;
    _responses?.close();
  }

  /// Normally lives for the application lifetime; also supports isolated tests.
  void dispose() {
    _fail(StateError('Preferences worker is disposed'));
    _worker?.kill(priority: Isolate.immediate);
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) async =>
      await _request(
            _Request(
              _nextId++,
              _Operation.set,
              key: key,
              valueType: valueType,
              value: value,
            ),
          )
          as bool;

  @override
  Future<bool> remove(String key) async =>
      await _request(_Request(_nextId++, _Operation.remove, key: key)) as bool;

  @override
  Future<Map<String, Object>> getAll() => getAllWithPrefix('flutter.');

  @override
  Future<Map<String, Object>> getAllWithPrefix(String prefix) =>
      getAllWithParameters(
        GetAllParameters(filter: PreferencesFilter(prefix: prefix)),
      );

  @override
  Future<Map<String, Object>> getAllWithParameters(
    GetAllParameters parameters,
  ) async =>
      await _request(
            _Request(
              _nextId++,
              _Operation.read,
              prefix: parameters.filter.prefix,
              allowList: parameters.filter.allowList,
            ),
          )
          as Map<String, Object>;

  @override
  Future<bool> clear() => clearWithPrefix('flutter.');

  @override
  Future<bool> clearWithPrefix(String prefix) => clearWithParameters(
    ClearParameters(filter: PreferencesFilter(prefix: prefix)),
  );

  @override
  Future<bool> clearWithParameters(ClearParameters parameters) async =>
      await _request(
            _Request(
              _nextId++,
              _Operation.clear,
              prefix: parameters.filter.prefix,
              allowList: parameters.filter.allowList,
            ),
          )
          as bool;
}

enum _Operation { read, set, remove, clear }

class _Request {
  const _Request(
    this.id,
    this.operation, {
    this.key = '',
    this.valueType = '',
    this.value,
    this.prefix = 'flutter.',
    this.allowList,
  });
  final int id;
  final _Operation operation;
  final String key;
  final String valueType;
  final Object? value;
  final String prefix;
  final Set<String>? allowList;
}

class _Reply {
  const _Reply(this.id, {this.value, this.error, this.stack});
  final int id;
  final Object? value;
  final Object? error;
  final StackTrace? stack;
}

Future<void> _servePreferences((PreferencesStoreFactory, SendPort) init) async {
  final store = await init.$1();
  final requests = ReceivePort();
  init.$2.send(requests.sendPort);
  await for (final message in requests) {
    if (message is! _Request) continue;
    try {
      final filter = PreferencesFilter(
        prefix: message.prefix,
        allowList: message.allowList,
      );
      final Object result = switch (message.operation) {
        _Operation.read => await store.getAllWithParameters(
          GetAllParameters(filter: filter),
        ),
        _Operation.set => await store.setValue(
          message.valueType,
          message.key,
          message.value!,
        ),
        _Operation.remove => await store.remove(message.key),
        _Operation.clear => await store.clearWithParameters(
          ClearParameters(filter: filter),
        ),
      };
      init.$2.send(_Reply(message.id, value: result));
    } catch (error, stack) {
      init.$2.send(_Reply(message.id, error: error, stack: stack));
    }
  }
}
