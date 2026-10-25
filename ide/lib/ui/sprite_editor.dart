import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/gestures.dart'
    show kPrimaryMouseButton, kSecondaryMouseButton;
import 'package:flutter/material.dart';
import 'package:rainbow_assets/rainbow_assets.dart';

import '../spectrum.dart';

/// Editor for `.rbs` sprite assets: pixel canvas, frame list, attr picker.
///
/// The .rbs JSON model: {w, h, attr, frames: [[row strings], ...]}.
/// Pixel rows: '#' = opaque ink, 'o' = opaque paper, '.' = transparent.
/// Optional "compose": [{sprite, x, y, frame}] — a visual-only list of
/// sibling sprites placed on the preview canvas; ignored by the encoder.
class SpriteEditor extends StatefulWidget {
  const SpriteEditor(
      {super.key,
      required this.text,
      required this.onChanged,
      required this.projectDir,
      required this.relPath});

  final String text;
  final ValueChanged<String> onChanged;
  final String projectDir;
  final String relPath;

  @override
  State<SpriteEditor> createState() => _SpriteEditorState();
}

/// A parsed sibling .rbs for the compose preview.
class _Sibling {
  _Sibling(this.w, this.h, this.attr, this.frames);
  final int w;
  final int h;
  final int attr;
  final List<List<String>> frames;
}

class _SpriteEditorState extends State<SpriteEditor> {
  late Map<String, dynamic> _model;
  int _frame = 0;

  /// Active pixel char: '#' ink, 'o' opaque paper, '.' transparent.
  String _tool = '#';
  String? _parseError;

  /// Compose-preview state: sibling sprites keyed by asset name, and the
  /// selected placement index within the "compose" array.
  bool _compose = false;
  int _sel = -1;
  final Map<String, _Sibling> _siblings = {};

  /// This asset's own name (basename without .rbs) — compose entries
  /// referencing it render live from _model.
  String get _ownName =>
      widget.relPath.split('/').last.replaceAll(RegExp(r'\.rbs$'), '');

  @override
  void initState() {
    super.initState();
    _parse();
    _loadSiblings();
  }

  /// Scan the project's assets dirs for sibling .rbs files.
  void _loadSiblings() {
    try {
      for (final d in Directory(widget.projectDir)
          .listSync()
          .whereType<Directory>()
          .where((d) => RegExp(r'/assets(-[^/]*)?$').hasMatch(d.path))) {
        for (final f in d
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.rbs'))) {
          try {
            final m = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
            _siblings[f.path.split('/').last.replaceAll(RegExp(r'\.rbs$'), '')] =
                _Sibling(
              m['w'] as int? ?? 8,
              m['h'] as int? ?? 8,
              (m['attr'] is String ? 0xFF : m['attr'] as int? ?? 0x38) & 0xFF,
              ((m['frames'] as List? ?? const []).cast<List>())
                  .map((fr) => fr.cast<String>().toList())
                  .toList(),
            );
          } catch (_) {/* bad sibling — skip */}
        }
      }
      setState(() {});
    } catch (_) {/* no project dir */}
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

  /// Import an image file into the current frame: resized to the
  /// sprite's w×h and thresholded on alpha — opaque pixels become
  /// ink ('#'), the rest transparent ('.').
  Future<void> _importPng() async {
    final f = await openFile(acceptedTypeGroups: [
      const XTypeGroup(
          label: 'images', extensions: ['png', 'gif', 'jpg', 'jpeg', 'bmp'])
    ]);
    if (f == null) return;
    try {
      final rows = imageToSpriteRows(await f.readAsBytes(), w: _w, h: _h);
      final frames = _frames;
      frames[_frame] = rows;
      _model['frames'] = frames;
      _commit();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('import failed: $e')));
      }
    }
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

  // ---- compose preview ----

  /// The persisted placements: [{sprite, x, y, frame}].
  List<Map<String, dynamic>> get _placements =>
      (_model['compose'] as List? ?? const [])
          .cast<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();

  void _setPlacements(List<Map<String, dynamic>> ps) {
    _model['compose'] = ps;
    _commit();
  }

  void _addPlacement(String sprite) {
    final ps = _placements
      ..add({'sprite': sprite, 'x': 0, 'y': 0, 'frame': 0});
    _sel = ps.length - 1;
    _setPlacements(ps);
  }

  void _delPlacement(int i) {
    final ps = _placements..removeAt(i);
    if (_sel >= ps.length) _sel = ps.length - 1;
    _setPlacements(ps);
  }

  /// Drag the selected placement on the scene canvas (pixel coords).
  void _composePointer(PointerEvent e, double scale) {
    if (_sel < 0) return;
    final ps = _placements;
    if (_sel >= ps.length) return;
    if ((e.buttons & kPrimaryMouseButton) == 0) return;
    final x = (e.localPosition.dx / scale).round();
    final y = (e.localPosition.dy / scale).round();
    ps[_sel]['x'] = x.clamp(-248, 255);
    ps[_sel]['y'] = y.clamp(-192, 191);
    _setPlacements(ps);
  }

  /// Resolve a placement to its frame rows: the current sprite renders
  /// live from _model; siblings come from the parsed map.
  ({List<String> rows, int w, int h, int attr})? _placementData(
      Map<String, dynamic> p) {
    final name = p['sprite'] as String;
    final fi = (p['frame'] as num? ?? 0).toInt();
    if (name == _ownName) {
      final a = _model['attr'];
      return (
        rows: _frames[fi.clamp(0, _frames.length - 1)],
        w: _w,
        h: _h,
        attr: a is String ? 0xFF : (a as int? ?? 0x38) & 0xFF
      );
    }
    final s = _siblings[name];
    if (s == null || s.frames.isEmpty) return null;
    return (
      rows: s.frames[fi.clamp(0, s.frames.length - 1)],
      w: s.w,
      h: s.h,
      attr: s.attr
    );
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
            child: ListView(
            children: [
              Text('$_w×$_h  frame ${_frame + 1}/${frames.length}',
                  style: const TextStyle(fontSize: 11, color: Colors.white54)),
              const SizedBox(height: 6),
              for (var i = 0; i < frames.length; i++)
                ListTile(
                  dense: true,
                  selected: i == _frame,
                  title: Text('frame $i',
                      style: const TextStyle(fontSize: 12)),
                  onTap: () => setState(() => _frame = i),
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
              _toolBtn('import image…', Icons.file_upload, _importPng),
              const Divider(height: 16, color: Colors.white12),
              _toolBtn('compose', Icons.layers, () {
                setState(() {
                  _compose = !_compose;
                  _sel = -1;
                });
              }, selected: _compose),
              if (_compose) ...[
                for (var i = 0; i < _placements.length; i++)
                  _placementRow(i),
                if (_siblings.isNotEmpty || _ownName.isNotEmpty)
                  _addSpriteDropdown(),
              ],
              ],
            ),
          ),
        ),
        // canvas: pixel editor, or the compose scene of placed sprites
        Expanded(
          child: Container(
            color: const Color(0xFF101018),
            child: _compose
                ? LayoutBuilder(builder: (context, con) {
                    final sx = con.maxWidth / 256;
                    final sy = con.maxHeight / 192;
                    final scale =
                        (sx < sy ? sx : sy).clamp(0.5, 4.0).toDouble();
                    return Center(
                      child: Listener(
                        onPointerDown: (e) => _composePointer(e, scale),
                        onPointerMove: (e) => _composePointer(e, scale),
                        child: CustomPaint(
                          size: Size(256 * scale, 192 * scale),
                          painter: _ComposePainter(
                            placements: _placements,
                            resolve: _placementData,
                            sel: _sel,
                            scale: scale,
                          ),
                        ),
                      ),
                    );
                  })
                : Center(
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

  /// One compose-placement row: select to drag on the canvas; the icon
  /// cycles the entry's frame, the cross removes it.
  Widget _placementRow(int i) {
    final p = _placements[i];
    final name = p['sprite'] as String;
    final d = _placementData(p);
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      selected: i == _sel,
      title: Text(name, style: const TextStyle(fontSize: 11)),
      subtitle: Text('${p['x']},${p['y']}  f:${p['frame']}',
          style: const TextStyle(fontSize: 10)),
      onTap: () => setState(() => _sel = i),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        IconButton(
            icon: const Icon(Icons.animation, size: 14),
            tooltip: 'next frame',
            visualDensity: VisualDensity.compact,
            onPressed: d == null
                ? null
                : () {
                    final ps = _placements;
                    final n =
                        name == _ownName ? _frames.length : _siblings[name]!.frames.length;
                    ps[i]['frame'] =
                        ((p['frame'] as num? ?? 0).toInt() + 1) % n;
                    _setPlacements(ps);
                  }),
        IconButton(
            icon: const Icon(Icons.close, size: 14),
            tooltip: 'remove',
            visualDensity: VisualDensity.compact,
            onPressed: () => _delPlacement(i)),
      ]),
    );
  }

  /// Dropdown to add a sprite (including this one) to the scene.
  Widget _addSpriteDropdown() {
    final names = <String>{
      _ownName,
      ..._siblings.keys,
    }.toList()
      ..sort();
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: DropdownButton<String>(
        isDense: true,
        isExpanded: true,
        hint: const Text('add sprite', style: TextStyle(fontSize: 11)),
        style: const TextStyle(fontSize: 11),
        items: [
          for (final n in names) DropdownMenuItem(value: n, child: Text(n))
        ],
        onChanged: (v) {
          if (v != null) _addPlacement(v);
        },
      ),
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

/// Paints the 256×192 compose scene: every placement's frame drawn in
/// its own attr colours (transparent pixels skipped); the selected
/// placement gets a highlight outline.
class _ComposePainter extends CustomPainter {
  _ComposePainter({
    required this.placements,
    required this.resolve,
    required this.sel,
    required this.scale,
  });

  final List<Map<String, dynamic>> placements;
  final ({List<String> rows, int w, int h, int attr})? Function(
      Map<String, dynamic>) resolve;
  final int sel;
  final double scale;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
        Offset.zero & size, Paint()..color = const Color(0xFF181820));
    final border = Paint()
      ..color = Colors.white24
      ..style = PaintingStyle.stroke;
    canvas.drawRect(Offset.zero & size, border);

    for (var i = 0; i < placements.length; i++) {
      final p = placements[i];
      final d = resolve(p);
      if (d == null) continue;
      final ox = (p['x'] as num? ?? 0) * scale;
      final oy = (p['y'] as num? ?? 0) * scale;
      final ink = Paint()
        ..color = d.attr == 0xFF ? Colors.white : zxInk(d.attr);
      final paper = Paint()
        ..color = d.attr == 0xFF ? Colors.grey : zxPaper(d.attr);
      for (var y = 0; y < d.rows.length; y++) {
        for (var x = 0; x < d.rows[y].length; x++) {
          final r =
              Rect.fromLTWH(ox + x * scale, oy + y * scale, scale, scale);
          switch (pixelKind(d.rows[y], x)) {
            case PixelKind.ink:
              canvas.drawRect(r, ink);
            case PixelKind.paper:
              canvas.drawRect(r, paper);
            case PixelKind.transparent:
              break;
          }
        }
      }
      if (i == sel) {
        canvas.drawRect(
            Rect.fromLTWH(
                ox, oy, d.w * scale, d.h * scale),
            Paint()
              ..color = const Color(0xFFE0AF68)
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.5);
      }
    }
  }

  @override
  bool shouldRepaint(_ComposePainter old) => true;
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
