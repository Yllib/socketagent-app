import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:provider/provider.dart';

import '../../config/app_palette.dart';
import '../../services/chat_provider.dart';
import '../../services/socketagent_link_router.dart';
import '../../widgets/inline_chat_images.dart';
import '../../widgets/markdown_blocks.dart';

/// The computer a board image lives on, from the `computer` (relay public
/// key) and `computerName` the server adds to each image link in a card.
/// [serverId] is that computer's server on this device, or null when this
/// device isn't paired with it.
typedef BoardImageHost = ({String? serverId, String name});

BoardImageHost boardImageHost(BuildContext context, String link) {
  final query = Uri.tryParse(link)?.queryParameters ?? const {};
  final key = query['computer'] ?? '';
  final configs = context.read<ChatProvider>().serverConfigs;
  final server = key.isEmpty
      ? null
      : configs.where((c) => c.serverPubkey == key).firstOrNull;
  return (
    serverId: server?.id,
    name: server?.name ?? query['computerName'] ?? 'another computer',
  );
}

Widget _notHere(BuildContext context, BoardImageHost host) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 6),
  child: Text(
    'Image on ${host.name}, which this device isn\'t paired with.',
    style: TextStyle(fontSize: 12.5, color: context.palette.textSecondary),
  ),
);

/// A socketagent-compare block, loaded from the computer its first image
/// names.
class _BoardCompareBuilder extends MarkdownElementBuilder {
  @override
  bool isBlockElement() => true;
  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final link = RegExp(
      r'socketagent://image\?[^\s"]+',
    ).firstMatch(element.textContent)?.group(0);
    final host = boardImageHost(context, link ?? '');
    if (host.serverId == null) return _notHere(context, host);
    return ChatCompareBuilder(host.serverId).visitElementAfterWithContext(
      context,
      element,
      preferredStyle,
      parentStyle,
    );
  }
}

/// A card's `detail` as Markdown, in the board's text sizes. Images load
/// over the connection to the computer that saved them.
class BoardMarkdown extends StatelessWidget {
  const BoardMarkdown(this.data, {super.key, this.fontSize = 13.5});

  final String data;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final scheme = Theme.of(context).colorScheme;
    final body = TextStyle(fontSize: fontSize, height: 1.5, color: p.text);
    TextStyle heading(double size) => TextStyle(
      fontSize: size,
      height: 1.35,
      fontWeight: FontWeight.w700,
      color: p.text,
    );
    return MarkdownBody(
      data: data,
      selectable: true,
      inlineSyntaxes: SocketAgentLinkRouter.inlineSyntaxes,
      blockSyntaxes: const [ChatCompareSyntax()],
      imageBuilder: (uri, title, alt) {
        final host = boardImageHost(context, uri.toString());
        return host.serverId == null
            ? _notHere(context, host)
            : buildChatMarkdownImage(uri, title, alt, host.serverId);
      },
      onTapLink: (text, href, title) =>
          SocketAgentLinkRouter.open(context, href),
      builders: {
        'socketagent-compare': _BoardCompareBuilder(),
        'pre': CodeBlockBuilder(
          style: TextStyle(fontSize: fontSize - 1.5),
          background: scheme.surfaceContainerHighest,
        ),
      },
      styleSheet: MarkdownStyleSheet(
        p: body,
        listBullet: body,
        h1: heading(fontSize + 5),
        h2: heading(fontSize + 3),
        h3: heading(fontSize + 1),
        a: body.copyWith(color: p.blue),
        blockquote: body.copyWith(color: p.textSecondary),
        blockquoteDecoration: BoxDecoration(
          border: Border(left: BorderSide(color: p.outline, width: 3)),
        ),
        blockquotePadding: const EdgeInsets.only(left: 12),
        code: TextStyle(
          fontSize: fontSize - 1.5,
          color: p.text,
          backgroundColor: scheme.surfaceContainerHighest,
        ),
        codeblockDecoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(6),
        ),
        horizontalRuleDecoration: BoxDecoration(
          border: Border(top: BorderSide(color: p.border)),
        ),
      ),
    );
  }
}
