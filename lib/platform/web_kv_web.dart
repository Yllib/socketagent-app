import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

const _database = 'socketagent';
const _store = 'files';

Future<web.IDBDatabase>? _opened;

Future<web.IDBDatabase> _db() => _opened ??= () {
  final done = Completer<web.IDBDatabase>();
  final request = web.window.indexedDB.open(_database, 1);
  request.onupgradeneeded = ((web.Event _) {
    final db = request.result as web.IDBDatabase;
    if (!db.objectStoreNames.contains(_store)) db.createObjectStore(_store);
  }).toJS;
  request.onsuccess = ((web.Event _) {
    done.complete(request.result as web.IDBDatabase);
  }).toJS;
  request.onerror = ((web.Event _) {
    _opened = null;
    done.completeError(StateError('IndexedDB did not open: ${request.error}'));
  }).toJS;
  return done.future;
}();

/// Runs one request in its own transaction and waits for it to finish.
Future<JSAny?> _run(
  web.IDBTransactionMode mode,
  web.IDBRequest Function(web.IDBObjectStore store) make,
) async {
  final db = await _db();
  final transaction = db.transaction(_store.toJS, mode);
  final request = make(transaction.objectStore(_store));
  final done = Completer<JSAny?>();
  transaction.oncomplete = ((web.Event _) {
    done.complete(request.result);
  }).toJS;
  transaction.onerror = ((web.Event _) {
    done.completeError(
      StateError('IndexedDB request failed: ${request.error}'),
    );
  }).toJS;
  transaction.onabort = ((web.Event _) {
    if (!done.isCompleted) {
      done.completeError(StateError('IndexedDB transaction aborted'));
    }
  }).toJS;
  return done.future;
}

Future<String?> webKvRead(String key) async {
  final value = await _run('readonly', (store) => store.get(key.toJS));
  return value.isA<JSString>() ? (value as JSString).toDart : null;
}

Future<void> webKvWrite(String key, String value) =>
    _run('readwrite', (store) => store.put(value.toJS, key.toJS));

Future<void> webKvDelete(String key) =>
    _run('readwrite', (store) => store.delete(key.toJS));

Future<List<String>> webKvKeys(String prefix) async {
  final value = await _run('readonly', (store) => store.getAllKeys());
  if (!value.isA<JSArray>()) return const [];
  return [
    for (final key in (value as JSArray<JSAny?>).toDart)
      if (key.isA<JSString>() && (key as JSString).toDart.startsWith(prefix))
        key.toDart,
  ];
}
