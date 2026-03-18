import 'package:flutter/widgets.dart';

/// Wraps a scrollable child so that overscroll at its extents
/// is forwarded to the nearest parent Scrollable (e.g. the chat ListView).
/// This prevents inner scroll views from "eating" scroll events when
/// the user has scrolled to the top or bottom of the card content.
class ScrollPassthrough extends StatelessWidget {
  final Widget child;
  const ScrollPassthrough({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return NotificationListener<OverscrollNotification>(
      onNotification: (notification) {
        final parentScrollable = Scrollable.maybeOf(context);
        if (parentScrollable != null) {
          parentScrollable.position.moveTo(
            parentScrollable.position.pixels + notification.overscroll,
          );
        }
        return true;
      },
      child: child,
    );
  }
}
