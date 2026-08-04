import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum KokoroModel {
  v019,
  v10;

  String get dirName =>
      this == v10 ? 'kokoro-multi-lang-v1_0' : 'kokoro-en-v0_19';
  String get label => this == v10
      ? 'v1.0 — 53 voices, multilingual'
      : 'v0.19 — 11 voices, English';
  String get shortLabel => this == v10 ? 'Kokoro v1.0' : 'Kokoro v0.19';
}

class KokoroModelManager {
  static const _modelKey = 'kokoro_active_model';

  final ValueNotifier<double?> downloadProgress = ValueNotifier(null);
  bool _isDownloading = false;
  bool get isDownloading => _isDownloading;

  Future<String> get _baseDir async {
    final dir = await getApplicationSupportDirectory();
    return '${dir.path}/tts-models';
  }

  Future<String> modelDirFor(KokoroModel model) async {
    return '${await _baseDir}/${model.dirName}';
  }

  /// Model dir for the active model.
  Future<String> get modelDir async => modelDirFor(await activeModel);

  /// Whether a specific model is installed.
  Future<bool> isModelVersionInstalled(KokoroModel model) async {
    final dir = await modelDirFor(model);
    return File('$dir/model.onnx').existsSync() &&
        File('$dir/voices.bin').existsSync();
  }

  /// Whether the active model is installed (backwards compat).
  Future<bool> isModelInstalled() async =>
      isModelVersionInstalled(await activeModel);

  /// The active model (user's selection).
  Future<KokoroModel> get activeModel async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getString(_modelKey);
    if (v == 'v10') return KokoroModel.v10;
    return KokoroModel.v019;
  }

  Future<void> setActiveModel(KokoroModel model) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_modelKey, model == KokoroModel.v10 ? 'v10' : 'v019');
  }

  // Compat shims for existing code
  Future<KokoroModel> get activeVariant => activeModel;
  Future<KokoroModel> get selectedVariant => activeModel;
  Future<KokoroModel> get installedVariant => activeModel;

  /// Path to the active model.onnx file.
  Future<String?> get activeModelPath async {
    final model = await activeModel;
    final dir = await modelDirFor(model);
    final p = '$dir/model.onnx';
    if (File(p).existsSync()) return p;
    // Fallback: try the other model
    for (final m in KokoroModel.values) {
      final other = '${await modelDirFor(m)}/model.onnx';
      if (File(other).existsSync()) return other;
    }
    return null;
  }

  /// Download a file from the server.
  Future<void> _downloadFile({
    required String serverHost,
    required int serverPort,
    required String authToken,
    required String fileName,
    required String savePath,
    required String modelDirName,
    double progressStart = 0.0,
    double progressEnd = 1.0,
  }) async {
    final url = Uri.parse(
      'http://$serverHost:$serverPort/tts-model?token=$authToken&file=$fileName&model=$modelDirName',
    );
    debugPrint('[KokoroModel] Downloading $fileName from $modelDirName');

    final request = http.Request('GET', url);
    final response = await http.Client().send(request);

    if (response.statusCode != 200) {
      throw Exception(
        'SocketAgent returned ${response.statusCode} for $fileName',
      );
    }

    final total = response.contentLength ?? 0;
    final tmpPath = '$savePath.tmp';
    final sink = File(tmpPath).openWrite();
    int received = 0;

    await for (final chunk in response.stream) {
      sink.add(chunk);
      received += chunk.length;
      if (total > 0) {
        final fileProgress = (received / total).clamp(0.0, 1.0);
        downloadProgress.value =
            progressStart + (progressEnd - progressStart) * fileProgress;
      }
    }
    await sink.close();
    File(tmpPath).renameSync(savePath);
    debugPrint('[KokoroModel] Downloaded $fileName ($received bytes)');
  }

  /// Download a specific model version.
  Future<void> downloadModel({
    required String serverHost,
    required int serverPort,
    required String authToken,
    KokoroModel model = KokoroModel.v019,
  }) async {
    if (_isDownloading) return;
    _isDownloading = true;
    downloadProgress.value = 0.0;

    try {
      final dir = await modelDirFor(model);
      final targetDir = Directory(dir);
      if (targetDir.existsSync()) {
        targetDir.deleteSync(recursive: true);
      }
      targetDir.createSync(recursive: true);

      // Download model.onnx (largest)
      await _downloadFile(
        serverHost: serverHost,
        serverPort: serverPort,
        authToken: authToken,
        fileName: 'model.onnx',
        savePath: '$dir/model.onnx',
        modelDirName: model.dirName,
        progressStart: 0.0,
        progressEnd: 0.75,
      );

      // Download voices.bin
      await _downloadFile(
        serverHost: serverHost,
        serverPort: serverPort,
        authToken: authToken,
        fileName: 'voices.bin',
        savePath: '$dir/voices.bin',
        modelDirName: model.dirName,
        progressStart: 0.75,
        progressEnd: 0.88,
      );

      // Download tokens.txt
      await _downloadFile(
        serverHost: serverHost,
        serverPort: serverPort,
        authToken: authToken,
        fileName: 'tokens.txt',
        savePath: '$dir/tokens.txt',
        modelDirName: model.dirName,
        progressStart: 0.88,
        progressEnd: 0.89,
      );

      // Download espeak-ng-data (tar.gz)
      final espeakTarPath = '$dir/espeak-ng-data.tar.gz';
      await _downloadFile(
        serverHost: serverHost,
        serverPort: serverPort,
        authToken: authToken,
        fileName: 'espeak-ng-data',
        savePath: espeakTarPath,
        modelDirName: model.dirName,
        progressStart: 0.89,
        progressEnd: 0.93,
      );
      downloadProgress.value = 0.93;
      final result = await Process.run('tar', [
        'xzf',
        espeakTarPath,
        '-C',
        dir,
      ]);
      if (result.exitCode != 0) {
        throw Exception('espeak-ng-data extraction failed: ${result.stderr}');
      }
      File(espeakTarPath).deleteSync();

      // v1.0 needs lexicon files and dict directory for multilingual support
      if (model == KokoroModel.v10) {
        // Download lexicon files
        for (final lexFile in [
          'lexicon-us-en.txt',
          'lexicon-gb-en.txt',
          'lexicon-zh.txt',
        ]) {
          await _downloadFile(
            serverHost: serverHost,
            serverPort: serverPort,
            authToken: authToken,
            fileName: lexFile,
            savePath: '$dir/$lexFile',
            modelDirName: model.dirName,
            progressStart: 0.93,
            progressEnd: 0.95,
          );
        }

        // Download dict directory (tar.gz, for Chinese text segmentation)
        final dictTarPath = '$dir/dict.tar.gz';
        await _downloadFile(
          serverHost: serverHost,
          serverPort: serverPort,
          authToken: authToken,
          fileName: 'dict',
          savePath: dictTarPath,
          modelDirName: model.dirName,
          progressStart: 0.95,
          progressEnd: 0.98,
        );
        downloadProgress.value = 0.98;
        final dictResult = await Process.run('tar', [
          'xzf',
          dictTarPath,
          '-C',
          dir,
        ]);
        if (dictResult.exitCode != 0) {
          throw Exception('dict extraction failed: ${dictResult.stderr}');
        }
        File(dictTarPath).deleteSync();
      }

      if (!File('$dir/model.onnx').existsSync()) {
        throw Exception('Download completed but model.onnx not found');
      }

      await setActiveModel(model);
      debugPrint('[KokoroModel] ${model.shortLabel} installed at $dir');
      downloadProgress.value = null;
    } catch (e) {
      debugPrint('[KokoroModel] Download failed: $e');
      downloadProgress.value = null;
      rethrow;
    } finally {
      _isDownloading = false;
    }
  }

  /// Delete a specific model version.
  Future<void> deleteModelVersion(KokoroModel model) async {
    final dir = await modelDirFor(model);
    final d = Directory(dir);
    if (d.existsSync()) {
      d.deleteSync(recursive: true);
      debugPrint('[KokoroModel] ${model.shortLabel} deleted');
    }
    // If active model was deleted, switch to the other if available
    final active = await activeModel;
    if (active == model) {
      final other = model == KokoroModel.v019
          ? KokoroModel.v10
          : KokoroModel.v019;
      if (await isModelVersionInstalled(other)) {
        await setActiveModel(other);
      }
    }
  }

  /// Delete all models.
  Future<void> deleteModel() async {
    for (final m in KokoroModel.values) {
      await deleteModelVersion(m);
    }
  }
}
