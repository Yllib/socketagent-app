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
/// [viewportRows] reports where the viewport sits in rows rather than pixels.
/// Rows are laid out lazily and vary a lot in height, so pixel extents are
/// estimates that swing as rows build; row positions do not. [scrollToRow]
/// goes the other way, for the scrollbar thumb.
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
  final ValueNotifier<ChatViewportRows?> _viewportRows = ValueNotifier(null);
  _Anchor? _anchor;
  ({RenderBox row, double inset, double? top})? _pendingReveal;
  bool _followJumpScheduled = false;

  /// Row counts of the list slivers, in sliver order, set by the view on
  /// each build. Needed to number the rows of an upward-growing sliver,
  /// which holds them newest first, and to know which laid-out row is the
  /// last one.
  List<int> sliverRowCounts = const [];

  /// Rows placed by the last layout pass, for [scrollToRow].
  List<_LaidOutRow> _lastRows = const [];
  double? _rowTarget;
  bool _rowTargetRetryScheduled = false;

  /// Running mean of every row height measured so far. Each row counts once
  /// and updates in place if it changes height. The entries die with their
  /// render boxes.
  final Expando<double> _measuredExtent = Expando();
  double _measuredExtentSum = 0;
  int _measuredExtentCount = 0;

  ValueListenable<bool> get followingListenable => _following;

  bool get following => _following.value;

  /// Where the viewport sits in the loaded rows, updated by every layout.
  ValueListenable<ChatViewportRows?> get viewportRows => _viewportRows;

  double get _meanExtent =>
      _measuredExtentCount == 0 ? 0 : _measuredExtentSum / _measuredExtentCount;

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

  /// Puts [row] (a fractional index into the loaded rows) at the top of the
  /// viewport. A row that is not laid out yet is reached by estimate from
  /// the nearest row that is, then refined after each layout until it is
  /// exact or [endRowScroll] is called. Each step is a jump, so it leaves
  /// FOLLOW like any other move and resumes it on landing at the end.
  void scrollToRow(double row) {
    _rowTarget = row;
    _stepTowardRowTarget();
  }

  void endRowScroll() => _rowTarget = null;

  void _stepTowardRowTarget() {
    final target = _rowTarget;
    if (target == null || !hasClients) return;
    final position = this.position;
    if (!position.hasContentDimensions) return;
    final rows = _lastRows;
    if (rows.isEmpty) return;
    final index = target.floor();
    _LaidOutRow? exact;
    _LaidOutRow? nearest;
    for (final row in rows) {
      if (row.index == index) exact = row;
      if (nearest == null ||
          (row.index - target).abs() < (nearest.index - target).abs()) {
        nearest = row;
      }
    }
    final double pixels;
    if (target <= 0) {
      // The very top, header and all.
      pixels = position.minScrollExtent;
    } else if (exact != null) {
      pixels = exact.top + (target - index) * exact.extent;
    } else {
      pixels = nearest!.top + (target - nearest.index) * _meanExtent;
    }
    final clamped = pixels
        .clamp(position.minScrollExtent, position.maxScrollExtent)
        .toDouble();
    if ((position.pixels - clamped).abs() >= 0.5) position.jumpTo(clamped);
    if (target <= 0 || exact != null || _rowTargetRetryScheduled) return;
    _rowTargetRetryScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _rowTargetRetryScheduled = false;
      _stepTowardRowTarget();
    });
  }

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
    _lastRows = const [];
    _rowTarget = null;
    _measuredExtentSum = 0;
    _measuredExtentCount = 0;
    _viewportRows.value = null;
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
    _viewportRows.dispose();
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
    _lastRows = rows;
    _viewportRows.value = _locateViewport(
      rows,
      position.pixels,
      position.viewportDimension,
      sliverRowCounts.fold(0, (sum, count) => sum + count),
    );
    return corrected;
  }

  /// The viewport's top edge and height in row units. The top is the index
  /// of the row under it plus how far into that row it is; the height is
  /// the viewport over the mean row height, so it does not change with the
  /// rows that happen to be on screen.
  ChatViewportRows? _locateViewport(
    List<_LaidOutRow> rows,
    double pixels,
    double viewportDimension,
    int count,
  ) {
    if (rows.isEmpty || count == 0) return null;
    final mean = _meanExtent;
    _LaidOutRow? under;
    for (final row in rows) {
      if (row.top + row.extent <= pixels) continue;
      if (under == null || row.index < under.index) under = row;
    }
    final top = under == null
        ? count.toDouble()
        : under.index + ((pixels - under.top) / under.extent).clamp(0.0, 1.0);
    return (
      top: top,
      height: mean > 0 ? viewportDimension / mean : count.toDouble(),
      count: count,
    );
  }

  static RenderSliverMultiBoxAdaptor? _multiBoxOf(RenderSliver sliver) {
    RenderSliver? inner = sliver;
    while (inner is RenderSliverEdgeInsetsPadding) {
      inner = inner.child;
    }
    return inner is RenderSliverMultiBoxAdaptor ? inner : null;
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

  /// Every row laid out in this pass, with its scroll-space position and its
  /// index in the loaded rows. Slivers are numbered in order; a sliver that
  /// grows upward holds its rows newest first.
  List<_LaidOutRow> _laidOutRows(RenderViewport viewport) {
    final rows = <_LaidOutRow>[];
    var base = 0;
    var sliverNumber = 0;
    for (
      var sliver = viewport.firstChild;
      sliver != null;
      sliver = viewport.childAfter(sliver)
    ) {
      final inner = _multiBoxOf(sliver);
      if (inner == null) continue;
      // Without a count the sliver is numbered as it is laid out, which is
      // right for a forward sliver and all the plain list has.
      final count = sliverRowCounts.elementAtOrNull(sliverNumber++) ?? -1;
      if (inner.geometry != null) {
        final preceding = inner.constraints.precedingScrollExtent;
        final reverse =
            inner.constraints.growthDirection == GrowthDirection.reverse;
        var row = inner.firstChild;
        while (row != null) {
          final next = inner.childAfter(row);
          final offset = inner.childScrollOffset(row);
          if (offset != null) {
            final sliverIndex = inner.indexOf(row);
            // Rows are laid out back to back, so the next row's offset is
            // this row's end. Without a next row the sliver's own extent
            // says where the row ends, but only when it is the last row;
            // otherwise that extent is an estimate for rows not built yet
            // and the row's height is taken from the mean instead.
            final nextOffset = next == null
                ? null
                : inner.childScrollOffset(next);
            final measured = nextOffset != null
                ? nextOffset - offset
                : sliverIndex == count - 1
                ? inner.geometry!.scrollExtent - offset
                : null;
            if (measured != null) _recordExtent(row, measured);
            final extent = measured ?? _measuredExtent[row] ?? _meanExtent;
            // In a reverse sliver the near edge is the row's bottom and the
            // scroll-space coordinate runs the other way.
            final edge = reverse ? -(preceding + offset) : preceding + offset;
            rows.add(
              _LaidOutRow(
                box: row,
                index:
                    base +
                    (reverse && count >= 0
                        ? count - 1 - sliverIndex
                        : sliverIndex),
                edge: edge,
                top: reverse ? edge - extent : edge,
                extent: extent,
              ),
            );
          }
          row = next;
        }
      }
      if (count > 0) base += count;
    }
    return rows;
  }

  void _recordExtent(RenderBox row, double extent) {
    final previous = _measuredExtent[row];
    if (previous == null) {
      _measuredExtentCount++;
      _measuredExtentSum += extent;
    } else {
      _measuredExtentSum += extent - previous;
    }
    _measuredExtent[row] = extent;
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

/// The viewport's place in the loaded rows: [top] is a fractional index into
/// them, [height] is the viewport in rows, [count] is how many are loaded.
typedef ChatViewportRows = ({double top, double height, int count});

/// A row placed by the layout pass that just finished. [edge] is the scroll
/// offset of the edge nearest the center sliver; [top] is the offset at which
/// the row's top meets the viewport's top; [extent] is measured, or the mean
/// row height when the row's end is not known yet.
class _LaidOutRow {
  const _LaidOutRow({
    required this.box,
    required this.index,
    required this.edge,
    required this.top,
    required this.extent,
  });

  final RenderBox box;
  final int index;
  final double edge;
  final double top;
  final double extent;
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
