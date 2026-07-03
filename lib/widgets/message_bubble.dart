import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/message.dart';
import '../screens/file_manager_screen.dart';
import '../services/chat_provider.dart';

class MessageBubble extends StatelessWidget {
  final ChatMessage message;
  final void Function(String uuid, {bool rewindFiles})? onRewindConversation;
  final void Function(String uuid)? onBranch;
  final void Function(String messageId)? onRetractPending;

  const MessageBubble({
    super.key,
    required this.message,
    this.onRewindConversation,
    this.onBranch,
    this.onRetractPending,
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
          ),
          if (isUploading)
            _buildUploadIndicator(context, theme, isUser, uploadProgress),
        ],
      ),
    );
  }

  Widget _buildBubbleStack(
    BuildContext context,
    ThemeData theme,
    Color textColor,
    bool isUser,
    bool isPending,
    String? priorityLabel,
    bool hasActions,
  ) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        GestureDetector(
          onLongPress: hasActions ? () => _showRewindSheet(context) : null,
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
                  ? SelectableText(
                      message.textContent,
                      style: TextStyle(color: textColor, fontSize: 15),
                    )
                  : MarkdownBody(
                      data: message.textContent,
                      selectable: true,
                      onTapLink: (text, href, title) {
                        _handleLinkTap(context, href);
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
                        code: GoogleFonts.jetBrainsMono(
                          color: const Color(0xFFCDD6F4),
                          backgroundColor: const Color(0xFF1E1E2E),
                          fontSize: 13,
                        ),
                        codeblockDecoration: BoxDecoration(
                          color: const Color(0xFF1E1E2E),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: const Color(0xFF313244),
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
                          color: const Color(0xFF89B4FA),
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
      ],
    );
  }

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

  Future<void> _handleLinkTap(BuildContext context, String? href) async {
    if (href == null || href.trim().isEmpty) return;
    final uri = Uri.tryParse(href);
    if (uri == null) return;

    if (uri.scheme == 'socketagent' && uri.host == 'file') {
      await _handleSocketAgentFileLink(context, uri);
      return;
    }

    await launchUrl(uri);
  }

  Future<void> _handleSocketAgentFileLink(BuildContext context, Uri uri) async {
    final action = uri.pathSegments.isNotEmpty ? uri.pathSegments.first : '';
    final filePath = uri.queryParameters['path'];
    final serverId = uri.queryParameters['serverId'];
    if (filePath == null || filePath.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('File link is missing a path')),
      );
      return;
    }

    switch (action) {
      case 'download':
        await _downloadSocketAgentFile(context, filePath, serverId);
        return;
      case 'browse':
        _openFileManager(context, filePath, serverId);
        return;
      case 'reveal':
        _openFileManager(
          context,
          _parentPath(filePath),
          serverId,
          highlightPath: filePath,
        );
        return;
      case 'view':
        _openFileManager(
          context,
          _parentPath(filePath),
          serverId,
          highlightPath: filePath,
          initialAction: 'view',
        );
        return;
      default:
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Unsupported file link action: $action')),
        );
    }
  }

  Future<void> _downloadSocketAgentFile(
    BuildContext context,
    String filePath,
    String? serverId,
  ) async {
    final provider = context.read<ChatProvider>();
    final name = _baseName(filePath);
    try {
      await provider.downloadFileManagerFile(
        path: filePath,
        fileName: name,
        serverId: serverId == null || serverId.isEmpty
            ? provider.activeServerId
            : serverId,
        showInChat: true,
      );
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Downloading $name')));
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Download failed: $e')));
    }
  }

  void _openFileManager(
    BuildContext context,
    String path,
    String? serverId, {
    String? highlightPath,
    String? initialAction,
  }) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => FileManagerScreen(
          serverId: serverId == null || serverId.isEmpty ? null : serverId,
          initialPath: path,
          highlightPath: highlightPath,
          initialAction: initialAction,
        ),
      ),
    );
  }

  String _parentPath(String filePath) {
    final normalized = filePath.replaceAll('\\', '/');
    final idx = normalized.lastIndexOf('/');
    if (idx <= 0) return filePath.startsWith('/') ? '/' : '';
    return filePath.substring(0, idx);
  }

  String _baseName(String filePath) {
    final normalized = filePath.replaceAll('\\', '/');
    final idx = normalized.lastIndexOf('/');
    if (idx < 0 || idx == normalized.length - 1) return normalized;
    return normalized.substring(idx + 1);
  }

  void _showRewindSheet(BuildContext context) {
    final uuid = message.uuid!;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 32,
              height: 4,
              margin: const EdgeInsets.only(top: 12, bottom: 8),
              decoration: BoxDecoration(
                color: Theme.of(
                  context,
                ).colorScheme.onSurfaceVariant.withAlpha(80),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Text(
                'Rewind Options',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            const Divider(),
            if (onRewindConversation != null)
              ListTile(
                leading: Icon(Icons.history, color: Colors.orange.shade400),
                title: const Text('Rewind Conversation'),
                subtitle: const Text(
                  'Remove messages after this point, keep files',
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _confirmAction(
                    context,
                    title: 'Rewind Conversation',
                    body:
                        'Rewind the conversation to this message?\n\n'
                        'All messages after this point will be removed. '
                        'File changes will be kept as-is. '
                        'You can then send a new message to take a different path.',
                    actionLabel: 'Rewind',
                    color: Colors.orange,
                    onConfirmed: () =>
                        onRewindConversation!(uuid, rewindFiles: false),
                  );
                },
              ),
            if (onRewindConversation != null)
              ListTile(
                leading: Icon(Icons.restore, color: Colors.deepOrange.shade400),
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
                leading: Icon(Icons.fork_right, color: Colors.blue.shade400),
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
                    color: Colors.blue,
                    onConfirmed: () => onBranch!(uuid),
                  );
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
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
    return GestureDetector(
      onTap: _handleTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: 24,
        height: 24,
        decoration: BoxDecoration(
          color: _pressed
              ? Colors.orange.shade600
              : Colors.orange.shade800.withAlpha(200),
          shape: BoxShape.circle,
          border: Border.all(
            color: _pressed
                ? Colors.orange.shade200
                : Colors.orange.shade300.withAlpha(120),
            width: _pressed ? 1.5 : 1,
          ),
        ),
        child: Icon(
          Icons.undo,
          size: 13,
          color: _pressed ? Colors.white : Colors.orange.shade200,
        ),
      ),
    );
  }
}
