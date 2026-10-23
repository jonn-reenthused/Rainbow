import 'dart:typed_data';

import 'ast.dart';
import 'diag.dart';
import 'sema.dart';
import 'targets.dart';

/// Z80 code generator: walks analysed units and emits Pasmo assembler.
///
/// Conventions:
///   - BYTE expressions evaluate into A, UINT/INT into HL
///   - binary ops push the left operand then evaluate the right
///   - variables are static memory cells rbv_<name>
///   - strings pool as rbs_<n>: defb len,"text"
///   - generated labels are global (rb_l<n>) so local-label scoping
///     inside runtime code can never collide with them
class CodeGen {
  CodeGen(this.info, this.diag,
      {this.assets = const {},
      this.banked = const {},
      this.bankedSize = const {},
      this.bankLens = const {},
      this.cart = false});

  final ProgramInfo info;
  final DiagnosticBag diag;

  /// Encoded binary assets keyed by sanitized name (rbs/rbt/rbm payloads).
  /// Emitted as `rba_<name>` in the data section — only when referenced
  /// by the code (e.g. the `loading` screen asset stays out of the binary
  /// unless the program uses `SHOWPIC "loading"`).
  final Map<String, Uint8List> assets;
  final Set<String> _usedAssets = {};

  /// Banked (128K) assets: name -> (bank, absolute address in the bank
  /// window — 0xC000 on ZX, 0x4000 on CPC). Referencing one emits a
  /// page-in first; the bytes live in the bank blocks, not the resident
  /// binary.
  final Map<String, ({int bank, int addr})> banked;

  /// Banked asset payload sizes (for COPYBANK's LDIR length).
  final Map<String, int> bankedSize;

  /// Whole-bank blob sizes, bank -> bytes. CPC cart builds emit these
  /// in `rbt_cartfiles` so the loader knows each page's copy length.
  final Map<int, int> bankLens;

  /// Cartridge build: the image is ROM at $0000, so the CPC runtime
  /// can't touch the filesystem — `rbt_cartfiles` replaces
  /// `rbt_bankfiles` and points the loader at cart pages instead.
  final bool cart;
  late final Sema _sema = Sema(diag);

  final StringBuffer _out = StringBuffer();
  final List<String> _strings = [];
  final List<int> _data = []; // DATA pool (word values)
  final usedModules = <String>{'core'};
  final List<String> _forTemps = []; // rbf_* labels needing defs
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

  /// Emit HL = absolute address of `sym` subscripted by [indices] plus an
  /// optional struct field offset. Row-major: the flat index folds as
  /// ((i0 * dims[1] + i1) * dims[2] + ...).
  void _emitRefAddr(Symbol sym, List<Expr> indices, String? field) {
    final foff = field != null
        ? (info.types[sym.structType]?.fields[field]?.$2 ?? 0)
        : 0;
    if (indices.isEmpty) {
      _i('ld\thl,${sym.asmLabel}${foff > 0 ? '+$foff' : ''}');
      return;
    }
    _genWord(indices[0]);
    for (var k = 1; k < indices.length; k++) {
      _emitMulHLByConst(sym.dims[k]); // HL = acc * dims[k]
      _i('push\thl');
      _genWord(indices[k]);
      _i('pop\tde');
      _i('add\thl,de');
    }
    final es = _elemSize(sym);
    if (es == 2) {
      _i('add\thl,hl');
    } else if (es > 2) {
      _emitMulHLByConst(es); // HL = flat * elemSize
    }
    _i('ld\tde,${sym.asmLabel}${foff > 0 ? '+$foff' : ''}');
    _i('add\thl,de');
  }

  /// Emit HL = HL * [n] as shifts and adds; [n] is a compile-time constant.
  /// For a power of two this is pure `add hl,hl`; otherwise DE holds the
  /// multiplicand while remaining set bits are folded in.
  void _emitMulHLByConst(int n) {
    if (n <= 0) {
      _i('ld\thl,0');
      return;
    }
    if (n == 1) return;
    if (n & (n - 1) == 0) {
      for (var i = 0; i < n.bitLength - 1; i++) {
        _i('add\thl,hl');
      }
      return;
    }
    _i('ld\td,h');
    _i('ld\te,l');
    for (var b = n.bitLength - 2; b >= 0; b--) {
      _i('add\thl,hl');
      if ((n >> b) & 1 == 1) _i('add\thl,de');
    }
  }

  /// Load the value at HL with width [t]: byte -> A, word -> HL.
  RType _loadAtHL(RType t) {
    if (_wide(t)) {
      _i('ld\ta,(hl)');
      _i('inc\thl');
      _i('ld\th,(hl)');
      _i('ld\tl,a');
    } else {
      _i('ld\ta,(hl)');
    }
    return t;
  }

  RType _t(Expr e) => _sema.typeOf(e, info, _scope, Unit(_curFile, const []));

  // -------------------------------------------------------------------------
  // Entry
  // -------------------------------------------------------------------------

  String generate(List<Unit> units) {
    // seed const table for constant folding
    for (final s in info.globals.values) {
      if (s.kind == SymKind.constSym && s.constValue != null) {
        _sema.noteConst(s.name, s.constValue!);
      }
    }

    _raw('; generated by rainbow compiler');
    _raw('; target: ${targetNameOf(info.target)} '
        'program "${info.programName}"');
    _raw('');

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
      _raw('\tdefw\t${chunk.join(',')}');
    }
    for (var i = 0; i < _strings.length; i++) {
      _lbl('rbs_$i');
      final s = _strings[i].replaceAll('"', "'");
      _raw('\tdefb\t${s.length},"$s"');
    }
    for (final l in _forTemps) {
      _lbl(l);
      _raw('\tdefw\t0');
    }
    for (final sym in _allVars()) {
      _lbl(sym.asmLabel);
      if (sym.kind == SymKind.arraySym || sym.structType != null) {
        _raw('\tdefs\t${(sym.size ?? 1) * _elemSize(sym)}');
      } else if (_wide(sym.type)) {
        _raw('\tdefw\t${sym.initValue ?? 0}');
      } else {
        _raw('\tdefb\t${(sym.initValue ?? 0) & 0xFF}');
      }
    }
    for (final e in assets.entries) {
      if (!_usedAssets.contains(e.key)) continue;
      _lbl('rba_${e.key}');
      final d = e.value;
      for (var i = 0; i < d.length; i += 16) {
        final c = d.sublist(i, i + 16 > d.length ? d.length : i + 16);
        _raw('\tdefb\t${c.join(',')}');
      }
    }
    // Bank loader tables read by rbt_bankload (CPC) / rbt_p3load
    // (+3). Only needed when the bank module is linked — i.e. a banked
    // asset or USEBANK/COPYBANK was used. CPC tape/disk records are 10
    // bytes: defb <bank>, defm "BANKn.BIN"; the +3 adds a #FF filename
    // terminator for +3DOS's name parser (entry = 11 bytes). On a CPC
    // cart the loader copies cart pages instead: 4-byte records
    // defb <bank>, defb <cart page>, defw <size>. Both tables end with
    // #FF — 0 is a valid bank number on ZX.
    if (usedModules.contains('bank') &&
        (platformOf(info.target) == TargetFamily.cpc ||
            info.target == 3)) {
      final banks = banked.values.map((b) => b.bank).toSet().toList()
        ..sort();
      if (cart) {
        _lbl('rbt_cartfiles');
        var page = 1;
        for (final b in banks) {
          _raw('\tdefb\t$b,$page');
          _raw('\tdefw\t${bankLens[b] ?? 0}');
          page++;
        }
        _raw('\tdefb\t#ff');
      } else {
        _lbl('rbt_bankfiles');
        for (final b in banks) {
          _raw('\tdefb\t$b');
          _raw('\tdefm\t"BANK$b.BIN"');
          if (info.target == 3) _raw('\tdefb\t#ff');
        }
        _raw('\tdefb\t#ff');
      }
    }
    // frame hook: called once per frame from rbt_vsync/rbt_pause/
    // rbt_waitkey/rbt_end — advances AY music when that module is used.
    _lbl('rbt_hook_frame');
    _i(usedModules.contains('ay') ? 'jp\trbt_ay_tick' : 'ret');
    _raw('\tend\trbt_start');
    return code + _out.toString();
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

  /// Emit `ld hl,<asset>` — paging the asset's bank in first when it
  /// is banked (128K). Banked pointers stay valid only while the bank
  /// remains selected; bind sites that store the pointer must also
  /// record the bank byte via [_emitBankByte] so the runtime can
  /// re-page on every access.
  void _loadAssetPtr(Node n, String name) {
    final key = sanitizeAssetName(name);
    final b = banked[key];
    if (b != null) {
      if (!bankCapableOf(info.target)) {
        diag.error(_curFile, n.line, n.col,
            'asset "$name" is banked (${targetNameOf(info.target)} '
            'has no banked RAM)');
        return;
      }
      usedModules.add('bank');
      _i('ld\ta,${b.bank}');
      _i('call\trbt_bank');
      _i('ld\thl,#${b.addr.toRadixString(16)}');
      _usedAssets.add(key);
      return;
    }
    _i('ld\thl,${_assetLabel(n, name)}');
  }

  /// Emit `ld <reg>,<bank>` for an asset — `#ff` when resident. Ensures
  /// the bank module is linked when the asset is banked.
  void _emitAssetBank(String name, [String reg = 'a']) {
    final b = banked[sanitizeAssetName(name)];
    if (b == null) {
      _i('ld\t$reg,#ff');
    } else {
      usedModules.add('bank');
      _i('ld\t$reg,#${b.bank.toRadixString(16)}');
    }
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
          _i('ld\thl,rbd_data');
          _i('ld\t(rbt_dataptr),hl');
          // deferred non-constant global initialisers
          for (final (sym, expr) in _globalInits) {
            _genExprTyped(expr, sym.type);
            _i(_wide(sym.type)
                ? 'ld\t(${sym.asmLabel}),hl'
                : 'ld\t(${sym.asmLabel}),a');
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
        _i('jp\t$top');
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
          _i('jp\trb_r_${_sub!.sym.name}');
        } else {
          _i('ret');
        }
      case GotoStmt g:
        _cmt(s);
        final lbl = g.name == 'MAIN' ? 'rb_main' : 'rb_${g.name.toLowerCase()}';
        _i(g.isGosub ? 'call\t$lbl' : 'jp\t$lbl');
      case PrintStmt p:
        _cmt(s);
        _genPrint(p);
      case Arg1Stmt a:
        _cmt(s);
        _genArg1(a);
      case ClsStmt _:
        _cmt(s);
        usedModules.add('charset');
        _i('call\trbt_cls');
      case PokeStmt p:
        _cmt(s);
        _genWord(p.addr);
        _i('push\thl');
        _genByte(p.value);
        _i('pop\thl');
        _i('ld\t(hl),a');
      case OutStmt o:
        _cmt(s);
        _genByte(o.value);
        _i('push\taf');
        _genWord(o.port);
        _i('ld\tb,h');
        _i('ld\tc,l');
        _i('pop\taf');
        _i('out\t(c),a');
      case PauseStmt p:
        _cmt(s);
        _genByte(p.frames);
        _i('ld\tb,a');
        _i('call\trbt_pause');
      case SimpleStmt sm:
        _cmt(s);
        switch (sm.kind) {
          case 'HALT':
            _i('call\trbt_vsync');
          case 'WAITKEY':
            _i('call\trbt_waitkey');
          case 'END':
            _i('jp\trbt_end');
          case 'RESTORE':
            _i('ld\thl,rbd_data');
            _i('ld\t(rbt_dataptr),hl');
        }
      case RandomizeStmt r:
        _cmt(s);
        if (r.seed != null) {
          _genWord(r.seed!);
        } else if (platformOf(info.target) == TargetFamily.cpc) {
          _i('call\t#bd0d');    // KL TIME PLEASE -> HL = firmware clock
        } else {
          _i('ld\thl,(#5c78)');
        }
        _i('ld\t(rbt_seed),hl');
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
        _i('ld\ta,${j.mode}');
        _i('ld\t(rbt_joymode),a');
      case FillAttrStmt f:
        _cmt(s);
        usedModules.add('charset');
        if (platformOf(info.target) == TargetFamily.cpc) {
          diag.warn(_curFile, s.line, s.col,
              'FILLATTR recolours the whole screen on CPC (no attribute '
              'plane — pen inks are global)');
        }
        _emitLoadRegs([(f.x, 'B'), (f.y, 'C'), (f.w, 'D'), (f.h, 'E')]);
        _i('call\trbt_fillattr');
      case PlotStmt p:
        _cmt(s);
        if (!_use('pixel', s, 'PLOT')) break;
        _emitLoadRegs([(p.x, 'C'), (p.y, 'B')]);
        _i('call\trbt_plot');
      case SpriteStmt sp:
        _cmt(s);
        _genSprite(sp, s);
      case SpritesStmt ss:
        _cmt(s);
        if (!_use('sprite', s, 'sprites')) break;
        _i(ss.op == 'UPDATE' ? 'call\trbt_sp_update' : 'call\trbt_sp_drawall');
      case TilesetStmt ts:
        _cmt(s);
        if (!_use('tilemap', s, 'tilemaps')) break;
        _loadAssetPtr(s, ts.asset);
        _emitAssetBank(ts.asset);
        _i('ld\t(rbt_tm_tbank),a');
        _i('call\trbt_tm_settiles');
      case CharsetStmt cs:
        _cmt(s);
        usedModules.add('charset');
        _loadAssetPtr(s, cs.asset);
        _i('ld\t(rbt_font),hl');
        _emitAssetBank(cs.asset);
        _i('ld\t(rbt_fontbank),a');
      case ShowpicStmt sp:
        _cmt(s);
        if (!_use('pixel', s, 'SHOWPIC')) break;
        _loadAssetPtr(s, sp.asset);
        _i('call\trbt_showpic');
      case MusicStmt ms:
        _cmt(s);
        _genMusic(ms, s);
      case SfxStmt sf:
        _cmt(s);
        if (!_use('sfx', s, 'SFX')) break;
        _loadAssetPtr(s, sf.asset);
        _emitAssetBank(sf.asset);   // A = bank byte for the queued effect
        _i('call\trbt_sfx');
      case UseBankStmt ub:
        _cmt(s);
        if (!bankCapableOf(info.target)) {
          diag.error(_curFile, s.line, s.col,
              'USEBANK requires a banked target (zx128/zxplus3/cpc6128)');
        } else {
          usedModules.add('bank');
          _genByte(ub.bank);
          _i('call\trbt_bank');
        }
      case CopyBankStmt cb:
        _cmt(s);
        _genCopyBank(cb, s);
      case TilemapStmt tm:
        _cmt(s);
        _genTilemap(tm, s);
      case TileAtSetStmt tas:
        _cmt(s);
        if (!_use('tilemap', s, 'tilemaps')) break;
        _emitLoadRegs([(tas.x, 'B'), (tas.y, 'C'), (tas.id, 'D')]);
        _i('call\trbt_tileatset');
      default:
        diag.error(
            _curFile, s.line, s.col, 'unsupported statement ${s.runtimeType}');
    }
  }

  /// MUSIC "name" / MUSIC STOP / MUSIC TICK.
  /// 48K: blocking AntEater beeper engine (MUSIC STOP/TICK warn + no-op).
  /// 128K/+3/CPC: AY player, auto-ticked on vsync/pause via
  /// rbt_hook_frame. On CPC both .ray and .rnt assets arrive in .ray
  /// format (the encoder converts AntEater counters to AY periods).
  void _genMusic(MusicStmt ms, Stmt s) {
    final cpc = platformOf(info.target) == TargetFamily.cpc;
    final ay = info.target == 128 || info.target == 3 || cpc;
    switch (ms.op) {
      case 'PLAY':
        usedModules.add(ay ? 'ay' : 'ant');
        if (ay && !cpc) {
          usedModules.add('bank'); // tick re-pages the song bank
        }
        _loadAssetPtr(s, ms.asset!);
        _i(ay ? 'call\trbt_ay_start' : 'call\trbt_ant');
      case 'STOP':
        if (!ay) {
          diag.warn(_curFile, s.line, s.col,
              'MUSIC STOP has no effect on a 48K blocking tune');
        } else {
          usedModules.add('ay');
          if (!cpc) usedModules.add('bank');
          _i('call\trbt_ay_stop');
        }
      case 'TICK':
        if (!ay) {
          diag.warn(_curFile, s.line, s.col,
              'MUSIC TICK is only needed on a 128K AY tune');
        } else {
          usedModules.add('ay');
          if (!cpc) usedModules.add('bank');
          _i('call\trbt_ay_tick');
        }
    }
  }

  /// COPYBANK "name", dest — copy a banked asset into resident memory.
  void _genCopyBank(CopyBankStmt cb, Stmt s) {
    if (!bankCapableOf(info.target)) {
      diag.error(_curFile, s.line, s.col,
          'COPYBANK requires a banked target (zx128/zxplus3/cpc6128)');
      return;
    }
    final key = sanitizeAssetName(cb.asset);
    final b = banked[key];
    if (b == null) {
      if (assets.containsKey(key)) {
        diag.error(_curFile, s.line, s.col,
            'asset "${cb.asset}" is resident, not banked');
      } else {
        diag.error(_curFile, s.line, s.col, 'unknown asset "${cb.asset}"');
      }
      return;
    }
    usedModules.add('bank');
    _usedAssets.add(key);
    _genWord(cb.dest);
    _i('push\thl');
    _i('ld\ta,${b.bank}');
    _i('ld\thl,#${b.addr.toRadixString(16)}');
    _i('pop\tde');
    _i('ld\tbc,${bankedSize[key]!}');
    _i('call\trbt_copybank');
  }

  void _genSub(SubDecl sd) {
    final skip = _newLabel();
    _i('jp\t$skip');
    final prev = _sub;
    _sub = info.subs[sd.name];
    _lbl('rbfn_${sd.name}');
    for (final s in sd.body) {
      _genStmt(s);
    }
    _lbl('rb_r_${sd.name}');
    _i('ret');
    _lbl(skip);
    _sub = prev;
  }

  /// Global DIMs with non-constant initialisers: emitted at MAIN prologue.
  final List<(Symbol, Expr)> _globalInits = [];

  void _genDimInit(DimDecl d) {
    final sym = _scope[d.name];
    if (sym == null || d.dims.isNotEmpty || d.init == null) return;
    if (_sub == null) {
      // global: constant -> data-section value, otherwise defer to MAIN
      final c = _sema.evalConst(d.init!);
      if (c != null) {
        sym.initValue = c;
      } else {
        _globalInits.add((sym, d.init!));
      }
      return;
    }
    // local DIM inside a SUB: executable position
    _cmt(d);
    _genExprTyped(d.init!, sym.type);
    _i(_wide(sym.type)
        ? 'ld\t(${sym.asmLabel}),hl'
        : 'ld\t(${sym.asmLabel}),a');
  }

  void _genAssign(AssignStmt a) {
    final sym = _scope[a.name];
    if (sym == null) return;
    if (a.indices.isEmpty && a.field == null) {
      _genExprTyped(a.value, sym.type);
      _i(_wide(sym.type)
          ? 'ld\t(${sym.asmLabel}),hl'
          : 'ld\t(${sym.asmLabel}),a');
      return;
    }
    // array element or struct field store
    final ft = _refType(sym, a.field);
    _emitRefAddr(sym, a.indices, a.field);
    _i('push\thl'); // target address
    _genExprTyped(a.value, ft);
    if (_wide(ft)) {
      _i('ex\tde,hl'); // DE = value
      _i('pop\thl'); // HL = address
      _i('ld\t(hl),e');
      _i('inc\thl');
      _i('ld\t(hl),d');
    } else {
      _i('pop\thl');
      _i('ld\t(hl),a');
    }
  }

  void _genRead(AssignStmt t) {
    final sym = _scope[t.name];
    if (sym == null) return;
    _i('ld\thl,(rbt_dataptr)');
    _i('ld\te,(hl)');
    _i('inc\thl');
    _i('ld\td,(hl)');
    _i('inc\thl');
    _i('ld\t(rbt_dataptr),hl');
    if (t.indices.isNotEmpty || t.field != null) {
      // array element / struct field store: DE holds the read value
      final ft = _refType(sym, t.field);
      _i('push\tde'); // value
      _emitRefAddr(sym, t.indices, t.field);
      _i('pop\tde');
      if (_wide(ft)) {
        _i('ld\t(hl),e');
        _i('inc\thl');
        _i('ld\t(hl),d');
      } else {
        _i('ld\t(hl),e');
      }
    } else if (_wide(sym.type)) {
      _i('ex\tde,hl');
      _i('ld\t(${sym.asmLabel}),hl');
    } else {
      _i('ld\ta,e');
      _i('ld\t(${sym.asmLabel}),a');
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
      if (!isLast || branch.cond != null) {
        if (!isLast) _i('jp\t$end');
      }
      if (!isLast) _lbl(next);
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
    _i(wide ? 'ld\t(${sym.asmLabel}),hl' : 'ld\t(${sym.asmLabel}),a');
    _genExprTyped(f.to, sym.type);
    _i(wide ? 'ld\t($endLbl),hl' : 'ld\t($endLbl),a');
    if (f.step != null) {
      _genExprTyped(f.step!, sym.type);
    } else {
      _i(wide ? 'ld\thl,1' : 'ld\ta,1');
    }
    _i(wide ? 'ld\t($stepLbl),hl' : 'ld\t($stepLbl),a');

    final top = _newLabel(), check = _newLabel(), end = _newLabel();
    _i('jp\t$check');
    _lbl(top);
    _genBlock(f.body);
    // NEXT: var += step
    if (wide) {
      _i('ld\thl,(${sym.asmLabel})');
      _i('ld\tde,($stepLbl)');
      _i('add\thl,de');
      _i('ld\t(${sym.asmLabel}),hl');
    } else {
      _i('ld\ta,(${sym.asmLabel})');
      _i('ld\tb,a');
      _i('ld\ta,($stepLbl)');
      _i('add\ta,b');
      _i('ld\t(${sym.asmLabel}),a');
    }
    _lbl(check);
    _emitForExitCheck(sym, endLbl, stepLbl, end);
    _i('jp\t$top');
    _lbl(end);
  }

  /// Exit when (step > 0 && var > end) or (step < 0 && var < end).
  void _emitForExitCheck(
      Symbol sym, String endLbl, String stepLbl, String exit) {
    final neg = _newLabel(), cont = _newLabel();
    final wide = _wide(sym.type);
    if (wide) {
      _i('ld\thl,($stepLbl)');
      _i('bit\t7,h');
    } else {
      _i('ld\ta,($stepLbl)');
      _i('and\t#80');
    }
    _i('jp\tnz,$neg');
    // positive step: exit if var > end  (end - var => CY)
    if (wide) {
      _i('ld\thl,($endLbl)');
      _i('ld\tde,(${sym.asmLabel})');
      _i('or\ta');
      _i('sbc\thl,de');
      _i('jp\tc,$exit');
    } else {
      _i('ld\ta,(${sym.asmLabel})');
      _i('ld\tb,a');
      _i('ld\ta,($endLbl)');
      _i('cp\tb'); // end - var
      _i('jp\tc,$exit');
    }
    _i('jp\t$cont');
    _lbl(neg);
    // negative step: exit if var < end  (var - end => CY)
    if (wide) {
      _i('ld\thl,(${sym.asmLabel})');
      _i('ld\tde,($endLbl)');
      _i('or\ta');
      _i('sbc\thl,de');
      _i('jp\tc,$exit');
    } else {
      _i('ld\ta,($endLbl)');
      _i('ld\tb,a');
      _i('ld\ta,(${sym.asmLabel})');
      _i('cp\tb'); // var - end
      _i('jp\tc,$exit');
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
      _i(_wide(psym.type)
          ? 'ld\t(${psym.asmLabel}),hl'
          : 'ld\t(${psym.asmLabel}),a');
    }
    _i('call\trbfn_${sub.sym.name}');
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
          _i('ld\ta,${n.value}');
          return RType.byte;
        }
        _i('ld\thl,${n.value}');
        return RType.uint;
      case StrLit s:
        _i('ld\thl,rbs_${_strIndex(s.text)}');
        return RType.string;
      case VarExpr v:
        final sym = _scope[v.name];
        if (sym == null) {
          _i('ld\ta,0');
          return RType.byte;
        }
        if (sym.kind == SymKind.constSym) {
          final val = sym.constValue ?? 0;
          if (val >= 0 && val <= 0xFF) {
            _i('ld\ta,$val');
            return RType.byte;
          }
          _i('ld\thl,$val');
          return RType.uint;
        }
        if (v.field != null) {
          final ft = _refType(sym, v.field);
          _emitRefAddr(sym, const [], v.field);
          return _loadAtHL(ft);
        }
        if (_wide(sym.type)) {
          _i('ld\thl,(${sym.asmLabel})');
        } else {
          _i('ld\ta,(${sym.asmLabel})');
        }
        return sym.type;
      case ArrayExpr a:
        final sym = _scope[a.name];
        if (sym == null) {
          _i('ld\ta,0');
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
            _i('call\trbt_neg16');
            return RType.int;
          case UnaryOp.not:
            if (_wide(t)) {
              _i('ld\ta,h');
              _i('or\tl');
            } else {
              _i('or\ta');
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
      _i('ld\ta,l');
      return;
    }
    if (!_wide(from) && _wide(to)) {
      if (from == RType.int) {
        _i('ld\tl,a');
        _i('rla');
        _i('sbc\ta,a');
        _i('ld\th,a');
      } else {
        _i('ld\tl,a');
        _i('ld\th,0');
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
      _i('push\taf');
      _genByte(b.right);
      _i('pop\tbc'); // B = left, A = right
      switch (b.op) {
        case BinOp.add:
          _i('add\ta,b');
        case BinOp.sub:
          _i('neg');
          _i('add\ta,b');
        case BinOp.mul:
          usedModules.add('math');
          _i('ld\td,b');
          _i('ld\te,a');
          _i('call\trbt_mul8');
          _i('ld\ta,l');
        case BinOp.div:
          usedModules.add('math');
          _i('ld\tc,a');
          _i('ld\ta,b');
          _i('ld\tb,c');
          _i('call\trbt_divmod8');
        case BinOp.mod:
          usedModules.add('math');
          _i('ld\tc,a');
          _i('ld\ta,b');
          _i('ld\tb,c');
          _i('call\trbt_divmod8');
          _i('ld\ta,b');
        case BinOp.and:
          _i('and\tb');
        case BinOp.or:
          _i('or\tb');
        case BinOp.xor:
          _i('xor\tb');
        case BinOp.eq ||
              BinOp.ne ||
              BinOp.lt ||
              BinOp.gt ||
              BinOp.le ||
              BinOp.ge:
          _i('ld\tc,a');
          _i('ld\ta,b');
          _i('cp\tc'); // left - right
          _emitCondToA(b.op);
          return RType.byte;
      }
      return wt;
    }

    // word path
    _genWord(b.left);
    _i('push\thl');
    _genWord(b.right);
    _i('pop\tde'); // DE = left, HL = right
    switch (b.op) {
      case BinOp.add:
        _i('ex\tde,hl');
        _i('add\thl,de');
      case BinOp.sub:
        _i('ex\tde,hl');
        _i('or\ta');
        _i('sbc\thl,de');
      case BinOp.mul:
        if (b.right case NumLit n when n.value >= 0 && n.value <= 255) {
          _i('ex\tde,hl'); // HL = left
          _emitMulHLByConst(n.value);
        } else if (b.left case NumLit n when n.value >= 0 && n.value <= 255) {
          _emitMulHLByConst(n.value); // HL = right
        } else {
          usedModules.add('math');
          _i('call\trbt_mul16');
        }
      case BinOp.div:
        usedModules.add('math');
        _i('ld\tb,d');
        _i('ld\tc,e');
        _i('ex\tde,hl');
        _i(wt == RType.int ? 'call\trbt_sdivmod16' : 'call\trbt_divmod16');
        _i('ld\th,b');
        _i('ld\tl,c');
      case BinOp.mod:
        usedModules.add('math');
        _i('ld\tb,d');
        _i('ld\tc,e');
        _i('ex\tde,hl');
        _i(wt == RType.int ? 'call\trbt_sdivmod16' : 'call\trbt_divmod16');
      case BinOp.and:
        _i('ld\ta,h');
        _i('and\td');
        _i('ld\th,a');
        _i('ld\ta,l');
        _i('and\te');
        _i('ld\tl,a');
      case BinOp.or:
        _i('ld\ta,h');
        _i('or\td');
        _i('ld\th,a');
        _i('ld\ta,l');
        _i('or\te');
        _i('ld\tl,a');
      case BinOp.xor:
        _i('ld\ta,h');
        _i('xor\td');
        _i('ld\th,a');
        _i('ld\ta,l');
        _i('xor\te');
        _i('ld\tl,a');
      case BinOp.eq || BinOp.ne || BinOp.lt || BinOp.gt || BinOp.le || BinOp.ge:
        _i('ex\tde,hl'); // HL = left, DE = right
        if (wt == RType.int) {
          _i('ld\ta,h');
          _i('xor\t#80');
          _i('ld\th,a');
          _i('ld\ta,d');
          _i('xor\t#80');
          _i('ld\td,a');
        }
        _i('or\ta');
        _i('sbc\thl,de');
        _emitCondToA(b.op);
        return RType.byte;
    }
    return wt;
  }

  /// After flags set by compare, produce A = 0/1.
  void _emitCondToA(BinOp op) {
    final yes = _newLabel(), done = _newLabel();
    switch (op) {
      case BinOp.eq:
        _i('jp\tnz,$done');
        _emitA1(yes, done);
      case BinOp.ne:
        _i('jp\tz,$done');
        _emitA1(yes, done);
      case BinOp.lt:
        _i('jp\tnc,$done');
        _emitA1(yes, done);
      case BinOp.ge:
        _i('jp\tc,$done');
        _emitA1(yes, done);
      case BinOp.le:
        // true iff CY or Z
        _i('jp\tc,$yes');
        _i('jp\tz,$yes');
        _i('jp\t$done');
        _lbl(yes);
        _i('ld\ta,1');
        _lbl(done);
      case BinOp.gt:
        // false iff Z or CY
        _i('jp\tz,$done');
        _i('jp\tc,$done');
        _emitA1(yes, done);
      default:
        _lbl(done);
    }
  }

  /// Emit: ld a,1 / jp end / done: xor a / end:
  void _emitA1(String yes, String done) {
    _i('ld\ta,1');
    _i('jp\t$yes');
    _lbl(done);
    _i('xor\ta');
    _lbl(yes);
  }

  void _emitToA({required bool zeroTrue}) {
    final done = _newLabel();
    _i('ld\ta,0');
    _i(zeroTrue ? 'jp\tnz,$done' : 'jp\tz,$done');
    _i('inc\ta');
    _lbl(done);
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
        _i('push\taf');
        _genByte(cond.right);
        _i('pop\tbc');
        _i('ld\tc,a');
        _i('ld\ta,b');
        _i('cp\tc'); // left - right
      } else {
        final signed = lt == RType.int || rt == RType.int;
        _genWord(cond.left);
        _i('push\thl');
        _genWord(cond.right);
        _i('pop\tde');
        _i('ex\tde,hl'); // HL=left, DE=right
        if (signed) {
          _i('ld\ta,h');
          _i('xor\t#80');
          _i('ld\th,a');
          _i('ld\ta,d');
          _i('xor\t#80');
          _i('ld\td,a');
        }
        _i('or\ta');
        _i('sbc\thl,de');
      }
      switch (cond.op) {
        case BinOp.eq:
          _i('jp\tnz,$target');
        case BinOp.ne:
          _i('jp\tz,$target');
        case BinOp.lt:
          _i('jp\tnc,$target');
        case BinOp.ge:
          _i('jp\tc,$target');
        case BinOp.gt:
          _i('jp\tz,$target'); // false iff equal or less
          _i('jp\tc,$target');
        case BinOp.le:
          // false iff a > b: NC and NZ — jump to a local skip on Z first
          final sk = _newLabel();
          _i('jp\tz,$sk');
          _i('jp\tnc,$target');
          _lbl(sk);
        default:
          break;
      }
      return;
    }
    _genByte(cond);
    _i('or\ta');
    _i('jp\tz,$target');
  }

  RType _genCallExpr(CallExpr c) {
    final sym = _scope[c.name];
    if (sym != null && sym.kind == SymKind.arraySym) {
      // a(i) — single-subscript array read (sema checked arity)
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
        _i('ld\ta,(hl)');
        return RType.byte;
      case 'PEEKW':
        _genWord(c.args[0]);
        _i('ld\ta,(hl)');
        _i('inc\thl');
        _i('ld\th,(hl)');
        _i('ld\tl,a');
        return RType.uint;
      case 'KEY':
        usedModules.add('input');
        _genByte(c.args[0]);
        _i('call\trbt_key');
        return RType.byte;
      case 'RND':
        if (c.args.isEmpty) {
          _i('call\trbt_rnd8');
        } else {
          _genByte(c.args[0]);
          _i('ld\tb,a');
          _i('call\trbt_rnd8');
          _i('call\trbt_mod8');
        }
        return RType.byte;
      case 'JOY':
        usedModules.add('input');
        _i('call\trbt_joy');
        return RType.byte;
      case 'JOYFIRE':
        usedModules.add('input');
        _i('call\trbt_joy');
        _i('and\t16');
        _emitToA(zeroTrue: false);
        return RType.byte;
      case 'INKEY':
        usedModules.add('input');
        _i('call\trbt_inkey');
        return RType.byte;
      case 'IN':
        _genWord(c.args[0]);
        _i('ld\tb,h');
        _i('ld\tc,l');
        _i('in\ta,(c)');
        return RType.byte;
      case 'ABS':
        final t = _genExpr(c.args[0]);
        if (_wide(t)) {
          usedModules.add('math');
          _i('call\trbt_abs16');
          return t;
        }
        return RType.byte;
      case 'MIN':
      case 'MAX':
        return _genMinMax(c);
      case 'POINT':
        if (!_use('pixel', c, 'POINT')) return RType.byte;
        _emitLoadRegs([(c.args[0], 'C'), (c.args[1], 'B')]);
        _i('call\trbt_point');
        return RType.byte;
      case 'SPRITEX':
        if (!_use('sprite', c, 'sprites')) return RType.byte;
        _genByte(c.args[0]);
        _i('call\trbt_spx');
        return RType.byte;
      case 'SPRITEY':
        if (!_use('sprite', c, 'sprites')) return RType.byte;
        _genByte(c.args[0]);
        _i('call\trbt_spy');
        return RType.byte;
      case 'SPRITECOLLIDE':
        if (!_use('sprite', c, 'sprites')) return RType.byte;
        _emitLoadRegs([(c.args[0], 'A'), (c.args[1], 'B')]);
        _i('call\trbt_spcoll');
        return RType.byte;
      case 'TILEAT':
        if (!_use('tilemap', c, 'tilemaps')) return RType.byte;
        _emitLoadRegs([(c.args[0], 'B'), (c.args[1], 'C')]);
        _i('call\trbt_tileat');
        return RType.byte;
      case 'TILEFLAGS':
        if (!_use('tilemap', c, 'tilemaps')) return RType.byte;
        _genByte(c.args[0]);
        _i('call\trbt_tileflags');
        return RType.byte;
      case 'COLLIDETILE':
        if (!_use('sprite', c, 'sprites') ||
            !_use('tilemap', c, 'tilemaps') ||
            !_use('spcoll', c, 'sprite-tile collision')) return RType.byte;
        _genByte(c.args[0]);
        _i('call\trbt_colltile');
        return RType.byte;
      case 'USR':
        final ret = _newLabel();
        _genWord(c.args[0]);
        _i('ld\tde,$ret');
        _i('push\tde');
        _i('jp\t(hl)');
        _lbl(ret);
        return RType.uint;
      default:
        diag.error(_curFile, c.line, c.col, 'unknown call ${c.name}');
        _i('ld\ta,0');
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
      _i('push\taf');
      _genByte(c.args[1]);
      _i('pop\tbc'); // B = left, A = right
      _i('ld\tc,a');
      _i('ld\ta,b');
      _i('cp\tc'); // left - right
      _i(isMin ? 'jp\tc,$keep' : 'jp\tnc,$keep');
      _i('ld\ta,c'); // right
      _i('jp\t$done');
      _lbl(keep);
      _i('ld\ta,b'); // left
      _lbl(done);
      return RType.byte;
    }
    _genWord(c.args[0]);
    _i('push\thl');
    _genWord(c.args[1]);
    _i('pop\tde');
    _i('ex\tde,hl'); // HL = left, DE = right
    _i('or\ta');
    _i('sbc\thl,de');
    _i(isMin ? 'jp\tc,$keep' : 'jp\tnc,$keep');
    _i('ex\tde,hl'); // HL = right
    _i('jp\t$done');
    _lbl(keep);
    _i('add\thl,de'); // restore left
    _lbl(done);
    return RType.uint;
  }

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  /// Evaluate each expr and land it in the named 8-bit register.
  ///
  /// Pops must go through HL: `push af` stores the value in the high byte,
  /// so `pop hl` lands it in H. Popping into AF or DE would clobber an 'A'
  /// or 'D' target assigned earlier in the sequence.
  void _emitLoadRegs(List<(Expr, String)> args) {
    for (var i = args.length - 1; i >= 0; i--) {
      _genByte(args[i].$1);
      _i('push\taf');
    }
    for (final (_, reg) in args) {
      _i('pop\thl');
      if (reg != 'H') _i('ld\t${reg.toLowerCase()},h');
    }
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
        _i('call\trbt_locate');
      } else if (item.text != null) {
        _i('ld\thl,rbs_${_strIndex(item.text!)}');
        _i('call\trbt_print_str');
      } else if (item.expr != null) {
        final t = _genExpr(item.expr!);
        if (t == RType.string) {
          _i('call\trbt_print_str');
        } else if (_wide(t)) {
          _i('call\trbt_print_u16');
        } else {
          _i('call\trbt_print_u8');
        }
      }
    }
    if (!p.noNewline) {
      _i('call\trbt_newline');
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
        // _loadAssetPtr pages the asset's bank via rbt_bank, which
        // clobbers A — preserve the sprite id across it.
        _i('push\taf');
        _loadAssetPtr(s, sp.asset!);
        _i('pop\taf');
        _emitAssetBank(sp.asset!, 'e'); // E = asset bank -> slot +14
        _i('call\trbt_sp_create');
      case 'MOVE':
        _emitLoadRegs([(arg(0), 'A'), (arg(1), 'B'), (arg(2), 'C')]);
        _i('call\trbt_sp_move');
      case 'PLACE':
        _emitLoadRegs([(arg(0), 'A'), (arg(1), 'B'), (arg(2), 'C')]);
        _i('call\trbt_sp_place');
      case 'FRAME':
        _emitLoadRegs([(arg(0), 'A'), (arg(1), 'B')]);
        _i('call\trbt_sp_frame');
      case 'ANIMATE':
        _emitLoadRegs([
          (arg(0), 'A'),
          (arg(1), 'B'),
          (arg(2), 'C'),
          (NumLit(s.line, s.col, sp.pingpong ? 1 : 0), 'D'),
        ]);
        _i('call\trbt_sp_anim');
      case 'REMOVE':
        _emitLoadRegs([(arg(0), 'A')]);
        _i('call\trbt_sp_kill');
      case 'HIDE':
        _emitLoadRegs([(arg(0), 'A')]);
        _i('call\trbt_sp_hide');
      case 'SHOW':
        _emitLoadRegs([(arg(0), 'A')]);
        _i('call\trbt_sp_show');
      case 'REDRAW':
        _emitLoadRegs([(arg(0), 'A')]);
        _i('call\trbt_sp_draw');
      case 'ATTR':
        // attr = (ink & 7) | ((paper & 7) << 3) | ((bright & 1) << 6)
        _emitLoadRegs([
          (arg(0), 'A'),
          (arg(1), 'B'),
          (arg(2), 'C'),
          (arg(3), 'D'),
        ]);
        _i('push\taf'); // save id
        _i('ld\ta,d');
        _i('and\t1');
        _i('rrca');
        _i('rrca');
        _i('ld\te,a'); // e = bright<<6
        _i('ld\ta,c');
        _i('and\t7');
        _i('add\ta,a');
        _i('add\ta,a');
        _i('add\ta,a');
        _i('or\te'); // a = paper<<3 | bright<<6
        _i('ld\te,a');
        _i('ld\ta,b');
        _i('and\t7');
        _i('or\te');
        _i('ld\tb,a'); // b = attr
        _i('pop\taf'); // a = id
        _i('call\trbt_sp_attr');
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
        _i('ld\t(rbt_tm_mbank),a');
        _i('call\trbt_tm_setmap');
      case 'VIEW':
        _emitLoadRegs(
            [(arg(0), 'B'), (arg(1), 'C'), (arg(2), 'D'), (arg(3), 'E')]);
        _i('call\trbt_tm_view');
      case 'CAMERA':
        _emitLoadRegs([(arg(0), 'B'), (arg(1), 'C')]);
        _i('call\trbt_tm_camera');
      case 'DRAW':
        _i('call\trbt_tm_draw');
      case 'SCROLL':
        _i('ld\ta,${tm.dir}');
        _i('push\taf');
        _genByte(arg(0, 1));
        _i('ld\tb,a');
        _i('pop\taf');
        _i('call\trbt_tm_scroll');
      case 'REDRAW':
        _emitLoadRegs(
            [(arg(0), 'B'), (arg(1), 'C'), (arg(2), 'D'), (arg(3), 'E')]);
        _i('call\trbt_tm_redraw');
      default:
        diag.error(_curFile, s.line, s.col, 'unknown TILEMAP op ${tm.op}');
    }
  }

  void _genArg1(Arg1Stmt a) {
    switch (a.kind) {
      case 'BORDER':
        _genByte(a.arg);
        _i('call\trbt_border');
      case 'INK':
      case 'PAPER':
      case 'BRIGHT':
      case 'FLASH':
        usedModules.add('charset');
        _genByte(a.arg);
        _i('call\trbt_${a.kind.toLowerCase()}');
      case 'OVER':
        _genByte(a.arg);
        _i('ld\t(rbt_over),a');
      case 'MODE':
        _genByte(a.arg);
        _i('call\trbt_scrmode');
      default:
        diag.error(_curFile, a.line, a.col, 'unknown statement ${a.kind}');
    }
  }
}
