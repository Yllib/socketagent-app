import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'multi_client_prompt_test.dart' show withSession;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Fix asks the computer to rerun setup and reports its answer', () async {
    final asked = Completer<Map<String, dynamic>>();
    await withSession(
      (provider, send) async {
        expect(
          provider.canRerunWindowsSetupElevated('multi-client-server'),
          isFalse,
        );
        await send({
          'type': 'server_capabilities',
          'windowsElevated': false,
          'windowsSetupElevationVersion': 1,
        });
        expect(provider.isLimitedWindowsInstall('multi-client-server'), isTrue);
        expect(
          provider.canRerunWindowsSetupElevated('multi-client-server'),
          isTrue,
        );

        final result = provider.rerunWindowsSetupElevated(
          'multi-client-server',
        );
        final request = await asked.future.timeout(const Duration(seconds: 5));
        await send({
          'type': 'windows_setup_elevation_result',
          'requestId': request['requestId'],
          'ok': false,
          'error': 'The administrator prompt was declined',
        });
        expect(
          await result.timeout(const Duration(seconds: 5)),
          'The administrator prompt was declined',
        );
      },
      onClientMessage: (event) {
        if (event['type'] == 'rerun_windows_setup_elevated' &&
            !asked.isCompleted) {
          asked.complete(event);
        }
      },
    );
  });
}
