import 'dart:async';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'download_part.dart';
import 'download_retry.dart';

class DownloadHttpException implements Exception {
  const DownloadHttpException(this.status);
  final int status;
  bool get retryable => status == 408 || status == 429 || status >= 500;
  @override
  String toString() => 'Download request failed (HTTP $status)';
}

class DownloadCancelled implements Exception {}

/// Range downloads with durable validators, strict response checks and bounded
/// retries. The URI and credentials are never written to the manifest.
class ResumableHttpDownload {
  ResumableHttpDownload({
    http.Client Function()? clientFactory,
    Future<void> Function(Duration)? sleep,
  }) : _clientFactory = clientFactory ?? http.Client.new,
       _sleep = sleep ?? Future<void>.delayed;
  final http.Client Function() _clientFactory;
  final Future<void> Function(Duration) _sleep;
  http.Client? _client;
  bool _cancelled = false;
  final Completer<void> _cancelSignal = Completer<void>();
  void cancel() {
    _cancelled = true;
    if (!_cancelSignal.isCompleted) _cancelSignal.complete();
    _client?.close();
  }

  Future<void> download({
    required Uri uri,
    required DownloadPart part,
    Map<String, String> headers = const {},
    String? immutableIdentity,
    void Function(int received, int? total)? onProgress,
    void Function(int attempt, int received)? onRetry,
    int maxAttempts = DownloadRetry.maxAttempts,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    await part.load();
    var forceFresh = false;
    for (var attempt = 1; ; attempt++) {
      if (_cancelled) throw DownloadCancelled();
      final client = _clientFactory();
      _client = client;
      Duration? retryAfter;
      try {
        final saved = await part.length;
        final savedVersion = part.version;
        final expected = savedVersion?.startsWith('v1-') == true
            ? '"$savedVersion"'
            : savedVersion;
        final mayResume = !forceFresh && saved > 0 && expected != null;
        final request = http.Request('GET', uri)..headers.addAll(headers);
        request.headers['Accept-Encoding'] = 'identity';
        if (mayResume) {
          request.headers['Range'] = 'bytes=$saved-';
          if (expected.startsWith('"') || expected.startsWith('W/')) {
            request.headers['If-Range'] = expected;
          } else if (immutableIdentity == null) {
            request.headers['If-Range'] = expected;
          }
        }
        final response = await client.send(request).timeout(timeout);
        final etag = response.headers['etag'];
        final identity = (etag != null && !etag.startsWith('W/'))
            ? etag
            : response.headers['last-modified'] ?? immutableIdentity;
        final range = response.headers['content-range'] ?? '';
        if (response.statusCode == 416) {
          final match = RegExp(r'^bytes \*/(\d+)$').firstMatch(range);
          if (mayResume &&
              identity == expected &&
              match != null &&
              int.parse(match[1]!) == saved) {
            await part.verifyComplete(saved);
            onProgress?.call(saved, saved);
            return;
          }
          // A source revision may have shrunk or changed. Keep the saved
          // prefix until a successful full response establishes its replacement.
          forceFresh = true;
          throw DownloadIncomplete();
        }
        if (response.statusCode != 200 && response.statusCode != 206) {
          final value = response.headers['retry-after'];
          if (value != null) {
            final seconds = int.tryParse(value);
            try {
              retryAfter = seconds != null
                  ? Duration(seconds: seconds)
                  : HttpDate.parse(value).difference(DateTime.now());
            } catch (_) {}
          }
          throw DownloadHttpException(response.statusCode);
        }
        int offset = 0;
        int? total = response.contentLength;
        if (response.statusCode == 206) {
          final match = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$').firstMatch(range);
          if (match == null) {
            throw const FormatException('Missing or malformed Content-Range');
          }
          offset = int.parse(match[1]!);
          final end = int.parse(match[2]!);
          total = int.parse(match[3]!);
          if (!mayResume ||
              offset != saved ||
              identity != expected ||
              end < offset ||
              end >= total ||
              (response.contentLength != null &&
                  response.contentLength != end - offset + 1)) {
            throw const FormatException(
              'Server returned an unsafe resume range',
            );
          }
        }
        if (_cancelled) throw DownloadCancelled();
        if (offset > 0 && savedVersion != expected) {
          part.metadata['version'] = expected;
        }
        await part.begin(offset: offset, size: total, identity: identity);
        var received = offset;
        onProgress?.call(received, total);
        await for (final chunk in response.stream.timeout(timeout)) {
          if (_cancelled) throw DownloadCancelled();
          received = await part.append(received, chunk);
          onProgress?.call(received, total);
        }
        if (_cancelled) throw DownloadCancelled();
        await part.verifyComplete();
        return;
      } catch (error) {
        if (_cancelled || error is DownloadCancelled) throw DownloadCancelled();
        if (error is FileSystemException ||
            error is FormatException ||
            (error is DownloadHttpException && !error.retryable) ||
            attempt >= maxAttempts) {
          rethrow;
        }
        onRetry?.call(attempt, await part.length);
      } finally {
        client.close();
        if (identical(_client, client)) _client = null;
      }
      final delay = retryAfter == null
          ? DownloadRetry.delay(attempt)
          : Duration(milliseconds: retryAfter.inMilliseconds.clamp(0, 60000));
      await Future.any([_sleep(delay), _cancelSignal.future]);
    }
  }
}
