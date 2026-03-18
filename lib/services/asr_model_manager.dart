import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
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
    return File('$dir/$encoderFile').existsSync();
  }

  Future<bool> isPunctInstalled() async {
    final dir = await punctDir;
    return File('$dir/$punctModelFile').existsSync();
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

    final client = http.Client();
    try {
      final request = http.Request('GET', Uri.parse(url));
      var response = await client.send(request);

      // Follow redirect if needed (GitHub releases)
      if (response.statusCode == 302 || response.statusCode == 301) {
        final redirectUrl = response.headers['location'];
        if (redirectUrl == null) throw Exception('Redirect without location');
        final redirectReq = http.Request('GET', Uri.parse(redirectUrl));
        response = await http.Client().send(redirectReq);
      }

      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}: ${response.reasonPhrase}');
      }

      final sink = File(archivePath).openWrite();
      int received = 0;
      final total = response.contentLength ?? 200 * 1024 * 1024;
      final progressRange = progressEnd - progressStart;

      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        downloadProgress.value = progressStart + (received / total).clamp(0.0, 1.0) * progressRange;
      }
      await sink.close();
      debugPrint('[AsrModel] Downloaded $dirName ($received bytes), extracting...');
    } finally {
      client.close();
    }

    // Extract
    final result = await Process.run('tar', ['xjf', archivePath, '-C', basePath]);
    if (result.exitCode != 0) {
      throw Exception('tar extraction failed for $dirName: ${result.stderr}');
    }
    File(archivePath).deleteSync();

    // Verify
    if (!File('$basePath/$dirName/$verifyFile').existsSync()) {
      throw Exception('Extraction succeeded but $verifyFile not found in $dirName');
    }
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
