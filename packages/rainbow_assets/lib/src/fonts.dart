import 'c64_font.dart';
import 'cpc_font.dart';
import 'zx_font.dart';

/// Shared geometry/encoding model for `.rbf` font assets.
///
/// `.rbf` v2 JSON:
///   "system": 'zx'|'cpc'|'c64'  (absent = 'zx', the v1 format)
///   "mode":   CPC screen mode 0|1|2 -> glyph bpp 4|2|1
///   "multi":  C64 multicolour text (2bpp pixel pairs)
///   "w":      glyph cell width in pixels, 4 or 8 (default 8)
///   "base":   absent/'rom' = unset chars inherit the system ROM font,
///             'blank' = empty glyphs
///   "chars":  ASCII code (string) -> 8 row strings of w pixel chars.
///             1bpp rows use the usual set chars ('#','X','x','1','*'
///             set; anything else clear); multibpp rows use a hex digit
///             per pixel ('0'..max), '#' aliases the max value.
class FontSpec {
  const FontSpec({
    required this.system,
    this.mode = 1,
    this.multi = false,
    this.w = 8,
  });

  /// 'zx', 'cpc' or 'c64'.
  final String system;

  /// CPC screen mode (0-2); meaningless elsewhere.
  final int mode;

  /// C64 multicolour text (2bpp pixel pairs, double-wide).
  final bool multi;

  /// Glyph cell width in pixels (4 or 8). C64 multi is always 4.
  final int w;

  static const h = 8;

  int get bpp {
    if (system == 'cpc') return 4 >> mode; // 4,2,1
    if (system == 'c64') return multi ? 2 : 1;
    return 1;
  }

  int get maxPx => (1 << bpp) - 1;

  /// Pixel value used when a glyph inherits the monochrome system font.
  /// CPC: pen 1 (the text pen). C64 multi: pair 11 = colour-RAM fg.
  int get inkPx {
    if (system == 'c64' && multi) return 3;
    return 1;
  }

  /// Bytes per glyph row in the encoded form.
  int get bytesPerRow {
    if (system == 'cpc') return (w * bpp + 7) ~/ 8;
    if (system == 'c64' && multi) return 1;
    return 1; // 1bpp packs left into a single byte
  }

  int get bytesPerGlyph => bytesPerRow * h;

  /// Editor canvas pixel aspect (mode-0 / C64-multi pixels are double-wide).
  double get pixelAspect =>
      (system == 'cpc' && mode == 0) || (system == 'c64' && multi) ? 2.0 : 1.0;

  /// Glyph count always spans ASCII 32-127.
  static const firstChar = 32;
  static const charCount = 96;
}

/// Parse a font's spec from its JSON (with system validation folded in —
/// callers should validate `system` membership first).
FontSpec fontSpec(Map<String, dynamic> json) {
  final system = (json['system'] as String? ?? 'zx').toLowerCase();
  final multi = json['multi'] == true;
  int num0(dynamic v, int dflt) => v is num ? v.toInt() : dflt;
  var w = num0(json['w'], 8);
  if (system == 'c64' && multi) w = 4;
  return FontSpec(
      system: system, mode: num0(json['mode'], 1), multi: multi, w: w);
}

/// The system's stock ROM glyph (1bpp, 8x8) for an ASCII code.
List<int> fontBaseGlyph(String system, int code) {
  final i = (code - FontSpec.firstChar) * 8;
  final table = switch (system) {
    'cpc' => cpcFont,
    'c64' => c64Font,
    _ => zxFont,
  };
  return table.sublist(i, i + 8);
}

/// Inherited glyph pixels at the font's width: 8 rows of spec.w values,
/// the system glyph cropped to the centre w columns, ink = spec.inkPx.
List<List<int>> fontBasePixels(FontSpec spec, int code) {
  final g = fontBaseGlyph(spec.system, code);
  final x0 = (8 - spec.w) ~/ 2;
  return [
    for (var y = 0; y < FontSpec.h; y++)
      [
        for (var x = 0; x < spec.w; x++)
          (g[y] & (0x80 >> (x + x0))) != 0 ? spec.inkPx : 0
      ]
  ];
}

/// Parse one pixel char. 1bpp honours the usual set chars; multibpp uses
/// hex digits with '#'/'X'/'x'/'*' aliasing the max value.
int fontPx(String row, int x, FontSpec spec) {
  if (x >= row.length) return 0;
  final c = row[x];
  if (spec.bpp == 1) {
    return (c == '#' || c == 'X' || c == 'x' || c == '1' || c == '*') ? 1 : 0;
  }
  if (c == '#' || c == 'X' || c == 'x' || c == '*') return spec.maxPx;
  final v = int.tryParse(c, radix: 16);
  return (v != null && v <= spec.maxPx) ? v : 0;
}

/// Row string -> pixel values (spec.w entries).
List<int> fontRowPixels(String row, FontSpec spec) =>
    [for (var x = 0; x < spec.w; x++) fontPx(row, x, spec)];

/// Pack one row of pixel values into the target byte format:
/// CPC uses the hardware interleave per mode; C64 multi packs pairs
/// msb-first; 1bpp packs msb-first into a single byte.
List<int> fontPackRow(List<int> px, FontSpec spec) {
  if (spec.system == 'cpc' && spec.bpp > 1) {
    final out = <int>[];
    if (spec.bpp == 4) {
      for (var i = 0; i < px.length; i += 2) {
        final a = px[i], b = i + 1 < px.length ? px[i + 1] : 0;
        out.add(((a & 1) << 7) |
            ((a & 2) << 2) |
            ((a & 4) << 3) |
            ((a & 8) >> 2) |
            ((b & 1) << 6) |
            ((b & 2) << 1) |
            ((b & 4) << 2) |
            ((b & 8) >> 3));
      }
    } else {
      for (var i = 0; i < px.length; i += 4) {
        var b = 0;
        for (var k = 0; k < 4; k++) {
          final v = i + k < px.length ? px[i + k] : 0;
          b |= (v & 1) << (7 - k);
          b |= ((v >> 1) & 1) << (3 - k);
        }
        out.add(b);
      }
    }
    return out;
  }
  if (spec.system == 'c64' && spec.multi) {
    var b = 0;
    for (var i = 0; i < px.length; i++) {
      b |= (px[i] & 3) << (6 - 2 * i);
    }
    return [b];
  }
  // 1bpp: msb-first, pixels in the top bits of one byte.
  var b = 0;
  for (var i = 0; i < px.length; i++) {
    if (px[i] != 0) b |= 0x80 >> i;
  }
  return [b];
}
