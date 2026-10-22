import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// The one owner of the chat viewport's scroll offset.
///
/// Two modes:
///
/// * FOLLOW ([following] is true). Every layout pass pins the viewport to the
///   end of the transcript before it paints, so streaming text, new rows and
///   late image loads never leave the latest content out of view.
/// * HOLD. The row under the top edge of the viewport keeps its scroll-space
///   offset across layout passes. Older pages landing above, the "load
///   earlier" header appearing or disappearing, and rows above the viewport
///   changing height all leave the reader looking at the same row.
///
/// Transitions:
///
/// * Any movement away from the end that this controller did not make itself
///   (drag, fling, mouse wheel, scrollbar thumb, jumpTo, animateTo) switches
///   to HOLD at once, so no later layout fights the reader.
/// * A scroll that ends within [followSnapDistance] of the end switches back
///   to FOLLOW. [follow] does the same on request.
///
/// [revealAfterLayout] wins over both modes for a single layout pass.
///
/// Corrections happen inside the viewport's layout, through
/// [ScrollPosition.correctPixels], so the viewport never paints a frame at a
/// stale offset and then jumps.
class ChatScrollController extends ScrollController {
  ChatScrollController({bool following = true})
    : _following = ValueNotifier(following),
      super(keepScrollOffset: false);

  /// A scroll that stops this close to the end turns FOLLOW back on.
  static const double followSnapDistance = 12;

  /// Movement this far from the end turns FOLLOW off.
  static const double _leaveEndDistance = 1;

  final ValueNotifier<bool> _following;
  _Anchor? _anchor;
  ({RenderBox row, double inset, double? top})? _pendingReveal;
  bool _followJumpScheduled = false;

  ValueListenable<bool> get followingListenable => _following;

  bool get following => _following.value;

  /// Switches to FOLLOW. The next layout pins the viewport to the end; if no
  /// layout is pending, a post-frame jump gets there instead.
  void follow() {
    _following.value = true;
    _pendingReveal = null;
    if (_followJumpScheduled) return;
    _followJumpScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _followJumpScheduled = false;
      if (!following || !hasClients) return;
      final position = this.position;
      if (!position.hasContentDimensions) return;
      if ((position.pixels - position.maxScrollExtent).abs() >= 0.5) {
        position.jumpTo(position.maxScrollExtent);
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  /// Switches to HOLD without moving.
  void hold() => _following.value = false;

  /// During the next layout pass, moves the viewport so [row]'s top edge sits
  /// [inset] pixels below the viewport's top edge. The offset is corrected in
  /// the same pass that lays [row] out, so the reader never sees the stale
  /// frame in between.
  void revealAfterLayout(RenderBox row, {double inset = 0}) {
    // Captured now: a row that shrinks out of the cache region is not laid
    // out again until the viewport reaches it, and rows above it keep their
    // offsets, so this is where its top will be.
    final viewport = RenderAbstractViewport.maybeOf(row);
    _pendingReveal = (
      row: row,
      inset: inset,
      top: viewport?.getOffsetToReveal(row, 0).offset,
    );
  }

  /// Forward every [ScrollNotification] from the chat scroll view here.
  bool handleScrollNotification(ScrollNotification notification) {
    // Nested tool output scrolls independently of the transcript.
    if (notification.depth != 0) return false;
    if (notification is ScrollEndNotification &&
        notification.metrics.extentAfter <= followSnapDistance) {
      _following.value = true;
    }
    return false;
  }

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) {
    _anchor = null;
    _pendingReveal = null;
    return _ChatScrollPosition(
      this,
      physics: physics,
      context: context,
      oldPosition: oldPosition,
      debugLabel: debugLabel,
    );
  }

  @override
  void dispose() {
    _following.dispose();
    super.dispose();
  }

  /// Runs inside the viewport's layout, after its slivers are laid out.
  /// Returns true when the offset was corrected and the viewport must lay
  /// out once more at the corrected offset.
  ///
  /// Only layout offsets are read here. A render object may not read its
  /// grandchildren's sizes while it lays out, and a row's extent follows from
  /// the next row's offset anyway.
  bool _correctAfterLayout(
    _ChatScrollPosition position,
    RenderViewport? viewport,
    double minScrollExtent,
    double maxScrollExtent,
  ) {
    final rows = viewport == null
        ? const <_LaidOutRow>[]
        : _laidOutRows(viewport);
    double? target;
    final reveal = _pendingReveal;
    if (reveal != null) {
      _pendingReveal = null;
      final box = _sliverChildOf(reveal.row);
      final row = rows.where((row) => row.box == box).firstOrNull;
      final top = row?.top ?? reveal.top;
      if (top != null) target = top + reveal.inset;
    } else if (following) {
      target = maxScrollExtent;
    } else {
      final anchor = _anchor;
      final row = anchor == null
          ? null
          : rows.where((row) => row.box == anchor.row).firstOrNull;
      if (row != null) {
        final delta = row.edge - anchor!.offset;
        if (delta.abs() >= 0.5) target = position.pixels + delta;
      }
    }
    final clamped = (target ?? position.pixels)
        .clamp(minScrollExtent, maxScrollExtent)
        .toDouble();
    final corrected = (position.pixels - clamped).abs() >= 0.5;
    if (corrected) position.correctPixels(clamped);
    _anchor = _captureAnchor(rows, position.pixels);
    return corrected;
  }

  /// A move the controller did not make. Leaving the end hands the viewport
  /// to whoever moved it.
  void _pixelsMoved(ScrollPosition position) {
    if (!following || !position.hasContentDimensions) return;
    if (position.maxScrollExtent - position.pixels > _leaveEndDistance) {
      _following.value = false;
    }
  }

  /// The viewport's own corrections move the slivers' content and the offset
  /// by the same amount, so the anchor moves with them.
  void _contentShifted(double correction) {
    _anchor?.offset += correction;
  }

  /// The first row whose near edge is at or below the viewport's top edge,
  /// or failing that the last row above it. Holding that edge keeps the
  /// reader's rows still whatever changes around them.
  static _Anchor? _captureAnchor(List<_LaidOutRow> rows, double pixels) {
    _LaidOutRow? below;
    _LaidOutRow? above;
    for (final row in rows) {
      if (row.edge >= pixels) {
        if (below == null || row.edge < below.edge) below = row;
      } else if (above == null || row.edge > above.edge) {
        above = row;
      }
    }
    final chosen = below ?? above;
    return chosen == null ? null : _Anchor(chosen.box, chosen.edge);
  }

  /// Every row laid out in this pass, with its scroll-space position.
  static List<_LaidOutRow> _laidOutRows(RenderViewport viewport) {
    final rows = <_LaidOutRow>[];
    var sliver = viewport.firstChild;
    while (sliver != null) {
      RenderSliver? inner = sliver;
      while (inner is RenderSliverEdgeInsetsPadding) {
        inner = inner.child;
      }
      if (inner is RenderSliverMultiBoxAdaptor && inner.geometry != null) {
        final preceding = inner.constraints.precedingScrollExtent;
        final reverse =
            inner.constraints.growthDirection == GrowthDirection.reverse;
        var row = inner.firstChild;
        while (row != null) {
          final next = inner.childAfter(row);
          final offset = inner.childScrollOffset(row);
          if (offset != null) {
            // Rows are laid out back to back, so the next row's offset is
            // this row's end. The last laid-out row ends where the sliver's
            // own extent says it does.
            final nextOffset = next == null
                ? null
                : inner.childScrollOffset(next);
            final extent =
                (nextOffset ?? inner.geometry!.scrollExtent) - offset;
            // In a reverse sliver the near edge is the row's bottom and the
            // scroll-space coordinate runs the other way.
            final edge = reverse ? -(preceding + offset) : preceding + offset;
            rows.add(
              _LaidOutRow(
                box: row,
                edge: edge,
                top: reverse ? edge - extent : edge,
              ),
            );
          }
          row = next;
        }
      }
      sliver = viewport.childAfter(sliver);
    }
    return rows;
  }

  /// Total extent of the center sliver and everything after it.
  static double _forwardExtent(RenderViewport viewport) {
    var extent = 0.0;
    for (
      var sliver = viewport.center ?? viewport.firstChild;
      sliver != null;
      sliver = viewport.childAfter(sliver)
    ) {
      extent += sliver.geometry?.scrollExtent ?? 0;
    }
    return extent;
  }

  /// The sliver's own child that contains [box]. The list wraps each row in
  /// a repaint boundary, so a row's render box is a descendant of it.
  static RenderBox? _sliverChildOf(RenderBox box) {
    RenderObject? node = box;
    while (node != null && node.parent is! RenderSliverMultiBoxAdaptor) {
      node = node.parent;
    }
    return node is RenderBox ? node : null;
  }

  static RenderViewport? _viewportOf(ScrollPosition position) {
    RenderObject? node = position.context.notificationContext
        ?.findRenderObject();
    while (node != null && node is! RenderViewport) {
      node = node is RenderObjectWithChildMixin ? node.child : null;
    }
    return node as RenderViewport?;
  }
}

/// A row placed by the layout pass that just finished. [edge] is the scroll
/// offset of the edge nearest the center sliver; [top] is the offset at which
/// the row's top meets the viewport's top.
class _LaidOutRow {
  const _LaidOutRow({required this.box, required this.edge, required this.top});

  final RenderBox box;
  final double edge;
  final double top;
}

class _Anchor {
  _Anchor(this.row, this.offset);

  final RenderBox row;
  double offset;
}

class _ChatScrollPosition extends ScrollPositionWithSingleContext {
  _ChatScrollPosition(
    this.owner, {
    required super.physics,
    required super.context,
    super.oldPosition,
    super.debugLabel,
  }) : super(keepScrollOffset: false);

  final ChatScrollController owner;

  @override
  bool applyContentDimensions(double minScrollExtent, double maxScrollExtent) {
    final viewport = ChatScrollController._viewportOf(this);
    if (viewport != null) {
      // The viewport never reports an end above its own zero, so when the
      // rows from the center onward are shorter than the viewport it would
      // leave the older rows out of view above them and blank space below.
      // The end is where the last row meets the bottom of the viewport, as
      // long as there is content above to fill it.
      maxScrollExtent = math.max(
        minScrollExtent,
        math.min(
          maxScrollExtent,
          ChatScrollController._forwardExtent(viewport) - viewportDimension,
        ),
      );
    }
    // Correct before the dimensions land. Applying them while the offset is
    // out of range starts a settling animation, and its end would read as a
    // scroll that stopped at the end and switch to FOLLOW on its own.
    final corrected =
        hasPixels &&
        owner._correctAfterLayout(
          this,
          viewport,
          minScrollExtent,
          maxScrollExtent,
        );
    final accepted = super.applyContentDimensions(
      minScrollExtent,
      maxScrollExtent,
    );
    // The sliver pass that produced these dimensions used the old offset.
    // Returning false makes the viewport lay out once more before paint, so
    // the rows at the corrected offset exist when it paints.
    return corrected ? false : accepted;
  }

  @override
  void correctBy(double correction) {
    super.correctBy(correction);
    owner._contentShifted(correction);
  }

  @override
  double setPixels(double newPixels) {
    final overscroll = super.setPixels(newPixels);
    owner._pixelsMoved(this);
    return overscroll;
  }

  @override
  void forcePixels(double value) {
    super.forcePixels(value);
    owner._pixelsMoved(this);
  }
}
