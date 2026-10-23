import 'dsk.dart';

/// Generates the `DISK` file that boots a +3 build: when the +3's
/// Loader menu option finds no boot sector it runs `LOAD "DISK"`,
/// which loads and auto-runs this BASIC program. The program just
/// loads the resident binary and enters it — the binary's own
/// rbt_p3load stub then calls +3DOS to fill the asset banks
/// (BASIC-level paging can't coexist with +3DOS: it owns bank 7 at
/// #C000 while it runs).
///
/// Files must be tokenised Spectrum BASIC: a line is
/// [line number big-endian][length little-endian][tokens][0x0D], where
/// keywords are single bytes and every numeric literal is its ASCII
/// digits followed by 0x0E and the 5-byte floating-point form
/// (small ints: 00 00 hi lo 00).
const _tokens = {
  'CLEAR': 0xFD,
  'BORDER': 0xE7,
  'PAPER': 0xDA,
  'INK': 0xD9,
  'CLS': 0xFB,
  'OUT': 0xDF,
  'LOAD': 0xEF,
  'CODE': 0xAF,
  'RANDOMIZE': 0xF9,
  'USR': 0xC0,
  'PEEK': 0xBE,
  'AND': 0xC6,
  'OR': 0xC5,
};

List<int> _number(int v) =>
    [...'$v'.codeUnits, 0x0E, 0, 0, v & 0xFF, (v >> 8) & 0xFF, 0];

/// Tokenises one BASIC source line: keyword runs outside quotes become
/// tokens, digit runs become ASCII + 0x0E + 5-byte int form, strings
/// stay literal. Used only for the fixed loader template — no
/// expression grammar needed.
List<int> _tokenise(String text) {
  final out = <int>[];
  var i = 0;
  while (i < text.length) {
    final c = text[i];
    if (c == '"') {
      out.add(0x22);
      i++;
      while (i < text.length && text[i] != '"') {
        out.add(text.codeUnitAt(i));
        i++;
      }
      if (i < text.length) {
        out.add(0x22);
        i++;
      }
      continue;
    }
    if (c.codeUnitAt(0) >= 0x30 && c.codeUnitAt(0) <= 0x39) {
      var j = i;
      while (j < text.length &&
          text[j].codeUnitAt(0) >= 0x30 &&
          text[j].codeUnitAt(0) <= 0x39) {
        j++;
      }
      out.addAll(_number(int.parse(text.substring(i, j))));
      i = j;
      continue;
    }
    if (RegExp('[A-Z]').hasMatch(c)) {
      var j = i;
      while (j < text.length &&
          RegExp('[A-Z]').hasMatch(text[j])) {
        j++;
      }
      final word = text.substring(i, j);
      final t = _tokens[word];
      if (t == null) {
        throw StateError('plus3 loader: unknown keyword $word');
      }
      out.add(t);
      i = j;
      continue;
    }
    if (c != ' ') out.add(c.codeUnitAt(0));
    i++;
  }
  return out;
}

/// Builds the DISK file bytes (PLUS3DOS header + tokenised BASIC
/// program). [screen] selects an optional loading-screen file; [org]
/// is the resident code's load and entry address. [name] is the
/// on-disc 8.3 program name (`<name>.BIN` holds the resident code).
List<int> buildPlus3Loader(String name,
    {required int org, bool screen = false}) {
  final lines = <(int, String)>[
    (10, 'CLEAR ${org - 1}'),
    (20, 'BORDER 0:PAPER 0:INK 7:CLS'),
    if (screen) (30, 'LOAD "SCREEN.BIN"CODE'),
    (40, 'LOAD "$name.BIN"CODE'),
    (50, 'RANDOMIZE USR $org'),
  ];

  final prog = <int>[];
  for (final (no, text) in lines) {
    final body = _tokenise(text);
    // the stored length includes the line's terminating 0x0D
    final len = body.length + 1;
    prog.addAll([(no >> 8) & 0xFF, no & 0xFF, len & 0xFF,
        (len >> 8) & 0xFF, ...body, 0x0D]);
  }

  return [
    ...buildPlus3Header('DISK',
        type: 0, dataLen: prog.length, param1: 10, param2: prog.length),
    ...prog,
  ];
}
