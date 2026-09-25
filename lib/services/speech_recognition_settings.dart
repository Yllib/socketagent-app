import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

enum AsrModel {
  zipformer('Zipformer', 'English', null, 0),
  moonshineTiny('Moonshine Tiny', 'English · 45 MB', 'tiny', 2),
  moonshineSmall('Moonshine Small', 'English · 142 MB', 'small', 4),
  moonshineMedium('Moonshine Medium', 'English · 269 MB', 'medium', 5);

  const AsrModel(
    this.label,
    this.description,
    this.moonshineSize,
    this.architecture,
  );
  final String label;
  final String description;
  final String? moonshineSize;
  final int architecture;
  bool get isMoonshine => moonshineSize != null;
}

/// Settings are applied at the next recording, never halfway through dictation.
class SpeechRecognitionSettings {
  const SpeechRecognitionSettings({
    this.model = AsrModel.zipformer,
    this.searchPaths = 1,
    this.stopAfterSilence = 4,
    this.endpointSilence = 1.2,
    this.vadThreshold = 0.5,
    this.updateInterval = 0.5,
  });
  final AsrModel model;
  final int searchPaths;
  final double stopAfterSilence;
  final double endpointSilence;
  final double vadThreshold;
  final double updateInterval;
  static const preferenceKey = 'speech_recognition_settings_v1';

  SpeechRecognitionSettings copyWith({
    AsrModel? model,
    int? searchPaths,
    double? stopAfterSilence,
    double? endpointSilence,
    double? vadThreshold,
    double? updateInterval,
  }) => SpeechRecognitionSettings(
    model: model ?? this.model,
    searchPaths: searchPaths ?? this.searchPaths,
    stopAfterSilence: stopAfterSilence ?? this.stopAfterSilence,
    endpointSilence: endpointSilence ?? this.endpointSilence,
    vadThreshold: vadThreshold ?? this.vadThreshold,
    updateInterval: updateInterval ?? this.updateInterval,
  );

  Map<String, Object> toJson() => {
    'model': model.name,
    'searchPaths': searchPaths,
    'stopAfterSilence': stopAfterSilence,
    'endpointSilence': endpointSilence,
    'vadThreshold': vadThreshold,
    'updateInterval': updateInterval,
  };

  factory SpeechRecognitionSettings.fromJson(Map<String, dynamic> json) {
    double bounded(String key, double fallback, double min, double max) {
      final value = json[key];
      return value is num && value.isFinite
          ? value.toDouble().clamp(min, max)
          : fallback;
    }

    return SpeechRecognitionSettings(
      model:
          AsrModel.values.where((m) => m.name == json['model']).firstOrNull ??
          AsrModel.zipformer,
      searchPaths: [1, 4, 8].contains(json['searchPaths'])
          ? json['searchPaths'] as int
          : 1,
      stopAfterSilence: bounded('stopAfterSilence', 4, 2, 12),
      endpointSilence: bounded('endpointSilence', 1.2, 0.4, 2.4),
      vadThreshold: bounded('vadThreshold', 0.5, 0.2, 0.8),
      updateInterval: bounded('updateInterval', 0.5, 0.25, 1.5),
    );
  }

  static Future<SpeechRecognitionSettings> load() async {
    final raw = (await SharedPreferences.getInstance()).getString(
      preferenceKey,
    );
    try {
      return raw == null
          ? const SpeechRecognitionSettings()
          : SpeechRecognitionSettings.fromJson(
              jsonDecode(raw) as Map<String, dynamic>,
            );
    } catch (_) {
      return const SpeechRecognitionSettings();
    }
  }

  Future<void> save() async => (await SharedPreferences.getInstance())
      .setString(preferenceKey, jsonEncode(toJson()));
}
