import 'package:flutter/material.dart';

/// Kept outside message selection so dates never become copied message text.
class MessageTimestamp extends StatelessWidget {
  const MessageTimestamp({super.key, required this.timestamp});

  final DateTime timestamp;

  @override
  Widget build(BuildContext context) {
    final local = timestamp.toLocal();
    final localization = MaterialLocalizations.of(context);
    // Time only. The run boundary carries the date when the day changes.
    final time = localization.formatTimeOfDay(
      TimeOfDay.fromDateTime(local),
      alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
    );
    return Text(
      time,
      style: TextStyle(
        fontSize: 10,
        height: 1.2,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }
}

class TimestampedChatCard extends StatelessWidget {
  const TimestampedChatCard({
    super.key,
    required this.timestamp,
    required this.child,
  });

  final DateTime timestamp;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      child,
      Padding(
        padding: const EdgeInsets.only(left: 12, right: 12, bottom: 4),
        child: MessageTimestamp(timestamp: timestamp),
      ),
    ],
  );
}
