import 'dart:io';
import 'package:flutter/foundation.dart';
import 'download_part.dart';
import 'resumable_http_download.dart';
import 'package:path_provider/path_provider.dart';

class AsrModelManager {
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

  Future<bool> isModelInstalled() async {
    final dir = await modelDir;
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
  Future<void> downloadModel() async {
    if (_isDownloading) return;
    _isDownloading = true;
    downloadProgress.value = 0.0;

    try {
      final base = await _baseDir;
      final baseDir = Directory(base);
      if (!baseDir.existsSync()) baseDir.createSync(recursive: true);

      // Download ASR model (~180MB) — 0% to 90%
      final asrInstalled = await isModelInstalled();
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

  Future<void> deleteModel() async {
    final base = await _baseDir;
    final d = Directory(base);
    if (d.existsSync()) {
      d.deleteSync(recursive: true);
      debugPrint('[AsrModel] All models deleted');
    }
  }
}
