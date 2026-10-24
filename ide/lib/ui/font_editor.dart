import 'dart:convert';

import 'package:flutter/gestures.dart'
    show kPrimaryMouseButton, kSecondaryMouseButton;
import 'package:flutter/material.dart';
import 'package:rainbow_assets/rainbow_assets.dart';

/// Editor for `.rbf` font assets: 96 glyphs (ASCII 32-127) on an 8-row
/// cell whose width, pixel depth and palette depend on the declared
/// target system/mode:
///   zx            8/4px, 1bpp
///   cpc mode 0    8/4px, 4bpp (16 pens, double-wide pixels)
///   cpc mode 1    8/4px, 2bpp (4 pens)
///   cpc mode 2    8/4px, 1bpp
///   c64           8/4px, 1bpp   (+ multi: 4px, 2bpp double-wide)
///
/// The .rbf JSON model: `{system, mode, multi, w, chars: {"ascii":
/// [8 row strings], ...}}`. Glyphs without an entry inherit the
/// system's ROM glyph (rendered dimmed).
class FontEditor extends StatefulWidget {
  const FontEditor({super.key, required this.text, required this.onChanged});

  final String text;
  final ValueChanged<String> onChanged;

  @override
  State<FontEditor> createState() => _FontEditorState();
}

class _FontEditorState extends State<FontEditor> {
  late Map<String, dynamic> _model;
  int _char = 65; // 'A'
  int _pen = 1;
  String? _parseError;

  @override
  void initState() {
    super.initState();
    _parse();
  }

  void _parse() {
    try {
      _model = jsonDecode(widget.text) as Map<String, dynamic>;
      _parseError = null;
    } catch (e) {
      _parseError = '$e';
      _model = {'system': 'zx', 'chars': <String, dynamic>{}};
    }
  }

  FontSpec get _spec => fontSpec(_model);

  Map<String, dynamic> get _chars =>
      _model['chars'] as Map<String, dynamic>? ?? const {};

  /// User-edited rows for [code], or null when inheriting the ROM glyph.
  List<String>? _glyph(int code) =>
      (_chars['$code'] as List?)?.cast<String>();

  /// Pixel grid (8 rows x spec.w) for [code]: edited rows parsed, else
  /// the inherited system glyph.
  List<List<int>> _glyphPx(int code) {
    final rows = _glyph(code);
    if (rows == null) return fontBasePixels(_spec, code);
    return [
      for (var y = 0; y < FontSpec.h; y++)
        fontRowPixels(y < rows.length ? rows[y] : '', _spec)
    ];
  }

  /// Serialise a pixel row back to a row string ('#'/'.' for 1bpp,
  /// hex digits for multibpp).
  String _rowOf(List<int> px) => _spec.bpp == 1
      ? px.map((v) => v != 0 ? '#' : '.').join()
      : px.map((v) => v.toRadixString(16)).join();

  void _commit() {
    widget.onChanged(const JsonEncoder.withIndent('  ').convert(_model));
    setState(() {});
  }

  void _setPixel(int x, int y, int pen) {
    // start from the effective glyph (edited or inherited ROM)
    final g = _glyph(_char) ??
        [for (final px in fontBasePixels(_spec, _char)) _rowOf(px)];
    final row = g[y];
    final ch = _spec.bpp == 1
        ? (pen != 0 ? '#' : '.')
        : pen.clamp(0, _spec.maxPx).toRadixString(16);
    g[y] = '${row.substring(0, x)}$ch${row.substring(x + 1)}';
    (_model['chars'] ??= <String, dynamic>{})['$_char'] = g;
  }

  void _paintAt(Offset local, double cw, double ch, bool erase) {
    final x = (local.dx / cw).floor();
    final y = (local.dy / ch).floor();
    if (x < 0 || x >= _spec.w || y < 0 || y >= FontSpec.h) return;
    _setPixel(x, y, erase ? 0 : _pen);
    _commit();
  }

  void _pointer(PointerEvent e, double cw, double ch) {
    if ((e.buttons & kSecondaryMouseButton) != 0) {
      _paintAt(e.localPosition, cw, ch, true);
    } else if ((e.buttons & kPrimaryMouseButton) != 0) {
      _paintAt(e.localPosition, cw, ch, false);
    }
  }

  void _clear() {
    (_model['chars'] ??= <String, dynamic>{})['$_char'] =
        List.filled(8, _rowOf(List.filled(_spec.w, 0)));
    _commit();
  }

  /// Drop the override so the char inherits the ROM glyph again.
  void _revert() {
    (_model['chars'] as Map<String, dynamic>?)?.remove('$_char');
    _commit();
  }

  void _invert() {
    final g = [
      for (final px in _glyphPx(_char))
        px.map((v) => v == 0 ? 1 : 0).toList()
    ];
    (_model['chars'] ??= <String, dynamic>{})['$_char'] =
        g.map(_rowOf).toList();
    _commit();
  }

  void _shift(int dx, int dy) {
    final src = _glyphPx(_char);
    final g = List.generate(8, (_) => List.filled(_spec.w, 0));
    for (var y = 0; y < 8; y++) {
      for (var x = 0; x < _spec.w; x++) {
        final sx = x - dx, sy = y - dy;
        if (sx < 0 || sx >= _spec.w || sy < 0 || sy >= 8) continue;
        g[y][x] = src[sy][sx];
      }
    }
    (_model['chars'] ??= <String, dynamic>{})['$_char'] =
        g.map(_rowOf).toList();
    _commit();
  }

  void _setSystem(String sys) {
    _model['system'] = sys;
    if (sys == 'cpc') _model.remove('multi');
    if (sys != 'cpc') _model.remove('mode');
    if (_pen > _spec.maxPx) _pen = _spec.maxPx;
    _commit();
  }

  @override
  Widget build(BuildContext context) {
    if (_parseError != null) {
      return Center(
          child: Text('invalid font JSON: $_parseError',
              style: const TextStyle(color: Colors.redAccent)));
    }
    final spec = _spec;
    const ch = 20.0;
    final cw = ch * spec.pixelAspect;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // glyph grid
        Material(
          color: const Color(0xFF1B1B24),
          child: Container(
            width: 280,
            padding: const EdgeInsets.all(8),
            child: GridView.builder(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 8, childAspectRatio: 0.9),
              itemCount: 96,
              itemBuilder: (context, i) {
                final code = 32 + i;
                final sel = code == _char;
                final inherited = _glyph(code) == null;
                return GestureDetector(
                  onTap: () => setState(() => _char = code),
                  child: Container(
                    margin: const EdgeInsets.all(1),
                    decoration: BoxDecoration(
                      color: sel ? const Color(0xFF3A3A55) : null,
                      border: Border.all(
                          color:
                              sel ? const Color(0xFFE0AF68) : Colors.white10),
                    ),
                    child: Column(
                      children: [
                        Text(
                            code < 127
                                ? String.fromCharCode(code)
                                : ' ',
                            style: const TextStyle(
                                fontSize: 9, color: Colors.white38)),
                        Expanded(
                          child: CustomPaint(
                            size: const Size(16, 16),
                            painter: _GlyphThumb(
                                px: _glyphPx(code),
                                spec: spec,
                                scale: 2,
                                inherited: inherited),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        // canvas
        Expanded(
          child: Container(
            color: const Color(0xFF101018),
            child: Center(
              child: Listener(
                onPointerDown: (e) => _pointer(e, cw, ch),
                onPointerMove: (e) => _pointer(e, cw, ch),
                child: CustomPaint(
                  size: Size(spec.w * cw, 8 * ch),
                  painter: _GlyphPainter(
                      px: _glyphPx(_char), spec: spec, cw: cw, ch: ch),
                ),
              ),
            ),
          ),
        ),
        // side panel
        Material(
          color: const Color(0xFF1B1B24),
          child: Container(
            width: 160,
            padding: const EdgeInsets.all(8),
            child: ListView(
              children: [
                Text(
                    _char < 127
                        ? "'${String.fromCharCode(_char)}'  ($_char)"
                        : 'DEL  ($_char)',
                    style:
                        const TextStyle(fontSize: 12, color: Colors.white70)),
                const SizedBox(height: 8),
                _dropdown<String>(
                    'system',
                    spec.system,
                    const ['zx', 'cpc', 'c64'],
                    (v) => _setSystem(v!)),
                if (spec.system == 'cpc')
                  _dropdown<int>('mode', spec.mode, const [0, 1, 2], (v) {
                    _model['mode'] = v;
                    if (_pen > _spec.maxPx) _pen = _spec.maxPx;
                    _commit();
                  }),
                if (spec.system == 'c64')
                  Row(children: [
                    Checkbox(
                        value: spec.multi,
                        onChanged: (v) {
                          if (v == true) {
                            _model['multi'] = true;
                          } else {
                            _model.remove('multi');
                          }
                          if (_pen > _spec.maxPx) _pen = _spec.maxPx;
                          _commit();
                        }),
                    const Text('multi',
                        style:
                            TextStyle(fontSize: 11, color: Colors.white70)),
                  ]),
                if (!(spec.system == 'c64' && spec.multi))
                  _dropdown<int>('width', spec.w, const [8, 4], (v) {
                    _model['w'] = v;
                    _commit();
                  }),
                const Divider(height: 16, color: Colors.white12),
                // palette
                Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  children: [
                    for (var p = 0; p <= spec.maxPx; p++)
                      GestureDetector(
                        onTap: () => setState(() => _pen = p),
                        child: Container(
                          width: 24,
                          height: 20,
                          decoration: BoxDecoration(
                            color: _penColour(p, spec.maxPx),
                            border: Border.all(
                                color: p == _pen
                                    ? const Color(0xFFE0AF68)
                                    : Colors.white24),
                          ),
                          child: spec.bpp > 1
                              ? Center(
                                  child: Text(
                                      p.toRadixString(16).toUpperCase(),
                                      style: const TextStyle(
                                          fontSize: 9,
                                          color: Colors.white70)))
                              : null,
                        ),
                      ),
                  ],
                ),
                const Divider(height: 16, color: Colors.white12),
                _btn('clear', Icons.clear, _clear),
                _btn('revert to ROM', Icons.undo, _revert),
                if (spec.bpp == 1) _btn('invert', Icons.invert_colors, _invert),
                const Divider(height: 16, color: Colors.white12),
                _btn('←', Icons.arrow_back, () => _shift(-1, 0)),
                _btn('→', Icons.arrow_forward, () => _shift(1, 0)),
                _btn('↑', Icons.arrow_upward, () => _shift(0, -1)),
                _btn('↓', Icons.arrow_downward, () => _shift(0, 1)),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// Swatch for palette index [p]: index 0 is dark, the max is white,
  /// intermediate pens ramp through hues so the palette reads clearly.
  static Color _penColour(int p, int maxPx) {
    if (p == 0) return const Color(0xFF16161E);
    if (p == maxPx) return Colors.white;
    final hue = 200.0 - (p - 1) * 360.0 / (maxPx > 2 ? maxPx : 2);
    return HSVColor.fromAHSV(1, hue % 360, 0.75, 0.85).toColor();
  }

  Widget _dropdown<T>(
      String label, T value, List<T> items, ValueChanged<T?> onChanged) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(children: [
        Text('$label ',
            style: const TextStyle(fontSize: 10, color: Colors.white54)),
        Expanded(
          child: DropdownButton<T>(
            value: value,
            isDense: true,
            isExpanded: true,
            dropdownColor: const Color(0xFF1B1B24),
            style: const TextStyle(fontSize: 11, color: Colors.white70),
            items: [
              for (final i in items)
                DropdownMenuItem(value: i, child: Text('$i')),
            ],
            onChanged: onChanged,
          ),
        ),
      ]),
    );
  }

  Widget _btn(String label, IconData icon, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: TextButton.icon(
        icon: Icon(icon, size: 14),
        label: Text(label, style: const TextStyle(fontSize: 11)),
        onPressed: onTap,
        style: TextButton.styleFrom(
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.symmetric(horizontal: 8)),
      ),
    );
  }
}

class _GlyphThumb extends CustomPainter {
  _GlyphThumb(
      {required this.px,
      required this.spec,
      required this.scale,
      this.inherited = false});

  final List<List<int>> px;
  final FontSpec spec;
  final double scale;
  final bool inherited;

  @override
  void paint(Canvas canvas, Size size) {
    for (var y = 0; y < 8 && y < px.length; y++) {
      for (var x = 0; x < px[y].length; x++) {
        final v = px[y][x];
        if (v == 0) continue;
        canvas.drawRect(
            Rect.fromLTWH(x * scale, y * scale, scale, scale),
            Paint()
              ..color = _FontEditorState._penColour(v, spec.maxPx)
                  .withValues(
                      alpha: inherited ? 0.4 : 0.9));
      }
    }
  }

  @override
  bool shouldRepaint(_GlyphThumb old) => true;
}

class _GlyphPainter extends CustomPainter {
  _GlyphPainter(
      {required this.px, required this.spec, required this.cw, required this.ch});

  final List<List<int>> px;
  final FontSpec spec;
  final double cw;
  final double ch;

  @override
  void paint(Canvas canvas, Size size) {
    final off = Paint()..color = const Color(0xFF16161E);
    final grid = Paint()
      ..color = Colors.white12
      ..strokeWidth = 0.5;
    for (var y = 0; y < 8; y++) {
      for (var x = 0; x < spec.w; x++) {
        final r = Rect.fromLTWH(x * cw, y * ch, cw, ch);
        final v = y < px.length && x < px[y].length ? px[y][x] : 0;
        canvas.drawRect(
            r,
            v == 0
                ? off
                : (Paint()
                  ..color = _FontEditorState._penColour(v, spec.maxPx)));
        canvas.drawRect(r, grid);
      }
    }
  }

  @override
  bool shouldRepaint(_GlyphPainter old) => true;
}
