import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../models/message.dart';
import '../services/chat_provider.dart';
import '../config/app_palette.dart';

class SpeakCard extends StatefulWidget {
  final ChatMessage message;

  const SpeakCard({super.key, required this.message});

  @override
  State<SpeakCard> createState() => _SpeakCardState();
}

class _SpeakCardState extends State<SpeakCard> {
  bool _expanded = false;

  String get _spokenText {
    return widget.message.toolInput?['text'] as String? ?? '';
  }

  @override
  Widget build(BuildContext context) {
    final text = _spokenText;
    final preview = text.length > 60 ? '${text.substring(0, 60)}...' : text;
    final provider = context.watch<ChatProvider>();
    final isSpeakingThis = provider.replaySpeakingText == text;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: context.palette.panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.palette.outline, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.vertical(
              top: const Radius.circular(12),
              bottom: _expanded ? Radius.zero : const Radius.circular(12),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Icon(
                    Icons.record_voice_over,
                    size: 16,
                    color: context.palette.green,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Speak',
                    style: GoogleFonts.jetBrainsMono(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: context.palette.green,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      preview,
                      style: GoogleFonts.jetBrainsMono(
                        fontSize: 11,
                        color: context.palette.textSecondary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      if (isSpeakingThis) {
                        provider.stopReplaySpeak();
                      } else {
                        provider.replaySpeak(text);
                      }
                    },
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Icon(
                        isSpeakingThis ? Icons.stop_circle : Icons.volume_up,
                        size: 22,
                        color: isSpeakingThis
                            ? context.palette.red
                            : context.palette.green,
                      ),
                    ),
                  ),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                    color: context.palette.textMuted,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded)
            Container(
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(color: context.palette.border, width: 1),
                ),
              ),
              padding: const EdgeInsets.all(12),
              child: SelectableText(
                text,
                style: GoogleFonts.jetBrainsMono(
                  fontSize: 12,
                  color: context.palette.text,
                  height: 1.5,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
