import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'chat_scroll_controller.dart';

/// The chat's one scrollbar. Lays over the transcript at its right edge.
///
/// The thumb is placed by row, not by pixel: its top is the row under the
/// viewport's top edge over every row of the conversation, loaded or not,
/// and its length is the viewport in mean row heights. Neither depends on
/// which rows have been laid out, so the thumb does not jump or change size
/// as rows build while scrolling, and it covers the whole conversation.
///
/// Dragging the thumb reports the row under its top through [onSeekRow] as
/// an index over the whole conversation; the view loads older history when
/// that row is not loaded yet. The thumb is a render object of its own, so
/// it repaints from the controller's layout-time metrics without a rebuild.
class ChatScrollbar extends LeafRenderObjectWidget {
  const ChatScrollbar({
    super.key,
    required this.controller,
    required this.olderRowCount,
    required this.color,
    required this.onSeekRow,
    required this.onSeekEnd,
  });

  final ChatScrollController controller;

  /// Rows of history before the oldest loaded one.
  final int olderRowCount;
  final Color color;
  final ValueChanged<double> onSeekRow;
  final VoidCallback onSeekEnd;

  static const double thickness = 3;
  static const double minThumbLength = 56;
  static const double margin = 4;

  /// Width of the strip over the thumb that takes a drag.
  static const double hitWidth = 24;

  @override
  RenderChatScrollbar createRenderObject(BuildContext context) {
    return RenderChatScrollbar(
      viewportRows: controller.viewportRows,
      olderRowCount: olderRowCount,
      color: color,
      onSeekRow: onSeekRow,
      onSeekEnd: onSeekEnd,
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    RenderChatScrollbar renderObject,
  ) {
    renderObject
      ..viewportRows = controller.viewportRows
      ..olderRowCount = olderRowCount
      ..color = color
      ..onSeekRow = onSeekRow
      ..onSeekEnd = onSeekEnd;
  }
}

class RenderChatScrollbar extends RenderBox {
  RenderChatScrollbar({
    required ValueListenable<ChatViewportRows?> viewportRows,
    required int olderRowCount,
    required Color color,
    required this.onSeekRow,
    required this.onSeekEnd,
  }) : _viewportRows = viewportRows,
       _olderRowCount = olderRowCount,
       _color = color;

  ValueChanged<double> onSeekRow;
  VoidCallback onSeekEnd;

  ValueListenable<ChatViewportRows?> _viewportRows;
  set viewportRows(ValueListenable<ChatViewportRows?> value) {
    if (identical(value, _viewportRows)) return;
    if (attached) _viewportRows.removeListener(markNeedsPaint);
    _viewportRows = value;
    if (attached) _viewportRows.addListener(markNeedsPaint);
    markNeedsPaint();
  }

  int _olderRowCount;
  set olderRowCount(int value) {
    if (value == _olderRowCount) return;
    _olderRowCount = value;
    markNeedsPaint();
  }

  Color _color;
  set color(Color value) {
    if (value == _color) return;
    _color = value;
    markNeedsPaint();
  }

  double? _dragStartY;
  double? _dragStartFraction;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _viewportRows.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _viewportRows.removeListener(markNeedsPaint);
    super.detach();
  }

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  /// The thumb's place on the track, or null when everything fits.
  ({Rect rect, double fraction, double movableRows})? get thumb {
    final rows = _viewportRows.value;
    final track = size.height - 2 * ChatScrollbar.margin;
    if (rows == null || track <= 0) return null;
    final total = _olderRowCount + rows.count;
    if (total <= 0 || rows.height >= total) return null;
    final length = (track * rows.height / total)
        .clamp(ChatScrollbar.minThumbLength, track)
        .toDouble();
    // The thumb's top travels over every row but the last viewport's worth.
    final movableRows = total - rows.height;
    final fraction = ((_olderRowCount + rows.top) / movableRows)
        .clamp(0.0, 1.0)
        .toDouble();
    final top = ChatScrollbar.margin + fraction * (track - length);
    return (
      rect: Rect.fromLTWH(
        size.width - ChatScrollbar.thickness,
        top,
        ChatScrollbar.thickness,
        length,
      ),
      fraction: fraction,
      movableRows: movableRows,
    );
  }

  @override
  bool hitTestSelf(Offset position) {
    final thumb = this.thumb;
    if (thumb == null) return false;
    return Rect.fromLTRB(
      size.width - ChatScrollbar.hitWidth,
      thumb.rect.top - ChatScrollbar.margin,
      size.width,
      thumb.rect.bottom + ChatScrollbar.margin,
    ).contains(position);
  }

  @override
  void handleEvent(PointerEvent event, BoxHitTestEntry entry) {
    final thumb = this.thumb;
    if (event is PointerDownEvent) {
      if (thumb == null) return;
      _dragStartY = event.position.dy;
      _dragStartFraction = thumb.fraction;
    } else if (event is PointerMoveEvent) {
      final startY = _dragStartY;
      final startFraction = _dragStartFraction;
      if (thumb == null || startY == null || startFraction == null) return;
      final movable =
          size.height - 2 * ChatScrollbar.margin - thumb.rect.height;
      if (movable <= 0) return;
      final fraction = (startFraction + (event.position.dy - startY) / movable)
          .clamp(0.0, 1.0);
      onSeekRow(fraction * thumb.movableRows);
    } else if (event is PointerUpEvent || event is PointerCancelEvent) {
      if (_dragStartY == null) return;
      _dragStartY = null;
      _dragStartFraction = null;
      onSeekEnd();
    }
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final thumb = this.thumb;
    if (thumb == null) return;
    context.canvas.drawRRect(
      RRect.fromRectAndRadius(
        thumb.rect.shift(offset),
        const Radius.circular(2),
      ),
      Paint()..color = _color,
    );
  }
}
