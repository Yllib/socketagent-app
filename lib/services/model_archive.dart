import 'dart:io';
import 'package:crypto/crypto.dart';

import 'download_part.dart';
import 'resumable_http_download.dart';

/// Keep interrupted downloads and mark extracted models unavailable until verified.
Future<void> installModelArchive({
  required Uri uri,
  required Directory directory,
  required String sha256Hex,
  required List<String> requiredFiles,
  required void Function(double) onProgress,
}) async {
  await directory.create(recursive: true);
  final marker = File('${directory.path}/.installing');
  await marker.writeAsString('Installing', flush: true);
  final part = DownloadPart(File('${directory.path}.tar.bz2.part'));
  await ResumableHttpDownload().download(
    uri: uri,
    part: part,
    immutableIdentity: sha256Hex,
    onProgress: (received, total) {
      if (total != null && total > 0) {
        onProgress((received / total).clamp(0.0, 1.0) * 0.9);
      }
    },
  );
  final digest = await sha256.bind(part.file.openRead()).first;
  if (digest.toString() != sha256Hex) {
    await part.file.delete();
    if (await part.manifest.exists()) await part.manifest.delete();
    throw StateError(
      'The model download was damaged. Please download it again.',
    );
  }
  onProgress(0.92);
  final result = await Process.run('tar', [
    'xjf',
    part.file.path,
    '--strip-components=1',
    '-C',
    directory.path,
  ]);
  if (result.exitCode != 0) {
    throw StateError(
      'Could not unpack the speech model. Check free disk space and try again.',
    );
  }
  for (final name in requiredFiles) {
    final file = File('${directory.path}/$name');
    if (!await file.exists() || await file.length() == 0) {
      throw StateError(
        'The speech model is incomplete. Please download it again.',
      );
    }
  }
  await marker.delete();
  await part.file.delete();
  if (await part.manifest.exists()) await part.manifest.delete();
  onProgress(1);
}
