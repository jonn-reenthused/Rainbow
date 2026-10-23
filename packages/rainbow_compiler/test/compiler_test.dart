import 'dart:typed_data';

import 'package:rainbow_compiler/rainbow_compiler.dart';
import 'package:rainbow_compiler/src/ast.dart';
import 'package:rainbow_compiler/src/parser.dart';
import 'package:test/test.dart';

void main() {
  group('lexer', () {
    test('identifiers may contain digits and underscores', () {
      final d = DiagnosticBag();
      final toks = Lexer('x1 = hp_20\n', 't', d).tokenize();
      expect(toks[0].kind, TokKind.ident);
      expect(toks[0].text, 'X1');
      expect(toks[2].kind, TokKind.ident);
      expect(toks[2].text, 'HP_20');
      expect(d.hasErrors, isFalse);
    });

    test('graphics words are keywords', () {
      final d = DiagnosticBag();
      final toks =
          Lexer('SPRITE TILEMAP COLLIDETILE PINGPONG', 't', d).tokenize();
      expect(toks.take(4).every((t) => t.kind == TokKind.keyword), isTrue);
    });

    test('hex and decimal numbers', () {
      final d = DiagnosticBag();
      final toks = Lexer('#ff 42', 't', d).tokenize();
      expect(toks[0].value, 0xFF);
      expect(toks[1].value, 42);
    });
  });

  group('parser', () {
    Unit parse(String src) {
      final d = DiagnosticBag();
      final toks = Lexer(src, 't', d).tokenize();
      final u = Parser(toks, 't', d).parseUnit();
      expect(d.hasErrors, isFalse);
      return u;
    }

    test('SPRITE CREATE parses id/asset/xy/mode', () {
      final u = parse('SPRITE CREATE 3,"ship",10,20,OR\n');
      final s = u.stmts.single as SpriteStmt;
      expect(s.op, 'CREATE');
      expect(s.args.length, 3);
      expect(s.asset, 'ship');
      expect(s.mode, 1);
    });

    test('SPRITE ANIMATE parses pingpong flag', () {
      final u = parse('SPRITE ANIMATE 0,0,3,PINGPONG\n');
      final s = u.stmts.single as SpriteStmt;
      expect(s.op, 'ANIMATE');
      expect(s.pingpong, isTrue);
    });

    test('TILEMAP SCROLL parses direction and count', () {
      final u = parse('TILEMAP SCROLL LEFT 2\n');
      final s = u.stmts.single as TilemapStmt;
      expect(s.op, 'SCROLL');
      expect(s.dir, 0);
      expect((s.args.single as NumLit).value, 2);
    });

    test('graphics builtins parse as call expressions', () {
      final u = parse('DIM x AS BYTE\nx = TILEAT(1,2) + SPRITEX(0)\n');
      final a = u.stmts[1] as AssignStmt;
      final sum = a.value as BinExpr;
      expect((sum.left as CallExpr).name, 'TILEAT');
      expect((sum.right as CallExpr).name, 'SPRITEX');
    });
  });

  group('sema', () {
    test('undefined variable is an error', () {
      final r = compile({'m.rbw': 'PROGRAM "T"\nx = 1\n'});
      expect(r.ok, isFalse);
      expect(r.diag.items.any((d) => d.message.contains('undefined')), isTrue);
    });

    test('wrong builtin arity is an error', () {
      final r =
          compile({'m.rbw': 'PROGRAM "T"\nDIM x AS BYTE\nx = TILEAT(1)\n'});
      expect(r.ok, isFalse);
    });

    test('label + goto must resolve', () {
      final r = compile({'m.rbw': 'PROGRAM "T"\nGOTO nowhere\n'});
      expect(r.ok, isFalse);
    });
  });

  group('codegen', () {
    Uint8List shipAsset() => Uint8List.fromList([
          2, 16, 1, 0x47, // wb, h, nframes, attr
          ...List<int>.filled(64, 0x55), // 1 frame of mask+bmp
        ]);

    test('SPRITE CREATE emits slot call with asset label', () {
      final r = compile({
        'm.rbw':
            'PROGRAM "T"\nMAIN:\n  SPRITE CREATE 0,"ship",10,20\ndone:\n  GOTO done\n'
      }, assets: {
        'ship': shipAsset()
      });
      expect(r.ok, isTrue);
      expect(r.asm, contains('call\trbt_sp_create'));
      expect(r.asm, contains('ld\thl,rba_ship'));
      expect(r.asm, contains('rba_ship:'));
      expect(r.asm, contains('defb\t85,'));
    });

    test('SPRITES UPDATE emits compositor call and pulls tmdata', () {
      final r = compile({
        'm.rbw': 'PROGRAM "T"\nMAIN:\n  SPRITES UPDATE\ndone:\n  GOTO done\n'
      });
      expect(r.ok, isTrue);
      expect(r.asm, contains('call\trbt_sp_update'));
      expect(r.asm, contains('rbt_sp_update:'));
      expect(r.asm, contains('rbt_tm_map')); // compositor needs tmdata module
      expect(r.asm, contains('rbt_sp_old'));
      expect(r.asm, contains('rbt_sp_dirty'));
    });

    test('SPRITES DRAWALL still emits drawall call', () {
      final r = compile({
        'm.rbw': 'PROGRAM "T"\nMAIN:\n  SPRITES DRAWALL\ndone:\n  GOTO done\n'
      });
      expect(r.ok, isTrue);
      expect(r.asm, contains('call\trbt_sp_drawall'));
      expect(r.asm, isNot(contains('call\trbt_sp_update')));
    });

    test('unknown asset name is a compile error', () {
      final r = compile(
          {'m.rbw': 'PROGRAM "T"\nMAIN:\n  SPRITE CREATE 0,"nope",0,0\n'});
      expect(r.ok, isFalse);
      expect(
          r.diag.items.any((d) => d.message.contains('unknown asset')), isTrue);
    });

    test('tilemap scroll emits dir in A and count in B', () {
      final r = compile({
        'm.rbw': 'PROGRAM "T"\nMAIN:\n  TILEMAP SCROLL RIGHT 3\n'
      }, assets: {
        'level': Uint8List.fromList([2, 2, 0, 0, 0, 0])
      });
      expect(r.ok, isTrue);
      expect(r.asm, contains('ld\ta,1')); // RIGHT
      expect(r.asm, contains('call\trbt_tm_scroll'));
    });

    test('COLLIDETILE pulls in sprite+tilemap modules', () {
      final r = compile({
        'm.rbw': 'PROGRAM "T"\nDIM h AS BYTE\nMAIN:\n  h = COLLIDETILE(0)\n'
      });
      expect(r.ok, isTrue);
      expect(r.asm, contains('call\trbt_colltile'));
      expect(r.asm, contains('rbt_sprite_asm'));
      expect(r.asm, contains('rbt_tilemap_asm'));
    });

    test('TILEATSET statement emits B,C,D register call', () {
      final r = compile({
        'm.rbw': 'PROGRAM "T"\nMAIN:\n  TILEATSET 1,2,3\n'
      }, assets: {
        'level': Uint8List.fromList([2, 2, 0, 0, 0, 0])
      });
      expect(r.ok, isTrue);
      expect(r.asm, contains('call\trbt_tileatset'));
    });

    test('CHARSET binds font asset to rbt_font', () {
      final r = compile({'m.rbw': 'PROGRAM "T"\nMAIN:\n  CHARSET "myfont"\n'},
          assets: {'myfont': Uint8List(768)});
      expect(r.ok, isTrue);
      expect(r.asm, contains('ld\thl,rba_myfont'));
      expect(r.asm, contains('ld\t(rbt_font),hl'));
      expect(r.asm, contains('rbt_charset_asm'));
    });

    test('TILESET/TILEMAP rebind mid-program emit setter calls', () {
      final r = compile({
        'm.rbw': '''PROGRAM "T"
DIM done AS BYTE = 0
MAIN:
  TILESET "t1"
  TILEMAP "m1"
  IF done THEN TILESET "t2" : TILEMAP "m2" : GOTO MAIN
done:
  GOTO done
'''
      }, assets: {
        't1': Uint8List(12),
        't2': Uint8List(12),
        'm1': Uint8List(6),
        'm2': Uint8List(6),
      });
      expect(r.ok, isTrue);
      expect(r.asm, contains('ld\thl,rba_t1'));
      expect(r.asm, contains('ld\thl,rba_t2'));
      expect(r.asm, contains('call\trbt_tm_settiles'));
      expect(r.asm, contains('ld\thl,rba_m1'));
      expect(r.asm, contains('ld\thl,rba_m2'));
      expect(r.asm, contains('call\trbt_tm_setmap'));
    });

    test('unreferenced assets are not emitted', () {
      final r = compile({
        'm.rbw': 'PROGRAM "T"\nMAIN:\n  SHOWPIC "used"\ndone:\n  GOTO done\n'
      }, assets: {
        'used': Uint8List(6912),
        'unused': Uint8List(6912),
      });
      expect(r.ok, isTrue);
      expect(r.asm, contains('rba_used:'));
      expect(r.asm, isNot(contains('rba_unused:')));
    });

    test('SHOWPIC copies screen asset to display', () {
      final r = compile({'m.rbw': 'PROGRAM "T"\nMAIN:\n  SHOWPIC "title"\n'},
          assets: {'title': Uint8List(6912)});
      expect(r.ok, isTrue);
      expect(r.asm, contains('ld\thl,rba_title'));
      expect(r.asm, contains('call\trbt_showpic'));
      expect(r.asm, contains('rbt_pixel_asm'));
    });

    test('MUSIC on 48K uses the AntEater beeper engine', () {
      final r = compile({'m.rbw': 'PROGRAM "T"\nMAIN:\n  MUSIC "tune"\n'},
          assets: {'tune': Uint8List(13)});
      expect(r.ok, isTrue);
      expect(r.asm, contains('call\trbt_ant'));
      expect(r.asm, contains('rbt_ant_asm'));
      expect(r.asm, contains('rbt_hook_frame:\n\tret'));
    });

    test('MUSIC on 128K uses the AY player + frame hook', () {
      final r = compile({
        'm.rbw':
            'PROGRAM "T"\nTARGET 128\nMAIN:\n  MUSIC "tune"\nloop:\n  MUSIC TICK\n  GOTO loop\n'
      }, assets: {
        'tune': Uint8List(18)
      });
      expect(r.ok, isTrue);
      expect(r.asm, contains('call\trbt_ay_start'));
      expect(r.asm, contains('call\trbt_ay_tick'));
      expect(r.asm, contains('rbt_ay_asm'));
      expect(r.asm, contains('rbt_hook_frame:\n\tjp\trbt_ay_tick'));
    });

    test('MUSIC STOP on 128K calls rbt_ay_stop', () {
      final r =
          compile({'m.rbw': 'PROGRAM "T"\nTARGET 128\nMAIN:\n  MUSIC STOP\n'});
      expect(r.ok, isTrue);
      expect(r.asm, contains('call\trbt_ay_stop'));
    });

    test('SFX emits beeper player call', () {
      final r = compile({'m.rbw': 'PROGRAM "T"\nMAIN:\n  SFX "zap"\n'},
          assets: {'zap': Uint8List(7)});
      expect(r.ok, isTrue);
      expect(r.asm, contains('ld\thl,rba_zap'));
      expect(r.asm, contains('call\trbt_sfx'));
      expect(r.asm, contains('rbt_sfx_asm'));
    });

    test('unary minus evaluates as signed 16-bit on both backends', () {
      // regression: CALL serve(-1) byte-negated to $FF then zero-extended
      // to +255, so a signed dir param got +255 — pong's ball flew right
      // after a left-side goal and scored for both players
      const src = 'PROGRAM "T"\n'
          'DIM v AS INT\n'
          'SUB serve(dir AS INT)\n  v = dir\nEND SUB\n'
          'MAIN:\n  CALL serve(-1)\n';
      final zx = compile({'m.rbw': src});
      expect(zx.ok, isTrue);
      expect(zx.asm, contains('call\trbt_neg16'));
      final c64 = compile({'m.rbw': src}, target: 64);
      expect(c64.ok, isTrue);
      expect(c64.asm, contains('jsr\trbt_neg16'));
    });
  });

  group('multidim arrays + types', () {
    test('DIM a(n)(m) emits row-major addressing', () {
      final r = compile({
        'm.rbw':
            'PROGRAM "T"\nDIM g(3)(4) AS BYTE\nDIM x AS BYTE\nMAIN:\n  g(1)(2) = 42\n  x = g(1)(2)\n'
      });
      expect(r.ok, isTrue);
      // flat = 1*4 + 2, row-major via dims[1]=4 constant multiply
      expect(r.asm, contains('add\thl,hl\n\tadd\thl,hl'));
      expect(r.asm, contains('rbv_G:\n\tdefs\t12'));
    });

    test('a(i) reads an array element in an expression', () {
      final r = compile({
        'm.rbw':
            'PROGRAM "T"\nDIM a(5) AS BYTE\nDIM x AS BYTE\nMAIN:\n  x = a(1)\n'
      });
      expect(r.ok, isTrue);
      expect(r.asm, contains('add\thl,de'));
      expect(r.asm, contains('ld\ta,(hl)'));
    });

    test('TYPE decl + struct fields compile', () {
      final r = compile({
        'm.rbw': '''
PROGRAM "T"
TYPE Enemy
  x AS BYTE
  hp AS UINT
END TYPE
DIM e AS Enemy
DIM foes(4) AS Enemy
MAIN:
  e.hp = 300
  foes(2).x = 9
'''
      });
      expect(r.ok, isTrue);
      // Enemy: x@0 (1B), hp@1 (2B) -> size 3
      expect(r.asm, contains('rbv_E:\n\tdefs\t3'));
      expect(r.asm, contains('rbv_FOES:\n\tdefs\t12'));
      // foes(2).x: flat 2 * elemsize 3 as a shift-add sequence
      expect(r.asm, contains('add\thl,hl\n\tadd\thl,de'));
      // e.hp = 300 is a wide store at rbv_E+1
      expect(r.asm, contains(RegExp('rbv_E\\+1')));
    });

    test('sema rejects bad index count / unknown field / struct assign', () {
      final r = compile({
        'm.rbw': '''
PROGRAM "T"
TYPE P
  x AS BYTE
END TYPE
DIM p AS P
DIM g(3)(4) AS BYTE
MAIN:
  g(1) = 2
  p.zz = 1
  p = 0
'''
      });
      expect(r.ok, isFalse);
      final errs = r.diag.items.join('\n');
      expect(errs, contains('expects 2 index'));
      expect(errs, contains('no field ZZ'));
      expect(errs, contains('whole struct'));
    });

    test('struct rvalue in an expression is an error', () {
      final r = compile({
        'm.rbw': '''
PROGRAM "T"
TYPE P
  x AS BYTE
END TYPE
DIM p AS P
DIM x AS BYTE
MAIN:
  x = p
'''
      });
      expect(r.ok, isFalse);
      expect(r.diag.items.join('\n'), contains('is a struct'));
    });
  });

  group('diagnostics', () {
    test('string assignment is an error', () {
      final r = compile(
          {'m.rbw': 'PROGRAM "T"\nDIM s AS BYTE\nMAIN:\n  s = "hi"\n'});
      expect(r.ok, isFalse);
      expect(r.diag.items.join('\n'), contains('assign a string'));
    });

    test('string operand in expression is an error', () {
      final r = compile(
          {'m.rbw': 'PROGRAM "T"\nDIM x AS BYTE\nMAIN:\n  x = "a" + 1\n'});
      expect(r.ok, isFalse);
      expect(r.diag.items.join('\n'), contains('string operands'));
    });

    test('string condition is an error', () {
      final r = compile(
          {'m.rbw': 'PROGRAM "T"\nMAIN:\n  IF "x" THEN\n  ENDIF\n'});
      expect(r.ok, isFalse);
      expect(r.diag.items.join('\n'), contains('condition must be numeric'));
    });

    test('constant division by zero is an error', () {
      final r = compile(
          {'m.rbw': 'PROGRAM "T"\nDIM x AS BYTE\nMAIN:\n  x = 1/0\n'});
      expect(r.ok, isFalse);
      expect(r.diag.items.join('\n'), contains('division by zero'));
    });

    test('STRING variables and params are rejected', () {
      final r = compile({
        'm.rbw': '''
PROGRAM "T"
DIM s AS STRING
SUB f(p AS STRING)
END SUB
MAIN:
'''
      });
      expect(r.ok, isFalse);
      final errs = r.diag.items.join('\n');
      expect(errs, contains('STRING variables are not supported'));
      expect(errs, contains('STRING parameter'));
    });

    test('unclosed blocks get named errors', () {
      for (final (src, msg) in [
        ('IF 1 THEN\n', 'IF without ENDIF'),
        ('FOR i = 0 TO 3\n', 'FOR without NEXT'),
        ('WHILE 1\n', 'WHILE without WEND'),
        ('REPEAT\n', 'REPEAT without UNTIL'),
      ]) {
        final r = compile({'m.rbw': 'PROGRAM "T"\nMAIN:\n$src'});
        expect(r.ok, isFalse, reason: src);
        expect(r.diag.items.join('\n'), contains(msg), reason: src);
      }
    });

    test('MODE emits the screen-mode call and warns on ZX', () {
      final r =
          compile({'m.rbw': 'PROGRAM "T"\nDIM x AS BYTE\nMAIN:\n  MODE 1\n'});
      expect(r.ok, isTrue);
      expect(r.asm, contains('call\trbt_scrmode'));
      expect(r.diag.items.join('\n'), contains('no effect on ZX'));
      // out-of-range constant warns too
      final r2 = compile({'m.rbw': 'PROGRAM "T"\nMAIN:\n  MODE 5\n'});
      expect(r2.diag.items.join('\n'), contains('out of range'));
      // expression arg compiles to the call without the range warning
      final r3 =
          compile({'m.rbw': 'PROGRAM "T"\nDIM x AS BYTE\nMAIN:\n  MODE x\n'});
      expect(r3.ok, isTrue);
      expect(r3.asm, contains('call\trbt_scrmode'));
    });
  });

  group('compile-time IF', () {
    test('IF CPC keeps only the matching branch per target', () {
      const src = 'PROGRAM "T"\nMAIN:\n'
          '  IF CPC THEN\n  BORDER 1\nELSE\n  BORDER 2\nENDIF\n';
      final cpc = compile({'m.rbw': src}, target: 6128);
      expect(cpc.ok, isTrue);
      expect(cpc.asm, contains('ld\ta,1\n\tcall\trbt_border'));
      expect(cpc.asm, isNot(contains('ld\ta,2\n\tcall\trbt_border')));
      final zx = compile({'m.rbw': src}, target: 48);
      expect(zx.ok, isTrue);
      expect(zx.asm, contains('ld\ta,2\n\tcall\trbt_border'));
      expect(zx.asm, isNot(contains('ld\ta,1\n\tcall\trbt_border')));
    });

    test('a dead branch is neither checked nor emitted', () {
      final r = compile({
        'm.rbw': 'PROGRAM "T"\nMAIN:\n'
            '  IF CPC THEN\n  SHOWPIC "nope"\nELSE\n  BORDER 3\nENDIF\n'
      }, target: 48);
      expect(r.ok, isTrue); // unknown asset in the dead CPC branch is fine
      expect(r.asm, isNot(contains('showpic')));
      expect(r.asm, contains('call\trbt_border'));
    });

    test('single-line IF and user CONSTs fold too', () {
      final r = compile({
        'm.rbw': 'PROGRAM "T"\nCONST DEBUG = 0\nMAIN:\n'
            '  IF DEBUG THEN BORDER 4\n  IF ZX THEN BORDER 5\n'
      }, target: 48);
      expect(r.ok, isTrue);
      expect(r.asm, isNot(contains('ld\ta,4\n\tcall\trbt_border')));
      expect(r.asm, contains('ld\ta,5\n\tcall\trbt_border'));
    });

    test('non-constant conditions still emit a runtime IF', () {
      final r = compile({
        'm.rbw': 'PROGRAM "T"\nDIM x AS BYTE\nMAIN:\n'
            '  IF x THEN\n    BORDER 1\n  ENDIF\n'
      });
      expect(r.ok, isTrue);
      expect(r.asm, contains('ld\ta,(rbv_X)'));
    });
  });

  group('cbm COPYBANK', () {
    Map<String, ({int bank, int addr})> bankedOf(List<String> keys) =>
        {for (final k in keys) k: (bank: 0, addr: 0xC000)};

    test('banked asset name resolves to its COPYBANK dest', () {
      final r = compile({
        'm.rbw': 'PROGRAM "T"\nMAIN:\n'
            '  COPYBANK "tune", #6400\n'
            '  MUSIC "tune"\n'
      },
          target: 64,
          banked: bankedOf(['tune']),
          bankedSize: {'tune': 100});
      expect(r.ok, isTrue);
      expect(r.asm, contains('lda\t#<(\$6400)'));
      expect(r.asm, contains('jsr\trbt_diskload'));
      expect(r.asm, contains('jsr\trbt_sid_start'));
      expect(r.asm, contains('rbf_tune:\n\t.byte\t4,"TUNE"'));
    });

    test('banked name without a COPYBANK is an error', () {
      final r = compile({
        'm.rbw': 'PROGRAM "T"\nMAIN:\n  MUSIC "tune"\n'
      },
          target: 64,
          banked: bankedOf(['tune']),
          bankedSize: {'tune': 10});
      expect(r.ok, isFalse);
      expect(
          r.diag.items.map((d) => d.message).join('\n'),
          contains('COPYBANK'));
    });

    test('target-guarded dests do not conflict (CBM const)', () {
      final r = compile({
        'm.rbw': 'PROGRAM "T"\nMAIN:\n'
            '  IF CBM THEN\n    COPYBANK "tune", #6000\n'
            '  ELSE\n    COPYBANK "tune", #7000\n  ENDIF\n'
            '  MUSIC "tune"\n'
      },
          target: 64,
          banked: bankedOf(['tune']),
          bankedSize: {'tune': 10});
      expect(r.ok, isTrue);
      expect(r.asm, contains('lda\t#<(\$6000)'));
    });

    test('conflicting live dests stay unresolvable', () {
      final r = compile({
        'm.rbw': 'PROGRAM "T"\nDIM x AS BYTE\nMAIN:\n'
            '  IF x THEN\n    COPYBANK "tune", #6000\n'
            '  ELSE\n    COPYBANK "tune", #7000\n  ENDIF\n'
            '  MUSIC "tune"\n'
      },
          target: 64,
          banked: bankedOf(['tune']),
          bankedSize: {'tune': 10});
      expect(r.ok, isFalse);
    });
  });
}
