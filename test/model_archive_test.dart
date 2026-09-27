import 'dart:io';
import 'package:app/services/model_archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;
  late HttpServer server;
  late List<int> archive;
  late String digest;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('socketagent-model-test-');
    final source = Directory('${root.path}/source/model');
    await source.create(recursive: true);
    await File('${source.path}/model.onnx').writeAsString('fixture-model');
    final packed = '${root.path}/fixture.tar.bz2';
    final result = await Process.run('tar', [
      'cjf',
      packed,
      '-C',
      source.parent.path,
      'model',
    ]);
    expect(result.exitCode, 0);
    archive = await File(packed).readAsBytes();
    digest = sha256.convert(archive).toString();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.headers.set('etag', '"fixture-v1"');
      request.response.contentLength = archive.length;
      request.response.add(archive);
      await request.response.close();
    });
  });
  tearDown(() async {
    await server.close(force: true);
    await root.delete(recursive: true);
  });
  Future<void> install(Directory target, {String? hash, List<String>? files}) =>
      installModelArchive(
        uri: Uri.parse('http://127.0.0.1:${server.port}/model'),
        directory: target,
        sha256Hex: hash ?? digest,
        requiredFiles: files ?? ['model.onnx'],
        onProgress: (_) {},
      );

  test('verified archive installs without any paired server or auth', () async {
    final target = Directory('${root.path}/installed');
    await install(target);
    expect(
      await File('${target.path}/model.onnx').readAsString(),
      'fixture-model',
    );
    expect(File('${target.path}/.installing').existsSync(), isFalse);
    expect(File('${target.path}.tar.bz2.part').existsSync(), isFalse);
  });
  test('hash mismatch never installs bytes and clears bad partial', () async {
    final target = Directory('${root.path}/installed');
    await expectLater(install(target, hash: 'wrong'), throwsStateError);
    expect(File('${target.path}/model.onnx').existsSync(), isFalse);
    expect(File('${target.path}/.installing').existsSync(), isTrue);
    expect(File('${target.path}.tar.bz2.part').existsSync(), isFalse);
  });
  test(
    'missing model dependencies keep the install unavailable and archive retryable',
    () async {
      final target = Directory('${root.path}/installed');
      await expectLater(
        install(target, files: ['tokens.txt']),
        throwsStateError,
      );
      expect(File('${target.path}/.installing').existsSync(), isTrue);
      expect(File('${target.path}.tar.bz2.part').existsSync(), isTrue);
    },
  );
}
