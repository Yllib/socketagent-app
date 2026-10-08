import 'dart:io';
import 'speech_recognition_settings.dart';
import 'model_archive.dart';
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
      : model == AsrModel.nemotron
      ? '${await _baseDir}/$nemotronDirName'
      : await modelDir;

  // ASR model — large zipformer trained on LibriSpeech + GigaSpeech (~180MB int8)
  static const _modelDirName = 'sherpa-onnx-streaming-zipformer-en-2023-06-21';
  static const _asrDownloadUrl =
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/$_modelDirName.tar.bz2';

  static const nemotronDirName =
      'sherpa-onnx-nemotron-speech-streaming-en-0.6b-560ms-int8-2026-04-25';
  static String encoderFor(AsrModel model) =>
      model == AsrModel.nemotron ? 'encoder.int8.onnx' : encoderFile;
  static String decoderFor(AsrModel model) =>
      model == AsrModel.nemotron ? 'decoder.int8.onnx' : decoderFile;
  static String joinerFor(AsrModel model) =>
      model == AsrModel.nemotron ? 'joiner.int8.onnx' : joinerFile;

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
          encoderFor(model),
          decoderFor(model),
          joinerFor(model),
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

      if (model == AsrModel.nemotron) {
        await installModelArchive(
          uri: Uri.parse(
            'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/$nemotronDirName.tar.bz2',
          ),
          directory: Directory(await directoryFor(model)),
          sha256Hex:
              '78e2b79fcf7271553a74402a76b771b09ea40117a39566a79f52235b23db6358',
          requiredFiles: [
            encoderFor(model),
            decoderFor(model),
            joinerFor(model),
            tokensFile,
          ],
          onProgress: (value) => downloadProgress.value = value,
        );
        return;
      }

      // Download ASR model (~180MB) — 0% to 90%
      final asrInstalled = await isModelInstalled(model);
      // These older release assets have no published SHA-256.
      if (!asrInstalled) {
        await installModelArchive(
          uri: Uri.parse(_asrDownloadUrl),
          directory: Directory('$base/$_modelDirName'),
          sha256Hex: null,
          requiredFiles: [
            encoderFor(model),
            decoderFor(model),
            joinerFor(model),
            tokensFile,
          ],
          onProgress: (value) => downloadProgress.value = value * 0.90,
        );
      }

      // Download punctuation model (~7MB) — 90% to 98%
      final punctInstalled = await isPunctInstalled();
      if (!punctInstalled) {
        await installModelArchive(
          uri: Uri.parse(_punctDownloadUrl),
          directory: Directory('$base/$_punctDirName'),
          sha256Hex: null,
          requiredFiles: [punctModelFile, punctVocabFile],
          onProgress: (value) => downloadProgress.value = 0.90 + value * 0.08,
          // Entries are stored as ./sherpa-onnx-online-punct-en-2024-08-06/...
          stripComponents: 2,
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
