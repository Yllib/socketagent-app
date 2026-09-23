import 'dart:io';
import 'package:flutter/foundation.dart';
import 'download_part.dart';
import 'resumable_http_download.dart';
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
    return !File('$dir/.installing').existsSync() &&
        File('$dir/model.onnx').existsSync() &&
        File('$dir/voices.bin').existsSync() &&
        File('$dir/tokens.txt').existsSync() &&
        Directory('$dir/espeak-ng-data').existsSync();
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

    if (File(savePath).existsSync()) return;
    final part = DownloadPart(File('$savePath.part'));
    await ResumableHttpDownload().download(
      uri: url,
      part: part,
      onProgress: (received, total) {
        if (total != null && total > 0) {
          downloadProgress.value =
              progressStart +
              (progressEnd - progressStart) *
                  (received / total).clamp(0.0, 1.0);
        }
      },
    );
    await part.file.rename(savePath);
    if (await part.manifest.exists()) await part.manifest.delete();
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
      targetDir.createSync(recursive: true);
      await File('$dir/.installing').writeAsString('Installing', flush: true);

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
      }

      if (!File('$dir/model.onnx').existsSync()) {
        throw Exception('Download completed but model.onnx not found');
      }

      await File('$dir/.installing').delete();
      for (final archive in ['espeak-ng-data.tar.gz', 'dict.tar.gz']) {
        final file = File('$dir/$archive');
        if (await file.exists()) await file.delete();
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
