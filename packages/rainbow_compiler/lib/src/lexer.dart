import 'diag.dart';

enum TokKind {
  ident,
  number,
  string,
  newline,
  colon,
  comma,
  semi,
  lparen,
  rparen,
  plus,
  minus,
  star,
  slash,
  eq,
  ne,
  lt,
  gt,
  le,
  ge,
  dot,
  eof,
  keyword,
}

class Token {
  Token(this.kind, this.text, this.line, this.col, {this.value});
  final TokKind kind;
  final String text;
  final int line;
  final int col;
  final int? value;

  @override
  String toString() => '$kind($text)@$line:$col';
}

class Lexer {
  Lexer(this.source, this.file, this.diag);

  final String source;
  final String file;
  final DiagnosticBag diag;

  static const keywords = {
    'PROGRAM',
    'TARGET',
    'INCLUDE',
    'CONST',
    'DIM',
    'GLOBAL',
    'AS',
    'TYPE',
    'BYTE',
    'UINT',
    'INT',
    'STRING',
    'SUB',
    'FUNCTION',
    'END',
    'RETURN',
    'CALL',
    'GOTO',
    'GOSUB',
    'IF',
    'THEN',
    'ELSEIF',
    'ELSE',
    'ENDIF',
    'WHILE',
    'WEND',
    'REPEAT',
    'UNTIL',
    'FOR',
    'TO',
    'STEP',
    'NEXT',
    'LET',
    'PRINT',
    'PRINTAT',
    'AT',
    'INK',
    'PAPER',
    'BRIGHT',
    'FLASH',
    'BORDER',
    'CLS',
    'POKE',
    'PEEK',
    'OUT',
    'IN',
    'PAUSE',
    'HALT',
    'WAITKEY',
    'RANDOMIZE',
    'RND',
    'KEY',
    'INKEY',
    'JOY',
    'JOYSTICK',
    'KEMPSTON',
    'SINCLAIR1',
    'SINCLAIR2',
    'CURSOR',
    'OFF',
    'JOYFIRE',
    'OVER',
    'PLOT',
    'POINT',
    'FILLATTR',
    'AND',
    'OR',
    'XOR',
    'NOT',
    'MOD',
    'MODE',
    'ABS',
    'MIN',
    'MAX',
    'DATA',
    'READ',
    'RESTORE',
    'ASM',
    'STOP',
    'REM',
    'USR',
    'PEEKW',
    'INVERSE',
    'SCROLL',
    'SCROLLSCREEN',
    'LINE',
    'CIRCLE',
    'CHARSET',
    'SHOWPIC',
    'SPRITE',
    'SPRITES',
    'TILESET',
    'TILEMAP',
    'TILEAT',
    'TILEATSET',
    'TILEFLAGS',
    'COLLIDETILE',
    'SPRITECOLLIDE',
    'SPRITEX',
    'SPRITEY',
    'VIEW',
    'CAMERA',
    'DRAW',
    'DRAWALL',
    'UPDATE',
    'CREATE',
    'PLACE',
    'FRAME',
    'ANIMATE',
    'REMOVE',
    'HIDE',
    'SHOW',
    'ATTR',
    'MASK',
    'PINGPONG',
    'LEFT',
    'RIGHT',
    'UP',
    'DOWN',
    'MOVE',
    'MUSIC',
    'SFX',
    'TICK',
    'USEBANK',
    'COPYBANK',
  };

  List<Token> tokenize() {
    final tokens = <Token>[];
    var i = 0;
    var line = 1;
    var col = 1;
    final n = source.length;

    void emit(TokKind kind, String text, int startCol, [int? value]) =>
        tokens.add(Token(kind, text, line, startCol, value: value));

    while (i < n) {
      final ch = source[i];
      final startCol = col;

      if (ch == '\n') {
        emit(TokKind.newline, '\n', startCol);
        i++;
        line++;
        col = 1;
        continue;
      }
      if (ch == '\r' || ch == ' ' || ch == '\t') {
        i++;
        col++;
        continue;
      }
      // comment: ' to end of line
      if (ch == '\'') {
        while (i < n && source[i] != '\n') {
          i++;
          col++;
        }
        continue;
      }
      if (ch == ';') {
        emit(TokKind.semi, ';', startCol);
        i++;
        col++;
        continue;
      }
      if (ch == ':') {
        emit(TokKind.colon, ':', startCol);
        i++;
        col++;
        continue;
      }
      if (ch == ',') {
        emit(TokKind.comma, ',', startCol);
        i++;
        col++;
        continue;
      }
      if (ch == '(') {
        emit(TokKind.lparen, '(', startCol);
        i++;
        col++;
        continue;
      }
      if (ch == ')') {
        emit(TokKind.rparen, ')', startCol);
        i++;
        col++;
        continue;
      }
      if (ch == '+') {
        emit(TokKind.plus, '+', startCol);
        i++;
        col++;
        continue;
      }
      if (ch == '-') {
        emit(TokKind.minus, '-', startCol);
        i++;
        col++;
        continue;
      }
      if (ch == '*') {
        emit(TokKind.star, '*', startCol);
        i++;
        col++;
        continue;
      }
      if (ch == '/') {
        emit(TokKind.slash, '/', startCol);
        i++;
        col++;
        continue;
      }
      if (ch == '=') {
        emit(TokKind.eq, '=', startCol);
        i++;
        col++;
        continue;
      }
      if (ch == '.') {
        emit(TokKind.dot, '.', startCol);
        i++;
        col++;
        continue;
      }
      if (ch == '<') {
        if (i + 1 < n && source[i + 1] == '>') {
          emit(TokKind.ne, '<>', startCol);
          i += 2;
          col += 2;
        } else if (i + 1 < n && source[i + 1] == '=') {
          emit(TokKind.le, '<=', startCol);
          i += 2;
          col += 2;
        } else {
          emit(TokKind.lt, '<', startCol);
          i++;
          col++;
        }
        continue;
      }
      if (ch == '>') {
        if (i + 1 < n && source[i + 1] == '=') {
          emit(TokKind.ge, '>=', startCol);
          i += 2;
          col += 2;
        } else {
          emit(TokKind.gt, '>', startCol);
          i++;
          col++;
        }
        continue;
      }
      if (ch == '"') {
        i++;
        col++;
        final start = i;
        while (i < n && source[i] != '"' && source[i] != '\n') {
          i++;
          col++;
        }
        final text = source.substring(start, i);
        if (i < n && source[i] == '"') {
          i++;
          col++;
        } else {
          diag.error(file, line, startCol, 'unterminated string');
        }
        emit(TokKind.string, text, startCol);
        continue;
      }
      // numbers: #hex, %bin, decimal
      if (ch == '#') {
        final start = ++i;
        while (i < n && _isHex(source[i])) {
          i++;
        }
        final text = source.substring(start, i);
        col += text.length + 1;
        if (text.isEmpty) {
          diag.error(file, line, startCol, 'expected hex digits after #');
          emit(TokKind.number, '0', startCol, 0);
        } else {
          emit(TokKind.number, '#$text', startCol, int.parse(text, radix: 16));
        }
        continue;
      }
      if (ch == '%') {
        final start = ++i;
        while (i < n && (source[i] == '0' || source[i] == '1')) {
          i++;
        }
        final text = source.substring(start, i);
        col += text.length + 1;
        if (text.isEmpty) {
          diag.error(file, line, startCol, 'expected binary digits after %');
          emit(TokKind.number, '0', startCol, 0);
        } else {
          emit(TokKind.number, '%$text', startCol, int.parse(text, radix: 2));
        }
        continue;
      }
      if (_isDigit(ch)) {
        final start = i;
        while (i < n && _isDigit(source[i])) {
          i++;
        }
        final text = source.substring(start, i);
        col += text.length;
        emit(TokKind.number, text, startCol, int.parse(text));
        continue;
      }
      // identifiers & keywords
      if (_isAlpha(ch)) {
        final start = i;
        while (i < n &&
            (source[i] == '_' || _isAlpha(source[i]) || _isDigit(source[i]))) {
          i++;
        }
        // trailing $ allowed for string identifiers
        if (i < n && source[i] == '\$') {
          i++;
        }
        final text = source.substring(start, i);
        col += text.length;
        final upper = text.toUpperCase();
        if (keywords.contains(upper)) {
          emit(TokKind.keyword, upper, startCol);
          // REM comment: swallow rest of line
          if (upper == 'REM') {
            while (i < n && source[i] != '\n') {
              i++;
              col++;
            }
          }
          // ASM: raw assembler passthrough. Forms:
          //   ASM "ld a,1"          - single-line string form
          //   ASM ld a,1            - inline form (rest of line)
          //   ASM                   - block form until 'END ASM' line
          //     <raw asm lines>
          //   END ASM
          if (upper == 'ASM') {
            var j = i;
            while (j < n && source[j] != '\n') {
              j++;
            }
            var rest = source.substring(i, j);
            final commentPos = rest.indexOf("'");
            if (commentPos >= 0) rest = rest.substring(0, commentPos);
            final trimmed = rest.trim();
            if (trimmed.startsWith('"')) {
              // string form: let the normal tokenizer handle it
            } else if (trimmed.isNotEmpty) {
              // inline form: rest of line is asm text
              i = j;
              col = 1;
              emit(TokKind.string, trimmed, startCol);
            } else {
              // block form: capture raw lines until 'END ASM'
              var k = j;
              if (k < n) k++; // skip newline
              final bufStart = k;
              var end = -1;
              var skipped = 0;
              while (k < n) {
                var lineEnd = k;
                while (lineEnd < n && source[lineEnd] != '\n') {
                  lineEnd++;
                }
                if (source.substring(k, lineEnd).trim().toUpperCase() ==
                    'END ASM') {
                  end = k;
                  break;
                }
                k = lineEnd + 1;
                skipped++;
              }
              if (end == -1) {
                diag.error(file, line, startCol,
                    'unterminated ASM block (expected END ASM)');
                end = n;
              }
              final raw = source.substring(bufStart, end);
              i = end;
              while (i < n && source[i] != '\n') {
                i++;
              }
              line += skipped + 1;
              col = 1;
              emit(TokKind.string, raw, startCol);
            }
          }
        } else {
          emit(TokKind.ident, upper, startCol);
        }
        continue;
      }
      diag.error(file, line, col, 'unexpected character "$ch"');
      i++;
      col++;
    }
    emit(TokKind.eof, '', col);
    return tokens;
  }

  static bool _isDigit(String c) =>
      c.codeUnitAt(0) >= 0x30 && c.codeUnitAt(0) <= 0x39;
  static bool _isHex(String c) {
    final u = c.codeUnitAt(0);
    return (u >= 0x30 && u <= 0x39) ||
        (u >= 0x41 && u <= 0x46) ||
        (u >= 0x61 && u <= 0x66);
  }

  static bool _isAlpha(String c) {
    final u = c.codeUnitAt(0);
    return (u >= 0x41 && u <= 0x5A) || (u >= 0x61 && u <= 0x7A);
  }
}
