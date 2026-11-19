import 'package:flutter/material.dart';

import '../../config/app_palette.dart';
import '../../models/project_board.dart';

/// Colour and icon for each status kind. Needs you is the warm one, so it
/// is the first thing the eye lands on.
extension BoardKindStyle on StatusKind {
  Color color(AppPalette p) => switch (this) {
    StatusKind.incoming => p.lavender,
    StatusKind.active => p.blue,
    StatusKind.user => p.peach,
    StatusKind.other => p.mauve,
    StatusKind.done => p.green,
  };

  IconData get icon => switch (this) {
    StatusKind.incoming => Icons.inbox_outlined,
    StatusKind.active => Icons.play_circle_outline,
    StatusKind.user => Icons.front_hand_outlined,
    StatusKind.other => Icons.hourglass_empty,
    StatusKind.done => Icons.check_circle_outline,
  };

  String get label => switch (this) {
    StatusKind.incoming => 'New',
    StatusKind.active => 'Active',
    StatusKind.user => 'Needs you',
    StatusKind.other => 'Waiting on others',
    StatusKind.done => 'Done',
  };
}

extension AskKindStyle on AskKind {
  IconData get icon => switch (this) {
    AskKind.approve => Icons.verified_outlined,
    AskKind.send => Icons.send_outlined,
    AskKind.decide => Icons.call_split,
    AskKind.answer => Icons.question_answer_outlined,
  };
}

extension LinkKindStyle on LinkKind {
  IconData get icon => switch (this) {
    LinkKind.session => Icons.chat_bubble_outline,
    LinkKind.ticket => Icons.confirmation_number_outlined,
    LinkKind.thread => Icons.forum_outlined,
    LinkKind.url => Icons.link,
  };
}

extension WaitingKindStyle on WaitingKind {
  IconData get icon => switch (this) {
    WaitingKind.user => Icons.person_outline,
    WaitingKind.person => Icons.person_outline,
    WaitingKind.agent => Icons.smart_toy_outlined,
  };
}

/// "now", "12m", "5h", "3d", "6w": how long a card has sat in its status.
String boardAge(DateTime since, {DateTime? now}) {
  final d = (now ?? DateTime.now()).difference(since);
  if (d.inMinutes < 1) return 'now';
  if (d.inHours < 1) return '${d.inMinutes}m';
  if (d.inDays < 1) return '${d.inHours}h';
  if (d.inDays < 14) return '${d.inDays}d';
  return '${d.inDays ~/ 7}w';
}

/// A small filled dot in a status colour.
class StatusDot extends StatelessWidget {
  const StatusDot(this.color, {super.key, this.size = 8});
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}
