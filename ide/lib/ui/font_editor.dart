import 'dart:convert';

import 'package:flutter/gestures.dart'
    show kPrimaryMouseButton, kSecondaryMouseButton;
import 'package:flutter/material.dart';
import 'package:rainbow_assets/rainbow_assets.dart';

import '../spectrum.dart';

/// Editor for `.rbf` font assets: 96 glyphs (ASCII 32-127) x 8x8 pixels.
///
/// The .rbf JSON model: `{chars: {"<ascii>": [8 row strings], ...}}`.
/// Glyphs without an entry inherit the Spectrum ROM glyph (rendered
/// dimmed); '#' = set pixel.
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
      _model = {'chars': <String, dynamic>{}};
    }
  }

  Map<String, dynamic> get _chars =>
      _model['chars'] as Map<String, dynamic>? ?? const {};

  /// User-edited rows for [code], or null when inheriting the ROM glyph.
  List<String>? _glyph(int code) =>
      (_chars['$code'] as List?)?.cast<String>();

  /// 8 bitmap bytes for [code]: edited rows packed, else the ROM glyph.
  List<int> _glyphBits(int code) {
    final rows = _glyph(code);
    if (rows == null) {
      return zxFont.sublist((code - 32) * 8, (code - 32) * 8 + 8);
    }
    return [
      for (final r in rows)
        [
          for (var x = 0; x < 8; x++)
            if (pixelKind(r, x) == PixelKind.ink) 0x80 >> x else 0
        ].fold(0, (a, b) => a | b)
    ];
  }

  void _commit() {
    widget.onChanged(const JsonEncoder.withIndent('  ').convert(_model));
    setState(() {});
  }

  void _setPixel(int x, int y, String ch) {
    // start from the effective glyph (edited or inherited ROM)
    final g = _glyph(_char) ??
        [for (final b in _glyphBits(_char)) _byteRow(b)];
    final row = g[y];
    g[y] = row.substring(0, x) + ch + row.substring(x + 1);
    (_model['chars'] ??= <String, dynamic>{})['$_char'] = g;
  }

  static String _byteRow(int b) =>
      [for (var x = 0; x < 8; x++) (b & (0x80 >> x)) != 0 ? '#' : '.']
          .join();

  void _paintAt(Offset local, double cell, String ch) {
    final x = (local.dx / cell).floor();
    final y = (local.dy / cell).floor();
    if (x < 0 || x >= 8 || y < 0 || y >= 8) return;
    _setPixel(x, y, ch);
    _commit();
  }

  void _pointer(PointerEvent e, double cell) {
    if ((e.buttons & kSecondaryMouseButton) != 0) {
      _paintAt(e.localPosition, cell, '.');
    } else if ((e.buttons & kPrimaryMouseButton) != 0) {
      _paintAt(e.localPosition, cell, '#');
    }
  }

  void _clear() {
    (_model['chars'] ??= <String, dynamic>{})['$_char'] =
        List.filled(8, '........');
    _commit();
  }

  /// Drop the override so the char inherits the ROM glyph again.
  void _revert() {
    (_model['chars'] as Map<String, dynamic>?)?.remove('$_char');
    _commit();
  }

  void _invert() {
    final g = [for (final b in _glyphBits(_char)) _byteRow(~b & 0xFF)];
    (_model['chars'] ??= <String, dynamic>{})['$_char'] = g;
    _commit();
  }

  void _shift(int dx, int dy) {
    final src = _glyphBits(_char);
    final g = List.filled(8, '........');
    for (var y = 0; y < 8; y++) {
      for (var x = 0; x < 8; x++) {
        final sx = x - dx, sy = y - dy;
        if (sx < 0 || sx >= 8 || sy < 0 || sy >= 8) continue;
        if ((src[sy] & (0x80 >> sx)) != 0) {
          final row = g[y];
          g[y] = '${row.substring(0, x)}#${row.substring(x + 1)}';
        }
      }
    }
    (_model['chars'] ??= <String, dynamic>{})['$_char'] = g;
    _commit();
  }

  @override
  Widget build(BuildContext context) {
    if (_parseError != null) {
      return Center(
          child: Text('invalid font JSON: $_parseError',
              style: const TextStyle(color: Colors.redAccent)));
    }
    const cell = 20.0;
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
                                bits: _glyphBits(code),
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
                onPointerDown: (e) => _pointer(e, cell),
                onPointerMove: (e) => _pointer(e, cell),
                child: CustomPaint(
                  size: const Size(8 * cell, 8 * cell),
                  painter: _GlyphPainter(
                      bits: _glyphBits(_char), cell: cell),
                ),
              ),
            ),
          ),
        ),
        // side panel
        Material(
          color: const Color(0xFF1B1B24),
          child: Container(
            width: 150,
            padding: const EdgeInsets.all(8),
            child: ListView(
              children: [
                Text(
                    _char < 127
                        ? "'${String.fromCharCode(_char)}'  ($_char)"
                        : 'DEL  ($_char)',
                    style:
                        const TextStyle(fontSize: 12, color: Colors.white70)),
                const SizedBox(height: 12),
                _btn('clear', Icons.clear, _clear),
                _btn('revert to ROM', Icons.undo, _revert),
                _btn('invert', Icons.invert_colors, _invert),
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
      {required this.bits, required this.scale, this.inherited = false});

  final List<int> bits;
  final double scale;
  final bool inherited;

  @override
  void paint(Canvas canvas, Size size) {
    final on = Paint()
      ..color = inherited ? Colors.white38 : Colors.white70;
    for (var y = 0; y < 8 && y < bits.length; y++) {
      for (var x = 0; x < 8; x++) {
        if ((bits[y] & (0x80 >> x)) != 0) {
          canvas.drawRect(
              Rect.fromLTWH(x * scale, y * scale, scale, scale), on);
        }
      }
    }
  }

  @override
  bool shouldRepaint(_GlyphThumb old) => true;
}

class _GlyphPainter extends CustomPainter {
  _GlyphPainter({required this.bits, required this.cell});

  final List<int> bits;
  final double cell;

  @override
  void paint(Canvas canvas, Size size) {
    final on = Paint()..color = Colors.white;
    final off = Paint()..color = const Color(0xFF16161E);
    final grid = Paint()
      ..color = Colors.white12
      ..strokeWidth = 0.5;
    for (var y = 0; y < 8; y++) {
      for (var x = 0; x < 8; x++) {
        final r = Rect.fromLTWH(x * cell, y * cell, cell, cell);
        canvas.drawRect(r, (bits[y] & (0x80 >> x)) != 0 ? on : off);
        canvas.drawRect(r, grid);
      }
    }
  }

  @override
  bool shouldRepaint(_GlyphPainter old) => true;
}
