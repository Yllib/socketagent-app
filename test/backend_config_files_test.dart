import 'package:app/models/backend_config_file.dart';
import 'package:app/models/computer_issue.dart';
import 'package:app/screens/settings/backend_config_screen.dart';
import 'package:app/services/chat_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Stands in for one computer: two files on disk, a Codex warning that points
/// at config.toml, and a save that can be made to conflict once.
class _ConfigProvider extends ChatProvider {
  final saves = <({String content, String? expectedVersion})>[];
  bool conflictNextSave = false;
  String diskContent = 'model = "gpt-5"\n';
  String diskVersion = 'v1';

  BackendConfigFile _config() => BackendConfigFile(
    id: 'codex-config',
    backend: 'codex',
    name: 'config.toml',
    label: 'Settings',
    format: 'toml',
    path: '/home/billy/.codex/config.toml',
    exists: true,
    size: diskContent.length,
    version: diskVersion,
  );

  @override
  bool serverSupportsBackendConfig(String serverId) => true;

  @override
  List<ComputerIssue> issuesForServer(String serverId) => const [
    ComputerIssue(
      backend: 'codex',
      error: false,
      message: '`windows_wsl_setup_acknowledged` is ignored.',
      path: '/home/billy/.codex/config.toml',
      configFile: 'codex-config',
    ),
  ];

  @override
  Future<List<BackendConfigFile>> listBackendConfigFiles(
    String serverId,
  ) async => [
    _config(),
    const BackendConfigFile(
      id: 'claude-md',
      backend: 'claude',
      name: 'CLAUDE.md',
      label: 'Instructions',
      format: 'markdown',
      path: '/home/billy/.claude/CLAUDE.md',
      exists: false,
    ),
  ];

  @override
  Future<BackendConfigText> readBackendConfigFile(
    String serverId,
    String id,
  ) async => BackendConfigText(
    file: _config(),
    content: diskContent,
    truncated: false,
  );

  @override
  Future<BackendConfigFile> writeBackendConfigFile(
    String serverId, {
    required String id,
    required String content,
    required String? expectedVersion,
  }) async {
    saves.add((content: content, expectedVersion: expectedVersion));
    if (conflictNextSave) {
      conflictNextSave = false;
      diskContent = 'model = "gpt-5-mini"\n';
      diskVersion = 'v2';
      throw BackendConfigSaveConflict(
        BackendConfigText(
          file: _config(),
          content: diskContent,
          truncated: false,
        ),
      );
    }
    diskContent = content;
    diskVersion = 'v${saves.length + 1}';
    return _config();
  }
}

/// A computer whose settings.json is valid but unindented.
class _JsonProvider extends _ConfigProvider {
  _JsonProvider() {
    diskContent = '{"model":"opus","permissions":{"allow":["Bash"]}}';
  }

  @override
  BackendConfigFile _config() => BackendConfigFile(
    id: 'claude-settings',
    backend: 'claude',
    name: 'settings.json',
    label: 'Settings',
    format: 'json',
    path: '/home/billy/.claude/settings.json',
    exists: true,
    size: diskContent.length,
    version: diskVersion,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('flutter_tts'),
          (_) async => null,
        );
  });

  Future<_ConfigProvider> pumpFiles(WidgetTester tester) async {
    final provider = _ConfigProvider();
    await tester.pumpWidget(
      ChangeNotifierProvider<ChatProvider>(
        create: (_) => provider,
        child: const MaterialApp(
          home: BackendConfigFilesScreen(serverId: 'server'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return provider;
  }

  testWidgets('lists files by backend, shows the warning, opens and saves', (
    tester,
  ) async {
    final provider = await pumpFiles(tester);
    expect(find.text('Codex'), findsOneWidget);
    expect(find.text('Claude'), findsOneWidget);
    expect(find.text('config.toml'), findsOneWidget);
    expect(find.text('Instructions · Markdown · Not created'), findsOneWidget);
    expect(
      find.text('`windows_wsl_setup_acknowledged` is ignored.'),
      findsOneWidget,
    );

    await tester.tap(find.text('config.toml'));
    await tester.pumpAndSettle();
    expect(find.text('/home/billy/.codex/config.toml'), findsOneWidget);
    expect(find.text('model = "gpt-5"\n'), findsOneWidget);
    // The warning follows the file into the editor.
    expect(
      find.text('`windows_wsl_setup_acknowledged` is ignored.'),
      findsOneWidget,
    );
    final save = find.widgetWithIcon(IconButton, Icons.save_outlined);
    expect(tester.widget<IconButton>(save).onPressed, isNull);

    await tester.enterText(find.byType(TextField), 'model = "gpt-5.1"\n');
    await tester.pumpAndSettle();
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(provider.saves, [
      (content: 'model = "gpt-5.1"\n', expectedVersion: 'v1'),
    ]);
    expect(find.text('config.toml saved'), findsOneWidget);
    expect(tester.widget<IconButton>(save).onPressed, isNull);
  });

  testWidgets('a conflicting save writes nothing until Overwrite', (
    tester,
  ) async {
    final provider = await pumpFiles(tester);
    provider.conflictNextSave = true;
    await tester.tap(find.text('config.toml'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'model = "mine"\n');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithIcon(IconButton, Icons.save_outlined));
    await tester.pumpAndSettle();

    expect(find.textContaining('Changed on the computer'), findsOneWidget);
    expect(find.text('config.toml saved'), findsNothing);
    expect(provider.diskContent, 'model = "gpt-5-mini"\n');

    await tester.tap(find.text('Overwrite'));
    await tester.pumpAndSettle();
    expect(provider.saves.last, (
      content: 'model = "mine"\n',
      expectedVersion: 'v2',
    ));
    expect(provider.diskContent, 'model = "mine"\n');
    expect(find.textContaining('Changed on the computer'), findsNothing);
  });

  testWidgets('Load theirs drops the local edit for the computer\'s text', (
    tester,
  ) async {
    final provider = await pumpFiles(tester);
    provider.conflictNextSave = true;
    await tester.tap(find.text('config.toml'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'model = "mine"\n');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithIcon(IconButton, Icons.save_outlined));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Load theirs'));
    await tester.pumpAndSettle();
    expect(find.text('model = "gpt-5-mini"\n'), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(
            find.widgetWithIcon(IconButton, Icons.save_outlined),
          )
          .onPressed,
      isNull,
    );
    expect(provider.saves, hasLength(1));
  });

  testWidgets(
    'Format re-indents JSON in the editor and leaves saving to the user',
    (tester) async {
      final provider = _JsonProvider();
      await tester.pumpWidget(
        ChangeNotifierProvider<ChatProvider>(
          create: (_) => provider,
          child: const MaterialApp(
            home: BackendConfigEditorScreen(
              serverId: 'server',
              fileId: 'claude-settings',
              fileName: 'settings.json',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('JSON · '), findsOneWidget);
      final save = find.widgetWithIcon(IconButton, Icons.save_outlined);
      expect(tester.widget<IconButton>(save).onPressed, isNull);

      await tester.tap(find.byTooltip('Format JSON'));
      await tester.pumpAndSettle();
      const pretty =
          '{\n'
          '  "model": "opus",\n'
          '  "permissions": {\n'
          '    "allow": [\n'
          '      "Bash"\n'
          '    ]\n'
          '  }\n'
          '}\n';
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        pretty,
      );
      expect(provider.saves, isEmpty);
      expect(tester.widget<IconButton>(save).onPressed, isNotNull);

      // Broken JSON is reported, not reformatted.
      await tester.enterText(find.byType(TextField), '{"model": }');
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Format JSON'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Cannot format.'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        '{"model": }',
      );
    },
  );
}
