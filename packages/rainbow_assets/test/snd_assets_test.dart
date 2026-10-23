import 'package:rainbow_assets/rainbow_assets.dart';
import 'package:test/test.dart';

void main() {
  group('antPeriodTable', () {
    test('index 0/1 are rests; range spans C..B x8', () {
      expect(antPeriodTable[0], 0);
      expect(antPeriodTable[1], 0);
      expect(antPeriodTable.length, 98);
    });

    test('period halves per octave for the same note', () {
      // C in consecutive in-range octaves halves the counter
      final c4 = antPeriodTable[2 + 4 * 12];
      final c5 = antPeriodTable[2 + 5 * 12];
      final c6 = antPeriodTable[2 + 6 * 12];
      expect(c4, closeTo(c5 * 2, 1));
      expect(c5, closeTo(c6 * 2, 1));
    });
  });

  group('encodeRnt', () {
    test('non-looping song: order + pattern with terminators', () {
      final b = encodeRnt('tune', {
        'speed': 6,
        'loop': -1,
        'rows': [
          {'n1': 26, 'n2': 38}, // C-ish + E-ish on the two channels
          {'dr': 1},
        ],
      });
      // order: dw 6, dw 0, dw 0  ->  intro pattern at offset 6
      expect(b.sublist(0, 8), [6, 0, 0, 0, 0, 0, 6 << 2, antPeriodTable[26]]);
      expect(b[8], antPeriodTable[38]);
      expect(b[9], (6 << 2) | 1); // row1: drum 1, no notes
      expect(b[12], 0xFF); // pattern end
      expect(b.length, 6 + 7);
    });

    test('looping song splits intro/loop patterns', () {
      final b = encodeRnt('tune', {
        'speed': 6,
        'loop': 1,
        'rows': [
          {'n1': 26},
          {'n2': 38},
          {'dr': 2},
        ],
      });
      // order: dw 8, dw loopPat, dw 0, dw 2
      expect(b.sublist(0, 8), [8, 0, 12, 0, 0, 0, 2, 0]);
      // intro = 1 row + ff -> loop pattern at 8+4=12, 2 rows + ff
      expect(b.length, 8 + 4 + 7);
      expect(b[8], 6 << 2); // intro row byte0
      expect(b[11], 0xFF);
      expect(b[12], 6 << 2); // loop row0: no drum
      expect(b[15], (6 << 2) | 2); // loop row1: drum 2
      expect(b[18], 0xFF);
    });

    test('speed changes are sticky; detune subtracts', () {
      final b = encodeRnt('t', {
        'speed': 6,
        'rows': [
          {'n1': 26},
          {'spd': 3, 'n1': 26, 'd1': 2},
        ],
      });
      expect(b[6], 6 << 2);
      expect(b[7], antPeriodTable[26]);
      expect(b[9], 3 << 2); // new speed
      expect(b[10], antPeriodTable[26] - 2); // detuned
    });
  });

  group('encodeRsf', () {
    test('steps encode len,per,slide + terminator', () {
      final b = encodeRsf('zap', {
        'steps': [
          {'per': 80, 'len': 30, 'slide': -2},
          {'per': 40, 'len': 10},
        ],
      });
      expect(b, [30, 80, 254, 10, 40, 0, 0]);
    });
  });

  group('encodeRay', () {
    test('map rows expand to dur + r0..r13', () {
      final b = encodeRay('ay', {
        'rows': [
          {'dur': 3, 'a': [428, 15], 'mixer': 62},
        ],
        'loop': -1,
      });
      expect(b.length, 15 + 3);
      expect(b[0], 3); // dur
      expect(b.sublist(1, 3), [428 & 0xFF, 428 >> 8]); // tone A lo/hi
      expect(b[7], 0); // r6 noise
      expect(b[8], 62); // r7 mixer
      expect(b[9], 15); // r8 vol A
      expect(b[10], 0); // r9 vol B
      expect(b[14], 0xFF); // eshape default = don't touch
      expect(b.sublist(15, 18), [0, 0xFF, 0xFF]); // end marker, no loop
    });

    test('loop offset points back into row data', () {
      final b = encodeRay('ay', {
        'rows': [
          [3, 0, 0, 0, 0, 0, 0, 0, 62, 15, 0, 0, 0, 0, 255],
          [3, 0, 0, 0, 0, 0, 0, 0, 62, 10, 0, 0, 0, 0, 255],
        ],
        'loop': 0,
      });
      expect(b.length, 33);
      expect(b.sublist(30, 33), [0, 0, 0]); // dur 0, offset 0 -> row 0
    });
  });

  group('encodeRsfCbm', () {
    test('steps encode len,dur,freq,slide16.8 + terminator', () {
      final b = encodeRsfCbm('zap', {
        'steps': [
          {'per': 80, 'len': 30, 'slide': -2},
        ],
      });
      expect(b.length, 7);
      expect(b[0], 30); // len
      expect(b[1], (2712 / 17.8).round()); // dur ~= ZX iter wall time
      // per 80 -> f = 3.5e6/2712 = 1290.6 Hz -> SID reg ~21979
      final fq = b[2] | (b[3] << 8);
      expect(fq, (3.5e6 * 16777216 / 985248 / 2712).round());
      // negative slide on `per` -> positive freq slope (freq is reciprocal)
      final sq = b[4] | (b[5] << 8);
      expect(sq, greaterThan(0));
      expect(b[6], 0); // terminator
    });
  });

  group('encodeRayBeeper', () {
    test('tones convert to AntEater counters at 92Hz', () {
      final b = encodeRayBeeper('t', {
        'rows': [
          {'dur': 8, 'a': [428, 15], 'b': [340, 15]},
        ],
      });
      // order header then one row + terminator
      expect(b.sublist(0, 6), [6, 0, 0, 0, 0, 0]);
      // dur 8 -> round(8*1.4804) = 12 speed units
      expect(b[6], 12 << 2);
      // p 428 -> round(428*0.3432352) = 147; p 340 -> 117
      expect(b[7], 147);
      expect(b[8], 117);
      expect(b[9], 0xFF);
    });

    test('the two most active channels get the voices', () {
      final b = encodeRayBeeper('t', {
        'rows': [
          {'dur': 4, 'a': [428, 15], 'c': [340, 15]}, // B silent
          {'dur': 4, 'a': [428, 15]},
        ],
      });
      // voices 1/2 = A and C
      expect(b[7], 147); // A -> voice 1
      expect(b[8], 117); // C -> voice 2
      expect(b[10], 147);
      expect(b[11], 0); // C silent on row 1
    });

    test('noise channel triggers drum 1; "drum" overrides', () {
      final b = encodeRayBeeper('t', {
        'rows': [
          {'dur': 4, 'a': [428, 15], 'mixer': 0x30}, // noise on A+B
          {'dur': 4, 'a': [428, 15], 'drum': 3},
        ],
      });
      expect(b[6] & 3, 1); // heuristic drum
      expect(b[9] & 3, 3); // explicit drum
    });

    test('long rows split into <=63-unit chunks', () {
      final b = encodeRayBeeper('t', {
        'rows': [
          {'dur': 100, 'a': [428, 15], 'drum': 2},
        ],
      });
      // 148 units -> 63 + 63 + 22; drum only on the first chunk
      expect(b[6], (63 << 2) | 2);
      expect(b[9], 63 << 2);
      expect(b[12], 22 << 2);
      expect(b[13], 147); // counter repeats on every chunk
      expect(b[15], 0xFF);
    });

    test('loop points at the emitted row for the .ray loop row', () {
      final b = encodeRayBeeper('t', {
        'rows': [
          {'dur': 100, 'a': [428, 15]}, // expands to 3 rows
          {'dur': 4, 'a': [428, 15]},
        ],
        'loop': 1,
      });
      // intro = 3 rows + ff -> 10 bytes; loopPat at 8+10=18
      expect(b.sublist(0, 8), [8, 0, 18, 0, 0, 0, 2, 0]);
    });
  });

  group('encodeRntZx / encodeRntCpc', () {
    test('counter converts to AY period at the target clock', () {
      const n = 26;
      final c = antPeriodTable[n];
      final zx = encodeRntZx('t', {
        'rows': [
          {'n1': n},
        ],
      });
      final cpc = encodeRntCpc('t', {
        'rows': [
          {'n1': n},
        ],
      });
      // row0: dur, then A-period lo/hi
      expect(zx[1] | (zx[2] << 8), (c * 92 * 1.7734 / 56).round());
      expect(cpc[1] | (cpc[2] << 8), (c * 92 / 56).round());
    });
  });

  group('encodeRayCpc', () {
    test('periods rescale to the 1MHz CPC clock keeping pitch', () {
      final b = encodeRayCpc('ay', {
        'rows': [
          {'dur': 3, 'a': [428, 15]},
        ],
      });
      // f = 1773400/(16*428) = 259 Hz -> CPC period = 1e6/(16*259) = 241
      expect(b[1] | (b[2] << 8), (428 / 1.7734).round());
    });
  });

  group('encodeRayCbm', () {
    test('AY rows become SID voice/freq/ctrl/pw/vol rows', () {
      final b = encodeRayCbm('ay', {
        'rows': [
          {'dur': 3, 'a': [428, 15], 'mixer': 62}, // tone A only
        ],
        'loop': -1,
      });
      expect(b.length, 13 + 3);
      expect(b[0], 3); // dur
      // AY 428 @1.7734MHz -> SID reg 0x113a; pulse+gate ctrl
      expect(b.sublist(1, 4), [0x3a, 0x11, 0x41]);
      expect(b.sublist(4, 10), List.filled(6, 0)); // v2/v3 silent
      expect(b.sublist(10, 12), [0x00, 0x08]); // default pw $800
      expect(b[12], 15); // master vol
      expect(b.sublist(13, 16), [0, 0xFF, 0xFF]); // end, stop
    });

    test('"wave" picks the voice waveform; "pw" sets pulse width', () {
      final b = encodeRayCbm('ay', {
        'rows': [
          {
            'dur': 3,
            'a': [428, 15],
            'b': [428, 15],
            'c': [428, 15],
            'wave': ['saw', 'tri', 'off'],
            'pw': 1024,
          },
        ],
        'loop': -1,
      });
      expect(b[3], 0x21); // v1 gate+saw
      expect(b[6], 0x11); // v2 gate+tri
      expect(b[9], 0x00); // v3 "off" -> ctrl 0
      expect(b.sublist(10, 12), [0x00, 0x04]); // pw $400
    });

    test('unknown wave names fall back to the auto mapping', () {
      final b = encodeRayCbm('ay', {
        'rows': [
          {
            'dur': 3,
            'a': [428, 15],
            'mixer': 62,
            'wave': ['wobble'],
          },
        ],
      });
      expect(b[3], 0x41); // still gate+pulse
    });
  });
}
