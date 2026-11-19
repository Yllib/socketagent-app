// Card images are links to the computer that saved them. The board loads
// each one from that computer, or says which computer holds it.
import 'package:app/screens/boards/board_markdown.dart';
import 'package:app/services/chat_provider.dart';
import 'package:app/widgets/inline_chat_images.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'support/fake_computers.dart';

const _here =
    'socketagent://image?id=0b6c1d2e-3f40-4a5b-8c6d-7e8f90a1b2c3&name=image.png&computer=pubkey';
// The image loader caches across tests, so the compare uses its own image.
const _hereToo =
    'socketagent://image?id=1c7d1d2e-3f40-4a5b-8c6d-7e8f90a1b2c3&name=image.png&computer=pubkey';
const _elsewhere =
    'socketagent://image?id=9f2e1d2e-3f40-4a5b-8c6d-7e8f90a1b2c3&name=image.png&computer=other&computerName=laptop';

/// Answers image fetches with a 1x1 PNG and records which computer each
/// one went to.
class _Provider extends FakeComputersProvider {
  _Provider()
    : super(configs: [fakeConfig('tower', 'Tower', host: '10.0.0.4')]);

  final fetchedFrom = <String?>[];

  @override
  Future<String?> fetchFileManagerFileBase64({
    required String path,
    required String fileName,
    String? serverId,
    Duration timeout = const Duration(minutes: 3),
  }) async {
    fetchedFrom.add(serverId);
    return 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/l9sAAAAASUVORK5CYII=';
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Provider provider;

  setUp(() {
    mockProviderChannels();
    provider = _Provider();
  });

  tearDown(unmockProviderChannels);

  Future<void> show(WidgetTester tester, String detail) => tester.pumpWidget(
    ChangeNotifierProvider<ChatProvider>.value(
      value: provider,
      child: MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: BoardMarkdown(detail)),
        ),
      ),
    ),
  );

  testWidgets('an image loads from the paired computer that saved it', (
    tester,
  ) async {
    await show(tester, '![Before]($_here)');
    final images = tester.widget<InlineChatImages>(
      find.byType(InlineChatImages),
    );
    expect(images.sourceServerId, 'tower');
    await tester.pump();
    expect(provider.fetchedFrom, ['tower']);
  });

  testWidgets('a compare block loads from its computer', (tester) async {
    await show(
      tester,
      '```socketagent-compare\n'
      '{"images":[{"src":"$_hereToo","label":"Before"},'
      '{"src":"$_hereToo","label":"After"}]}\n'
      '```',
    );
    final images = tester.widget<InlineChatImages>(
      find.byType(InlineChatImages),
    );
    expect(images.sourceServerId, 'tower');
    expect(images.images, hasLength(2));
    await tester.pump();
    expect(provider.fetchedFrom, ['tower']);
  });

  testWidgets('an image on an unpaired computer names that computer', (
    tester,
  ) async {
    await show(
      tester,
      '![Before]($_elsewhere)\n\n'
      '```socketagent-compare\n["$_elsewhere"]\n```',
    );
    expect(find.byType(InlineChatImages), findsNothing);
    expect(provider.fetchedFrom, isEmpty);
    expect(
      find.text("Image on laptop, which this device isn't paired with."),
      findsNWidgets(2),
    );
  });
}
