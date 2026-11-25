import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/message.dart';
import '../services/chat_provider.dart';
import 'computer_access_card.dart';

/// Shows an app-wide approval card, such as an AI connector client asking to
/// use a board, over whatever screen is open. It closes itself once the card
/// is answered here or elsewhere, or expires.
Future<void> showComputerAccessDialog(BuildContext context, ChatMessage card) {
  return showDialog<void>(
    context: context,
    builder: (_) => ComputerAccessDialog(card: card),
  );
}

class ComputerAccessDialog extends StatefulWidget {
  const ComputerAccessDialog({super.key, required this.card});

  final ChatMessage card;

  @override
  State<ComputerAccessDialog> createState() => _ComputerAccessDialogState();
}

class _ComputerAccessDialogState extends State<ComputerAccessDialog> {
  bool _closing = false;

  @override
  Widget build(BuildContext context) {
    // The provider notifies when the card's status changes.
    context.watch<ChatProvider>();
    if (widget.card.answered && !_closing) {
      _closing = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).pop();
      });
    }
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: SingleChildScrollView(
        child: ComputerAccessCard(message: widget.card),
      ),
    );
  }
}
