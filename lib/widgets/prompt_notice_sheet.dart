import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:google_fonts/google_fonts.dart';

import '../config/app_palette.dart';
import '../services/socketagent_link_router.dart';
import 'app_bottom_sheet.dart';
import 'inline_chat_images.dart';
import 'markdown_blocks.dart';

/// Opens the full text behind a card that stands in for a prompt the server
/// sent, such as a scheduled reminder or a delegated agent's question.
/// [markdown] comes from the prompt's parser; [serverId] is the computer
/// whose chat the card is in, for images and file links.
Future<void> showPromptNoticeSheet(
  BuildContext context, {
  required String markdown,
  String? serverId,
}) {
  return showAppBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.black,
    builder: (sheetContext) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      minChildSize: 0.3,
      maxChildSize: 0.95,
      builder: (_, controller) => ListView(
        controller: controller,
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [
          MarkdownSelectionArea(
            child: _NoticeMarkdown(markdown: markdown, serverId: serverId),
          ),
        ],
      ),
    ),
  );
}

class _NoticeMarkdown extends StatelessWidget {
  const _NoticeMarkdown({required this.markdown, this.serverId});

  final String markdown;
  final String? serverId;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final body = TextStyle(fontSize: 14, height: 1.5, color: p.text);
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
          style: GoogleFonts.jetBrainsMono(fontSize: 12, color: p.text),
          padding: const EdgeInsets.all(8),
          background: p.panelLow,
        ),
      },
      onTapLink: (text, href, title) =>
          SocketAgentLinkRouter.open(context, href, sourceServerId: serverId),
      styleSheet: MarkdownStyleSheet(
        p: body,
        listBullet: body,
        h3: body.copyWith(fontSize: 16, fontWeight: FontWeight.w700),
        a: body.copyWith(color: p.blue),
        code: GoogleFonts.jetBrainsMono(fontSize: 12.5, color: p.text),
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
