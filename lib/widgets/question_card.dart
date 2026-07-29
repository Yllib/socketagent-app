import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import '../models/message.dart';
import 'scroll_passthrough.dart';

class QuestionCard extends StatefulWidget {
  final ChatMessage message;
  final void Function(String questionId, Map<String, String> answers) onAnswer;

  const QuestionCard({
    super.key,
    required this.message,
    required this.onAnswer,
  });

  @override
  State<QuestionCard> createState() => _QuestionCardState();
}

class _QuestionCardState extends State<QuestionCard> {
  final Map<String, Set<String>> _selectedOptions = {};
  final Map<String, TextEditingController> _otherControllers = {};

  @override
  void dispose() {
    for (final c in _otherControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _submit() {
    final answers = <String, String>{};
    for (final q in widget.message.questions ?? <QuestionItem>[]) {
      final key = q.question;
      final selected = _selectedOptions[key] ?? {};
      final extra = _otherControllers[key]?.text.trim() ?? '';
      final parts = <String>[
        if (selected.isNotEmpty) selected.join(', '),
        if (extra.isNotEmpty) extra,
      ];
      answers[key] = parts.join(' — ');
    }
    widget.onAnswer(widget.message.questionId!, answers);
  }

  bool get _isPlanReview =>
      widget.message.questions?.any((q) => q.header == 'Plan Review') ?? false;

  @override
  Widget build(BuildContext context) {
    final questions = widget.message.questions ?? [];
    final isAnswered = widget.message.answered;
    final theme = Theme.of(context);
    final isPlan = _isPlanReview;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Card(
        color: isAnswered
            ? theme.colorScheme.surfaceContainerHighest.withAlpha(128)
            : isPlan
            ? theme.colorScheme.tertiaryContainer
            : theme.colorScheme.secondaryContainer,
        elevation: isAnswered ? 0 : 2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    isPlan ? Icons.architecture : Icons.help_outline,
                    size: 20,
                    color: isPlan
                        ? theme.colorScheme.onTertiaryContainer
                        : theme.colorScheme.onSecondaryContainer,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    isPlan ? 'Plan Review' : 'Question',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: isPlan
                          ? theme.colorScheme.onTertiaryContainer
                          : theme.colorScheme.onSecondaryContainer,
                    ),
                  ),
                  if (isAnswered) ...[
                    const SizedBox(width: 8),
                    Icon(
                      Icons.check_circle,
                      size: 18,
                      color: Colors.green.shade400,
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 12),
              for (final q in questions)
                _buildQuestionSection(context, q, isAnswered),
              if (!isAnswered) ...[
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton(
                    onPressed: _submit,
                    child: const Text('Submit'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildQuestionSection(
    BuildContext context,
    QuestionItem question,
    bool isAnswered,
  ) {
    final key = question.question;
    _selectedOptions.putIfAbsent(key, () => {});
    _otherControllers.putIfAbsent(key, () => TextEditingController());

    final isPlanReview = question.header == 'Plan Review';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (question.header != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              question.header!,
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5,
              ),
            ),
          ),
        if (isPlanReview)
          Container(
            constraints: const BoxConstraints(maxHeight: 400),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
            ),
            padding: const EdgeInsets.all(12),
            child: ScrollPassthrough(
              child: Scrollbar(
                child: SingleChildScrollView(
                  child: MarkdownBody(
                    data: question.question,
                    styleSheet: MarkdownStyleSheet(
                      p: TextStyle(
                        fontSize: 13,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                      h1: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                      h2: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                      h3: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                      code: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.primary,
                        backgroundColor: Theme.of(
                          context,
                        ).colorScheme.surfaceContainerHighest,
                      ),
                      listBullet: TextStyle(
                        fontSize: 13,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          )
        else
          Text(question.question, style: const TextStyle(fontSize: 14)),
        const SizedBox(height: 8),
        if (!isAnswered) ...[
          if (question.options.any(
            (o) => o.preview != null && o.preview!.isNotEmpty,
          ))
            Column(
              children: [
                for (final opt in question.options)
                  _buildOptionChip(key, opt, question.multiSelect),
              ],
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final opt in question.options)
                  _buildOptionChip(key, opt, question.multiSelect),
              ],
            ),
          if (!isPlanReview)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: TextField(
                controller: _otherControllers[key],
                decoration: InputDecoration(
                  hintText: 'Add context or type a custom answer...',
                  isDense: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                maxLines: 2,
              ),
            ),
        ] else ...[
          _buildSubmittedAnswer(context, question),
        ],
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _buildSubmittedAnswer(BuildContext context, QuestionItem question) {
    final answer =
        widget.message.answers?[question.question]?.trim() ??
        (question.header == null
            ? ''
            : widget.message.answers?[question.header!]?.trim() ?? '');
    if (answer.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Your answer',
            style: TextStyle(
              color: theme.colorScheme.onSurfaceVariant,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 3),
          SelectableText(answer, style: const TextStyle(fontSize: 14)),
        ],
      ),
    );
  }

  Widget _buildOptionChip(
    String questionKey,
    QuestionOption option,
    bool multiSelect,
  ) {
    final selected =
        _selectedOptions[questionKey]?.contains(option.label) ?? false;

    // If option has a preview, render a richer card with markdown preview
    if (option.preview != null && option.preview!.isNotEmpty) {
      return _buildPreviewOption(questionKey, option, multiSelect, selected);
    }

    return FilterChip(
      label: Text(option.label),
      tooltip: option.description,
      selected: selected,
      onSelected: (val) {
        setState(() {
          if (multiSelect) {
            if (val) {
              _selectedOptions[questionKey]!.add(option.label);
            } else {
              _selectedOptions[questionKey]!.remove(option.label);
            }
          } else {
            _selectedOptions[questionKey] = val ? {option.label} : {};
          }
        });
      },
    );
  }

  Widget _buildPreviewOption(
    String questionKey,
    QuestionOption option,
    bool multiSelect,
    bool selected,
  ) {
    final theme = Theme.of(context);

    return GestureDetector(
      onTap: () {
        setState(() {
          if (multiSelect) {
            if (selected) {
              _selectedOptions[questionKey]!.remove(option.label);
            } else {
              _selectedOptions[questionKey]!.add(option.label);
            }
          } else {
            _selectedOptions[questionKey] = selected ? {} : {option.label};
          }
        });
      },
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: selected
              ? theme.colorScheme.primaryContainer
              : theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected
                ? theme.colorScheme.primary
                : theme.colorScheme.outlineVariant,
            width: selected ? 2 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
              child: Row(
                children: [
                  if (selected)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: Icon(
                        Icons.check_circle,
                        size: 16,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  Expanded(
                    child: Text(
                      option.label,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                        color: selected
                            ? theme.colorScheme.onPrimaryContainer
                            : theme.colorScheme.onSurface,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (option.description != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                child: Text(
                  option.description!,
                  style: TextStyle(
                    fontSize: 11,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            Container(
              margin: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                borderRadius: BorderRadius.circular(8),
              ),
              child: MarkdownBody(
                data: option.preview!,
                styleSheet: MarkdownStyleSheet(
                  p: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.onSurface,
                  ),
                  code: TextStyle(
                    fontSize: 11,
                    color: theme.colorScheme.primary,
                    backgroundColor: theme.colorScheme.surfaceContainerHighest,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
