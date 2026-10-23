import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart'
    show kPrimaryMouseButton, kSecondaryMouseButton;
import 'package:flutter/material.dart';

import '../spectrum.dart';

/// Editor for `.rbm` tilemap assets.
///
/// JSON model: {w, h, map: [w*h tile indices]}.
/// The tile picker reads the first `.rbt` tileset in the project's
/// assets directory.
class TilemapEditor extends StatefulWidget {
  const TilemapEditor({
    super.key,
    required this.text,
    required this.projectDir,
    this.relPath,
    required this.onChanged,
  });

  final String text;
  final String projectDir;

  /// The tilemap's project-relative path — used to prefer a tileset in
  /// the same `assets*` root (shared `assets/` or `assets-<key>/`).
  final String? relPath;
  final ValueChanged<String> onChanged;

  @override
  State<TilemapEditor> createState() => _TilemapEditorState();
}

class _TilemapEditorState extends State<TilemapEditor> {
  Map<String, dynamic> _model = {};
  List<List<String>> _tiles = [];
  List<int> _tileAttrs = [];
  int _selTile = 1;
  String? _parseError;

  @override
  void initState() {
    super.initState();
    _parse();
    _loadTileset();
  }

  void _parse() {
    try {
      _model = jsonDecode(widget.text) as Map<String, dynamic>;
      _parseError = null;
    } catch (e) {
      _parseError = '$e';
      _model = {'w': 32, 'h': 20, 'map': List.filled(32 * 20, 0)};
    }
  }

  void _loadTileset() {
    // find first .rbt, preferring the tilemap's own assets root
    // (`assets/` or `assets-<key>/`) then the others
    final ownRoot = widget.relPath == null
        ? null
        : RegExp(r'^assets(-[^/]*)?/').firstMatch(widget.relPath!)
            ?.group(0);
    final proj = Directory(widget.projectDir);
    final roots = proj
        .listSync()
        .whereType<Directory>()
        .map((d) => '${d.path}/')
        .where((p) =>
            RegExp(r'/assets(-[^/]*)?/$').hasMatch(p))
        .toList()
      ..sort((a, b) => (a.endsWith('/$ownRoot') ? 0 : 1)
          .compareTo(b.endsWith('/$ownRoot') ? 0 : 1));
    File? rbt;
    for (final p in roots) {
      rbt = Directory(p)
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.rbt'))
          .firstOrNull;
      if (rbt != null) break;
    }
    if (rbt == null) return;
    try {
      final m = jsonDecode(rbt.readAsStringSync()) as Map<String, dynamic>;
      _tiles = (m['tiles'] as List? ?? const [])
          .map((t) => (t as List).cast<String>())
          .toList();
      _tileAttrs = (m['attrs'] as List? ?? const []).cast<int>();
      setState(() {});
    } catch (_) {/* tileset invalid — picker shows indices only */}
  }

  int get _w => _model['w'] as int;
  int get _h => _model['h'] as int;
  List<int> get _map => (_model['map'] as List? ?? const []).cast<int>();

  void _commit() {
    widget.onChanged(const JsonEncoder.withIndent('  ').convert(_model));
    setState(() {});
  }

  static const _cell = 16.0;

  void _pointer(PointerEvent e) {
    if ((e.buttons & kSecondaryMouseButton) != 0) {
      _paintAt(e.localPosition, _cell, erase: true);
    } else if ((e.buttons & kPrimaryMouseButton) != 0) {
      _paintAt(e.localPosition, _cell);
    }
  }

  void _paintAt(Offset local, double cell, {bool erase = false}) {
    final x = (local.dx / cell).floor();
    final y = (local.dy / cell).floor();
    if (x < 0 || x >= _w || y < 0 || y >= _h) return;
    final map = _map;
    map[y * _w + x] = erase ? 0 : _selTile;
    _model['map'] = map;
    _commit();
  }

  @override
  Widget build(BuildContext context) {
    if (_parseError != null) {
      return Center(
          child: Text('invalid tilemap JSON: $_parseError',
              style: const TextStyle(color: Colors.redAccent)));
    }
    const cell = 16.0;
    final map = _map;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // tile picker
        Container(
          width: 140,
          color: const Color(0xFF1B1B24),
          padding: const EdgeInsets.all(6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('tiles (${_tiles.length})',
                  style: const TextStyle(fontSize: 11, color: Colors.white54)),
              const SizedBox(height: 6),
              Expanded(
                child: GridView.builder(
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 4,
                      mainAxisSpacing: 3,
                      crossAxisSpacing: 3),
                  itemCount: _tiles.length,
                  itemBuilder: (context, i) => GestureDetector(
                    onTap: () => setState(() => _selTile = i),
                    child: Container(
                      decoration: BoxDecoration(
                        border: Border.all(
                            color: i == _selTile
                                ? Colors.white
                                : Colors.white12,
                            width: i == _selTile ? 2 : 1),
                      ),
                      child: CustomPaint(
                        painter: _MiniTile(
                            rows: _tiles[i],
                            attr: i < _tileAttrs.length ? _tileAttrs[i] : 0x38,
                            cell: 3.5),
                      ),
                    ),
                  ),
                ),
              ),
              Text('sel: $_selTile',
                  style: const TextStyle(fontSize: 11, color: Colors.white38)),
            ],
          ),
        ),
        // map canvas (scrollable both ways)
        Expanded(
          child: Container(
            color: const Color(0xFF101018),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Listener(
                    onPointerDown: _pointer,
                    onPointerMove: _pointer,
                    child: CustomPaint(
                      size: Size(_w * cell, _h * cell),
                      painter: _MapPainter(

                          map: map,
                          w: _w,
                          tiles: _tiles,
                          attrs: _tileAttrs,
                          cell: cell),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        // size controls
        Container(
          width: 130,
          color: const Color(0xFF1B1B24),
          padding: const EdgeInsets.all(8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('$_w × $_h tiles',
                  style: const TextStyle(fontSize: 11, color: Colors.white54)),
              const SizedBox(height: 8),
              _sizeBtn('w+8', () => _resize(_w + 8, _h)),
              _sizeBtn('h+4', () => _resize(_w, _h + 4)),
              _sizeBtn('clear', _clear),
            ],
          ),
        ),
      ],
    );
  }

  Widget _sizeBtn(String label, VoidCallback onTap) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: TextButton(onPressed: onTap, child: Text(label)),
      );

  void _resize(int w, int h) {
    final old = _map;
    final map = List<int>.filled(w * h, 0);
    for (var y = 0; y < h && y < _h; y++) {
      for (var x = 0; x < w && x < _w; x++) {
        map[y * w + x] = old[y * _w + x];
      }
    }
    _model['w'] = w;
    _model['h'] = h;
    _model['map'] = map;
    _commit();
  }

  void _clear() {
    _model['map'] = List<int>.filled(_w * _h, 0);
    _commit();
  }
}

class _MiniTile extends CustomPainter {
  _MiniTile({required this.rows, required this.attr, required this.cell});
  final List<String> rows;
  final int attr;
  final double cell;

  @override
  void paint(Canvas canvas, Size size) {
    final ink = Paint()..color = zxInk(attr);
    final paper = Paint()..color = zxPaper(attr);
    for (var y = 0; y < 8 && y < rows.length; y++) {
      for (var x = 0; x < 8; x++) {
        canvas.drawRect(
            Rect.fromLTWH(x * cell, y * cell, cell, cell),
            pixelSet(rows[y], x) ? ink : paper);
      }
    }
  }

  // tile rows come from shared model lists mutated in place — always
  // repaint on rebuild.
  @override
  bool shouldRepaint(_MiniTile old) => true;
}

class _MapPainter extends CustomPainter {
  _MapPainter(
      {required this.map,
      required this.w,
      required this.tiles,
      required this.attrs,
      required this.cell});

  final List<int> map;
  final int w;
  final List<List<String>> tiles;
  final List<int> attrs;
  final double cell;

  @override
  void paint(Canvas canvas, Size size) {
    final bg = Paint()..color = const Color(0xFF1A1A26);
    final grid = Paint()
      ..color = Colors.white10
      ..strokeWidth = 0.4;
    canvas.drawRect(Offset.zero & size, bg);
    final px = cell / 8;
    for (var i = 0; i < map.length; i++) {
      final t = map[i];
      final cx = (i % w) * cell;
      final cy = (i ~/ w) * cell;
      if (t > 0 && t < tiles.length) {
        final attr = t < attrs.length ? attrs[t] : 0x38;
        final ink = Paint()..color = zxInk(attr);
        final paper = Paint()..color = zxPaper(attr);
        for (var y = 0; y < 8; y++) {
          for (var x = 0; x < 8; x++) {
            canvas.drawRect(
                Rect.fromLTWH(cx + x * px, cy + y * px, px, px),
                pixelSet(tiles[t][y], x) ? ink : paper);
          }
        }
      } else if (t > 0) {
        canvas.drawRect(
            Rect.fromLTWH(cx, cy, cell, cell),
            Paint()..color = Colors.deepPurple.withValues(alpha: 0.4));
      }
      canvas.drawRect(Rect.fromLTWH(cx, cy, cell, cell), grid);
    }
  }

  // map cells are mutated in place — always repaint on rebuild.
  @override
  bool shouldRepaint(_MapPainter old) => true;
}
