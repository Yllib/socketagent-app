import 'package:flutter/material.dart';

/// Fullscreen pan and zoom for an image. Pinch zooms between fit and 8x.
/// Double tap zooms in around the tap point, or back to fit when zoomed.
/// Pass [controller] to reset the view from outside, for example a toolbar
/// button; the caller owns and disposes it.
class ZoomableImage extends StatefulWidget {
  const ZoomableImage({super.key, required this.child, this.controller});

  final Widget child;
  final TransformationController? controller;

  static const minScale = 1.0;
  static const maxScale = 8.0;
  static const doubleTapScale = 2.5;

  @override
  State<ZoomableImage> createState() => _ZoomableImageState();
}

class _ZoomableImageState extends State<ZoomableImage>
    with SingleTickerProviderStateMixin {
  TransformationController? _ownController;
  late final AnimationController _animation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
  )..addListener(_onAnimate);
  Animation<Matrix4>? _zoom;
  Offset _tapPosition = Offset.zero;

  TransformationController get _controller =>
      widget.controller ?? (_ownController ??= TransformationController());

  @override
  void dispose() {
    _animation.dispose();
    _ownController?.dispose();
    super.dispose();
  }

  void _onAnimate() {
    final zoom = _zoom;
    if (zoom != null) _controller.value = zoom.value;
  }

  void _toggleZoom() {
    final zoomed = _controller.value.getMaxScaleOnAxis() > 1.01;
    final Matrix4 target;
    if (zoomed) {
      target = Matrix4.identity();
    } else {
      const s = ZoomableImage.doubleTapScale;
      // Scale around the tap so the tapped pixel stays under the finger.
      target = Matrix4.diagonal3Values(s, s, 1)
        ..setTranslationRaw(
          -_tapPosition.dx * (s - 1),
          -_tapPosition.dy * (s - 1),
          0,
        );
    }
    _zoom = Matrix4Tween(
      begin: _controller.value,
      end: target,
    ).animate(CurvedAnimation(parent: _animation, curve: Curves.easeOut));
    _animation.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onDoubleTapDown: (details) => _tapPosition = details.localPosition,
      onDoubleTap: _toggleZoom,
      child: InteractiveViewer(
        transformationController: _controller,
        minScale: ZoomableImage.minScale,
        maxScale: ZoomableImage.maxScale,
        onInteractionStart: (_) => _animation.stop(),
        child: SizedBox.expand(child: Center(child: widget.child)),
      ),
    );
  }
}
