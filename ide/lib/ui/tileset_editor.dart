import 'dart:convert';

import 'package:flutter/material.dart';

import '../spectrum.dart';
import 'sprite_editor.dart' show AttrPicker;

/// Editor for `.rbt` tileset assets.
///
/// JSON model: {tiles: [[8 row strings], ...], attrs: [int], flags: [int]}.
/// flags bit0 = solid (COLLIDETILE).
class TilesetEditor extends StatefulWidget {
  const TilesetEditor({super.key, required this.text, required this.onChanged});

  final String text;
  final ValueChanged<String> onChanged;

  @override
  State<TilesetEditor> createState() => _TilesetEditorState();
}

class _TilesetEditorState extends State<TilesetEditor> {
  Map<String, dynamic> _model = {};
  int _tile = 0;
  bool _erase = false;
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
      _model = {'tiles': [], 'attrs': [], 'flags': []};
    }
  }

  List<List<String>> get _tiles => (_model['tiles'] as List? ?? const [])
      .map((t) => (t as List).cast<String>())
      .toList();
  List<int> get _attrs =>
      (_model['attrs'] as List? ?? const []).cast<int>().toList();
  List<int> get _flags =>
      (_model['flags'] as List? ?? const []).cast<int>().toList();

  void _commit() {
    widget.onChanged(const JsonEncoder.withIndent('  ').convert(_model));
    setState(() {});
  }

  void _addTile() {
    final tiles = _tiles..add(List.filled(8, '........'));
    final attrs = _attrs..add(0x38);
    final flags = _flags..add(0);
    _model['tiles'] = tiles;
    _model['attrs'] = attrs;
    _model['flags'] = flags;
    _tile = tiles.length - 1;
    _commit();
  }

  void _delTile() {
    final tiles = _tiles;
    if (tiles.isEmpty) return;
    tiles.removeAt(_tile);
    final attrs = _attrs..removeAt(_tile);
    final flags = _flags..removeAt(_tile);
    _model['tiles'] = tiles;
    _model['attrs'] = attrs;
    _model['flags'] = flags;
    if (_tile >= tiles.length) _tile = tiles.length - 1;
    _commit();
  }

  void _setPixel(int x, int y, bool on) {
    final tiles = _tiles;
    if (_tile < 0 || _tile >= tiles.length) return;
    final row = tiles[_tile][y];
    tiles[_tile][y] =
        row.substring(0, x) + (on ? '#' : '.') + row.substring(x + 1);
    _model['tiles'] = tiles;
  }

  void _paintAt(Offset local, double cell) {
    final x = (local.dx / cell).floor();
    final y = (local.dy / cell).floor();
    if (x < 0 || x >= 8 || y < 0 || y >= 8) return;
    _setPixel(x, y, !_erase);
    _commit();
  }

  void _setAttr(int a) {
    final attrs = _attrs;
    if (_tile >= attrs.length) return;
    attrs[_tile] = a;
    _model['attrs'] = attrs;
    _commit();
  }

  void _setFlagBit(int bit, bool on) {
    final flags = _flags;
    if (_tile >= flags.length) return;
    flags[_tile] = on ? (flags[_tile] | (1 << bit)) : (flags[_tile] & ~(1 << bit));
    _model['flags'] = flags;
    _commit();
  }

  @override
  Widget build(BuildContext context) {
    if (_parseError != null) {
      return Center(
          child: Text('invalid tileset JSON: $_parseError',
              style: const TextStyle(color: Colors.redAccent)));
    }
    final tiles = _tiles;
    if (tiles.isEmpty) {
      return Center(
        child: TextButton.icon(
          icon: const Icon(Icons.add),
          label: const Text('add first tile'),
          onPressed: _addTile,
        ),
      );
    }
    if (_tile >= tiles.length) _tile = tiles.length - 1;
    const cell = 24.0;
    final attr = _tile < _attrs.length ? _attrs[_tile] : 0x38;
    final flags = _tile < _flags.length ? _flags[_tile] : 0;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // tile grid
        Material(
          color: const Color(0xFF1B1B24),
          child: Container(
            width: 132,
            padding: const EdgeInsets.all(6),
            child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('${tiles.length} tiles',
                  style: const TextStyle(fontSize: 11, color: Colors.white54)),
              const SizedBox(height: 6),
              Expanded(
                child: GridView.builder(
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3, mainAxisSpacing: 4, crossAxisSpacing: 4),
                  itemCount: tiles.length,
                  itemBuilder: (context, i) => GestureDetector(
                    onTap: () => setState(() => _tile = i),
                    child: Container(
                      decoration: BoxDecoration(
                        border: Border.all(
                            color: i == _tile ? Colors.white : Colors.white12,
                            width: i == _tile ? 2 : 1),
                      ),
                      child: CustomPaint(
                        painter: _TilePainter(
                            rows: tiles[i],
                            attr: i < _attrs.length ? _attrs[i] : 0x38,
                            cell: 4),
                      ),
                    ),
                  ),
                ),
              ),
              TextButton.icon(
                icon: const Icon(Icons.add, size: 14),
                label: const Text('add', style: TextStyle(fontSize: 11)),
                onPressed: _addTile,
              ),
              TextButton.icon(
                icon: const Icon(Icons.delete, size: 14),
                label: const Text('delete', style: TextStyle(fontSize: 11)),
                onPressed: _delTile,
              ),
              ],
            ),
          ),
        ),
        // canvas
        Expanded(
          child: Container(
            color: const Color(0xFF101018),
            child: Center(
              child: GestureDetector(
                onPanDown: (d) => _paintAt(d.localPosition, cell),
                onPanUpdate: (d) => _paintAt(d.localPosition, cell),
                child: CustomPaint(
                  size: const Size(8 * cell, 8 * cell),
                  painter:
                      _TilePainter(rows: tiles[_tile], attr: attr, cell: cell, grid: true),
                ),
              ),
            ),
          ),
        ),
        // attr + flags
        Material(
          color: const Color(0xFF1B1B24),
          child: Container(
            width: 160,
            padding: const EdgeInsets.all(8),
            child: ListView(
            children: [
              Text('tile $_tile',
                  style: const TextStyle(fontSize: 11, color: Colors.white54)),
              const SizedBox(height: 8),
              AttrPicker(attr: attr, onChanged: _setAttr),
              const Divider(height: 24, color: Colors.white12),
              const Text('FLAGS',
                  style: TextStyle(fontSize: 10, color: Colors.white54)),
              _flag('solid', 0, flags),
              _flag('bit 1', 1, flags),
              _flag('bit 2', 2, flags),
              _flag('bit 3', 3, flags),
              const SizedBox(height: 16),
              TextButton.icon(
                icon: Icon(_erase ? Icons.check_box : Icons.brush, size: 14),
                label: Text('erase ${_erase ? 'on' : 'off'}',
                    style: const TextStyle(fontSize: 11)),
                onPressed: () => setState(() => _erase = !_erase),
              ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _flag(String label, int bit, int flags) {
    return CheckboxListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(label, style: const TextStyle(fontSize: 11)),
      value: (flags & (1 << bit)) != 0,
      onChanged: (v) => _setFlagBit(bit, v!),
    );
  }
}

/// Paints an 8×8 tile from row strings.
class _TilePainter extends CustomPainter {
  _TilePainter({required this.rows, required this.attr, required this.cell, this.grid = false});

  final List<String> rows;
  final int attr;
  final double cell;
  final bool grid;

  @override
  void paint(Canvas canvas, Size size) {
    final ink = Paint()..color = zxInk(attr);
    final paper = Paint()..color = zxPaper(attr);
    final gridPaint = Paint()
      ..color = Colors.white12
      ..strokeWidth = 0.5;
    for (var y = 0; y < 8 && y < rows.length; y++) {
      for (var x = 0; x < 8; x++) {
        final r = Rect.fromLTWH(x * cell, y * cell, cell, cell);
        canvas.drawRect(r, pixelSet(rows[y], x) ? ink : paper);
        if (grid) canvas.drawRect(r, gridPaint);
      }
    }
  }

  // tile rows are mutated in place — always repaint on rebuild.
  @override
  bool shouldRepaint(_TilePainter old) => true;
}
