import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../services/desktop_qr_import.dart';

class DesktopQrImportButton extends StatelessWidget {
  const DesktopQrImportButton({super.key, required this.onDecoded});
  final Future<void> Function(String) onDecoded;

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
    icon: const Icon(Icons.image_outlined),
    label: const Text('Open QR image'),
    onPressed: () async {
      try {
        final result = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['png', 'jpg', 'jpeg']);
        final path = result?.files.single.path;
        if (path == null) return;
        final file = File(path);
        if (await file.length() > 20 * 1024 * 1024) throw const FormatException('Choose a QR image smaller than 20 MB.');
        final text = await compute(decodeDesktopQr, await file.readAsBytes());
        if (context.mounted) await onDecoded(text);
      } catch (error) {
        if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error is FormatException ? error.message : 'Could not import that QR image.')));
      }
    },
  );
}
