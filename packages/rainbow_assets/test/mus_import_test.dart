import 'dart:typed_data';

import 'package:rainbow_assets/rainbow_assets.dart';
import 'package:test/test.dart';

/// Build a synthetic .mus: load addr, three voice lengths, voice data
/// (each stream ends with HLT 01 4F), then a title line.
Uint8List mus(List<List<int>> voices, {String title = 'TEST'}) {
  final out = <int>[0x00, 0x80];
  for (final v in voices) {
    out.addAll([v.length & 0xFF, v.length >> 8]);
  }
  for (final v in voices) {
    out.addAll(v);
  }
  out.addAll(title.codeUnits);
  out.add(0);
  return Uint8List.fromList(out);
}

const _hlt = [0x01, 0x4F];
const _quarter = 0x10; // duration code 100 = quarter note
const _c4 = 0x99; // natural, octave 4, C
const _a2 = 0xAE; // natural, octave 2, A

void main() {
  group('musToRay', () {
    test('parses voices, notes and rests into frame rows', () {
      // v1: C-4 quarter, rest quarter, HLT — others empty
      final r = musToRay(mus([
        [_quarter, _c4, _quarter, 0x98, ..._hlt],
        _hlt,
        _hlt,
      ]));
      final rows = r.json['rows'] as List;
      // 120 qpm default: quarter = 16 units * 1.5625 = 25 frames
      expect(rows.length, 2);
      expect(rows[0]['dur'], 25);
      expect(rows[0]['a'][1], 15);
      expect(rows[0]['a'][0], closeTo(424, 2)); // C-4 -> AY period
      expect(rows[1]['a'], [0, 0]); // rest
    });

    test('TEM on voice 1 applies globally', () {
      final r = musToRay(mus([
        [0x06, 0x00, _quarter, _c4, ..._hlt], // TEM 0 -> 56 qpm
        _hlt,
        [_quarter, _a2, ..._hlt],
      ]));
      final rows = r.json['rows'] as List;
      // 14400 ~/ 256 = 56 qpm -> 16 * 187.5/56 = 53.57 -> ~54 frames
      expect(rows[0]['dur'], inInclusiveRange(52, 55));
      // v3 inherits the same tempo -> same row length
      expect(rows[0]['c'][0], closeTo(1008, 4)); // A-2 = 110 Hz
    });

    test('WAV, P-W and VOL map to wave/pw/vol keys', () {
      final r = musToRay(mus([
        [0x01, 0x87, 0x82, 0x00, 0x01, 0xAE, _quarter, _c4, ..._hlt],
        _hlt,
        _hlt,
      ]));
      final row = r.json['rows'][0];
      expect(row['wave'], [0x40, 0, 0]); // WAV 100 -> pulse
      expect(row['pw'], 0x800);
      expect(row['vol'], 10); // VOL A -> master volume 10
    });

    test('CAL expands a measure inline', () {
      final r = musToRay(mus([
        [
          0x1E, 0x00, // MS# 0
          _quarter, _c4,
          0x1E, 0x01, // MS# 1
          _quarter, _a2,
          0x1E, 0x02, // MS# 2
          0x01, 0x12, // CAL 1
          0x1E, 0x03, // MS# 3
          ..._hlt,
        ],
        _hlt,
        _hlt,
      ]));
      final rows = r.json['rows'] as List;
      // measure 1's A-2 plays twice (once inline, once via CAL) — the
      // identical notes merge into one 50-frame row
      expect(rows.length, 2);
      expect(rows[1]['dur'], 50);
    });

    test('TPS transposes following notes', () {
      final r = musToRay(mus([
        [
          _quarter, _c4,
          0xA6, 0x0C, // TPS +12
          _quarter, _c4,
          ..._hlt,
        ],
        _hlt,
        _hlt,
      ]));
      final rows = r.json['rows'] as List;
      // C-5 is roughly half the C-4 period
      expect(rows[1]['a'][0], closeTo(rows[0]['a'][0] / 2, 3));
    });

    test('reports skipped commands and the title', () {
      final r = musToRay(mus([
        [0x01, 0x1B, _quarter, _c4, ..._hlt], // FLT YES -> fx skip
        _hlt,
        _hlt,
      ], title: 'CANON'));
      expect(r.json['source'], 'CANON');
      expect(r.report.join(' '), contains('skipped'));
    });

    test('rejects truncated files', () {
      expect(() => musToRay(Uint8List(4)),
          throwsA(isA<ModFormatException>()));
      expect(
          () => musToRay(
              Uint8List.fromList([0, 0, 0xFF, 0x7F, 0, 0, 0, 0])),
          throwsA(isA<ModFormatException>()));
    });
  });
}
