import 'package:flutter/material.dart';

/// Card for a turn the model's safeguards flagged. Styled like a police
/// notice: a static red and blue light bar over black, so a refusal never
/// reads as an ordinary status line.
class RefusalCard extends StatelessWidget {
  const RefusalCard({super.key, required this.message});

  final String message;

  static const _red = Color(0xFFFF3B30);
  static const _blue = Color(0xFF2F7BFF);

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: _blue.withAlpha(140)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 5,
            child: Row(
              children: [
                for (var i = 0; i < 10; i++)
                  Expanded(child: ColoredBox(color: i.isEven ? _red : _blue)),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.local_police, size: 20, color: _blue),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'REFUSAL',
                        style: TextStyle(
                          color: _red,
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.4,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        message,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
