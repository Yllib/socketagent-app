import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:open_filex/open_filex.dart';
import 'package:http/http.dart' as http;

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
      'https://raw.githubusercontent.com/Yllib/socketagent/master/app-version.json';

  UpdateInfo? _updateInfo;
  double? _downloadProgress;
  bool _isDownloading = false;
  bool _hasDownloadedApk = false;
  String? _downloadedApkPath;
  String? _error;

  UpdateInfo? get updateInfo => _updateInfo;
  double? get downloadProgress => _downloadProgress;
  bool get isDownloading => _isDownloading;
  bool get hasDownloadedApk => _hasDownloadedApk;
  String? get downloadedApkPath => _downloadedApkPath;
  String? get error => _error;
  bool get updateAvailable => _updateInfo?.updateAvailable ?? false;

  /// Apply app release metadata returned by the SocketAgent server over the
  /// active socket connection.
  Future<UpdateInfo?> applyVersionInfo(Map<String, dynamic> serverInfo) async {
    _error = null;
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final currentVersion = packageInfo.version;
      final appInfoRaw = serverInfo['app'];
      final appInfo = appInfoRaw is Map
          ? Map<String, dynamic>.from(appInfoRaw)
          : serverInfo;

      final latestVersion = appInfo['version'] as String?;
      final downloadUrl = appInfo['url'] as String? ?? '';
      if (latestVersion == null || latestVersion.isEmpty) {
        _error =
            serverInfo['error'] as String? ??
            serverInfo['fetchError'] as String? ??
            'Server did not provide app update info';
        notifyListeners();
        return null;
      }

      debugPrint(
        '[Update] current=$currentVersion latest=$latestVersion newer=${_isNewer(latestVersion, currentVersion)}',
      );

      _updateInfo = UpdateInfo(
        latestVersion: latestVersion,
        downloadUrl: downloadUrl,
        currentVersion: currentVersion,
        updateAvailable: _isNewer(latestVersion, currentVersion),
      );
      await _refreshDownloadedApkState();
      notifyListeners();
      return _updateInfo;
    } catch (e) {
      _error = 'Update check failed: $e';
      notifyListeners();
      return null;
    }
  }

  /// Fallback direct check for development builds that are not connected to a
  /// SocketAgent server.
  Future<UpdateInfo?> checkForUpdate() async {
    _error = null;
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final currentVersion = packageInfo.version;

      final cacheBust = DateTime.now().millisecondsSinceEpoch;
      final response = await http
          .get(Uri.parse('$_versionUrl?t=$cacheBust'))
          .timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
        _error = 'Could not check for updates (${response.statusCode})';
        notifyListeners();
        return null;
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final latestVersion = data['version'] as String? ?? currentVersion;
      final downloadUrl = data['url'] as String? ?? '';

      debugPrint(
        '[Update] current=$currentVersion latest=$latestVersion newer=${_isNewer(latestVersion, currentVersion)}',
      );

      _updateInfo = UpdateInfo(
        latestVersion: latestVersion,
        downloadUrl: downloadUrl,
        currentVersion: currentVersion,
        updateAvailable: _isNewer(latestVersion, currentVersion),
      );
      await _refreshDownloadedApkState();
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
    await _refreshDownloadedApkState();
    if (_hasDownloadedApk) {
      await installDownloaded();
      return;
    }

    _isDownloading = true;
    _error = null;
    await _updatePartialProgress();
    notifyListeners();

    try {
      final updateDir = await _updatesDirectory();
      if (!await updateDir.exists()) await updateDir.create(recursive: true);

      final apkPath = await _apkPathForVersion(_updateInfo!.latestVersion);
      final apkFile = File(apkPath);
      final partFile = File('$apkPath.part');

      // Delete old APKs
      if (await updateDir.exists()) {
        for (final f in updateDir.listSync()) {
          if (f is File && f.path != apkPath && f.path != partFile.path) {
            f.deleteSync();
          }
        }
      }

      final result = await _downloadWithResume(
        url: _updateInfo!.downloadUrl,
        partFile: partFile,
        finalFile: apkFile,
      );
      if (!result) {
        throw Exception('Download failed');
      }

      _isDownloading = false;
      _downloadProgress = null;
      _hasDownloadedApk = true;
      _downloadedApkPath = apkPath;
      notifyListeners();

      await installDownloaded();
    } catch (e) {
      _isDownloading = false;
      await _updatePartialProgress();
      _error = 'Download failed: $e';
      notifyListeners();
    }
  }

  Future<void> installDownloaded() async {
    await _refreshDownloadedApkState();
    final apkPath = _downloadedApkPath;
    if (apkPath == null || apkPath.isEmpty) {
      _error = 'No downloaded update found';
      notifyListeners();
      return;
    }

    final result = await OpenFilex.open(
      apkPath,
      type: 'application/vnd.android.package-archive',
    );
    if (result.type != ResultType.done) {
      _error = 'Could not open installer: ${result.message}';
      notifyListeners();
    }
  }

  Future<bool> _downloadWithResume({
    required String url,
    required File partFile,
    required File finalFile,
  }) async {
    var existingBytes = await partFile.exists() ? await partFile.length() : 0;
    var request = http.Request('GET', Uri.parse(url));
    if (existingBytes > 0) {
      request.headers['Range'] = 'bytes=$existingBytes-';
    }

    var client = http.Client();
    http.StreamedResponse response;
    try {
      response = await client.send(request);
    } finally {
      // The response stream owns the socket after send returns.
    }

    if (response.statusCode == 416 && existingBytes > 0) {
      await _deleteIfExists(partFile);
      existingBytes = 0;
      client.close();
      request = http.Request('GET', Uri.parse(url));
      client = http.Client();
      response = await client.send(request);
    }

    if (response.statusCode == 200 && existingBytes > 0) {
      await _deleteIfExists(partFile);
      existingBytes = 0;
    } else if (response.statusCode != 200 && response.statusCode != 206) {
      client.close();
      throw Exception('Download failed (${response.statusCode})');
    }

    final contentLength = response.contentLength ?? 0;
    final totalBytes = response.statusCode == 206
        ? existingBytes + contentLength
        : contentLength;
    var receivedBytes = existingBytes;
    _downloadProgress = totalBytes > 0 ? receivedBytes / totalBytes : null;
    notifyListeners();

    final sink = partFile.openWrite(mode: FileMode.append);
    try {
      await for (final chunk in response.stream) {
        sink.add(chunk);
        receivedBytes += chunk.length;
        if (totalBytes > 0) {
          _downloadProgress = (receivedBytes / totalBytes).clamp(0.0, 1.0);
          notifyListeners();
        }
      }
      await sink.close();
      client.close();
    } catch (_) {
      await sink.close();
      client.close();
      rethrow;
    }

    if (await finalFile.exists()) await finalFile.delete();
    await partFile.rename(finalFile.path);
    return true;
  }

  Future<void> _deleteIfExists(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  Future<void> _refreshDownloadedApkState() async {
    final info = _updateInfo;
    if (info == null) {
      _hasDownloadedApk = false;
      _downloadedApkPath = null;
      return;
    }
    final path = await _apkPathForVersion(info.latestVersion);
    final file = File(path);
    _hasDownloadedApk = await file.exists() && await file.length() > 0;
    _downloadedApkPath = _hasDownloadedApk ? path : null;
    if (!_isDownloading) {
      await _updatePartialProgress();
    }
  }

  Future<void> _updatePartialProgress() async {
    final info = _updateInfo;
    if (info == null) {
      _downloadProgress = null;
      return;
    }
    final partFile = File(
      '${await _apkPathForVersion(info.latestVersion)}.part',
    );
    if (!await partFile.exists()) {
      _downloadProgress = null;
      return;
    }
    final bytes = await partFile.length();
    _downloadProgress = bytes > 0 ? 0.0 : null;
  }

  Future<Directory> _updatesDirectory() async {
    final dir = await getApplicationDocumentsDirectory();
    return Directory('${dir.path}/updates');
  }

  Future<String> _apkPathForVersion(String version) async {
    final updateDir = await _updatesDirectory();
    return '${updateDir.path}/socketagent-$version.apk';
  }

  /// Compare semver strings. Returns true if latest > current.
  static bool _isNewer(String latest, String current) {
    final latestParts = latest
        .split('.')
        .map((s) => int.tryParse(s) ?? 0)
        .toList();
    final currentParts = current
        .split('.')
        .map((s) => int.tryParse(s) ?? 0)
        .toList();

    for (int i = 0; i < 3; i++) {
      final l = i < latestParts.length ? latestParts[i] : 0;
      final c = i < currentParts.length ? currentParts[i] : 0;
      if (l > c) return true;
      if (l < c) return false;
    }
    return false;
  }
}
