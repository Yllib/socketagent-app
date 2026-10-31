import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'inline_chat_images.dart';
import 'markdown_blocks.dart';
import '../models/message.dart';
import '../services/socketagent_link_router.dart';
import 'scroll_passthrough.dart';
import '../config/app_palette.dart';

class QuestionCard extends StatefulWidget {
  final ChatMessage message;
  final void Function(String questionId, Map<String, String> answers) onAnswer;
  final String? sourceServerId;

  const QuestionCard({
    super.key,
    required this.message,
    required this.onAnswer,
    this.sourceServerId,
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

    final accent = isPlan
        ? theme.colorScheme.tertiary
        : theme.colorScheme.primary;
    final icon = isPlan ? Icons.architecture : Icons.help_outline;
    final titleText = isPlan ? 'Plan Review' : 'Question';
    final single = questions.length == 1;
    final answeredMark = isAnswered
        ? Padding(
            padding: const EdgeInsets.only(left: 6),
            child: Icon(
              Icons.check_circle,
              size: 16,
              color: context.palette.shade(Colors.green, 400),
            ),
          )
        : null;
    final submit = isAnswered
        ? null
        : FilledButton(
            onPressed: _submit,
            style: FilledButton.styleFrom(
              minimumSize: const Size(0, 36),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('Submit'),
          );

    // A flat block with a left accent, not a raised card. With one question
    // its header line doubles as the card title.
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(
        color: isAnswered
            ? theme.colorScheme.surfaceContainerLow
            : theme.colorScheme.surfaceContainer,
        border: Border(
          left: BorderSide(
            color: accent.withAlpha(isAnswered ? 110 : 255),
            width: 3,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!single) ...[
            Row(
              children: [
                Icon(icon, size: 16, color: accent),
                const SizedBox(width: 6),
                Text(
                  titleText,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: accent,
                  ),
                ),
                ?answeredMark,
              ],
            ),
            const SizedBox(height: 6),
          ],
          for (final (index, q) in questions.indexed)
            _buildQuestionSection(
              context,
              q,
              isAnswered,
              leading: single ? Icon(icon, size: 14, color: accent) : null,
              trailing: single ? answeredMark : null,
              fallbackHeader: titleText,
              submit: index == questions.length - 1 ? submit : null,
            ),
        ],
      ),
    );
  }

  /// [submit] renders beside the custom-answer field, or below the options
  /// when the question has no field.
  Widget _buildQuestionSection(
    BuildContext context,
    QuestionItem question,
    bool isAnswered, {
    Widget? leading,
    Widget? trailing,
    required String fallbackHeader,
    Widget? submit,
  }) {
    final key = question.question;
    _selectedOptions.putIfAbsent(key, () => {});
    _otherControllers.putIfAbsent(key, () => TextEditingController());

    final isPlanReview = question.header == 'Plan Review';
    final header = question.header ?? (leading == null ? null : fallbackHeader);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (header != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              children: [
                if (leading != null) ...[leading, const SizedBox(width: 6)],
                Text(
                  header,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.5,
                  ),
                ),
                ?trailing,
              ],
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
            child: _scrollingMarkdown(context, question.question),
          )
        else if (question.header == 'Tool approval')
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 400),
            child: _scrollingMarkdown(context, question.question),
          )
        else
          Text(question.question, style: const TextStyle(fontSize: 14)),
        const SizedBox(height: 6),
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
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _otherControllers[key],
                      decoration: InputDecoration(
                        hintText: 'Add context or type a custom answer...',
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      minLines: 1,
                      maxLines: 3,
                    ),
                  ),
                  if (submit != null) ...[const SizedBox(width: 8), submit],
                ],
              ),
            )
          else if (submit != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Align(alignment: Alignment.centerRight, child: submit),
            ),
        ] else ...[
          _buildSubmittedAnswer(context, question),
        ],
        const SizedBox(height: 4),
      ],
    );
  }

  /// Question text rendered as markdown, scrolling inside its parent's
  /// height limit. Plan reviews and tool approvals carry markdown.
  Widget _scrollingMarkdown(BuildContext context, String data) {
    return ScrollPassthrough(
      child: Scrollbar(
        child: SingleChildScrollView(
          child: MarkdownBody(
            imageBuilder: (uri, title, alt) =>
                buildChatMarkdownImage(uri, title, alt, widget.sourceServerId),
            blockSyntaxes: const [ChatCompareSyntax()],
            builders: {
              'socketagent-compare': ChatCompareBuilder(widget.sourceServerId),
              'pre': CodeBlockBuilder(
                style: const TextStyle(fontSize: 12),
                background: Theme.of(
                  context,
                ).colorScheme.surfaceContainerHighest,
              ),
            },
            data: data,
            inlineSyntaxes: SocketAgentLinkRouter.inlineSyntaxes,
            onTapLink: (text, href, title) {
              SocketAgentLinkRouter.open(
                context,
                href,
                sourceServerId: widget.sourceServerId,
              );
            },
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
              codeblockDecoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(6),
              ),
              listBullet: TextStyle(
                fontSize: 13,
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
          ),
        ),
      ),
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
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(6),
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
      labelStyle: const TextStyle(fontSize: 13),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
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
                imageBuilder: (uri, title, alt) => buildChatMarkdownImage(
                  uri,
                  title,
                  alt,
                  widget.sourceServerId,
                ),
                blockSyntaxes: const [ChatCompareSyntax()],
                builders: {
                  'socketagent-compare': ChatCompareBuilder(
                    widget.sourceServerId,
                  ),
                  'pre': CodeBlockBuilder(
                    style: const TextStyle(fontSize: 11),
                    padding: const EdgeInsets.all(8),
                    background: theme.colorScheme.surfaceContainerHighest,
                  ),
                },
                data: option.preview!,
                inlineSyntaxes: SocketAgentLinkRouter.inlineSyntaxes,
                onTapLink: (text, href, title) {
                  SocketAgentLinkRouter.open(
                    context,
                    href,
                    sourceServerId: widget.sourceServerId,
                  );
                },
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
                  codeblockDecoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(6),
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
