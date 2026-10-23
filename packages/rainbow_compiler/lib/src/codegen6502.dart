import 'dart:typed_data';

import 'ast.dart';
import 'diag.dart';
import 'sema.dart';
import 'targets.dart';

/// 6502 code generator: walks analysed units and emits ca65 assembler
/// for the Commodore family (C64 first, C128 reuses the backend later).
///
/// Conventions (parallel to the Z80 emitter):
///   - BYTE expressions evaluate into A, UINT/INT into the zero-page
///     pair rbt_hl; pointers also live in rbt_hl (indirect via ldy)
///   - binary ops push the left operand then evaluate the right
///     (rbt_ph/rbt_pd for words, pha/pla for bytes)
///   - byte argument registers are the ZP cells rbt_b..rbt_e
///   - variables are static memory cells rbv_<name>
///   - strings pool as rbs_<n>: .byte len,"text"
///   - generated labels are global (rb_l<n>)
///
/// Flag-mapping note: 6502 `cmp` sets C=1 iff A>=operand — the inverse
/// of Z80 `cp`'s borrow — so every carry-conditional jump inverts:
/// Z80 `jp c` -> `bcc`, `jp nc` -> `bcs`.
class CodeGen6502 {
  CodeGen6502(this.info, this.diag,
      {this.assets = const {},
      this.banked = const {},
      this.bankedSize = const {}});

  final ProgramInfo info;
  final DiagnosticBag diag;

  /// Encoded binary assets keyed by sanitized name (see CodeGen).
  final Map<String, Uint8List> assets;
  final Set<String> _usedAssets = {};

  /// Asset keys bound by SPRITE CREATE — emitted .align 64 so encoded
  /// frames sit on 64-byte boundaries and the mux can point the VIC
  /// sprite pointer straight at them (no pool copy).
  final Set<String> _spriteAssets = {};

  /// Banked assets — on cbm these stream off the .d64 via COPYBANK;
  /// kept so the emitter
  /// shares the compiler() call shape.
  final Map<String, ({int bank, int addr})> banked;
  final Map<String, int> bankedSize;
  late final Sema _sema = Sema(diag);

  final StringBuffer _out = StringBuffer();
  final List<String> _strings = [];
  final List<int> _data = []; // DATA pool (word values)
  final usedModules = <String>{'core'};
  final List<String> _forTemps = [];
  int _lc = 0;
  String _curFile = '';
  SubInfo? _sub;

  String _newLabel() => 'rb_l${_lc++}';

  /// Records that [mod] is required, or reports a capability error when
  /// the target platform doesn't provide it. Returns false when the
  /// caller should skip emitting the dependent runtime call.
  bool _use(String mod, Node n, String feature) {
    if (!targetSupportsModule(info.target, mod)) {
      diag.error(_curFile, n.line, n.col,
          '$feature is not yet supported on ${targetNameOf(info.target)}');
      return false;
    }
    usedModules.add(mod);
    return true;
  }

  void _raw(String s) => _out.writeln(s);
  void _i(String s) => _out.writeln('\t$s');
  void _lbl(String s) => _out.writeln('$s:');

  /// Push rbt_hl onto the hardware stack (inline — a helper can't push
  /// data and RTS because the pushed bytes would sit above the return
  /// address). Pop order for rbt_pd is lo then hi.
  void _pushHl() {
    _i('lda\trbt_hl+1');
    _i('pha');
    _i('lda\trbt_hl');
    _i('pha');
  }

  /// Pop a pushed word into rbt_de (matches [_pushHl]).
  void _popDe() {
    _i('pla');
    _i('sta\trbt_de');
    _i('pla');
    _i('sta\trbt_de+1');
  }

  /// Pop a pushed word back into rbt_hl (matches [_pushHl]).
  void _popHl() {
    _i('pla');
    _i('sta\trbt_hl');
    _i('pla');
    _i('sta\trbt_hl+1');
  }
  void _cmt(Stmt s) => _out.writeln('\t; --- $_curFile:${s.line}');

  Map<String, Symbol> get _scope =>
      _sub != null ? {...info.globals, ..._sub!.locals} : info.globals;

  bool _wide(RType t) => t == RType.uint || t == RType.int;

  /// Bytes per element: struct size for user types, 2 for UINT/INT/STRING,
  /// 1 for BYTE.
  int _elemSize(Symbol sym) => sym.structType != null
      ? (info.types[sym.structType]?.size ?? 1)
      : _wide(sym.type) || sym.type == RType.string
          ? 2
          : 1;

  /// The value type produced by a reference: field type when `.field` is
  /// given, otherwise the element/scalar type.
  RType _refType(Symbol sym, String? field) {
    if (field == null) return sym.type;
    return info.types[sym.structType]?.fields[field]?.$1 ?? RType.byte;
  }

  // -------------------------------------------------------------------------
  // Emit helpers (Z80 idiom -> 6502 translation)
  // -------------------------------------------------------------------------

  /// rbt_hl = <expr>  (`ld hl,expr`)
  void _ldhl(String expr) {
    _i('lda\t#<$expr');
    _i('sta\trbt_hl');
    _i('lda\t#>$expr');
    _i('sta\trbt_hl+1');
  }

  /// rbt_de = <expr>  (`ld de,expr`)
  void _ldde(String expr) {
    _i('lda\t#<$expr');
    _i('sta\trbt_de');
    _i('lda\t#>$expr');
    _i('sta\trbt_de+1');
  }

  /// (label) = rbt_hl  (`ld (label),hl`)
  void _sthl(String label) {
    _i('lda\trbt_hl');
    _i('sta\t$label');
    _i('lda\trbt_hl+1');
    _i('sta\t$label+1');
  }

  /// rbt_hl = (label)  (`ld hl,(label)`)
  void _ldhlind(String label) {
    _i('lda\t$label');
    _i('sta\trbt_hl');
    _i('lda\t$label+1');
    _i('sta\trbt_hl+1');
  }

  /// rbt_hl += rbt_de  (`add hl,de`)
  void _addHLDE() {
    _i('clc');
    _i('lda\trbt_hl');
    _i('adc\trbt_de');
    _i('sta\trbt_hl');
    _i('lda\trbt_hl+1');
    _i('adc\trbt_de+1');
    _i('sta\trbt_hl+1');
  }

  /// rbt_hl <<= 1  (`add hl,hl`)
  void _shlHL() {
    _i('asl\trbt_hl');
    _i('rol\trbt_hl+1');
  }

  /// Emit rbt_hl = absolute address of `sym` subscripted by [indices]
  /// plus an optional struct field offset. Row-major.
  void _emitRefAddr(Symbol sym, List<Expr> indices, String? field) {
    final foff = field != null
        ? (info.types[sym.structType]?.fields[field]?.$2 ?? 0)
        : 0;
    if (indices.isEmpty) {
      _ldhl('(${sym.asmLabel}${foff > 0 ? '+$foff' : ''})');
      return;
    }
    _genWord(indices[0]);
    for (var k = 1; k < indices.length; k++) {
      _emitMulHLByConst(sym.dims[k]);
      _pushHl();
      _genWord(indices[k]);
      _popDe();
      _addHLDE();
    }
    final es = _elemSize(sym);
    if (es == 2) {
      _shlHL();
    } else if (es > 2) {
      _emitMulHLByConst(es);
    }
    _ldde('(${sym.asmLabel}${foff > 0 ? '+$foff' : ''})');
    _addHLDE();
  }

  /// Emit rbt_hl = rbt_hl * [n] as shifts and adds (compile-time constant).
  void _emitMulHLByConst(int n) {
    if (n <= 0) {
      _ldhl('0');
      return;
    }
    if (n == 1) return;
    if (n & (n - 1) == 0) {
      for (var i = 0; i < n.bitLength - 1; i++) {
        _shlHL();
      }
      return;
    }
    _i('lda\trbt_hl'); // rbt_de = multiplicand
    _i('sta\trbt_de');
    _i('lda\trbt_hl+1');
    _i('sta\trbt_de+1');
    for (var b = n.bitLength - 2; b >= 0; b--) {
      _shlHL();
      if ((n >> b) & 1 == 1) _addHLDE();
    }
  }

  /// Load the value at (rbt_hl) with width [t]: byte -> A, word -> rbt_hl.
  RType _loadAtHL(RType t) {
    if (_wide(t)) {
      _i('ldy\t#0');
      _i('lda\t(rbt_hl),y');
      _i('sta\trbt_t0');
      _i('ldy\t#1');
      _i('lda\t(rbt_hl),y');
      _i('sta\trbt_hl+1');
      _i('lda\trbt_t0');
      _i('sta\trbt_hl');
    } else {
      _i('ldy\t#0');
      _i('lda\t(rbt_hl),y');
    }
    return t;
  }

  RType _t(Expr e) => _sema.typeOf(e, info, _scope, Unit(_curFile, const []));

  // -------------------------------------------------------------------------
  // Entry
  // -------------------------------------------------------------------------

  String generate(List<Unit> units) {
    for (final s in info.globals.values) {
      if (s.kind == SymKind.constSym && s.constValue != null) {
        _sema.noteConst(s.name, s.constValue!);
      }
    }

    _raw('; generated by rainbow compiler (6502)');
    _raw('; target: ${targetNameOf(info.target)} '
        'program "${info.programName}"');
    _raw('');

    // Pre-scan COPYBANK dests so banked-asset name references can
    // resolve to their resident copy address regardless of source
    // order (SUBs may run long after the copy).
    for (final unit in units) {
      _scanCopyDests(unit.stmts);
    }

    for (final unit in units) {
      _curFile = unit.file;
      for (final s in unit.stmts) {
        _genStmt(s);
      }
    }

    final code = _out.toString();
    _out.clear();

    // ---------------- data section ----------------
    _raw('');
    _raw('; ==================== data ====================');
    _lbl('rbd_data');
    for (var i = 0; i < _data.length; i += 8) {
      final chunk =
          _data.sublist(i, i + 8 > _data.length ? _data.length : i + 8);
      _raw('\t.word\t${chunk.join(',')}');
    }
    for (var i = 0; i < _strings.length; i++) {
      _lbl('rbs_$i');
      final s = _strings[i].replaceAll('"', "'");
      _raw('\t.byte\t${s.length},"$s"');
    }
    for (final l in _forTemps) {
      _lbl(l);
      _raw('\t.word\t0');
    }
    for (final sym in _allVars()) {
      _lbl(sym.asmLabel);
      if (sym.kind == SymKind.arraySym || sym.structType != null) {
        _raw('\t.res\t${(sym.size ?? 1) * _elemSize(sym)}');
      } else if (_wide(sym.type)) {
        _raw('\t.word\t${sym.initValue ?? 0}');
      } else {
        _raw('\t.byte\t${(sym.initValue ?? 0) & 0xFF}');
      }
    }
    for (final e in assets.entries) {
      if (!_usedAssets.contains(e.key)) continue;
      if (_spriteAssets.contains(e.key)) _raw('\t.segment\t"SPDATA"');
      _lbl('rba_${e.key}');
      final d = e.value;
      for (var i = 0; i < d.length; i += 16) {
        final c = d.sublist(i, i + 16 > d.length ? d.length : i + 16);
        _raw('\t.byte\t${c.join(',')}');
      }
      if (_spriteAssets.contains(e.key)) _raw('\t.code');
    }
    // Length-prefixed PETSCII name records for COPYBANK'd (disk-
    // streamed) assets — '_' isn't a PETSCII filename char, use '-'.
    for (final key in banked.keys) {
      if (!_usedAssets.contains(key)) continue;
      final fn =
          key.toUpperCase().replaceAll('_', '-');
      final n = fn.length > 16 ? fn.substring(0, 16) : fn;
      _lbl('rbf_$key');
      _raw('\t.byte\t${n.length},"$n"');
    }
    // frame hook: called once per frame from rbt_rwait callers — will
    // advance SID music when that module lands.
    _lbl('rbt_hook_frame');
    _i(usedModules.contains('sid') ? 'jmp\trbt_sid_tick' : 'rts');
    return code + _out.toString();
  }

  /// COPYBANK "name", dest — kernal LOAD of the asset's disk file.
  /// rbt_de = dest, rbt_hl = length-prefixed name record.
  void _genCopyBank(CopyBankStmt cb, Stmt s) {
    final key = sanitizeAssetName(cb.asset);
    if (!banked.containsKey(key)) {
      if (assets.containsKey(key)) {
        diag.error(_curFile, s.line, s.col,
            'asset "${cb.asset}" is resident, not banked');
      } else {
        diag.error(_curFile, s.line, s.col, 'unknown asset "${cb.asset}"');
      }
      return;
    }
    _usedAssets.add(key);
    _genWord(cb.dest);
    _i('jsr\trbt_xhlde');
    _ldhl('(rbf_$key)');
    _i('jsr\trbt_diskload');
  }

  /// Sanitize an asset name to its map key / label suffix.
  static String sanitizeAssetName(String name) =>
      name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9_]'), '_');

  String _assetLabel(Node n, String name) {
    final key = sanitizeAssetName(name);
    if (!assets.containsKey(key) && !banked.containsKey(key)) {
      diag.error(_curFile, n.line, n.col, 'unknown asset "$name"');
    } else {
      _usedAssets.add(key);
    }
    return 'rba_$key';
  }

  /// COPYBANK destinations gathered by [_scanCopyDests]: a banked
  /// asset's name resolves to the resident RAM the program copies it
  /// into, since cbm assets can't be referenced while still on disk.
  final Map<String, int> _copyDest = {};

  /// Walk the program recording `COPYBANK "x", #const` destinations.
  /// IF branches whose condition is const-false for this target are
  /// skipped; a banked asset is resolvable only when every surviving
  /// COPYBANK gives it the same constant destination.
  void _scanCopyDests(List<Stmt> stmts) {
    final dests = <String, Set<int>>{};
    void walk(List<Stmt> ss) {
      for (final s in ss) {
        switch (s) {
          case CopyBankStmt cb:
            (dests[sanitizeAssetName(cb.asset)] ??= {})
                .add(_sema.evalConst(cb.dest) ?? -1);
          case IfStmt i:
            for (final b in i.branches) {
              final c =
                  b.cond == null ? null : _sema.evalConst(b.cond!);
              if (c == 0) continue; // dead on this target
              walk(b.body);
              if (c != null) break; // const-true: rest unreachable
            }
          case SubDecl sd:
            walk(sd.body);
          case WhileStmt w:
            walk(w.body);
          case RepeatStmt r:
            walk(r.body);
          case ForStmt f:
            walk(f.body);
        }
      }
    }
    walk(stmts);
    for (final e in dests.entries) {
      if (e.value.length == 1 && e.value.first >= 0) {
        _copyDest[e.key] = e.value.first;
      }
    }
  }

  /// Emit rbt_hl = <asset>. Resident assets emit their label; banked
  /// ones resolve to the address a COPYBANK loads them into — cbm has
  /// no banked RAM, so the resident copy is the only live pointer.
  void _loadAssetPtr(Node n, String name) {
    final key = sanitizeAssetName(name);
    final b = banked[key];
    if (b != null) {
      final dest = _copyDest[key];
      if (dest == null) {
        diag.error(_curFile, n.line, n.col,
            'asset "$name" is banked (${targetNameOf(info.target)} '
            'has no banked RAM) — COPYBANK "$name", #<constant addr> '
            'loads it off disk first');
        return;
      }
      _usedAssets.add(key);
      _ldhl('(\$${dest.toRadixString(16)})');
      return;
    }
    _ldhl('(${_assetLabel(n, name)})');
  }

  /// Emit the asset's bank byte into A — always #\$ff on cbm.
  void _emitAssetBank(String name) {
    _i('lda\t#\$ff');
  }

  Iterable<Symbol> _allVars() sync* {
    yield* info.globals.values
        .where((s) => s.kind == SymKind.varSym || s.kind == SymKind.arraySym);
    for (final sub in info.subs.values) {
      yield* sub.locals.values.where((s) =>
          s.kind == SymKind.varSym ||
          s.kind == SymKind.arraySym ||
          s.kind == SymKind.paramSym);
    }
  }

  // -------------------------------------------------------------------------
  // Statements
  // -------------------------------------------------------------------------

  void _genBlock(List<Stmt> stmts) {
    for (final s in stmts) {
      _genStmt(s);
    }
  }

  void _genStmt(Stmt s) {
    switch (s) {
      case ProgramDecl _:
      case TargetDecl _:
      case ConstDecl _:
      case TypeDecl _:
        break;
      case DimDecl d:
        _genDimInit(d);
      case SubDecl sd:
        _genSub(sd);
      case LabelStmt l:
        _lbl(l.name == 'MAIN' ? 'rb_main' : 'rb_${l.name.toLowerCase()}');
        if (l.name == 'MAIN') {
          _ldhl('rbd_data');
          _sthl('rbt_dataptr');
          for (final (sym, expr) in _globalInits) {
            _genExprTyped(expr, sym.type);
            if (_wide(sym.type)) {
              _sthl(sym.asmLabel);
            } else {
              _i('sta\t${sym.asmLabel}');
            }
          }
        }
      case AssignStmt a:
        _cmt(s);
        _genAssign(a);
      case CallStmt c:
        _cmt(s);
        _genCallStmt(c, s);
      case IfStmt i:
        _cmt(s);
        _genIf(i);
      case WhileStmt w:
        _cmt(s);
        final top = _newLabel(), end = _newLabel();
        _lbl(top);
        _emitJumpIfFalse(w.cond, end);
        _genBlock(w.body);
        _i('jmp\t$top');
        _lbl(end);
      case RepeatStmt r:
        _cmt(s);
        final top = _newLabel();
        _lbl(top);
        _genBlock(r.body);
        _emitJumpIfFalse(r.cond, top);
      case ForStmt f:
        _cmt(s);
        _genFor(f);
      case ReturnStmt r:
        _cmt(s);
        if (r.value != null && _sub != null) {
          _genExprTyped(r.value!, _sub!.sym.type);
          _i('jmp\trb_r_${_sub!.sym.name}');
        } else {
          _i('rts');
        }
      case GotoStmt g:
        _cmt(s);
        final lbl = g.name == 'MAIN' ? 'rb_main' : 'rb_${g.name.toLowerCase()}';
        _i(g.isGosub ? 'jsr\t$lbl' : 'jmp\t$lbl');
      case PrintStmt p:
        _cmt(s);
        _genPrint(p);
      case Arg1Stmt a:
        _cmt(s);
        _genArg1(a);
      case ClsStmt _:
        _cmt(s);
        usedModules.add('charset');
        _i('jsr\trbt_cls');
      case PokeStmt p:
        _cmt(s);
        _genWord(p.addr);
        _pushHl();
        _genByte(p.value);
        _i('tax');
        _popHl();
        _i('txa');
        _i('ldy\t#0');
        _i('sta\t(rbt_hl),y');
      case OutStmt o:
        _cmt(s);
        // no port space on the 6502 — OUT writes the value to the
        // memory-mapped address (covers \$D020-style hardware regs).
        _genByte(o.value);
        _i('pha');
        _genWord(o.port);
        _i('pla');
        _i('ldy\t#0');
        _i('sta\t(rbt_hl),y');
      case PauseStmt p:
        _cmt(s);
        _genByte(p.frames);
        _i('sta\trbt_b');
        _i('jsr\trbt_pause');
      case SimpleStmt sm:
        _cmt(s);
        switch (sm.kind) {
          case 'HALT':
            _i('jsr\trbt_vsync');
          case 'WAITKEY':
            _i('jsr\trbt_waitkey');
          case 'END':
            _i('jmp\trbt_end');
          case 'RESTORE':
            _ldhl('rbd_data');
            _sthl('rbt_dataptr');
        }
      case RandomizeStmt r:
        _cmt(s);
        if (r.seed != null) {
          _genWord(r.seed!);
        } else {
          // raster + kernal jiffy clock
          _i('jsr\trbt_mapio'); // c128: $d012 sits in the I/O window
          _i('lda\t\$d012');
          _i('jsr\trbt_maprun');
          _i('sta\trbt_hl');
          _i('lda\t\$a0');
          _i('sta\trbt_hl+1');
        }
        _sthl('rbt_seed');
      case DataStmt d:
        for (final v in d.values) {
          if (v is StrLit) {
            _data.add(_strIndex(v.text) | 0x8000);
          } else {
            _data.add(_sema.evalConst(v) ?? 0);
          }
        }
      case ReadStmt r:
        _cmt(s);
        for (final t in r.targets) {
          _genRead(t);
        }
      case AsmBlock a:
        _cmt(s);
        for (final line in a.lines) {
          if (line.trim().isNotEmpty) _raw(line);
        }
      case JoystickStmt j:
        _cmt(s);
        usedModules.add('input');
        _i('lda\t#${j.mode}');
        _i('sta\trbt_joymode');
      case FillAttrStmt f:
        _cmt(s);
        usedModules.add('charset');
        _emitLoadRegs([(f.x, 'B'), (f.y, 'C'), (f.w, 'D'), (f.h, 'E')]);
        _i('jsr\trbt_fillattr');
      case PlotStmt p:
        _cmt(s);
        if (!_use('pixel', s, 'PLOT')) break;
        _emitLoadRegs([(p.x, 'C'), (p.y, 'B')]);
        _i('jsr\trbt_plot');
      case SpriteStmt sp:
        _cmt(s);
        _genSprite(sp, s);
      case SpritesStmt ss:
        _cmt(s);
        if (!_use('sprite', s, 'sprites')) break;
        _i(ss.op == 'UPDATE'
            ? 'jsr\trbt_sp_update'
            : 'jsr\trbt_sp_drawall');
      case TilesetStmt ts:
        _cmt(s);
        if (!_use('tilemap', s, 'tilemaps')) break;
        _loadAssetPtr(s, ts.asset);
        _emitAssetBank(ts.asset);
        _i('sta\trbt_tm_tbank');
        _i('jsr\trbt_tm_settiles');
      case CharsetStmt cs:
        _cmt(s);
        usedModules.add('charset');
        _loadAssetPtr(s, cs.asset);
        _sthl('rbt_font');
        _emitAssetBank(cs.asset);
        _i('sta\trbt_fontbank');
        _i('jsr\trbt_fset');
      case ShowpicStmt sp:
        _cmt(s);
        if (!_use('pixel', s, 'SHOWPIC')) break;
        _loadAssetPtr(s, sp.asset);
        _i('jsr\trbt_showpic');
      case MusicStmt ms:
        _cmt(s);
        _genMusic(ms, s);
      case SfxStmt sf:
        _cmt(s);
        if (!_use('sfx', s, 'SFX')) break;
        _loadAssetPtr(s, sf.asset);
        _emitAssetBank(sf.asset);
        _i('jsr\trbt_sfx');
      case UseBankStmt():
        _cmt(s);
        diag.error(_curFile, s.line, s.col,
            'USEBANK requires a banked target (zx128/zxplus3/cpc6128)');
      case CopyBankStmt cb:
        _cmt(s);
        // cbm has no banked RAM — banked assets are files on the .d64
        // and COPYBANK is a kernal LOAD into resident memory.
        if (!_use('diskload', s, 'disk COPYBANK')) break;
        _genCopyBank(cb, s);
      case TilemapStmt tm:
        _cmt(s);
        _genTilemap(tm, s);
      case TileAtSetStmt tas:
        _cmt(s);
        if (!_use('tilemap', s, 'tilemaps')) break;
        _emitLoadRegs([(tas.x, 'B'), (tas.y, 'C'), (tas.id, 'D')]);
        _i('jsr\trbt_tileatset');
      default:
        diag.error(
            _curFile, s.line, s.col, 'unsupported statement ${s.runtimeType}');
    }
  }

  /// MUSIC "name" / MUSIC STOP / MUSIC TICK — SID player, non-blocking;
  /// rbt_sid_tick runs once per frame via rbt_hook_frame.
  void _genMusic(MusicStmt ms, Stmt s) {
    if (!_use('sid', s, 'MUSIC')) return;
    switch (ms.op) {
      case 'PLAY':
        _loadAssetPtr(s, ms.asset!);
        _i('jsr\trbt_sid_start');
      case 'STOP':
        _i('jsr\trbt_sid_stop');
      case 'TICK':
        _i('jsr\trbt_sid_tick');
    }
  }

  void _genSub(SubDecl sd) {
    final skip = _newLabel();
    _i('jmp\t$skip');
    final prev = _sub;
    _sub = info.subs[sd.name];
    _lbl('rbfn_${sd.name}');
    for (final s in sd.body) {
      _genStmt(s);
    }
    _lbl('rb_r_${sd.name}');
    _i('rts');
    _lbl(skip);
    _sub = prev;
  }

  /// Global DIMs with non-constant initialisers: emitted at MAIN prologue.
  final List<(Symbol, Expr)> _globalInits = [];

  void _genDimInit(DimDecl d) {
    final sym = _scope[d.name];
    if (sym == null || d.dims.isNotEmpty || d.init == null) return;
    if (_sub == null) {
      final c = _sema.evalConst(d.init!);
      if (c != null) {
        sym.initValue = c;
      } else {
        _globalInits.add((sym, d.init!));
      }
      return;
    }
    _cmt(d);
    _genExprTyped(d.init!, sym.type);
    if (_wide(sym.type)) {
      _sthl(sym.asmLabel);
    } else {
      _i('sta\t${sym.asmLabel}');
    }
  }

  void _genAssign(AssignStmt a) {
    final sym = _scope[a.name];
    if (sym == null) return;
    if (a.indices.isEmpty && a.field == null) {
      _genExprTyped(a.value, sym.type);
      if (_wide(sym.type)) {
        _sthl(sym.asmLabel);
      } else {
        _i('sta\t${sym.asmLabel}');
      }
      return;
    }
    // array element or struct field store
    final ft = _refType(sym, a.field);
    _emitRefAddr(sym, a.indices, a.field);
    _pushHl(); // target address
    _genExprTyped(a.value, ft);
    // byte values arrive in A and would be clobbered by the pop — stash in X
    if (!_wide(ft)) _i('tax');
    _popDe(); // rbt_de = addr, rbt_hl = value
    _i('ldy\t#0');
    _i(_wide(ft) ? 'lda\trbt_hl' : 'txa');
    _i('sta\t(rbt_de),y');
    if (_wide(ft)) {
      _i('iny');
      _i('lda\trbt_hl+1');
      _i('sta\t(rbt_de),y');
    }
  }

  void _genRead(AssignStmt t) {
    final sym = _scope[t.name];
    if (sym == null) return;
    // rbt_de = word at (rbt_dataptr); dataptr += 2
    _i('lda\trbt_dataptr');
    _i('sta\trbt_ptr');
    _i('lda\trbt_dataptr+1');
    _i('sta\trbt_ptr+1');
    _i('ldy\t#0');
    _i('lda\t(rbt_ptr),y');
    _i('sta\trbt_de');
    _i('iny');
    _i('lda\t(rbt_ptr),y');
    _i('sta\trbt_de+1');
    _i('clc');
    _i('lda\trbt_ptr');
    _i('adc\t#2');
    _i('sta\trbt_dataptr');
    _i('lda\trbt_ptr+1');
    _i('adc\t#0');
    _i('sta\trbt_dataptr+1');
    if (t.indices.isNotEmpty || t.field != null) {
      final ft = _refType(sym, t.field);
      _i('lda\trbt_de'); // save the read value
      _i('pha');
      _i('lda\trbt_de+1');
      _i('pha');
      _emitRefAddr(sym, t.indices, t.field);
      _i('pla');
      _i('sta\trbt_de+1');
      _i('pla');
      _i('sta\trbt_de');
      _i('ldy\t#0');
      _i('lda\trbt_de');
      _i('sta\t(rbt_hl),y');
      if (_wide(ft)) {
        _i('iny');
        _i('lda\trbt_de+1');
        _i('sta\t(rbt_hl),y');
      }
    } else if (_wide(sym.type)) {
      _i('lda\trbt_de');
      _i('sta\t${sym.asmLabel}');
      _i('lda\trbt_de+1');
      _i('sta\t${sym.asmLabel}+1');
    } else {
      _i('lda\trbt_de');
      _i('sta\t${sym.asmLabel}');
    }
  }

  void _genIf(IfStmt i) {
    final end = _newLabel();
    for (var b = 0; b < i.branches.length; b++) {
      final branch = i.branches[b];
      final isLast = b == i.branches.length - 1;
      final next = isLast ? end : _newLabel();
      if (branch.cond != null) {
        _emitJumpIfFalse(branch.cond!, next);
      }
      _genBlock(branch.body);
      if (!isLast) {
        _i('jmp\t$end');
        _lbl(next);
      }
    }
    _lbl(end);
  }

  void _genFor(ForStmt f) {
    final sym = _scope[f.varName];
    if (sym == null) return;
    final wide = _wide(sym.type);
    final id = _lc++;
    final endLbl = 'rbf_${id}_end';
    final stepLbl = 'rbf_${id}_step';
    _forTemps.addAll([endLbl, stepLbl]);

    _genExprTyped(f.from, sym.type);
    if (wide) {
      _sthl(sym.asmLabel);
    } else {
      _i('sta\t${sym.asmLabel}');
    }
    _genExprTyped(f.to, sym.type);
    if (wide) {
      _sthl(endLbl);
    } else {
      _i('sta\t$endLbl');
    }
    if (f.step != null) {
      _genExprTyped(f.step!, sym.type);
    } else {
      if (wide) {
        _ldhl('1');
      } else {
        _i('lda\t#1');
      }
    }
    if (wide) {
      _sthl(stepLbl);
    } else {
      _i('sta\t$stepLbl');
    }

    final top = _newLabel(), check = _newLabel(), end = _newLabel();
    _i('jmp\t$check');
    _lbl(top);
    _genBlock(f.body);
    // NEXT: var += step
    if (wide) {
      _i('clc');
      _i('lda\t${sym.asmLabel}');
      _i('adc\t$stepLbl');
      _i('sta\t${sym.asmLabel}');
      _i('lda\t${sym.asmLabel}+1');
      _i('adc\t$stepLbl+1');
      _i('sta\t${sym.asmLabel}+1');
    } else {
      _i('clc');
      _i('lda\t${sym.asmLabel}');
      _i('adc\t$stepLbl');
      _i('sta\t${sym.asmLabel}');
    }
    _lbl(check);
    _emitForExitCheck(sym, endLbl, stepLbl, end);
    _i('jmp\t$top');
    _lbl(end);
  }

  /// Exit when (step > 0 && var > end) or (step < 0 && var < end).
  void _emitForExitCheck(
      Symbol sym, String endLbl, String stepLbl, String exit) {
    final neg = _newLabel(), cont = _newLabel();
    final wide = _wide(sym.type);
    if (wide) {
      _i('lda\t$stepLbl+1');
    } else {
      _i('lda\t$stepLbl');
    }
    _i('bmi\t$neg');
    // positive step: exit if var > end  (i.e. end < var)
    if (wide) {
      _ldhlind(endLbl);
      _ldde('(${sym.asmLabel})');
      _i('jsr\trbt_cmp16');
      _i('bcc\t$exit');
    } else {
      _i('lda\t$endLbl');
      _i('cmp\t${sym.asmLabel}'); // end - var
      _i('bcc\t$exit');
    }
    _i('jmp\t$cont');
    _lbl(neg);
    // negative step: exit if var < end
    if (wide) {
      _ldhlind(sym.asmLabel);
      _ldde('($endLbl)');
      _i('jsr\trbt_cmp16');
      _i('bcc\t$exit');
    } else {
      _i('lda\t${sym.asmLabel}');
      _i('cmp\t$endLbl'); // var - end
      _i('bcc\t$exit');
    }
    _lbl(cont);
  }

  void _genCallStmt(CallStmt c, Stmt s) {
    final sym = _scope[c.name];
    if (sym != null &&
        (sym.kind == SymKind.subSym || sym.kind == SymKind.funcSym)) {
      _genSubCall(info.subs[c.name]!, c.args);
      return;
    }
    diag.error(_curFile, s.line, s.col, 'cannot call ${c.name}');
  }

  void _genSubCall(SubInfo sub, List<Expr> args) {
    final decl = sub.decl;
    for (var i = 0; i < args.length && i < decl.params.length; i++) {
      final psym = sub.locals[decl.params[i].name]!;
      _genExprTyped(args[i], psym.type);
      if (_wide(psym.type)) {
        _sthl(psym.asmLabel);
      } else {
        _i('sta\t${psym.asmLabel}');
      }
    }
    _i('jsr\trbfn_${sub.sym.name}');
  }

  // -------------------------------------------------------------------------
  // Expressions
  // -------------------------------------------------------------------------

  void _genExprTyped(Expr e, RType want) {
    final t = _genExpr(e);
    _convert(t, want);
  }

  void _genByte(Expr e) => _genExprTyped(e, RType.byte);
  void _genWord(Expr e) => _genExprTyped(e, RType.uint);

  RType _genExpr(Expr e) {
    switch (e) {
      case NumLit n:
        if (n.value <= 0xFF) {
          _i('lda\t#${n.value}');
          return RType.byte;
        }
        _ldhl('${n.value}');
        return RType.uint;
      case StrLit s:
        _ldhl('(rbs_${_strIndex(s.text)})');
        return RType.string;
      case VarExpr v:
        final sym = _scope[v.name];
        if (sym == null) {
          _i('lda\t#0');
          return RType.byte;
        }
        if (sym.kind == SymKind.constSym) {
          final val = sym.constValue ?? 0;
          if (val >= 0 && val <= 0xFF) {
            _i('lda\t#$val');
            return RType.byte;
          }
          _ldhl('$val');
          return RType.uint;
        }
        if (v.field != null) {
          final ft = _refType(sym, v.field);
          _emitRefAddr(sym, const [], v.field);
          return _loadAtHL(ft);
        }
        if (_wide(sym.type)) {
          _ldhlind(sym.asmLabel);
        } else {
          _i('lda\t${sym.asmLabel}');
        }
        return sym.type;
      case ArrayExpr a:
        final sym = _scope[a.name];
        if (sym == null) {
          _i('lda\t#0');
          return RType.byte;
        }
        final ft = _refType(sym, a.field);
        _emitRefAddr(sym, a.indices, a.field);
        return _loadAtHL(ft);
      case UnaryExpr u:
        final t = _genExpr(u.operand);
        switch (u.op) {
          case UnaryOp.neg:
            if (!_wide(t)) {
              _convert(t, RType.uint);
            }
            usedModules.add('math');
            _i('jsr\trbt_neg16');
            return RType.int;
          case UnaryOp.not:
            if (_wide(t)) {
              _i('lda\trbt_hl');
              _i('ora\trbt_hl+1');
            } else {
              _i('cmp\t#0');
            }
            _emitToA(zeroTrue: true);
            return RType.byte;
        }
      case BinExpr b:
        return _genBin(b);
      case CallExpr c:
        return _genCallExpr(c);
    }
    throw StateError('unhandled expression $e');
  }

  void _convert(RType from, RType to) {
    if (from == to) return;
    if (_wide(from) && !_wide(to)) {
      _i('lda\trbt_hl');
      return;
    }
    if (!_wide(from) && _wide(to)) {
      if (from == RType.int) {
        // sign-extend A into rbt_hl
        final pos = _newLabel();
        _i('sta\trbt_hl');
        _i('lda\t#0');
        _i('bit\trbt_hl');
        _i('bpl\t$pos');
        _i('lda\t#\$ff');
        _lbl(pos);
        _i('sta\trbt_hl+1');
      } else {
        _i('sta\trbt_hl');
        _i('lda\t#0');
        _i('sta\trbt_hl+1');
      }
    }
  }

  RType _genBin(BinExpr b) {
    final lt = _t(b.left), rt = _t(b.right);
    final wt = (lt == RType.int || rt == RType.int)
        ? RType.int
        : (_wide(lt) || _wide(rt) ? RType.uint : RType.byte);

    if (wt == RType.byte) {
      _genByte(b.left);
      _i('pha');
      _genByte(b.right);
      _i('sta\trbt_c'); // rbt_c = right
      _i('pla');
      _i('sta\trbt_b'); // rbt_b = left
      switch (b.op) {
        case BinOp.add:
          _i('clc');
          _i('lda\trbt_b');
          _i('adc\trbt_c');
        case BinOp.sub:
          _i('sec');
          _i('lda\trbt_b');
          _i('sbc\trbt_c');
        case BinOp.mul:
          usedModules.add('math');
          _i('lda\trbt_b');
          _i('sta\trbt_d');
          _i('lda\trbt_c');
          _i('sta\trbt_e');
          _i('jsr\trbt_mul8');
          _i('lda\trbt_hl');
        case BinOp.div:
          usedModules.add('math');
          _i('lda\trbt_b'); // A = dividend (left)
          _i('ldx\trbt_c');
          _i('stx\trbt_b'); // rbt_b = divisor (right)
          _i('jsr\trbt_divmod8');
        case BinOp.mod:
          usedModules.add('math');
          _i('lda\trbt_b');
          _i('ldx\trbt_c');
          _i('stx\trbt_b');
          _i('jsr\trbt_divmod8');
          _i('lda\trbt_b'); // remainder
        case BinOp.and:
          _i('lda\trbt_b');
          _i('and\trbt_c');
        case BinOp.or:
          _i('lda\trbt_b');
          _i('ora\trbt_c');
        case BinOp.xor:
          _i('lda\trbt_b');
          _i('eor\trbt_c');
        case BinOp.eq ||
              BinOp.ne ||
              BinOp.lt ||
              BinOp.gt ||
              BinOp.le ||
              BinOp.ge:
          _i('lda\trbt_b');
          _i('cmp\trbt_c'); // left - right
          _emitCondToA(b.op);
          return RType.byte;
      }
      return wt;
    }

    // word path: push left, eval right, rbt_de = left, rbt_hl = right
    _genWord(b.left);
    _pushHl();
    _genWord(b.right);
    _popDe();
    switch (b.op) {
      case BinOp.add:
        _addHLDE();
      case BinOp.sub:
        _i('jsr\trbt_xhlde'); // hl = left
        _i('jsr\trbt_sub16');
      case BinOp.mul:
        if (b.right case NumLit n when n.value >= 0 && n.value <= 255) {
          _i('jsr\trbt_xhlde'); // hl = left
          _emitMulHLByConst(n.value);
        } else if (b.left case NumLit n when n.value >= 0 && n.value <= 255) {
          _emitMulHLByConst(n.value); // hl = right
        } else {
          usedModules.add('math');
          _i('jsr\trbt_mul16');
        }
      case BinOp.div:
        usedModules.add('math');
        _i('jsr\trbt_xhlde'); // hl = left (dividend)
        _i('lda\trbt_hl');
        _i('sta\trbt_bc');
        _i('lda\trbt_hl+1');
        _i('sta\trbt_bc+1');
        _i(wt == RType.int
            ? 'jsr\trbt_sdivmod16'
            : 'jsr\trbt_divmod16');
        _i('lda\trbt_bc');
        _i('sta\trbt_hl');
        _i('lda\trbt_bc+1');
        _i('sta\trbt_hl+1');
      case BinOp.mod:
        usedModules.add('math');
        _i('jsr\trbt_xhlde');
        _i('lda\trbt_hl');
        _i('sta\trbt_bc');
        _i('lda\trbt_hl+1');
        _i('sta\trbt_bc+1');
        _i(wt == RType.int
            ? 'jsr\trbt_sdivmod16'
            : 'jsr\trbt_divmod16');
        // remainder already in rbt_hl
      case BinOp.and:
        _i('lda\trbt_hl');
        _i('and\trbt_de');
        _i('sta\trbt_hl');
        _i('lda\trbt_hl+1');
        _i('and\trbt_de+1');
        _i('sta\trbt_hl+1');
      case BinOp.or:
        _i('lda\trbt_hl');
        _i('ora\trbt_de');
        _i('sta\trbt_hl');
        _i('lda\trbt_hl+1');
        _i('ora\trbt_de+1');
        _i('sta\trbt_hl+1');
      case BinOp.xor:
        _i('lda\trbt_hl');
        _i('eor\trbt_de');
        _i('sta\trbt_hl');
        _i('lda\trbt_hl+1');
        _i('eor\trbt_de+1');
        _i('sta\trbt_hl+1');
      case BinOp.eq || BinOp.ne || BinOp.lt || BinOp.gt || BinOp.le || BinOp.ge:
        _i('jsr\trbt_xhlde'); // hl = left, de = right
        if (wt == RType.int) {
          _i('lda\trbt_hl+1');
          _i('eor\t#\$80');
          _i('sta\trbt_hl+1');
          _i('lda\trbt_de+1');
          _i('eor\t#\$80');
          _i('sta\trbt_de+1');
        }
        _i('jsr\trbt_cmp16');
        _emitCondToA(b.op);
        return RType.byte;
    }
    return wt;
  }

  /// After flags set by a compare (byte cmp / rbt_cmp16), produce A = 0/1.
  /// 6502 C semantics are the inverse of Z80 borrow, so the false-branch
  /// per op differs from the Z80 emitter.
  void _emitCondToA(BinOp op) {
    final z = _newLabel(), e = _newLabel();
    switch (op) {
      case BinOp.eq:
        _i('bne\t$z');
        _emitTrueFalse(z, e);
      case BinOp.ne:
        _i('beq\t$z');
        _emitTrueFalse(z, e);
      case BinOp.lt:
        _i('bcs\t$z'); // C=1 -> left >= right -> false
        _emitTrueFalse(z, e);
      case BinOp.ge:
        _i('bcc\t$z'); // C=0 -> left < right -> false
        _emitTrueFalse(z, e);
      case BinOp.le:
        // true iff left < right (C=0) or equal (Z=1)
        final y = _newLabel();
        _i('bcc\t$y');
        _i('beq\t$y');
        _i('jmp\t$z');
        _lbl(y);
        _emitTrueFalse(z, e);
      case BinOp.gt:
        // false iff equal (Z=1) or left < right (C=0)
        _i('beq\t$z');
        _i('bcc\t$z');
        _emitTrueFalse(z, e);
      default:
        _lbl(z);
        _lbl(e);
    }
  }

  /// Emit: lda #1 / jmp end / z: lda #0 / end:
  void _emitTrueFalse(String z, String e) {
    _i('lda\t#1');
    _i('jmp\t$e');
    _lbl(z);
    _i('lda\t#0');
    _lbl(e);
  }

  void _emitToA({required bool zeroTrue}) {
    final z = _newLabel(), e = _newLabel();
    _i('cmp\t#0');
    _i(zeroTrue ? 'bne\t$z' : 'beq\t$z');
    _emitTrueFalse(z, e);
  }

  /// Inverted-branch + jmp trampoline for conditional jumps: 6502
  /// branches are ±127 bytes, so `bXX target` becomes
  /// `bYY skip; jmp target; skip:` — always in range.
  static const _invBr = {
    'beq': 'bne', 'bne': 'beq',
    'bcc': 'bcs', 'bcs': 'bcc',
    'bmi': 'bpl', 'bpl': 'bmi',
  };
  void _br(String op, String target) {
    final sk = _newLabel();
    _i('${_invBr[op]}\t$sk');
    _i('jmp\t$target');
    _lbl(sk);
  }

  /// Jump to [target] when the condition is FALSE.
  void _emitJumpIfFalse(Expr cond, String target) {
    if (cond is BinExpr &&
        const {BinOp.eq, BinOp.ne, BinOp.lt, BinOp.gt, BinOp.le, BinOp.ge}
            .contains(cond.op)) {
      final lt = _t(cond.left), rt = _t(cond.right);
      final wide = _wide(lt) || _wide(rt);
      if (!wide) {
        _genByte(cond.left);
        _i('pha');
        _genByte(cond.right);
        _i('sta\trbt_c');
        _i('pla');
        _i('cmp\trbt_c'); // left - right
      } else {
        final signed = lt == RType.int || rt == RType.int;
        _genWord(cond.left);
        _pushHl();
        _genWord(cond.right);
        _popDe();
        _i('jsr\trbt_xhlde'); // hl = left, de = right
        if (signed) {
          _i('lda\trbt_hl+1');
          _i('eor\t#\$80');
          _i('sta\trbt_hl+1');
          _i('lda\trbt_de+1');
          _i('eor\t#\$80');
          _i('sta\trbt_de+1');
        }
        _i('jsr\trbt_cmp16');
      }
      switch (cond.op) {
        case BinOp.eq:
          _br('bne', target);
        case BinOp.ne:
          _br('beq', target);
        case BinOp.lt:
          _br('bcs', target);
        case BinOp.ge:
          _br('bcc', target);
        case BinOp.gt:
          _br('beq', target); // false iff equal or less
          _br('bcc', target);
        case BinOp.le:
          // false iff left > right: C=1 and Z=0 — skip check when equal
          final sk = _newLabel();
          _i('beq\t$sk');
          _br('bcs', target);
          _lbl(sk);
        default:
          break;
      }
      return;
    }
    _genByte(cond);
    _i('cmp\t#0');
    _br('beq', target);
  }

  RType _genCallExpr(CallExpr c) {
    final sym = _scope[c.name];
    if (sym != null && sym.kind == SymKind.arraySym) {
      _emitRefAddr(sym, c.args, null);
      return _loadAtHL(sym.type);
    }
    if (sym != null && sym.kind == SymKind.funcSym) {
      _genSubCall(info.subs[c.name]!, c.args);
      return sym.type;
    }
    switch (c.name) {
      case 'PEEK':
        _genWord(c.args[0]);
        _i('ldy\t#0');
        _i('lda\t(rbt_hl),y');
        return RType.byte;
      case 'PEEKW':
        _genWord(c.args[0]);
        _i('ldy\t#0');
        _i('lda\t(rbt_hl),y');
        _i('sta\trbt_t0');
        _i('ldy\t#1');
        _i('lda\t(rbt_hl),y');
        _i('sta\trbt_hl+1');
        _i('lda\trbt_t0');
        _i('sta\trbt_hl');
        return RType.uint;
      case 'KEY':
        usedModules.add('input');
        _genByte(c.args[0]);
        _i('jsr\trbt_key');
        return RType.byte;
      case 'RND':
        if (c.args.isEmpty) {
          _i('jsr\trbt_rnd8');
        } else {
          _genByte(c.args[0]);
          _i('sta\trbt_b');
          _i('jsr\trbt_rnd8');
          _i('jsr\trbt_mod8');
        }
        return RType.byte;
      case 'JOY':
        usedModules.add('input');
        _i('jsr\trbt_joy');
        return RType.byte;
      case 'JOYFIRE':
        usedModules.add('input');
        _i('jsr\trbt_joy');
        _i('and\t#16');
        _emitToA(zeroTrue: false);
        return RType.byte;
      case 'INKEY':
        usedModules.add('input');
        _i('jsr\trbt_inkey');
        return RType.byte;
      case 'IN':
        _genWord(c.args[0]);
        _i('ldy\t#0');
        _i('lda\t(rbt_hl),y');
        return RType.byte;
      case 'ABS':
        final t = _genExpr(c.args[0]);
        if (_wide(t)) {
          usedModules.add('math');
          _i('jsr\trbt_abs16');
          return t;
        }
        return RType.byte;
      case 'MIN':
      case 'MAX':
        return _genMinMax(c);
      case 'POINT':
        if (!_use('pixel', c, 'POINT')) return RType.byte;
        _emitLoadRegs([(c.args[0], 'C'), (c.args[1], 'B')]);
        _i('jsr\trbt_point');
        return RType.byte;
      case 'SPRITEX':
        if (!_use('sprite', c, 'sprites')) return RType.byte;
        _genByte(c.args[0]);
        _i('jsr\trbt_spx');
        return RType.byte;
      case 'SPRITEY':
        if (!_use('sprite', c, 'sprites')) return RType.byte;
        _genByte(c.args[0]);
        _i('jsr\trbt_spy');
        return RType.byte;
      case 'SPRITECOLLIDE':
        if (!_use('sprite', c, 'sprites')) return RType.byte;
        _emitLoadRegs([(c.args[0], 'A'), (c.args[1], 'B')]);
        _i('jsr\trbt_spcoll');
        return RType.byte;
      case 'TILEAT':
        if (!_use('tilemap', c, 'tilemaps')) return RType.byte;
        _emitLoadRegs([(c.args[0], 'B'), (c.args[1], 'C')]);
        _i('jsr\trbt_tileat');
        return RType.byte;
      case 'TILEFLAGS':
        if (!_use('tilemap', c, 'tilemaps')) return RType.byte;
        _genByte(c.args[0]);
        _i('jsr\trbt_tileflags');
        return RType.byte;
      case 'COLLIDETILE':
        if (!_use('sprite', c, 'sprites') ||
            !_use('tilemap', c, 'tilemaps') ||
            !_use('spcoll', c, 'sprite-tile collision')) return RType.byte;
        _genByte(c.args[0]);
        _i('jsr\trbt_colltile');
        return RType.byte;
      case 'USR':
        final ret = _newLabel();
        _genWord(c.args[0]);
        _i('lda\t#>($ret-1)');
        _i('pha');
        _i('lda\t#<($ret-1)');
        _i('pha');
        _i('jmp\t(rbt_hl)');
        _lbl(ret);
        return RType.uint;
      default:
        diag.error(_curFile, c.line, c.col, 'unknown call ${c.name}');
        _i('lda\t#0');
        return RType.byte;
    }
  }

  RType _genMinMax(CallExpr c) {
    final isMin = c.name == 'MIN';
    final lt = _t(c.args[0]), rt = _t(c.args[1]);
    final wide = _wide(lt) || _wide(rt);
    final keep = _newLabel(), done = _newLabel();
    if (!wide) {
      _genByte(c.args[0]);
      _i('pha');
      _genByte(c.args[1]);
      _i('sta\trbt_c'); // right
      _i('pla');
      _i('sta\trbt_b'); // left
      _i('lda\trbt_b');
      _i('cmp\trbt_c'); // left - right
      _i(isMin ? 'bcc\t$keep' : 'bcs\t$keep');
      _i('lda\trbt_c'); // right
      _i('jmp\t$done');
      _lbl(keep);
      _i('lda\trbt_b'); // left
      _lbl(done);
      return RType.byte;
    }
    _genWord(c.args[0]);
    _pushHl();
    _genWord(c.args[1]);
    _popDe();
    _i('jsr\trbt_xhlde'); // hl = left, de = right
    _i('jsr\trbt_cmp16');
    _i(isMin ? 'bcc\t$keep' : 'bcs\t$keep');
    _i('jsr\trbt_xhlde'); // hl = right
    _i('jmp\t$done');
    _lbl(keep);
    _lbl(done);
    return RType.uint;
  }

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  /// Evaluate each expr and land it in the named byte register —
  /// 'A' is the accumulator itself, 'B'..'E' are the ZP cells
  /// rbt_b..rbt_e (the Z80 B/C/D/E roles).
  void _emitLoadRegs(List<(Expr, String)> args) {
    for (var i = args.length - 1; i >= 0; i--) {
      _genByte(args[i].$1);
      _i('pha');
    }
    var needTxa = false;
    for (final (_, reg) in args) {
      if (reg == 'A') {
        // no PLX on the 6510 — pop to A then stash in X so a later
        // pla doesn't clobber it
        _i('pla');
        _i('tax');
        needTxa = true;
      } else {
        _i('pla');
        _i('sta\trbt_${reg.toLowerCase()}');
      }
    }
    if (needTxa) _i('txa');
  }

  int _strIndex(String s) {
    var i = _strings.indexOf(s);
    if (i < 0) {
      _strings.add(s);
      i = _strings.length - 1;
    }
    return i;
  }

  void _genPrint(PrintStmt p) {
    usedModules.add('charset');
    for (final item in p.items) {
      if (item.at != null) {
        _emitLoadRegs([(item.at!.$2, 'B'), (item.at!.$1, 'C')]);
        _i('jsr\trbt_locate');
      } else if (item.text != null) {
        _ldhl('(rbs_${_strIndex(item.text!)})');
        _i('jsr\trbt_print_str');
      } else if (item.expr != null) {
        final t = _genExpr(item.expr!);
        if (t == RType.string) {
          _i('jsr\trbt_print_str');
        } else if (_wide(t)) {
          _i('jsr\trbt_print_u16');
        } else {
          _i('jsr\trbt_print_u8');
        }
      }
    }
    if (!p.noNewline) {
      _i('jsr\trbt_newline');
    }
  }

  void _genSprite(SpriteStmt sp, Stmt s) {
    if (!_use('sprite', s, 'sprites')) return;
    Expr arg(int i, [int dflt = 0]) =>
        i < sp.args.length ? sp.args[i] : NumLit(s.line, s.col, dflt);
    switch (sp.op) {
      case 'CREATE':
        _emitLoadRegs([
          (arg(0), 'A'),
          (NumLit(s.line, s.col, sp.mode), 'B'),
          (arg(1), 'C'),
          (arg(2), 'D'),
        ]);
        // keep the sprite id in A across the asset-bank byte
        _i('pha');
        _emitAssetBank(sp.asset!); // A = bank -> slot record (via E)
        _i('sta\trbt_e');
        _spriteAssets.add(sanitizeAssetName(sp.asset!));
        _loadAssetPtr(s, sp.asset!);
        _i('pla');
        _i('jsr\trbt_sp_create');
      case 'MOVE':
        _emitLoadRegs([(arg(0), 'A'), (arg(1), 'B'), (arg(2), 'C')]);
        _i('jsr\trbt_sp_move');
      case 'PLACE':
        _emitLoadRegs([(arg(0), 'A'), (arg(1), 'B'), (arg(2), 'C')]);
        _i('jsr\trbt_sp_place');
      case 'FRAME':
        _emitLoadRegs([(arg(0), 'A'), (arg(1), 'B')]);
        _i('jsr\trbt_sp_frame');
      case 'ANIMATE':
        _emitLoadRegs([
          (arg(0), 'A'),
          (arg(1), 'B'),
          (arg(2), 'C'),
          (NumLit(s.line, s.col, sp.pingpong ? 1 : 0), 'D'),
        ]);
        _i('jsr\trbt_sp_anim');
      case 'REMOVE':
        _emitLoadRegs([(arg(0), 'A')]);
        _i('jsr\trbt_sp_kill');
      case 'HIDE':
        _emitLoadRegs([(arg(0), 'A')]);
        _i('jsr\trbt_sp_hide');
      case 'SHOW':
        _emitLoadRegs([(arg(0), 'A')]);
        _i('jsr\trbt_sp_show');
      case 'REDRAW':
        _emitLoadRegs([(arg(0), 'A')]);
        _i('jsr\trbt_sp_draw');
      case 'ATTR':
        // C64 hardware sprites take a colour nibble directly
        _emitLoadRegs([(arg(0), 'A'), (arg(1), 'B')]);
        _i('jsr\trbt_sp_attr');
      default:
        diag.error(_curFile, s.line, s.col, 'unknown SPRITE op ${sp.op}');
    }
  }

  void _genTilemap(TilemapStmt tm, Stmt s) {
    if (!_use('tilemap', s, 'tilemaps')) return;
    Expr arg(int i, [int dflt = 0]) =>
        i < tm.args.length ? tm.args[i] : NumLit(s.line, s.col, dflt);
    switch (tm.op) {
      case 'BIND':
        _loadAssetPtr(s, tm.asset!);
        _emitAssetBank(tm.asset!);
        _i('sta\trbt_tm_mbank');
        _i('jsr\trbt_tm_setmap');
      case 'VIEW':
        _emitLoadRegs(
            [(arg(0), 'B'), (arg(1), 'C'), (arg(2), 'D'), (arg(3), 'E')]);
        _i('jsr\trbt_tm_view');
      case 'CAMERA':
        _emitLoadRegs([(arg(0), 'B'), (arg(1), 'C')]);
        _i('jsr\trbt_tm_camera');
      case 'DRAW':
        _i('jsr\trbt_tm_draw');
      case 'SCROLL':
        _i('lda\t#${tm.dir}');
        _i('pha');
        _genByte(arg(0, 1));
        _i('sta\trbt_b');
        _i('pla');
        _i('jsr\trbt_tm_scroll');
      case 'REDRAW':
        _emitLoadRegs(
            [(arg(0), 'B'), (arg(1), 'C'), (arg(2), 'D'), (arg(3), 'E')]);
        _i('jsr\trbt_tm_redraw');
      default:
        diag.error(_curFile, s.line, s.col, 'unknown TILEMAP op ${tm.op}');
    }
  }

  void _genArg1(Arg1Stmt a) {
    switch (a.kind) {
      case 'BORDER':
        _genByte(a.arg);
        _i('jsr\trbt_border');
      case 'INK':
      case 'PAPER':
      case 'BRIGHT':
      case 'FLASH':
        usedModules.add('charset');
        _genByte(a.arg);
        _i('jsr\trbt_${a.kind.toLowerCase()}');
      case 'OVER':
        _genByte(a.arg);
        _i('sta\trbt_over');
      case 'MODE':
        _genByte(a.arg);
        _i('jsr\trbt_scrmode');
      default:
        diag.error(_curFile, a.line, a.col, 'unknown statement ${a.kind}');
    }
  }
}
