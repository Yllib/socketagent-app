import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../models/message.dart';

class MonitorCard extends StatefulWidget {
  final ChatMessage message;

  const MonitorCard({super.key, required this.message});

  @override
  State<MonitorCard> createState() => _MonitorCardState();
}

class _MonitorCardState extends State<MonitorCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final description = widget.message.textContent;
    final output = widget.message.toolOutput ?? '';
    final lines = output.split('\n').where((l) => l.isNotEmpty).toList();
    final lineCount = lines.length;
    final preview = lines.isNotEmpty
        ? (lines.last.length > 80 ? '${lines.last.substring(0, 80)}...' : lines.last)
        : '';

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E2E),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF45475A), width: 1),
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
                  const Icon(
                    Icons.monitor_heart_outlined,
                    size: 16,
                    color: Color(0xFF89B4FA),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Monitor',
                    style: GoogleFonts.jetBrainsMono(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: const Color(0xFF89B4FA),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    description,
                    style: GoogleFonts.jetBrainsMono(
                      fontSize: 11,
                      color: const Color(0xFFA6ADC8),
                    ),
                  ),
                  const Spacer(),
                  if (lineCount > 0)
                    Text(
                      '$lineCount line${lineCount == 1 ? '' : 's'}',
                      style: GoogleFonts.jetBrainsMono(
                        fontSize: 10,
                        color: const Color(0xFF6C7086),
                      ),
                    ),
                  const SizedBox(width: 4),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 16,
                    color: const Color(0xFF6C7086),
                  ),
                ],
              ),
            ),
          ),
          if (!_expanded && preview.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 12, right: 12, bottom: 8),
              child: Text(
                preview,
                style: GoogleFonts.jetBrainsMono(
                  fontSize: 10,
                  color: const Color(0xFF6C7086),
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          if (_expanded)
            Container(
              decoration: const BoxDecoration(
                color: Color(0xFF181825),
                borderRadius: BorderRadius.vertical(
                  bottom: Radius.circular(12),
                ),
              ),
              constraints: const BoxConstraints(maxHeight: 300),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(12),
                child: Text(
                  output,
                  style: GoogleFonts.jetBrainsMono(
                    fontSize: 11,
                    color: const Color(0xFFCDD6F4),
                    height: 1.4,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
