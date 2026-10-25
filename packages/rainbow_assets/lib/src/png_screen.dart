import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// PNG/image -> Spectrum screen conversion, adapted from the SCRN app.
///
/// Per 8x8 attribute block the two dominant colours become paper and ink;
/// every pixel is quantised to the nearer of the two. Both normal and
/// bright palettes are evaluated per block and the lower-error candidate
/// wins (biasable via [PngImportOptions.brightnessPreference]).
///
/// The result is 6912 bytes in Spectrum display order (bitmap: thirds,
/// char rows, pixel lines; then 32x24 attribute bytes), ready to embed as
/// a `.rbc` asset or write straight to 0x4000.

enum PngFitMode { letterbox, crop }

enum BrightnessPreference { neutral, preferBright, preferNormal }

enum ErrorMetric { squared, absolute }

class PngImportOptions {
  const PngImportOptions({
    this.fit = PngFitMode.letterbox,
    this.brightnessPreference = BrightnessPreference.neutral,
    this.contrast = 1.0,
    this.errorMetric = ErrorMetric.squared,
  });

  final PngFitMode fit;
  final BrightnessPreference brightnessPreference;
  final double contrast;
  final ErrorMetric errorMetric;

  static const defaults = PngImportOptions();
}

/// Spectrum palette (dim/bright), RGB.
const _normal = [
  [0, 0, 0],
  [0, 0, 215],
  [215, 0, 0],
  [215, 0, 215],
  [0, 215, 0],
  [0, 215, 215],
  [215, 215, 0],
  [215, 215, 215],
];
const _bright = [
  [0, 0, 0],
  [0, 0, 255],
  [255, 0, 0],
  [255, 0, 255],
  [0, 255, 0],
  [0, 255, 255],
  [255, 255, 0],
  [255, 255, 255],
];

List<int> _rgb(int index, bool bright) =>
    (bright ? _bright : _normal)[index.clamp(0, 7)];

/// Decode an image file and convert to `.rbs` frame rows sized [w]×[h]:
/// pixels at/above [alphaThreshold] become '#' (ink), the rest '.'
/// (transparent). The image is resized to the cell if its dimensions
/// differ. Throws [FormatException] if undecodable.
List<String> imageToSpriteRows(Uint8List imageBytes,
    {required int w, required int h, int alphaThreshold = 128}) {
  var source = img.decodeImage(imageBytes);
  if (source == null) {
    throw const FormatException('could not decode image');
  }
  if (source.width != w || source.height != h) {
    source = img.copyResize(source, width: w, height: h);
  }
  return [
    for (var y = 0; y < h; y++)
      [
        for (var x = 0; x < w; x++)
          source.getPixel(x, y).a >= alphaThreshold ? '#' : '.'
      ].join()
  ];
}

/// Decode an image file (PNG, GIF, JPEG...) and convert to 6912 bytes of
/// Spectrum screen data. Throws [FormatException] if undecodable.
Uint8List imageToScreen(Uint8List imageBytes,
    {PngImportOptions options = PngImportOptions.defaults}) {
  final source = img.decodeImage(imageBytes);
  if (source == null) {
    throw const FormatException('could not decode image');
  }
  return imageToScreenImage(source, options: options);
}

/// Convert an already-decoded [img.Image].
Uint8List imageToScreenImage(img.Image source,
    {PngImportOptions options = PngImportOptions.defaults}) {
  final normalized = _normalize(source, options.fit);
  final out = Uint8List(6912);

  for (var by = 0; by < 24; by++) {
    for (var bx = 0; bx < 32; bx++) {
      final normal = _evaluateBlock(normalized, bx, by, false, options);
      final bright = _evaluateBlock(normalized, bx, by, true, options);

      var normalScore = normal.error;
      var brightScore = bright.error;
      if (options.brightnessPreference == BrightnessPreference.preferBright) {
        brightScore *= 0.97;
      } else if (options.brightnessPreference ==
          BrightnessPreference.preferNormal) {
        brightScore *= 1.03;
      }
      final w = brightScore < normalScore ? bright : normal;

      // attribute byte: ink | paper<<3 | bright<<6 | flash<<7
      out[6144 + by * 32 + bx] =
          w.ink | (w.paper << 3) | (w.bright ? 0x40 : 0);

      for (var ly = 0; ly < 8; ly++) {
        var row = 0;
        for (var lx = 0; lx < 8; lx++) {
          if (w.bits[ly * 8 + lx] == 1) row |= 0x80 >> lx;
        }
        final y = by * 8 + ly;
        out[(y ~/ 64) * 2048 + (y % 8) * 256 + ((y ~/ 8) % 8) * 32 + bx] =
            row;
      }
    }
  }
  return out;
}

/// Scale/fit [source] onto a 256x192 black canvas.
img.Image _normalize(img.Image source, PngFitMode mode) {
  final canvas = img.Image(
      width: 256, height: 192, numChannels: 4);
  canvas.clear(img.ColorRgba8(0, 0, 0, 255));

  final sourceAspect = source.width / source.height;
  const targetAspect = 256 / 192;
  var drawW = 256;
  var drawH = 192;
  if (mode == PngFitMode.crop) {
    if (sourceAspect > targetAspect) {
      drawW = (192 * sourceAspect).round();
    } else {
      drawH = (256 / sourceAspect).round();
    }
  } else {
    if (sourceAspect > targetAspect) {
      drawH = (256 / sourceAspect).round();
    } else {
      drawW = (192 * sourceAspect).round();
    }
  }
  final offX = ((256 - drawW) / 2).floor();
  final offY = ((192 - drawH) / 2).floor();

  final startX = math.max(0, offX);
  final startY = math.max(0, offY);
  final endX = math.min(256, offX + drawW);
  final endY = math.min(192, offY + drawH);
  for (var ty = startY; ty < endY; ty++) {
    final sy = ((ty - offY) + 0.5) * source.height / drawH - 0.5;
    for (var tx = startX; tx < endX; tx++) {
      final sx = ((tx - offX) + 0.5) * source.width / drawW - 0.5;
      final rgb = _bilinearSampleOverBlack(source, sx, sy);
      canvas.setPixelRgba(tx, ty, rgb.$1, rgb.$2, rgb.$3, 255);
    }
  }
  return canvas;
}

(int, int, int) _bilinearSampleOverBlack(img.Image source, double x, double y) {
  final left = x.floor().clamp(0, source.width - 1);
  final top = y.floor().clamp(0, source.height - 1);
  final right = (left + 1).clamp(0, source.width - 1);
  final bottom = (top + 1).clamp(0, source.height - 1);
  final hw = (x - x.floorToDouble()).clamp(0.0, 1.0);
  final vw = (y - y.floorToDouble()).clamp(0.0, 1.0);

  final p00 = source.getPixel(left, top);
  final p10 = source.getPixel(right, top);
  final p01 = source.getPixel(left, bottom);
  final p11 = source.getPixel(right, bottom);

  double ch(double Function(img.Pixel) f) {
    final topRow =
        f(p00) + ((f(p10) - f(p00)) * hw);
    final botRow =
        f(p01) + ((f(p11) - f(p01)) * hw);
    return topRow + ((botRow - topRow) * vw);
  }

  final alpha = ch((p) => p.a.toDouble()) / 255.0;
  int c(double Function(img.Pixel) f) =>
      (ch(f) * alpha).round().clamp(0, 255);
  return (c((p) => p.r.toDouble()), c((p) => p.g.toDouble()),
      c((p) => p.b.toDouble()));
}

class _Sample {
  const _Sample(this.r, this.g, this.b);
  final int r, g, b;
}

class _Candidate {
  const _Candidate(this.bits, this.bright, this.error, this.ink, this.paper);
  final List<int> bits;
  final bool bright;
  final double error;
  final int ink, paper;
}

_Candidate _evaluateBlock(img.Image image, int bx, int by, bool bright,
    PngImportOptions options) {
  final colourCounts = List<int>.filled(8, 0);
  final samples = <_Sample>[];
  for (var ly = 0; ly < 8; ly++) {
    for (var lx = 0; lx < 8; lx++) {
      final p = image.getPixel(bx * 8 + lx, by * 8 + ly);
      final r = _applyContrast(p.r.toInt(), options.contrast);
      final g = _applyContrast(p.g.toInt(), options.contrast);
      final b = _applyContrast(p.b.toInt(), options.contrast);
      colourCounts[_nearestIndex(r, g, b, bright, options.errorMetric)]++;
      samples.add(_Sample(r, g, b));
    }
  }

  final ranked = List<int>.generate(8, (i) => i)
    ..sort((a, b) => colourCounts[b].compareTo(colourCounts[a]));
  final paper = ranked[0];
  var ink = paper;
  for (var i = 1; i < 8; i++) {
    if (colourCounts[ranked[i]] > 0) {
      ink = ranked[i];
      break;
    }
  }

  final bits = List<int>.filled(64, 0);
  final paperRgb = _rgb(paper, bright);
  final inkRgb = _rgb(ink, bright);
  var error = 0.0;
  for (var i = 0; i < 64; i++) {
    final s = samples[i];
    final pd = _distance(
        s.r, s.g, s.b, paperRgb[0], paperRgb[1], paperRgb[2], options.errorMetric);
    final id = _distance(
        s.r, s.g, s.b, inkRgb[0], inkRgb[1], inkRgb[2], options.errorMetric);
    final useInk = ink != paper && id < pd;
    bits[i] = useInk ? 1 : 0;
    error += useInk ? id : pd;
  }
  return _Candidate(bits, bright, error, ink, paper);
}

int _nearestIndex(
    int r, int g, int b, bool bright, ErrorMetric metric) {
  var best = 0;
  var bestDist = double.infinity;
  for (var i = 0; i < 8; i++) {
    final p = _rgb(i, bright);
    final d = _distance(r, g, b, p[0], p[1], p[2], metric);
    if (d < bestDist) {
      best = i;
      bestDist = d;
    }
  }
  return best;
}

double _distance(
    int rA, int gA, int bA, int rB, int gB, int bB, ErrorMetric metric) {
  if (metric == ErrorMetric.absolute) {
    return ((rA - rB).abs() + (gA - gB).abs() + (bA - bB).abs()).toDouble();
  }
  final dr = rA - rB, dg = gA - gB, db = bA - bB;
  return (dr * dr + dg * dg + db * db).toDouble();
}

int _applyContrast(int v, double contrast) =>
    ((v - 128) * contrast + 128).round().clamp(0, 255);
