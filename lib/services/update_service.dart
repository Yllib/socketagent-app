import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:open_filex/open_filex.dart';
import 'package:shared_preferences/shared_preferences.dart';

class UpdateInfo {
  final String latestVersion;
  final String downloadUrl;
  final String currentVersion;
  final bool updateAvailable;

  UpdateInfo({
    required this.latestVersion,
    required this.downloadUrl,
    required this.currentVersion,
    required this.updateAvailable,
  });
}

class UpdateService extends ChangeNotifier {
  static const _versionUrl =
      'https://raw.githubusercontent.com/Yllib/socketclaude/master/app-version.json';

  UpdateInfo? _updateInfo;
  double? _downloadProgress;
  bool _isDownloading = false;
  String? _error;

  UpdateInfo? get updateInfo => _updateInfo;
  double? get downloadProgress => _downloadProgress;
  bool get isDownloading => _isDownloading;
  String? get error => _error;
  bool get updateAvailable => _updateInfo?.updateAvailable ?? false;

  /// Check GitHub for a newer version.
  Future<UpdateInfo?> checkForUpdate() async {
    _error = null;
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final currentVersion = packageInfo.version;

      final cacheBust = DateTime.now().millisecondsSinceEpoch;
      final response = await http.get(Uri.parse('$_versionUrl?t=$cacheBust'))
          .timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
        _error = 'Could not check for updates (${response.statusCode})';
        notifyListeners();
        return null;
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final latestVersion = data['version'] as String? ?? currentVersion;
      final downloadUrl = data['url'] as String? ?? '';

      debugPrint('[Update] current=$currentVersion latest=$latestVersion newer=${_isNewer(latestVersion, currentVersion)}');

      _updateInfo = UpdateInfo(
        latestVersion: latestVersion,
        downloadUrl: downloadUrl,
        currentVersion: currentVersion,
        updateAvailable: _isNewer(latestVersion, currentVersion),
      );
      notifyListeners();
      return _updateInfo;
    } catch (e) {
      _error = 'Update check failed: $e';
      notifyListeners();
      return null;
    }
  }

  /// Download the APK and open the installer.
  Future<void> downloadAndInstall() async {
    if (_updateInfo == null || _updateInfo!.downloadUrl.isEmpty) return;
    if (_isDownloading) return;

    _isDownloading = true;
    _downloadProgress = 0;
    _error = null;
    notifyListeners();

    try {
      final cacheDir = await getTemporaryDirectory();
      final updateDir = Directory('${cacheDir.path}/updates');
      if (!await updateDir.exists()) await updateDir.create(recursive: true);

      final apkPath = '${updateDir.path}/socketclaude-${_updateInfo!.latestVersion}.apk';
      final apkFile = File(apkPath);

      // Delete old APKs
      if (await updateDir.exists()) {
        for (final f in updateDir.listSync()) {
          if (f is File && f.path != apkPath) f.deleteSync();
        }
      }

      // Download with progress
      final request = http.Request('GET', Uri.parse(_updateInfo!.downloadUrl));
      final streamedResponse = await http.Client().send(request);

      if (streamedResponse.statusCode != 200) {
        throw Exception('Download failed (${streamedResponse.statusCode})');
      }

      final totalBytes = streamedResponse.contentLength ?? 0;
      int receivedBytes = 0;
      final sink = apkFile.openWrite();

      await for (final chunk in streamedResponse.stream) {
        sink.add(chunk);
        receivedBytes += chunk.length;
        if (totalBytes > 0) {
          _downloadProgress = receivedBytes / totalBytes;
          notifyListeners();
        }
      }

      await sink.close();

      _isDownloading = false;
      _downloadProgress = null;
      notifyListeners();

      // Open APK installer
      final result = await OpenFilex.open(apkPath, type: 'application/vnd.android.package-archive');
      if (result.type != ResultType.done) {
        _error = 'Could not open installer: ${result.message}';
        notifyListeners();
      }
    } catch (e) {
      _isDownloading = false;
      _downloadProgress = null;
      _error = 'Download failed: $e';
      notifyListeners();
    }
  }

  /// Compare semver strings. Returns true if latest > current.
  static bool _isNewer(String latest, String current) {
    final latestParts = latest.split('.').map((s) => int.tryParse(s) ?? 0).toList();
    final currentParts = current.split('.').map((s) => int.tryParse(s) ?? 0).toList();

    for (int i = 0; i < 3; i++) {
      final l = i < latestParts.length ? latestParts[i] : 0;
      final c = i < currentParts.length ? currentParts[i] : 0;
      if (l > c) return true;
      if (l < c) return false;
    }
    return false;
  }
}
