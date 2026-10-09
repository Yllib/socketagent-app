import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../models/message.dart';
import '../config/app_palette.dart';

class ReminderCard extends StatelessWidget {
  final ChatMessage message;
  const ReminderCard({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    final title = message.toolInput?['title'] as String? ?? 'Reminder';
    final scheduledTime = message.toolInput?['scheduledTime'] as String? ?? '';

    // Format the time for display
    final dt = DateTime.tryParse(scheduledTime);
    final timeStr = dt != null
        ? '${dt.month}/${dt.day} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}'
        : scheduledTime;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: context.palette.panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.palette.outline, width: 1),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Icon(Icons.alarm, size: 16, color: context.palette.yellow),
            const SizedBox(width: 8),
            Text(
              'Reminder',
              style: GoogleFonts.jetBrainsMono(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: context.palette.yellow,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '$title  $timeStr',
                style: GoogleFonts.jetBrainsMono(
                  fontSize: 11,
                  color: context.palette.textSecondary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
