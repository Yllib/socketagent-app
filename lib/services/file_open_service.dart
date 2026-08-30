import 'dart:io';

import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';

import '../config/app_distribution.dart';

enum FileOpenOutcome { opened, needsApkPermission, failed }

class FileOpenResult {
  const FileOpenResult._(this.outcome, this.message);

  const FileOpenResult.opened() : this._(FileOpenOutcome.opened, null);

  const FileOpenResult.needsApkPermission()
    : this._(FileOpenOutcome.needsApkPermission, null);

  const FileOpenResult.failed(String message)
    : this._(FileOpenOutcome.failed, message);

  final FileOpenOutcome outcome;
  final String? message;
}

typedef PlatformFileOpener =
    Future<OpenResult> Function(String path, {String? type});

/// Opens downloaded files and handles Android's separate authorization for
/// installing APKs. The manifest permission alone does not grant that access.
class FileOpenService {
  FileOpenService({
    MethodChannel nativeChannel = const MethodChannel(
      'com.socketagent.app/intent',
    ),
    PlatformFileOpener? platformFileOpener,
    bool? isAndroid,
    bool? supportsApkInstalls,
  }) : _nativeChannel = nativeChannel,
       _platformFileOpener = platformFileOpener ?? _openWithPlatform,
       _isAndroid = isAndroid ?? Platform.isAndroid,
       _supportsApkInstalls =
           supportsApkInstalls ?? AppBuild.supportsApkInstalls;

  final MethodChannel _nativeChannel;
  final PlatformFileOpener _platformFileOpener;
  final bool _isAndroid;
  final bool _supportsApkInstalls;

  static Future<OpenResult> _openWithPlatform(String path, {String? type}) =>
      OpenFilex.open(path, type: type);

  Future<FileOpenResult> open(String path) async {
    final isApk = path.toLowerCase().endsWith('.apk');

    if (isApk && _isAndroid) {
      if (!_supportsApkInstalls) {
        return const FileOpenResult.failed(
          'APK installation is disabled in this build.',
        );
      }

      try {
        final allowed =
            await _nativeChannel.invokeMethod<bool>(
              'canRequestPackageInstalls',
            ) ??
            false;
        if (!allowed) return const FileOpenResult.needsApkPermission();
      } on PlatformException catch (error) {
        return FileOpenResult.failed(
          'Could not check APK install access: ${error.message ?? error.code}',
        );
      }
    }

    try {
      final result = await _platformFileOpener(
        path,
        type: isApk ? 'application/vnd.android.package-archive' : null,
      );
      return switch (result.type) {
        ResultType.done => const FileOpenResult.opened(),
        ResultType.fileNotFound => const FileOpenResult.failed(
          'The downloaded file is no longer available.',
        ),
        ResultType.noAppToOpen => const FileOpenResult.failed(
          'No installed app can open this file type.',
        ),
        ResultType.permissionDenied => const FileOpenResult.failed(
          'Android denied access to this file.',
        ),
        ResultType.error => FileOpenResult.failed(
          result.message.trim().isEmpty || result.message == 'done'
              ? 'Could not open the file.'
              : result.message.trim(),
        ),
      };
    } catch (error) {
      return FileOpenResult.failed('Could not open the file: $error');
    }
  }

  Future<bool> openApkPermissionSettings() async {
    try {
      return await _nativeChannel.invokeMethod<bool>(
            'openPackageInstallSettings',
          ) ??
          false;
    } on PlatformException {
      return false;
    }
  }
}
