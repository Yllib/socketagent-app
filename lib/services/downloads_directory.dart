import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Chooses where a downloaded file lands, given what the platform reports.
///
/// Split out from the lookup so the decision can be tested without a device.
/// [platformDownloads] is what `getDownloadsDirectory` returned, which is null
/// on Android and iOS and on a desktop that cannot name the folder.
///
/// Android keeps the shared Download folder it has always used. Everywhere
/// else has to ask the platform: that Android path is absolute-but-drive-
/// relative on Windows, so it resolved to `C:\storage\emulated\0\Download` and
/// downloads landed in a directory nobody would ever look in.
String resolveDownloadsPath({
  required bool isAndroid,
  required String? platformDownloads,
  required String? home,
}) {
  if (isAndroid) return '/storage/emulated/0/Download';

  final reported = platformDownloads?.trim();
  if (reported != null && reported.isNotEmpty) return reported;

  // A desktop that would not name its Downloads folder still has a home to
  // put files in, which beats failing the download outright.
  final base = home?.trim();
  if (base != null && base.isNotEmpty) {
    return '$base${Platform.pathSeparator}Downloads';
  }
  return Directory.systemTemp.path;
}

/// The user's home directory, as each platform spells it.
String? homeDirectoryFrom(Map<String, String> environment) =>
    environment['HOME'] ?? environment['USERPROFILE'];

Directory? _cached;

/// The directory downloads are saved to, resolved once per run.
Future<Directory> downloadsDirectory() async {
  final cached = _cached;
  if (cached != null) return cached;

  String? platformDownloads;
  if (!Platform.isAndroid && !Platform.isIOS) {
    try {
      platformDownloads = (await getDownloadsDirectory())?.path;
    } catch (_) {
      // Unsupported platform or a failed lookup both fall through to home.
    }
  }

  final directory = Directory(
    resolveDownloadsPath(
      isAndroid: Platform.isAndroid,
      platformDownloads: platformDownloads,
      home: homeDirectoryFrom(Platform.environment),
    ),
  );
  if (!directory.existsSync()) {
    directory.createSync(recursive: true);
  }
  _cached = directory;
  return directory;
}

/// The downloads directory without waiting for the platform lookup.
///
/// For callers that cannot await: chunk handling has to stay synchronous, or
/// two chunks arriving together both pass the "first chunk" check and open the
/// output file twice. Every download awaits [downloadsDirectory] while asking
/// for the file, so by the time chunks arrive this is the resolved answer; the
/// fallback only covers a chunk for a download this app never started.
Directory downloadsDirectorySync() =>
    _cached ??
    Directory(
      resolveDownloadsPath(
        isAndroid: Platform.isAndroid,
        platformDownloads: null,
        home: homeDirectoryFrom(Platform.environment),
      ),
    );

/// Forget the resolved directory. For tests only.
void resetDownloadsDirectoryForTest() => _cached = null;
