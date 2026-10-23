/// Compute! Sidplayer (.mus) -> Rainbow .ray converter.
///
/// .mus layout: dw load address, dw length for each of 3 voices, then
/// the three voice streams of two-byte pairs ending in HLT (01 4F),
/// then PETSCII title/credit lines. Each pair is a note (byte1 low two
/// bits = 00) or a command. Note byte1 packs tie/dot/duration bits —
/// durations are in 64ths of a whole note, tempo from TEM (quarters
/// per minute = 14400/value). Commands map to SID registers:
/// WAV -> "wave", P-W -> "pw", VOL -> channel volume, TPS -> transpose.
/// Instrument/fx commands with no .ray home (ADSR, vibrato, filter,
/// portamento, detune, repeats) are counted in the report.
///
/// CAL n plays measure n as a subroutine (MS# nE marks measure starts);
/// calls are expanded inline so the output stays a flat row list.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'mod_import.dart';

/// One frame-quantised voice segment: constant pitch/vol/wave/pw over
/// [t0, t1) in 50 Hz frames.
class _Seg {
  _Seg(this.t0, this.t1, this.per, this.vol, this.waveBits, this.pw);
  double t0, t1;
  int per, vol, waveBits, pw;
}

/// Sidplayer WAV command value -> SID waveform bits.
const _sidWave = [0x80, 0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x70];

/// Duration codes (byte1 bits 4-2) in 64ths of a whole note; code 1 is
/// the unused "utility" slot, treated as a 64th.
const _durUnits = [1.0, 1.0, 64.0, 32.0, 16.0, 8.0, 4.0, 2.0];

/// Convert a Sidplayer .mus file to .ray JSON (see mus_import.dart
/// header). [bytes] is the whole file including the load address.
ModImportResult musToRay(Uint8List bytes) {
  final report = <String>[];
  if (bytes.length < 8) {
    throw ModFormatException('file too small for a .mus header');
  }
  final l1 = bytes[2] | (bytes[3] << 8);
  final l2 = bytes[4] | (bytes[5] << 8);
  final l3 = bytes[6] | (bytes[7] << 8);
  if (8 + l1 + l2 + l3 > bytes.length) {
    throw ModFormatException('voice lengths exceed file size');
  }
  final voices = [
    bytes.sublist(8, 8 + l1),
    bytes.sublist(8 + l1, 8 + l1 + l2),
    bytes.sublist(8 + l1 + l2, 8 + l1 + l2 + l3),
  ];
  final text = String.fromCharCodes(
          bytes.sublist(8 + l1 + l2 + l3).where((b) => b >= 32 && b < 127))
      .trim();
  final title = RegExp(r'\S.*').firstMatch(text)?.group(0) ?? '';

  final skipped = <String, int>{};
  void skip(String n) => skipped[n] = (skipped[n] ?? 0) + 1;

  // TEM is a global setting: voices without one inherit the first TEM
  // found (usually voice 1's). Quarter notes/min = 14400 ~/ value.
  var defQpm = 120;
  outer:
  for (final v in voices) {
    for (var i = 0; i + 1 < v.length; i += 2) {
      if (v[i] == 0x06) {
        final n = v[i + 1] == 0 ? 256 : v[i + 1];
        defQpm = 14400 ~/ n;
        break outer;
      }
    }
  }
  if (defQpm == 0) defQpm = 56;

  // VOL writes the SID master volume — collect timestamped changes
  // across all voices, applied to each row's "vol" extension key.
  final volEvents = <({double t, int vol})>[];

  List<_Seg> convertVoice(Uint8List v) {
    // measure numbers -> byte offset in the stream, for CAL calls
    final measures = <int, int>{};
    final ends = <int>[];
    for (var i = 0; i + 1 < v.length; i += 2) {
      if ((v[i] & 0x3F) == 0x1E) {
        measures[((v[i] >> 6) << 8) | v[i + 1]] = i;
      } else if (v[i] == 1 && v[i + 1] == 0x2F) {
        ends.add(i);
      }
    }

    final segs = <_Seg>[];
    var t = 0.0; // cursor, frames
    var f64 = 187.5 / defQpm; // frames per 64th of a whole note
    var waveBits = 0x40, pw = 0x800, transpose = 0;

    int ayPeriod(int midi) {
      final hz = 440.0 * math.pow(2, (midi - 69) / 12);
      return (1773400 / (16 * hz)).round().clamp(1, 4095);
    }

    /// Split the open note segment at [t] so state changes (wave, vol,
    /// pw) apply mid-note, mirroring the SID player's live register
    /// writes.
    void ctrl() {
      if (segs.isNotEmpty && segs.last.t1 > t) {
        final old = segs.last;
        final end = old.t1;
        old.t1 = t;
        segs.add(_Seg(t, end, old.per, 15, waveBits, pw));
      }
    }

    void seg(int midi, double d64) {
      final per = midi == 0 ? 0 : ayPeriod(midi + transpose);
      segs.add(_Seg(t, t + d64 * f64, per, midi == 0 ? 0 : 15, waveBits, pw));
      t += d64 * f64;
    }

    void emit(int from, int to, int depth) {
      if (depth > 8) return;
      for (var i = from; i + 1 < to; i += 2) {
        final b1 = v[i], b2 = v[i + 1];
        if (b1 & 3 == 0) {
          if (b1 == 0) {
            // absolute pitch: byte2 is a raw pitch index
            skip('APITCH');
            seg(b2, 1);
            continue;
          }
          var d = _durUnits[(b1 >> 2) & 7];
          if (((b1 >> 2) & 7) == 1) {
            skip('UDUR'); // utility voice/duration codes
          }
          if ((b1 & 0xBC) == 0xB0) {
            d = 2 / 3; // triplet-64th special case
          } else if (b1 & 0x80 != 0 && b1 & 0x20 == 0) {
            d *= 2 / 3; // triplet
          } else if (b1 & 0x20 != 0) {
            d *= b1 & 0x80 != 0 ? 1.75 : 1.5; // double/single dot
          }
          final n = b2 & 7;
          if (n == 0) {
            seg(0, d); // rest
            continue;
          }
          const semi = [0, 2, 4, 5, 7, 9, 11];
          var s = semi[n - 1];
          switch (b2 >> 6) {
            case 1:
              s += 1; // sharp
            case 3:
              s -= 1; // flat
            case 0:
              // double sharp C D F G / double flat A B E
              s += (n == 3 || n >= 6) ? -2 : 2;
          }
          seg((7 - ((b2 >> 3) & 7) + 1) * 12 + s, d);
          continue;
        }
        if (b1 == 1) {
          switch (b2 & 0x0F) {
            case 0x0:
              skip('DCY');
            case 0x1:
              skip('RUP');
            case 0x2:
              final m = measures[b2 >> 4];
              if (m == null) {
                skip('CAL?');
              } else {
                var end = to;
                for (final o in [...measures.values, ...ends]..sort()) {
                  if (o > m) {
                    end = o;
                    break;
                  }
                }
                emit(m, end, depth + 1);
              }
            case 0x3:
              skip(b2 & 0x80 != 0 ? 'DEF' : 'fx${b2.toRadixString(16)}');
            case 0x4:
              skip('ATK/SUS');
            case 0x5:
              skip('RDN/RES');
            case 0x6:
              skip('DEF');
            case 0x7:
              if (b2 & 0x10 == 0) {
                waveBits = _sidWave[(b2 >> 5) & 7];
                ctrl();
              } else {
                skip('F-M');
              }
            case 0x8:
              skip('RLS');
            case 0xA:
              skip('RES');
            case 0xB:
              skip('fx${b2.toRadixString(16)}');
            case 0xC:
              skip('cmdC');
            case 0xE:
              volEvents.add((t: t, vol: b2 >> 4)); // VOL: SID master vol
            case 0xF:
              if (b2 == 0x4F) return; // HLT
              if (b2 != 0x0F && b2 != 0x2F) skip('SRC/DST');
          }
          continue;
        }
        switch (b1 & 0x0F) {
          case 0x2:
            pw = ((b1 >> 4) << 8) | b2; // P-W pulse width
            ctrl();
          case 0x6:
            switch (b1) {
              case 0x06:
                final n = b2 == 0 ? 256 : b2;
                f64 = 187.5 / math.max(1, 14400 ~/ n);
              case 0xA6:
                // TPS: bit0 sign; +v: octaves=7-bits3..1, +bits7..4 semis;
                // -v: octaves=bits3..1, 11-bits7..4 semis
                final s = (b2 >> 4) & 0x0F;
                transpose = b2 & 1 == 0
                    ? (7 - ((b2 >> 1) & 7)) * 12 + s
                    : -((((b2 >> 1) & 7)) * 12 + (11 - s));
              default:
                skip('cmd${b1.toRadixString(16)}');
            }
          case 0xA:
            skip('DTN');
          case 0xE:
            if ((b1 & 0x3F) == 0x1E) {
              break; // MS# measure marker
            }
            if ((b1 & 0x30) == 0x30) {
              skip('JIF'); // 3E/7E/BE/FE: timing adjustment
            } else {
              skip(const {
                0x0E: 'F-C',
                0x2E: 'RTP',
                0x4E: 'HLD',
                0x6E: 'SCA',
              }[b1] ??
                  'cmd${b1.toRadixString(16)}');
            }
          default:
            if (b1 & 3 == 3) {
              skip('POR');
            } else {
              skip('cmd${b1.toRadixString(16)}');
            }
        }
      }
    }

    emit(0, v.length, 0);
    return segs;
  }

  final segs = voices.map(convertVoice).toList();
  volEvents.sort((a, b) => a.t.compareTo(b.t));

  // merge the three voice timelines onto a shared frame grid
  final total = segs
      .map((s) => s.isEmpty ? 0.0 : s.last.t1)
      .fold(0.0, (a, b) => a > b ? a : b)
      .ceil();
  final rows = <Map<String, dynamic>>[];
  var f = 0;
  while (f < total) {
    final ch = List.filled(3, 0);
    final vol = List.filled(3, 0);
    final wave = List.filled(3, 0);
    final pw = List.filled(3, 0);
    var mixer = 0;
    for (var vi = 0; vi < 3; vi++) {
      final i = _segAt(segs[vi], f + 0.001);
      if (i >= 0) {
        ch[vi] = segs[vi][i].per;
        vol[vi] = segs[vi][i].vol;
        wave[vi] = segs[vi][i].waveBits;
        pw[vi] = segs[vi][i].pw;
      }
      final toneOn = vol[vi] > 0 && wave[vi] & 0x70 != 0;
      final noiseOn = vol[vi] > 0 && wave[vi] & 0x80 != 0;
      if (!toneOn) mixer |= 1 << vi;
      if (!noiseOn) mixer |= 8 << vi;
    }
    var sharedPw = 0;
    for (var vi = 0; vi < 3; vi++) {
      if (wave[vi] & 0x40 != 0 && vol[vi] > 0) {
        sharedPw = pw[vi];
        break;
      }
    }
    var dur = 1;
    while (f + dur < total &&
        _sameFrame(segs, f + dur + 0.001, ch, vol, wave, pw)) {
      dur++;
    }
    var masterVol = 15;
    for (final e in volEvents) {
      if (e.t <= f) {
        masterVol = e.vol;
      } else {
        // a VOL change mid-row must split it
        final splitAt = e.t.ceil();
        if (splitAt > f && splitAt < f + dur) dur = splitAt - f;
        break;
      }
    }
    while (dur > 0) {
      final chunk = dur > 255 ? 255 : dur;
      rows.add({
        'dur': chunk,
        'a': [ch[0], vol[0]],
        'b': [ch[1], vol[1]],
        'c': [ch[2], vol[2]],
        'noise': 8,
        'mixer': mixer,
        if (wave.any((w) => w != 0x40)) 'wave': wave,
        if (sharedPw != 0) 'pw': sharedPw,
        if (masterVol != 15) 'vol': masterVol,
      });
      dur -= chunk;
      f += chunk;
    }
  }

  if (skipped.isNotEmpty) {
    report.add('skipped commands: '
        '${skipped.entries.map((e) => '${e.key}x${e.value}').join(', ')}');
  }
  report.add('${rows.length} rows across 3 voices');
  return ModImportResult(
      {'type': 'ray', 'loop': -1, 'rows': rows, 'source': title}, report);
}

/// Binary search for the segment covering frame [t].
int _segAt(List<_Seg> s, double t) {
  var lo = 0, hi = s.length - 1, best = -1;
  while (lo <= hi) {
    final m = (lo + hi) >> 1;
    if (s[m].t0 <= t) {
      best = m;
      lo = m + 1;
    } else {
      hi = m - 1;
    }
  }
  if (best < 0 || s[best].t1 <= t) return -1;
  return best;
}

bool _sameFrame(List<List<_Seg>> segs, double t, List<int> ch, List<int> vol,
    List<int> wave, List<int> pw) {
  for (var vi = 0; vi < 3; vi++) {
    final i = _segAt(segs[vi], t);
    if (i < 0) {
      if (ch[vi] != 0 || vol[vi] != 0) return false;
    } else {
      final s = segs[vi][i];
      if (s.per != ch[vi] || s.vol != vol[vi]) return false;
      if (s.waveBits != wave[vi] || s.pw != pw[vi]) return false;
    }
  }
  return true;
}
