import 'dart:io';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:open_filex/open_filex.dart';
import 'package:provider/provider.dart';
import '../models/message.dart';
import '../services/chat_provider.dart';

class FileCard extends StatelessWidget {
  final ChatMessage message;

  const FileCard({super.key, required this.message});

  String get _filePath {
    return message.toolInput?['file_path'] as String? ?? 'Unknown file';
  }

  String get _displayName {
    return _filePath.split('/').last;
  }

  String _formatBytes(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '$bytes B';
  }

  IconData _fileIcon(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.pdf')) return Icons.picture_as_pdf;
    if (lower.endsWith('.zip') ||
        lower.endsWith('.tar') ||
        lower.endsWith('.gz')) {
      return Icons.folder_zip;
    }
    if (lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.gif') ||
        lower.endsWith('.webp')) {
      return Icons.image;
    }
    if (lower.endsWith('.mp3') ||
        lower.endsWith('.wav') ||
        lower.endsWith('.m4a') ||
        lower.endsWith('.ogg')) {
      return Icons.audio_file;
    }
    if (lower.endsWith('.mp4') ||
        lower.endsWith('.mkv') ||
        lower.endsWith('.mov') ||
        lower.endsWith('.avi')) {
      return Icons.video_file;
    }
    if (lower.endsWith('.apk')) return Icons.android;
    if (lower.endsWith('.txt') ||
        lower.endsWith('.md') ||
        lower.endsWith('.log')) {
      return Icons.text_snippet;
    }
    if (lower.endsWith('.csv') ||
        lower.endsWith('.xlsx') ||
        lower.endsWith('.xls')) {
      return Icons.table_chart;
    }
    return Icons.insert_drive_file;
  }

  @override
  Widget build(BuildContext context) {
    final name = _displayName;
    final provider = context.watch<ChatProvider>();
    final embeddedFileId = message.toolInput?['_file_id'] as String?;
    final fileId = embeddedFileId != null && embeddedFileId.isNotEmpty
        ? embeddedFileId
        : provider.getFileId(_filePath);
    final localPath = fileId != null
        ? provider.getReceivedFilePath(fileId)
        : null;
    final fileExists = localPath != null ? File(localPath).existsSync() : false;
    final hasFile = localPath != null && fileExists;
    final isDownloading = fileId != null && provider.isDownloading(fileId);
    final hasServerFile =
        fileId != null && provider.getServerFilePath(fileId) != null;
    final serverFileSize = fileId != null
        ? provider.getServerFileSize(fileId)
        : null;
    final progress = fileId != null
        ? provider.getDownloadProgress(fileId)
        : null;
    final error = fileId != null ? provider.getDownloadError(fileId) : null;

    final toolOutput = message.toolOutput?.trim() ?? '';
    String subtitle;
    if (hasFile) {
      final savedName = localPath.split('/').last;
      subtitle = 'Saved to Downloads/$savedName';
    } else if (error != null && error.isNotEmpty) {
      subtitle = error;
    } else if (isDownloading && progress != null) {
      subtitle = 'Downloading... ${(progress * 100).toInt()}%';
    } else if (isDownloading) {
      subtitle = 'Downloading...';
    } else if (hasServerFile) {
      subtitle = serverFileSize != null
          ? 'Ready to download - ${_formatBytes(serverFileSize)}'
          : 'Ready to download';
    } else if (toolOutput.isNotEmpty) {
      subtitle = toolOutput;
    } else {
      subtitle = _filePath;
    }

    return GestureDetector(
      onLongPressStart: hasFile && fileId != null
          ? (details) {
              showMenu<String>(
                context: context,
                position: RelativeRect.fromLTRB(
                  details.globalPosition.dx,
                  details.globalPosition.dy,
                  details.globalPosition.dx,
                  details.globalPosition.dy,
                ),
                color: const Color(0xFF313244),
                items: [
                  const PopupMenuItem(
                    value: 'redownload',
                    child: Text(
                      'Re-download',
                      style: TextStyle(color: Color(0xFFCDD6F4)),
                    ),
                  ),
                ],
              ).then((value) {
                if (value == 'redownload') {
                  provider.clearReceivedFile(fileId);
                  provider.requestFile(fileId);
                }
              });
            }
          : null,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: const Color(0xFF1E1E2E),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFF45475A), width: 1),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Icon(_fileIcon(name), size: 24, color: const Color(0xFF89B4FA)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: GoogleFonts.jetBrainsMono(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: const Color(0xFFCDD6F4),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: GoogleFonts.jetBrainsMono(
                        fontSize: 10,
                        color: const Color(0xFF6C7086),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              if (hasFile) ...[
                const SizedBox(width: 4),
                IconButton(
                  icon: const Icon(
                    Icons.open_in_new,
                    size: 20,
                    color: Color(0xFFA6E3A1),
                  ),
                  onPressed: () => OpenFilex.open(localPath),
                  tooltip: 'Open',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 36,
                    minHeight: 36,
                  ),
                ),
              ] else if (isDownloading)
                SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: const Color(0xFFF9E2AF),
                    value: progress,
                  ),
                )
              else if (hasServerFile)
                IconButton(
                  icon: Icon(
                    error == null ? Icons.download : Icons.refresh,
                    size: 20,
                    color: const Color(0xFF89B4FA),
                  ),
                  onPressed: () => provider.requestFile(fileId),
                  tooltip: error == null ? 'Download' : 'Retry download',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 36,
                    minHeight: 36,
                  ),
                )
              else
                const Icon(
                  Icons.insert_drive_file,
                  size: 20,
                  color: Color(0xFF585B70),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
