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

  testWidgets('settings header exposes version and direct update check', (
    tester,
  ) async {
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
      find.ancestor(of: find.text('v1.2.3'), matching: find.byType(TextButton)),
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
  });

  testWidgets('settings header downloads an available update directly', (
    tester,
  ) async {
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
  });

  testWidgets('settings header draws circular download progress', (
    tester,
  ) async {
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
  });

  testWidgets('settings header installs an already downloaded update', (
    tester,
  ) async {
    final provider = ChatProvider();
    final updateService = _FakeUpdateService(available: true, downloaded: true);
    addTearDown(provider.dispose);
    addTearDown(updateService.dispose);

    await pumpSettings(tester, provider, updateService);

    expect(find.byTooltip('Install downloaded app update'), findsOneWidget);
    expect(find.byIcon(Icons.install_mobile), findsWidgets);
    await tester.tap(find.byTooltip('Install downloaded app update'));
    await tester.pump();
    expect(updateService.installCount, 1);
  });

  testWidgets('settings header shows and disables installer launch progress', (
    tester,
  ) async {
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
  });

  testWidgets('installed current-version APK is not offered again', (
    tester,
  ) async {
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
  });
}
