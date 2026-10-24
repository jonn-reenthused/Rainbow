import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:rainbow_compiler/rainbow_compiler.dart';

import '../app_state.dart';
import '../spectrum.dart';

const _baseColour = Color(0xFFD4D4D4);
const _kwColour = Color(0xFF569CD6);
const _numColour = Color(0xFFB5CEA8);
const _strColour = Color(0xFFCE9178);
const _cmtColour = Color(0xFF6A9955);
const _identColour = Color(0xFF9CDCFE);
const _errColour = Color(0xFFF44747);
const _warnColour = Color(0xFFCCA700);
const gutterColour = Color(0xFF6E7681);

const codeStyle =
    TextStyle(fontFamily: 'Menlo',
          fontFamilyFallback: monoFontFallback,
          fontSize: 13, height: 1.35, color: _baseColour);

/// Syntax-highlighting controller for Rainbow BASIC.
///
/// Re-lexes the buffer on every build and colours tokens; comments and
/// unlexable spans fall back to plain/comment styles. Diagnostics mark
/// their line's tokens with a wavy underline.
class RbwEditingController extends TextEditingController {
  RbwEditingController({super.text});

  /// Diagnostics to underline — matched by 1-based line number.
  List<Diagnostic> diags = [];

  @override
  TextSpan buildTextSpan(
      {required BuildContext context,
      TextStyle? style,
      required bool withComposing}) {
    final src = text;
    final spans = <InlineSpan>[];
    List<Token> toks;
    try {
      toks = Lexer(src, 'editor', DiagnosticBag()).tokenize();
    } catch (_) {
      toks = const [];
    }

    final lineStarts = <int>[0];
    for (var i = 0; i < src.length; i++) {
      if (src[i] == '\n') lineStarts.add(i + 1);
    }

    final lineDeco = <int, Color>{};
    for (final d in diags) {
      lineDeco.putIfAbsent(d.line, () => d.isWarning ? _warnColour : _errColour);
    }

    var pos = 0;
    for (final t in toks) {
      if (t.kind == TokKind.eof || t.kind == TokKind.newline) continue;
      if (t.line - 1 >= lineStarts.length) break;
      final start = lineStarts[t.line - 1] + t.col - 1;
      if (start < pos || start > src.length) continue;
      if (start > pos) spans.add(_plain(src.substring(pos, start)));
      var end = (start + t.text.length).clamp(0, src.length);
      // String tokens hold the contents only — t.col points at the
      // opening quote, so the span must cover the delimiters too.
      if (t.kind == TokKind.string &&
          start < src.length &&
          src[start] == '"') {
        if (end < src.length) end++; // opening quote
        if (end < src.length && src[end] == '"') end++; // closing quote
      }
      spans.add(_styled(src.substring(start, end), t, lineDeco[t.line]));
      pos = end;
    }
    if (pos < src.length) spans.add(_plain(src.substring(pos)));
    return TextSpan(style: codeStyle, children: spans);
  }

  InlineSpan _styled(String s, Token t, Color? deco) {
    final colour = switch (t.kind) {
      TokKind.keyword => _kwColour,
      TokKind.number => _numColour,
      TokKind.string => _strColour,
      TokKind.ident => _identColour,
      _ => _baseColour,
    };
    return TextSpan(
      text: s,
      style: TextStyle(
        color: colour,
        decoration: deco == null ? null : TextDecoration.underline,
        decorationColor: deco,
        decorationStyle: TextDecorationStyle.wavy,
      ),
    );
  }

  InlineSpan _plain(String s) {
    // highlight comments inside plain runs (lexer drops them)
    final children = <InlineSpan>[];
    var rest = s;
    while (rest.isNotEmpty) {
      final nl = rest.indexOf('\n');
      final chunk = nl < 0 ? rest : rest.substring(0, nl);
      final apos = chunk.indexOf("'");
      if (apos >= 0) {
        if (apos > 0) children.add(TextSpan(text: chunk.substring(0, apos)));
        children.add(TextSpan(
            text: chunk.substring(apos),
            style: const TextStyle(color: _cmtColour)));
      } else {
        children.add(TextSpan(text: chunk));
      }
      if (nl < 0) break;
      children.add(const TextSpan(text: '\n'));
      rest = rest.substring(nl + 1);
    }
    return children.length == 1 ? children.single : TextSpan(children: children);
  }
}

/// A line-numbered, syntax-highlighted code editor.
class CodeEditor extends StatefulWidget {
  const CodeEditor({
    super.key,
    required this.doc,
    required this.diags,
    required this.onChanged,
    this.symbols = const {},
  });

  final EditorDoc doc;
  final List<Diagnostic> diags;
  final ValueChanged<String> onChanged;

  /// Completion candidates: keywords + user symbols (Ctrl+Space).
  final Set<String> symbols;

  @override
  State<CodeEditor> createState() => CodeEditorState();
}

class CodeEditorState extends State<CodeEditor> {
  late final RbwEditingController _ctrl;
  final _editorScroll = ScrollController();
  final _gutterScroll = ScrollController();
  final _focusNode = FocusNode();

  OverlayEntry? _popup;
  List<String> _items = [];
  int _sel = 0;
  int _wordStart = 0;
  bool _inserting = false;

  @override
  void initState() {
    super.initState();
    _ctrl = RbwEditingController(text: widget.doc.text);
    _focusNode.onKeyEvent = _onKey;
    _ctrl.addListener(_refilter);
    _editorScroll.addListener(() {
      if (_gutterScroll.hasClients) {
        _gutterScroll.jumpTo(_editorScroll.offset);
      }
    });
  }

  @override
  void dispose() {
    _closePopup();
    _ctrl.dispose();
    _editorScroll.dispose();
    _gutterScroll.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  // -- autocomplete ---------------------------------------------------------

  String get _wordPrefix {
    final sel = _ctrl.selection;
    if (!sel.isValid || !sel.isCollapsed) return '';
    final end = sel.baseOffset;
    var start = end;
    while (start > 0 &&
        RegExp(r'[A-Za-z0-9_]').hasMatch(_ctrl.text[start - 1])) {
      start--;
    }
    _wordStart = start;
    return _ctrl.text.substring(start, end);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    if (_popup != null) {
      switch (e.logicalKey) {
        case LogicalKeyboardKey.arrowDown:
          setStatePopup((_sel + 1) % _items.length);
          return KeyEventResult.handled;
        case LogicalKeyboardKey.arrowUp:
          setStatePopup((_sel - 1 + _items.length) % _items.length);
          return KeyEventResult.handled;
        case LogicalKeyboardKey.enter:
        case LogicalKeyboardKey.tab:
          _accept();
          return KeyEventResult.handled;
        case LogicalKeyboardKey.escape:
          _closePopup();
          return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (e.logicalKey == LogicalKeyboardKey.tab) {
      _indent(dedent: HardwareKeyboard.instance.isShiftPressed);
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.space &&
        (HardwareKeyboard.instance.isControlPressed ||
            HardwareKeyboard.instance.isMetaPressed)) {
      _openPopup();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  static const _indentUnit = '  ';

  /// Tab / Shift+Tab: insert two spaces at the caret, or (with a
  /// selection spanning lines) indent every covered line by two
  /// spaces. Shift+Tab removes up to two leading spaces per line.
  void _indent({required bool dedent}) {
    final v = _ctrl.value;
    final sel = v.selection;
    if (!sel.isValid) return;
    final text = v.text;
    final s = sel.start, e = sel.end;

    if (!dedent && sel.isCollapsed) {
      _ctrl.value = TextEditingValue(
          text: '${text.substring(0, s)}$_indentUnit${text.substring(s)}',
          selection: TextSelection.collapsed(offset: s + _indentUnit.length));
      return;
    }

    // line range covered by the selection
    var ls = s;
    while (ls > 0 && text[ls - 1] != '\n') {
      ls--;
    }
    var ee = e;
    if (e > s && e > 0 && text[e - 1] == '\n') ee--; // trailing line start
    var le = ee;
    while (le > 0 && text[le - 1] != '\n') {
      le--;
    }
    var leEnd = text.indexOf('\n', le);
    if (leEnd < 0) leEnd = text.length;

    var firstDelta = 0; // change applied to the first line only
    final segLines = text.substring(ls, leEnd).split('\n');
    for (var i = 0; i < segLines.length; i++) {
      if (dedent) {
        final n = segLines[i].startsWith(_indentUnit)
            ? 2
            : (segLines[i].startsWith(' ') ? 1 : 0);
        if (i == 0) firstDelta = -n;
        segLines[i] = segLines[i].substring(n);
      } else {
        if (i == 0) firstDelta = _indentUnit.length;
        segLines[i] = '$_indentUnit${segLines[i]}';
      }
    }
    final nt = '${text.substring(0, ls)}${segLines.join('\n')}${text.substring(leEnd)}';
    var ns = s + firstDelta;
    if (ns < ls) ns = ls;
    final ne = e + (nt.length - text.length);
    _ctrl.value = TextEditingValue(
        text: nt,
        selection: TextSelection(baseOffset: ns, extentOffset: ne));
  }

  void setStatePopup(int sel) {
    _sel = sel;
    _popup?.markNeedsBuild();
  }

  void _refilter() {
    if (_popup == null || _inserting) return;
    final prefix = _wordPrefix;
    if (prefix.isEmpty) {
      _closePopup();
      return;
    }
    _items = _candidates(prefix);
    if (_items.isEmpty) {
      _closePopup();
      return;
    }
    _sel = 0;
    _popup!.markNeedsBuild();
  }

  List<String> _candidates(String prefix) {
    final up = prefix.toUpperCase();
    final hits = widget.symbols
        .where((s) =>
            s.toUpperCase().startsWith(up) && s.toUpperCase() != up)
        .toList()
      ..sort();
    return hits.take(12).toList();
  }

  void _openPopup() {
    final prefix = _wordPrefix;
    _items = _candidates(prefix);
    if (_items.isEmpty) return;
    _sel = 0;

    // caret position estimate (Menlo is monospace; measure one char)
    final tp = TextPainter(
        text: const TextSpan(text: '0', style: codeStyle),
        textDirection: TextDirection.ltr)
      ..layout();
    final cw = tp.width;
    final lh = tp.height;
    final before = _ctrl.text.substring(0, _wordStart);
    final row = '\n'.allMatches(before).length;
    final col = _wordStart - (before.lastIndexOf('\n') + 1);
    final box = context.findRenderObject() as RenderBox;
    final left = 44 + 8 + col * cw;
    final top = 8 + (row + 1) * lh - _editorScroll.offset;

    _popup = OverlayEntry(
      builder: (_) => Positioned(
        left: box.localToGlobal(Offset(left, top)).dx,
        top: box.localToGlobal(Offset(left, top)).dy,
        child: Material(
          elevation: 8,
          color: const Color(0xFF252538),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 220, maxHeight: 200),
            child: ListView.builder(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              itemCount: _items.length,
              itemBuilder: (_, i) => InkWell(
                onTap: () => _accept(i),
                child: Container(
                  color: i == _sel ? const Color(0xFF3A3A55) : null,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  child: Text(_items[i],
                      style: codeStyle.copyWith(fontSize: 12)),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    Overlay.of(context).insert(_popup!);
  }

  void _accept([int? i]) {
    final word = _items[i ?? _sel];
    _inserting = true;
    final sel = _ctrl.selection;
    final end = sel.isValid && sel.isCollapsed ? sel.baseOffset : _wordStart;
    _ctrl.text = _ctrl.text.substring(0, _wordStart) +
        word +
        _ctrl.text.substring(end);
    _ctrl.selection =
        TextSelection.collapsed(offset: _wordStart + word.length);
    _inserting = false;
    _closePopup();
    widget.onChanged(_ctrl.text);
  }

  void _closePopup() {
    _popup?.remove();
    _popup = null;
  }

  @override
  Widget build(BuildContext context) {
    _ctrl.diags = widget.diags;
    final lineCount = '\n'.allMatches(_ctrl.text).length + 1;
    final errLines = {for (final d in widget.diags) d.line: d.isWarning};
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          width: 44,
          color: const Color(0xFF1B1B24),
          padding: const EdgeInsets.only(top: 8, right: 6),
          child: SingleChildScrollView(
            controller: _gutterScroll,
            physics: const NeverScrollableScrollPhysics(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (var i = 1; i <= lineCount; i++)
                  Text('$i',
                      style: codeStyle.copyWith(
                        color: !errLines.containsKey(i)
                            ? gutterColour
                            : (errLines[i]! ? _warnColour : _errColour),
                      )),
              ],
            ),
          ),
        ),
        Expanded(
          child: TextField(
            controller: _ctrl,
            focusNode: _focusNode,
            onChanged: widget.onChanged,
            scrollController: _editorScroll,
            expands: true,
            maxLines: null,
            minLines: null,
            keyboardType: TextInputType.multiline,
            style: codeStyle,
            cursorColor: Colors.white70,
            decoration: const InputDecoration(
              border: InputBorder.none,
              contentPadding: EdgeInsets.all(8),
              isCollapsed: true,
            ),
          ),
        ),
      ],
    );
  }
}
