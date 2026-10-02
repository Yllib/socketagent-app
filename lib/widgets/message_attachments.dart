import 'dart:io';

import 'package:flutter/material.dart';
import '../models/inline_chat_media.dart';
import '../models/message_attachment.dart';
import '../services/chat_image_loader.dart';
import '../services/socketagent_link_router.dart';
import 'inline_chat_images.dart';

class MessageAttachments extends StatelessWidget {
  const MessageAttachments({
    super.key,
    required this.attachments,
    required this.sourceServerId,
  });

  final List<MessageAttachment> attachments;
  final String? sourceServerId;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      for (final attachment in attachments)
        if (attachment.isImage)
          InlineChatImages(
            key: ValueKey((attachment.path, attachment.isLocal)),
            images: [
              ChatImageSource.upload(attachment.path, name: attachment.name),
            ],
            title: attachment.name,
            sourceServerId: sourceServerId,
            loadImage: attachment.isLocal
                ? (_, _) async {
                    final file = File(attachment.path);
                    if (await file.length() > ChatImageLoader.maxImageBytes) {
                      throw const FormatException('Image exceeds 20 MB.');
                    }
                    return file.readAsBytes();
                  }
                : null,
          )
        else
          Semantics(
            button: true,
            label: 'Open ${attachment.name}',
            child: InkWell(
              onTap: attachment.isLocal || sourceServerId == null
                  ? null
                  : () => SocketAgentLinkRouter.open(
                      context,
                      Uri(
                        scheme: 'socketagent',
                        host: 'file',
                        path: '/view',
                        queryParameters: {'path': attachment.path},
                      ).toString(),
                      sourceServerId: sourceServerId,
                    ),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.insert_drive_file_outlined, size: 28),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        attachment.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(
                      attachment.isLocal
                          ? Icons.upload_outlined
                          : Icons.open_in_new,
                      size: 18,
                    ),
                  ],
                ),
              ),
            ),
          ),
    ],
  );
}
