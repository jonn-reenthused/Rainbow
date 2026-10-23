import 'dart:io';
import 'dart:typed_data';

import 'package:rainbow_assets/rainbow_assets.dart';

import 'ast.dart';
import 'codegen.dart';
import 'codegen6502.dart';
import 'diag.dart';
import 'lexer.dart';
import 'parser.dart';
import 'sema.dart';
import 'targets.dart';
import '../runtime_bundle.dart';

/// Result of a compile: diagnostics plus (on success) generated asm.
class CompileResult {
  CompileResult(this.diag, {this.asm, this.info, this.usedModules});
  final DiagnosticBag diag;
  final String? asm;
  final ProgramInfo? info;
  final Set<String>? usedModules;
  bool get ok => !diag.hasErrors && asm != null;
}

/// Compile Rainbow BASIC sources to Pasmo assembler text.
///
/// [sources] is an ordered map of filename -> source text.
/// [org] is the load/entry address; null picks the platform default
/// (0x8000 on ZX, 0x4000 on CPC — resolved once the target is known).
/// [assets] maps sanitized asset names to encoded binary payloads
/// (see rainbow_assets gfx encoders); emitted as `rba_<name>` labels.
CompileResult compile(Map<String, String> sources,
    {int? org,
    Map<String, Uint8List>? assets,
    int? target,
    Map<String, ({int bank, int addr})>? banked,
    Map<String, int>? bankedSize,
    Map<int, int>? bankLens,
    bool cart = false}) {
  final diag = DiagnosticBag();
  final units = <Unit>[];

  for (final entry in sources.entries) {
    final lexer = Lexer(entry.value, entry.key, diag);
    final tokens = lexer.tokenize();
    final parser = Parser(tokens, entry.key, diag);
    units.add(parser.parseUnit());
  }
  if (diag.hasErrors) return CompileResult(diag);

  final sema =
      Sema(diag, defaultTarget: target ?? 48, targetExplicit: target != null);
  final info = sema.analyze(units);
  if (diag.hasErrors) return CompileResult(diag, info: info);

  final resolvedOrg = org ?? defaultOrgOf(info.target);

  // The Commodore family goes down the 6502 backend — different
  // assembler syntax, runtime module set and image layout (the binary
  // starts with a BASIC SYS stub rather than jumping straight in).
  if (platformOf(info.target) == TargetFamily.cbm) {
    return _compile6502(info, diag, units, resolvedOrg,
        assets ?? const {}, banked ?? const {}, bankedSize ?? const {});
  }

  final gen = CodeGen(info, diag,
      assets: assets ?? const {},
      banked: banked ?? const {},
      bankedSize: bankedSize ?? const {},
      bankLens: bankLens ?? const {},
      cart: cart);
  final generated = gen.generate(units);
  if (diag.hasErrors) return CompileResult(diag, info: info);

  final buf = StringBuffer()
    ..writeln('; ============================================')
    ..writeln('; rainbow build — pasmo source')
    ..writeln('; ============================================')
    ..writeln('RBT_CART\tequ\t${cart ? 1 : 0}');
  // Cart builds assemble at the normal RAM org: the build wraps the
  // image in a ROM preamble that LDIRs it into RAM and jumps in, so
  // variables stay writable — RBT_CART only selects the firmware-free
  // code paths (no ROM font on ZX, no firmware at all on GX4000).
  buf.writeln(
      '\torg\t#${resolvedOrg.toRadixString(16).padLeft(4, '0')}');
  buf.writeln('');
  // CPC screen base: #C000 on both — the 6128's c4-c7 MMR configs page
  // asset banks at #4000-#7FFF, and #C000 is the one window they never
  // remap. The pixel line table and SCR SET BASE both key off these equs.
  if (platformOf(info.target) == TargetFamily.cpc) {
    final scrb = 0xC000;
    buf
      ..writeln('RBT_SCRB\tequ\t#${scrb.toRadixString(16).padLeft(4, '0')}')
      ..writeln('RBT_SCRP\tequ\t#${(scrb >> 8).toRadixString(16)}')
      ..writeln('');
  } else {
    // ROM select bit for #7FFD writes when paging banks: bit 4 set
    // picks the 48K BASIC ROM on the toastrack and ROM3 (the +3's
    // own 48K ROM) on the +3 — the same resting ROM in both cases.
    // RBT_BANKM is the +3 paging sysvar kept in sync by rbt_bank
    // (0 = absent on the toastrack).
    buf
      ..writeln(info.target == 3
          ? 'RBT_BANKROM\tequ\t#10\t; +3: 48K BASIC ROM3\n'
              'RBT_BANKM\tequ\t#5b5c\t; +3 paging sysvar'
          : 'RBT_BANKROM\tequ\t#10\t; 128K: 48K ROM\n'
              'RBT_BANKM\tequ\t#0000\t; no sysvar on the toastrack')
      ..writeln('');
  }
  // runtime modules in fixed order, only those used
  // tmdata (tilemap state + mapat) is shared by the tilemap engine and the
  // sprite compositor.
  final used = {...gen.usedModules};
  if (used.contains('sprite') || used.contains('tilemap')) {
    used.add('tmdata');
  }
  // On CPC the screen primitives (line table, rbt_laddr, rbt_tile8) live
  // in the 'pixel' module; sprites, the tilemap engine and the software
  // font path all call into it.
  final cpc = platformOf(info.target) == TargetFamily.cpc;
  if (cpc &&
      (used.contains('sprite') ||
          used.contains('tilemap') ||
          used.contains('charset'))) {
    used.add('pixel');
  }
  // On the +3 the resident binary starts with the +3DOS bank loader:
  // BASIC LOADs BANKED.BIN then USR's the org address, which must be
  // rbt_p3load — it fills the asset banks before jumping to rbt_start.
  if (info.target == 3 && used.contains('bank')) {
    used.add('p3load');
  }
  // CPC cart builds have no firmware key buffer: rbt_waitkey polls the
  // matrix (rbt_kbd_any -> rbt_kbd_scan) even when the program never
  // uses INKEY/JOYSTICK, so the input module is always required.
  if (cart && cpc) used.add('input');
  const order = [
    'p3load',
    'core',
    'charset',
    'math',
    'input',
    'pixel',
    'sprite',
    'tmdata',
    'tilemap',
    'spcoll',
    'ant',
    'sfx',
    'bank',
    'ay'
  ];
  final modules = runtimeModules[platformNameOf(info.target)] ?? const {};
  for (final m in order) {
    if (used.contains(m)) {
      buf.writeln(modules[m] ?? '; missing module $m');
      buf.writeln('');
    }
  }
  // When the bank module isn't linked (48K, or no banked assets), the
  // auto-page guards in the sprite/tilemap/charset engines still
  // reference rbt_pg_in/out — emit no-op stubs. Bank bytes are always
  // #FF on such builds so the stubs' early-out behaviour matches.
  if (!used.contains('bank')) {
    buf.writeln('rbt_bank:\tret');
    buf.writeln('rbt_pg_in:\tret');
    buf.writeln('rbt_pg_out:\tret');
    buf.writeln('rbt_cur_bank:\tdb\t0');
    buf.writeln('');
  }
  // CPC rbt_start calls rbt_bankload unconditionally; the real disc
  // loader lives in the bank module, so stub it when that's absent.
  if (cpc && !used.contains('bank')) {
    buf.writeln('rbt_bankload:\tret');
    buf.writeln('');
  }
  // Same for the SFX drain: frame-wait routines call it unconditionally,
  // so emit a no-op when the sfx module isn't linked.
  if (!used.contains('sfx')) {
    buf.writeln('rbt_sfx_drain:\tret');
    buf.writeln('');
  }
  // The CPC sfx player checks rbt_ay_on to decide whether it may touch
  // the mixer and reads rbt_ay_r7 (the music's last mixer byte) to merge
  // the channel-C bits; emit stubs when sfx plays without the ay module.
  if (cpc && used.contains('sfx') && !used.contains('ay')) {
    buf.writeln('rbt_ay_on:\tdb\t0');
    buf.writeln('rbt_ay_r7:\tdb\t0');
    buf.writeln('');
  }
  // CPC stub: rbt_cls calls rbt_sp_reset even with no sprites linked.
  if (cpc && !used.contains('sprite')) {
    buf.writeln('rbt_sp_reset:\tret');
    buf.writeln('');
  }
  // CPC sprite erase checks rbt_tm_on (from tmdata, always linked with
  // sprites) and would call rbt_tm_redraw — stub the call target when
  // the tilemap module is absent; rbt_tm_on stays 0 so it never runs.
  if (cpc && used.contains('sprite') && !used.contains('tilemap')) {
    buf.writeln('rbt_tm_redraw:\tret');
    buf.writeln('');
  }
  if (cart && used.contains('charset')) {
    // Cart builds have no ROM/firmware font to fall back on, so the
    // Spectrum charset is embedded; rbt_font points at it under
    // RBT_CART (a CHARSET asset still wins at runtime).
    buf.writeln('rbt_cartfont:');
    for (var i = 0; i < zxFont.length; i += 8) {
      buf.writeln('\tdefb\t${zxFont.sublist(i, i + 8).join(',')}');
    }
    buf.writeln('');
  }
  buf.write(generated);
  return CompileResult(diag, asm: buf.toString(), info: info);
}

/// Emit a Commodore-family binary image: ca65 source beginning with a
/// BASIC `10 SYS` stub, the used runtime modules, then the generated
/// program. Entry is the $080E `jmp rbt_start` the SYS points at.
CompileResult _compile6502(
    ProgramInfo info,
    DiagnosticBag diag,
    List<Unit> units,
    int resolvedOrg,
    Map<String, Uint8List> assets,
    Map<String, ({int bank, int addr})> banked,
    Map<String, int> bankedSize) {
  final gen = CodeGen6502(info, diag,
      assets: assets, banked: banked, bankedSize: bankedSize);
  final generated = gen.generate(units);
  if (diag.hasErrors) return CompileResult(diag, info: info);

  final buf = StringBuffer()
    ..writeln('; ============================================')
    ..writeln('; rainbow build — ca65 source')
    ..writeln('; ============================================')
    // target constants the shared runtime conditionals read: on the
    // C128 the kernal IRQ is entered at $FA6B (not $EA31) — past its
    // raster-split manager, which would re-arm $D012 — and its MMU
    // must map RAM-under-ROM for bitmap reads
    ..writeln('RBT_C128 = ${info.target == 1280 ? 1 : 0}')
    ..writeln('RBT_KERNAL_IRQ = ${info.target == 1280 ? '\$fa6b' : '\$ea31'}')
    ..writeln('\t.code');
  // BASIC stub: "10 SYS <entry>" — 13 bytes at the org, so the jmp
  // lands at org+13 ($080E on the C64, $1C0E on the C128). The linker
  // cfg places the CODE segment at the org; this stub is the image's
  // first bytes.
  if (resolvedOrg == defaultOrgOf(info.target)) {
    buf.writeln('\t.word\trbt_basend\n'
        '\t.word\t10\n'
        '\t.byte\t\$9e," ${resolvedOrg + 13}",0\n'
        'rbt_basend:\n'
        '\t.word\t0\n'
        '\tjmp\trbt_start\n');
  } else {
    buf.writeln('\tjmp\trbt_start\n');
  }

  // runtime modules in fixed order, only those used (same order table
  // as the Z80 path — the cbm set is a subset of these names for now)
  final used = {...gen.usedModules};
  if (used.contains('sprite') || used.contains('tilemap')) {
    used.add('tmdata');
  }
  // The tilemap engine patches glyph RAM inside the charset window the
  // text engine owns — it reads rbt_font to decide how much of the
  // chargen ROM to copy first, so tilemap implies charset.
  if (used.contains('tilemap')) used.add('charset');
  const order = [
    'core',
    'charset',
    'math',
    'input',
    'pixel',
    'sprite',
    'tmdata',
    'tilemap',
    'spcoll',
    'sfx',
    'sid',
    'diskload',
  ];
  final modules = runtimeModules['cbm'] ?? const {};
  for (final m in order) {
    if (used.contains(m)) {
      buf.writeln(modules[m] ?? '; missing module $m');
      buf.writeln('');
    }
  }
  // rbt_sfx_drain is called by the frame-wait routines; emit a no-op
  // when the sfx module isn't linked (same contract as the Z80 path).
  if (!used.contains('sfx')) {
    buf.writeln('rbt_sfx_drain:\trts');
    buf.writeln('');
  }
  buf.write(generated);
  return CompileResult(diag,
      asm: buf.toString(), info: info, usedModules: used);
}

/// Assemble a Pasmo source file to binary via the pasmo executable.
Future<({int code, String out, String err})> runPasmo(
  String asmPath,
  String binPath, {
  String pasmo = 'pasmo',
  String? symPath,
}) async {
  final args = ['--alocal', '--bin', asmPath, binPath];
  if (symPath != null) args.add(symPath);
  final r = await Process.run(pasmo, args);
  return (
    code: r.exitCode,
    out: r.stdout.toString(),
    err: r.stderr.toString(),
  );
}

/// Assemble a ca65 source file to an object file via the ca65
/// executable.
Future<({int code, String out, String err})> runCa65(
  String asmPath,
  String objPath, {
  String ca65 = 'ca65',
}) async {
  final r = await Process.run(ca65, [asmPath, '-o', objPath]);
  return (
    code: r.exitCode,
    out: r.stdout.toString(),
    err: r.stderr.toString(),
  );
}

/// Link a ca65 object file to a flat binary via the ld65 executable
/// and the linker config at [cfgPath].
Future<({int code, String out, String err})> runLd65(
  String objPath,
  String binPath,
  String cfgPath,
  String mapPath, {
  String ld65 = 'ld65',
}) async {
  final r = await Process.run(
      ld65, ['-C', cfgPath, objPath, '-o', binPath, '-m', mapPath]);
  return (
    code: r.exitCode,
    out: r.stdout.toString(),
    err: r.stderr.toString(),
  );
}

/// Linker config for a C64/C128 flat binary: CODE placed at [org]
/// ($0801/$1C01 for a BASIC-start program) with RAM mapped through
/// [ramTop] ($A000 on the C64 — the kernal ROM sits above that in the
/// standard memory map; $4000 on the C128, where bank 0's flat RAM
/// ends at the BASIC ROM-lo boundary). When the pixel module is
/// linked the program may enter hires bitmap mode, which owns VIC
/// bank 1 ($4000-$7FFF: bitmap + colour matrix + the relocated sprite
/// pool) — RAM is then capped at $4000 so a linked program can't
/// overwrite its own display.
String c64LinkerCfg(int org, {bool bitmapSafe = false, int? ramTop}) {
  String h(int v) => '\$${v.toRadixString(16).padLeft(4, '0')}';
  final top = (bitmapSafe ? 0x4000 : ramTop) ?? 0xA000;
  return 'MEMORY {\n'
      '    ZP:  start = \$02, size = \$8e, type = rw, file = "";\n'
      '    RAM: start = ${h(org)}, size = ${h(top - org)},'
      ' type = rw, file = %O;\n'
      '}\n'
      'SEGMENTS {\n'
      '    ZEROPAGE: load = ZP,  type = zp;\n'
      '    CODE:     load = RAM, type = ro;\n'
      // Sprite frames must sit on 64B boundaries in VIC bank 0 so the
      // mux can point SPRPTR at them without a pool copy — segment-level
      // alignment (absolute, unlike .align inside CODE at $0801) does it.
      '    SPDATA:   load = RAM, type = ro, align = \$40;\n'
      '}\n';
}

/// Build a 48K TAP: BASIC loader + optional screen + code block.
Uint8List buildTap48({
  required String name,
  required int org,
  required List<int> code,
  List<int>? screen,
}) {
  final tap = TapWriter();
  final codeBlocks = screen != null ? 2 : 1;
  tap.addProgram(
    name: name,
    program:
        buildGameLoader(clearAddr: org - 1, entry: org, codeBlocks: codeBlocks),
    autoStartLine: 10,
  );
  if (screen != null) {
    tap.addCode(name: 'screen', org: 0x4000, data: screen);
  }
  tap.addCode(name: 'game', org: org, data: code);
  return tap.bytes;
}
