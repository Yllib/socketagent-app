import 'dart:convert';

import 'package:app/services/firebase_project_configuration_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  String configuration({String packageName = 'com.socketagent.app'}) {
    return jsonEncode({
      'project_info': {
        'project_number': '123456789',
        'project_id': 'socketagent-kevin',
      },
      'client': [
        {
          'client_info': {
            'mobilesdk_app_id': '1:123456789:android:abcdef',
            'android_client_info': {'package_name': packageName},
          },
          'api_key': [
            {'current_key': 'public-firebase-api-key'},
          ],
        },
      ],
    });
  }

  test('parses the matching Firebase Android app', () {
    final parsed = FirebaseProjectConfiguration.fromGoogleServicesJson(
      configuration(),
      expectedPackageName: 'com.socketagent.app',
    );

    expect(parsed.projectId, 'socketagent-kevin');
    expect(parsed.projectNumber, '123456789');
    expect(parsed.appId, '1:123456789:android:abcdef');
    expect(parsed.apiKey, 'public-firebase-api-key');
    expect(parsed.packageName, 'com.socketagent.app');
  });

  test('rejects a Firebase Android app for another package', () {
    expect(
      () => FirebaseProjectConfiguration.fromGoogleServicesJson(
        configuration(packageName: 'com.example.other'),
        expectedPackageName: 'com.socketagent.app',
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('com.socketagent.app'),
        ),
      ),
    );
  });

  test('rejects a service-account JSON on the phone', () {
    expect(
      () => FirebaseProjectConfiguration.fromGoogleServicesJson(
        jsonEncode({
          'type': 'service_account',
          'project_id': 'socketagent-kevin',
          'private_key': 'private-key',
        }),
        expectedPackageName: 'com.socketagent.app',
      ),
      throwsA(isA<FormatException>()),
    );
  });
}
