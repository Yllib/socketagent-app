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

/// Runs a desktop command. Replaceable so tests need no file manager.
typedef DesktopCommandRunner =
    Future<bool> Function(String executable, List<String> arguments);

/// Extensions the desktop opens by revealing rather than by launching.
///
/// Tapping Open must never run a binary that just came off the network. The
/// installer this was written for is exactly that case: revealing it costs one
/// double click and leaves the decision to run it with the user.
const _executableExtensions = {
  '.exe', '.msi', '.bat', '.cmd', '.com', '.scr', '.ps1',
  '.sh', '.command', '.app', '.appimage', '.run', '.jar',
};

bool _isExecutablePath(String path) {
  final lower = path.toLowerCase();
  return _executableExtensions.any(lower.endsWith);
}

Future<bool> _runDesktopCommand(String executable, List<String> arguments) async {
  try {
    final result = await Process.run(executable, arguments);
    return result.exitCode == 0;
  } catch (_) {
    return false;
  }
}

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
    String? desktopPlatform,
    DesktopCommandRunner? desktopCommandRunner,
  }) : _nativeChannel = nativeChannel,
       _platformFileOpener = platformFileOpener,
       _isAndroid = isAndroid ?? Platform.isAndroid,
       _supportsApkInstalls =
           supportsApkInstalls ?? AppBuild.supportsApkInstalls,
       // Gated on Android so a test naming a mobile platform is not treated as
       // the Linux host it runs on.
       _desktopPlatform = desktopPlatform ??
           ((isAndroid ?? Platform.isAndroid) ? '' : _currentDesktopPlatform()),
       _desktopCommandRunner = desktopCommandRunner ?? _runDesktopCommand;

  final MethodChannel _nativeChannel;
  final PlatformFileOpener? _platformFileOpener;
  final bool _isAndroid;
  final bool _supportsApkInstalls;

  /// "windows", "macos", "linux", or empty on mobile.
  final String _desktopPlatform;
  final DesktopCommandRunner _desktopCommandRunner;

  static String _currentDesktopPlatform() {
    if (Platform.isWindows) return 'windows';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isLinux) return 'linux';
    return '';
  }

  static Future<OpenResult> openPlatformFile(
    String path, {
    String? type,
    MethodChannel nativeChannel = const MethodChannel(
      'com.socketagent.app/intent',
    ),
    bool? isAndroid,
  }) async {
    if (!(isAndroid ?? Platform.isAndroid) ||
        path.toLowerCase().endsWith('.apk')) {
      return OpenFilex.open(path, type: type);
    }
    try {
      final opened = await nativeChannel.invokeMethod<bool>(
        'openDownloadedFile',
        {'path': path, if (type != null) 'type': type},
      );
      return opened == true
          ? OpenResult()
          : OpenResult(
              type: ResultType.error,
              message: 'Could not open the file.',
            );
    } on PlatformException catch (error) {
      return OpenResult(
        type: switch (error.code) {
          'FILE_NOT_FOUND' => ResultType.fileNotFound,
          'FILE_ACCESS_DENIED' => ResultType.permissionDenied,
          'NO_FILE_VIEWER' => ResultType.noAppToOpen,
          _ => ResultType.error,
        },
        message: error.message ?? 'Could not open the file.',
      );
    }
  }

  /// open_filex registers no desktop implementation, so every desktop open
  /// went through a plugin that is not there. Shelling out to the platform's
  /// own file manager is what it would have done anyway.
  Future<FileOpenResult> _openOnDesktop(String path) async {
    if (!File(path).existsSync() && !Directory(path).existsSync()) {
      return const FileOpenResult.failed(
        'The downloaded file is no longer available.',
      );
    }

    final reveal = _isExecutablePath(path);
    final (executable, arguments) = switch (_desktopPlatform) {
      'windows' => ('explorer', reveal ? ['/select,$path'] : [path]),
      'macos' => ('open', reveal ? ['-R', path] : [path]),
      _ => ('xdg-open', [reveal ? File(path).parent.path : path]),
    };

    // Windows explorer reports a nonzero exit code even when it succeeds, so
    // its result is not worth believing either way.
    final ok = await _desktopCommandRunner(executable, arguments);
    if (ok || _desktopPlatform == 'windows') return const FileOpenResult.opened();
    return FileOpenResult.failed(
      reveal
          ? 'Could not show the file. It is in $path'
          : 'No installed app can open this file type.',
    );
  }

  Future<FileOpenResult> open(String path) async {
    // An injected opener wins, so a caller supplying one still controls where
    // the file goes. Nothing injects one on a real desktop.
    if (_desktopPlatform.isNotEmpty && _platformFileOpener == null) {
      return await _openOnDesktop(path);
    }

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
      final type = isApk ? 'application/vnd.android.package-archive' : null;
      final result = _platformFileOpener != null
          ? await _platformFileOpener(path, type: type)
          : await openPlatformFile(
              path,
              type: type,
              nativeChannel: _nativeChannel,
              isAndroid: _isAndroid,
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
