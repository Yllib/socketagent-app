import 'download_part.dart';
import 'resumable_http_download.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:open_filex/open_filex.dart';
import 'package:http/http.dart' as http;
import 'package:crypto/crypto.dart' as crypto;
import '../config/app_distribution.dart';

class UpdateInfo {
  final String latestVersion;
  final String downloadUrl;
  final String sha256;
  final int? size;
  final String signingCertSha256;
  final String currentVersion;
  final bool updateAvailable;

  UpdateInfo({
    required this.latestVersion,
    required this.downloadUrl,
    required this.sha256,
    this.size,
    this.signingCertSha256 = '',
    required this.currentVersion,
    required this.updateAvailable,
  });
}

class UpdateService extends ChangeNotifier {
  static const _versionApiUrl =
      'https://api.github.com/repos/Yllib/socketagent/contents/app-version.json?ref=master';
  static const _versionRawUrl =
      'https://raw.githubusercontent.com/Yllib/socketagent/master/app-version.json';

  UpdateInfo? _updateInfo;
  double? _downloadProgress;
  bool _isDownloading = false;
  bool _isOpeningInstaller = false;
  Timer? _installerLaunchResetTimer;
  bool _hasDownloadedApk = false;
  String? _downloadedApkPath;
  String? _error;

  UpdateInfo? get updateInfo => _updateInfo;
  double? get downloadProgress => _downloadProgress;
  bool get isDownloading => _isDownloading;
  bool get isOpeningInstaller => _isOpeningInstaller;
  // A verified APK is only actionable while it targets a newer version.
  // Android leaves our downloaded installer in app storage after installation,
  // so file existence alone must never keep the UI in "ready to install".
  bool get hasDownloadedApk => updateAvailable && _hasDownloadedApk;
  String? get downloadedApkPath => _downloadedApkPath;
  String? get error => _error;
  bool get updateAvailable => _updateInfo?.updateAvailable ?? false;

  /// Direct app update check against the public release metadata on GitHub.
  Future<UpdateInfo?> checkForUpdate() async {
    if (!AppBuild.supportsSelfUpdates) return null;
    _finishInstallerLaunchState();
    _error = null;
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final currentVersion = packageInfo.version;

      final data = await _fetchReleaseMetadata();
      if (data == null) {
        _error = 'Could not load current release metadata';
        notifyListeners();
        return null;
      }

      final latestVersion = data['version'] as String? ?? currentVersion;
      final downloadUrl = data['url'] as String? ?? '';
      final sha256 = _normalizeSha256(data['sha256'] as String? ?? '');
      final size = data['size'] is int ? data['size'] as int : null;
      final signingCertSha256 = (data['signingCertSha256'] as String? ?? '')
          .trim();
      final newer = _isNewer(latestVersion, currentVersion);

      debugPrint(
        '[Update] current=$currentVersion latest=$latestVersion newer=$newer sha256=${sha256.isNotEmpty}',
      );

      if (newer && sha256.isEmpty) {
        _error = 'Update metadata is missing APK SHA-256.';
      }

      _updateInfo = UpdateInfo(
        latestVersion: latestVersion,
        downloadUrl: downloadUrl,
        sha256: sha256,
        size: size,
        signingCertSha256: signingCertSha256,
        currentVersion: currentVersion,
        updateAvailable: newer && sha256.isNotEmpty,
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

  Future<Map<String, dynamic>?> _fetchReleaseMetadata() async {
    final cacheBust = DateTime.now().microsecondsSinceEpoch;
    final sources = [
      (
        Uri.parse('$_versionApiUrl&t=$cacheBust'),
        true,
        <String, String>{
          'Accept': 'application/vnd.github+json',
          'X-GitHub-Api-Version': '2022-11-28',
          'Cache-Control': 'no-cache',
        },
      ),
      (
        Uri.parse('$_versionRawUrl?t=$cacheBust'),
        false,
        <String, String>{'Cache-Control': 'no-cache'},
      ),
    ];

    for (final source in sources) {
      try {
        final response = await http
            .get(source.$1, headers: source.$3)
            .timeout(const Duration(seconds: 10));
        if (response.statusCode != 200) continue;
        final metadata = decodeReleaseMetadata(
          response.body,
          githubContentsResponse: source.$2,
        );
        if ((metadata['version'] as String? ?? '').isNotEmpty &&
            (metadata['url'] as String? ?? '').isNotEmpty) {
          return metadata;
        }
      } catch (e) {
        debugPrint('[Update] Metadata source failed: ${source.$1.host}: $e');
      }
    }
    return null;
  }

  @visibleForTesting
  static Map<String, dynamic> decodeReleaseMetadata(
    String body, {
    required bool githubContentsResponse,
  }) {
    final decoded = jsonDecode(body);
    if (!githubContentsResponse) {
      return Map<String, dynamic>.from(decoded as Map);
    }
    final envelope = Map<String, dynamic>.from(decoded as Map);
    final encoded = (envelope['content'] as String? ?? '').replaceAll(
      RegExp(r'\s+'),
      '',
    );
    if (encoded.isEmpty || envelope['encoding'] != 'base64') {
      throw const FormatException(
        'GitHub response did not contain base64 data',
      );
    }
    final content = utf8.decode(base64Decode(encoded));
    return Map<String, dynamic>.from(jsonDecode(content) as Map);
  }

  /// Download and verify the APK without opening the installer. Download state
  /// lives on this service, so it continues while callers navigate elsewhere.
  Future<void> downloadUpdate() async {
    if (!AppBuild.supportsSelfUpdates) return;
    if (_updateInfo == null || _updateInfo!.downloadUrl.isEmpty) return;
    if (_isDownloading) return;
    if (_updateInfo!.sha256.isEmpty) {
      _error = 'Update metadata is missing APK SHA-256.';
      notifyListeners();
      return;
    }
    await _refreshDownloadedApkState();
    if (_hasDownloadedApk) return;

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
          if (f is File &&
              f.path != apkPath &&
              f.path != partFile.path &&
              f.path != '${partFile.path}.json') {
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
      await _verifyDownloadedApkOrThrow(apkFile, _updateInfo!);

      _isDownloading = false;
      _downloadProgress = null;
      _hasDownloadedApk = true;
      _downloadedApkPath = apkPath;
      notifyListeners();
    } catch (e) {
      _isDownloading = false;
      await _updatePartialProgress();
      _error = 'Download failed: $e';
      notifyListeners();
    }
  }

  /// Compatibility action for update entry points that intentionally combine
  /// both steps. New compact controls should use downloadUpdate followed by
  /// installDownloaded so the ready-to-install state remains explicit.
  Future<void> downloadAndInstall() async {
    if (!AppBuild.supportsSelfUpdates) return;
    await _refreshDownloadedApkState();
    if (!_hasDownloadedApk) {
      await downloadUpdate();
    }
    if (_hasDownloadedApk) {
      await installDownloaded();
    }
  }

  Future<void> installDownloaded() async {
    if (!AppBuild.supportsSelfUpdates) return;
    if (_isOpeningInstaller) return;
    _isOpeningInstaller = true;
    _error = null;
    notifyListeners();

    await _refreshDownloadedApkState();
    final apkPath = _downloadedApkPath;
    if (apkPath == null || apkPath.isEmpty) {
      _error = 'No downloaded update found';
      _finishInstallerLaunchState();
      notifyListeners();
      return;
    }

    try {
      await _verifyDownloadedApkOrThrow(File(apkPath), _updateInfo!);
    } catch (e) {
      _hasDownloadedApk = false;
      _downloadedApkPath = null;
      _error = e.toString().replaceFirst('Exception: ', '');
      _finishInstallerLaunchState();
      notifyListeners();
      return;
    }

    final result = await OpenFilex.open(
      apkPath,
      type: 'application/vnd.android.package-archive',
    );
    if (result.type != ResultType.done) {
      _error = 'Could not open installer: ${result.message}';
      _finishInstallerLaunchState();
      notifyListeners();
      return;
    }
    // Keep every install affordance visibly busy while Android transitions to
    // its package installer. If no lifecycle transition occurs, recover after
    // a short guard period so a failed platform handoff is retryable.
    _installerLaunchResetTimer?.cancel();
    _installerLaunchResetTimer = Timer(
      const Duration(seconds: 4),
      _finishInstallerLaunchState,
    );
  }

  void _finishInstallerLaunchState() {
    _installerLaunchResetTimer?.cancel();
    _installerLaunchResetTimer = null;
    if (!_isOpeningInstaller) return;
    _isOpeningInstaller = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _installerLaunchResetTimer?.cancel();
    super.dispose();
  }

  Future<bool> _downloadWithResume({
    required String url,
    required File partFile,
    required File finalFile,
  }) async {
    final download = ResumableHttpDownload();
    await download.download(
      uri: Uri.parse(url),
      part: DownloadPart(partFile),
      immutableIdentity: _updateInfo?.sha256,
      onProgress: (received, total) {
        _downloadProgress = total != null && total > 0
            ? received / total
            : null;
        _error = null;
        notifyListeners();
      },
      onRetry: (attempt, received) {
        _error =
            'Connection interrupted. Retrying from ${_formatBytes(received)}...';
        notifyListeners();
      },
    );
    if (await finalFile.exists()) await finalFile.delete();
    await partFile.rename(finalFile.path);
    final manifest = File('${partFile.path}.json');
    if (await manifest.exists()) await manifest.delete();
    return true;
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
    final mb = kb / 1024;
    if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
    final gb = mb / 1024;
    return '${gb.toStringAsFixed(1)} GB';
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
    if (!info.updateAvailable) {
      // A successful installation leaves the APK behind. Once the running
      // package has caught up, clear both the stale action state and its files.
      await _deleteIfExists(file);
      await _deleteIfExists(File('$path.part'));
      _hasDownloadedApk = false;
      _downloadedApkPath = null;
      _downloadProgress = null;
      return;
    }
    _hasDownloadedApk = await file.exists() && await file.length() > 0;
    if (_hasDownloadedApk && info.sha256.isNotEmpty) {
      final verified = await _verifyDownloadedApk(file, info);
      if (!verified) {
        await _deleteIfExists(file);
        _hasDownloadedApk = false;
      }
    }
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
    final total = info.size;
    _downloadProgress = bytes > 0
        ? total != null && total > 0
              ? (bytes / total).clamp(0.0, 1.0)
              : 0.0
        : null;
  }

  Future<Directory> _updatesDirectory() async {
    final dir = await getApplicationDocumentsDirectory();
    return Directory('${dir.path}/updates');
  }

  Future<String> _apkPathForVersion(String version) async {
    final updateDir = await _updatesDirectory();
    return '${updateDir.path}/socketagent-$version.apk';
  }

  static String _normalizeSha256(String value) {
    return value.trim().toLowerCase().replaceAll(RegExp(r'[^a-f0-9]'), '');
  }

  Future<String> _fileSha256(File file) async {
    final digest = await crypto.sha256.bind(file.openRead()).first;
    return digest.toString();
  }

  Future<bool> _verifyDownloadedApk(File file, UpdateInfo info) async {
    if (info.sha256.isEmpty) return false;
    if (!await file.exists()) return false;
    if (info.size != null && info.size! > 0) {
      final actualSize = await file.length();
      if (actualSize != info.size) return false;
    }
    final actual = await _fileSha256(file);
    return actual == info.sha256;
  }

  Future<void> _verifyDownloadedApkOrThrow(File file, UpdateInfo info) async {
    final ok = await _verifyDownloadedApk(file, info);
    if (ok) return;
    await _deleteIfExists(file);
    throw Exception('Downloaded APK did not match release SHA-256.');
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
