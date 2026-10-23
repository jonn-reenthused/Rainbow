import 'dart:typed_data';

import 'package:rainbow_assets/rainbow_assets.dart';
import 'package:test/test.dart';

/// Build a minimal valid .mod: 1 pattern, given 4-channel cells.
Uint8List makeMod(List<List<List<int>>> cells,
    {int songLen = 1, List<int>? order, List<int>? vols}) {
  final b = Uint8List(1084 + 64 * 4 * 4);
  // title
  final t = 'TEST'.codeUnits;
  for (var i = 0; i < t.length; i++) {
    b[i] = t[i];
  }
  // sample volumes
  final v = vols ?? List<int>.filled(31, 64);
  for (var i = 0; i < 31; i++) {
    b[20 + i * 30 + 25] = v[i];
  }
  b[950] = songLen;
  final ord = order ?? List<int>.filled(128, 0);
  for (var i = 0; i < 128; i++) {
    b[952 + i] = ord[i];
  }
  b.setRange(1080, 1084, 'M.K.'.codeUnits);
  // cells: list of rows, each row = list of 4 cells [period,sample,fx,param]
  for (var r = 0; r < cells.length && r < 64; r++) {
    for (var ch = 0; ch < 4; ch++) {
      final c = r < cells.length && ch < cells[r].length
          ? cells[r][ch]
          : const [0, 0, 0, 0];
      final o = 1084 + (r * 4 + ch) * 4;
      b[o] = ((c[1] & 0xF0) | (c[0] >> 8)) & 0xFF;
      b[o + 1] = c[0] & 0xFF;
      b[o + 2] = (((c[1] & 0x0F) << 4) | c[2]) & 0xFF;
      b[o + 3] = c[3] & 0xFF;
    }
  }
  return b;
}

void main() {
  group('modToRay', () {
    test('note converts amiga period to AY period', () {
      // C-2 in MOD = period 428 -> AY ~ 428/32 = 13
      final m = makeMod([
        [
          [428, 1, 0, 0],
          [0, 0, 0, 0],
          [0, 0, 0, 0],
          [0, 0, 0, 0]
        ],
      ]);
      final r = modToRay(m);
      final row = (r.json['rows'] as List)[0] as List;
      expect(row[1] | (row[2] << 8), modPeriodToAy(428));
      expect(row[9], 15); // vol A = sample vol 64>>2 = 15... 64>>2=16 clamp15
      expect(row[10], 0); // ch B silent
      expect(row[8], 0x38); // mixer tones on
      expect(row[0], 6); // default speed
    });

    test('speed effect F06 stays default; F03 slows rows', () {
      final m = makeMod([
        [
          [428, 1, 0x0F, 3],
          [0, 0, 0, 0],
          [0, 0, 0, 0],
          [0, 0, 0, 0]
        ],
        [
          [428, 1, 0, 0],
          [0, 0, 0, 0],
          [0, 0, 0, 0],
          [0, 0, 0, 0]
        ],
      ]);
      final r = modToRay(m);
      expect((r.json['rows'] as List)[0][0], 3);
      expect((r.json['rows'] as List)[1][0], 3); // sticky
    });

    test('rejects non-mod data', () {
      expect(
          () => modToRay(Uint8List(100)), throwsA(isA<ModFormatException>()));
      final m = makeMod([]);
      m.setRange(1080, 1084, 'XXXX'.codeUnits);
      expect(() => modToRay(m), throwsA(isA<ModFormatException>()));
    });

    test('ch4 merge: ch4 note lands on C only when C has no new note', () {
      final m = makeMod([
        // row 0: ch4 plays a note, ch3 empty -> merged to AY ch C
        [
          [428, 1, 0, 0],
          [0, 0, 0, 0],
          [0, 0, 0, 0],
          [214, 1, 0, 0]
        ],
        // row 1: both ch3 and ch4 play -> ch3 wins
        [
          [428, 1, 0, 0],
          [0, 0, 0, 0],
          [856, 1, 0, 0],
          [214, 1, 0, 0]
        ],
      ]);
      final r = modToRay(m, ch4: ModCh4Mode.merge);
      final rows = r.json['rows'] as List;
      expect(rows[0][5] | (rows[0][6] << 8), modPeriodToAy(214));
      expect(rows[1][5] | (rows[1][6] << 8), modPeriodToAy(856));
      // default drop mode keeps ch3 and ignores ch4
      final r2 = modToRay(m);
      expect(
          (r2.json['rows'] as List)[0][5] |
              ((r2.json['rows'] as List)[0][6] << 8),
          0);
      expect(r.report.any((s) => s.contains('merged')), isTrue);
    });

    test('unsupported effects are reported not fatal', () {
      final m = makeMod([
        [
          [428, 1, 0x01, 0x20], // portamento up
          [0, 0, 0, 0],
          [0, 0, 0, 0],
          [0, 0, 0, 0]
        ],
      ]);
      final r = modToRay(m);
      expect(r.report.any((s) => s.contains('dropped')), isTrue);
      expect(r.report.any((s) => s.contains('channel 4')), isTrue);
    });
  });
}
