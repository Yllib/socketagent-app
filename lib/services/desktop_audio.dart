import 'dart:io';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';

/// Register before constructing players. The Windows MediaPlayer backend stalls
/// when loading the generated speech playlists used by our local TTS engines.
void initializeDesktopAudio() {
  if (!Platform.isWindows) return;
  JustAudioMediaKit.ensureInitialized(windows: true, linux: false);
  JustAudioMediaKit.title = 'SocketAgent Desktop';
}
