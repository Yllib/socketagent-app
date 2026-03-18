import 'dart:math';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../models/message.dart';
import 'scroll_passthrough.dart';

class ThinkingCard extends StatefulWidget {
  final ChatMessage message;

  const ThinkingCard({super.key, required this.message});

  @override
  State<ThinkingCard> createState() => _ThinkingCardState();
}

class _ThinkingCardState extends State<ThinkingCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final text = widget.message.textContent;
    final isStreaming = widget.message.toolStreaming;
    final preview = text.length > 60 ? '${text.substring(0, 60)}...' : text;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: CustomPaint(
        painter: _CloudBorderPainter(
          fillColor: const Color(0xFF1E1E2E),
          borderColor: isStreaming
              ? const Color(0xFFCBA6F7).withAlpha(120)
              : const Color(0xFF45475A),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header
              GestureDetector(
                onTap: () => setState(() => _expanded = !_expanded),
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.psychology,
                        size: 16,
                        color: Color(0xFFCBA6F7),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Thinking',
                        style: GoogleFonts.jetBrainsMono(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: const Color(0xFFCBA6F7),
                        ),
                      ),
                      const SizedBox(width: 8),
                      if (isStreaming)
                        const Padding(
                          padding: EdgeInsets.only(right: 8),
                          child: SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(
                              strokeWidth: 1.5,
                              color: Color(0xFFCBA6F7),
                            ),
                          ),
                        ),
                      Expanded(
                        child: Text(
                          preview,
                          style: GoogleFonts.jetBrainsMono(
                            fontSize: 11,
                            color: const Color(0xFFA6ADC8),
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Icon(
                        _expanded ? Icons.expand_less : Icons.expand_more,
                        size: 18,
                        color: const Color(0xFF6C7086),
                      ),
                    ],
                  ),
                ),
              ),
              // Expanded content
              if (_expanded)
                Container(
                  constraints: const BoxConstraints(maxHeight: 400),
                  decoration: const BoxDecoration(
                    border: Border(
                      top: BorderSide(color: Color(0xFF313244), width: 1),
                    ),
                  ),
                  child: ScrollPassthrough(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(12),
                      child: SelectableText(
                        text,
                        style: GoogleFonts.jetBrainsMono(
                          fontSize: 12,
                          color: const Color(0xFFCDD6F4),
                          height: 1.5,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CloudBorderPainter extends CustomPainter {
  final Color fillColor;
  final Color borderColor;

  _CloudBorderPainter({required this.fillColor, required this.borderColor});

  @override
  void paint(Canvas canvas, Size size) {
    final fill = Paint()
      ..color = fillColor
      ..style = PaintingStyle.fill;
    final stroke = Paint()
      ..color = borderColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;

    final path = _buildCloudPath(size);
    canvas.drawPath(path, fill);
    canvas.drawPath(path, stroke);
  }

  Path _buildCloudPath(Size size) {
    final path = Path();
    final w = size.width;
    final h = size.height;
    // Bubble radius for the scallops
    const r = 12.0;

    // Start bottom-left, go right along bottom
    path.moveTo(r, h);
    // Bottom edge scallops
    double x = r;
    while (x < w - r) {
      final nextX = min(x + r * 2, w - r);
      final midX = (x + nextX) / 2;
      path.quadraticBezierTo(midX, h + r * 0.4, nextX, h);
      x = nextX;
    }
    // Right edge scallops (going up)
    double y = h;
    while (y > r) {
      final nextY = max(y - r * 2, 0.0);
      final midY = (y + nextY) / 2;
      path.quadraticBezierTo(w + r * 0.4, midY, w, nextY);
      y = nextY;
    }
    // Top edge scallops (going left)
    x = w;
    while (x > r) {
      final nextX = max(x - r * 2, r);
      final midX = (x + nextX) / 2;
      path.quadraticBezierTo(midX, -r * 0.4, nextX, 0);
      x = nextX;
    }
    // Left edge scallops (going down)
    y = 0;
    while (y < h - r) {
      final nextY = min(y + r * 2, h);
      final midY = (y + nextY) / 2;
      path.quadraticBezierTo(-r * 0.4, midY, 0, nextY);
      y = nextY;
    }
    path.close();
    return path;
  }

  @override
  bool shouldRepaint(covariant _CloudBorderPainter oldDelegate) =>
      oldDelegate.fillColor != fillColor || oldDelegate.borderColor != borderColor;
}

