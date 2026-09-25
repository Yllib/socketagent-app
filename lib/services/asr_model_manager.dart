import 'dart:io';
import 'speech_recognition_settings.dart';
import 'package:flutter/foundation.dart';
import 'download_part.dart';
import 'resumable_http_download.dart';
import 'package:path_provider/path_provider.dart';

class AsrModelManager {
  AsrModel selectedModel = AsrModel.zipformer;
  AsrModel? downloadingModel;

  // Pinned Moonshine 0.1.5 streaming assets, without optional timestamp models.
  static const moonshineFiles = {
    'adapter.ort': [1319664, 2870368, 3651296],
    'cross_kv.ort': [1287544, 5356536, 11643776],
    'decoder_kv.ort': [32583720, 81878600, 146972408],
    'encoder.ort': [7675440, 44148576, 94705376],
    'frontend.model.ort': [23344, 26944, 28720],
    'frontend.weights.ort': [2093464, 7769464, 11889560],
    'streaming_config.json': [509, 512, 513],
    'tokenizer.bin': [249974, 249974, 249974],
  };
  static int moonshineFileSize(AsrModel model, String file) =>
      moonshineFiles[file]![AsrModel.values.indexOf(model) - 1];
  static String moonshineUrl(AsrModel model, String file) =>
      'https://download.moonshine.ai/model/${model.moonshineSize}-streaming-en/quantized_26_08_21/$file';

  Future<String> directoryFor(AsrModel model) async => model.isMoonshine
      ? '${await _baseDir}/moonshine-${model.moonshineSize}-streaming-en-26-08-21'
      : await modelDir;

  // ASR model — large zipformer trained on LibriSpeech + GigaSpeech (~180MB int8)
  static const _modelDirName = 'sherpa-onnx-streaming-zipformer-en-2023-06-21';
  static const _asrDownloadUrl =
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/$_modelDirName.tar.bz2';

  // Punctuation model
  static const _punctDirName = 'sherpa-onnx-online-punct-en-2024-08-06';
  static const _punctDownloadUrl =
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/punctuation-models/$_punctDirName.tar.bz2';

  // int8 quantized model files
  static const encoderFile = 'encoder-epoch-99-avg-1.int8.onnx';
  static const decoderFile = 'decoder-epoch-99-avg-1.int8.onnx';
  static const joinerFile = 'joiner-epoch-99-avg-1.int8.onnx';
  static const tokensFile = 'tokens.txt';

  // Punctuation model files
  static const punctModelFile = 'model.int8.onnx';
  static const punctVocabFile = 'bpe.vocab';

  final ValueNotifier<double?> downloadProgress = ValueNotifier(null);
  bool _isDownloading = false;
  bool get isDownloading => _isDownloading;

  Future<String> get _baseDir async {
    final dir = await getApplicationSupportDirectory();
    return '${dir.path}/asr-models';
  }

  Future<String> get modelDir async {
    return '${await _baseDir}/$_modelDirName';
  }

  Future<String> get punctDir async {
    return '${await _baseDir}/$_punctDirName';
  }

  Future<bool> isModelInstalled([AsrModel? model]) async {
    model ??= selectedModel;
    final dir = await directoryFor(model);
    if (model.isMoonshine) {
      if (File('$dir/.installing').existsSync()) return false;
      for (final name in moonshineFiles.keys) {
        final file = File('$dir/$name');
        if (!await file.exists() ||
            await file.length() != moonshineFileSize(model, name)) {
          return false;
        }
      }
      return true;
    }
    return !File('$dir/.installing').existsSync() &&
        [
          encoderFile,
          decoderFile,
          joinerFile,
          tokensFile,
        ].every((name) => File('$dir/$name').existsSync());
  }

  Future<bool> isPunctInstalled() async {
    final dir = await punctDir;
    return !File('$dir/.installing').existsSync() &&
        [
          punctModelFile,
          punctVocabFile,
        ].every((name) => File('$dir/$name').existsSync());
  }

  /// Download both ASR and punctuation models from GitHub releases.
  Future<void> downloadModel([AsrModel? model]) async {
    model ??= selectedModel;
    if (_isDownloading) {
      throw StateError('A speech model is already downloading');
    }
    downloadingModel = model;
    _isDownloading = true;
    downloadProgress.value = 0.0;

    try {
      final base = await _baseDir;
      final baseDir = Directory(base);
      if (!baseDir.existsSync()) baseDir.createSync(recursive: true);

      if (model.isMoonshine) {
        await _downloadMoonshine(model);
        return;
      }

      // Download ASR model (~180MB) — 0% to 90%
      final asrInstalled = await isModelInstalled(AsrModel.zipformer);
      if (!asrInstalled) {
        await _downloadAndExtract(
          url: _asrDownloadUrl,
          dirName: _modelDirName,
          basePath: base,
          verifyFile: encoderFile,
          progressStart: 0.0,
          progressEnd: 0.90,
        );
      }

      // Download punctuation model (~7MB) — 90% to 98%
      final punctInstalled = await isPunctInstalled();
      if (!punctInstalled) {
        await _downloadAndExtract(
          url: _punctDownloadUrl,
          dirName: _punctDirName,
          basePath: base,
          verifyFile: punctModelFile,
          progressStart: 0.90,
          progressEnd: 0.98,
        );
      }

      debugPrint('[AsrModel] All models installed');
      downloadProgress.value = null;
    } catch (e) {
      debugPrint('[AsrModel] Download failed: $e');
      downloadProgress.value = null;
      rethrow;
    } finally {
      _isDownloading = false;
      downloadingModel = null;
      downloadProgress.value = null;
    }
  }

  Future<void> _downloadAndExtract({
    required String url,
    required String dirName,
    required String basePath,
    required String verifyFile,
    required double progressStart,
    required double progressEnd,
  }) async {
    final targetDir = Directory('$basePath/$dirName');
    if (targetDir.existsSync()) {
      targetDir.deleteSync(recursive: true);
    }

    final archivePath = '$basePath/$dirName.tar.bz2';
    debugPrint('[AsrModel] Downloading $dirName from $url');

    final part = DownloadPart(File('$archivePath.part'));
    if (!File(archivePath).existsSync()) {
      await ResumableHttpDownload().download(
        uri: Uri.parse(url),
        part: part,
        onProgress: (received, total) {
          if (total != null && total > 0) {
            downloadProgress.value =
                progressStart +
                (received / total).clamp(0.0, 1.0) *
                    (progressEnd - progressStart);
          }
        },
      );
      await part.file.rename(archivePath);
      if (await part.manifest.exists()) await part.manifest.delete();
    }

    // Extract
    await targetDir.create(recursive: true);
    await File(
      '${targetDir.path}/.installing',
    ).writeAsString('Installing', flush: true);
    final result = await Process.run('tar', [
      'xjf',
      archivePath,
      '-C',
      basePath,
    ]);
    if (result.exitCode != 0) {
      throw Exception('tar extraction failed for $dirName: ${result.stderr}');
    }
    File(archivePath).deleteSync();

    // Verify
    if (!File('$basePath/$dirName/$verifyFile').existsSync()) {
      throw Exception(
        'Extraction succeeded but $verifyFile not found in $dirName',
      );
    }
    await File('${targetDir.path}/.installing').delete();
    debugPrint('[AsrModel] $dirName installed');
  }

  Future<void> _downloadMoonshine(AsrModel model) async {
    final dir = await directoryFor(model);
    await Directory(dir).create(recursive: true);
    final marker = File('$dir/.installing');
    await marker.writeAsString('Installing', flush: true);
    final total = moonshineFiles.keys.fold<int>(
      0,
      (sum, file) => sum + moonshineFileSize(model, file),
    );
    var completed = 0;
    for (final name in moonshineFiles.keys) {
      final expected = moonshineFileSize(model, name);
      final file = File('$dir/$name');
      if (!await file.exists() || await file.length() != expected) {
        final part = DownloadPart(File('$dir/$name.part'));
        await ResumableHttpDownload().download(
          uri: Uri.parse(moonshineUrl(model, name)),
          part: part,
          onProgress: (received, _) => downloadProgress.value =
              ((completed + received) / total).clamp(0.0, 1.0),
        );
        if (await part.file.length() != expected) {
          await part.file.delete();
          if (await part.manifest.exists()) await part.manifest.delete();
          throw StateError(
            'Incomplete Moonshine file: $name. Retry the download.',
          );
        }
        if (await file.exists()) await file.delete();
        await part.file.rename(file.path);
        if (await part.manifest.exists()) await part.manifest.delete();
      }
      completed += expected;
      downloadProgress.value = completed / total;
    }
    await marker.delete();
  }

  Future<void> deleteModel([AsrModel? model]) async {
    if (_isDownloading) throw StateError('Wait for the download to finish');
    final dir = Directory(await directoryFor(model ?? selectedModel));
    if (await dir.exists()) await dir.delete(recursive: true);
    // Punctuation is shared and small; keep it for a later Zipformer install.
  }
}
