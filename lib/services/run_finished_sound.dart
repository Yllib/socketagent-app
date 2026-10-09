import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

/// Plays a short pop when the run on screen finishes, in place of a popup
/// notification. The player is created on first use and never takes audio
/// focus, so music or speech keep playing underneath it.
class RunFinishedSound {
  AudioPlayer? _player;

  Future<void> play() async {
    try {
      final player = _player ??= AudioPlayer(
        handleInterruptions: false,
        handleAudioSessionActivation: false,
      );
      if (player.audioSource == null) {
        await player.setAsset('assets/sounds/run_finished.wav');
      }
      await player.seek(Duration.zero);
      await player.play();
    } catch (error) {
      debugPrint('[Sound] Could not play the run finished sound: $error');
    }
  }

  Future<void> dispose() async => _player?.dispose();
}
