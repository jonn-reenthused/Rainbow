import 'dart:convert';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/gestures.dart'
    show kPrimaryMouseButton, kSecondaryMouseButton;
import 'package:flutter/material.dart';
import 'package:rainbow_assets/rainbow_assets.dart';

import '../spectrum.dart';
import 'sprite_editor.dart' show AttrPicker;

/// Editor for `.rbc` screen assets: a 256x192 Spectrum screen.
///
/// The .rbc JSON model: {bitmap: "<6144 bytes hex>", attrs: "<768 hex>"}.
/// Left-drag draws ink pixels / paints attr cells; right-drag erases.
/// Two tools: pixel draw and attribute paint (8x8 cells).
class ScreenEditor extends StatefulWidget {
  const ScreenEditor({super.key, required this.text, required this.onChanged});

  final String text;
  final ValueChanged<String> onChanged;

  @override
  State<ScreenEditor> createState() => _ScreenEditorState();
}

class _ScreenEditorState extends State<ScreenEditor> {
  late Uint8List _bitmap;
  late Uint8List _attrs;
  String? _parseError;

  bool _attrMode = false;
  bool _showAttrs = true;
  int _attr = 0x38;

  static const cell = 2.0;

  @override
  void initState() {
    super.initState();
    _parse();
  }

  Uint8List _hex(String? s, int want) {
    if (s == null) return Uint8List(want);
    final clean = s.replaceAll(RegExp(r'\s'), '');
    if (clean.length != want * 2) throw FormatException('$want*2 hex chars');
    final out = Uint8List(want);
    for (var i = 0; i < want; i++) {
      out[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }

  void _parse() {
    try {
      final m = jsonDecode(widget.text) as Map<String, dynamic>;
      _bitmap = _hex(m['bitmap'] as String?, 6144);
      _attrs = _hex(m['attrs'] as String?, 768);
      _parseError = null;
    } catch (e) {
      _parseError = '$e';
      _bitmap = Uint8List(6144);
      _attrs = Uint8List(768)..fillRange(0, 768, 0x38);
    }
  }

  String _hexOf(Uint8List d) =>
      [for (final b in d) b.toRadixString(16).padLeft(2, '0')].join();

  void _commit() {
    widget.onChanged(const JsonEncoder.withIndent('  ').convert({
      'bitmap': _hexOf(_bitmap),
      'attrs': _hexOf(_attrs),
    }));
    setState(() {});
  }

  /// Spectrum screen address: (y%8)<<8 | (y/8)<<5 | x/8, within the y/64 third.
  int _bmpOff(int x, int y) => ((y ~/ 64) * 2048) +
      ((y % 8) << 8) +
      (((y ~/ 8) % 8) << 5) +
      (x >> 3);

  void _setPixel(int x, int y, bool ink) {
    final o = _bmpOff(x, y);
    final b = 0x80 >> (x & 7);
    _bitmap[o] = ink ? _bitmap[o] | b : _bitmap[o] & ~b;
  }

  void _paintAt(Offset local, bool ink) {
    final x = (local.dx / cell).floor();
    final y = (local.dy / cell).floor();
    if (x < 0 || x >= 256 || y < 0 || y >= 192) return;
    if (_attrMode) {
      _attrs[(y ~/ 8) * 32 + (x ~/ 8)] = _attr;
    } else {
      _setPixel(x, y, ink);
    }
    _commit();
  }

  void _pointer(PointerEvent e) {
    if ((e.buttons & kPrimaryMouseButton) != 0) {
      _paintAt(e.localPosition, true);
    } else if ((e.buttons & kSecondaryMouseButton) != 0) {
      _paintAt(e.localPosition, false);
    }
  }

  void _clear() {
    _bitmap.fillRange(0, 6144, 0);
    _commit();
  }

  void _invert() {
    for (var i = 0; i < 6144; i++) {
      _bitmap[i] = ~_bitmap[i] & 0xFF;
    }
    _commit();
  }

  Future<void> _importPng() async {
    final f = await openFile(acceptedTypeGroups: [
      const XTypeGroup(
          label: 'images', extensions: ['png', 'gif', 'jpg', 'jpeg', 'bmp'])
    ]);
    if (f == null) return;
    try {
      final scr = imageToScreen(await f.readAsBytes());
      _bitmap.setRange(0, 6144, scr, 0);
      _attrs.setRange(0, 768, scr, 6144);
      _commit();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('import failed: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_parseError != null) {
      return Center(
          child: Text('invalid screen JSON: $_parseError',
              style: const TextStyle(color: Colors.redAccent)));
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // canvas (scrollable: 512x384 at 2x)
        Expanded(
          child: Container(
            color: const Color(0xFF101018),
            child: SingleChildScrollView(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Center(
                  child: Listener(
                    onPointerDown: _pointer,
                    onPointerMove: _pointer,
                    child: CustomPaint(
                      size: const Size(256 * cell, 192 * cell),
                      painter: _ScreenPainter(
                          bitmap: _bitmap,
                          attrs: _attrs,
                          scale: cell,
                          showAttrs: _showAttrs),
                    ),
                  ),
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
                const Text('screen 256×192',
                    style: TextStyle(fontSize: 11, color: Colors.white54)),
                const SizedBox(height: 8),
                CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title:
                      const Text('attr mode', style: TextStyle(fontSize: 11)),
                  subtitle: const Text('paint 8×8 cells',
                      style: TextStyle(fontSize: 10)),
                  value: _attrMode,
                  onChanged: (v) => setState(() => _attrMode = v!),
                ),
                CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title:
                      const Text('show attrs', style: TextStyle(fontSize: 11)),
                  value: _showAttrs,
                  onChanged: (v) => setState(() => _showAttrs = v!),
                ),
                _btn('import image…', Icons.file_upload, _importPng),
                _btn('clear pixels', Icons.clear, _clear),
                _btn('invert', Icons.invert_colors, _invert),
                const Divider(height: 16, color: Colors.white12),
                AttrPicker(
                    attr: _attr,
                    onChanged: (a) => setState(() {
                          _attr = a;
                          _attrMode = true;
                        })),
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

class _ScreenPainter extends CustomPainter {
  _ScreenPainter(
      {required this.bitmap,
      required this.attrs,
      required this.scale,
      required this.showAttrs});

  final Uint8List bitmap;
  final Uint8List attrs;
  final double scale;
  final bool showAttrs;

  @override
  void paint(Canvas canvas, Size size) {
    final inkP = Paint(), paperP = Paint();
    final cellGrid = Paint()
      ..color = Colors.white10
      ..strokeWidth = 0.5;
    if (!showAttrs) {
      canvas.drawRect(Offset.zero & size, Paint()..color = Colors.black);
    }
    for (var cy = 0; cy < 24; cy++) {
      for (var cx = 0; cx < 32; cx++) {
        final a = attrs[cy * 32 + cx];
        if (showAttrs) {
          final cellR = Rect.fromLTWH(
              cx * 8 * scale, cy * 8 * scale, 8 * scale, 8 * scale);
          canvas.drawRect(cellR, paperP..color = zxPaper(a));
          canvas.drawRect(cellR, cellGrid);
        }
        inkP.color = showAttrs ? zxInk(a) : Colors.white;
        for (var ly = 0; ly < 8; ly++) {
          final y = cy * 8 + ly;
          final o = ((y ~/ 64) * 2048) +
              ((y % 8) << 8) +
              (((y ~/ 8) % 8) << 5) +
              cx;
          final row = bitmap[o];
          for (var bit = 0; bit < 8; bit++) {
            if ((row & (0x80 >> bit)) == 0) continue;
            canvas.drawRect(
                Rect.fromLTWH((cx * 8 + bit) * scale, y * scale, scale, scale),
                inkP);
          }
        }
      }
    }
  }

  // bitmap/attrs are mutated in place, so identity checks can't detect
  // changes — always repaint when the widget rebuilds.
  @override
  bool shouldRepaint(_ScreenPainter old) => true;
}
