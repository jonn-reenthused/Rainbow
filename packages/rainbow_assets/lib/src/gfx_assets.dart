import 'dart:typed_data';

import 'snd_assets.dart';
import 'zx_font.dart';

/// Encoders for Rainbow graphics assets (.rbs / .rbt / .rbm JSON files).
///
/// Runtime binary layouts (read by rbt_sprite.asm / rbt_tilemap.asm):
///
/// Sprite (.rbs):
///   defb wb          ; width in bytes
///   defb h           ; height in pixels
///   defb nframes
///   defb attr        ; default attribute (0xFF = don't write attrs)
///   defw nframes*8   ; offset table: offs[phase*nframes + frame],
///                    ; absolute offset from asset start to that phase/frame's
///                    ; pre-shifted block (used by the cell compositor)
///   per frame: wb*h mask bytes (1=keep screen,0=draw) then wb*h bitmap bytes
///   pre-shifted blocks, phase-major then frame, per phase p in 0..7:
///     h rows x (wb+1) columns of {mask,bmp} byte pairs; column i is the
///     source column pair (i-1,i) shifted right by p already applied, so the
///     compositor only fetches and merges (pad: mask #FF, bmp 0)
///
/// Pixel chars in frame rows: '#'/'X'/'x'/'1'/'*' = opaque ink pixel,
/// 'o'/'O' = opaque paper pixel (clears screen), anything-else-clear
/// ('.', '0', ' ') = transparent — background shows through.
///
/// Tileset (.rbt):
///   defb n           ; tile count
///   defb n*8         ; 8x8 bitmaps
///   defb n           ; attributes
///   defb n           ; per-tile flag bytes (bit0 = solid for COLLIDETILE)
///
/// Tilemap (.rbm):
///   defb w, h        ; map size in tiles
///   defb w*h         ; tile indices, row-major
///
/// Font (.rbf):
///   defb 96*8        ; glyphs for ASCII 32-127, 8 bytes each
///                  ; unset chars inherit the ROM font ("base":"blank" = 0s)
///
/// Screen (.rbc):
///   defb 6144        ; bitmap in Spectrum display order (thirds/rows/lines)
///   defb 768         ; attribute cells, row-major

class AssetFormatException implements Exception {
  AssetFormatException(this.asset, this.message);
  final String asset;
  final String message;
  @override
  String toString() => '$asset: $message';
}

/// Pack one row of pixel text into bytes. Set chars: '#', 'X', 'x', '1', '*'.
int _packRow(String row, int byteIndex, String asset) {
  var b = 0;
  for (var bit = 0; bit < 8; bit++) {
    final c = row[byteIndex * 8 + bit];
    if (c == '#' || c == 'X' || c == 'x' || c == '1' || c == '*') {
      b |= 0x80 >> bit;
    } else if (c != '.' && c != '0' && c != ' ') {
      throw AssetFormatException(
          asset, 'invalid pixel char "$c" (use . and #)');
    }
  }
  return b;
}

List<String> _frameRows(Map<String, dynamic> json, int i, String asset) {
  final frames = json['frames'];
  if (frames is! List || frames.isEmpty || i >= frames.length) {
    throw AssetFormatException(asset, 'missing frame $i');
  }
  final f = frames[i];
  if (f is! List)
    throw AssetFormatException(asset, 'frame $i must be a list of strings');
  return f.cast<String>();
}

/// Encode a sprite asset to its runtime binary form.
Uint8List encodeSprite(String name, Map<String, dynamic> json) {
  final w = json['w'] as int? ?? 0;
  final h = json['h'] as int? ?? 0;
  if (w <= 0 || w > 248 || w % 8 != 0) {
    throw AssetFormatException(
        name, 'w must be a positive multiple of 8 (<=248)');
  }
  if (h <= 0 || h > 192) {
    throw AssetFormatException(name, 'h must be 1..192');
  }
  final wb = w >> 3;
  final frames = json['frames'] as List? ?? const [];
  if (frames.isEmpty || frames.length > 255) {
    throw AssetFormatException(name, 'need 1..255 frames');
  }
  // attr byte, or "none" -> 0xFF: runtime skips the attribute write so
  // the sprite doesn't clash with background attrs.
  final a = json['attr'];
  final attr = a is String && a == 'none' ? 0xFF : (a as int? ?? 0x38) & 0xFF;
  final out = BytesBuilder(copy: false)
    ..addByte(wb)
    ..addByte(h)
    ..addByte(frames.length)
    ..addByte(attr);
  final frameMasks = List<Uint8List>.filled(frames.length, Uint8List(0));
  final frameBmps = List<Uint8List>.filled(frames.length, Uint8List(0));

  for (var f = 0; f < frames.length; f++) {
    final rows = _frameRows(json, f, name);
    if (rows.length != h) {
      throw AssetFormatException(
          name, 'frame $f has ${rows.length} rows, expected $h');
    }
    for (final r in rows) {
      if (r.length != w) {
        throw AssetFormatException(
            name, 'frame $f row length ${r.length}, expected $w');
      }
    }
    // Per pixel: '#'-set = opaque ink, 'o' = opaque paper (clears the
    // screen pixel), '.' = transparent (mask keeps the screen).
    final bmp = Uint8List(wb * h);
    final mask = Uint8List(wb * h);
    for (var y = 0; y < h; y++) {
      for (var bx = 0; bx < wb; bx++) {
        var b = 0, m = 0;
        for (var bit = 0; bit < 8; bit++) {
          final c = rows[y][bx * 8 + bit];
          final p = 0x80 >> bit;
          switch (c) {
            case '#' || 'X' || 'x' || '1' || '*':
              b |= p; // opaque ink
            case 'o' || 'O':
              break; // opaque paper: mask 0, bmp 0
            case '.' || '0' || ' ':
              m |= p; // transparent
            default:
              throw AssetFormatException(
                  name, 'invalid pixel char "$c" (use . o #)');
          }
        }
        bmp[y * wb + bx] = b;
        mask[y * wb + bx] = m;
      }
    }
    frameMasks[f] = mask;
    frameBmps[f] = bmp;
  }

  // Offset table at asset+4: nframes*8 u16 entries, absolute offset from
  // asset start. Table order is phase-major: offs[phase*nframes + frame].
  final ow = wb + 1;
  final tableSize = frames.length * 8 * 2;
  final blockBase = 4 + tableSize + frames.length * wb * h * 2;
  final blockSize = h * ow * 2;
  for (var p = 0; p < 8; p++) {
    for (var f = 0; f < frames.length; f++) {
      final off = blockBase + (p * frames.length + f) * blockSize;
      out
        ..addByte(off & 0xFF)
        ..addByte((off >> 8) & 0xFF);
    }
  }
  // Frame data (unchanged layout, used by the immediate draw path).
  for (var f = 0; f < frames.length; f++) {
    out.add(frameMasks[f]);
    out.add(frameBmps[f]);
  }
  // Pre-shifted blocks: for each pixel phase the compositor's
  // (prev<<8|cur)>>shift result is baked into ow = wb+1 columns of
  // {mask,bmp} pairs, so the cell compositor only fetches and merges.
  for (var p = 0; p < 8; p++) {
    for (var f = 0; f < frames.length; f++) {
      final mask = frameMasks[f];
      final bmp = frameBmps[f];
      for (var y = 0; y < h; y++) {
        for (var i = 0; i < ow; i++) {
          final mPrev = i > 0 ? mask[y * wb + i - 1] : 0xFF;
          final mCur = i < wb ? mask[y * wb + i] : 0xFF;
          final bPrev = i > 0 ? bmp[y * wb + i - 1] : 0;
          final bCur = i < wb ? bmp[y * wb + i] : 0;
          out
            ..addByte(((mPrev << (8 - p)) & 0xFF) | (mCur >> p))
            ..addByte(((bPrev << (8 - p)) & 0xFF) | (bCur >> p));
        }
      }
    }
  }
  return out.toBytes();
}

/// Encode a sprite asset for the CPC runtime.
///
/// Layout (read by runtime/cpc/rbt_sprite.asm):
///   defb wpx         ; width in pixels (multiple of 8)
///   defb h           ; height in pixels
///   defb nframes
///   defb attr        ; stored, unused on CPC
///   defw nframes*4   ; offs[phase*nframes + frame], from asset start
///   blocks: per phase p in 0..3, per frame, h rows x (wpx/4+1) columns
///   of {mask,bmp} bytes. Column bytes cover 4 pixels each in mode-1
///   pen-1/pen-0 encoding: mask bit = 1 keeps the screen bit (positions
///   0x88>>k per pixel), bmp bit = 1 draws pen 1 (positions 0x08>>k).
Uint8List encodeSpriteCpc(String name, Map<String, dynamic> json) {
  final w = json['w'] as int? ?? 0;
  final h = json['h'] as int? ?? 0;
  if (w <= 0 || w > 248 || w % 8 != 0) {
    throw AssetFormatException(
        name, 'w must be a positive multiple of 8 (<=248)');
  }
  if (h <= 0 || h > 192) {
    throw AssetFormatException(name, 'h must be 1..192');
  }
  final frames = json['frames'] as List? ?? const [];
  if (frames.isEmpty || frames.length > 255) {
    throw AssetFormatException(name, 'need 1..255 frames');
  }
  final a = json['attr'];
  final attr = a is String && a == 'none' ? 0xFF : (a as int? ?? 0x38) & 0xFF;
  final nf = frames.length;
  final cols = w ~/ 4 + 1;
  final blockSize = h * cols * 2;
  final blockBase = 4 + nf * 4 * 2;
  final out = BytesBuilder(copy: false)
    ..addByte(w)
    ..addByte(h)
    ..addByte(nf)
    ..addByte(attr);
  for (var i = 0; i < nf * 4; i++) {
    final off = blockBase + i * blockSize;
    out
      ..addByte(off & 0xFF)
      ..addByte((off >> 8) & 0xFF);
  }
  for (var p = 0; p < 4; p++) {
    for (var f = 0; f < nf; f++) {
      final rows = _frameRows(json, f, name);
      if (rows.length != h) {
        throw AssetFormatException(
            name, 'frame $f has ${rows.length} rows, expected $h');
      }
      for (var y = 0; y < h; y++) {
        final r = rows[y];
        if (r.length != w) {
          throw AssetFormatException(
              name, 'frame $f row length ${r.length}, expected $w');
        }
        for (var jx = 0; jx < cols; jx++) {
          var mask = 0, bmp = 0;
          for (var k = 0; k < 4; k++) {
            final srcPx = jx * 4 + k - p; // screen px = p + src index
            if (srcPx < 0 || srcPx >= w) {
              mask |= 0x88 >> k; // out of sprite: keep screen
              continue;
            }
            switch (r[srcPx]) {
              case '#' || 'X' || 'x' || '1' || '*':
                bmp |= 0x08 >> k; // opaque ink -> pen 1
              case 'o' || 'O':
                break; // opaque paper -> pen 0
              case '.' || '0' || ' ':
                mask |= 0x88 >> k; // transparent -> keep screen
              default:
                throw AssetFormatException(
                    name, 'invalid pixel char "${r[srcPx]}" (use . o #)');
            }
          }
          out
            ..addByte(mask)
            ..addByte(bmp);
        }
      }
    }
  }
  return out.toBytes();
}

/// Encode a screen asset for the CPC: Spectrum bitmap order expanded to
/// mode-1 pen1/pen0 bytes, y-linear (192 lines x 64 bytes). Attributes
/// are ignored - pen inks are set via INK/PAPER at runtime.
Uint8List encodeScreenCpc(String name, Map<String, dynamic> json) {
  final bm = (json['bitmap'] as String? ?? '').replaceAll(RegExp(r'\s'), '');
  if (bm.length != 6144 * 2) {
    throw AssetFormatException(
        name, '"bitmap" is ${bm.length ~/ 2} bytes, expected 6144');
  }
  final b = Uint8List(6144);
  for (var i = 0; i < 6144; i++) {
    b[i] = int.parse(bm.substring(i * 2, i * 2 + 2), radix: 16);
  }
  final out = Uint8List(192 * 64);
  for (var y = 0; y < 192; y++) {
    // Spectrum display order: third | row | line | column
    final rowOff = (y >> 6) * 2048 + ((y >> 3) & 7) * 256 + (y & 7) * 32;
    for (var xb = 0; xb < 32; xb++) {
      final v = b[rowOff + xb];
      out[y * 64 + xb * 2] = (v >> 4) & 0x0F; // px0..3 -> pen1 lo bits
      out[y * 64 + xb * 2 + 1] = v & 0x0F; // px4..7
    }
  }
  return out;
}

/// Encode a tileset asset.
Uint8List encodeTileset(String name, Map<String, dynamic> json) {
  final tiles = json['tiles'] as List? ?? const [];
  if (tiles.isEmpty || tiles.length > 255) {
    throw AssetFormatException(name, 'need 1..255 tiles');
  }
  final n = tiles.length;
  final defaultAttr = (json['attr'] as int? ?? 0x38) & 0xFF;
  final attrs =
      (json['attrs'] as List?)?.cast<int>() ?? List<int>.filled(n, defaultAttr);
  final flags = (json['flags'] as List?)?.cast<int>() ?? List<int>.filled(n, 0);
  if (attrs.length != n || flags.length != n) {
    throw AssetFormatException(name, 'attrs/flags must have $n entries');
  }
  final out = BytesBuilder(copy: false)..addByte(n);
  for (var t = 0; t < n; t++) {
    final rows = (tiles[t] as List).cast<String>();
    if (rows.length != 8) {
      throw AssetFormatException(
          name, 'tile $t has ${rows.length} rows, expected 8');
    }
    for (var y = 0; y < 8; y++) {
      if (rows[y].length != 8) {
        throw AssetFormatException(
            name, 'tile $t row $y length ${rows[y].length}, expected 8');
      }
      out.addByte(_packRow(rows[y], 0, name));
    }
  }
  for (var t = 0; t < n; t++) {
    out.addByte(attrs[t] & 0xFF);
  }
  for (var t = 0; t < n; t++) {
    out.addByte(flags[t] & 0xFF);
  }
  return out.toBytes();
}

/// Encode a font asset: 96 glyphs (ASCII 32-127), 8 bytes each.
///
/// `.rbf` JSON: `"chars"` is a map of ASCII code (as string) -> list of 8
/// row strings. Codes without an entry inherit the Spectrum ROM glyph
/// (set `"base": "blank"` to start from empty glyphs instead), so a font
/// file only needs the glyphs it overrides.
Uint8List encodeFont(String name, Map<String, dynamic> json) {
  final chars = json['chars'] as Map<String, dynamic>? ?? const {};
  final romBase = json['base'] != 'blank';
  final out = BytesBuilder(copy: false);
  for (var code = 32; code < 128; code++) {
    final rows = (chars['$code'] as List?)?.cast<String>();
    if (rows == null) {
      if (romBase) {
        out.add(zxFont.sublist((code - 32) * 8, (code - 32) * 8 + 8));
      } else {
        for (var i = 0; i < 8; i++) {
          out.addByte(0);
        }
      }
      continue;
    }
    if (rows.length != 8) {
      throw AssetFormatException(
          name, 'char $code has ${rows.length} rows, expected 8');
    }
    for (var y = 0; y < 8; y++) {
      if (rows[y].length != 8) {
        throw AssetFormatException(name,
            'char $code row $y length ${rows[y].length}, expected 8');
      }
      out.addByte(_packRow(rows[y], 0, name));
    }
  }
  return out.toBytes();
}

/// Encode a tilemap asset.
Uint8List encodeTilemap(String name, Map<String, dynamic> json) {
  final w = json['w'] as int? ?? 0;
  final h = json['h'] as int? ?? 0;
  if (w <= 0 || w > 255 || h <= 0 || h > 255) {
    throw AssetFormatException(name, 'w and h must be 1..255');
  }
  final map = (json['map'] as List?)?.cast<int>() ?? const [];
  if (map.length != w * h) {
    throw AssetFormatException(
        name, 'map has ${map.length} cells, expected ${w * h}');
  }
  final out = BytesBuilder(copy: false)
    ..addByte(w)
    ..addByte(h);
  for (final t in map) {
    out.addByte(t & 0xFF);
  }
  return out.toBytes();
}

/// Encode a screen asset: 6144 bitmap + 768 attr bytes (6912 total),
/// ready to LDIR straight to 0x4000.
///
/// `.rbc` JSON: `"bitmap"` and `"attrs"` are hex strings in Spectrum
/// display order (bitmap: thirds, then char rows, then pixel lines;
/// attrs: 32x24 cells row-major).
Uint8List encodeScreen(String name, Map<String, dynamic> json) {
  Uint8List hex(String key, int want) {
    final s = (json[key] as String? ?? '').replaceAll(RegExp(r'\s'), '');
    if (s.length != want * 2) {
      throw AssetFormatException(
          name, '"$key" is ${s.length ~/ 2} bytes, expected $want');
    }
    final out = Uint8List(want);
    for (var i = 0; i < want; i++) {
      out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }

  final out = BytesBuilder(copy: false)
    ..add(hex('bitmap', 6144))
    ..add(hex('attrs', 768));
  return out.toBytes();
}

/// File extension -> encoder, for the build driver's asset scan.
typedef GfxEncoder = Uint8List Function(String name, Map<String, dynamic> json);
const gfxEncoders = <String, GfxEncoder>{
  '.rbs': encodeSprite,
  '.rbt': encodeTileset,
  '.rbm': encodeTilemap,
  '.rbf': encodeFont,
  '.rbc': encodeScreen,
  '.rnt': encodeRnt,
  '.rsf': encodeRsf,
  '.ray': encodeRay,
};

/// 48K variant: .ray songs convert to AntEater beeper format (the 48K
/// MUSIC engine), so the same asset covers every ZX target.
final zx48GfxEncoders = <String, GfxEncoder>{
  ...gfxEncoders,
  '.ray': encodeRayBeeper,
};

/// 128K/+3 variant: .rnt songs convert to ZX-clock .ray rows so they
/// play through the AY MUSIC engine.
final zx128GfxEncoders = <String, GfxEncoder>{
  ...gfxEncoders,
  '.rnt': encodeRntZx,
};

/// Encode a sprite asset for the CBM (C64) runtime.
///
/// C64 hardware sprites are 24x21 1bpp pixels = 63 bytes at 64-byte
/// alignment. The source sprite is clipped/padded into that window.
///
/// Layout (read by runtime/c64/rbt_sprite.s):
///   defb w           ; source width in pixels (collision bbox)
///   defb h           ; source height in pixels
///   defb nframes
///   defb colour      ; C64 colour nibble (ZX attr ink + bright<<3)
///   pad to 64 bytes  ; the header occupies one whole sprite-data block
///   per frame: 63 bytes + pad — 21 rows x 3 bytes, MSB = leftmost pixel
///
/// Frames are padded to 64 bytes and the asset is emitted .align 64 so
/// every frame lands on a 64-byte boundary inside VIC bank 0 — the
/// multiplexer can then point the hardware sprite pointer directly at
/// the asset instead of copying frames into the sprite pool.
///
/// 'o'/paper pixels are transparent on hardware sprites (there is no
/// mask channel) — only set pixels draw, in the sprite's colour.
Uint8List encodeSpriteCbm(String name, Map<String, dynamic> json) {
  final w = json['w'] as int? ?? 0;
  final h = json['h'] as int? ?? 0;
  if (w <= 0 || w > 248 || w % 8 != 0) {
    throw AssetFormatException(
        name, 'w must be a positive multiple of 8 (<=248)');
  }
  if (h <= 0 || h > 192) {
    throw AssetFormatException(name, 'h must be 1..192');
  }
  final frames = json['frames'] as List? ?? const [];
  if (frames.isEmpty || frames.length > 255) {
    throw AssetFormatException(name, 'need 1..255 frames');
  }
  final a = json['attr'];
  // 'none' (no ZX attr) -> white. ZX attr = FBPPPIII -> C64 nibble:
  // ink bits + bright into bit3.
  final ai = a is int ? a : 0x38;
  final colour =
      a is String && a == 'none' ? 1 : ((ai & 7) | ((ai >> 3) & 8));
  final out = BytesBuilder(copy: false)
    ..addByte(w)
    ..addByte(h)
    ..addByte(frames.length)
    ..addByte(colour);
  for (var i = 4; i < 64; i++) {
    out.addByte(0);
  }
  for (var f = 0; f < frames.length; f++) {
    final rows = _frameRows(json, f, name);
    if (rows.length != h) {
      throw AssetFormatException(
          name, 'frame $f has ${rows.length} rows, expected $h');
    }
    for (final r in rows) {
      if (r.length != w) {
        throw AssetFormatException(
            name, 'frame $f row length ${r.length}, expected $w');
      }
    }
    for (var y = 0; y < 21; y++) {
      for (var bx = 0; bx < 3; bx++) {
        var b = 0;
        for (var bit = 0; bit < 8; bit++) {
          final px = bx * 8 + bit;
          if (y >= h || px >= w) continue;
          final c = rows[y][px];
          switch (c) {
            case '#' || 'X' || 'x' || '1' || '*':
              b |= 0x80 >> bit;
            case 'o' || 'O' || '.' || '0' || ' ':
              break; // transparent on a hardware sprite
            default:
              throw AssetFormatException(
                  name, 'invalid pixel char "$c" (use . o #)');
          }
        }
        out.addByte(b);
      }
    }
    out.addByte(0);
  }
  return out.toBytes();
}

/// Encoder table for CPC targets. 1bpp formats (.rbt tilesets, .rbm
/// tilemaps, .rbf fonts) are shared - the CPC runtime expands them to
/// mode-1 pixels at draw time. Sprites, screens and sound need
/// platform-specific payloads (4-phase 2bpp sprites, interleaved
/// screen order, AY-clock periods).
const cpcGfxEncoders = <String, GfxEncoder>{
  '.rbs': encodeSpriteCpc,
  '.rbt': encodeTileset,
  '.rbm': encodeTilemap,
  '.rbf': encodeFont,
  '.rbc': encodeScreenCpc,
  '.rnt': encodeRntCpc,
  '.rsf': encodeRsfCpc,
  '.ray': encodeRayCpc,
};

/// Encode a screen asset for the C64: Spectrum bitmap+attrs repacked to
/// the hires-bitmap layout SHOWPIC blits — 8000 bitmap bytes (y-linear:
/// (y>>3)*320 + (x>>3)*8 + (y&7)) then 1000 matrix bytes (fg<<4|bg per
/// 8x8 cell, ink/paper + bright folded to C64 nibbles; FLASH swaps).
/// The 256x192 source sits top-left of the 320x200 screen; cells the
/// source doesn't cover extend the edge attribute outward.
Uint8List encodeScreenCbm(String name, Map<String, dynamic> json) {
  Uint8List hex(String key, int want) {
    final s = (json[key] as String? ?? '').replaceAll(RegExp(r'\s'), '');
    if (s.length != want * 2) {
      throw AssetFormatException(
          name, '"$key" is ${s.length ~/ 2} bytes, expected $want');
    }
    final out = Uint8List(want);
    for (var i = 0; i < want; i++) {
      out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }

  final bm = hex('bitmap', 6144);
  final at = hex('attrs', 768);
  final out = Uint8List(8000 + 1000);
  for (var y = 0; y < 200; y++) {
    for (var xb = 0; xb < 40; xb++) {
      var v = 0;
      if (y < 192 && xb < 32) {
        // Spectrum display order: third | char row | line | column
        v = bm[(y >> 6) * 2048 + ((y >> 3) & 7) * 256 + (y & 7) * 32 + xb];
      }
      out[(y >> 3) * 320 + xb * 8 + (y & 7)] = v;
    }
  }
  for (var r = 0; r < 25; r++) {
    for (var c = 0; c < 40; c++) {
      final a = at[(r > 23 ? 23 : r) * 32 + (c > 31 ? 31 : c)];
      var fg = (a & 7) | ((a >> 3) & 8); // ink + bright
      var bg = ((a >> 3) & 7) | ((a >> 3) & 8); // paper + bright
      if (a & 0x80 != 0) {
        final t = fg;
        fg = bg;
        bg = t;
      }
      out[8000 + r * 40 + c] = (fg << 4) | bg;
    }
  }
  return out;
}

/// Encoder table for CBM (C64) targets. Tilesets/tilemaps/fonts are the
/// shared 1bpp formats; sprites are repacked to 24x21 hardware-sprite
/// frames; music (.ray/.rnt) and SFX (.rsf) convert to the SID row and
/// voice-3 sweep formats; screens go to hires bitmap+matrix.
const cbmGfxEncoders = <String, GfxEncoder>{
  '.rbs': encodeSpriteCbm,
  '.rbt': encodeTileset,
  '.rbm': encodeTilemap,
  '.rbf': encodeFont,
  '.rbc': encodeScreenCbm,
  '.rnt': encodeRntCbm,
  '.rsf': encodeRsfCbm,
  '.ray': encodeRayCbm,
};
