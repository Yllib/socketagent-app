import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:google_fonts/google_fonts.dart';

import '../config/app_palette.dart';
import '../services/socketagent_link_router.dart';
import 'inline_chat_images.dart';
import 'markdown_blocks.dart';
import 'scroll_passthrough.dart';

/// A card standing in for a prompt the server sent, such as a scheduled
/// reminder, a scheduled task's result or a delegated agent's question.
/// Tapping it expands the full message, [markdown] from the prompt's parser,
/// in place. [serverId] is the computer whose chat the card is in, for images
/// and file links.
class PromptNoticeCard extends StatefulWidget {
  const PromptNoticeCard({
    super.key,
    required this.icon,
    required this.color,
    required this.background,
    required this.label,
    required this.text,
    required this.markdown,
    this.serverId,
  });

  final IconData icon;
  final Color color;
  final Color background;
  final String label;
  final String text;
  final String markdown;
  final String? serverId;

  @override
  State<PromptNoticeCard> createState() => _PromptNoticeCardState();
}

class _PromptNoticeCardState extends State<PromptNoticeCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final color = widget.color;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: widget.background,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withAlpha(60)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Icon(widget.icon, size: 16, color: color),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.text,
                      maxLines: _expanded ? null : 2,
                      overflow: _expanded ? null : TextOverflow.ellipsis,
                      style: TextStyle(color: color, fontSize: 12),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: color.withAlpha(30),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      widget.label,
                      style: TextStyle(
                        color: color,
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                    color: context.palette.textMuted,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded)
            Container(
              constraints: const BoxConstraints(maxHeight: 360),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: color.withAlpha(60))),
              ),
              child: ScrollPassthrough(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                  child: MarkdownSelectionArea(
                    child: _NoticeMarkdown(
                      markdown: widget.markdown,
                      serverId: widget.serverId,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _NoticeMarkdown extends StatelessWidget {
  const _NoticeMarkdown({required this.markdown, this.serverId});

  final String markdown;
  final String? serverId;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final body = TextStyle(fontSize: 13, height: 1.45, color: p.text);
    return MarkdownBody(
      data: markdown,
      // Questions and task output are often plain text with one fact per line.
      softLineBreak: true,
      inlineSyntaxes: SocketAgentLinkRouter.inlineSyntaxes,
      blockSyntaxes: const [ChatCompareSyntax()],
      imageBuilder: (uri, title, alt) =>
          buildChatMarkdownImage(uri, title, alt, serverId),
      builders: {
        'socketagent-compare': ChatCompareBuilder(serverId),
        'pre': CodeBlockBuilder(
          style: GoogleFonts.jetBrainsMono(fontSize: 11.5, color: p.text),
          padding: const EdgeInsets.all(8),
          background: p.panelLow,
        ),
      },
      onTapLink: (text, href, title) =>
          SocketAgentLinkRouter.open(context, href, sourceServerId: serverId),
      styleSheet: MarkdownStyleSheet(
        p: body,
        listBullet: body,
        h3: body.copyWith(fontSize: 14, fontWeight: FontWeight.w700),
        a: body.copyWith(color: p.blue),
        code: GoogleFonts.jetBrainsMono(fontSize: 12, color: p.text),
        codeblockDecoration: BoxDecoration(
          color: p.panelLow,
          borderRadius: BorderRadius.circular(6),
        ),
        horizontalRuleDecoration: BoxDecoration(
          border: Border(top: BorderSide(color: p.border)),
        ),
      ),
    );
  }
}
