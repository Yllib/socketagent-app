import 'package:flutter/material.dart';
import '../models/message.dart';

/// A native resume request blocks the submitted prompt. Dismissing the window
/// only postpones the choice; it never answers the SDK's dialog implicitly.
class ResumeContextCard extends StatefulWidget {
  const ResumeContextCard({
    super.key,
    required this.message,
    required this.onAnswer,
  });
  final ChatMessage message;
  final void Function(String, Map<String, String>) onAnswer;
  @override
  State<ResumeContextCard> createState() => _ResumeContextCardState();
}

class _ResumeContextCardState extends State<ResumeContextCard> {
  static final _shown = <String>{};
  DialogRoute<String>? _route;
  NavigatorState? _navigator;
  @override
  void initState() {
    super.initState();
    final id = widget.message.questionId!;
    if (!widget.message.answered && _shown.add(id)) {
      if (_shown.length > 512) _shown.remove(_shown.first);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && ModalRoute.of(context)?.isCurrent == true) _choose();
      });
    }
  }

  @override
  void didUpdateWidget(covariant ResumeContextCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.message.answered && _route != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _close());
    }
  }

  void _close() {
    final route = _route;
    _route = null;
    if (route?.isActive == true) _navigator?.removeRoute(route!);
  }

  @override
  void dispose() {
    // Remove our own route, never whichever route the user opened afterwards.
    WidgetsBinding.instance.addPostFrameCallback((_) => _close());
    super.dispose();
  }

  Future<void> _choose() async {
    if (_route != null || widget.message.answered) return;
    final question = widget.message.questions!.first;
    final route = DialogRoute<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(question.question),
        content: const Text(
          'Your message is waiting. Compact summarizes earlier context and may lose some detail. Keeping full context may use more tokens when resuming.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Decide later'),
          ),
          for (final option in question.options)
            TextButton(
              onPressed: () => Navigator.pop(context, option.label),
              child: Text(option.label),
            ),
        ],
      ),
    );
    _route = route;
    _navigator = Navigator.of(context);
    final choice = await _navigator!.push(route);
    _route = null;
    if (mounted && !widget.message.answered && choice != null) {
      widget.onAnswer(widget.message.questionId!, {question.question: choice});
    }
  }

  @override
  Widget build(BuildContext context) {
    final answered = widget.message.answered;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              answered
                  ? (widget.message.answers?.values.firstOrNull ??
                        'Resume request ended')
                  : 'Message waiting. Choose how to resume.',
            ),
          ),
          if (!answered)
            TextButton(onPressed: _choose, child: const Text('Review')),
        ],
      ),
    );
  }
}
