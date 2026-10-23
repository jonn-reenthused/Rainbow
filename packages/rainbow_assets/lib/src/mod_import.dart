import 'dart:typed_data';

/// How to treat MOD channel 4, which has no direct AY channel.
enum ModCh4Mode {
  /// Drop channel 4 entirely.
  drop,

  /// Merge channel 4 into AY channel C on rows where channel C itself
  /// starts no new note (period == 0). A sustained note on C can still
  /// be cut by an incoming ch4 note.
  merge,
}

/// ProTracker .mod -> Rainbow .ray (AY) converter.
///
/// Maps MOD channels 1-3 to AY channels A-C (channel 4 is dropped or
/// merged into C — see [ModCh4Mode]). Amiga period -> AY period: AY tone
/// freq = 1773400/(16*tp) vs PAL Amiga 7093789/(2*p) => tp ~= p / 32.06.
///
/// Supported effects: 0xC set volume, 0xF set speed, 0xB position jump,
/// 0xD pattern break. Others are dropped and listed in the report.
class ModImportResult {
  ModImportResult(this.json, this.report);
  final Map<String, dynamic> json;
  final List<String> report;
}

class ModFormatException implements Exception {
  ModFormatException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Amiga period -> AY tone period (12-bit).
int modPeriodToAy(int amigaPeriod) {
  if (amigaPeriod <= 0) return 0;
  final tp = (amigaPeriod * 3546800.0 / 113700624.0).round();
  return tp.clamp(1, 4095);
}

ModImportResult modToRay(Uint8List bytes, {ModCh4Mode ch4 = ModCh4Mode.drop}) {
  final report = <String>[];
  if (bytes.length < 1084) {
    throw ModFormatException('file too small for a .mod header');
  }
  final magic = String.fromCharCodes(bytes.sublist(1080, 1084));
  const magics = {'M.K.': 4, 'M!K!': 4, 'FLT4': 4, '4CHN': 4};
  final channels = magics[magic];
  if (channels == null) {
    throw ModFormatException(
        'unsupported module magic "$magic" (expected M.K./M!K!/FLT4/4CHN)');
  }
  final title = String.fromCharCodes(
      bytes.sublist(0, 20).where((b) => b >= 32 && b < 127)).trim();

  // 31 sample headers at offset 20, 30 bytes each; volume byte at +25.
  final volumes = List<int>.generate(31, (i) => bytes[20 + i * 30 + 25]);

  final songLen = bytes[950] & 0x7F;
  final order = bytes.sublist(952, 952 + 128);
  final npats = order.sublist(0, songLen).fold(0, (a, b) => a > b ? a : b) + 1;
  const patBase = 1084;
  final patSize = 64 * channels * 4;
  if (bytes.length < patBase + npats * patSize) {
    throw ModFormatException('truncated: pattern data missing');
  }

  (int period, int sample, int eff, int param) cell(int pat, int row, int ch) {
    final o = patBase + (pat * 64 + row) * channels * 4 + ch * 4;
    return (
      ((bytes[o] & 0x0F) << 8) | bytes[o + 1],
      (bytes[o] & 0xF0) | (bytes[o + 2] >> 4),
      bytes[o + 2] & 0x0F,
      bytes[o + 3],
    );
  }

  // Flatten the order list into a row stream (Bxx/Dxx handled in-order;
  // the emitted row list is the literal play sequence).
  final rows = <List<int>>[];
  var speed = 6;
  final lastVol = [0, 0, 0];
  final lastPer = [0, 0, 0];
  const loopRow = 0; // MODs loop the whole song (restart position)

  var pos = 0;
  var guard = 0;
  while (pos >= 0 && pos < songLen && guard++ < 1000) {
    final pat = order[pos];
    var nextPos = pos + 1;
    var row = 0;
    while (row < 64) {
      final c0 = cell(pat, row, 0);
      final c1 = cell(pat, row, 1);
      var c2 = cell(pat, row, 2);
      final c3 = channels > 3 ? cell(pat, row, 3) : (0, 0, 0, 0);
      // ch4 merge: ch4's note takes AY channel C when C starts nothing
      // new this row.
      if (ch4 == ModCh4Mode.merge && c3.$1 != 0 && c2.$1 == 0) {
        c2 = c3;
      }
      final cells = [c0, c1, c2, c3];

      // Fxx sets speed (row duration in ticks); Bxx/Dxx change flow.
      var broke = false;
      for (var ci = 0; ci < channels; ci++) {
        final (period, sample, e, x) = cells[ci];
        switch (e) {
          case 0x0F:
            if (x == 0) break;
            if (x <= 32) {
              speed = x;
            } else {
              report.add(
                  'pos $pos pat $pat row $row: tempo F${x.toRadixString(16)} '
                  'dropped (only tick speeds 1-32 supported)');
            }
          case 0x0B:
            nextPos = x;
            row = 64;
            broke = true;
          case 0x0D:
            nextPos = pos + 1;
            row = 64; // row x within next pattern not modelled
            broke = true;
          case 0x00 || 0x0C:
            break; // arpeggio-as-plain-note / set volume handled below
          default:
            report.add('pos $pos pat $pat row $row ch${'ABCD'[ci]}: '
                'effect ${e.toRadixString(16).toUpperCase()}'
                '${x.toRadixString(16).padLeft(2, '0').toUpperCase()} dropped');
        }
      }

      final per = [0, 0, 0];
      final vol = [0, 0, 0];
      for (var ci = 0; ci < 3; ci++) {
        final (period, sample, e, x) = cells[ci];
        if (period != 0) {
          per[ci] = modPeriodToAy(period);
          lastPer[ci] = per[ci];
        } else {
          per[ci] = lastPer[ci];
        }
        var v = lastVol[ci];
        if (sample > 0) v = volumes[(sample - 1) & 31] >> 2;
        if (e == 0x0C) v = (x > 64 ? 64 : x) >> 2;
        v = v.clamp(0, 15);
        // a channel that has never played a note stays silent
        if (per[ci] == 0) v = 0;
        vol[ci] = v;
        lastVol[ci] = v;
      }

      rows.add([
        speed,
        per[0] & 0xFF, per[0] >> 8,
        per[1] & 0xFF, per[1] >> 8,
        per[2] & 0xFF, per[2] >> 8,
        0, 0x38, // noise, mixer: tones on
        vol[0], vol[1], vol[2],
        0, 0, 0xFF, // env lo/hi, shape = don't touch
      ]);
      if (broke) break;
      row++;
    }
    pos = nextPos;
  }
  if (guard >= 1000) {
    report.add('order jump loop detected; truncated');
  }

  if (channels >= 4) {
    report.add(ch4 == ModCh4Mode.merge
        ? 'MOD channel 4 merged into channel C (used when C has no new '
            'note; may cut sustained notes)'
        : 'MOD channel 4 dropped (AY has 3 tone channels)');
  }
  report.insert(
      0,
      '"$title" ${songLen} positions, $npats patterns '
      '-> ${rows.length} AY rows');

  return ModImportResult(
      {'type': 'ray', 'loop': loopRow, 'rows': rows, 'source': title}, report);
}
