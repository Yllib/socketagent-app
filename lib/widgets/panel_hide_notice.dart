import 'package:flutter/material.dart';

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
        color: const Color(0xFF181818),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF2E2E2E)),
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
                  style: const TextStyle(
                    fontSize: 11,
                    height: 1.2,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFFE6E6E6),
                  ),
                ),
                const SizedBox(height: 2),
                const Text(
                  'Restore: More → Session settings',
                  style: TextStyle(
                    fontSize: 10,
                    height: 1.2,
                    color: Color(0xFFB0B0B0),
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
