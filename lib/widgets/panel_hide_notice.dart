import 'package:flutter/material.dart';
import '../config/app_palette.dart';

class PanelHideNotice extends StatelessWidget {
  const PanelHideNotice({
    super.key,
    required this.label,
    required this.onCancel,
  });
  final String label;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
      decoration: BoxDecoration(
        color: context.palette.panel,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: context.palette.border),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Hiding $label…',
                  style: TextStyle(
                    fontSize: 11,
                    height: 1.2,
                    fontWeight: FontWeight.w600,
                    color: context.palette.text,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Restore: More → Session settings',
                  style: TextStyle(
                    fontSize: 10,
                    height: 1.2,
                    color: context.palette.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 4),
          SizedBox(
            width: 64,
            child: TextButton(
              onPressed: onCancel,
              style: TextButton.styleFrom(
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                minimumSize: const Size(0, 24),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                textStyle: const TextStyle(fontSize: 11),
              ),
              child: const FittedBox(
                fit: BoxFit.scaleDown,
                child: Text('Cancel'),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
