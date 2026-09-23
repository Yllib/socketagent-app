import 'dart:async';
import 'dart:io';
import 'package:app/services/download_part.dart';
import 'package:app/services/resumable_http_download.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('download-test-');
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });
  DownloadPart part() => DownloadPart(File('${directory.path}/saved.part'));

  test(
    'interrupted HTTP transfer retries from flushed bytes with If-Range',
    () async {
      var attempts = 0;
      final requests = <http.BaseRequest>[];
      final download = ResumableHttpDownload(
        sleep: (_) async {},
        clientFactory: () => MockClient.streaming((request, _) async {
          requests.add(request);
          attempts++;
          if (attempts == 1) {
            Stream<List<int>> interrupted() async* {
              yield [1, 2, 3];
              throw const SocketException('Connection dropped');
            }

            return http.StreamedResponse(
              interrupted(),
              200,
              contentLength: 6,
              headers: {'etag': '"one"'},
            );
          }
          return http.StreamedResponse(
            Stream.value([4, 5, 6]),
            206,
            contentLength: 3,
            headers: {'etag': '"one"', 'content-range': 'bytes 3-5/6'},
          );
        }),
      );
      final saved = part();
      await download.download(
        uri: Uri.parse('https://local.test/file'),
        part: saved,
      );
      expect(requests[1].headers['Range'], 'bytes=3-');
      expect(requests[1].headers['If-Range'], '"one"');
      expect(await saved.file.readAsBytes(), [1, 2, 3, 4, 5, 6]);
    },
  );

  test(
    'new instance restores a prefix, supports duplicate chunks and rejects gaps',
    () async {
      final original = part();
      await original.begin(offset: 0, size: 6, identity: 'version');
      await original.append(0, [1, 2, 3]);
      final restored = part();
      await restored.load();
      await restored.begin(offset: 3, size: 6, identity: 'version');
      expect(await restored.append(1, [2, 3]), 3);
      await expectLater(restored.append(4, [5]), throwsFormatException);
      expect(await restored.length, 3);
      await restored.append(2, [3, 4, 5, 6]);
      await restored.verifyComplete();
      expect(await restored.file.readAsBytes(), [1, 2, 3, 4, 5, 6]);
    },
  );

  test(
    'retry exhaustion and permanent HTTP errors preserve bytes for manual retry',
    () async {
      final saved = part();
      await saved.begin(offset: 0, size: 8, identity: '"old"');
      await saved.append(0, [1, 2]);
      for (final status in [503, 403]) {
        var attempts = 0;
        final download = ResumableHttpDownload(
          sleep: (_) async {},
          clientFactory: () => MockClient.streaming((request, _) async {
            attempts++;
            return http.StreamedResponse(const Stream.empty(), status);
          }),
        );
        await expectLater(
          download.download(
            uri: Uri.parse('https://local.test/file'),
            part: part(),
            maxAttempts: 3,
          ),
          throwsA(isA<DownloadHttpException>()),
        );
        expect(attempts, status == 503 ? 3 : 1);
        expect(await saved.file.readAsBytes(), [1, 2]);
      }
    },
  );

  test(
    'source changes restart safely instead of mixing two revisions',
    () async {
      final saved = part();
      await saved.begin(offset: 0, size: 4, identity: '"old"');
      await saved.append(0, [1, 2]);
      await ResumableHttpDownload(
        clientFactory: () => MockClient.streaming((request, _) async {
          expect(request.headers['If-Range'], '"old"');
          return http.StreamedResponse(
            Stream.value([7, 8, 9]),
            200,
            contentLength: 3,
            headers: {'etag': '"new"'},
          );
        }),
      ).download(uri: Uri.parse('https://local.test/file'), part: saved);
      expect(await saved.file.readAsBytes(), [7, 8, 9]);
      expect(saved.version, '"new"');
    },
  );

  test('malformed ranges cannot corrupt saved bytes', () async {
    final saved = part();
    await saved.begin(offset: 0, size: 4, identity: '"one"');
    await saved.append(0, [1, 2]);
    final download = ResumableHttpDownload(
      clientFactory: () => MockClient.streaming(
        (request, _) async => http.StreamedResponse(
          Stream.value([9, 9]),
          206,
          contentLength: 2,
          headers: {'etag': '"one"', 'content-range': 'bytes 1-2/4'},
        ),
      ),
    );
    await expectLater(
      download.download(uri: Uri.parse('https://local.test/file'), part: saved),
      throwsFormatException,
    );
    expect(await saved.file.readAsBytes(), [1, 2]);
  });

  test(
    'a full prefix plus matching 416 completes without redownloading',
    () async {
      final saved = part();
      await saved.begin(offset: 0, size: 2, identity: '"one"');
      await saved.append(0, [1, 2]);
      await ResumableHttpDownload(
        clientFactory: () => MockClient.streaming(
          (request, _) async => http.StreamedResponse(
            const Stream.empty(),
            416,
            headers: {'etag': '"one"', 'content-range': 'bytes */2'},
          ),
        ),
      ).download(uri: Uri.parse('https://local.test/file'), part: part());
      expect(await saved.file.readAsBytes(), [1, 2]);
    },
  );

  test(
    'empty files complete and cancellation retains flushed progress',
    () async {
      final saved = part();
      await ResumableHttpDownload(
        clientFactory: () => MockClient.streaming(
          (request, _) async => http.StreamedResponse(
            const Stream.empty(),
            200,
            contentLength: 0,
            headers: {'etag': '"zero"'},
          ),
        ),
      ).download(uri: Uri.parse('https://local.test/empty'), part: saved);
      expect(await saved.length, 0);
      late ResumableHttpDownload download;
      download = ResumableHttpDownload(
        clientFactory: () => MockClient.streaming(
          (request, _) async => http.StreamedResponse(
            Stream.fromIterable([
              [1, 2],
              [3, 4],
            ]),
            200,
            contentLength: 4,
            headers: {'etag': '"four"'},
          ),
        ),
      );
      await expectLater(
        download.download(
          uri: Uri.parse('https://local.test/file'),
          part: saved,
          onProgress: (received, _) {
            if (received == 2) download.cancel();
          },
        ),
        throwsA(isA<DownloadCancelled>()),
      );
      expect(await saved.file.readAsBytes(), [1, 2]);
    },
  );
}
