import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:app/models/message.dart';
import 'package:app/services/outgoing_queue.dart';
import 'package:cross_file/cross_file.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'multi_client_prompt_test.dart' show withSession;

/// A picked file backed by a real file on disk.
base class TestFile extends PlatformFile {
  TestFile(this.file);
  final File file;
  @override
  String get name => 'example.txt';
  @override
  Uri get uri => file.uri;
  @override
  XFile get xFile => XFile(file.path, name: name);
  @override
  int? lengthSync() => file.lengthSync();
  @override
  Future<int?> length() => file.length();
  @override
  Future<Uint8List> readAsBytes() => file.readAsBytes();
  @override
  Stream<Uint8List> readAsByteStream() =>
      file.openRead().map(Uint8List.fromList);
}

class TestPicker extends FilePickerPlatform {
  TestPicker(this.file);
  final File file;
  @override
  Future<List<PlatformFile>> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async => [TestFile(file)];
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
      FilePickerPlatform.instance = TestPicker(file);
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
            final bubble = provider.messages.lastWhere(
              (message) => message.sender == MessageSender.user,
            );
            expect(bubble.attachments.single.name, 'example.txt');
            expect(bubble.attachments.single.isLocal, isTrue);
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
            expect(bubble.attachments.single.path, '/saved/example.txt');
            expect(bubble.attachments.single.isLocal, isFalse);
            expect(
              (await OutgoingQueue().load()).single.files.single['serverPath'],
              '/saved/example.txt',
            );
            await send({
              'type': 'prompt_received',
              'messageId': prompt['messageId'],
            });
            expect(await OutgoingQueue().load(), isEmpty);
            provider.resumeSession(
              'shared-session',
              serverId: 'multi-client-server',
            );
            await send({
              'type': 'session_history',
              'total': 1,
              'offset': 0,
              'messages': [
                {
                  'role': 'user',
                  'content': prompt['text'],
                  'uuid': 'uploaded-prompt',
                  'entryId': 'upload-entry',
                  'sessionSeq': 1,
                  'revision': 1,
                },
              ],
            });
            final recovered = provider.messages.singleWhere(
              (message) => message.uuid == 'uploaded-prompt',
            );
            expect(recovered.textContent, 'look at this file');
            expect(recovered.attachments.single.path, '/saved/example.txt');
            expect(recovered.attachments.single.isLocal, isFalse);
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

  test('composer files stay with their session across switches', () async {
    final dir = await Directory.systemTemp.createTemp('composer-files-');
    final file = await File('${dir.path}/shot.png').writeAsBytes([1, 2, 3]);
    try {
      await withSession((provider, _) async {
        provider.attachFilePaths([file.path]);
        provider.resumeSession(
          'other-session',
          serverId: 'multi-client-server',
        );
        expect(provider.pendingFileAttachments, isEmpty);
        provider.resumeSession(
          'shared-session',
          serverId: 'multi-client-server',
        );
        expect(provider.pendingFileAttachments.single.path, file.path);
        expect(provider.pendingFileAttachments.single.isImage, isTrue);
      });
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('a dropped folder is reported, not silently skipped', () async {
    final dir = await Directory.systemTemp.createTemp('composer-folder-');
    try {
      await withSession((provider, _) async {
        provider.attachFilePaths([dir.path]);
        expect(provider.pendingFileAttachments, isEmpty);
        final row = provider.messages.last;
        expect(row.type, MessageType.error);
        expect(row.textContent, contains('only files can be attached'));
        expect(row.trace?.kind, 'attach_file');
      });
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('a secret stays with its session across switches', () async {
    await withSession((provider, _) async {
      provider.queueSecureAttachment(label: 'API_KEY', value: 'hunter2');
      provider.resumeSession('other-session', serverId: 'multi-client-server');
      expect(provider.pendingSecretAttachments, isEmpty);
      provider.resumeSession('shared-session', serverId: 'multi-client-server');
      expect(provider.pendingSecretAttachments.single.value, 'hunter2');
    });
  });

  test('an offline secret waits in the outbox, never in its files', () async {
    await withSession((provider, _) async {
      provider.queueSecureAttachment(label: 'API_KEY', value: 'hunter2');
      provider.disconnect();
      expect(await provider.sendPrompt('use this key'), isTrue);
      expect(provider.pendingSecretAttachments, isEmpty);
      final queued = (await OutgoingQueue().load()).single;
      expect(queued.secrets.single.label, 'API_KEY');
      expect(queued.secrets.single.saved, isNull);
      expect(jsonEncode(queued.toJson()), isNot(contains('hunter2')));
      expect(
        await OutgoingQueue().secretValue(queued.id, queued.secrets.single),
        'hunter2',
      );
    });
  });

  test('a queued secret is saved on the computer before its prompt', () async {
    final stored = Completer<Map<String, dynamic>>();
    final received = <Map<String, dynamic>>[];
    await withSession(
      (provider, send) async {
        provider.queueSecureAttachment(label: 'API_KEY', value: 'hunter2');
        final sending = provider.sendPrompt('use this key');
        final store = await stored.future.timeout(const Duration(seconds: 5));
        expect(store['value'], 'hunter2');
        expect(received.where((m) => m['type'] == 'prompt'), isEmpty);
        await send({
          'type': 'secret_operation_result',
          'requestId': store['clientRequestId'],
          'operation': 'create',
          'ok': true,
          'secret': {
            'secretId': 'sec_1',
            'label': 'API_KEY',
            'scope': 'session',
            'filePath': '/secrets/API_KEY_sec_1',
            'envHint': 'API_KEY',
            'createdAt': '2026-10-11T12:00:00.000Z',
          },
        });
        await sending.timeout(const Duration(seconds: 5));
        final prompt = received.singleWhere((m) => m['type'] == 'prompt');
        expect(
          prompt['text'],
          startsWith('[Attached secret: {"label":"API_KEY"'),
        );
        expect(prompt['text'], endsWith('\nuse this key'));
        final queued = (await OutgoingQueue().load()).single;
        expect(queued.secrets.single.saved?.secretId, 'sec_1');
        expect(
          await OutgoingQueue().secretValue(queued.id, queued.secrets.single),
          isNull,
        );
      },
      onClientMessage: (event) {
        received.add(event);
        if (event['type'] == 'secure_input_store' && !stored.isCompleted) {
          stored.complete(event);
        }
      },
    );
  });

  test('a secret the computer refuses fails with a traceable error', () async {
    final stored = Completer<Map<String, dynamic>>();
    final received = <Map<String, dynamic>>[];
    await withSession(
      (provider, send) async {
        provider.queueSecureAttachment(label: 'API_KEY', value: 'hunter2');
        final sending = provider.sendPrompt('use this key');
        final store = await stored.future.timeout(const Duration(seconds: 5));
        await send({
          'type': 'secret_operation_result',
          'requestId': store['clientRequestId'],
          'operation': 'create',
          'ok': false,
          'error': 'disk full',
        });
        await sending.timeout(const Duration(seconds: 5));
        final problem = provider.activeDeliveryProblems.single.failure;
        expect(problem?.message, 'API_KEY was not saved: disk full');
        expect(problem?.id, matches(RegExp(r'^E-[0-9A-F]{8}$')));
        expect(received.where((m) => m['type'] == 'prompt'), isEmpty);
        expect(
          received.singleWhere(
            (m) => m['type'] == 'client_event_error',
          )['message'],
          '[${problem?.id}] API_KEY was not saved: disk full',
        );
      },
      onClientMessage: (event) {
        received.add(event);
        if (event['type'] == 'secure_input_store' && !stored.isCompleted) {
          stored.complete(event);
        }
      },
    );
  });
}
