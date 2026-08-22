import 'package:app/services/tts_engine.dart';
import 'package:app/widgets/tts_playback_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pumpBar(
    WidgetTester tester,
    TtsPlaybackState state, {
    VoidCallback? onPause,
    VoidCallback? onResume,
    VoidCallback? onRestart,
    ValueChanged<double>? onSeek,
    VoidCallback? onClose,
    double? speed,
    ValueChanged<double>? onSpeedChanged,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TtsPlaybackBar(
            state: state,
            onPause: onPause ?? () {},
            onResume: onResume ?? () {},
            onRestart: onRestart ?? () {},
            onSeek: onSeek ?? (_) {},
            onClose: onClose ?? () {},
            speed: speed,
            onSpeedChanged: onSpeedChanged,
          ),
        ),
      ),
    );
  }

  testWidgets('shows an immediate loading state while speech is generated', (
    tester,
  ) async {
    var closed = false;
    await pumpBar(
      tester,
      const TtsPlaybackState(
        status: TtsPlaybackStatus.loading,
        text: 'A long response that is still being generated.',
      ),
      onClose: () => closed = true,
    );

    expect(find.byKey(const ValueKey<String>('tts-playback-bar')), findsOne);
    expect(find.byKey(const ValueKey<String>('tts-loading')), findsOne);
    expect(find.text('Preparing speech…'), findsOne);

    await tester.tap(find.byKey(const ValueKey<String>('tts-close')));
    expect(closed, isTrue);
  });

  testWidgets('playing state supports pause, restart, seeking, and close', (
    tester,
  ) async {
    var pauses = 0;
    var restarts = 0;
    var closes = 0;
    double? seek;
    await pumpBar(
      tester,
      const TtsPlaybackState(
        status: TtsPlaybackStatus.playing,
        text: 'Speech is currently playing.',
        position: Duration(seconds: 25),
        duration: Duration(seconds: 100),
        progress: 0.25,
      ),
      onPause: () => pauses++,
      onRestart: () => restarts++,
      onSeek: (value) => seek = value,
      onClose: () => closes++,
    );

    expect(find.text('Reading aloud'), findsOne);
    expect(find.text('0:25'), findsOne);
    expect(find.text('1:40'), findsOne);

    await tester.tap(find.byKey(const ValueKey<String>('tts-play-pause')));
    await tester.tap(find.byKey(const ValueKey<String>('tts-restart')));
    await tester.tap(find.byKey(const ValueKey<String>('tts-close')));

    var slider = tester.widget<Slider>(
      find.byKey(const ValueKey<String>('tts-progress')),
    );
    slider.onChanged!(0.7);
    await tester.pump();
    slider = tester.widget<Slider>(
      find.byKey(const ValueKey<String>('tts-progress')),
    );
    slider.onChangeEnd!(0.7);

    expect(pauses, 1);
    expect(restarts, 1);
    expect(closes, 1);
    expect(seek, 0.7);
  });

  testWidgets('paused state resumes and completed state replays', (
    tester,
  ) async {
    var resumes = 0;
    var restarts = 0;
    await pumpBar(
      tester,
      const TtsPlaybackState(
        status: TtsPlaybackStatus.paused,
        text: 'Paused speech.',
        duration: Duration(seconds: 20),
        progress: 0.5,
      ),
      onResume: () => resumes++,
      onRestart: () => restarts++,
    );
    await tester.tap(find.byKey(const ValueKey<String>('tts-play-pause')));
    expect(resumes, 1);

    await pumpBar(
      tester,
      const TtsPlaybackState(
        status: TtsPlaybackStatus.completed,
        text: 'Finished speech.',
        position: Duration(seconds: 20),
        duration: Duration(seconds: 20),
        progress: 1,
      ),
      onResume: () => resumes++,
      onRestart: () => restarts++,
    );
    await tester.tap(find.byKey(const ValueKey<String>('tts-play-pause')));
    expect(restarts, 1);
    expect(resumes, 1);
  });

  testWidgets('offers ElevenLabs speaking speed presets', (tester) async {
    double? selectedSpeed;
    await pumpBar(
      tester,
      const TtsPlaybackState(
        status: TtsPlaybackStatus.playing,
        text: 'Speech with adjustable speed.',
      ),
      speed: 1.0,
      onSpeedChanged: (value) => selectedSpeed = value,
    );

    expect(find.text('1.00×'), findsOne);
    await tester.tap(find.byKey(const ValueKey<String>('tts-speed')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1.20×'));

    expect(selectedSpeed, 1.2);
  });
}
