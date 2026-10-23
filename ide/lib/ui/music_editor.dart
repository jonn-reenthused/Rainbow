import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../audio.dart';

/// Tracker-style editor for `.rnt` (AntEater beeper) and `.ray` (AY)
/// music assets, with a host-side PCM preview (approximate timing).
class MusicEditor extends StatefulWidget {
  const MusicEditor({
    super.key,
    required this.text,
    required this.onChanged,
    required this.isAy,
  });
  final String text;
  final bool isAy;
  final void Function(String) onChanged;

  @override
  State<MusicEditor> createState() => _MusicEditorState();
}

const _noteNames = [
  'C-',
  'C#',
  'D-',
  'D#',
  'E-',
  'F-',
  'F#',
  'G-',
  'G#',
  'A-',
  'A#',
  'B-',
];

/// `.rnt` note index (0/1 = rest, 2..97 = C..B over 8 octaves).
String antNoteName(int i) {
  if (i < 2 || i > 97) return '---';
  final n = i - 2;
  return '${_noteNames[n % 12]}${n ~/ 12}';
}

/// AY period -> nearest note name ("C-4"), for the .ray editor.
String ayNoteName(int period) {
  if (period <= 0) return '---';
  // freq = 1773400/(16*p); MIDI = 69 + 12*log2(f/440)
  final f = 1773400.0 / (16.0 * period);
  final midi = (69 + 12 * (math.log(f / 440.0) / math.ln2)).round().clamp(
    0,
    127,
  );
  return '${_noteNames[midi % 12]}${midi ~/ 12 - 1}';
}

/// Parse a typed note ("C-4", "C#4", "c4", "G#1") -> (octave, semitone),
/// or null when unrecognised. Returns (-1, -1) for "---"/"off"/"0".
(int, int)? parseNoteName(String s) {
  final t = s.trim().toUpperCase();
  if (t.isEmpty || t == '---' || t == 'OFF' || t == '0') {
    return (-1, -1);
  }
  final m = RegExp(r'^([A-G])(#|S|-)?(\d)$').firstMatch(t);
  if (m == null) return null;
  const base = {'C': 0, 'D': 2, 'E': 4, 'F': 5, 'G': 7, 'A': 9, 'B': 11};
  var semi = base[m[1]!]!;
  final acc = m[2];
  if (acc == '#' || acc == 'S') semi++;
  // '-' is just the display separator for naturals ("C-4"), not a flat.
  return (int.parse(m[3]!), semi);
}

/// Note name -> AntEater note index (2..97); "---"/"off" -> 0.
int? parseAntNote(String s) {
  final p = parseNoteName(s);
  if (p == null) return null;
  if (p.$1 < 0) return 0;
  final idx = 2 + p.$1 * 12 + p.$2;
  return idx <= 97 ? idx : null;
}

/// Note name -> AY tone period (1..4095); "---"/"off" -> 0.
int? ayPeriodForName(String s) {
  final p = parseNoteName(s);
  if (p == null) return null;
  if (p.$1 < 0) return 0;
  final midi = (p.$1 + 1) * 12 + p.$2;
  final f = 440.0 * math.pow(2.0, (midi - 69) / 12.0);
  return (1773400.0 / (16.0 * f)).round().clamp(1, 4095);
}

class _MusicEditorState extends State<MusicEditor> {
  Map<String, dynamic> _json = {};
  List<Map<String, dynamic>> _rows = [];
  int _selRow = 0;
  bool _playing = false;

  @override
  void initState() {
    super.initState();
    _parse();
  }

  void _parse() {
    try {
      _json = Map<String, dynamic>.from(
        jsonDecode(widget.text) as Map<String, dynamic>,
      );
      _rows = (_json['rows'] as List? ?? []).map(_rowToMap).toList();
    } catch (_) {
      _json = {'type': widget.isAy ? 'ray' : 'rnt', 'loop': -1};
      _rows = [];
    }
  }

  /// .ray rows may be maps {dur,a:[p,v],...} or raw 15-int register
  /// lists [dur, r0..r13] — e.g. from the .mod importer. Normalise to
  /// map form for editing.
  Map<String, dynamic> _rowToMap(dynamic r) {
    if (r is Map) return Map<String, dynamic>.from(r);
    if (r is List && r.length == 15) {
      int per(int i) =>
          ((r[1 + i * 2] as int) & 0xFF) |
          (((r[2 + i * 2] as int) & 0xFF) << 8);
      return <String, dynamic>{
        'dur': r[0],
        'a': [per(0), r[8]],
        'b': [per(1), r[9]],
        'c': [per(2), r[10]],
        'noise': r[6],
        'mixer': r[7],
        'env': [r[11], r[12]],
        'eshape': r[13],
      };
    }
    return <String, dynamic>{};
  }

  void _commit() {
    _json['rows'] = _rows;
    widget.onChanged(const JsonEncoder.withIndent('  ').convert(_json));
  }

  Future<void> _preview() async {
    if (_playing) return;
    setState(() => _playing = true);
    try {
      _json['rows'] = _rows;
      final pcm = widget.isAy ? synthRay(_json) : synthRnt(_json);
      if (pcm.isEmpty) {
        throw const FormatException('song produces no audio');
      }
      await playPreview(pcm);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('preview failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _playing = false);
    }
  }

  Widget _numCell(
    int value,
    void Function(int) set, {
    int min = 0,
    int max = 255,
    int width = 46,
  }) {
    final ctl = TextEditingController(text: '$value')
      ..selection = TextSelection(baseOffset: 0, extentOffset: '$value'.length);
    return SizedBox(
      width: width.toDouble(),
      height: 26,
      child: TextField(
        controller: ctl,
        style: const TextStyle(fontFamily: 'Menlo', fontSize: 11),
        decoration: const InputDecoration(
          isDense: true,
          contentPadding: EdgeInsets.all(4),
        ),
        onSubmitted: (v) {
          final n = int.tryParse(v);
          if (n != null) set(n.clamp(min, max));
        },
        onTapOutside: (_) {
          final n = int.tryParse(ctl.text);
          if (n != null && n != value) set(n.clamp(min, max));
        },
      ),
    );
  }

  /// Typeable note cell for .rnt: shows "C-4"/"---", accepts note
  /// names ("C#4", "c4"), "---"/"off"/"0" for a rest.
  Widget _noteCell(int idx, void Function(int) set) {
    final text = antNoteName(idx);
    final ctl = TextEditingController(text: text)
      ..selection = TextSelection(baseOffset: 0, extentOffset: text.length);
    return SizedBox(
      width: 56,
      height: 26,
      child: TextField(
        controller: ctl,
        style: const TextStyle(fontFamily: 'Menlo', fontSize: 11),
        decoration: const InputDecoration(
          isDense: true,
          contentPadding: EdgeInsets.all(4),
        ),
        onSubmitted: (v) {
          final n = parseAntNote(v);
          if (n != null) set(n);
        },
        onTapOutside: (_) {
          final n = parseAntNote(ctl.text);
          if (n != null && n != idx) set(n);
        },
      ),
    );
  }

  /// Typeable AY period cell for .ray: shows the nearest note name,
  /// accepts note names ("C-4") or a raw period number.
  Widget _perCell(int per, void Function(int) set) {
    final text = per <= 0 ? '---' : ayNoteName(per);
    final ctl = TextEditingController(text: text)
      ..selection = TextSelection(baseOffset: 0, extentOffset: text.length);
    return SizedBox(
      width: 44,
      height: 26,
      child: TextField(
        controller: ctl,
        style: const TextStyle(fontFamily: 'Menlo', fontSize: 11),
        decoration: const InputDecoration(
          isDense: true,
          contentPadding: EdgeInsets.all(4),
        ),
        onSubmitted: (v) {
          final n = ayPeriodForName(v) ?? int.tryParse(v.trim());
          if (n != null) set(n.clamp(0, 4095));
        },
        onTapOutside: (_) {
          final t = ctl.text.trim();
          final n = ayPeriodForName(t) ?? int.tryParse(t);
          if (n != null && n != per) set(n.clamp(0, 4095));
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final loop = _json['loop'] as int? ?? -1;
    return Column(
      children: [
        Container(
          height: 34,
          color: const Color(0xFF1B1B24),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                Text(
                  widget.isAy ? 'AY music' : 'Beeper music (AntEater)',
                  style: const TextStyle(fontSize: 12),
                ),
                const SizedBox(width: 12),
                if (!widget.isAy) ...[
                  const Text(
                    'speed',
                    style: TextStyle(fontSize: 11, color: Colors.white54),
                  ),
                  const SizedBox(width: 4),
                  _numCell(
                    _json['speed'] as int? ?? 6,
                    (v) {
                      _json['speed'] = v;
                      _commit();
                    },
                    min: 1,
                    max: 63,
                    width: 34,
                  ),
                ],
                const SizedBox(width: 12),
                const Text(
                  'loop row (-1 = none)',
                  style: TextStyle(fontSize: 11, color: Colors.white54),
                ),
                const SizedBox(width: 4),
                _numCell(
                  loop,
                  (v) {
                    _json['loop'] = v;
                    _commit();
                  },
                  min: -1,
                  max: 999,
                  width: 40,
                ),
                const SizedBox(width: 12),
                IconButton(
                  icon: const Icon(Icons.add, size: 16),
                  tooltip: 'insert row',
                  onPressed: () {
                    _rows.insert(
                      _selRow,
                      widget.isAy
                          ? {
                              'dur': 6,
                              'a': [0, 0],
                              'mixer': 62,
                            }
                          : {
                              'spd': 0,
                              'n1': 0,
                              'd1': 0,
                              'n2': 0,
                              'd2': 0,
                              'dr': 0,
                            },
                    );
                    _commit();
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.remove, size: 16),
                  tooltip: 'delete row',
                  onPressed: _rows.isEmpty
                      ? null
                      : () {
                          _rows.removeAt(_selRow.clamp(0, _rows.length - 1));
                          _selRow = _selRow.clamp(0, _rows.length - 1);
                          _commit();
                        },
                ),
                const SizedBox(width: 12),
                TextButton.icon(
                  icon: Icon(
                    _playing ? Icons.hourglass_top : Icons.play_arrow,
                    size: 16,
                  ),
                  label: const Text('Preview'),
                  onPressed: _preview,
                ),
                const SizedBox(width: 16),
                Text(
                  widget.isAy
                      ? 'notes C-4 / --- · tags: ·ay AY+CPC, ·sid C64, ·bpr 48K'
                      : 'type notes as C-4 / C#4 / --- · click row # to select',
                  style: const TextStyle(fontSize: 10, color: Colors.white38),
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: _rows.isEmpty
              ? const Center(
                  child: Text(
                    'no rows — add one',
                    style: TextStyle(color: Colors.white38),
                  ),
                )
              : ListView.builder(
                  itemCount: _rows.length,
                  itemBuilder: (_, i) {
                    final sel = i == _selRow;
                    final isLoop = i == loop;
                    return InkWell(
                      onTap: () => setState(() => _selRow = i),
                      child: Container(
                        height: 28,
                        color: sel
                            ? const Color(0xFF2D3A55)
                            : (i.isEven
                                  ? Colors.transparent
                                  : const Color(0xFF16161E)),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 34,
                              child: Text(
                                isLoop ? '$i ↻' : '$i',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontFamily: 'Menlo',
                                  color: isLoop
                                      ? const Color(0xFF9ECE6A)
                                      : Colors.white38,
                                ),
                              ),
                            ),
                            ...widget.isAy ? _rayRow(i) : _rntRow(i),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  List<Widget> _rntRow(int i) {
    final r = _rows[i];
    void set(String k, int v) {
      r[k] = v;
      _commit();
    }

    return [
      _numCell(
        r['spd'] as int? ?? 0,
        (v) => set('spd', v),
        min: 0,
        max: 63,
        width: 34,
      ),
      const SizedBox(width: 6),
      _noteCell(r['n1'] as int? ?? 0, (v) => set('n1', v)),
      _numCell(
        r['d1'] as int? ?? 0,
        (v) => set('d1', v),
        min: 0,
        max: 9,
        width: 28,
      ),
      const SizedBox(width: 6),
      _noteCell(r['n2'] as int? ?? 0, (v) => set('n2', v)),
      _numCell(
        r['d2'] as int? ?? 0,
        (v) => set('d2', v),
        min: 0,
        max: 9,
        width: 28,
      ),
      const SizedBox(width: 6),
      SizedBox(
        width: 44,
        height: 26,
        child: DropdownButton<int>(
          isDense: true,
          value: (r['dr'] as int? ?? 0).clamp(0, 4),
          style: const TextStyle(fontFamily: 'Menlo', fontSize: 11),
          items: const [
            DropdownMenuItem(value: 0, child: Text('-')),
            DropdownMenuItem(value: 1, child: Text('D1')),
            DropdownMenuItem(value: 2, child: Text('D2')),
            DropdownMenuItem(value: 3, child: Text('D3')),
            DropdownMenuItem(value: 4, child: Text('D4')),
          ],
          onChanged: (v) => set('dr', v ?? 0),
        ),
      ),
    ];
  }

  List<Widget> _rayRow(int i) {
    final r = _rows[i];
    List<int> chv(String ch) => ((r[ch] as List?)?.cast<int>()) ?? [0, 0];
    void setCh(String ch, int per, int vol) {
      r[ch] = [per, vol];
      _commit();
    }

    // per-voice waveform names stored as "wave":[v1,v2,v3]; 'auto' =
    // encoder default (tone->pulse, noise-only->noise). Int entries are
    // raw SID wave bits (combined waveforms, e.g. from .mus imports).
    const waves = ['auto', 'tri', 'saw', 'pulse', 'noise', 'off'];
    const waveNames = {0x10: 'tri', 0x20: 'saw', 0x40: 'pulse', 0x80: 'noise', 0: 'off'};
    String waveAt(int idx) {
      final w = r['wave'] as List?;
      final e = w != null && idx < w.length ? w[idx] : null;
      if (e is int) {
        return waveNames[e] ?? 'x${e.toRadixString(16).padLeft(2, '0')}';
      }
      final s = '$e';
      return waves.contains(s) ? s : 'auto';
    }

    void setWave(int idx, String name) {
      final w = List<dynamic>.from(
        r['wave'] as List? ?? ['auto', 'auto', 'auto'],
      );
      while (w.length < 3) {
        w.add('auto');
      }
      w[idx] =
          name.startsWith('x') ? int.tryParse(name.substring(1), radix: 16) ?? name : name;
      r['wave'] = w;
      _commit();
    }

    Widget chCell(String ch, int idx) {
      final v = chv(ch);
      return Row(
        children: [
          _perCell(v[0], (x) => setCh(ch, x, v[1])),
          _numCell(v[1], (x) => setCh(ch, v[0], x), min: 0, max: 15, width: 30),
          SizedBox(
            width: 62,
            height: 26,
            child: DropdownButton<String>(
              isDense: true,
              value: waveAt(idx),
              style: const TextStyle(fontFamily: 'Menlo', fontSize: 10),
              items: [
                for (final w in waves)
                  DropdownMenuItem(value: w, child: Text(w)),
                if (!waves.contains(waveAt(idx)))
                  DropdownMenuItem(value: waveAt(idx), child: Text(waveAt(idx))),
              ],
              onChanged: (w) => setWave(idx, w ?? 'auto'),
            ),
          ),
          const SizedBox(width: 4),
        ],
      );
    }

    // target tags: ·ay = AY/CPC only, ·sid = C64 only, ·bpr = beeper only
    const tagAy = TextStyle(fontSize: 10, color: Colors.white38);
    const tagSid = TextStyle(fontSize: 10, color: Color(0xFFE0AF68));
    const tagBpr = TextStyle(fontSize: 10, color: Color(0xFF9ECE6A));

    final eshape = r['eshape'] as int? ?? 255;
    return [
      _numCell(
        r['dur'] as int? ?? 6,
        (v) {
          r['dur'] = v;
          _commit();
        },
        min: 1,
        max: 255,
        width: 34,
      ),
      const SizedBox(width: 6),
      chCell('a', 0),
      chCell('b', 1),
      chCell('c', 2),
      _numCell(
        r['noise'] as int? ?? 0,
        (v) {
          r['noise'] = v;
          _commit();
        },
        min: 0,
        max: 31,
        width: 30,
      ),
      const Text(' noi·ay', style: tagAy),
      const SizedBox(width: 6),
      _numCell(
        r['mixer'] as int? ?? 62,
        (v) {
          r['mixer'] = v;
          _commit();
        },
        min: 0,
        max: 63,
        width: 34,
      ),
      const Text(' mix·ay', style: tagAy),
      const SizedBox(width: 6),
      _numCell(
        eshape == 255 ? -1 : eshape,
        (v) {
          r['eshape'] = v < 0 ? 255 : v;
          _commit();
        },
        min: -1,
        max: 15,
        width: 30,
      ),
      const Text(' env·ay', style: tagAy),
      const SizedBox(width: 6),
      _numCell(
        r['pw'] as int? ?? 2048,
        (v) {
          r['pw'] = v;
          _commit();
        },
        min: 0,
        max: 4095,
        width: 44,
      ),
      const Text(' pw·sid', style: tagSid),
      const SizedBox(width: 6),
      _numCell(
        r['vol'] as int? ?? 15,
        (v) {
          r['vol'] = v;
          _commit();
        },
        min: 0,
        max: 15,
        width: 30,
      ),
      const Text(' vol·sid', style: tagSid),
      const SizedBox(width: 6),
      SizedBox(
        width: 44,
        height: 26,
        child: DropdownButton<int>(
          isDense: true,
          value: (r['drum'] as int? ?? 0).clamp(0, 4),
          style: const TextStyle(fontFamily: 'Menlo', fontSize: 11),
          items: const [
            DropdownMenuItem(value: 0, child: Text('-')),
            DropdownMenuItem(value: 1, child: Text('D1')),
            DropdownMenuItem(value: 2, child: Text('D2')),
            DropdownMenuItem(value: 3, child: Text('D3')),
            DropdownMenuItem(value: 4, child: Text('D4')),
          ],
          onChanged: (v) {
            r['drum'] = v ?? 0;
            _commit();
          },
        ),
      ),
      const Text(' ·bpr', style: tagBpr),
    ];
  }
}

/// Editor for `.rsf` beeper sound effects: a list of {per, len, slide}
/// steps plus preview.
class SfxEditor extends StatefulWidget {
  const SfxEditor({super.key, required this.text, required this.onChanged});
  final String text;
  final void Function(String) onChanged;

  @override
  State<SfxEditor> createState() => _SfxEditorState();
}

/// Ready-made .rsf step lists for common effect shapes.
const _rsfPresets = <String, List<Map<String, int>>>{
  'laser': [
    {'per': 30, 'len': 60, 'slide': 4},
  ],
  'jump': [
    {'per': 120, 'len': 40, 'slide': -3},
  ],
  'coin': [
    {'per': 80, 'len': 10, 'slide': 0},
    {'per': 60, 'len': 14, 'slide': 0},
  ],
  'hiss': [
    {'per': 10, 'len': 80, 'slide': 1},
  ],
  'thud': [
    {'per': 200, 'len': 30, 'slide': 6},
  ],
  'beep': [
    {'per': 80, 'len': 30, 'slide': 0},
  ],
};

class _SfxEditorState extends State<SfxEditor> {
  Map<String, dynamic> _json = {};
  List<Map<String, dynamic>> _steps = [];
  bool _playing = false;

  @override
  void initState() {
    super.initState();
    try {
      _json = Map<String, dynamic>.from(
        jsonDecode(widget.text) as Map<String, dynamic>,
      );
      _steps = (_json['steps'] as List? ?? [])
          .map((s) => Map<String, dynamic>.from(s as Map))
          .toList();
    } catch (_) {
      _json = {'type': 'rsf'};
      _steps = [];
    }
  }

  void _commit() {
    _json['steps'] = _steps;
    widget.onChanged(const JsonEncoder.withIndent('  ').convert(_json));
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          height: 34,
          color: const Color(0xFF1B1B24),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              const Text('Beeper SFX', style: TextStyle(fontSize: 12)),
              const SizedBox(width: 12),
              SizedBox(
                width: 96,
                height: 26,
                child: DropdownButton<String>(
                  isDense: true,
                  isExpanded: true,
                  hint: const Text('preset', style: TextStyle(fontSize: 11)),
                  style: const TextStyle(fontFamily: 'Menlo', fontSize: 11),
                  items: [
                    for (final p in _rsfPresets.keys)
                      DropdownMenuItem(value: p, child: Text(p)),
                  ],
                  onChanged: (v) {
                    if (v == null) return;
                    _steps = [
                      for (final s in _rsfPresets[v]!)
                        Map<String, dynamic>.from(s),
                    ];
                    _commit();
                  },
                ),
              ),
              IconButton(
                icon: const Icon(Icons.add, size: 16),
                tooltip: 'add step',
                onPressed: () {
                  _steps.add({'per': 60, 'len': 40, 'slide': -1});
                  _commit();
                },
              ),
              TextButton.icon(
                icon: Icon(
                  _playing ? Icons.hourglass_top : Icons.play_arrow,
                  size: 16,
                ),
                label: const Text('Preview'),
                onPressed: _playing
                    ? null
                    : () async {
                        setState(() => _playing = true);
                        try {
                          await playPreview(synthRsf(_json));
                        } finally {
                          if (mounted) {
                            setState(() => _playing = false);
                          }
                        }
                      },
              ),
              const Spacer(),
              const Text(
                'per = period · len = toggles · slide = per step',
                style: TextStyle(fontSize: 10, color: Colors.white38),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: _steps.length,
            itemBuilder: (_, i) {
              final s = _steps[i];
              Widget cell(String k, int min, int max) {
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: SizedBox(
                    width: 60,
                    height: 26,
                    child: TextField(
                      controller: TextEditingController(text: '${s[k] ?? 0}'),
                      style: const TextStyle(fontFamily: 'Menlo', fontSize: 11),
                      decoration: InputDecoration(
                        labelText: k,
                        labelStyle: const TextStyle(fontSize: 9),
                        isDense: true,
                        contentPadding: const EdgeInsets.all(4),
                      ),
                      onSubmitted: (v) {
                        final n = int.tryParse(v);
                        if (n != null) {
                          s[k] = n.clamp(min, max);
                          _commit();
                        }
                      },
                    ),
                  ),
                );
              }

              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                child: Row(
                  children: [
                    SizedBox(
                      width: 30,
                      child: Text(
                        '$i',
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.white38,
                        ),
                      ),
                    ),
                    cell('per', 0, 255),
                    cell('len', 1, 255),
                    cell('slide', -128, 127),
                    IconButton(
                      icon: const Icon(Icons.close, size: 14),
                      onPressed: () {
                        _steps.removeAt(i);
                        _commit();
                      },
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
