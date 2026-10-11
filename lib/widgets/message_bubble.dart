import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:share_plus/share_plus.dart';
import '../models/message.dart';
import '../models/ai_response_report.dart';
import '../services/socketagent_link_router.dart';
import '../util/markdown_plain_text.dart';
import 'adaptive_action_sheet.dart';
import 'inline_chat_images.dart';
import 'markdown_blocks.dart';
import 'message_timestamp.dart';
import 'message_attachments.dart';
import '../config/app_palette.dart';

class MessageBubble extends StatelessWidget {
  static TextStyle _codeStyle(AppPalette palette) => GoogleFonts.jetBrainsMono(
    color: palette.text,
    backgroundColor: palette.panel,
    fontSize: 13,
  );

  final ChatMessage message;
  final bool codexRewind;
  final void Function(String uuid, {bool rewindFiles})? onRewindConversation;
  final void Function(String uuid)? onBranch;
  final void Function(String messageId)? onRetractPending;
  final ValueChanged<String>? onReadAloud;
  final Future<String?> Function(
    ChatMessage message,
    AiResponseReportCategory category,
  )?
  onReport;
  final String? sourceServerId;

  const MessageBubble({
    super.key,
    required this.message,
    this.codexRewind = false,
    this.onRewindConversation,
    this.onBranch,
    this.onRetractPending,
    this.onReadAloud,
    this.onReport,
    this.sourceServerId,
  });

  @override
  Widget build(BuildContext context) {
    final isUser = message.sender == MessageSender.user;
    final theme = Theme.of(context);

    final textColor = isUser
        ? theme.colorScheme.onPrimary
        : theme.colorScheme.onSurface;

    final hasActions =
        isUser &&
        message.uuid != null &&
        (onRewindConversation != null || onBranch != null);
    final hasMessageActions = !isUser && message.textContent.trim().isNotEmpty;

    final isPending = isUser && message.isPending;
    final priorityLabel = message.injectionPriority;
    final uploadProgress = message.uploadProgress;
    final isUploading = isUser && uploadProgress != null;

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Column(
        crossAxisAlignment: isUser
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          _buildBubbleStack(
            context,
            theme,
            textColor,
            isUser,
            isPending,
            priorityLabel,
            hasActions,
            hasMessageActions,
          ),
          Padding(
            padding: const EdgeInsets.only(left: 12, right: 12, bottom: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                MessageTimestamp(timestamp: message.timestamp),
                if (isUser) ..._deliveryMark(theme),
              ],
            ),
          ),
          if (isUploading)
            _buildUploadIndicator(context, theme, isUser, uploadProgress),
        ],
      ),
    );
  }

  /// An empty circle once the computer has the message, a check in it once
  /// the agent has it. A queued message shows only as a faded bubble.
  List<Widget> _deliveryMark(ThemeData theme) {
    final muted = theme.colorScheme.onSurfaceVariant;
    final (icon, color, label) = message.uuid != null
        ? (Icons.check_circle, muted, 'Read by the agent')
        : switch (message.delivery) {
            MessageDelivery.received => (
              Icons.radio_button_unchecked,
              muted,
              'Received by the computer',
            ),
            MessageDelivery.failed => (
              Icons.error_outline,
              theme.colorScheme.error,
              'Not delivered',
            ),
            MessageDelivery.queued || null => (null, muted, ''),
          };
    if (icon == null) return const [];
    return [
      const SizedBox(width: 4),
      Tooltip(
        message: label,
        child: Icon(icon, size: 12, color: color, semanticLabel: label),
      ),
    ];
  }

  Widget _buildBubbleStack(
    BuildContext context,
    ThemeData theme,
    Color textColor,
    bool isUser,
    bool isPending,
    String? priorityLabel,
    bool hasActions,
    bool hasMessageActions,
  ) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        GestureDetector(
          key: ValueKey<String>('message-bubble-actions-${message.id}'),
          onLongPress: hasActions
              ? () => _showRewindSheet(context)
              : hasMessageActions
              ? () => _showMessageActions(context)
              : null,
          child: Opacity(
            opacity: isPending ? 0.5 : 1.0,
            child: Container(
              margin: EdgeInsets.only(
                left: isUser ? 64 : 8,
                right: isUser ? 8 : 64,
                top: 4,
                bottom: 4,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: isUser
                    ? theme.colorScheme.primary
                    : theme.colorScheme.surfaceContainerHighest,
                border: isPending
                    ? Border.all(
                        color: theme.colorScheme.primary.withAlpha(128),
                        width: 1,
                        strokeAlign: BorderSide.strokeAlignOutside,
                      )
                    : null,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(16),
                  topRight: const Radius.circular(16),
                  bottomLeft: Radius.circular(isUser ? 16 : 4),
                  bottomRight: Radius.circular(isUser ? 4 : 16),
                ),
              ),
              child: isUser
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (message.attachments.isNotEmpty)
                          IconTheme(
                            data: IconThemeData(color: textColor),
                            child: DefaultTextStyle(
                              style: TextStyle(color: textColor, fontSize: 15),
                              child: MessageAttachments(
                                attachments: message.attachments,
                                sourceServerId: sourceServerId,
                              ),
                            ),
                          ),
                        if (message.textContent.isNotEmpty)
                          SelectableText(
                            message.textContent,
                            style: TextStyle(color: textColor, fontSize: 15),
                            contextMenuBuilder: (_, state) =>
                                AdaptiveTextSelectionToolbar.buttonItems(
                                  anchors: state.contextMenuAnchors,
                                  buttonItems: [
                                    ...state.contextMenuButtonItems,
                                    ..._desktopMenuItems(context, hasActions),
                                  ],
                                ),
                          ),
                      ],
                    )
                  : MarkdownSelectionArea(
                      menuItems: _desktopMenuItems(context, false),
                      // MarkdownBody's selectable mode creates one independent
                      // SelectableText per block. One selection area around
                      // ordinary rich text lets selection span paragraphs,
                      // lists, headings, and code blocks as one message.
                      child: MarkdownBody(
                        data: message.textContent,
                        selectable: false,
                        inlineSyntaxes: SocketAgentLinkRouter.inlineSyntaxes,
                        imageBuilder: (uri, title, alt) =>
                            buildChatMarkdownImage(
                              uri,
                              title,
                              alt,
                              sourceServerId,
                            ),
                        blockSyntaxes: const [ChatCompareSyntax()],
                        builders: {
                          'socketagent-compare': ChatCompareBuilder(
                            sourceServerId,
                          ),
                          'pre': CodeBlockBuilder(
                            style: _codeStyle(theme.palette),
                          ),
                        },
                        onTapLink: (text, href, title) {
                          SocketAgentLinkRouter.open(
                            context,
                            href,
                            sourceServerId: sourceServerId,
                          );
                        },
                        styleSheet: MarkdownStyleSheet(
                          p: TextStyle(
                            color: textColor,
                            fontSize: 15,
                            height: 1.4,
                          ),
                          h1: TextStyle(
                            color: textColor,
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                            height: 1.4,
                          ),
                          h2: TextStyle(
                            color: textColor,
                            fontSize: 19,
                            fontWeight: FontWeight.bold,
                            height: 1.4,
                          ),
                          h3: TextStyle(
                            color: textColor,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            height: 1.4,
                          ),
                          strong: TextStyle(
                            color: textColor,
                            fontWeight: FontWeight.bold,
                          ),
                          em: TextStyle(
                            color: textColor,
                            fontStyle: FontStyle.italic,
                          ),
                          code: _codeStyle(theme.palette),
                          codeblockDecoration: BoxDecoration(
                            color: context.palette.panel,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: context.palette.border,
                              width: 1,
                            ),
                          ),
                          codeblockPadding: const EdgeInsets.all(12),
                          codeblockAlign: WrapAlignment.start,
                          blockquoteDecoration: BoxDecoration(
                            border: Border(
                              left: BorderSide(
                                color: theme.colorScheme.primary,
                                width: 3,
                              ),
                            ),
                          ),
                          blockquotePadding: const EdgeInsets.only(left: 12),
                          a: TextStyle(
                            color: context.palette.blue,
                            decoration: TextDecoration.underline,
                          ),
                          listBullet: TextStyle(color: textColor, fontSize: 15),
                          tableHead: TextStyle(
                            color: textColor,
                            fontWeight: FontWeight.bold,
                          ),
                          tableBody: TextStyle(color: textColor),
                          tableBorder: TableBorder.all(
                            color: textColor.withAlpha(51),
                            width: 1,
                          ),
                          tableCellsPadding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          horizontalRuleDecoration: BoxDecoration(
                            border: Border(
                              top: BorderSide(
                                color: textColor.withAlpha(51),
                                width: 1,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
            ),
          ), // close Opacity
        ), // close GestureDetector
        if (isPending && priorityLabel != null)
          Positioned(
            bottom: 2,
            right: 12,
            child: GestureDetector(
              onTap: onRetractPending == null
                  ? null
                  : () => onRetractPending!(message.id),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: theme.colorScheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'queued: $priorityLabel',
                      style: TextStyle(
                        fontSize: 9,
                        color: theme.colorScheme.onSecondaryContainer,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (onRetractPending != null) ...[
                      const SizedBox(width: 4),
                      Icon(
                        Icons.undo,
                        size: 10,
                        color: theme.colorScheme.onSecondaryContainer,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        if (hasActions)
          Positioned(
            top: -2,
            left: 56,
            child: _RewindButton(onTap: () => _showRewindSheet(context)),
          ),
        if (hasMessageActions)
          Positioned(
            top: -2,
            right: 56,
            child: _MessageActionsButton(
              onTap: () => _showMessageActions(context),
            ),
          ),
      ],
    );
  }

  Future<void> _copy(BuildContext context, String text, String notice) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(notice)));
  }

  /// Message actions in the Windows right-click menu, after the text
  /// selection items. Phones reach the same actions by long press.
  List<ContextMenuButtonItem> _desktopMenuItems(
    BuildContext context,
    bool hasRewind,
  ) {
    if (!Platform.isWindows || message.textContent.trim().isEmpty) {
      return const [];
    }
    ContextMenuButtonItem item(String label, VoidCallback action) =>
        ContextMenuButtonItem(
          label: label,
          onPressed: () {
            ContextMenuController.removeAny();
            action();
          },
        );
    final isUser = message.sender == MessageSender.user;
    return [
      item(
        'Copy message',
        () => _copy(
          context,
          isUser
              ? message.textContent
              : markdownToPlainText(message.textContent),
          'Message copied',
        ),
      ),
      if (!isUser)
        item(
          'Copy as Markdown',
          () => _copy(context, message.textContent, 'Markdown copied'),
        ),
      if (!isUser && onReadAloud != null)
        item(
          'Read aloud',
          () => onReadAloud!(markdownToPlainText(message.textContent)),
        ),
      if (!isUser && onReport != null)
        item('Report response', () => _showReportSheet(context)),
      if (hasRewind) item('Rewind or branch', () => _showRewindSheet(context)),
    ];
  }

  void _showMessageActions(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      constraints: adaptiveActionSheetConstraints,
      builder: (sheetContext) => AdaptiveSheetBody(
        children: [
          ListTile(
            key: const ValueKey<String>('copy-message-plain'),
            leading: const Icon(Icons.content_copy_outlined),
            title: const Text('Copy as plain text'),
            subtitle: const Text('Copy without Markdown formatting'),
            onTap: () {
              Navigator.pop(sheetContext);
              _copy(
                context,
                markdownToPlainText(message.textContent),
                'Message copied',
              );
            },
          ),
          ListTile(
            key: const ValueKey<String>('copy-message-markdown'),
            leading: const Icon(Icons.code_outlined),
            title: const Text('Copy as Markdown'),
            subtitle: const Text('Copy the original formatting source'),
            onTap: () {
              Navigator.pop(sheetContext);
              _copy(context, message.textContent, 'Markdown copied');
            },
          ),
          ListTile(
            key: const ValueKey<String>('share-message'),
            leading: const Icon(Icons.share_outlined),
            title: const Text('Share'),
            subtitle: const Text('Share plain text with another app'),
            onTap: () async {
              Navigator.pop(sheetContext);
              try {
                await SharePlus.instance.share(
                  ShareParams(
                    text: markdownToPlainText(message.textContent),
                    subject: 'SocketAgent message',
                    title: 'Share message',
                  ),
                );
              } catch (_) {
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Unable to share this message')),
                );
              }
            },
          ),
          if (onReadAloud != null)
            ListTile(
              key: const ValueKey<String>('read-whole-message'),
              leading: const Icon(Icons.volume_up_outlined),
              title: const Text('Read aloud'),
              subtitle: const Text('Use your selected text-to-speech voice'),
              onTap: () {
                Navigator.pop(sheetContext);
                onReadAloud!(markdownToPlainText(message.textContent));
              },
            ),
          if (onReport != null)
            ListTile(
              key: const ValueKey<String>('report-ai-response'),
              leading: const Icon(Icons.flag_outlined),
              title: const Text('Report response'),
              subtitle: const Text('Flag offensive or unsafe AI content'),
              onTap: () {
                Navigator.pop(sheetContext);
                _showReportSheet(context);
              },
            ),
        ],
      ),
    );
  }

  Future<void> _showReportSheet(BuildContext context) async {
    final category = await showModalBottomSheet<AiResponseReportCategory>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      constraints: adaptiveActionSheetConstraints,
      builder: (sheetContext) => AdaptiveSheetBody(
        title: 'Why are you reporting this response?',
        subtitle:
            'SocketAgent will send this response and your reason to Rubano Enterprises for review.',
        children: [
          for (final option in AiResponseReportCategory.values)
            ListTile(
              key: ValueKey<String>('report-category-${option.wireName}'),
              leading: Icon(_reportIcon(option)),
              title: Text(option.label),
              onTap: () => Navigator.pop(sheetContext, option),
            ),
        ],
      ),
    );
    if (category == null || onReport == null || !context.mounted) return;

    final error = await onReport!(message, category);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(error ?? 'Response reported'),
        backgroundColor: error == null
            ? null
            : Theme.of(context).colorScheme.error,
      ),
    );
  }

  static IconData _reportIcon(AiResponseReportCategory category) =>
      switch (category) {
        AiResponseReportCategory.offensiveOrUnsafe => Icons.gpp_maybe_outlined,
        AiResponseReportCategory.misleadingOrDeceptive =>
          Icons.fact_check_outlined,
        AiResponseReportCategory.other => Icons.more_horiz,
      };

  Widget _buildUploadIndicator(
    BuildContext context,
    ThemeData theme,
    bool isUser,
    double progress,
  ) {
    // Server-side upload_progress events drive `progress` from real bytes
    // received. While we're waiting on the first event (progress == 0), the
    // spinner stays indeterminate so we don't sit at a misleading 0%.
    final name = message.uploadFileName ?? 'file';
    final pct = (progress.clamp(0.0, 1.0) * 100).round();
    final indeterminate = progress <= 0.0 || progress >= 1.0;
    return Container(
      margin: EdgeInsets.only(
        left: isUser ? 64 : 8,
        right: isUser ? 8 : 64,
        bottom: 4,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withAlpha(28),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(
              value: indeterminate ? null : progress,
              strokeWidth: 2,
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              indeterminate ? 'Uploading $name…' : 'Uploading $name… $pct%',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showRewindSheet(BuildContext context) {
    final uuid = message.uuid!;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      constraints: adaptiveActionSheetConstraints,
      builder: (ctx) => AdaptiveSheetBody(
        title: 'Rewind options',
        children: [
          if (onRewindConversation != null)
            ListTile(
              leading: Icon(
                Icons.history,
                color: context.palette.shade(Colors.orange, 400),
              ),
              title: Text(
                codexRewind ? 'Rewind to here' : 'Rewind Conversation',
              ),
              subtitle: Text(
                codexRewind
                    ? 'Remove this turn and later turns, keep files'
                    : 'Remove messages after this point, keep files',
              ),
              onTap: () {
                Navigator.pop(ctx);
                _confirmAction(
                  context,
                  title: codexRewind
                      ? 'Rewind to here?'
                      : 'Rewind Conversation',
                  body: codexRewind
                      ? 'Remove this prompt, its response, and every later turn from the active conversation?\n\n'
                            'Files and commands are not undone. A transcript backup is kept. '
                            'Messages sent during a turn can only be rewound from that turn’s first prompt.'
                      : 'Rewind the conversation to this message?\n\n'
                            'All messages after this point will be removed. '
                            'File changes will be kept as-is. '
                            'You can then send a new message to take a different path.',
                  actionLabel: 'Rewind',
                  color: context.palette.warning,
                  onConfirmed: () =>
                      onRewindConversation!(uuid, rewindFiles: false),
                );
              },
            ),
          if (onRewindConversation != null && !codexRewind)
            ListTile(
              leading: Icon(
                Icons.restore,
                color: context.palette.shade(Colors.deepOrange, 400),
              ),
              title: const Text('Rewind Everything'),
              subtitle: const Text('Revert files and remove messages'),
              onTap: () {
                Navigator.pop(ctx);
                _confirmAction(
                  context,
                  title: 'Rewind Everything',
                  body:
                      'Rewind the conversation and revert all file changes back to this message?\n\n'
                      'Both files and messages after this point will be reverted. '
                      'You can then send a new message to take a different path.',
                  actionLabel: 'Rewind',
                  color: Colors.deepOrange,
                  onConfirmed: () =>
                      onRewindConversation!(uuid, rewindFiles: true),
                );
              },
            ),
          if (onBranch != null)
            ListTile(
              leading: Icon(
                Icons.fork_right,
                color: context.palette.shade(Colors.blue, 400),
              ),
              title: const Text('Branch From Here'),
              subtitle: const Text('Fork into a new session at this point'),
              onTap: () {
                Navigator.pop(ctx);
                _confirmAction(
                  context,
                  title: 'Branch Conversation',
                  body:
                      'Create a new session branching from this message?\n\n'
                      'The original conversation stays untouched. '
                      'You\'ll be switched to the new branch.',
                  actionLabel: 'Branch',
                  color: context.palette.info,
                  onConfirmed: () => onBranch!(uuid),
                );
              },
            ),
        ],
      ),
    );
  }

  void _confirmAction(
    BuildContext context, {
    required String title,
    required String body,
    required String actionLabel,
    required Color color,
    required VoidCallback onConfirmed,
  }) {
    showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: color),
            child: Text(actionLabel),
          ),
        ],
      ),
    ).then((confirmed) {
      if (confirmed == true) onConfirmed();
    });
  }
}

class _MessageActionsButton extends StatelessWidget {
  const _MessageActionsButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      shape: const CircleBorder(),
      child: InkWell(
        key: const ValueKey<String>('assistant-message-actions-button'),
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: const Padding(
          padding: EdgeInsets.all(4),
          child: Icon(Icons.more_horiz, size: 16),
        ),
      ),
    );
  }
}

class _RewindButton extends StatefulWidget {
  final VoidCallback onTap;
  const _RewindButton({required this.onTap});

  @override
  State<_RewindButton> createState() => _RewindButtonState();
}

class _RewindButtonState extends State<_RewindButton> {
  bool _pressed = false;

  void _handleTap() {
    setState(() => _pressed = true);
    Future.delayed(const Duration(milliseconds: 200), () {
      if (mounted) setState(() => _pressed = false);
    });
    widget.onTap();
  }

  @override
  Widget build(BuildContext context) {
    // Shades of the accent, which follows the session's backend.
    final accent = Theme.of(context).colorScheme.primary;
    final light = Color.lerp(accent, Colors.white, .55)!;
    return GestureDetector(
      onTap: _handleTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: 24,
        height: 24,
        decoration: BoxDecoration(
          color: _pressed
              ? accent
              : Color.lerp(accent, Colors.black, .4)!.withAlpha(220),
          shape: BoxShape.circle,
          border: Border.all(
            color: _pressed ? light : light.withAlpha(120),
            width: _pressed ? 1.5 : 1,
          ),
        ),
        child: Icon(
          Icons.undo,
          size: 13,
          color: _pressed ? Colors.white : light,
        ),
      ),
    );
  }
}
