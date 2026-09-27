import 'dart:io';
import 'package:flutter/foundation.dart';
import 'model_archive.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum KokoroModel {
  v019,
  v10;

  String get dirName =>
      this == v10 ? 'kokoro-multi-lang-v1_0' : 'kokoro-en-v0_19';
  String get label => this == v10 ? 'v1.0 · Multilingual' : 'v0.19 · English';
  String get downloadLabel =>
      this == v10 ? '350 MB download' : '320 MB download';
  String get archiveSha256 => this == v10
      ? 'c5f7e2d2caf082bc1d20fb70334a61d99d20b484500aad32e7cf84c128ea3298'
      : '912804855a04745fa77a30be545b3f9a5d15c4d66db00b88cbcd4921df605ac7';
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
        Directory('$dir/espeak-ng-data').existsSync() &&
        (model != KokoroModel.v10 ||
            [
              'lexicon-us-en.txt',
              'lexicon-gb-en.txt',
            ].every((name) => File('$dir/$name').existsSync()));
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
    return null;
  }

  /// Public model assets download directly, without a paired server.
  Future<void> downloadModel({KokoroModel model = KokoroModel.v019}) async {
    if (_isDownloading) {
      throw StateError('A voice model is already downloading.');
    }
    _isDownloading = true;
    downloadProgress.value = 0;
    try {
      await installModelArchive(
        uri: Uri.parse(
          'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/${model.dirName}.tar.bz2',
        ),
        directory: Directory(await modelDirFor(model)),
        sha256Hex: model.archiveSha256,
        requiredFiles: [
          'model.onnx',
          'voices.bin',
          'tokens.txt',
          'espeak-ng-data/phontab',
          if (model == KokoroModel.v10) ...[
            'lexicon-us-en.txt',
            'lexicon-gb-en.txt',
          ],
        ],
        onProgress: (value) => downloadProgress.value = value,
      );
      await setActiveModel(model);
    } finally {
      _isDownloading = false;
      downloadProgress.value = null;
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
