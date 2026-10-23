import 'ast.dart';
import 'diag.dart';
import 'lexer.dart';
import 'targets.dart';

class Parser {
  Parser(this.tokens, this.file, this.diag);

  final List<Token> tokens;
  final String file;
  final DiagnosticBag diag;

  int _pos = 0;

  /// Statements queued by constructs that expand to several AST nodes
  /// (e.g. comma-separated DIM declarators). Drained by the block loop.
  final List<Stmt> _pending = [];

  Token get _cur => tokens[_pos];
  Token get _peek => tokens[_pos + 1 < tokens.length ? _pos + 1 : _pos];

  bool _at(TokKind k) => _cur.kind == k;
  bool _atKw(String kw) => _cur.kind == TokKind.keyword && _cur.text == kw;

  Token _next() => tokens[_pos++];

  Token _expect(TokKind k, String what) {
    if (_at(k)) return _next();
    diag.error(
        file, _cur.line, _cur.col, 'expected $what, found "${_cur.text}"');
    return _cur;
  }

  Token _expectKw(String kw) {
    if (_atKw(kw)) return _next();
    diag.error(file, _cur.line, _cur.col, 'expected $kw, found "${_cur.text}"');
    return _cur;
  }

  void _skipSeparators() {
    while (_at(TokKind.newline) || _at(TokKind.colon)) {
      _next();
    }
  }

  void _expectEol() {
    if (_at(TokKind.newline) || _at(TokKind.colon)) {
      _skipSeparators();
    } else if (!_at(TokKind.eof)) {
      diag.error(file, _cur.line, _cur.col,
          'expected end of line, found "${_cur.text}"');
      _skipSeparators();
    }
  }

  /// Parse a whole source file.
  Unit parseUnit() {
    final stmts = <Stmt>[];
    _skipSeparators();
    while (!_at(TokKind.eof)) {
      final s = _parseTopLevel();
      if (s != null) stmts.add(s);
      while (_pending.isNotEmpty) {
        stmts.add(_pending.removeAt(0));
      }
      _skipSeparators();
    }
    return Unit(file, stmts);
  }

  // -------------------------------------------------------------------------
  // Top level
  // -------------------------------------------------------------------------

  Stmt? _parseTopLevel() {
    final t = _cur;
    if (_at(TokKind.keyword)) {
      switch (t.text) {
        case 'PROGRAM':
          _next();
          final name = _expect(TokKind.string, 'program name string');
          return ProgramDecl(t.line, t.col, name.text);
        case 'TARGET':
          _next();
          if (_at(TokKind.ident)) {
            final n = _next();
            final id = kTargetIds[n.text.toLowerCase()];
            if (id == null) {
              diag.error(file, n.line, n.col,
                  'unknown target ${n.text} '
                  '(want ${kTargetNames.values.join(', ').toUpperCase()})');
            }
            return TargetDecl(t.line, t.col, id ?? 48);
          }
          final n = _expect(TokKind.number,
              'target (${kTargetNames.values.join(', ').toUpperCase()})');
          return TargetDecl(t.line, t.col, n.value ?? 48);
        case 'INCLUDE':
          _next();
          _expect(TokKind.string, 'include path');
          return null; // handled by driver, still consume
        case 'CONST':
          _next();
          return _parseConst();
        case 'DIM':
          _next();
          return _parseDim(false);
        case 'GLOBAL':
          _next();
          if (_atKw('DIM')) _next();
          return _parseDim(true);
        case 'SUB':
          return _parseSub(isFunction: false);
        case 'FUNCTION':
          return _parseSub(isFunction: true);
        case 'TYPE':
          return _parseTypeDecl();
        default:
          return _parseStatement();
      }
    }
    return _parseStatement();
  }

  ConstDecl _parseConst() {
    final t = _cur;
    final name = _expect(TokKind.ident, 'constant name');
    _expect(TokKind.eq, '=');
    final value = _parseExpr();
    return ConstDecl(t.line, t.col, name.text, value);
  }

  Stmt _parseDim(bool isGlobal) {
    // DIM decl[, decl]*
    final first = _parseDimDecl(isGlobal);
    while (_at(TokKind.comma)) {
      _next();
      _pending.add(_parseDimDecl(isGlobal));
    }
    return first;
  }

  DimDecl _parseDimDecl(bool isGlobal) {
    // name[(size)][(size)]* [AS type|typename] [= init]
    final t = _cur;
    final name = _expect(TokKind.ident, 'variable name');
    final dims = <Expr>[];
    while (_at(TokKind.lparen)) {
      _next();
      dims.add(_parseExpr());
      _expect(TokKind.rparen, ')');
    }
    var type = RType.byte;
    String? structType;
    if (_atKw('AS')) {
      _next();
      if (_at(TokKind.keyword)) {
        final ty = _next();
        type = typeFromName(ty.text);
      } else {
        structType = _expect(TokKind.ident, 'type name').text;
      }
    }
    Expr? init;
    if (_at(TokKind.eq)) {
      _next();
      init = _parseExpr();
    }
    return DimDecl(t.line, t.col, name.text, type,
        dims: dims, structType: structType, init: init, isGlobal: isGlobal);
  }

  TypeDecl _parseTypeDecl() {
    // TYPE Name
    //   field AS BYTE|UINT|INT|STRING
    //   ...
    // END TYPE
    final t = _expectKw('TYPE');
    final name = _expect(TokKind.ident, 'type name');
    _expectEol();
    final fields = <Param>[];
    while (true) {
      _skipSeparators();
      if (_atKw('END')) {
        _next();
        _expectKw('TYPE');
        break;
      }
      if (_at(TokKind.eof)) {
        diag.error(
            file, t.line, t.col, 'unterminated TYPE (expected END TYPE)');
        break;
      }
      final f = _expect(TokKind.ident, 'field name');
      _expectKw('AS');
      final ty = _expect(TokKind.keyword, 'field type (BYTE/UINT/INT/STRING)');
      fields.add(Param(f.text, typeFromName(ty.text)));
      _expectEol();
    }
    return TypeDecl(t.line, t.col, name.text, fields);
  }

  SubDecl _parseSub({required bool isFunction}) {
    final t = _next(); // SUB / FUNCTION
    final name = _expect(TokKind.ident, 'subroutine name');
    final params = <Param>[];
    if (_at(TokKind.lparen)) {
      _next();
      while (!_at(TokKind.rparen) && !_at(TokKind.eof)) {
        final p = _expect(TokKind.ident, 'parameter name');
        var pt = RType.byte;
        if (_atKw('AS')) {
          _next();
          final ty = _expect(TokKind.keyword, 'type name');
          pt = typeFromName(ty.text);
        }
        params.add(Param(p.text, pt));
        if (_at(TokKind.comma)) _next();
      }
      _expect(TokKind.rparen, ')');
    }
    var retType = RType.byte;
    if (isFunction && _atKw('AS')) {
      _next();
      final ty = _expect(TokKind.keyword, 'return type');
      retType = typeFromName(ty.text);
    }
    _expectEol();
    final kind = isFunction ? 'FUNCTION' : 'SUB';
    final body = _parseBlock(endKws: {'END'});
    if (_atKw('END') &&
        _peek.kind == TokKind.keyword &&
        _peek.text == kind) {
      _next();
      _next();
    } else {
      diag.error(file, t.line, t.col, 'unterminated $kind (expected END $kind)');
    }
    return SubDecl(t.line, t.col, name.text, params, body,
        isFunction: isFunction, retType: retType);
  }

  /// Parse statements until one of [endKws] (not consumed).
  List<Stmt> _parseBlock({required Set<String> endKws}) {
    final stmts = <Stmt>[];
    _skipSeparators();
    while (!_at(TokKind.eof)) {
      if (_at(TokKind.keyword) && endKws.contains(_cur.text)) break;
      // 'ELSE'/'ELSEIF'/'NEXT'/'UNTIL'/'WEND' terminate when requested
      final s = _parseStatement();
      if (s != null) stmts.add(s);
      while (_pending.isNotEmpty) {
        stmts.add(_pending.removeAt(0));
      }
      _skipSeparators();
    }
    return stmts;
  }

  // -------------------------------------------------------------------------
  // Statements
  // -------------------------------------------------------------------------

  Stmt? _parseStatement() {
    final t = _cur;

    if (_at(TokKind.ident)) {
      // label?  IDENT ':'
      if (_peek.kind == TokKind.colon) {
        _next();
        _next();
        return LabelStmt(t.line, t.col, t.text);
      }
      // call  name(args)  or  assign  name[(i)][(j)]*[.f] = expr
      _next();
      final indices = <Expr>[];
      List<Expr>? args;
      if (_at(TokKind.lparen)) {
        _next();
        args = _parseArgList();
        _expect(TokKind.rparen, ')');
        while (_at(TokKind.lparen)) {
          _next();
          indices.add(_parseExpr());
          _expect(TokKind.rparen, ')');
        }
      }
      String? field;
      if (_at(TokKind.dot)) {
        _next();
        field = _expect(TokKind.ident, 'field name').text;
      }
      if (_at(TokKind.eq)) {
        _next();
        final v = _parseExpr();
        if (args != null) {
          if (args.length != 1) {
            diag.error(
                file, t.line, t.col, 'array subscript takes one index per ( )');
          } else {
            indices.insert(0, args[0]);
          }
        }
        return AssignStmt(t.line, t.col, t.text, v,
            indices: indices, field: field);
      }
      if (field != null || indices.isNotEmpty) {
        diag.error(file, t.line, t.col, 'expected =');
      }
      if (args != null) return CallStmt(t.line, t.col, t.text, args);
      // bare call with no args
      return CallStmt(t.line, t.col, t.text, const []);
    }

    if (!_at(TokKind.keyword)) {
      diag.error(file, t.line, t.col, 'unexpected "${t.text}"');
      _next();
      return null;
    }

    switch (t.text) {
      case 'CALL':
        _next();
        final n = _expect(TokKind.ident, 'subroutine name');
        var args = <Expr>[];
        if (_at(TokKind.lparen)) {
          _next();
          args = _parseArgList();
          _expect(TokKind.rparen, ')');
        }
        return CallStmt(t.line, t.col, n.text, args);

      case 'LET':
        _next();
        final name = _expect(TokKind.ident, 'variable name');
        final indices = <Expr>[];
        while (_at(TokKind.lparen)) {
          _next();
          indices.add(_parseExpr());
          _expect(TokKind.rparen, ')');
        }
        String? field;
        if (_at(TokKind.dot)) {
          _next();
          field = _expect(TokKind.ident, 'field name').text;
        }
        _expect(TokKind.eq, '=');
        final v = _parseExpr();
        return AssignStmt(t.line, t.col, name.text, v,
            indices: indices, field: field);

      case 'DIM':
        _next();
        return _parseDim(false);

      case 'IF':
        return _parseIf();

      case 'WHILE':
        _next();
        final cond = _parseExpr();
        _expectEol();
        final body = _parseBlock(endKws: {'WEND'});
        if (!_atKw('WEND')) {
          diag.error(file, t.line, t.col, 'WHILE without WEND');
        } else {
          _next();
        }
        return WhileStmt(t.line, t.col, cond, body);

      case 'REPEAT':
        _next();
        _expectEol();
        final body = _parseBlock(endKws: {'UNTIL'});
        if (!_atKw('UNTIL')) {
          diag.error(file, t.line, t.col, 'REPEAT without UNTIL');
          return RepeatStmt(t.line, t.col, body, NumLit(t.line, t.col, 0));
        }
        _next();
        final cond = _parseExpr();
        return RepeatStmt(t.line, t.col, body, cond);

      case 'FOR':
        return _parseFor();

      case 'RETURN':
        _next();
        if (_at(TokKind.newline) || _at(TokKind.colon) || _at(TokKind.eof)) {
          return ReturnStmt(t.line, t.col, null);
        }
        return ReturnStmt(t.line, t.col, _parseExpr());

      case 'GOTO':
        _next();
        final n = _expect(TokKind.ident, 'label name');
        return GotoStmt(t.line, t.col, n.text);

      case 'GOSUB':
        _next();
        final n = _expect(TokKind.ident, 'label name');
        return GotoStmt(t.line, t.col, n.text, isGosub: true);

      case 'PRINT':
        return _parsePrint();

      case 'PRINTAT':
        _next();
        final row = _parseExpr();
        _expect(TokKind.comma, ',');
        final col = _parseExpr();
        // PRINTAT y, x, item; item...
        final items = <PrintItem>[PrintItem.at((row, col))];
        if (_at(TokKind.comma)) {
          _next();
          _parsePrintItems(items);
        }
        return PrintStmt(t.line, t.col, items);

      case 'INK':
      case 'PAPER':
      case 'BRIGHT':
      case 'FLASH':
      case 'BORDER':
      case 'OVER':
      case 'INVERSE':
      case 'MODE':
        _next();
        return Arg1Stmt(t.line, t.col, t.text, _parseExpr());

      case 'CLS':
        _next();
        return ClsStmt(t.line, t.col);

      case 'POKE':
        _next();
        final addr = _parseExpr();
        _expect(TokKind.comma, ',');
        final v = _parseExpr();
        return PokeStmt(t.line, t.col, addr, v);

      case 'OUT':
        _next();
        final port = _parseExpr();
        _expect(TokKind.comma, ',');
        final v = _parseExpr();
        return OutStmt(t.line, t.col, port, v);

      case 'PAUSE':
        _next();
        return PauseStmt(t.line, t.col, _parseExpr());

      case 'HALT':
        _next();
        return SimpleStmt(t.line, t.col, 'HALT');

      case 'WAITKEY':
        _next();
        return SimpleStmt(t.line, t.col, 'WAITKEY');

      case 'STOP':
      case 'END':
        _next();
        return SimpleStmt(t.line, t.col, 'END');

      case 'RANDOMIZE':
        _next();
        if (_at(TokKind.newline) || _at(TokKind.colon) || _at(TokKind.eof)) {
          return RandomizeStmt(t.line, t.col, null);
        }
        return RandomizeStmt(t.line, t.col, _parseExpr());

      case 'DATA':
        return _parseData();

      case 'READ':
        _next();
        final targets = <AssignStmt>[];
        do {
          final n = _expect(TokKind.ident, 'variable name');
          final indices = <Expr>[];
          while (_at(TokKind.lparen)) {
            _next();
            indices.add(_parseExpr());
            _expect(TokKind.rparen, ')');
          }
          String? field;
          if (_at(TokKind.dot)) {
            _next();
            field = _expect(TokKind.ident, 'field name').text;
          }
          targets.add(AssignStmt(
              t.line, t.col, n.text, NumLit(t.line, t.col, 0),
              indices: indices, field: field));
          if (_at(TokKind.comma)) {
            _next();
          } else {
            break;
          }
        } while (true);
        return ReadStmt(t.line, t.col, targets);

      case 'RESTORE':
        _next();
        return SimpleStmt(t.line, t.col, 'RESTORE');

      case 'ASM':
        return _parseAsm();

      case 'JOYSTICK':
        _next();
        if (_atKw('KEMPSTON')) {
          _next();
          return JoystickStmt(t.line, t.col, 1);
        } else if (_atKw('SINCLAIR1')) {
          _next();
          return JoystickStmt(t.line, t.col, 2);
        } else if (_atKw('SINCLAIR2')) {
          _next();
          return JoystickStmt(t.line, t.col, 3);
        } else if (_atKw('CURSOR')) {
          _next();
          return JoystickStmt(t.line, t.col, 4);
        } else if (_atKw('OFF')) {
          _next();
          return JoystickStmt(t.line, t.col, 0);
        }
        diag.error(file, t.line, t.col,
            'expected KEMPSTON|SINCLAIR1|SINCLAIR2|CURSOR|OFF');
        return JoystickStmt(t.line, t.col, 0);

      case 'FILLATTR':
        _next();
        final x = _parseExpr();
        _expect(TokKind.comma, ',');
        final y = _parseExpr();
        _expect(TokKind.comma, ',');
        final w = _parseExpr();
        _expect(TokKind.comma, ',');
        final h = _parseExpr();
        return FillAttrStmt(t.line, t.col, x, y, w, h);

      case 'PLOT':
        _next();
        final px = _parseExpr();
        _expect(TokKind.comma, ',');
        final py = _parseExpr();
        return PlotStmt(t.line, t.col, px, py);

      case 'SPRITE':
        return _parseSprite(t);

      case 'SPRITES':
        _next();
        if (_atKw('DRAWALL') || _atKw('UPDATE')) {
          final op = _next().text;
          return SpritesStmt(t.line, t.col, op);
        }
        diag.error(
            file, t.line, t.col, 'expected DRAWALL or UPDATE after SPRITES');
        return SpritesStmt(t.line, t.col, 'DRAWALL');

      case 'TILESET':
        _next();
        final ts = _expect(TokKind.string, 'tileset asset name');
        return TilesetStmt(t.line, t.col, ts.text);

      case 'CHARSET':
        _next();
        final cs = _expect(TokKind.string, 'font asset name');
        return CharsetStmt(t.line, t.col, cs.text);

      case 'SHOWPIC':
        _next();
        final sp = _expect(TokKind.string, 'screen asset name');
        return ShowpicStmt(t.line, t.col, sp.text);

      case 'MUSIC':
        _next();
        if (_atKw('STOP')) {
          _next();
          return MusicStmt(t.line, t.col, 'STOP');
        }
        if (_atKw('TICK')) {
          _next();
          return MusicStmt(t.line, t.col, 'TICK');
        }
        final mus = _expect(TokKind.string, 'music asset name');
        return MusicStmt(t.line, t.col, 'PLAY', asset: mus.text);

      case 'SFX':
        _next();
        final fx = _expect(TokKind.string, 'sfx asset name');
        return SfxStmt(t.line, t.col, fx.text);

      case 'USEBANK':
        _next();
        return UseBankStmt(t.line, t.col, _parseExpr());

      case 'COPYBANK':
        _next();
        final cb = _expect(TokKind.string, 'banked asset name');
        _expect(TokKind.comma, ',');
        final dest = _parseExpr();
        return CopyBankStmt(t.line, t.col, cb.text, dest);

      case 'TILEMAP':
        return _parseTilemap(t);

      case 'TILEATSET':
        _next();
        final tx = _parseExpr();
        _expect(TokKind.comma, ',');
        final ty = _parseExpr();
        _expect(TokKind.comma, ',');
        final tid = _parseExpr();
        return TileAtSetStmt(t.line, t.col, tx, ty, tid);

      default:
        diag.error(file, t.line, t.col, 'unknown statement "${t.text}"');
        _next();
        return null;
    }
  }

  IfStmt _parseIf() {
    final t = _expectKw('IF');
    final branches = <IfBranch>[];
    final cond = _parseExpr();
    _expectKw('THEN');
    while (_at(TokKind.colon)) {
      _next();
    }
    // single-line IF:  IF cond THEN stmt (: stmt)*   — no ENDIF required
    if (_at(TokKind.newline)) {
      _expectEol();
      final body = _parseBlock(endKws: {'ELSEIF', 'ELSE', 'ENDIF', 'END'});
      branches.add(IfBranch(cond, body));
      while (_atKw('ELSEIF')) {
        _next();
        final c = _parseExpr();
        _expectKw('THEN');
        _expectEol();
        final b = _parseBlock(endKws: {'ELSEIF', 'ELSE', 'ENDIF', 'END'});
        branches.add(IfBranch(c, b));
      }
      if (_atKw('ELSE')) {
        _next();
        _expectEol();
        final b = _parseBlock(endKws: {'ENDIF', 'END'});
        branches.add(IfBranch(null, b));
      }
      if (_atKw('ENDIF')) {
        _next();
      } else if (_atKw('END') &&
          _peek.kind == TokKind.keyword &&
          _peek.text == 'IF') {
        _next();
        _next();
      } else {
        diag.error(file, t.line, t.col, 'IF without ENDIF');
      }
    } else {
      // single-line form: everything until EOL is the body
      final body = <Stmt>[];
      while (!_at(TokKind.newline) && !_at(TokKind.eof)) {
        if (_at(TokKind.colon)) {
          _next();
          continue;
        }
        final s = _parseStatement();
        if (s != null) body.add(s);
      }
      branches.add(IfBranch(cond, body));
    }
    return IfStmt(t.line, t.col, branches);
  }

  ForStmt _parseFor() {
    final t = _expectKw('FOR');
    final name = _expect(TokKind.ident, 'loop variable');
    _expect(TokKind.eq, '=');
    final from = _parseExpr();
    _expectKw('TO');
    final to = _parseExpr();
    Expr? step;
    if (_atKw('STEP')) {
      _next();
      step = _parseExpr();
    }
    _expectEol();
    final body = _parseBlock(endKws: {'NEXT'});
    if (!_atKw('NEXT')) {
      diag.error(file, t.line, t.col, 'FOR without NEXT');
    } else {
      _next();
      if (_at(TokKind.ident)) _next(); // optional loop var name
    }
    return ForStmt(t.line, t.col, name.text, from, to, step, body);
  }

  PrintStmt _parsePrint() {
    final t = _expectKw('PRINT');
    final items = <PrintItem>[];
    var noNewline = false;
    if (_at(TokKind.newline) || _at(TokKind.eof) || _at(TokKind.colon)) {
      items.add(PrintItem.text(''));
      return PrintStmt(t.line, t.col, items);
    }
    noNewline = _parsePrintItems(items);
    return PrintStmt(t.line, t.col, items, noNewline: noNewline);
  }

  /// Parse `AT y,x` and `expr`/`"str"` items separated by `;` or `,`.
  /// Returns true if a trailing ';' suppressed the newline.
  bool _parsePrintItems(List<PrintItem> items) {
    var trailingSemi = false;
    while (true) {
      if (_atKw('AT')) {
        _next();
        final row = _parseExpr();
        _expect(TokKind.comma, ',');
        final col = _parseExpr();
        items.add(PrintItem.at((row, col)));
        trailingSemi = false;
      } else if (_at(TokKind.string)) {
        final s = _next();
        items.add(PrintItem.text(s.text));
        trailingSemi = false;
      } else if (_at(TokKind.semi)) {
        _next();
        trailingSemi = true;
        continue;
      } else if (_at(TokKind.comma)) {
        _next();
        trailingSemi = true;
        continue;
      } else {
        if (_at(TokKind.newline) || _at(TokKind.eof) || _at(TokKind.colon)) {
          break; // line ended right after a ';' separator
        }
        items.add(PrintItem.expr(_parseExpr()));
        trailingSemi = false;
      }
      if (_at(TokKind.semi) || _at(TokKind.comma)) {
        continue;
      }
      break;
    }
    // consume a trailing separator
    while (_at(TokKind.semi) || _at(TokKind.comma)) {
      _next();
      trailingSemi = true;
    }
    return trailingSemi;
  }

  Stmt _parseSprite(Token t) {
    _next(); // SPRITE
    final sub = _cur;
    List<Expr> exprs() {
      final l = <Expr>[_parseExpr()];
      while (_at(TokKind.comma)) {
        _next();
        l.add(_parseExpr());
      }
      return l;
    }

    switch (sub.text) {
      case 'CREATE':
        _next();
        final id = _parseExpr();
        _expect(TokKind.comma, ',');
        final asset = _expect(TokKind.string, 'sprite asset name');
        _expect(TokKind.comma, ',');
        final x = _parseExpr();
        _expect(TokKind.comma, ',');
        final y = _parseExpr();
        var mode = 0;
        if (_at(TokKind.comma)) {
          _next();
          if (_atKw('OR')) {
            _next();
            mode = 1;
          } else if (_atKw('XOR')) {
            _next();
            mode = 2;
          } else if (_atKw('MASK')) {
            _next();
          } else {
            diag.error(file, _cur.line, _cur.col,
                'expected MASK, OR or XOR draw mode');
          }
        }
        return SpriteStmt(t.line, t.col, 'CREATE', [id, x, y],
            asset: asset.text, mode: mode);
      case 'MOVE':
        _next();
        return SpriteStmt(t.line, t.col, 'MOVE', exprs());
      case 'PLACE':
        _next();
        return SpriteStmt(t.line, t.col, 'PLACE', exprs());
      case 'FRAME':
        _next();
        return SpriteStmt(t.line, t.col, 'FRAME', exprs());
      case 'ANIMATE':
        _next();
        final a = <Expr>[_parseExpr()];
        _expect(TokKind.comma, ',');
        a.add(_parseExpr());
        _expect(TokKind.comma, ',');
        a.add(_parseExpr());
        var pp = false;
        if (_at(TokKind.comma)) {
          _next();
          if (_atKw('PINGPONG')) {
            _next();
            pp = true;
          } else {
            diag.error(file, _cur.line, _cur.col, 'expected PINGPONG');
          }
        }
        return SpriteStmt(t.line, t.col, 'ANIMATE', a, pingpong: pp);
      case 'REMOVE':
      case 'HIDE':
      case 'SHOW':
      case 'REDRAW':
        final op = sub.text;
        _next();
        return SpriteStmt(t.line, t.col, op, exprs());
      case 'ATTR':
        _next();
        return SpriteStmt(t.line, t.col, 'ATTR', exprs());
      default:
        diag.error(file, sub.line, sub.col,
            'expected SPRITE CREATE|MOVE|PLACE|FRAME|ANIMATE|REMOVE|HIDE|SHOW|ATTR|REDRAW');
        _next();
        return SpriteStmt(t.line, t.col, 'REMOVE', [NumLit(t.line, t.col, 0)]);
    }
  }

  Stmt _parseTilemap(Token t) {
    _next(); // TILEMAP
    if (_at(TokKind.string)) {
      final s = _next();
      return TilemapStmt(t.line, t.col, 'BIND', asset: s.text);
    }
    final sub = _cur;
    List<Expr> exprs() {
      final l = <Expr>[_parseExpr()];
      while (_at(TokKind.comma)) {
        _next();
        l.add(_parseExpr());
      }
      return l;
    }

    switch (sub.text) {
      case 'VIEW':
        _next();
        return TilemapStmt(t.line, t.col, 'VIEW', args: exprs());
      case 'CAMERA':
        _next();
        return TilemapStmt(t.line, t.col, 'CAMERA', args: exprs());
      case 'DRAW':
        _next();
        return TilemapStmt(t.line, t.col, 'DRAW');
      case 'REDRAW':
        _next();
        return TilemapStmt(t.line, t.col, 'REDRAW', args: exprs());
      case 'SCROLL':
        _next();
        var dir = -1;
        if (_atKw('LEFT')) {
          dir = 0;
        } else if (_atKw('RIGHT')) {
          dir = 1;
        } else if (_atKw('UP')) {
          dir = 2;
        } else if (_atKw('DOWN')) {
          dir = 3;
        }
        if (dir < 0) {
          diag.error(file, _cur.line, _cur.col,
              'expected LEFT|RIGHT|UP|DOWN after SCROLL');
          dir = 0;
        } else {
          _next();
        }
        final args = <Expr>[];
        if (_at(TokKind.comma)) {
          _next();
          args.add(_parseExpr());
        } else if (!_at(TokKind.newline) &&
            !_at(TokKind.colon) &&
            !_at(TokKind.eof)) {
          args.add(_parseExpr());
        }
        return TilemapStmt(t.line, t.col, 'SCROLL', args: args, dir: dir);
      default:
        diag.error(file, sub.line, sub.col,
            'expected TILEMAP "name"|VIEW|CAMERA|DRAW|SCROLL|REDRAW');
        _next();
        return TilemapStmt(t.line, t.col, 'DRAW');
    }
  }

  DataStmt _parseData() {
    final t = _expectKw('DATA');
    final values = <Expr>[];
    do {
      if (_at(TokKind.string)) {
        values.add(StrLit(t.line, t.col, _next().text));
      } else {
        values.add(_parseExpr());
      }
      if (_at(TokKind.comma)) {
        _next();
      } else {
        break;
      }
    } while (true);
    return DataStmt(t.line, t.col, values);
  }

  AsmBlock _parseAsm() {
    final t = _expectKw('ASM');
    if (_at(TokKind.string)) {
      final s = _next();
      return AsmBlock(t.line, t.col, s.text.split('\n'));
    }
    diag.error(file, t.line, t.col, 'expected assembler text after ASM');
    _skipSeparators();
    return AsmBlock(t.line, t.col, const []);
  }

  List<Expr> _parseArgList() {
    final args = <Expr>[];
    if (_at(TokKind.rparen)) return args;
    while (true) {
      args.add(_parseExpr());
      if (_at(TokKind.comma)) {
        _next();
        continue;
      }
      break;
    }
    return args;
  }

  // -------------------------------------------------------------------------
  // Expressions
  // -------------------------------------------------------------------------

  Expr _parseExpr() => _parseOr();

  Expr _parseOr() {
    var left = _parseXor();
    while (_atKw('OR')) {
      final op = _next();
      left = BinExpr(op.line, op.col, BinOp.or, left, _parseXor());
    }
    return left;
  }

  Expr _parseXor() {
    var left = _parseAnd();
    while (_atKw('XOR')) {
      final op = _next();
      left = BinExpr(op.line, op.col, BinOp.xor, left, _parseAnd());
    }
    return left;
  }

  Expr _parseAnd() {
    var left = _parseEquality();
    while (_atKw('AND')) {
      final op = _next();
      left = BinExpr(op.line, op.col, BinOp.and, left, _parseEquality());
    }
    return left;
  }

  Expr _parseEquality() {
    var left = _parseRelational();
    while (_at(TokKind.eq) || _at(TokKind.ne)) {
      final op = _next();
      left = BinExpr(
          op.line,
          op.col,
          op.kind == TokKind.eq ? BinOp.eq : BinOp.ne,
          left,
          _parseRelational());
    }
    return left;
  }

  Expr _parseRelational() {
    var left = _parseAdd();
    while (_at(TokKind.lt) ||
        _at(TokKind.gt) ||
        _at(TokKind.le) ||
        _at(TokKind.ge)) {
      final op = _next();
      final bop = switch (op.kind) {
        TokKind.lt => BinOp.lt,
        TokKind.gt => BinOp.gt,
        TokKind.le => BinOp.le,
        _ => BinOp.ge,
      };
      left = BinExpr(op.line, op.col, bop, left, _parseAdd());
    }
    return left;
  }

  Expr _parseAdd() {
    var left = _parseMul();
    while (_at(TokKind.plus) || _at(TokKind.minus)) {
      final op = _next();
      left = BinExpr(op.line, op.col,
          op.kind == TokKind.plus ? BinOp.add : BinOp.sub, left, _parseMul());
    }
    return left;
  }

  Expr _parseMul() {
    var left = _parseUnary();
    while (_at(TokKind.star) || _at(TokKind.slash) || _atKw('MOD')) {
      final op = _next();
      final bop = switch (op.kind) {
        TokKind.star => BinOp.mul,
        TokKind.slash => BinOp.div,
        _ => BinOp.mod,
      };
      left = BinExpr(op.line, op.col, bop, left, _parseUnary());
    }
    return left;
  }

  Expr _parseUnary() {
    if (_at(TokKind.minus)) {
      final t = _next();
      return UnaryExpr(t.line, t.col, UnaryOp.neg, _parseUnary());
    }
    if (_atKw('NOT')) {
      final t = _next();
      return UnaryExpr(t.line, t.col, UnaryOp.not, _parseUnary());
    }
    return _parsePrimary();
  }

  Expr _parsePrimary() {
    final t = _cur;
    if (_at(TokKind.number)) {
      _next();
      return NumLit(t.line, t.col, t.value ?? 0);
    }
    if (_at(TokKind.string)) {
      _next();
      return StrLit(t.line, t.col, t.text);
    }
    if (_at(TokKind.lparen)) {
      _next();
      final e = _parseExpr();
      _expect(TokKind.rparen, ')');
      return e;
    }
    if (_at(TokKind.ident)) {
      _next();
      List<Expr>? args;
      final indices = <Expr>[];
      if (_at(TokKind.lparen)) {
        _next();
        args = _parseArgList();
        _expect(TokKind.rparen, ')');
        // a(i)(j)... — extra groups make this an array index chain
        while (_at(TokKind.lparen)) {
          _next();
          indices.add(_parseExpr());
          _expect(TokKind.rparen, ')');
        }
      }
      String? field;
      if (_at(TokKind.dot)) {
        _next();
        field = _expect(TokKind.ident, 'field name').text;
      }
      if (args != null) {
        if (indices.isEmpty && field == null) {
          // a(i) or f(args) — sema resolves array vs call
          return CallExpr(t.line, t.col, t.text, args);
        }
        if (args.length != 1) {
          diag.error(
              file, t.line, t.col, 'array subscript takes one index per ( )');
        } else {
          indices.insert(0, args[0]);
        }
        return ArrayExpr(t.line, t.col, t.text, indices, field: field);
      }
      if (field != null) {
        return VarExpr(t.line, t.col, t.text, field: field);
      }
      return VarExpr(t.line, t.col, t.text);
    }
    // zero-arg builtins used without parens: INKEY, RND bare? keep strict.
    if (_at(TokKind.keyword)) {
      // allow builtins as primaries: KEY(...), PEEK(...), RND(...) etc.
      switch (t.text) {
        case 'PEEK':
        case 'PEEKW':
        case 'KEY':
        case 'RND':
        case 'JOY':
        case 'JOYFIRE':
        case 'INKEY':
        case 'IN':
        case 'ABS':
        case 'MIN':
        case 'MAX':
        case 'USR':
        case 'POINT':
        case 'TILEAT':
        case 'TILEFLAGS':
        case 'COLLIDETILE':
        case 'SPRITECOLLIDE':
        case 'SPRITEX':
        case 'SPRITEY':
          _next();
          if (_at(TokKind.lparen)) {
            _next();
            final args = _parseArgList();
            _expect(TokKind.rparen, ')');
            return CallExpr(t.line, t.col, t.text, args);
          }
          return CallExpr(t.line, t.col, t.text, const []);
        default:
          break;
      }
    }
    diag.error(file, t.line, t.col, 'expected expression, found "${t.text}"');
    _next();
    return NumLit(t.line, t.col, 0);
  }
}
