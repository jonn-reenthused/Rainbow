import 'package:rainbow_assets/rainbow_assets.dart';
import 'package:test/test.dart';

void main() {
  group('encodeSprite', () {
    test('encodes header + mask/bitmap per frame', () {
      final b = encodeSprite('blob', {
        'w': 8,
        'h': 8,
        'attr': 7,
        'frames': [
          [
            '########',
            '#......#',
            '#..##..#',
            '#.#..#.#',
            '#.#..#.#',
            '#..##..#',
            '#......#',
            '########',
          ]
        ],
      });
      // 4 header + 8*nf u16 phase offsets + nf*(mask+bmp) +
      // 8*nf*h*(wb+1)*2 pre-shifted bytes
      expect(b.length, 4 + 16 + 16 + 256);
      expect(b.sublist(0, 4), [1, 8, 1, 7]); // wb, h, nframes, attr
      // offset table: phase-major u16 offsets from asset start;
      // blockBase = 36, blockSize = h*(wb+1)*2 = 32
      expect(b.sublist(4, 20),
          [36, 0, 68, 0, 100, 0, 132, 0, 164, 0, 196, 0, 228, 0, 4, 1]);
      // immediate frame data at 20: mask then bitmap per frame
      expect(b.sublist(20, 28),
          [0x00, 0x7E, 0x66, 0x5A, 0x5A, 0x66, 0x7E, 0x00]); // masks
      expect(b.sublist(28, 36),
          [0xFF, 0x81, 0x99, 0xA5, 0xA5, 0x99, 0x81, 0xFF]); // bitmaps
      // phase-0 block row0 at 36: {mask,bmp} x (wb+1) columns
      expect(b.sublist(36, 40), [0x00, 0xFF, 0xFF, 0x00]);
    });

    test("'o' pixels are opaque-paper: mask 0, bitmap 0", () {
      final b = encodeSprite('s', {
        'w': 8,
        'h': 2,
        'frames': [
          ['#o#o#o#o', '.o.o.o.o']
        ],
      });
      // mask then bitmap in the immediate frame data (offset 20)
      expect(b[20], 0x00); // '#o#o#o#o' all opaque -> mask 0
      expect(b[21], 0xAA); // '.o.o.o.o' transparent at even bits
      expect(b[22], 0xAA); // '#o#o#o#o' ink at even bits
      expect(b[23], 0x00); // '.o.o.o.o' no ink
    });

    test('two frames multiply data size', () {
      final b = encodeSprite('s', {
        'w': 16,
        'h': 4,
        'frames': [
          List.filled(4, '................'),
          List.filled(4, '################'),
        ],
      });
      // 4 + 2*8*2 offsets + 2*(2*4 mask+bmp) + 8*2*4*(2+1)*2 blocks
      expect(b.length, 4 + 32 + 32 + 384);
      expect(b[3], 0x38); // default attr
    });

    test('rejects bad geometry', () {
      expect(
          () => encodeSprite('x', {
                'w': 10,
                'h': 8,
                'frames': []
              }),
          throwsA(isA<AssetFormatException>()));
    });
  });

  group('encodeTileset', () {
    test('bitmap then attrs then flags', () {
      final b = encodeTileset('t', {
        'tiles': [
          List.filled(8, '........'),
          List.filled(8, '########'),
        ],
        'attrs': [56, 7],
        'flags': [0, 1],
      });
      expect(b.length, 1 + 16 + 2 + 2);
      expect(b[0], 2);
      expect(b.sublist(1, 9), List.filled(8, 0));
      expect(b.sublist(9, 17), List.filled(8, 0xFF));
      expect(b.sublist(17, 19), [56, 7]);
      expect(b.sublist(19, 21), [0, 1]);
    });
  });

  group('encodeTilemap', () {
    test('w,h then w*h cells', () {
      final b = encodeTilemap('m', {
        'w': 3,
        'h': 2,
        'map': [0, 1, 2, 3, 4, 5],
      });
      expect(b, [3, 2, 0, 1, 2, 3, 4, 5]);
    });

    test('rejects wrong cell count', () {
      expect(
          () => encodeTilemap('m', {'w': 2, 'h': 2, 'map': [1]}),
          throwsA(isA<AssetFormatException>()));
    });
  });

  group('encodeFont', () {
    test('always emits 768 bytes; unset glyphs inherit ROM font', () {
      final b = encodeFont('f', {'chars': <String, dynamic>{}});
      expect(b.length, 768);
      // 'A' = 65 -> offset 264 inherits the Spectrum glyph
      expect(b.sublist(264, 272),
          [0x00, 0x3C, 0x42, 0x42, 0x7E, 0x42, 0x42, 0x00]);
      expect(b.sublist(0, 8), List.filled(8, 0)); // space
    });

    test('"base": "blank" emits zeros for unset glyphs', () {
      final b = encodeFont(
          'f', {'base': 'blank', 'chars': <String, dynamic>{}});
      expect(b, List.filled(768, 0));
    });

    test('glyph for ASCII code lands at (code-32)*8', () {
      final b = encodeFont('f', {
        'chars': {
          '65': [
            '........',
            '..####..',
            '.##..##.',
            '##....##',
            '########',
            '##....##',
            '##....##',
            '........',
          ]
        }
      });
      expect(b.length, 768);
      // 'A' = 65 -> glyph index 33 -> byte offset 264
      expect(b.sublist(264, 272), [0x00, 0x3C, 0x66, 0xC3, 0xFF, 0xC3, 0xC3, 0x00]);
      expect(b.sublist(0, 8), List.filled(8, 0));
    });
  });

  group('encodeScreenCbm', () {
    String hx(List<int> bytes) =>
        bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

    test('ZX display order maps to linear C64 hires layout', () {
      final bm = List<int>.filled(6144, 0);
      // ZX y=8 (char row 1, line 0), col 0 -> display index 1*256
      bm[256] = 0xFF;
      // ZX y=1 (char row 0, line 1), col 0 -> display index 1*32
      bm[32] = 0x80;
      // ZX y=191 (third 2, row 7, line 7), col 31 -> 2*2048+7*256+7*32+31
      bm[2 * 2048 + 7 * 256 + 7 * 32 + 31] = 0x01;
      final b = encodeScreenCbm('s',
          {'bitmap': hx(bm), 'attrs': hx(List<int>.filled(768, 0))});
      expect(b.length, 9000);
      expect(b[320], 0xFF); // C64 char row 1: 1*320
      expect(b[1], 0x80); // C64 char row 0, line 1: 0*320 + 0*8 + 1
      // C64 y=191, col 31: 23*320 + 31*8 + 7
      expect(b[23 * 320 + 31 * 8 + 7], 0x01);
      // ZX-only columns/rows leave the C64-only band zero
      expect(b[24 * 320], 0); // y=192 has no ZX source
      expect(b[32 * 8], 0); // char col 32 has no ZX source
    });

    test('attrs map to fg<<4|bg matrix bytes, bright and flash handled', () {
      final at = List<int>.filled(768, 0);
      at[0] = 0x15; // paper 2, ink 5
      at[1] = 0x55; // bright + paper 2, ink 5
      at[2] = 0x95; // flash + paper 2, ink 5
      final b = encodeScreenCbm('s', {
        'bitmap': hx(List<int>.filled(6144, 0)),
        'attrs': hx(at),
      });
      expect(b[8000], 0x52); // fg 5, bg 2
      expect(b[8001], 0xDA); // bright -> c64 light variants
      expect(b[8002], 0x25); // flash swaps fg/bg
      // row 24 / col 32+ clamp to the ZX edge
      at.fillRange(0, 768, 0);
      at[23 * 32] = 0x15;
      at[31] = 0x21; // row 0 col 31: paper 4 ink 1
      final b2 = encodeScreenCbm('s', {
        'bitmap': hx(List<int>.filled(6144, 0)),
        'attrs': hx(at),
      });
      expect(b2[8000 + 24 * 40], 0x52); // row 24 <- ZX row 23
      expect(b2[8000 + 32], 0x14); // col 32 <- ZX col 31
    });

    test('rejects wrong-length fields', () {
      expect(
          () => encodeScreenCbm('s', {'bitmap': '00', 'attrs': ''}),
          throwsA(isA<AssetFormatException>()));
    });
  });
}
