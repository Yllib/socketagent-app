import 'package:flutter/material.dart';

import '../services/tts_engine.dart';

class TtsPlaybackBar extends StatefulWidget {
  final TtsPlaybackState state;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final VoidCallback onRestart;
  final ValueChanged<double> onSeek;
  final VoidCallback onClose;

  const TtsPlaybackBar({
    super.key,
    required this.state,
    required this.onPause,
    required this.onResume,
    required this.onRestart,
    required this.onSeek,
    required this.onClose,
  });

  @override
  State<TtsPlaybackBar> createState() => _TtsPlaybackBarState();
}

class _TtsPlaybackBarState extends State<TtsPlaybackBar> {
  double? _dragProgress;

  @override
  void didUpdateWidget(covariant TtsPlaybackBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_dragProgress != null && oldWidget.state.text != widget.state.text) {
      _dragProgress = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = widget.state;
    final progress = (_dragProgress ?? state.progress).clamp(0.0, 1.0);
    final loading = state.isLoading;
    final canSeek = !loading && state.duration > Duration.zero;

    return Material(
      color: theme.colorScheme.surfaceContainerHigh,
      child: Container(
        key: const ValueKey<String>('tts-playback-bar'),
        padding: const EdgeInsets.fromLTRB(8, 5, 4, 5),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: theme.colorScheme.outlineVariant.withAlpha(120),
            ),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                IconButton(
                  key: const ValueKey<String>('tts-restart'),
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Restart from beginning',
                  onPressed: loading ? null : widget.onRestart,
                  icon: const Icon(Icons.skip_previous_rounded, size: 22),
                ),
                if (loading)
                  const SizedBox(
                    key: ValueKey<String>('tts-loading'),
                    width: 36,
                    height: 36,
                    child: Padding(
                      padding: EdgeInsets.all(8),
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    ),
                  )
                else
                  IconButton(
                    key: const ValueKey<String>('tts-play-pause'),
                    visualDensity: VisualDensity.compact,
                    tooltip: state.isPlaying ? 'Pause' : 'Play',
                    onPressed: state.isPlaying
                        ? widget.onPause
                        : state.isPaused
                        ? widget.onResume
                        : widget.onRestart,
                    icon: Icon(
                      state.isPlaying
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                      size: 25,
                    ),
                  ),
                const SizedBox(width: 4),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _statusLabel(state),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: state.status == TtsPlaybackStatus.error
                              ? theme.colorScheme.error
                              : theme.colorScheme.onSurface,
                        ),
                      ),
                      Text(
                        state.status == TtsPlaybackStatus.error
                            ? state.error ?? 'Speech playback failed'
                            : state.text.replaceAll(RegExp(r'\s+'), ' ').trim(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  key: const ValueKey<String>('tts-close'),
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Stop and close',
                  onPressed: widget.onClose,
                  icon: const Icon(Icons.close_rounded, size: 21),
                ),
              ],
            ),
            Row(
              children: [
                SizedBox(
                  width: 40,
                  child: Text(
                    _formatDuration(state.duration * progress),
                    textAlign: TextAlign.right,
                    style: theme.textTheme.labelSmall,
                  ),
                ),
                Expanded(
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 2.5,
                      thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 6,
                      ),
                      overlayShape: const RoundSliderOverlayShape(
                        overlayRadius: 14,
                      ),
                    ),
                    child: Slider(
                      key: const ValueKey<String>('tts-progress'),
                      value: progress,
                      onChanged: canSeek
                          ? (value) => setState(() => _dragProgress = value)
                          : null,
                      onChangeEnd: canSeek
                          ? (value) {
                              setState(() => _dragProgress = null);
                              widget.onSeek(value);
                            }
                          : null,
                    ),
                  ),
                ),
                SizedBox(
                  width: 40,
                  child: Text(
                    _formatDuration(state.duration),
                    style: theme.textTheme.labelSmall,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _statusLabel(TtsPlaybackState state) {
    switch (state.status) {
      case TtsPlaybackStatus.loading:
        return 'Preparing speech…';
      case TtsPlaybackStatus.playing:
        return 'Reading aloud';
      case TtsPlaybackStatus.paused:
        return 'Paused';
      case TtsPlaybackStatus.completed:
        return 'Finished';
      case TtsPlaybackStatus.error:
        return 'Unable to play speech';
      case TtsPlaybackStatus.idle:
        return '';
    }
  }

  String _formatDuration(Duration duration) {
    final totalSeconds = duration.inSeconds.clamp(0, 24 * 60 * 60);
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }
}
