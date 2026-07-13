import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';

/// Paints [image] through a 3D-LUT fragment [shader], with [atlas] bound as the
/// LUT sampler. Size this to the image's aspect ratio (e.g. via `AspectRatio`)
/// so the frame fills the rect without letterboxing.
class LutPainter extends CustomPainter {
  LutPainter({
    required this.image,
    required this.shader,
    required this.atlas,
    required this.lutSize,
  });

  final ui.Image image;
  final ui.FragmentShader shader;
  final ui.Image atlas;
  final double lutSize;

  @override
  void paint(Canvas canvas, Size size) {
    shader
      ..setFloat(0, size.width)
      ..setFloat(1, size.height)
      ..setFloat(2, lutSize)
      ..setImageSampler(0, image)
      ..setImageSampler(1, atlas);
    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(LutPainter old) =>
      old.image != image || old.atlas != atlas || old.lutSize != lutSize;
}
