// Native builds keep files on disk and never call WebKv.

Never _unsupported() =>
    throw UnsupportedError('WebKv is only available in a browser');

Future<String?> webKvRead(String key) async => _unsupported();
Future<void> webKvWrite(String key, String value) async => _unsupported();
Future<void> webKvDelete(String key) async => _unsupported();
Future<List<String>> webKvKeys(String prefix) async => _unsupported();
