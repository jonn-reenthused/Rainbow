import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:rainbow_assets/rainbow_assets.dart';

/// Approximate PCM synthesizers for previewing Rainbow sound assets on the
/// host (not cycle-exact — enough to check melody/effect shape).
///
/// AntEater engine timing: the sound loop is 184 T-states; a tone counter
/// toggles the speaker every `c` iterations -> square wave at
/// 3.5e6/(2*184*c) Hz. Row length = (speed<<2) iterations.

const _cpu = 3500000.0;
const _rate = 22050;

double _antFreq(int counter) => counter <= 0 ? 0 : _cpu / (368.0 * counter);
double _ayFreq(int period) => period <= 0 ? 0 : 1773400.0 / (16.0 * period);

/// Render a .rnt song to mono samples (-1..1). One pass (loop ignored).
Float64List synthRnt(Map<String, dynamic> json, {double gain = 0.4}) {
  final enc = encodeRnt('preview', json); // validates + resolves speed/detune
  // walk the encoded pattern rows (after the order table): 3B rows + 0xFF
  var off = (json['loop'] as int? ?? -1) < 0 ? 6 : 8;
  final out = <double>[];
  var phase1 = 0.0, phase2 = 0.0;
  final rnd = Random(7);
  while (off < enc.length && enc[off] != 0xFF) {
    final b0 = enc[off], c1 = enc[off + 1], c2 = enc[off + 2];
    off += 3;
    // engine loads BC with the speed byte in BOTH halves and counts down
    // as a 16-bit value -> (speed<<2)*257 iterations of the 184T loop
    final secs = (b0 & 0xFC) * 257 * 184 / _cpu;
    final n = (secs * _rate).round();
    final f1 = _antFreq(c1), f2 = _antFreq(c2);
    final drum = b0 & 3;
    final drumLen = drum > 0 ? (_rate * 0.012).round() : 0;
    for (var i = 0; i < n; i++) {
      var s = 0.0;
      if (f1 > 0) {
        phase1 += f1 / _rate;
        if (phase1 >= 1) phase1 -= 1;
        s += phase1 < 0.5 ? 0.5 : -0.5;
      }
      if (f2 > 0) {
        phase2 += f2 / _rate;
        if (phase2 >= 1) phase2 -= 1;
        // crude PWM colour: pulse-ish duty wobble
        s += phase2 < 0.35 ? 0.5 : -0.5;
      }
      if (i < drumLen) s += (rnd.nextDouble() * 2 - 1) * 0.6;
      out.add(s * gain);
    }
  }
  return Float64List.fromList(out);
}

/// Render a .rsf effect to mono samples.
Float64List synthRsf(Map<String, dynamic> json, {double gain = 0.5}) {
  final enc = encodeRsf('preview', json);
  final out = <double>[];
  var level = 0.5;
  var i = 0;
  while (i < enc.length && enc[i] != 0) {
    final len = enc[i];
    var per = enc[i + 1].toDouble();
    final slide = (enc[i + 2] & 0x80) != 0
        ? (enc[i + 2] - 256).toDouble()
        : enc[i + 2].toDouble();
    i += 3;
    for (var t = 0; t < len; t++) {
      // half-cycle ~= 16*per T-states
      final half = ((per <= 0 ? 1 : per) * 16 / _cpu * _rate).round();
      level = -level;
      for (var s = 0; s < half; s++) {
        out.add(level * gain);
      }
      per += slide;
      if (per < 1) per = 1;
    }
  }
  return Float64List.fromList(out);
}

/// Render a .ray AY song to mono samples (square tones + noise, envelope
/// approximated as a slow decay when r13 != 0xFF).
Float64List synthRay(Map<String, dynamic> json, {double gain = 0.35}) {
  final enc = encodeRay('preview', json);
  final out = <double>[];
  var phase = [0.0, 0.0, 0.0];
  final rnd = Random(3);
  var off = 0;
  while (off + 15 <= enc.length && enc[off] != 0) {
    final dur = enc[off];
    final pa = enc[off + 1] | (enc[off + 2] << 8);
    final pb = enc[off + 3] | (enc[off + 4] << 8);
    final pc = enc[off + 5] | (enc[off + 6] << 8);
    final noise = enc[off + 7] & 0x1F;
    final mixer = enc[off + 8];
    final vol = [
      enc[off + 9] & 15,
      enc[off + 10] & 15,
      enc[off + 11] & 15
    ];
    final pers = [pa, pb, pc];
    off += 15;
    final n = (dur / 50.0 * _rate).round();
    for (var i = 0; i < n; i++) {
      var s = 0.0;
      for (var c = 0; c < 3; c++) {
        final v = vol[c] / 15.0;
        if (v == 0) continue;
        final toneOff = (mixer & (1 << c)) != 0;
        final noiseOff = (mixer & (8 << c)) != 0;
        var sig = 0.0;
        if (!toneOff) {
          final f = _ayFreq(pers[c]);
          if (f > 0) {
            phase[c] += f / _rate;
            if (phase[c] >= 1) phase[c] -= 1;
            sig += phase[c] < 0.5 ? 0.5 : -0.5;
          }
        }
        if (!noiseOff && noise > 0) {
          // noise rate ~ clock/16/noise; approximate with filtered-ish noise
          sig += (rnd.nextDouble() * 2 - 1) * 0.5;
        }
        s += sig * v;
      }
      out.add(s * gain);
    }
  }
  return Float64List.fromList(out);
}

/// Wrap mono float samples (-1..1) into a 16-bit WAV.
Uint8List wavFromPcm(Float64List samples, {int rate = _rate}) {
  final n = samples.length;
  final data = Uint8List(n * 2);
  final dv = ByteData.view(data.buffer);
  for (var i = 0; i < n; i++) {
    final v = (samples[i].clamp(-1.0, 1.0) * 32767).round();
    dv.setInt16(i * 2, v, Endian.little);
  }
  final out = BytesBuilder(copy: false);
  void str(String s) => out.add(s.codeUnits);
  void u32(int v) => out.add(
      [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF]);
  void u16(int v) => out.add([v & 0xFF, (v >> 8) & 0xFF]);
  str('RIFF');
  u32(36 + data.length);
  str('WAVE');
  str('fmt ');
  u32(16);
  u16(1); // PCM
  u16(1); // mono
  u32(rate);
  u32(rate * 2);
  u16(2);
  u16(16);
  str('data');
  u32(data.length);
  out.add(data);
  return out.toBytes();
}

/// Write PCM to a temp .wav and play it with the platform's bundled
/// player: afplay on macOS, PowerShell SoundPlayer on Windows,
/// aplay/paplay/ffplay on Linux.
Future<void> playPreview(Float64List samples) async {
  final f = File('${Directory.systemTemp.path}/rainbow_preview.wav');
  await f.writeAsBytes(wavFromPcm(samples));
  if (Platform.isMacOS) {
    await Process.start('afplay', [f.path]);
  } else if (Platform.isWindows) {
    await Process.start('powershell', [
      '-NoProfile',
      '-Command',
      "(New-Object System.Media.SoundPlayer '${f.path}').PlaySync()",
    ]);
  } else {
    for (final player in [
      const ['aplay'],
      const ['paplay'],
      const ['ffplay', '-nodisp', '-autoexit'],
    ]) {
      try {
        await Process.start(player.first, [...player.skip(1), f.path]);
        return;
      } on ProcessException {
        continue;
      }
    }
  }
}
