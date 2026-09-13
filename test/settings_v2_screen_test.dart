import 'package:app/config/app_distribution.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:app/screens/settings/settings_v2_screen.dart';
import 'package:app/services/chat_provider.dart';
import 'package:app/services/update_service.dart';

class _FakeUpdateService extends UpdateService {
  _FakeUpdateService({
    this.available = false,
    this.downloading = false,
    this.downloaded = false,
    this.opening = false,
    this.progress,
  });

  int checkCount = 0;
  int downloadCount = 0;
  int installCount = 0;
  bool available;
  bool downloading;
  bool downloaded;
  bool opening;
  double? progress;

  @override
  UpdateInfo get updateInfo => UpdateInfo(
    latestVersion: available ? '1.2.4' : '1.2.3',
    downloadUrl: 'https://example.test/app.apk',
    sha256: List.filled(64, 'a').join(),
    currentVersion: '1.2.3',
    updateAvailable: available,
  );

  @override
  bool get updateAvailable => available;

  @override
  bool get isDownloading => downloading;

  @override
  bool get hasDownloadedApk => available && downloaded;

  @override
  bool get isOpeningInstaller => opening;

  @override
  double? get downloadProgress => progress;

  @override
  Future<UpdateInfo?> checkForUpdate() async {
    checkCount += 1;
    return updateInfo;
  }

  @override
  Future<void> downloadUpdate() async {
    downloadCount += 1;
  }

  @override
  Future<void> installDownloaded() async {
    installCount += 1;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('flutter_tts'),
          (_) async => null,
        );
    SharedPreferences.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
      appName: 'SocketAgent',
      packageName: 'com.socketagent.app',
      version: '1.2.3',
      buildNumber: '4',
      buildSignature: '',
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('flutter_tts'), null);
  });

  Future<void> pumpSettings(
    WidgetTester tester,
    ChatProvider provider,
    UpdateService updateService,
  ) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<ChatProvider>.value(
        value: provider,
        child: MaterialApp(
          home: SettingsV2Screen(updateService: updateService),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets(
    'settings header exposes version and direct update check',
    (tester) async {
      final provider = ChatProvider();
      final updateService = _FakeUpdateService();
      addTearDown(provider.dispose);
      addTearDown(updateService.dispose);

      await pumpSettings(tester, provider, updateService);

      expect(find.text('Settings'), findsOneWidget);
      expect(find.text('Settings V2'), findsNothing);
      expect(find.text('v1.2.3'), findsOneWidget);
      expect(find.text('About SocketAgent'), findsNothing);
      expect(
        find.ancestor(
          of: find.text('v1.2.3'),
          matching: find.byType(TextButton),
        ),
        findsNothing,
      );
      await tester.tap(find.byTooltip('Check for app updates'));
      await tester.pumpAndSettle();

      expect(updateService.checkCount, 1);
      expect(find.text('SocketAgent is up to date'), findsOneWidget);

      await tester.scrollUntilVisible(
        find.text('Export Computers'),
        500,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Export Computers'), findsOneWidget);
      expect(find.text('Import Computers'), findsOneWidget);
    },
    skip: !AppBuild.supportsSelfUpdates,
  );

  testWidgets(
    'store builds hide the direct updater in every update state',
    (tester) async {
      for (final updateService in [
        _FakeUpdateService(),
        _FakeUpdateService(available: true),
        _FakeUpdateService(available: true, downloading: true, progress: .42),
        _FakeUpdateService(available: true, downloaded: true),
        _FakeUpdateService(available: true, downloaded: true, opening: true),
      ]) {
        final provider = ChatProvider();
        addTearDown(provider.dispose);
        addTearDown(updateService.dispose);
        await pumpSettings(tester, provider, updateService);
        expect(find.text('v1.2.3'), findsOneWidget);
        for (final label in [
          'Check for app updates',
          'Download app update',
          'Downloading app update 42%',
          'Install downloaded app update',
          'Opening Android installer',
        ]) {
          expect(find.byTooltip(label), findsNothing);
        }
        expect(updateService.checkCount, 0);
        expect(updateService.downloadCount, 0);
        expect(updateService.installCount, 0);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
    skip: AppBuild.supportsSelfUpdates,
  );

  testWidgets('seven version taps reveal owner access', (tester) async {
    final provider = ChatProvider();
    final updateService = _FakeUpdateService();
    addTearDown(provider.dispose);
    addTearDown(updateService.dispose);

    await pumpSettings(tester, provider, updateService);
    final versionRow = find.byKey(const Key('app-version-row'));
    await tester.scrollUntilVisible(
      versionRow,
      500,
      scrollable: find.byType(Scrollable).first,
    );

    for (var tap = 0; tap < 6; tap += 1) {
      await tester.tap(versionRow);
      await tester.pump();
    }
    expect(find.text('Owner access'), findsNothing);

    await tester.tap(versionRow);
    await tester.pumpAndSettle();
    expect(find.text('Owner access'), findsOneWidget);
    expect(find.text('Owner code'), findsOneWidget);
  });

  testWidgets(
    'settings header downloads an available update directly',
    (tester) async {
      final provider = ChatProvider();
      final updateService = _FakeUpdateService(available: true);
      addTearDown(provider.dispose);
      addTearDown(updateService.dispose);

      await pumpSettings(tester, provider, updateService);

      expect(find.byTooltip('Download app update'), findsOneWidget);
      expect(find.byIcon(Icons.download), findsWidgets);
      await tester.tap(find.byTooltip('Download app update'));
      await tester.pump();
      expect(updateService.downloadCount, 1);
    },
    skip: !AppBuild.supportsSelfUpdates,
  );

  testWidgets(
    'settings header draws circular download progress',
    (tester) async {
      final provider = ChatProvider();
      final updateService = _FakeUpdateService(
        available: true,
        downloading: true,
        progress: 0.42,
      );
      addTearDown(provider.dispose);
      addTearDown(updateService.dispose);

      await pumpSettings(tester, provider, updateService);

      expect(find.byTooltip('Downloading app update 42%'), findsOneWidget);
      final indicators = tester.widgetList<CircularProgressIndicator>(
        find.byType(CircularProgressIndicator),
      );
      expect(indicators.any((indicator) => indicator.value == 0.42), isTrue);
    },
    skip: !AppBuild.supportsSelfUpdates,
  );

  testWidgets(
    'settings header installs an already downloaded update',
    (tester) async {
      final provider = ChatProvider();
      final updateService = _FakeUpdateService(
        available: true,
        downloaded: true,
      );
      addTearDown(provider.dispose);
      addTearDown(updateService.dispose);

      await pumpSettings(tester, provider, updateService);

      expect(find.byTooltip('Install downloaded app update'), findsOneWidget);
      expect(find.byIcon(Icons.install_mobile), findsWidgets);
      await tester.tap(find.byTooltip('Install downloaded app update'));
      await tester.pump();
      expect(updateService.installCount, 1);
    },
    skip: !AppBuild.supportsSelfUpdates,
  );

  testWidgets(
    'settings header shows and disables installer launch progress',
    (tester) async {
      final provider = ChatProvider();
      final updateService = _FakeUpdateService(
        available: true,
        downloaded: true,
        opening: true,
      );
      addTearDown(provider.dispose);
      addTearDown(updateService.dispose);

      await pumpSettings(tester, provider, updateService);

      expect(find.byTooltip('Opening Android installer'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsWidgets);
      await tester.tap(find.byTooltip('Opening Android installer'));
      await tester.pump();
      expect(updateService.installCount, 0);
    },
    skip: !AppBuild.supportsSelfUpdates,
  );

  testWidgets(
    'installed current-version APK is not offered again',
    (tester) async {
      final provider = ChatProvider();
      final updateService = _FakeUpdateService(
        available: false,
        downloaded: true,
      );
      addTearDown(provider.dispose);
      addTearDown(updateService.dispose);

      await pumpSettings(tester, provider, updateService);

      expect(find.byTooltip('Install downloaded app update'), findsNothing);
      expect(find.byTooltip('Check for app updates'), findsOneWidget);
      await tester.tap(find.byTooltip('Check for app updates'));
      await tester.pumpAndSettle();
      expect(updateService.installCount, 0);
      expect(updateService.checkCount, 1);
    },
    skip: !AppBuild.supportsSelfUpdates,
  );

  testWidgets('Condensed Tool Usage is persisted from Chat & Display', (
    tester,
  ) async {
    final provider = ChatProvider();
    final updateService = _FakeUpdateService();
    addTearDown(provider.dispose);
    addTearDown(updateService.dispose);

    await pumpSettings(tester, provider, updateService);
    await tester.scrollUntilVisible(
      find.text('Condensed Tool Usage'),
      400,
      scrollable: find.byType(Scrollable).first,
    );

    expect(provider.condensedToolUsage, isFalse);
    await tester.tap(find.text('Condensed Tool Usage'));
    await tester.pump();

    expect(provider.condensedToolUsage, isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('condensed_tool_usage'), isTrue);
  });
}
