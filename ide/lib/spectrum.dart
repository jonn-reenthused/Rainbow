import 'package:flutter/material.dart';

/// ZX Spectrum palette and attribute helpers.

/// INK/PAPER colours (index 0..7), non-bright and bright variants.
const zxColours = [
  Color(0xFF000000), // 0 black
  Color(0xFF0000D8), // 1 blue
  Color(0xFFD80000), // 2 red
  Color(0xFFD800D8), // 3 magenta
  Color(0xFF00D800), // 4 green
  Color(0xFF00D8D8), // 5 cyan
  Color(0xFFD8D800), // 6 yellow
  Color(0xFFD8D8D8), // 7 white
];

const zxBright = [
  Color(0xFF000000),
  Color(0xFF0000FF),
  Color(0xFFFF0000),
  Color(0xFFFF00FF),
  Color(0xFF00FF00),
  Color(0xFF00FFFF),
  Color(0xFFFFFF00),
  Color(0xFFFFFFFF),
];

/// Decode a Spectrum attribute byte: FLASH|BRIGHT|PAPER|INK.
Color zxInk(int attr) =>
    (attr & 0x40) != 0 ? zxBright[attr & 7] : zxColours[attr & 7];
Color zxPaper(int attr) =>
    (attr & 0x40) != 0 ? zxBright[(attr >> 3) & 7] : zxColours[(attr >> 3) & 7];

int zxAttr({required int ink, required int paper, bool bright = false}) =>
    (ink & 7) | ((paper & 7) << 3) | (bright ? 0x40 : 0);

/// Pixel states in sprite frame rows.
enum PixelKind { ink, paper, transparent }

/// Classify a sprite pixel char:
/// '#','X','x','1','*' = opaque ink; 'o','O' = opaque paper;
/// anything else ('.', '0', ' ') = transparent.
PixelKind pixelKind(String row, int x) {
  if (x >= row.length) return PixelKind.transparent;
  switch (row[x]) {
    case '#' || 'X' || 'x' || '1' || '*':
      return PixelKind.ink;
    case 'o' || 'O':
      return PixelKind.paper;
    default:
      return PixelKind.transparent;
  }
}

/// Parse a tile pixel char (tiles have no transparency).
bool pixelSet(String row, int x) =>
    x < row.length && pixelKind(row, x) == PixelKind.ink;
