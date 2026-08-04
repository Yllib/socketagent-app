import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_highlight/flutter_highlight.dart';
import 'package:flutter_highlight/themes/github.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:open_filex/open_filex.dart';
import 'package:pdfx/pdfx.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../models/file_manager_entry.dart';
import '../models/server_config.dart';
import '../services/chat_provider.dart';
import '../services/websocket_service.dart';

enum _FilePreviewKind { text, markdown, html, code, image, pdf }

class FileManagerScreen extends StatefulWidget {
  final String? serverId;
  final String? initialPath;
  final String? highlightPath;
  final String? initialAction;

  const FileManagerScreen({
    super.key,
    this.serverId,
    this.initialPath,
    this.highlightPath,
    this.initialAction,
  });

  @override
  State<FileManagerScreen> createState() => _FileManagerScreenState();
}

class _FileManagerScreenState extends State<FileManagerScreen> {
  String? _serverId;
  String _currentPath = '';
  FileManagerListing? _listing;
  bool _includeHidden = false;
  bool _loading = true;
  String? _error;
  String _filter = '';
  final TextEditingController _filterController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _initialActionHandled = false;

  @override
  void initState() {
    super.initState();
    _serverId = widget.serverId;
    _currentPath = widget.initialPath ?? '';
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadInitialPath());
  }

  @override
  void dispose() {
    _filterController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadInitialPath() async {
    final provider = context.read<ChatProvider>();
    final serverId = _effectiveServerId(provider);
    if ((widget.initialPath == null || widget.initialPath!.isEmpty) &&
        serverId != null) {
      final prefs = await SharedPreferences.getInstance();
      final lastPath = prefs.getString('file_manager_last_path_$serverId');
      if (mounted && lastPath != null && lastPath.isNotEmpty) {
        _currentPath = lastPath;
      }
    }
    if (mounted) {
      await _load(_currentPath);
    }
  }

  List<ServerConfig> _availableServers(ChatProvider provider) {
    final connected = provider.serverConfigs
        .where(
          (config) =>
              provider.connMgr.statusOf(config.id) ==
              ConnectionStatus.connected,
        )
        .toList();
    return connected.isNotEmpty ? connected : provider.serverConfigs;
  }

  String? _effectiveServerId(ChatProvider provider) {
    final servers = _availableServers(provider);
    if (servers.isEmpty) return null;
    final preferred = _serverId ?? provider.activeServerId;
    if (preferred != null && servers.any((s) => s.id == preferred)) {
      return preferred;
    }
    return servers.first.id;
  }

  Future<void> _load([String? path]) async {
    final provider = context.read<ChatProvider>();
    final serverId = _effectiveServerId(provider);
    if (serverId == null) {
      setState(() {
        _loading = false;
        _error = 'No computer connected';
      });
      return;
    }

    setState(() {
      _serverId = serverId;
      _loading = true;
      _error = null;
    });

    try {
      final listing = await provider.listFileManagerDirectory(
        path ?? _currentPath,
        serverId: serverId,
        includeHidden: _includeHidden,
      );
      if (!mounted) return;
      setState(() {
        _listing = listing;
        _currentPath = listing.path;
        _loading = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _revealHighlightedEntry(listing);
      });
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('file_manager_last_path_$serverId', listing.path);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _setProtected(
    FileManagerEntry entry, {
    required bool protect,
    String pattern = 'exact',
  }) async {
    final provider = context.read<ChatProvider>();
    final serverId = _effectiveServerId(provider);
    if (serverId == null) return;
    try {
      await provider.setFileManagerProtected(
        path: entry.path,
        protected: protect,
        serverId: serverId,
        pattern: pattern,
      );
      await _load(_currentPath);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            protect ? 'Protected for agents' : 'Protection removed',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Protection update failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Consumer<ChatProvider>(
      builder: (context, provider, _) {
        final servers = _availableServers(provider);
        final selectedId = _effectiveServerId(provider);
        final selected = servers
            .where((server) => server.id == selectedId)
            .firstOrNull;

        return Scaffold(
          appBar: AppBar(
            title: Text(selected == null ? 'Computer Files' : selected.name),
            actions: [
              if (servers.length > 1)
                PopupMenuButton<String>(
                  icon: const Icon(Icons.dns_outlined),
                  tooltip: 'Computer',
                  onSelected: (id) {
                    setState(() {
                      _serverId = id;
                      _currentPath = '';
                    });
                    _load('');
                  },
                  itemBuilder: (_) => [
                    for (final server in servers)
                      PopupMenuItem(
                        value: server.id,
                        child: Row(
                          children: [
                            if (server.id == selectedId)
                              Icon(
                                Icons.check,
                                size: 16,
                                color: theme.colorScheme.primary,
                              )
                            else
                              const SizedBox(width: 16),
                            const SizedBox(width: 8),
                            Expanded(child: Text(server.name)),
                          ],
                        ),
                      ),
                  ],
                ),
              IconButton(
                tooltip: _includeHidden ? 'Hide dotfiles' : 'Show dotfiles',
                icon: Icon(
                  _includeHidden
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                ),
                onPressed: () {
                  setState(() => _includeHidden = !_includeHidden);
                  _load(_currentPath);
                },
              ),
              IconButton(
                tooltip: 'Refresh',
                icon: const Icon(Icons.refresh),
                onPressed: () => _load(_currentPath),
              ),
              IconButton(
                tooltip: 'Upload file',
                icon: const Icon(Icons.upload_file_outlined),
                onPressed: _uploadFile,
              ),
              IconButton(
                tooltip: 'New folder',
                icon: const Icon(Icons.create_new_folder_outlined),
                onPressed: _createFolder,
              ),
            ],
          ),
          body: Column(
            children: [
              _PathHeader(path: _currentPath),
              if (_listing?.roots.isNotEmpty == true)
                _RootChips(
                  roots: _listing!.roots,
                  currentPath: _currentPath,
                  onTap: _load,
                ),
              _SearchField(
                controller: _filterController,
                onChanged: (value) => setState(() => _filter = value),
              ),
              Expanded(child: _buildBody(theme, provider)),
            ],
          ),
        );
      },
    );
  }

  Widget _buildBody(ThemeData theme, ChatProvider provider) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.error_outline,
                size: 44,
                color: theme.colorScheme.error.withAlpha(190),
              ),
              const SizedBox(height: 12),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () => _load(_currentPath),
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    final listing = _listing;
    if (listing == null) return const SizedBox.shrink();
    final needle = _filter.trim().toLowerCase();
    final rows = needle.isEmpty
        ? listing.entries
        : listing.entries
              .where(
                (entry) =>
                    entry.name.toLowerCase().contains(needle) ||
                    entry.path.toLowerCase().contains(needle),
              )
              .toList();
    if (rows.isEmpty && listing.parentPath == null) {
      return Center(
        child: Text(
          needle.isEmpty ? 'No files' : 'No matching files',
          style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: () => _load(_currentPath),
      child: ListView.builder(
        controller: _scrollController,
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: rows.length + (listing.parentPath != null ? 1 : 0),
        itemBuilder: (context, index) {
          if (listing.parentPath != null && index == 0) {
            return ListTile(
              leading: Icon(
                Icons.arrow_upward,
                color: theme.colorScheme.primary,
              ),
              title: const Text('..'),
              subtitle: Text(listing.parentPath!),
              onTap: () => _load(listing.parentPath),
            );
          }
          final entryIndex = index - (listing.parentPath != null ? 1 : 0);
          final entry = rows[entryIndex];
          final fileId = provider.getFileId(entry.path);
          return _FileEntryTile(
            entry: entry,
            highlighted: entry.path == widget.highlightPath,
            isDownloading: fileId != null && provider.isDownloading(fileId),
            downloadProgress: fileId == null
                ? null
                : provider.getDownloadProgress(fileId),
            onOpen: entry.isDirectory
                ? () => _load(entry.path)
                : () => _showFileActions(entry),
            onDownload: entry.isDirectory ? null : () => _downloadEntry(entry),
            onProtectExact: () => _setProtected(entry, protect: true),
            onProtectDirectory: entry.isDirectory
                ? () =>
                      _setProtected(entry, protect: true, pattern: 'directory')
                : null,
            onUnprotect: entry.isProtected
                ? () => _setProtected(entry, protect: false)
                : null,
            onRename: () => _renameEntry(entry),
            onDelete: () => _deleteEntry(entry),
          );
        },
      ),
    );
  }

  void _revealHighlightedEntry(FileManagerListing listing) {
    final targetPath = widget.highlightPath;
    if (targetPath == null || targetPath.isEmpty) return;
    final index = listing.entries.indexWhere(
      (entry) => entry.path == targetPath,
    );
    if (index < 0) return;

    final visualIndex = index + (listing.parentPath != null ? 1 : 0);
    if (_scrollController.hasClients) {
      final offset = (visualIndex * 72.0 - 96).clamp(
        0.0,
        _scrollController.position.maxScrollExtent,
      );
      _scrollController.animateTo(
        offset,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOutCubic,
      );
    }

    if (_initialActionHandled ||
        (widget.initialAction != 'view' && widget.initialAction != 'open')) {
      return;
    }
    _initialActionHandled = true;
    final entry = listing.entries[index];
    if (widget.initialAction == 'open' && entry.isDirectory) {
      _load(entry.path);
      return;
    }
    if (_canPreview(entry)) {
      _previewEntry(entry);
    } else {
      _showFileActions(entry);
    }
  }

  Future<void> _downloadEntry(FileManagerEntry entry) async {
    final provider = context.read<ChatProvider>();
    final serverId = _effectiveServerId(provider);
    if (serverId == null) return;
    try {
      await provider.downloadFileManagerFile(
        path: entry.path,
        fileName: entry.name,
        serverId: serverId,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Downloading ${entry.name}')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Download failed: $e')));
    }
  }

  Future<void> _showFileActions(FileManagerEntry entry) async {
    final provider = context.read<ChatProvider>();
    final fileId = provider.getFileId(entry.path);
    final localPath = fileId == null
        ? null
        : provider.getReceivedFilePath(fileId);
    final hasLocalFile = localPath != null && File(localPath).existsSync();
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(_iconForEntry(entry)),
              title: Text(
                entry.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                entry.path,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (hasLocalFile)
              ListTile(
                leading: const Icon(Icons.open_in_new),
                title: const Text('Open downloaded file'),
                subtitle: Text(
                  localPath,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => Navigator.of(context).pop('open'),
              ),
            if (_canPreview(entry))
              ListTile(
                leading: const Icon(Icons.visibility_outlined),
                title: const Text('View'),
                onTap: () => Navigator.of(context).pop('preview'),
              ),
            ListTile(
              leading: const Icon(Icons.download_outlined),
              title: Text(hasLocalFile ? 'Download again' : 'Download'),
              onTap: () => Navigator.of(context).pop('download'),
            ),
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline),
              title: const Text('Rename'),
              onTap: () => Navigator.of(context).pop('rename'),
            ),
            ListTile(
              leading: Icon(
                Icons.delete_outline,
                color: Theme.of(context).colorScheme.error,
              ),
              title: Text(
                'Delete',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              onTap: () => Navigator.of(context).pop('delete'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;

    switch (action) {
      case 'open':
        if (localPath != null) {
          await OpenFilex.open(localPath);
        }
        break;
      case 'download':
        await _downloadEntry(entry);
        break;
      case 'preview':
        await _previewEntry(entry);
        break;
      case 'rename':
        await _renameEntry(entry);
        break;
      case 'delete':
        await _deleteEntry(entry);
        break;
    }
  }

  Future<void> _previewEntry(FileManagerEntry entry) async {
    final kind = _previewKindFor(entry);
    if (kind == null) return;
    if (kind == _FilePreviewKind.image) {
      await _previewImageEntry(entry);
      return;
    }
    if (kind == _FilePreviewKind.pdf) {
      await _previewPdfEntry(entry);
      return;
    }
    await _previewTextEntry(entry, kind);
  }

  Future<void> _previewTextEntry(
    FileManagerEntry entry,
    _FilePreviewKind kind,
  ) async {
    final provider = context.read<ChatProvider>();
    final serverId = _effectiveServerId(provider);
    if (serverId == null) return;
    try {
      final result = await provider.readFileManagerText(
        path: entry.path,
        serverId: serverId,
        maxBytes: 1024 * 1024,
      );
      if (!mounted) return;
      final content = result['content'] as String? ?? '';
      final truncated = result['truncated'] == true;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => _FileTextPreviewScreen(
            entry: entry,
            content: content,
            truncated: truncated,
            kind: kind,
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Preview failed: $e')));
    }
  }

  Future<void> _previewImageEntry(FileManagerEntry entry) async {
    final provider = context.read<ChatProvider>();
    final serverId = _effectiveServerId(provider);
    if (serverId == null) return;
    try {
      final base64Data = await provider.fetchFileManagerFileBase64(
        path: entry.path,
        fileName: entry.name,
        serverId: serverId,
      );
      if (!mounted) return;
      if (base64Data == null || base64Data.isEmpty) {
        throw Exception('No image data returned');
      }
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => _FileImagePreviewScreen(
            entry: entry,
            bytes: base64Decode(base64Data),
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Image preview failed: $e')));
    }
  }

  Future<void> _previewPdfEntry(FileManagerEntry entry) async {
    final provider = context.read<ChatProvider>();
    final serverId = _effectiveServerId(provider);
    if (serverId == null) return;
    try {
      final base64Data = await provider.fetchFileManagerFileBase64(
        path: entry.path,
        fileName: entry.name,
        serverId: serverId,
        timeout: const Duration(seconds: 45),
      );
      if (!mounted) return;
      if (base64Data == null || base64Data.isEmpty) {
        throw Exception('No PDF data returned');
      }
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => _FilePdfPreviewScreen(
            entry: entry,
            bytes: base64Decode(base64Data),
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('PDF preview failed: $e')));
    }
  }

  Future<void> _uploadFile() async {
    final provider = context.read<ChatProvider>();
    final serverId = _effectiveServerId(provider);
    if (serverId == null) return;
    final result = await FilePicker.platform.pickFiles();
    final file = result?.files.single;
    final localPath = file?.path;
    if (file == null || localPath == null) return;

    try {
      final serverPath = await provider.uploadFileManagerFile(
        localPath: localPath,
        name: file.name,
        targetDir: _currentPath,
        serverId: serverId,
        conflictPolicy: 'rename',
      );
      await _load(_currentPath);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Uploaded to $serverPath')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Upload failed: $e')));
    }
  }

  Future<void> _createFolder() async {
    final name = await _promptForName(
      title: 'New folder',
      label: 'Folder name',
    );
    if (!mounted) return;
    if (name == null || name.isEmpty) return;
    final provider = context.read<ChatProvider>();
    final serverId = _effectiveServerId(provider);
    if (serverId == null) return;
    try {
      await provider.createFileManagerFolder(
        path: _joinPath(_currentPath, name),
        serverId: serverId,
      );
      await _load(_currentPath);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Create folder failed: $e')));
    }
  }

  Future<void> _renameEntry(FileManagerEntry entry) async {
    final name = await _promptForName(
      title: 'Rename',
      label: 'New name',
      initialValue: entry.name,
    );
    if (!mounted) return;
    if (name == null || name.isEmpty || name == entry.name) return;
    final provider = context.read<ChatProvider>();
    final serverId = _effectiveServerId(provider);
    if (serverId == null) return;
    try {
      await provider.renameFileManagerEntry(
        fromPath: entry.path,
        toName: name,
        serverId: serverId,
      );
      await _load(_currentPath);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Rename failed: $e')));
    }
  }

  Future<void> _deleteEntry(FileManagerEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${entry.isDirectory ? 'folder' : 'file'}?'),
        content: Text(
          entry.isDirectory
              ? 'Delete "${entry.name}" and everything inside it?'
              : 'Delete "${entry.name}"?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (confirmed != true) return;
    final provider = context.read<ChatProvider>();
    final serverId = _effectiveServerId(provider);
    if (serverId == null) return;
    try {
      await provider.deleteFileManagerEntry(
        path: entry.path,
        recursive: entry.isDirectory,
        serverId: serverId,
      );
      await _load(_currentPath);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Delete failed: $e')));
    }
  }

  Future<String?> _promptForName({
    required String title,
    required String label,
    String initialValue = '',
  }) async {
    final controller = TextEditingController(text: initialValue);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(labelText: label),
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => Navigator.of(context).pop(controller.text.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    return result?.trim();
  }

  String _joinPath(String base, String name) {
    if (base.isEmpty) return name;
    final separator = base.contains('\\') ? '\\' : '/';
    if (base.endsWith(separator)) return '$base$name';
    return '$base$separator$name';
  }

  IconData _iconForEntry(FileManagerEntry entry) {
    if (entry.kind == FileManagerEntryKind.directory) {
      return Icons.folder_outlined;
    }
    if (_normalizedExtension(entry.extension) == 'pdf') {
      return Icons.picture_as_pdf_outlined;
    }
    switch (entry.mediaKind) {
      case FileManagerMediaKind.image:
        return Icons.image_outlined;
      case FileManagerMediaKind.video:
        return Icons.movie_outlined;
      case FileManagerMediaKind.audio:
        return Icons.audio_file_outlined;
      case FileManagerMediaKind.archive:
        return Icons.folder_zip_outlined;
      case FileManagerMediaKind.code:
        return Icons.code;
      case FileManagerMediaKind.text:
        return Icons.description_outlined;
      case FileManagerMediaKind.other:
        return Icons.insert_drive_file_outlined;
    }
  }

  bool _canPreview(FileManagerEntry entry) {
    return _previewKindFor(entry) != null;
  }

  _FilePreviewKind? _previewKindFor(FileManagerEntry entry) {
    if (entry.mediaKind == FileManagerMediaKind.image) {
      return _FilePreviewKind.image;
    }
    final extension = _normalizedExtension(entry.extension);
    if (extension == 'md' ||
        extension == 'markdown' ||
        extension == 'mdown' ||
        extension == 'mkd') {
      return _FilePreviewKind.markdown;
    }
    if (extension == 'html' || extension == 'htm') {
      return _FilePreviewKind.html;
    }
    if (extension == 'pdf') {
      return _FilePreviewKind.pdf;
    }
    if (entry.mediaKind == FileManagerMediaKind.code) {
      return _FilePreviewKind.code;
    }
    if (entry.mediaKind == FileManagerMediaKind.text) {
      return _FilePreviewKind.text;
    }
    return null;
  }
}

class _FileTextPreviewScreen extends StatefulWidget {
  final FileManagerEntry entry;
  final String content;
  final bool truncated;
  final _FilePreviewKind kind;

  const _FileTextPreviewScreen({
    required this.entry,
    required this.content,
    required this.truncated,
    required this.kind,
  });

  @override
  State<_FileTextPreviewScreen> createState() => _FileTextPreviewScreenState();
}

class _FileTextPreviewScreenState extends State<_FileTextPreviewScreen> {
  WebViewController? _webViewController;
  int _htmlZoomPercent = 100;

  @override
  void initState() {
    super.initState();
    if (widget.kind == _FilePreviewKind.html) {
      _webViewController = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.disabled)
        ..enableZoom(true)
        ..loadHtmlString(_htmlPreviewDocument);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.entry.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          if (widget.truncated)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Center(
                child: Chip(
                  label: const Text('Truncated'),
                  visualDensity: VisualDensity.compact,
                  side: BorderSide.none,
                  backgroundColor: Theme.of(
                    context,
                  ).colorScheme.secondaryContainer,
                ),
              ),
            ),
        ],
      ),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    final theme = Theme.of(context);
    switch (widget.kind) {
      case _FilePreviewKind.markdown:
        return Markdown(
          data: _displayContent,
          selectable: true,
          padding: const EdgeInsets.all(16),
          styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
            codeblockDecoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            blockquoteDecoration: BoxDecoration(
              border: Border(
                left: BorderSide(color: theme.colorScheme.primary, width: 4),
              ),
            ),
          ),
        );
      case _FilePreviewKind.html:
        final controller = _webViewController;
        if (controller == null) {
          return const Center(child: CircularProgressIndicator());
        }
        return Stack(
          children: [
            WebViewWidget(controller: controller),
            Positioned(
              left: 12,
              right: 12,
              bottom: 12,
              child: _HtmlPreviewControls(
                zoomPercent: _htmlZoomPercent,
                onZoomOut: () => _setHtmlZoom(_htmlZoomPercent - 10),
                onReset: () => _setHtmlZoom(100),
                onZoomIn: () => _setHtmlZoom(_htmlZoomPercent + 10),
              ),
            ),
          ],
        );
      case _FilePreviewKind.code:
        return Container(
          color:
              githubTheme['root']?.backgroundColor ?? theme.colorScheme.surface,
          child: Scrollbar(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SingleChildScrollView(
                child: HighlightView(
                  _displayContent,
                  language: _languageForExtension(widget.entry.extension),
                  theme: githubTheme,
                  padding: const EdgeInsets.all(16),
                  textStyle: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 13,
                    height: 1.35,
                  ),
                ),
              ),
            ),
          ),
        );
      case _FilePreviewKind.text:
      case _FilePreviewKind.image:
      case _FilePreviewKind.pdf:
        return SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: SelectableText(
            _displayContent,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 13,
              height: 1.35,
            ),
          ),
        );
    }
  }

  String get _displayContent {
    if (!widget.truncated) return widget.content;
    return '${widget.content}\n\n[Preview truncated]';
  }

  String get _htmlPreviewDocument {
    final style =
        '''
<style>
  html {
    overflow: scroll;
    scrollbar-gutter: stable both-edges;
  }
  body {
    min-height: 100vh;
    overflow: visible;
    zoom: $_htmlZoomPercent%;
  }
  ::-webkit-scrollbar {
    width: 12px;
    height: 12px;
  }
  ::-webkit-scrollbar-track {
    background: rgba(128, 128, 128, 0.12);
  }
  ::-webkit-scrollbar-thumb {
    background: rgba(128, 128, 128, 0.55);
    border-radius: 6px;
  }
</style>
''';
    final content = widget.content;
    final headClose = RegExp('</head>', caseSensitive: false);
    if (headClose.hasMatch(content)) {
      return content.replaceFirst(headClose, '$style</head>');
    }
    return '''
<!doctype html>
<html>
<head>
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  $style
</head>
<body>
$content
</body>
</html>
''';
  }

  void _setHtmlZoom(int zoomPercent) {
    final next = zoomPercent.clamp(50, 220);
    if (next == _htmlZoomPercent) return;
    setState(() => _htmlZoomPercent = next);
    _webViewController?.loadHtmlString(_htmlPreviewDocument);
  }
}

class _HtmlPreviewControls extends StatelessWidget {
  final int zoomPercent;
  final VoidCallback onZoomOut;
  final VoidCallback onReset;
  final VoidCallback onZoomIn;

  const _HtmlPreviewControls({
    required this.zoomPercent,
    required this.onZoomOut,
    required this.onReset,
    required this.onZoomIn,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Material(
        elevation: 3,
        borderRadius: BorderRadius.circular(18),
        color: theme.colorScheme.surfaceContainerHigh.withAlpha(236),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: 'Zoom out',
                icon: const Icon(Icons.remove),
                onPressed: onZoomOut,
                visualDensity: VisualDensity.compact,
              ),
              TextButton(onPressed: onReset, child: Text('$zoomPercent%')),
              IconButton(
                tooltip: 'Zoom in',
                icon: const Icon(Icons.add),
                onPressed: onZoomIn,
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FilePdfPreviewScreen extends StatefulWidget {
  final FileManagerEntry entry;
  final Uint8List bytes;

  const _FilePdfPreviewScreen({required this.entry, required this.bytes});

  @override
  State<_FilePdfPreviewScreen> createState() => _FilePdfPreviewScreenState();
}

class _FilePdfPreviewScreenState extends State<_FilePdfPreviewScreen> {
  late final PdfControllerPinch _controller;
  int _page = 1;
  int? _pages;

  @override
  void initState() {
    super.initState();
    _controller = PdfControllerPinch(
      document: PdfDocument.openData(widget.bytes),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.entry.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(
              child: Text(
                _pages == null ? '$_page' : '$_page/$_pages',
                style: TextStyle(
                  fontSize: 13,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ],
      ),
      body: PdfViewPinch(
        controller: _controller,
        scrollDirection: Axis.vertical,
        minScale: 1,
        maxScale: 8,
        padding: 12,
        backgroundDecoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
        ),
        onPageChanged: (page) {
          if (mounted) setState(() => _page = page);
        },
        onDocumentLoaded: (document) {
          if (mounted) setState(() => _pages = document.pagesCount);
        },
        onDocumentError: (error) {
          if (!mounted) return;
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('PDF render failed: $error')));
        },
      ),
    );
  }
}

class _FileImagePreviewScreen extends StatelessWidget {
  final FileManagerEntry entry;
  final Uint8List bytes;

  const _FileImagePreviewScreen({required this.entry, required this.bytes});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(entry.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      backgroundColor: theme.colorScheme.surface,
      body: Center(
        child: InteractiveViewer(
          minScale: 0.25,
          maxScale: 5,
          child: Image.memory(
            bytes,
            fit: BoxFit.contain,
            errorBuilder: (context, error, stackTrace) => Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'Image preview failed: $error',
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String? _languageForExtension(String? extension) {
  switch (_normalizedExtension(extension)) {
    case 'bash':
    case 'sh':
    case 'zsh':
      return 'bash';
    case 'c':
    case 'h':
      return 'c';
    case 'cc':
    case 'cpp':
    case 'cxx':
    case 'hpp':
      return 'cpp';
    case 'cs':
      return 'cs';
    case 'css':
      return 'css';
    case 'dart':
      return 'dart';
    case 'go':
      return 'go';
    case 'gradle':
      return 'gradle';
    case 'graphql':
    case 'gql':
      return 'graphql';
    case 'html':
    case 'htm':
      return 'xml';
    case 'java':
      return 'java';
    case 'js':
    case 'jsx':
    case 'mjs':
    case 'cjs':
      return 'javascript';
    case 'json':
    case 'jsonc':
      return 'json';
    case 'kt':
    case 'kts':
      return 'kotlin';
    case 'lua':
      return 'lua';
    case 'md':
    case 'markdown':
      return 'markdown';
    case 'php':
      return 'php';
    case 'ps1':
      return 'powershell';
    case 'py':
      return 'python';
    case 'rb':
      return 'ruby';
    case 'rs':
      return 'rust';
    case 'sql':
      return 'sql';
    case 'swift':
      return 'swift';
    case 'toml':
      return 'ini';
    case 'ts':
    case 'tsx':
      return 'typescript';
    case 'xml':
    case 'svg':
      return 'xml';
    case 'yaml':
    case 'yml':
      return 'yaml';
    default:
      return null;
  }
}

String _normalizedExtension(String? extension) {
  final value = (extension ?? '').trim().toLowerCase();
  if (value.startsWith('.')) return value.substring(1);
  return value;
}

class _PathHeader extends StatelessWidget {
  final String path;

  const _PathHeader({required this.path});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: theme.colorScheme.surfaceContainerHighest,
      child: Row(
        children: [
          Icon(Icons.folder_open, size: 18, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              path.isEmpty ? '...' : path,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                fontFamily: 'monospace',
                color: theme.colorScheme.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RootChips extends StatelessWidget {
  final List<FileManagerRoot> roots;
  final String currentPath;
  final ValueChanged<String> onTap;

  const _RootChips({
    required this.roots,
    required this.currentPath,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        scrollDirection: Axis.horizontal,
        itemBuilder: (context, index) {
          final root = roots[index];
          final selected = currentPath == root.path;
          return ChoiceChip(
            selected: selected,
            label: Text(root.label),
            onSelected: (_) => onTap(root.path),
          );
        },
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemCount: roots.length,
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  const _SearchField({required this.controller, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        decoration: InputDecoration(
          isDense: true,
          prefixIcon: const Icon(Icons.search, size: 20),
          hintText: 'Search current folder',
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          suffixIcon: controller.text.isEmpty
              ? null
              : IconButton(
                  tooltip: 'Clear search',
                  icon: const Icon(Icons.clear, size: 18),
                  onPressed: () {
                    controller.clear();
                    onChanged('');
                  },
                ),
        ),
        style: TextStyle(fontSize: 14, color: theme.colorScheme.onSurface),
      ),
    );
  }
}

class _FileEntryTile extends StatelessWidget {
  final FileManagerEntry entry;
  final bool highlighted;
  final bool isDownloading;
  final double? downloadProgress;
  final VoidCallback? onOpen;
  final VoidCallback? onDownload;
  final VoidCallback onProtectExact;
  final VoidCallback? onProtectDirectory;
  final VoidCallback? onUnprotect;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  const _FileEntryTile({
    required this.entry,
    required this.onProtectExact,
    required this.onRename,
    required this.onDelete,
    this.highlighted = false,
    this.isDownloading = false,
    this.downloadProgress,
    this.onOpen,
    this.onDownload,
    this.onProtectDirectory,
    this.onUnprotect,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      tileColor: highlighted
          ? theme.colorScheme.primaryContainer.withAlpha(150)
          : null,
      leading: Icon(_iconFor(entry), color: _colorFor(entry, theme)),
      title: Row(
        children: [
          Expanded(
            child: Text(
              entry.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (entry.isProtected) ...[
            const SizedBox(width: 8),
            Tooltip(
              message: entry.protectedLabel ?? 'Protected from agents',
              child: Icon(
                Icons.shield_outlined,
                size: 16,
                color: theme.colorScheme.primary,
              ),
            ),
          ],
        ],
      ),
      subtitle: Text(
        isDownloading && downloadProgress != null
            ? 'Downloading... ${(downloadProgress!.clamp(0.0, 1.0) * 100).floor()}%'
            : _subtitle(entry),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: onOpen,
      trailing: PopupMenuButton<String>(
        onSelected: (value) {
          switch (value) {
            case 'protect_exact':
              onProtectExact();
              break;
            case 'download':
              onDownload?.call();
              break;
            case 'protect_directory':
              onProtectDirectory?.call();
              break;
            case 'unprotect':
              onUnprotect?.call();
              break;
            case 'rename':
              onRename();
              break;
            case 'delete':
              onDelete();
              break;
          }
        },
        itemBuilder: (_) => [
          if (!entry.isDirectory)
            const PopupMenuItem(value: 'download', child: Text('Download')),
          if (!entry.isProtected)
            const PopupMenuItem(
              value: 'protect_exact',
              child: Text('Protect exact path'),
            ),
          if (entry.isDirectory && !entry.isProtected)
            const PopupMenuItem(
              value: 'protect_directory',
              child: Text('Protect folder recursively'),
            ),
          if (entry.isProtected)
            const PopupMenuItem(
              value: 'unprotect',
              child: Text('Remove protection'),
            ),
          const PopupMenuDivider(),
          const PopupMenuItem(value: 'rename', child: Text('Rename')),
          PopupMenuItem(
            value: 'delete',
            child: Text(
              'Delete',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        ],
      ),
    );
  }

  IconData _iconFor(FileManagerEntry entry) {
    if (entry.kind == FileManagerEntryKind.directory) {
      return Icons.folder_outlined;
    }
    if (entry.kind == FileManagerEntryKind.symlink) {
      return Icons.link;
    }
    switch (entry.mediaKind) {
      case FileManagerMediaKind.image:
        return Icons.image_outlined;
      case FileManagerMediaKind.video:
        return Icons.movie_outlined;
      case FileManagerMediaKind.audio:
        return Icons.audio_file_outlined;
      case FileManagerMediaKind.archive:
        return Icons.folder_zip_outlined;
      case FileManagerMediaKind.code:
        return Icons.code;
      case FileManagerMediaKind.text:
        return Icons.description_outlined;
      case FileManagerMediaKind.other:
        return Icons.insert_drive_file_outlined;
    }
  }

  Color _colorFor(FileManagerEntry entry, ThemeData theme) {
    if (entry.kind == FileManagerEntryKind.directory) {
      return theme.colorScheme.primary;
    }
    if (entry.isProtected) return theme.colorScheme.primary;
    return theme.colorScheme.onSurfaceVariant;
  }

  String _subtitle(FileManagerEntry entry) {
    final pieces = <String>[];
    pieces.add(entry.kind.name);
    if (entry.size != null && !entry.isDirectory) {
      pieces.add(_formatBytes(entry.size!));
    }
    if (entry.modifiedAt != null) {
      pieces.add(_formatDate(entry.modifiedAt!));
    }
    return pieces.join(' · ');
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
    final mb = kb / 1024;
    if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
    return '${(mb / 1024).toStringAsFixed(1)} GB';
  }

  String _formatDate(DateTime dt) {
    final local = dt.toLocal();
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')} '
        '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }
}
