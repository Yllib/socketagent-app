import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:app/screens/settings/settings_v2_screen.dart';
import 'package:app/services/chat_provider.dart';
import 'package:app/services/update_service.dart';

class _FakeUpdateService extends UpdateService {
  int checkCount = 0;

  @override
  Future<UpdateInfo?> checkForUpdate() async {
    checkCount += 1;
    return UpdateInfo(
      latestVersion: '1.2.3',
      downloadUrl: '',
      sha256: '',
      currentVersion: '1.2.3',
      updateAvailable: false,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
      appName: 'SocketAgent',
      packageName: 'com.socketagent.app',
      version: '1.2.3',
      buildNumber: '4',
      buildSignature: '',
    );
  });

  testWidgets('settings header exposes version, About, and update check', (
    tester,
  ) async {
    final provider = ChatProvider();
    final updateService = _FakeUpdateService();
    addTearDown(provider.dispose);
    addTearDown(updateService.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider<ChatProvider>.value(
        value: provider,
        child: MaterialApp(
          home: SettingsV2Screen(updateService: updateService),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Settings V2'), findsNothing);
    expect(find.text('v1.2.3'), findsOneWidget);
    expect(find.text('About SocketAgent'), findsNothing);

    await tester.tap(find.text('v1.2.3'));
    await tester.pumpAndSettle();
    expect(find.text('About'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Check for app updates'));
    await tester.pumpAndSettle();

    expect(updateService.checkCount, 1);
    expect(find.text('SocketAgent is up to date'), findsOneWidget);
  });
}
