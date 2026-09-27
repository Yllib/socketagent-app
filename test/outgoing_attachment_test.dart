import 'dart:async';
import 'dart:io';
import 'package:app/services/outgoing_queue.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'multi_client_prompt_test.dart' show withSession;

class TestPicker extends FilePicker {
  TestPicker(this.file);
  final File file;
  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = true,
    int compressionQuality = 30,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async => FilePickerResult([
    PlatformFile(
      name: 'example.txt',
      path: file.path,
      size: await file.length(),
    ),
  ]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'switching sessions during an attachment upload keeps its original destination',
    () async {
      final dir = await Directory.systemTemp.createTemp('outgoing-attachment-');
      final file = await File(
        '${dir.path}/example.txt',
      ).writeAsString('file snapshot');
      FilePicker.platform = TestPicker(file);
      final start = Completer<Map<String, dynamic>>();
      final received = <Map<String, dynamic>>[];
      try {
        await withSession(
          (provider, send) async {
            await provider.pickFiles();
            final sending = provider.sendPrompt('look at this file');
            final upload = await start.future.timeout(
              const Duration(seconds: 5),
            );
            expect(upload['sessionId'], 'shared-session');
            expect((await OutgoingQueue().load()).single.files, isNotEmpty);
            await file.delete();
            provider.resumeSession(
              'other-session',
              serverId: 'multi-client-server',
            );
            await send({
              'type': 'upload_complete',
              'uploadId': upload['uploadId'],
              'serverPath': '/saved/example.txt',
            });
            await sending;
            await Future<void>.delayed(const Duration(milliseconds: 80));
            final prompt = received.singleWhere((m) => m['type'] == 'prompt');
            expect(prompt['sessionId'], 'shared-session');
            expect(
              prompt['text'],
              '[Attached file: /saved/example.txt]\nlook at this file',
            );
            expect(provider.activeSessionId, 'other-session');
            expect(
              (await OutgoingQueue().load()).single.files.single['serverPath'],
              '/saved/example.txt',
            );
            await send({
              'type': 'prompt_received',
              'messageId': prompt['messageId'],
            });
            expect(await OutgoingQueue().load(), isEmpty);
          },
          onClientMessage: (event) {
            received.add(event);
            if (event['type'] == 'upload_start' && !start.isCompleted) {
              start.complete(event);
            }
          },
        );
      } finally {
        await dir.delete(recursive: true);
      }
    },
  );
}
