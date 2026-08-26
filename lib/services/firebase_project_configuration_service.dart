import 'dart:convert';

import 'package:flutter/services.dart';

class FirebaseProjectConfiguration {
  const FirebaseProjectConfiguration({
    required this.projectId,
    required this.projectNumber,
    required this.appId,
    required this.apiKey,
    required this.packageName,
  });

  final String projectId;
  final String projectNumber;
  final String appId;
  final String apiKey;
  final String packageName;

  factory FirebaseProjectConfiguration.fromGoogleServicesJson(
    String source, {
    required String expectedPackageName,
  }) {
    final decoded = jsonDecode(source);
    if (decoded is! Map) {
      throw const FormatException(
        'This is not a Firebase Android configuration',
      );
    }
    final projectInfo = decoded['project_info'];
    final clients = decoded['client'];
    if (projectInfo is! Map || clients is! List) {
      throw const FormatException('Firebase project information is missing');
    }

    Map<dynamic, dynamic>? matchingClient;
    for (final candidate in clients) {
      if (candidate is! Map) continue;
      final clientInfo = candidate['client_info'];
      final androidInfo = clientInfo is Map
          ? clientInfo['android_client_info']
          : null;
      if (androidInfo is Map &&
          androidInfo['package_name'] == expectedPackageName) {
        matchingClient = candidate;
        break;
      }
    }
    if (matchingClient == null) {
      throw FormatException(
        'The Firebase Android app must use package $expectedPackageName',
      );
    }

    final clientInfo = matchingClient['client_info'];
    final apiKeys = matchingClient['api_key'];
    final apiKey = apiKeys is List
        ? apiKeys
              .whereType<Map>()
              .map((entry) => entry['current_key'])
              .whereType<String>()
              .map((value) => value.trim())
              .firstWhere((value) => value.isNotEmpty, orElse: () => '')
        : '';
    final configuration = FirebaseProjectConfiguration(
      projectId: _requiredString(projectInfo['project_id']),
      projectNumber: _requiredString(projectInfo['project_number']),
      appId: _requiredString(
        clientInfo is Map ? clientInfo['mobilesdk_app_id'] : null,
      ),
      apiKey: apiKey,
      packageName: expectedPackageName,
    );
    if (configuration.apiKey.isEmpty) {
      throw const FormatException('Firebase API key is missing');
    }
    return configuration;
  }

  factory FirebaseProjectConfiguration.fromPlatformMap(Map value) {
    return FirebaseProjectConfiguration(
      projectId: _requiredString(value['projectId']),
      projectNumber: _requiredString(value['projectNumber']),
      appId: _requiredString(value['appId']),
      apiKey: _requiredString(value['apiKey']),
      packageName: _requiredString(value['packageName']),
    );
  }

  Map<String, String> toPlatformMap() => {
    'projectId': projectId,
    'projectNumber': projectNumber,
    'appId': appId,
    'apiKey': apiKey,
    'packageName': packageName,
  };

  static String _requiredString(Object? value) {
    final string = value is String ? value.trim() : '';
    if (string.isEmpty) {
      throw const FormatException('Firebase configuration is incomplete');
    }
    return string;
  }
}

class FirebaseProjectConfigurationService {
  FirebaseProjectConfigurationService._();

  static final FirebaseProjectConfigurationService instance =
      FirebaseProjectConfigurationService._();
  static const MethodChannel _channel = MethodChannel(
    'com.socketagent.app/intent',
  );

  FirebaseProjectConfiguration? _customConfiguration;
  String? _bundledProjectId;

  FirebaseProjectConfiguration? get customConfiguration => _customConfiguration;
  String? get bundledProjectId => _bundledProjectId;
  bool get usesCustomProject => _customConfiguration != null;

  Future<void> initialize() async {
    try {
      final value = await _channel.invokeMapMethod<Object?, Object?>(
        'getFirebaseProjectConfiguration',
      );
      final custom = value?['custom'];
      _customConfiguration = custom is Map
          ? FirebaseProjectConfiguration.fromPlatformMap(custom)
          : null;
      final bundled = value?['bundledProjectId'];
      _bundledProjectId = bundled is String && bundled.trim().isNotEmpty
          ? bundled.trim()
          : null;
    } on MissingPluginException {
      _customConfiguration = null;
      _bundledProjectId = null;
    }
  }

  Future<void> save(FirebaseProjectConfiguration configuration) async {
    await _channel.invokeMethod<void>(
      'setFirebaseProjectConfiguration',
      configuration.toPlatformMap(),
    );
    _customConfiguration = configuration;
  }

  Future<void> clear() async {
    await _channel.invokeMethod<void>('clearFirebaseProjectConfiguration');
    _customConfiguration = null;
  }
}
