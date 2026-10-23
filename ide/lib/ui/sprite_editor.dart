import 'dart:convert';

import 'package:flutter/gestures.dart'
    show kPrimaryMouseButton, kSecondaryMouseButton;
import 'package:flutter/material.dart';

import '../spectrum.dart';

/// Editor for `.rbs` sprite assets: pixel canvas, frame list, attr picker.
///
/// The .rbs JSON model: {w, h, attr, frames: [[row strings], ...]}.
/// Pixel rows: '#' = opaque ink, 'o' = opaque paper, '.' = transparent.
class SpriteEditor extends StatefulWidget {
  const SpriteEditor({super.key, required this.text, required this.onChanged});

  final String text;
  final ValueChanged<String> onChanged;

  @override
  State<SpriteEditor> createState() => _SpriteEditorState();
}

class _SpriteEditorState extends State<SpriteEditor> {
  late Map<String, dynamic> _model;
  int _frame = 0;

  /// Active pixel char: '#' ink, 'o' opaque paper, '.' transparent.
  String _tool = '#';
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
      _model = {'w': 16, 'h': 16, 'attr': 0x47, 'frames': _blankFrames(16, 16, 1)};
    }
  }

  static List<List<String>> _blankFrames(int w, int h, int n) => [
        for (var i = 0; i < n; i++) List.filled(h, '.' * w),
      ];

  int get _w => _model['w'] as int;
  int get _h => _model['h'] as int;
  List<List<String>> get _frames =>
      (_model['frames'] as List).cast<List>().map((f) => f.cast<String>()).toList();

  void _commit() {
    widget.onChanged(const JsonEncoder.withIndent('  ').convert(_model));
    setState(() {});
  }

  void _setPixel(int x, int y, String ch) {
    final frames = _frames;
    if (_frame >= frames.length) return;
    final row = frames[_frame][y];
    frames[_frame][y] = row.substring(0, x) + ch + row.substring(x + 1);
    _model['frames'] = frames;
  }

  void _paintAt(Offset local, double cell, String ch) {
    final x = (local.dx / cell).floor();
    final y = (local.dy / cell).floor();
    if (x < 0 || x >= _w || y < 0 || y >= _h) return;
    _setPixel(x, y, ch);
    _commit();
  }

  void _pointer(PointerEvent e, double cell) {
    if ((e.buttons & kSecondaryMouseButton) != 0) {
      _paintAt(e.localPosition, cell, '.'); // right-drag = transparent
    } else if ((e.buttons & kPrimaryMouseButton) != 0) {
      _paintAt(e.localPosition, cell, _tool);
    }
  }

  void _addFrame() {
    final frames = _frames;
    frames.add(List.filled(_h, '.' * _w));
    _model['frames'] = frames;
    _frame = frames.length - 1;
    _commit();
  }

  void _dupFrame() {
    final frames = _frames;
    frames.insert(_frame + 1, List.of(frames[_frame]));
    _model['frames'] = frames;
    _frame++;
    _commit();
  }

  void _delFrame() {
    final frames = _frames;
    if (frames.length <= 1) return;
    frames.removeAt(_frame);
    _model['frames'] = frames;
    if (_frame >= frames.length) _frame = frames.length - 1;
    _commit();
  }

  void _mirrorX() {
    final frames = _frames;
    frames[_frame] = [
      for (final r in frames[_frame]) r.split('').reversed.join()
    ];
    _model['frames'] = frames;
    _commit();
  }

  void _mirrorY() {
    final frames = _frames;
    frames[_frame] = frames[_frame].reversed.toList();
    _model['frames'] = frames;
    _commit();
  }

  @override
  Widget build(BuildContext context) {
    if (_parseError != null) {
      return Center(
          child: Text('invalid sprite JSON: $_parseError',
              style: const TextStyle(color: Colors.redAccent)));
    }
    final frames = _frames;
    if (_frame >= frames.length) _frame = frames.length - 1;
    const cell = 20.0;
    final a = _model['attr'];
    final attr = a is String ? 0xFF : (a as int? ?? 0x38) & 0xFF;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // frame list + tools
        Material(
          color: const Color(0xFF1B1B24),
          child: Container(
            width: 150,
            padding: const EdgeInsets.all(8),
            child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('$_w×$_h  frame ${_frame + 1}/${frames.length}',
                  style: const TextStyle(fontSize: 11, color: Colors.white54)),
              const SizedBox(height: 6),
              Expanded(
                child: ListView.builder(
                  itemCount: frames.length,
                  itemBuilder: (context, i) => ListTile(
                    dense: true,
                    selected: i == _frame,
                    title: Text('frame $i',
                        style: const TextStyle(fontSize: 12)),
                    onTap: () => setState(() => _frame = i),
                  ),
                ),
              ),
              _toolBtn('add frame', Icons.add, _addFrame),
              _toolBtn('duplicate', Icons.copy, _dupFrame),
              _toolBtn('delete', Icons.delete, _delFrame,
                  enabled: frames.length > 1),
              const Divider(height: 16, color: Colors.white12),
              _toolBtn('ink', Icons.brush, () => setState(() => _tool = '#'),
                  selected: _tool == '#'),
              _toolBtn('paper', Icons.format_color_fill,
                  () => setState(() => _tool = 'o'),
                  selected: _tool == 'o'),
              _toolBtn('transparent', Icons.grid_off,
                  () => setState(() => _tool = '.'),
                  selected: _tool == '.'),
              const Divider(height: 16, color: Colors.white12),
              _toolBtn('flip ↔', Icons.swap_horiz, _mirrorX),
              _toolBtn('flip ↕', Icons.swap_vert, _mirrorY),
              ],
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
                  size: Size(_w * cell, _h * cell),
                  painter: _SpritePainter(
                      frame: frames[_frame], attr: attr, cell: cell),
                ),
              ),
            ),
          ),
        ),
        // attr picker
        Material(
          color: const Color(0xFF1B1B24),
          child: Container(
            width: 150,
            padding: const EdgeInsets.all(8),
            child: ListView(
              children: [
                CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('no attr write',
                      style: TextStyle(fontSize: 11)),
                  subtitle: const Text('keep bg colours',
                      style: TextStyle(fontSize: 10)),
                  value: attr == 0xFF,
                  onChanged: (v) {
                    _model['attr'] = v! ? 'none' : 0x47;
                    _commit();
                  },
                ),
                if (attr != 0xFF)
                  AttrPicker(
                    attr: attr,
                    onChanged: (a) {
                      _model['attr'] = a;
                      _commit();
                    },
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _toolBtn(String label, IconData icon, VoidCallback onTap,
      {bool enabled = true, bool selected = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: TextButton.icon(
        icon: Icon(icon,
            size: 14, color: selected ? const Color(0xFFE0AF68) : null),
        label: Text(label,
            style: TextStyle(
                fontSize: 11,
                color: selected ? const Color(0xFFE0AF68) : null)),
        onPressed: enabled ? onTap : null,
        style: TextButton.styleFrom(
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.symmetric(horizontal: 8)),
      ),
    );
  }
}

class _SpritePainter extends CustomPainter {
  _SpritePainter({required this.frame, required this.attr, required this.cell});

  final List<String> frame;
  final int attr;
  final double cell;

  @override
  void paint(Canvas canvas, Size size) {
    // 0xFF = no attr write; preview ink pixels in black.
    final ink = Paint()..color = attr == 0xFF ? Colors.black : zxInk(attr);
    final paper = Paint()..color = zxPaper(attr);
    final grid = Paint()
      ..color = Colors.white12
      ..strokeWidth = 0.5;
    final checkerA = Paint()..color = const Color(0xFF2A2A36);
    final checkerB = Paint()..color = const Color(0xFF1E1E28);
    final h = frame.length;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < (frame[y].length); x++) {
        final r = Rect.fromLTWH(x * cell, y * cell, cell, cell);
        switch (pixelKind(frame[y], x)) {
          case PixelKind.ink:
            canvas.drawRect(r, ink);
          case PixelKind.paper:
            canvas.drawRect(r, paper);
          case PixelKind.transparent:
            // checkerboard for transparency
            final half = cell / 2;
            final odd = (x + y) % 2 == 0;
            canvas.drawRect(r, odd ? checkerA : checkerB);
            canvas.drawRect(
                Rect.fromLTWH(x * cell + half, y * cell + half, half, half),
                odd ? checkerB : checkerA);
        }
        canvas.drawRect(r, grid);
      }
    }
  }

  // frame rows are mutated in place, so identity checks can't detect
  // changes — always repaint when the widget rebuilds.
  @override
  bool shouldRepaint(_SpritePainter old) => true;
}

/// Ink/paper/bright picker producing a Spectrum attribute byte.
class AttrPicker extends StatelessWidget {
  const AttrPicker({super.key, required this.attr, required this.onChanged});

  final int attr;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final i = attr & 7;
    final p = (attr >> 3) & 7;
    final b = (attr & 0x40) != 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('INK', style: TextStyle(fontSize: 10, color: Colors.white54)),
        _swatches(i, (v) => onChanged(zxAttr(ink: v, paper: p, bright: b))),
        const SizedBox(height: 8),
        const Text('PAPER',
            style: TextStyle(fontSize: 10, color: Colors.white54)),
        _swatches(p, (v) => onChanged(zxAttr(ink: i, paper: v, bright: b))),
        const SizedBox(height: 8),
        CheckboxListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('BRIGHT', style: TextStyle(fontSize: 11)),
          value: b,
          onChanged: (v) => onChanged(zxAttr(ink: i, paper: p, bright: v!)),
        ),
        const SizedBox(height: 8),
        Container(
          height: 40,
          decoration: BoxDecoration(
            color: zxPaper(attr),
            border: Border.all(color: Colors.white24),
          ),
          child: Center(
              child: Text('0x${attr.toRadixString(16)}',
                  style: TextStyle(color: zxInk(attr), fontSize: 12))),
        ),
      ],
    );
  }

  Widget _swatches(int selected, ValueChanged<int> pick) {
    return Row(
      children: [
        for (var c = 0; c < 8; c++)
          Expanded(
            child: GestureDetector(
              onTap: () => pick(c),
              child: Container(
                height: 18,
                decoration: BoxDecoration(
                  color: zxBright[c],
                  border: Border.all(
                      color: c == selected ? Colors.white : Colors.white24,
                      width: c == selected ? 2 : 0.5),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
