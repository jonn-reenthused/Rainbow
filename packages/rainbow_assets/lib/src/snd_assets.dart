import 'dart:typed_data';

import 'gfx_assets.dart' show AssetFormatException;

/// Encoders for Rainbow sound assets (.rnt / .rsf / .ray JSON files).
///
/// Runtime binary layouts (read by rbt_ant.asm / rbt_sfx.asm / rbt_ay.asm):
///
/// Beeper music (.rnt) — AntEater engine format (all order entries are
/// offsets from asset base; the engine relocates at play time):
///   order table:
///     defw intro_pattern_off
///     defw loop_pattern_off   ; played once, then...
///     defw 0                  ; end-of-order marker
///     defw 2                  ; ...loop back to order slot at offset 2
///                             ; (defw 0 here = stop instead)
///   patterns: rows of 3 bytes, terminated by defb #ff
///     defb (drum & 3) | (speed << 2), ch1_counter, ch2_counter
///   (counter 0 = silent; speed sticky at 1..63; drum 0..4)
///
/// Beeper SFX (.rsf):
///   steps of 3 bytes: defb len, period, slide (signed)
///   len = toggle iterations, period += slide each iteration; len 0 ends.
///
/// AY music (.ray):
///   rows of 15 bytes: defb dur, then AY regs r0..r13
///     (r13 = env shape; 0xFF = leave unchanged)
///   terminated by defb 0 (dur), defw loop_addr (0 = stop + silence)

/// AntEater note->counter table. note index 0/1 = rest, 2..97 =
/// C..B across 8 octaves (counter = cpuClock/(92Hz-loop) / freq,
/// freq = C7..B7 base / (32 >> octave)); 1tracker-compatible.
final List<int> antPeriodTable = () {
  const freq = [
    2093.0, 2217.4, 2349.2, 2489.0, 2637.0, 2793.8,
    2960.0, 3136.0, 3322.4, 3520.0, 3729.2, 3951.0
  ];
  final t = List<int>.filled(98, 0);
  var div = 32.0;
  for (var oct = 0; oct < 8; oct++) {
    for (var n = 0; n < 12; n++) {
      var p = (3500000.0 / 92.0) / (freq[n] / div);
      final pi = p.round();
      t[2 + oct * 12 + n] = (pi <= 1 || pi > 255) ? 0 : pi;
    }
    div /= 2.0;
  }
  return t;
}();

/// Note name helpers for the editor/importer: index 2 = C of the
/// lowest octave ("C-2" shown to the user), each +12 = octave up.
int antNoteIndex(int octave, int semitone) => 2 + octave * 12 + semitone;

/// Encode an AntEater beeper song (.rnt).
///
/// JSON:
/// ```
/// {"type":"rnt","speed":6,"loop":-1,
///  "rows":[{"spd":0,"n1":0,"d1":0,"n2":0,"d2":0,"dr":0}, ...]}
/// ```
/// `speed` = default row speed (1..63); `spd` per row overrides
/// (sticky). `n1`/`n2` = period-table index (0 = rest); `d1`/`d2` =
/// detune 0..9 (subtracted); `dr` = drum 0..4. `loop` = row index to
/// loop back to, or -1/none for play-once-then-silence.
Uint8List encodeRnt(String name, Map<String, dynamic> json) {
  final rows = (json['rows'] as List?)?.cast<Map<String, dynamic>>();
  if (rows == null || rows.isEmpty) {
    throw AssetFormatException(name, 'missing rows');
  }
  var speed = (json['speed'] as int? ?? 6).clamp(1, 63);
  var loop = json['loop'] as int? ?? -1;
  if (loop >= rows.length) loop = -1;

  int counter(int n, int d) {
    if (n <= 0 || n >= antPeriodTable.length) return 0;
    final v = antPeriodTable[n] - d;
    return v.clamp(0, 255);
  }

  List<List<int>> pattern(int from, int to) {
    final out = <List<int>>[];
    var spd = speed;
    for (var i = from; i < to; i++) {
      final r = rows[i];
      final rs = r['spd'] as int? ?? 0;
      if (rs > 0) spd = rs.clamp(1, 63);
      final dr = (r['dr'] as int? ?? 0).clamp(0, 4);
      out.add([
        ((dr & 3) | (spd << 2)) & 0xFF,
        counter(r['n1'] as int? ?? 0, r['d1'] as int? ?? 0),
        counter(r['n2'] as int? ?? 0, r['d2'] as int? ?? 0),
      ]);
    }
    return out;
  }

  // spd overrides do not carry across the intro/loop split: the loop
  // pattern re-encodes from the default speed, as before.
  return _rntWrap(pattern(0, loop < 0 ? rows.length : loop),
      loop < 0 ? null : pattern(loop, rows.length));
}

/// Wrap encoded 3-byte AntEater rows in the engine's order-table
/// header: intro pattern, optional loop pattern, both 0xFF-terminated.
Uint8List _rntWrap(List<List<int>> intro, List<List<int>>? loopPat) {
  List<int> flat(List<List<int>> rs) => [for (final r in rs) ...r, 0xFF];
  final i = flat(intro);
  final out = BytesBuilder(copy: false);
  if (loopPat == null) {
    // order: dw intro(6); dw 0; dw 0 (no loop -> engine stops)
    out.add([6, 0, 0, 0, 0, 0]);
    out.add(i);
  } else {
    final l = flat(loopPat);
    // order: dw intro; dw loopPat; dw 0; dw 2 (loop at order slot 2)
    out.add([8, 0]);
    out.add([(8 + i.length) & 0xFF, (8 + i.length) >> 8]);
    out.add([0, 0, 2, 0]);
    out.add(i);
    out.add(l);
  }
  return out.toBytes();
}

/// Encode an AY song (.ray) for the 48K beeper: rows convert to the
/// AntEater .rnt binary so the same asset plays under `MUSIC` on all
/// ZX targets.
///
/// The two most active AY channels (tone enabled + vol>0) map to
/// AntEater's voices; the third is dropped. Any channel playing noise
/// (mixer noise bit clear + vol>0) triggers drum voice 1 — a
/// `"drum":0..4` key on a map-form row overrides the drum type.
///
/// AY periods (1.7734 MHz reference) convert straight to AntEater
/// counters: f = 1773400/(16p) Hz, counter = 3.5MHz/(92*f) ~ p*0.3432.
/// Periods whose counter falls outside 2..255 rest, matching the
/// period table's convention. `dur` is in 50 Hz frames; the 92 Hz
/// AntEater loop needs ~1.48 speed units per frame, so long rows split
/// into <=63-unit chunks (the drum only triggers on the first).
Uint8List encodeRayBeeper(String name, Map<String, dynamic> json) {
  final ay = encodeRay(name, json);
  final jrows = json['rows'] as List;
  final offs = <int>[for (var o = 0; o + 15 <= ay.length && ay[o] != 0; o += 15) o];
  bool toneOn(int r, int v) => ay[offs[r] + 8] & (1 << v) == 0;
  bool noiseOn(int r, int v) => ay[offs[r] + 8] & (1 << (v + 3)) == 0;
  int vol(int r, int v) => ay[offs[r] + 9 + v] & 0x0F;

  // channel activity: rows where the channel audibly plays a tone
  final act = [0, 0, 0];
  for (var r = 0; r < offs.length; r++) {
    for (var v = 0; v < 3; v++) {
      if (vol(r, v) > 0 && toneOn(r, v)) act[v]++;
    }
  }
  final byActivity = [0, 1, 2]
    ..sort((a, b) => act[a] != act[b] ? act[b].compareTo(act[a]) : a - b);
  final v1 = byActivity[0], v2 = byActivity[1];

  int counter(int r, int v) {
    if (vol(r, v) == 0 || !toneOn(r, v)) return 0;
    final p = ay[offs[r] + 1 + v * 2] | (ay[offs[r] + 2 + v * 2] << 8);
    if (p == 0) return 0;
    final c = (p * 0.3432352).round();
    return c <= 1 || c > 255 ? 0 : c;
  }

  final rows = <List<int>>[];
  final rowStart = <int>[];
  for (var r = 0; r < offs.length; r++) {
    rowStart.add(rows.length);
    var dr = 0;
    if (jrows.length > r && jrows[r] is Map<String, dynamic>) {
      dr = ((jrows[r] as Map)['drum'] as int? ?? 0).clamp(0, 4);
    }
    if (dr == 0) {
      for (var v = 0; v < 3; v++) {
        if (vol(r, v) > 0 && noiseOn(r, v)) {
          dr = 1;
          break;
        }
      }
    }
    var units = (ay[offs[r]] * 1.4804).round().clamp(1, 63 * 16);
    while (units > 0) {
      final spd = units > 63 ? 63 : units;
      units -= spd;
      rows.add([((dr & 3) | (spd << 2)) & 0xFF, counter(r, v1), counter(r, v2)]);
      dr = 0;
    }
  }

  final tail = offs.last + 15;
  final loopOff = ay[tail + 1] | (ay[tail + 2] << 8);
  final loop = loopOff == 0xFFFF ? -1 : rowStart[loopOff ~/ 15];
  return _rntWrap(loop < 0 ? rows : rows.sublist(0, loop),
      loop < 0 ? null : rows.sublist(loop));
}

/// Encode an AntEater beeper song (.rnt) for the CPC: emits rows in the
/// .ray format so the CPC AY player handles both formats.
Uint8List encodeRntCpc(String name, Map<String, dynamic> json) =>
    _rntToAy(name, json, 1.0);

/// Encode an AntEater beeper song (.rnt) for the 128K/+3 ZX AY player:
/// same conversion, periods scaled for the ZX's 1.7734 MHz AY clock.
Uint8List encodeRntZx(String name, Map<String, dynamic> json) =>
    _rntToAy(name, json, 1.7734);

/// Shared .rnt -> .ray row conversion. AntEater counters convert to AY
/// periods via period = counter*92*ayMHz/56 (f = 3.5MHz/(92*c) on ZX;
/// AY period = ayMHz*1MHz/(16*f), e.g. 56 for the CPC's 1 MHz clock,
/// 1.7734 for ZX). Row duration: speed s -> max(1, round(s*0.6755))
/// frames (the 92 Hz AntEater loop runs ~2/3 of a frame per unit).
Uint8List _rntToAy(String name, Map<String, dynamic> json, double ayMHz) {
  final rows = (json['rows'] as List?)?.cast<Map<String, dynamic>>();
  if (rows == null || rows.isEmpty) {
    throw AssetFormatException(name, 'missing rows');
  }
  var speed = (json['speed'] as int? ?? 6).clamp(1, 63);
  var loop = json['loop'] as int? ?? -1;
  if (loop >= rows.length) loop = -1;

  int counter(int n, int d) {
    if (n <= 0 || n >= antPeriodTable.length) return 0;
    return antPeriodTable[n] - d;
  }

  int period(int n, int d) {
    final c = counter(n, d);
    if (c <= 0) return 0;
    return (c * 92 * ayMHz / 56).round().clamp(1, 4095);
  }

  final out = BytesBuilder(copy: false);
  var spd = speed;
  for (final r in rows) {
    final rs = r['spd'] as int? ?? 0;
    if (rs > 0) spd = rs.clamp(1, 63);
    final n1 = r['n1'] as int? ?? 0;
    final n2 = r['n2'] as int? ?? 0;
    final d1 = r['d1'] as int? ?? 0;
    final d2 = r['d2'] as int? ?? 0;
    final dr = (r['dr'] as int? ?? 0).clamp(0, 4);
    final pa = period(n1, d1);
    final pb = period(n2, d2);
    final dur = (spd * 0.6755).round().clamp(1, 255);
    final mixer =
        (pa == 0 ? 1 : 0) | (pb == 0 ? 2 : 0) | 4 | 8 | 16 | (dr == 0 ? 32 : 0);
    out.add([
      dur,
      pa & 0xFF, (pa >> 8) & 0xFF, // r0,r1: tone A
      pb & 0xFF, (pb >> 8) & 0xFF, // r2,r3: tone B
      0, 0, // r4,r5: tone C (unused - drums are noise)
      dr > 0 ? (dr * 8).clamp(0, 31) : 0, // r6: noise period (5 bits)
      mixer, // r7
      pa > 0 ? 12 : 0, // r8: vol A
      pb > 0 ? 12 : 0, // r9: vol B
      dr > 0 ? 10 : 0, // r10: vol C (drum)
      0, 0, // r11,r12: env period
      0xFF, // r13: don't touch
    ]);
  }
  out.addByte(0);
  final loopAddr = loop < 0 ? 0xFFFF : loop * 15;
  out.add([loopAddr & 0xFF, (loopAddr >> 8) & 0xFF]);
  return out.toBytes();
}

/// Encode a beeper SFX (.rsf).
///
/// JSON: `{"type":"rsf","steps":[{"per":80,"len":30,"slide":-2},...]}`
/// Each step: `len` speaker toggles, waiting `per` delay units between
/// them, adding `slide` to `per` each toggle (signed -128..127).
Uint8List encodeRsf(String name, Map<String, dynamic> json) {
  final steps = (json['steps'] as List?)?.cast<Map<String, dynamic>>();
  if (steps == null || steps.isEmpty) {
    throw AssetFormatException(name, 'missing steps');
  }
  final out = BytesBuilder(copy: false);
  for (final s in steps) {
    final len = s['len'] as int? ?? 0;
    if (len <= 0 || len > 255) {
      throw AssetFormatException(name, 'step len must be 1..255');
    }
    out.addByte(len);
    out.addByte((s['per'] as int? ?? 0).clamp(0, 255));
    out.addByte((s['slide'] as int? ?? 0) & 0xFF);
  }
  out.addByte(0);
  return out.toBytes();
}

/// Encode a beeper SFX (.rsf) for the CPC AY engine (channel C).
///
/// Step format (6 bytes, read by runtime/cpc/rbt_sfx.asm):
///   defb len    ; update iterations (0 = end)
///   defb dur    ; delay units between updates (~13T each at 4 MHz)
///   defw period ; AY period in q8 fixed point (period*8)
///   defw slide  ; signed per-iteration delta, also q8
///
/// Timing model measured from runtime/zx/rbt_sfx.asm: each beeper toggle
/// costs per*16 + ~76 T @3.5 MHz (dec/jr wait loop is 16 T per unit), so a
/// full square cycle is (32*per + 152) T and f = 3.5MHz/(32*per + 152).
/// AY period for equal pitch at the CPC's 1 MHz clock:
///   (32*per + 152)/56 ~ per*0.5714 + 2.7 -> q8: (32*per + 152)*8/56.
/// dur reproduces the ZX per-iteration time (~per*18.3 + 87 T at 4 MHz)
/// minus the player's ~700 T per-step PSG write overhead.
Uint8List encodeRsfCpc(String name, Map<String, dynamic> json) {
  final steps = (json['steps'] as List?)?.cast<Map<String, dynamic>>();
  if (steps == null || steps.isEmpty) {
    throw AssetFormatException(name, 'missing steps');
  }
  final out = BytesBuilder(copy: false);
  for (final s in steps) {
    final len = s['len'] as int? ?? 0;
    if (len <= 0 || len > 255) {
      throw AssetFormatException(name, 'step len must be 1..255');
    }
    final per = (s['per'] as int? ?? 0).clamp(0, 255);
    final slide = (s['slide'] as int? ?? 0).clamp(-128, 127);
    final dur = ((per * 18.29 + 87 - 720) / 13).round().clamp(1, 255);
    final pq = ((per * 32 + 152) * 8 / 56).round().clamp(0, 32767); // q8 period
    final sq = (slide * 32 * 8 / 56).round().clamp(-32768, 32767);
    out.addByte(len);
    out.addByte(dur);
    out.addByte(pq & 0xFF);
    out.addByte((pq >> 8) & 0xFF);
    out.addByte(sq & 0xFF);
    out.addByte((sq >> 8) & 0xFF);
  }
  out.addByte(0);
  return out.toBytes();
}

/// Encode an AY song (.ray) for the CPC: same row format, but tone,
/// noise and envelope periods are rescaled for the CPC's 1 MHz AY clock
/// (ZX AY = 1.7734 MHz; f = clock/(16*period), so same-pitch periods
/// shrink by the clock ratio) so ZX-authored .ray assets keep pitch.
Uint8List encodeRayCpc(String name, Map<String, dynamic> json) {
  final zx = encodeRay(name, json); // reuse the row encoding + end marker
  const scale = 1.0 / 1.7734;
  int scaleReg(int lo, int hi, int mask) {
    final p = zx[lo] | ((zx[hi] & (mask >> 8)) << 8);
    final q = (p * scale).round().clamp(0, mask);
    zx[lo] = q & 0xFF;
    zx[hi] = (zx[hi] & ~(mask >> 8)) | ((q >> 8) & (mask >> 8));
    return q;
  }

  // Rows are 15 bytes until the 0-dur end marker.
  for (var off = 0; off + 15 <= zx.length; off += 15) {
    if (zx[off] == 0) break;
    scaleReg(off + 1, off + 2, 0xFFF); // tone A
    scaleReg(off + 3, off + 4, 0xFFF); // tone B
    scaleReg(off + 5, off + 6, 0xFFF); // tone C
    zx[off + 7] = (zx[off + 7] * scale).round().clamp(0, 31); // noise
    scaleReg(off + 12, off + 13, 0xFFFF); // envelope period
  }
  return zx;
}

/// Encode a beeper SFX (.rsf) for the C64 SID (voice 3).
///
/// Step format (6 bytes, read by runtime/c64/rbt_sfx.s):
///   defb len    ; update iterations (0 = end)
///   defb dur    ; delay units between updates (~5 cycles each @ ~1 MHz)
///   defw freq   ; SID frequency register, 16-bit
///   defw slide  ; signed per-iteration delta, 16.8 fixed point
///
/// ZX half-period = (32*per + 152) T at 3.5 MHz -> f = 3.5e6/(32*per+152)
/// Hz; SID reg = f * 2^24 / 985248 (PAL clock) =~ f * 17.029. Slide is
/// linearised at the step's initial period (freq is reciprocal in per):
/// d(reg)/d(per) = -32 * reg0 / t.
Uint8List encodeRsfCbm(String name, Map<String, dynamic> json) {
  final steps = (json['steps'] as List?)?.cast<Map<String, dynamic>>();
  if (steps == null || steps.isEmpty) {
    throw AssetFormatException(name, 'missing steps');
  }
  const k = 3.5e6 * 16777216 / 985248; // f -> SID reg
  final out = BytesBuilder(copy: false);
  for (final s in steps) {
    final len = s['len'] as int? ?? 0;
    if (len <= 0 || len > 255) {
      throw AssetFormatException(name, 'step len must be 1..255');
    }
    final per = (s['per'] as int? ?? 0).clamp(0, 255);
    final slide = (s['slide'] as int? ?? 0).clamp(-128, 127);
    final t = 32 * per + 152; // ZX half-period in T states
    final fq = (k / t).round().clamp(0, 0xFFFF);
    final sq = (-32 * fq * 256 * slide / (t * t)).round().clamp(-32768, 32767);
    // iteration wall time = t/3.5 us; delay loop is ~5.08 cycles @PAL
    final dur = (t / 17.8).round().clamp(1, 255);
    out.addByte(len);
    out.addByte(dur);
    out.addByte(fq & 0xFF);
    out.addByte((fq >> 8) & 0xFF);
    out.addByte(sq & 0xFF);
    out.addByte((sq >> 8) & 0xFF);
  }
  out.addByte(0);
  return out.toBytes();
}

/// SID waveform bits for the `.ray` `"wave"` extension key: a row may
/// name a waveform per voice — `"wave":["tri","saw","noise"]` (also
/// triangle/sawtooth/square/off). Missing or unknown entries keep the
/// automatic mapping (tone -> pulse, noise-only -> noise).
const _sidWaveBits = <String, int>{
  'tri': 0x10,
  'triangle': 0x10,
  'saw': 0x20,
  'sawtooth': 0x20,
  'pulse': 0x40,
  'square': 0x40,
  'noise': 0x80,
  'off': 0x00,
};

/// Resolve a `"wave"` entry to SID waveform bits: a name from
/// [_sidWaveBits] or a raw int (0-255) for combined waveforms, e.g.
/// `48` for tri+saw — emitted by the .mus importer.
int? _waveBitsFor(dynamic e) {
  if (e is int) return e & 0xF0;
  return _sidWaveBits[e?.toString().toLowerCase() ?? ''];
}

/// Convert one 15-byte .ray row (dur + AY r0..r13) to a 13-byte SID
/// row: dur + per voice {freq lo/hi, ctrl} + shared pulse width +
/// master vol. [ayClockHz] is the AY clock the periods are authored
/// for (ZX 1.7734 MHz; the CPC and AntEater paths feed 1 MHz periods).
/// [jr] is the source JSON row (map form) supplying the optional
/// `wave`/`pw` extension keys.
///
/// AY freq = ayClock/(16*p); SID reg = f * 2^24 / 985248. AY square
/// tones map to the SID pulse wave ($41, 50% duty), a noise-only
/// channel to $81; a silent/mixed-off channel gets ctrl 0.
List<int> _ayRowToSid(List<int> r, double ayClockHz, dynamic jr) {
  final mixer = r[8];
  final wave = jr is Map<String, dynamic> ? jr['wave'] as List? : null;
  final pw = jr is Map<String, dynamic>
      ? ((jr['pw'] as int? ?? 0x800).clamp(0, 0xFFF))
      : 0x800;
  final out = <int>[r[0]];
  for (var v = 0; v < 3; v++) {
    final p = r[1 + v * 2] | (r[2 + v * 2] << 8);
    final vol = r[9 + v];
    final toneOff = (mixer >> v) & 1;
    final noiseOff = (mixer >> (v + 3)) & 1;
    final toneOn = toneOff == 0, noiseOn = noiseOff == 0;
    var freq = 0, ctrl = 0;
    final wv = wave != null && v < wave.length
        ? _waveBitsFor(wave[v])
        : null;
    if (vol > 0 && (toneOn || noiseOn)) {
      // channel plays: pick the period — noise voice tracks r6 instead
      final np = toneOn ? p : (r[7] & 0x1F);
      final f = ayClockHz / (16 * (np <= 0 ? 1 : np));
      freq = (f * 16777216 / 985248).round().clamp(0, 0xFFFF);
      ctrl = wv == 0
          ? 0 // "off": gate off, voice silent
          : 0x01 | (wv ?? ((noiseOn && !toneOn) ? 0x80 : 0x40));
    }
    out.add(freq & 0xFF);
    out.add((freq >> 8) & 0xFF);
    out.add(ctrl);
  }
  out.add(pw & 0xFF);
  out.add(pw >> 8);
  out.add(jr is Map<String, dynamic>
      ? ((jr['vol'] as int? ?? 15).clamp(0, 15))
      : 15); // master volume
  return out;
}

/// Shared tail for the cbm song encoders: convert a stream of 15-byte
/// AY rows (0-dur end marker + 2-byte loop offset in row units) into
/// the 13-byte SID row format, re-pointing the loop offset. [jrows] is
/// the source JSON row list, aligned 1:1 with the encoded rows — map
/// entries may carry the `wave`/`pw` extension keys.
Uint8List _ayStreamToSid(Uint8List ay, double ayClockHz, [List? jrows]) {
  final out = BytesBuilder(copy: false);
  var off = 0, i = 0;
  for (; off + 15 <= ay.length && ay[off] != 0; off += 15, i++) {
    out.add(_ayRowToSid(ay.sublist(off, off + 15), ayClockHz,
        jrows != null && i < jrows.length ? jrows[i] : null));
  }
  out.addByte(0);
  final loopOff = off + 2 < ay.length ? ay[off + 1] | (ay[off + 2] << 8) : 0xFFFF;
  final loop = loopOff == 0xFFFF ? 0xFFFF : (loopOff ~/ 15) * 13;
  out.add([loop & 0xFF, (loop >> 8) & 0xFF]);
  return out.toBytes();
}

/// Encode an AY song (.ray) for the C64: rows become SID voice/freq/
/// ctrl writes; ZX-clock AY periods rescale to SID frequency regs.
/// Map-form rows may carry `"wave"`/`"pw"` extension keys — per-voice
/// waveform names (tri/saw/pulse/noise/off) and a shared 12-bit pulse
/// width — honoured by the SID encoder and ignored elsewhere.
Uint8List encodeRayCbm(String name, Map<String, dynamic> json) =>
    _ayStreamToSid(encodeRay(name, json), 1773400, json['rows'] as List?);

/// Encode an AntEater song (.rnt) for the C64: reuses the CPC AY-row
/// conversion (1 MHz periods) then maps those rows to SID regs.
Uint8List encodeRntCbm(String name, Map<String, dynamic> json) =>
    _ayStreamToSid(encodeRntCpc(name, json), 1000000);

/// Encode an AY song (.ray): one row = `dur` + the 14 AY registers.
///
/// Row forms (JSON):
/// - list: `[dur, r0, r1, ..., r13]` (r13 = 255 means "don't touch")
/// - map: `{"dur":d,"a":[period,vol],"b":[period,vol],"c":[period,vol],
///   "noise":n,"mixer":m,"env":[lo,hi],"eshape":s}` — missing channels
///   keep silence (vol 0, tone on in mixer must be set explicitly).
///
/// `loop` = row index to loop back to, -1 = stop and silence
/// (encoded as offset #FFFF so loop=0 can return to the first row).
Uint8List encodeRay(String name, Map<String, dynamic> json) {
  final rows = json['rows'] as List?;
  if (rows == null || rows.isEmpty) {
    throw AssetFormatException(name, 'missing rows');
  }
  var loop = json['loop'] as int? ?? -1;
  if (loop >= rows.length) loop = -1;

  List<int> row(dynamic r) {
    if (r is List) {
      if (r.length != 15) {
        throw AssetFormatException(
            name, 'list rows need 15 values (dur + r0..r13)');
      }
      return r.map((v) => (v as int) & 0xFF).toList();
    }
    if (r is Map<String, dynamic>) {
      int per(String ch) => ((r[ch] as List?)?[0] as int? ?? 0);
      int vol(String ch) => ((r[ch] as List?)?[1] as int? ?? 0);
      final env = (r['env'] as List?)?.cast<int>() ?? [0, 0];
      return [
        (r['dur'] as int? ?? 0) & 0xFF,
        per('a') & 0xFF, (per('a') >> 8) & 0xFF,
        per('b') & 0xFF, (per('b') >> 8) & 0xFF,
        per('c') & 0xFF, (per('c') >> 8) & 0xFF,
        (r['noise'] as int? ?? 0) & 0xFF,
        (r['mixer'] as int? ?? 0x38) & 0xFF, // default: tones enabled
        vol('a') & 0xFF, vol('b') & 0xFF, vol('c') & 0xFF,
        env[0] & 0xFF, env[1] & 0xFF,
        (r['eshape'] as int? ?? 0xFF) & 0xFF,
      ];
    }
    throw AssetFormatException(name, 'row must be a list or map');
  }

  final out = BytesBuilder(copy: false);
  for (final r in rows) {
    out.add(row(r));
  }
  out.addByte(0); // dur = 0 -> end marker
  final loopAddr = loop < 0 ? 0xFFFF : loop * 15;
  out.add([loopAddr & 0xFF, (loopAddr >> 8) & 0xFF]);
  return out.toBytes();
}
