import 'package:flutter/material.dart';

import '../models/message.dart';
import '../util/format.dart';
import 'second_ticker.dart';

/// Timer icon and the time left before the server deletes an idle fleeting
/// session. Rebuilds once a minute, which is as fine as the label gets. A
/// running fleeting session has no deadline, so only the icon shows.
class FleetingTimeLeft extends StatelessWidget {
  const FleetingTimeLeft({super.key, required this.session});

  final Session session;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurface.withAlpha(150);
    final deadline = session.expiresAt;
    return ValueListenableBuilder<int>(
      valueListenable: minuteTicks,
      builder: (context, _, _) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.timer_outlined, size: 12, color: color),
          if (deadline != null) ...[
            const SizedBox(width: 3),
            Text(
              formatTimeLeft(deadline.difference(DateTime.now())),
              style: TextStyle(fontSize: 11, color: color),
            ),
          ],
        ],
      ),
    );
  }
}
