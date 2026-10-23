import 'ast.dart';
import 'diag.dart';
import 'targets.dart';

enum SymKind { constSym, varSym, arraySym, subSym, funcSym, labelSym, paramSym }

/// A user TYPE (C-struct-like): ordered fields with byte offsets.
class StructInfo {
  StructInfo(this.name, this.fields, this.size);
  final String name;
  final Map<String, (RType, int)> fields; // field -> (type, byte offset)
  final int size;
}

class Symbol {
  Symbol(this.name, this.kind, this.type,
      {this.constValue,
      this.size,
      this.dims = const [],
      this.structType,
      this.initValue});

  final String name;
  final SymKind kind;
  RType type;
  int? constValue;
  int? size; // array element count (product of dims)
  List<int> dims = const []; // per-dimension sizes; empty for scalars
  String? structType; // user TYPE name when the var/element is a struct
  int? initValue; // constant initialiser for data-section emission

  String get asmLabel => switch (kind) {
        SymKind.funcSym => 'rbfn_$name',
        SymKind.subSym => 'rbfn_$name',
        SymKind.labelSym =>
          name == 'MAIN' ? 'rb_main' : 'rb_${name.toLowerCase()}',
        _ => 'rbv_$name',
      };
}

class SubInfo {
  SubInfo(this.sym, this.decl);
  final Symbol sym; // kind subSym/funcSym
  final SubDecl decl;
  final Map<String, Symbol> locals = {}; // params + DIMs inside
}

/// Result of semantic analysis: everything codegen needs to resolve names.
class ProgramInfo {
  final Map<String, Symbol> globals = {}; // consts + global vars/arrays
  final Map<String, SubInfo> subs = {}; // SUB/FUNCTION by name
  final Map<String, StructInfo> types = {}; // user TYPEs by name
  final Set<String> labels = {};
  int target = 48;
  String programName = 'RAINBOW';
}

class Sema {
  Sema(this.diag, {this.defaultTarget = 48, this.targetExplicit = false});

  final DiagnosticBag diag;

  /// Target machine (48/128) used when no `TARGET` decl overrides it
  /// (e.g. the project manifest's target).
  final int defaultTarget;

  /// True when [defaultTarget] came from an explicit build/manifest
  /// selection rather than the 48K default — a `TARGET` decl then
  /// conflicts (warning) instead of overriding.
  final bool targetExplicit;

  /// Analyse all units, building the global symbol table.
  ProgramInfo analyze(List<Unit> units) {
    final info = ProgramInfo()..target = defaultTarget;
    _resolveTarget(units, info);
    final resolvedTarget = info.target;
    _definePlatformConsts(info);
    _preScanConsts(units);
    for (final unit in units) {
      _foldIfs(unit.stmts);
    }
    _collectTopLevel(units, info);
    if (info.target != resolvedTarget) {
      diag.error(
          '', 0, 0,
          'TARGET must be declared once at top level, not inside a '
          'conditional IF');
    }
    // second pass: locals inside subs + label collection + call/type checks
    for (final unit in units) {
      _checkUnit(unit, info);
    }
    return info;
  }

  /// Effective target: an explicit build/manifest target wins; otherwise
  /// a top-level `TARGET` decl overrides the 48K default. Diagnostics
  /// for the decl itself are emitted by [_collectTopLevel].
  void _resolveTarget(List<Unit> units, ProgramInfo info) {
    if (targetExplicit) return;
    for (final unit in units) {
      for (final s in unit.stmts) {
        if (s is TargetDecl && kTargetNames.containsKey(s.target)) {
          info.target = s.target;
        }
      }
    }
  }

  /// Built-in compile-time constants for target-conditional code:
  /// `IF CPC THEN ... ELSE ... ENDIF`, CONST arithmetic, etc.
  void _definePlatformConsts(ProgramInfo info) {
    final consts = <String, int>{
      'ZX': platformOf(info.target) == TargetFamily.zx ? 1 : 0,
      'CPC': platformOf(info.target) == TargetFamily.cpc ? 1 : 0,
      'CBM': platformOf(info.target) == TargetFamily.cbm ? 1 : 0,
      'BANKED': bankCapableOf(info.target) ? 1 : 0,
      for (final t in kTargetNames.keys)
        kTargetNames[t]!.toUpperCase(): t == info.target ? 1 : 0,
    };
    for (final e in consts.entries) {
      info.globals.putIfAbsent(
          e.key,
          () => Symbol(e.key, SymKind.constSym, RType.uint,
              constValue: e.value));
      noteConst(e.key, e.value);
    }
  }

  /// Seed the const evaluator with top-level `CONST`s so IF conditions
  /// may use them (and CONSTs may use the platform consts above).
  void _preScanConsts(List<Unit> units) {
    for (final unit in units) {
      for (final s in unit.stmts) {
        if (s is ConstDecl && !_constLookup.containsKey(s.name)) {
          final v = evalConst(s.value);
          if (v != null) noteConst(s.name, v);
        }
      }
    }
  }

  /// Compile-time IF folding: an IF branch whose condition is a
  /// constant expression keeps only the taken branch — dead branches
  /// are removed before checking and codegen, so they may freely use
  /// target-only statements, assets or labels. Non-constant conditions
  /// remain ordinary runtime IFs.
  void _foldIfs(List<Stmt> stmts) {
    for (var i = 0; i < stmts.length; i++) {
      final s = stmts[i];
      switch (s) {
        case WhileStmt w:
          _foldIfs(w.body);
        case RepeatStmt r:
          _foldIfs(r.body);
        case ForStmt f:
          _foldIfs(f.body);
        case SubDecl sd:
          _foldIfs(sd.body);
        default:
          break;
      }
      if (s is! IfStmt) continue;
      for (final b in s.branches) {
        _foldIfs(b.body);
      }
      var runtime = false;
      List<Stmt>? taken;
      final kept = <IfBranch>[];
      for (final b in s.branches) {
        if (b.cond == null) {
          if (runtime) {
            kept.add(b);
          } else {
            taken = b.body;
          }
          break;
        }
        final v = evalConst(b.cond!);
        if (v == null) {
          runtime = true;
          kept.add(b);
        } else if (v == 0) {
          // dead branch — drop it
        } else if (runtime) {
          kept.add(b); // statically-true tail: later branches unreachable
          break;
        } else {
          taken = b.body;
          break;
        }
      }
      if (taken != null) {
        stmts.replaceRange(i, i + 1, taken);
        i += taken.length - 1;
      } else if (kept.isEmpty) {
        stmts.removeAt(i);
        i--;
      } else if (kept.length != s.branches.length) {
        s.branches
          ..clear()
          ..addAll(kept);
      }
    }
  }

  void _collectTopLevel(List<Unit> units, ProgramInfo info) {
    for (final unit in units) {
      for (final s in unit.stmts) {
        switch (s) {
          case ProgramDecl p:
            info.programName = p.name;
          case TargetDecl t:
            if (!kTargetNames.containsKey(t.target)) {
              diag.error(unit.file, s.line, s.col,
                  'TARGET must be one of '
                  '${kTargetNames.values.join(', ')}');
            } else if (targetExplicit) {
              if (t.target != info.target) {
                diag.warn(unit.file, s.line, s.col,
                    'TARGET ${targetNameOf(t.target)} ignored — build '
                    'target is ${targetNameOf(info.target)}');
              }
            } else {
              info.target = t.target;
            }
          case ConstDecl c:
            final v = evalConst(c.value);
            if (v == null) {
              diag.error(unit.file, c.line, c.col,
                  'CONST ${c.name} must be a constant expression');
            }
            _define(
                info.globals,
                unit,
                s,
                Symbol(c.name, SymKind.constSym, RType.uint,
                    constValue: v ?? 0));
            noteConst(c.name, v ?? 0);
          case TypeDecl td:
            _defineType(unit, td, info);
          case DimDecl d:
            if (d.isGlobal) _defineGlobal(unit, s, d, info);
          // non-global DIMs at top level are also global (Rainbow has no
          // separate global section; DIM inside SUB is local).
          case SubDecl sd:
            final kind = sd.isFunction ? SymKind.funcSym : SymKind.subSym;
            final sym =
                Symbol(sd.name, kind, sd.isFunction ? sd.retType : RType.voidT);
            _define(info.globals, unit, s, sym);
            info.subs[sd.name] = SubInfo(sym, sd);
          case LabelStmt l:
            if (!info.labels.add(l.name)) {
              diag.error(unit.file, s.line, s.col, 'duplicate label ${l.name}');
            }
          default:
            break;
        }
      }
    }
    // top-level non-GLOBAL DIMs are global too
    for (final unit in units) {
      for (final s in unit.stmts) {
        if (s is DimDecl && !s.isGlobal) _defineGlobal(unit, s, s, info);
      }
    }
    // collect labels inside subs (labels are global scope)
    for (final unit in units) {
      for (final s in unit.stmts) {
        if (s is SubDecl) {
          for (final inner in _allStmts(s.body)) {
            if (inner is LabelStmt && !info.labels.add(inner.name)) {
              diag.error(unit.file, inner.line, inner.col,
                  'duplicate label ${inner.name}');
            }
          }
        }
      }
    }
    if (!info.labels.contains('MAIN')) {
      diag.error('', 0, 0, 'program has no MAIN: label');
    }
  }

  Iterable<Stmt> _allStmts(List<Stmt> stmts) sync* {
    for (final s in stmts) {
      yield s;
      switch (s) {
        case IfStmt i:
          for (final b in i.branches) {
            yield* _allStmts(b.body);
          }
        case WhileStmt w:
          yield* _allStmts(w.body);
        case RepeatStmt r:
          yield* _allStmts(r.body);
        case ForStmt f:
          yield* _allStmts(f.body);
        default:
          break;
      }
    }
  }

  void _defineType(Unit unit, TypeDecl td, ProgramInfo info) {
    if (info.types.containsKey(td.name) || info.globals.containsKey(td.name)) {
      diag.error(
          unit.file, td.line, td.col, 'duplicate definition of ${td.name}');
      return;
    }
    final fields = <String, (RType, int)>{};
    var off = 0;
    for (final f in td.fields) {
      if (fields.containsKey(f.name)) {
        diag.error(unit.file, td.line, td.col,
            'duplicate field ${f.name} in TYPE ${td.name}');
        continue;
      }
      if (f.type == RType.string) {
        diag.error(unit.file, td.line, td.col,
            'struct field ${f.name} cannot be STRING');
        continue;
      }
      fields[f.name] = (f.type, off);
      off += _typeSize(f.type);
    }
    if (fields.isEmpty) {
      diag.error(unit.file, td.line, td.col, 'TYPE ${td.name} has no fields');
    }
    info.types[td.name] = StructInfo(td.name, fields, off);
  }

  static int _typeSize(RType t) => switch (t) {
        RType.byte => 1,
        _ => 2,
      };

  /// Evaluate DIM subscripts to constant sizes; resolves a user struct
  /// type name. Returns the symbol's dims/size/structType fields filled.
  Symbol _dimSymbol(
      Unit unit, Stmt stmt, DimDecl d, String name, ProgramInfo info) {
    if (d.type == RType.string) {
      diag.error(unit.file, stmt.line, stmt.col,
          'STRING variables are not supported (strings are literal-only)');
    }
    final dims = <int>[];
    var size = 1;
    for (final e in d.dims) {
      var n = evalConst(e);
      if (n == null || n <= 0 || n > 65535) {
        diag.error(unit.file, stmt.line, stmt.col,
            'array size for $name must be a constant 1..65535');
        n = 1;
      }
      dims.add(n);
      size *= n;
    }
    if (d.structType != null && !info.types.containsKey(d.structType)) {
      diag.error(
          unit.file, stmt.line, stmt.col, 'unknown type ${d.structType}');
    } else if (d.structType != null) {
      final t = info.types[d.structType]!;
      return Symbol(
          name, dims.isEmpty ? SymKind.varSym : SymKind.arraySym, RType.structT,
          size: dims.isEmpty ? null : size, dims: dims, structType: t.name);
    }
    return Symbol(
        name, dims.isEmpty ? SymKind.varSym : SymKind.arraySym, d.type,
        size: dims.isEmpty ? null : size, dims: dims);
  }

  void _defineGlobal(Unit unit, Stmt stmt, DimDecl d, ProgramInfo info) {
    _define(info.globals, unit, stmt, _dimSymbol(unit, stmt, d, d.name, info));
  }

  void _define(Map<String, Symbol> scope, Unit unit, Stmt stmt, Symbol sym) {
    final existing = scope[sym.name];
    if (existing != null) {
      diag.error(unit.file, stmt.line, stmt.col,
          'duplicate definition of ${sym.name}');
      return;
    }
    scope[sym.name] = sym;
  }

  // -------------------------------------------------------------------------
  // Pass 2: local vars, labels, name/type checking
  // -------------------------------------------------------------------------

  void _checkUnit(Unit unit, ProgramInfo info) {
    for (final s in unit.stmts) {
      if (s is SubDecl) {
        final sub = info.subs[s.name]!;
        if (s.isFunction && s.retType == RType.string) {
          diag.error(unit.file, s.line, s.col,
              'STRING return type is not supported '
              '(strings are literal-only)');
        }
        for (final p in s.params) {
          if (p.type == RType.string) {
            diag.error(unit.file, s.line, s.col,
                'STRING parameter ${p.name} is not supported '
                '(strings are literal-only)');
          }
          sub.locals[p.name] =
              Symbol('${s.name}_${p.name}', SymKind.paramSym, p.type);
        }
        _checkStmts(unit, s.body, info, sub, s);
      } else {
        _checkStmt(unit, s, info, null, null);
      }
    }
  }

  void _checkStmts(Unit unit, List<Stmt> stmts, ProgramInfo info, SubInfo? sub,
      SubDecl? subDecl) {
    for (final s in stmts) {
      _checkStmt(unit, s, info, sub, subDecl);
    }
  }

  void _checkStmt(
      Unit unit, Stmt s, ProgramInfo info, SubInfo? sub, SubDecl? subDecl) {
    final scope = sub != null ? {...info.globals, ...sub.locals} : info.globals;
    switch (s) {
      case DimDecl d:
        if (sub != null) {
          // local DIM inside a SUB
          final sym =
              _dimSymbol(unit, s, d, '${subDecl!.name}_${d.name}', info);
          if (sub.locals.containsKey(d.name)) {
            diag.error(unit.file, s.line, s.col, 'duplicate local ${d.name}');
          } else {
            sub.locals[d.name] = sym;
          }
        }
        if (d.init != null) {
          _chkNum(unit, d.init!, info, scope,
              'cannot initialise ${d.name} with a string');
        }
      case AssignStmt a:
        final sym = scope[a.name];
        if (sym == null) {
          diag.error(unit.file, s.line, s.col, 'undefined variable ${a.name}');
        } else if (sym.kind == SymKind.constSym) {
          diag.error(
              unit.file, s.line, s.col, 'cannot assign to CONST ${a.name}');
        } else if (a.indices.isNotEmpty && sym.kind != SymKind.arraySym) {
          diag.error(unit.file, s.line, s.col, '${a.name} is not an array');
        } else if (a.indices.isEmpty && sym.kind == SymKind.arraySym) {
          diag.error(unit.file, s.line, s.col,
              '${a.name} is an array; use ${a.name}(index)');
        } else if (a.indices.length != sym.dims.length) {
          diag.error(unit.file, s.line, s.col,
              '${a.name} expects ${sym.dims.length} index(es)');
        } else if (a.field != null) {
          _checkFieldRef(unit, s, a.name, sym, a.field!, info);
        } else if (sym.structType != null) {
          diag.error(unit.file, s.line, s.col,
              'cannot assign to whole struct ${a.name}');
        }
        for (final e in a.indices) {
          _chkNum(unit, e, info, scope, 'array index must be numeric');
        }
        _chkNum(unit, a.value, info, scope,
            'cannot assign a string to ${a.name}');
      case CallStmt c:
        _checkCall(unit, s, c.name, c.args, info, scope);
        for (final e in c.args) {
          typeOf(e, info, scope, unit);
        }
      case IfStmt i:
        for (final b in i.branches) {
          if (b.cond != null) {
            _chkNum(unit, b.cond!, info, scope, 'condition must be numeric');
          }
          _checkStmts(unit, b.body, info, sub, subDecl);
        }
      case WhileStmt w:
        _chkNum(unit, w.cond, info, scope, 'condition must be numeric');
        _checkStmts(unit, w.body, info, sub, subDecl);
      case RepeatStmt r:
        _chkNum(unit, r.cond, info, scope, 'condition must be numeric');
        _checkStmts(unit, r.body, info, sub, subDecl);
      case ForStmt f:
        final sym = scope[f.varName];
        if (sym == null || sym.kind != SymKind.varSym) {
          diag.error(unit.file, s.line, s.col,
              'FOR variable ${f.varName} must be a scalar variable');
        }
        _chkNum(unit, f.from, info, scope, 'FOR bounds must be numeric');
        _chkNum(unit, f.to, info, scope, 'FOR bounds must be numeric');
        if (f.step != null) {
          _chkNum(unit, f.step!, info, scope, 'FOR bounds must be numeric');
        }
        _checkStmts(unit, f.body, info, sub, subDecl);
      case ReturnStmt r:
        if (subDecl == null) {
          diag.error(
              unit.file, s.line, s.col, 'RETURN outside of SUB/FUNCTION');
        } else if (!subDecl.isFunction && r.value != null) {
          diag.error(unit.file, s.line, s.col,
              'RETURN with value only allowed in FUNCTION');
        }
        if (r.value != null) {
          _chkNum(unit, r.value!, info, scope,
              'RETURN value must be numeric');
        }
      case GotoStmt g:
        if (!info.labels.contains(g.name)) {
          diag.error(unit.file, s.line, s.col, 'undefined label ${g.name}');
        }
      case ReadStmt r:
        for (final t in r.targets) {
          _checkStmt(unit, t, info, sub, subDecl);
        }
      default:
        _checkStmtExprs(unit, s, info, scope);
    }
  }

  /// Like [typeOf] but reports [what] when the expression is a string;
  /// the language has no string variables so any string value reaching a
  /// numeric context is a mistake. Returns the expression's type.
  RType _chkNum(Unit unit, Expr e, ProgramInfo info,
      Map<String, Symbol> scope, String what) {
    final t = typeOf(e, info, scope, unit);
    if (t == RType.string) {
      diag.error(unit.file, e.line, e.col, what);
    }
    return t;
  }

  /// Type-check the expressions carried by the remaining statement kinds
  /// (prints, pokes, graphics/sprite args, ...).
  void _checkStmtExprs(
      Unit unit, Stmt s, ProgramInfo info, Map<String, Symbol> scope) {
    void t(Expr e) => _chkNum(
        unit, e, info, scope, 'expected a numeric expression');
    switch (s) {
      case PrintStmt p:
        for (final it in p.items) {
          if (it.expr != null) t(it.expr!);
          if (it.at != null) {
            t(it.at!.$1);
            t(it.at!.$2);
          }
        }
      case LocateStmt l:
        t(l.row);
        t(l.colExpr);
      case Arg1Stmt a:
        t(a.arg);
        if (a.kind == 'MODE') {
          if (platformOf(info.target) == TargetFamily.zx) {
            diag.warn(unit.file, s.line, s.col,
                'MODE has no effect on ZX targets '
                '(no hardware screen modes)');
          }
          final v = evalConst(a.arg);
          if (v != null && (v < 0 || v > 2)) {
            diag.warn(unit.file, s.line, s.col,
                'MODE $v is out of range (0-2)');
          }
        }
      case PokeStmt p:
        t(p.addr);
        t(p.value);
      case OutStmt o:
        t(o.port);
        t(o.value);
      case PauseStmt p:
        t(p.frames);
      case RandomizeStmt r:
        if (r.seed != null) t(r.seed!);
      case FillAttrStmt f:
        t(f.x);
        t(f.y);
        t(f.w);
        t(f.h);
      case PlotStmt p:
        t(p.x);
        t(p.y);
      case SpriteStmt sp:
        for (final e in sp.args) {
          t(e);
        }
      case TilemapStmt tm:
        for (final e in tm.args) {
          t(e);
        }
      case TileAtSetStmt ta:
        t(ta.x);
        t(ta.y);
        t(ta.id);
      case UseBankStmt u:
        t(u.bank);
      case CopyBankStmt c:
        t(c.dest);
      default:
        break;
    }
  }

  void _checkCall(Unit unit, Stmt s, String name, List<Expr> args,
      ProgramInfo info, Map<String, Symbol> scope) {
    final sym = scope[name];
    if (sym != null) {
      if (sym.kind != SymKind.subSym && sym.kind != SymKind.funcSym) {
        diag.error(unit.file, s.line, s.col, '$name is not callable');
        return;
      }
      final decl = info.subs[name]!.decl;
      if (decl.params.length != args.length) {
        diag.error(unit.file, s.line, s.col,
            '$name takes ${decl.params.length} argument(s), got ${args.length}');
      }
      return;
    }
    if (!_builtins.containsKey(name)) {
      diag.error(unit.file, s.line, s.col, 'undefined call $name');
    }
  }

  /// Validate `.field` against a symbol's struct type (assignment targets).
  void _checkFieldRef(Unit unit, Stmt s, String name, Symbol sym, String field,
      ProgramInfo info) {
    _fieldType(unit, s, name, sym, field, info);
  }

  /// Resolve `.field` on a struct symbol to the field's type.
  RType _fieldType(Unit unit, Node n, String name, Symbol sym, String field,
      ProgramInfo info) {
    final st = sym.structType != null ? info.types[sym.structType] : null;
    if (st == null) {
      diag.error(unit.file, n.line, n.col, '$name has no fields');
      return RType.byte;
    }
    final f = st.fields[field];
    if (f == null) {
      diag.error(unit.file, n.line, n.col, '${st.name} has no field $field');
      return RType.byte;
    }
    return f.$1;
  }

  /// Expression type inference. Also reports errors on unknown names.
  RType typeOf(Expr e, ProgramInfo info, Map<String, Symbol> scope, Unit unit) {
    switch (e) {
      case NumLit n:
        if (n.value < 0 || n.value > 0xFFFF) {
          diag.error(
              unit.file, e.line, e.col, 'number ${n.value} out of range');
          return RType.byte;
        }
        return n.value <= 0xFF ? RType.byte : RType.uint;
      case StrLit _:
        return RType.string;
      case VarExpr v:
        final sym = scope[v.name];
        if (sym == null) {
          diag.error(unit.file, e.line, e.col, 'undefined variable ${v.name}');
          return RType.byte;
        }
        if (sym.kind == SymKind.arraySym) {
          diag.error(unit.file, e.line, e.col,
              '${v.name} is an array; use ${v.name}(index)');
          return RType.byte;
        }
        if (v.field != null) {
          return _fieldType(unit, e, v.name, sym, v.field!, info);
        }
        if (sym.structType != null) {
          diag.error(unit.file, e.line, e.col,
              '${v.name} is a struct; access a field with .name');
          return RType.byte;
        }
        return sym.type;
      case ArrayExpr a:
        final sym = scope[a.name];
        if (sym == null) {
          diag.error(unit.file, e.line, e.col, 'undefined variable ${a.name}');
          return RType.byte;
        }
        if (sym.kind != SymKind.arraySym) {
          diag.error(unit.file, e.line, e.col, '${a.name} is not an array');
          return RType.byte;
        }
        if (a.indices.length != sym.dims.length) {
          diag.error(unit.file, e.line, e.col,
              '${a.name} expects ${sym.dims.length} index(es)');
          return RType.byte;
        }
        if (a.field != null) {
          return _fieldType(unit, e, a.name, sym, a.field!, info);
        }
        if (sym.structType != null) {
          diag.error(unit.file, e.line, e.col,
              '${a.name}(...) is a struct; access a field with .name');
          return RType.byte;
        }
        return sym.type;
      case CallExpr c:
        final sym = scope[c.name];
        if (sym != null && sym.kind == SymKind.arraySym) {
          // a(i) — single subscript reads like ArrayExpr
          if (c.args.length != 1 || sym.dims.length != 1) {
            diag.error(unit.file, e.line, e.col,
                '${c.name} expects ${sym.dims.length} index(es)');
            return RType.byte;
          }
          if (sym.structType != null) {
            diag.error(unit.file, e.line, e.col,
                '${c.name}(...) is a struct; access a field with .name');
            return RType.byte;
          }
          return sym.type;
        }
        if (sym != null && sym.kind == SymKind.funcSym) {
          return sym.type;
        }
        if (sym != null && sym.kind == SymKind.subSym) {
          diag.error(unit.file, e.line, e.col,
              'SUB ${c.name} does not return a value');
          return RType.byte;
        }
        if (sym != null) {
          diag.error(unit.file, e.line, e.col, '${c.name} is not callable');
          return RType.byte;
        }
        final b = _builtins[c.name];
        if (b == null) {
          diag.error(unit.file, e.line, e.col, 'undefined function ${c.name}');
          return RType.byte;
        }
        if (b.argCount >= 0 && b.argCount != c.args.length) {
          diag.error(unit.file, e.line, e.col,
              '${c.name} takes ${b.argCount} argument(s)');
        }
        return b.retType;
      case UnaryExpr u:
        if (u.op == UnaryOp.neg) return RType.int;
        if (u.op == UnaryOp.not) return RType.byte;
        return typeOf(u.operand, info, scope, unit);
      case BinExpr b:
        final lt = typeOf(b.left, info, scope, unit);
        final rt = typeOf(b.right, info, scope, unit);
        if (lt == RType.string || rt == RType.string) {
          diag.error(unit.file, e.line, e.col,
              'string operands are not supported in expressions');
          return RType.byte;
        }
        if (b.op == BinOp.div || b.op == BinOp.mod) {
          if (evalConst(b.right) == 0) {
            diag.error(unit.file, b.right.line, b.right.col,
                'division by zero');
          }
        }
        if (b.op == BinOp.eq ||
            b.op == BinOp.ne ||
            b.op == BinOp.lt ||
            b.op == BinOp.gt ||
            b.op == BinOp.le ||
            b.op == BinOp.ge) {
          return RType.byte;
        }
        return _wider(lt, rt);
    }
    return RType.byte;
  }

  RType _wider(RType a, RType b) {
    if (a == RType.string || b == RType.string) return RType.string;
    if (a == RType.int || b == RType.int) return RType.int;
    if (a == RType.uint || b == RType.uint) return RType.uint;
    return RType.byte;
  }

  /// Constant-expression evaluation (numbers, consts, +,-,*,/,MOD, unary).
  int? evalConst(Expr e) {
    switch (e) {
      case NumLit n:
        return n.value;
      case UnaryExpr u:
        final v = evalConst(u.operand);
        if (v == null) return null;
        return u.op == UnaryOp.neg ? -v & 0xFFFF : ~v & 0xFFFF;
      case BinExpr b:
        final l = evalConst(b.left);
        final r = evalConst(b.right);
        if (l == null || r == null) return null;
        return switch (b.op) {
          BinOp.add => (l + r) & 0xFFFF,
          BinOp.sub => (l - r) & 0xFFFF,
          BinOp.mul => (l * r) & 0xFFFF,
          BinOp.div => r == 0 ? null : l ~/ r,
          BinOp.mod => r == 0 ? null : l % r,
          BinOp.and => l & r,
          BinOp.or => l | r,
          BinOp.xor => l ^ r,
          BinOp.eq => l == r ? 1 : 0,
          BinOp.ne => l != r ? 1 : 0,
          BinOp.lt => l < r ? 1 : 0,
          BinOp.gt => l > r ? 1 : 0,
          BinOp.le => l <= r ? 1 : 0,
          BinOp.ge => l >= r ? 1 : 0,
        };
      case VarExpr v:
        return _constLookup[v.name];
      default:
        return null;
    }
  }

  final Map<String, int> _constLookup = {};

  void noteConst(String name, int value) => _constLookup[name] = value;
}

class _Builtin {
  const _Builtin(this.argCount, this.retType);
  final int argCount; // -1 = variadic
  final RType retType;
}

const _builtins = <String, _Builtin>{
  'PEEK': _Builtin(1, RType.byte),
  'PEEKW': _Builtin(1, RType.uint),
  'KEY': _Builtin(1, RType.byte),
  'RND': _Builtin(1, RType.byte),
  'JOY': _Builtin(0, RType.byte),
  'JOYFIRE': _Builtin(0, RType.byte),
  'INKEY': _Builtin(0, RType.byte),
  'IN': _Builtin(1, RType.byte),
  'ABS': _Builtin(1, RType.uint),
  'MIN': _Builtin(2, RType.byte),
  'MAX': _Builtin(2, RType.byte),
  'USR': _Builtin(1, RType.uint),
  'POINT': _Builtin(2, RType.byte),
  'TILEAT': _Builtin(2, RType.byte),
  'TILEFLAGS': _Builtin(1, RType.byte),
  'COLLIDETILE': _Builtin(1, RType.byte),
  'SPRITECOLLIDE': _Builtin(2, RType.byte),
  'SPRITEX': _Builtin(1, RType.byte),
  'SPRITEY': _Builtin(1, RType.byte),
};
