import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:rainbow_compiler/rainbow_compiler.dart';
import 'package:test/test.dart';

String _spriteJson([String fill = '.']) {
  final rows = List.filled(8, fill * 8);
  return jsonEncode({
    'w': 8,
    'h': 8,
    'attr': 'none',
    'frames': [rows]
  });
}

String _screenJson() => jsonEncode({
      'bitmap': '00' * 6144,
      'attrs': '38' * 768,
    });

Directory _mkproj(void Function(Directory) fill) {
  final d = Directory.systemTemp.createTempSync('rb_bank_test');
  Directory('${d.path}/src').createSync(recursive: true);
  File('${d.path}/project.rbw.json').writeAsStringSync(jsonEncode({
    'name': 'T',
    'target': 128,
    'sources': ['src/main.rbw'],
  }));
  File('${d.path}/src/main.rbw').writeAsStringSync('PROGRAM "T"\n');
  fill(d);
  return d;
}

void main() {
  group('scanAssets banked layout', () {
    test('assets under bank<N>/ are packed into bank blobs at 0xC000', () {
      final errs = <String>[];
      final d = _mkproj((p) {
        Directory('${p.path}/assets/sprites').createSync(recursive: true);
        Directory('${p.path}/assets/bank3').createSync(recursive: true);
        File('${p.path}/assets/sprites/s.rbs').writeAsStringSync(_spriteJson());
        File('${p.path}/assets/bank3/tune.rbs')
            .writeAsStringSync(_spriteJson('#'));
        File('${p.path}/assets/bank3/pic.rbc').writeAsStringSync(_screenJson());
      });
      final scan = scanAssets(d.path, onError: errs.add)!;
      expect(errs, isEmpty);
      expect(scan.resident.keys, contains('s'));
      expect(scan.resident.keys, isNot(contains('tune')));
      // bank 3 packs sorted-by-name: pic.rbc then tune.rbs
      expect(scan.banked['pic'], (bank: 3, addr: 0xC000));
      expect(scan.banked['tune'], (bank: 3, addr: 0xC000 + 6912));
      // 8x8x1 sprite = 4 hdr + 16 offs + 16 frame data + 8*8*4 shifted
      expect(scan.bankBlobs[3]!.length, 6912 + 292);
      expect(scan.bankedSize['tune'], 292);
      expect(scan.bankFiles[3]!.map((e) => e.$1), ['pic', 'tune']);
      d.deleteSync(recursive: true);
    });

    test('a bank overflowing 16K reports an error', () {
      final errs = <String>[];
      final d = _mkproj((p) {
        Directory('${p.path}/assets/bank0').createSync(recursive: true);
        for (final n in ['a', 'b', 'c']) {
          File('${p.path}/assets/bank0/$n.rbc')
              .writeAsStringSync(_screenJson());
        }
      });
      final scan = scanAssets(d.path, onError: errs.add);
      expect(scan, isNull);
      expect(errs.single, contains('overflows'));
      d.deleteSync(recursive: true);
    });

    test('bank5/bank2 dirs are rejected', () {
      final errs = <String>[];
      final d = _mkproj((p) {
        Directory('${p.path}/assets/bank5').createSync(recursive: true);
        File('${p.path}/assets/bank5/x.rbs').writeAsStringSync(_spriteJson());
      });
      expect(scanAssets(d.path, onError: errs.add), isNull);
      expect(errs.single, contains('bank5'));
      d.deleteSync(recursive: true);
    });
  });

  group('banked codegen', () {
    final banked = {
      'pic': (bank: 3, addr: 0xC000),
      'tune': (bank: 7, addr: 0xC100),
    };
    final bankedSize = {'pic': 6912, 'tune': 100};

    test('USEBANK pages the requested bank', () {
      final r = compile(
          {'m.rbw': 'PROGRAM "T"\nTARGET 128\nMAIN:\n  USEBANK 3\n'},
          target: 128);
      expect(r.ok, isTrue);
      expect(r.asm, contains('call\trbt_bank'));
    });

    test('banked SHOWPIC emits page-in + absolute address', () {
      final r = compile(
          {'m.rbw': 'PROGRAM "T"\nTARGET 128\nMAIN:\n  SHOWPIC "pic"\n'},
          target: 128, banked: banked, bankedSize: bankedSize);
      expect(r.ok, isTrue);
      expect(r.asm, contains('ld\ta,3'));
      expect(r.asm, contains('call\trbt_bank'));
      expect(r.asm, contains('ld\thl,#c000'));
      expect(r.asm, contains('call\trbt_showpic'));
      expect(r.asm, isNot(contains('rba_pic:')));
    });

    test('COPYBANK emits banked->resident copy with size', () {
      final r = compile({
        'm.rbw': 'PROGRAM "T"\nTARGET 128\nMAIN:\n  COPYBANK "tune", #9000\n'
      }, target: 128, banked: banked, bankedSize: bankedSize);
      expect(r.ok, isTrue);
      expect(r.asm, contains('ld\ta,7'));
      expect(r.asm, contains('ld\thl,#c100'));
      expect(r.asm, contains('ld\tbc,100'));
      expect(r.asm, contains('call\trbt_copybank'));
    });

    test('banked MUSIC on 128K pages the bank and starts AY', () {
      final r = compile(
          {'m.rbw': 'PROGRAM "T"\nTARGET 128\nMAIN:\n  MUSIC "tune"\n'},
          target: 128, banked: banked, bankedSize: bankedSize);
      expect(r.ok, isTrue);
      expect(r.asm, contains('ld\ta,7'));
      expect(r.asm, contains('call\trbt_ay_start'));
      expect(r.asm, contains('rbt_bank:')); // module included
    });

    test('banked SPRITE CREATE preserves the sprite id across the page', () {
      final r = compile(
          {
            'm.rbw':
                'PROGRAM "T"\nTARGET 128\nMAIN:\n  SPRITE CREATE 2,"gem",10,20\n'
          },
          target: 128,
          banked: const {'gem': (bank: 1, addr: 0xC300)},
          bankedSize: const {'gem': 20});
      expect(r.ok, isTrue);
      // A holds the sprite id — the bank-page call must be wrapped in
      // push/pop af so rbt_bank's A=bank|0x10 can't clobber it, and the
      // bank itself is passed in E for the slot metadata.
      expect(
          r.asm,
          contains(RegExp('push\\taf\\s+ld\\ta,1\\s+call\\trbt_bank\\s+'
              'ld\\thl,#c300\\s+pop\\taf\\s+ld\\te,#1\\s+'
              'call\\trbt_sp_create')));
    });

    test('banked reference on a 48K target is an error', () {
      final r = compile({'m.rbw': 'PROGRAM "T"\nMAIN:\n  SHOWPIC "pic"\n'},
          target: 48, banked: banked, bankedSize: bankedSize);
      expect(r.ok, isFalse);
      expect(r.diag.items.join('\n'), contains('has no banked RAM'));
    });

    test('USEBANK on 48K is an error', () {
      final r =
          compile({'m.rbw': 'PROGRAM "T"\nMAIN:\n  USEBANK 1\n'}, target: 48);
      expect(r.ok, isFalse);
    });
  });

  group('zxplus3 platform', () {
    test('bank file table uses #FF terminator so bank 0 loads', () {
      final r = compile(
          {'m.rbw': 'PROGRAM "T"\nTARGET ZXPLUS3\nMAIN:\n  SHOWPIC "pic"\n'},
          target: 3,
          banked: const {'pic': (bank: 0, addr: 0xC000)},
          bankedSize: const {'pic': 6912});
      expect(r.ok, isTrue, reason: r.diag.items.join('\n'));
      // Entry order: bank byte, "BANKn.BIN", #FF name terminator; the
      // table itself ends with #FF — 0 is a valid bank on ZX.
      expect(
          r.asm,
          contains('rbt_bankfiles:\n\tdefb\t0\n\tdefm\t"BANK0.BIN"\n'
              '\tdefb\t#ff\n\tdefb\t#ff'));
      expect(r.asm, contains('rbt_p3load:'));
      expect(r.asm, contains('RBT_BANKM\tequ\t#5b5c'));
    });

    test('MUSIC on +3 uses the AY driver, not blocking ANT', () {
      final r = compile(
          {'m.rbw': 'PROGRAM "T"\nTARGET ZXPLUS3\nMAIN:\n  MUSIC "tune"\n'},
          target: 3,
          banked: const {'tune': (bank: 3, addr: 0xC000)},
          bankedSize: const {'tune': 100});
      expect(r.ok, isTrue, reason: r.diag.items.join('\n'));
      expect(r.asm, contains('call\trbt_ay_start'));
      expect(r.asm, isNot(contains('call\trbt_ant')));
      expect(r.asm, contains('jp\trbt_ay_tick')); // frame hook
    });
  });

  group('bank loader + map', () {
    test('buildBankLoader emits per-bank loads then jumps to org', () {
      final asm =
          buildBankLoader({3: Uint8List(10), 0: Uint8List(20)}, 0x8000, 999);
      expect(asm, contains('org\t#6000'));
      // bank 0 and 3 each get an out + LD_BYTES load at c000; every
      // page write keeps the 48K ROM selected (bank | 0x10) so ROM
      // LD-BYTES and the IM1 ISR are reachable
      expect(asm, contains('ld\ta,19\n\tout\t(c),a')); // bank 3
      expect(asm, contains('ld\ta,16\n\tout\t(c),a')); // bank 0
      expect(asm, contains('ld\tix,#c000'));
      expect(asm, contains('ld\tix,#8000'));
      expect(asm, contains('ld\tde,999'));
      expect(asm.trim().endsWith('jp\t#8000'), isTrue);
    });

    test('buildMapReport lists per-bank usage', () {
      final scan = AssetScan({}, {
        'tune': (bank: 3, addr: 0xC000)
      }, {
        3: Uint8List(100)
      }, {
        3: [('tune', 0xC000, 100)]
      });
      final map = buildMapReport('T', 0x8000, 500, scan);
      expect(map, contains('bank 3'));
      expect(map, contains('tune'));
      expect(map, contains('16284'));
    });
  });

  group('multi-target + INCLUDE', () {
    Directory mkMulti() {
      final d = Directory.systemTemp.createTempSync('rb_mt_test');
      Directory('${d.path}/src').createSync(recursive: true);
      File('${d.path}/project.rbw.json').writeAsStringSync(jsonEncode({
        'name': 'MT',
        'targets': {
          'zx48': {'target': 48, 'sources': ['src/main48.rbw']},
          'zx128': {'target': 128, 'sources': ['src/main128.rbw']},
        },
      }));
      File('${d.path}/src/shared.rbw')
          .writeAsStringSync('SUB helper()\nEND SUB\n');
      File('${d.path}/src/main48.rbw').writeAsStringSync(
          'PROGRAM "mt"\nINCLUDE "shared.rbw"\nMAIN:\n  CALL helper\n');
      File('${d.path}/src/main128.rbw').writeAsStringSync(
          'PROGRAM "mt"\nTARGET 48\nINCLUDE "shared.rbw"\nMAIN:\n  CALL helper\n');
      return d;
    }

    test('targets map builds every entry into build/<key>/', () async {
      final d = mkMulti();
      final r = await buildProject(d.path, assemble: false);
      expect(r.ok, isTrue);
      expect(File('${d.path}/build/zx48/game.asm').existsSync(), isTrue);
      expect(File('${d.path}/build/zx128/game.asm').existsSync(), isTrue);
      expect(r.log.join('\n'), contains('== target zx48 =='));
      // INCLUDE pulled shared.rbw in: CALL helper resolved both sides
      expect(File('${d.path}/build/zx48/game.asm').readAsStringSync(),
          isNot(contains('undefined')));
      // main128 declares TARGET 48 but the manifest says 128 -> warning
      expect(r.log.join('\n'), contains('TARGET zx48 ignored'));
      d.deleteSync(recursive: true);
    });

    test('targetName selects one entry; unknown name errors', () async {
      final d = mkMulti();
      final r = await buildProject(d.path,
          assemble: false, targetName: 'zx48');
      expect(r.ok, isTrue);
      expect(File('${d.path}/build/zx48/game.asm').existsSync(), isTrue);
      final r2 = await buildProject(d.path,
          assemble: false, targetName: 'cpc');
      expect(r2.ok, isFalse);
      expect(r2.log.join('\n'), contains('unknown target'));
      d.deleteSync(recursive: true);
    });

    test('INCLUDE expands relative paths and reports missing files',
        () async {
      final d = _mkproj((p) {
        File('${p.path}/src/main.rbw').writeAsStringSync(
            'PROGRAM "t"\nINCLUDE "sub/lib.rbw"\nMAIN:\n  CALL f\n');
        Directory('${p.path}/src/sub').createSync();
        File('${p.path}/src/sub/lib.rbw')
            .writeAsStringSync('INCLUDE "../x.rbw"\nSUB f()\nEND SUB\n');
        File('${p.path}/src/x.rbw').writeAsStringSync('DIM q AS BYTE\n');
      });
      final r = await buildProject(d.path, assemble: false);
      expect(r.ok, isTrue);
      d.deleteSync(recursive: true);

      final d2 = _mkproj((p) {
        File('${p.path}/src/main.rbw').writeAsStringSync(
            'PROGRAM "t"\nINCLUDE "gone.rbw"\nMAIN:\n');
      });
      final r2 = await buildProject(d2.path, assemble: false);
      expect(r2.ok, isFalse);
      expect(r2.log.join('\n'), contains('missing source: src/gone.rbw'));
      d2.deleteSync(recursive: true);
    });
  });

  group('cpc464 platform', () {
    test('target resolution and platform metadata', () {
      expect(resolveTargetId('cpc464'), 464);
      expect(resolveTargetId('CPC464'), 464);
      expect(platformOf(464), TargetFamily.cpc);
      expect(platformOf(48), TargetFamily.zx);
      expect(targetNameOf(464), 'cpc464');
      expect(defaultOrgOf(464), 0x4000);
      expect(defaultOrgOf(48), 0x8000);
      expect(targetSupportsModule(464, 'core'), isTrue);
      expect(targetSupportsModule(464, 'sprite'), isTrue);
      expect(targetSupportsModule(464, 'ay'), isTrue);
      expect(targetSupportsModule(464, 'bank'), isFalse);
      expect(targetSupportsModule(464, 'ant'), isFalse);
    });

    test('TARGET CPC464 compiles core statements with cpc org', () {
      final r = compile({
        'm.rbw': 'PROGRAM "t"\nTARGET CPC464\n'
            'MAIN:\n  MODE 1\n  BORDER 1\n  CLS\n'
            '  PRINTAT 1, 1, "hi"\n  END\n'
      });
      expect(r.ok, isTrue, reason: r.diag.items.join('\n'));
      expect(r.info!.target, 464);
      expect(r.asm, contains('org\t#4000'));
      expect(r.asm, contains('call\trbt_scrmode'));
      expect(r.asm, contains('FW_SCR_SET_MODE'));
      expect(r.asm, contains('rbt_waitkey:')); // cpc core linked
      expect(r.asm, contains('FW_MC_WAIT_FLY'));
      // no MODE warning on CPC, and ZX runtime not linked
      expect(r.diag.items.join('\n'), isNot(contains('MODE')));
      expect(r.asm, isNot(contains('out     (#fe),a')));
    });

    test('MODE warns on ZX targets only', () {
      final r = compile({'m.rbw': 'PROGRAM "t"\nMAIN:\n  MODE 1\n'},
          target: 48);
      expect(r.ok, isTrue);
      expect(r.diag.items.join('\n'),
          contains('MODE has no effect on ZX targets'));
    });

    test('platform-unsupported statements error politely on cpc464', () {
      final r = compile({
        'm.rbw': 'PROGRAM "t"\nTARGET CPC464\n'
            'MAIN:\n'
            '  USEBANK 3\n'
            '  COPYBANK "tune", #9000\n'
            '  END\n'
      }, banked: {
        'tune': (bank: 3, addr: 0xC000)
      }, bankedSize: {
        'tune': 100
      });
      expect(r.ok, isFalse);
      final log = r.diag.items.join('\n');
      expect(log,
          contains('USEBANK requires a banked target (zx128/zxplus3/cpc6128)'));
      expect(log, contains(
          'COPYBANK requires a banked target (zx128/zxplus3/cpc6128)'));
    });

    test('assets-<key> overlay overrides same-named shared assets', () {
      final d = _mkproj((p) {
        Directory('${p.path}/assets').createSync(recursive: true);
        Directory('${p.path}/assets-cpc464').createSync(recursive: true);
        File('${p.path}/assets/s.rbs').writeAsStringSync(_spriteJson());
        File('${p.path}/assets-cpc464/s.rbs')
            .writeAsStringSync(_spriteJson('#'));
      });
      final shared = scanAssets(d.path)!;
      final cpc = scanAssets(d.path, overlayKey: 'cpc464')!;
      // overlay only applies to its own key
      final other = scanAssets(d.path, overlayKey: 'zx48')!;
      expect(shared.resident['s'], isNotNull);
      expect(other.resident['s'].toString(),
          shared.resident['s'].toString());
      expect(cpc.resident['s'].toString(),
          isNot(shared.resident['s'].toString()));
      d.deleteSync(recursive: true);
    });

    test('cpc464 manifest entry builds build/cpc464/game.asm', () async {
      final d = Directory.systemTemp.createTempSync('rb_cpc_test');
      Directory('${d.path}/src').createSync(recursive: true);
      File('${d.path}/project.rbw.json').writeAsStringSync(jsonEncode({
        'name': 'T',
        'targets': {
          'zx48': {'target': 'zx48', 'sources': ['src/main.rbw']},
          'cpc464': {'target': 'cpc464', 'sources': ['src/main.rbw']},
        },
      }));
      File('${d.path}/src/main.rbw').writeAsStringSync(
          'PROGRAM "t"\nMAIN:\n  CLS\n  PRINT "hi"\n  END\n');
      final r = await buildProject(d.path, assemble: false);
      expect(r.ok, isTrue, reason: r.log.join('\n'));
      expect(File('${d.path}/build/cpc464/game.asm').readAsStringSync(),
          contains('org\t#4000'));
      expect(File('${d.path}/build/zx48/game.asm').readAsStringSync(),
          contains('org\t#8000'));
      d.deleteSync(recursive: true);
    });
  });

  group('cpc6128 platform', () {
    test('target resolution and bank metadata', () {
      expect(resolveTargetId('cpc6128'), 6128);
      expect(platformOf(6128), TargetFamily.cpc);
      expect(targetNameOf(6128), 'cpc6128');
      expect(defaultOrgOf(6128), 0x8000);
      expect(bankCapableOf(6128), isTrue);
      expect(bankCapableOf(464), isFalse);
      expect(bankCapableOf(128), isTrue);
      expect(targetSupportsModule(6128, 'bank'), isTrue);
    });

    test('cpc bank dirs accept banks 4-7 only', () {
      final errs = <String>[];
      final d = _mkproj((p) {
        Directory('${p.path}/assets/bank4').createSync(recursive: true);
        File('${p.path}/assets/bank4/tune.rbs')
            .writeAsStringSync(_spriteJson('#'));
      });
      final scan = scanAssets(d.path,
          onError: errs.add, pageableBanks: kCpcPageableBanks)!;
      expect(errs, isEmpty);
      expect(scan.banked['tune']!.bank, 4);
      // a ZX-style bank dir errors on the cpc6128 bank set
      Directory('${d.path}/assets/bank1').createSync(recursive: true);
      File('${d.path}/assets/bank1/x.rbs').writeAsStringSync(_spriteJson());
      expect(
          scanAssets(d.path,
              onError: errs.add, pageableBanks: kCpcPageableBanks),
          isNull);
      expect(errs.last, contains('not a pageable bank dir'));
      d.deleteSync(recursive: true);
    });

    test('cpc6128 codegen emits scr base equ + bank file table', () {
      final r = compile({
        'm.rbw': 'PROGRAM "t"\nTARGET CPC6128\n'
            'MAIN:\n  CHARSET "crypt"\n  PRINTAT 0,0,"x"\n  END\n'
      }, banked: {
        'crypt': (bank: 4, addr: 0xC000)
      });
      expect(r.ok, isTrue, reason: r.diag.items.join('\n'));
      expect(r.asm, contains('RBT_SCRB\tequ\t#c000'));
      expect(r.asm, contains('RBT_SCRP\tequ\t#c0'));
      expect(r.asm, contains('ld\ta,4\n\tcall\trbt_bank'));
      expect(r.asm, contains('rbt_bankfiles:'));
      expect(r.asm, contains('defm\t"BANK4.BIN"'));
      expect(r.asm, contains('rbt_bankload:')); // real loader, not stub
      expect(r.asm, isNot(contains('rbt_bankload:\tret')));
    });

    test('cpc464 emits c000 scr base and bankload stub', () {
      final r = compile({
        'm.rbw': 'PROGRAM "t"\nTARGET CPC464\n'
            'MAIN:\n  CLS\n  END\n'
      });
      expect(r.ok, isTrue, reason: r.diag.items.join('\n'));
      expect(r.asm, contains('RBT_SCRB\tequ\t#c000'));
      expect(r.asm, contains('rbt_bankload:\tret'));
    });

    test('amsdos header checksums and dsk packs files into blocks', () {
      final hdr = buildAmsdosHeader('GAME.BIN',
          loadAddr: 0x8000, execAddr: 0x8000, dataLen: 100);
      var sum = 0;
      for (var i = 0; i < 67; i++) {
        sum += hdr[i];
      }
      expect(hdr[67] | (hdr[68] << 8), sum);
      expect(hdr[18], 2); // binary
      expect(hdr[21] | (hdr[22] << 8), 0x8000);
      expect(hdr[26] | (hdr[27] << 8), 0x8000);
      expect(
          String.fromCharCodes(hdr.sublist(1, 9)).trimRight(), 'GAME');

      final dsk = buildDsk([
        (
          name: 'GAME.BIN',
          bytes: [...hdr, ...List.filled(100, 0xAA)],
        ),
        (
          name: 'BANK4.BIN',
          bytes: List.filled(128 + 100, 0x55),
        ),
      ]);
      expect(
          String.fromCharCodes(dsk.sublist(0, 8)), 'EXTENDED');
      expect(dsk[0x30], 40); // tracks
      // dir entry 0: GAME.BIN -> blocks from 2; entry 1: BANK4.BIN
      expect(String.fromCharCodes(dsk.sublist(0x201, 0x209)).trimRight(),
          'GAME');
      expect(String.fromCharCodes(dsk.sublist(0x209, 0x20C)).trimRight(),
          'BIN');
      expect(String.fromCharCodes(dsk.sublist(0x221, 0x229)).trimRight(),
          'BANK4');
      expect(dsk[0x210], 2); // first data block after directory
      // data format: sector IDs interleaved by the AMSDOS skew table
      // (#C1,#C6,#C2,...) — sequential IDs would make AMSDOS read the
      // wrong sectors for every other logical block.
      expect(dsk[0x100 + 0x18 + 2], 0xC1); // logical sector 0
      expect(dsk[0x100 + 0x18 + 8 + 2], 0xC6); // logical sector 1
      expect(dsk[0x34], 0x13); // extended: track size 4864/256
      // GAME.BIN block 2 = logical sectors 4,5; slot s holds the logical
      // sector (id - #C1), so logical 4 (id #C5) is in physical slot 8
      final s4 = 0x100 + 256 + 8 * 512;
      expect(dsk[s4], 0); // user byte of the AMSDOS header
      expect(dsk[s4 + 128], 0xAA); // payload follows the header
    });

    test('cpc6128 multi-target project builds a .dsk', () async {
      final d = Directory.systemTemp.createTempSync('rb_cpc6128_test');
      Directory('${d.path}/src').createSync(recursive: true);
      Directory('${d.path}/assets-cpc6128/bank4')
          .createSync(recursive: true);
      File('${d.path}/project.rbw.json').writeAsStringSync(jsonEncode({
        'name': 'T',
        'targets': {
          'cpc6128': {
            'target': 'cpc6128',
            'sources': ['src/main.rbw']
          },
        },
      }));
      File('${d.path}/src/main.rbw').writeAsStringSync('PROGRAM "t"\n'
          'TARGET CPC6128\n'
          'MAIN:\n  CHARSET "crypt"\n  PRINTAT 0,0,"x"\n  END\n');
      File('${d.path}/assets-cpc6128/bank4/crypt.rbf')
          .writeAsStringSync(jsonEncode({
        'name': 'crypt',
        'chars': {
          '65': List.filled(8, '11111111'),
        }
      }));
      final r = await buildProject(d.path, assemble: false);
      expect(r.ok, isTrue, reason: r.log.join('\n'));
      expect(File('${d.path}/build/cpc6128/game.asm').readAsStringSync(),
          contains('org\t#8000'));
      d.deleteSync(recursive: true);
    });
  });

  group('c64 platform', () {
    test('target resolution and org', () {
      expect(resolveTargetId('c64'), 64);
      expect(resolveTargetId('C64'), 64);
      expect(resolveTargetId('c128'), 1280);
      expect(platformOf(64), TargetFamily.cbm);
      expect(platformOf(1280), TargetFamily.cbm);
      expect(platformOf(48), TargetFamily.zx);
      expect(platformNameOf(64), 'cbm');
      expect(defaultOrgOf(64), 0x0801);
      expect(bankCapableOf(64), isFalse);
    });

    test('c64 codegen emits ca65 source with BASIC stub', () {
      final r = compile(
          {'m.rbw': 'PROGRAM "T"\nTARGET C64\nMAIN:\n  PRINT "HI"\n  END\n'},
          target: 64);
      expect(r.ok, isTrue, reason: r.diag.items.join('\n'));
      expect(r.asm, contains('; rainbow build — ca65 source'));
      // 10 SYS 2062 stub so LOAD+RUN works from BASIC
      expect(r.asm, contains('.byte\t\$9e," 2062",0'));
      expect(r.asm, contains('jmp\trbt_start'));
      expect(r.asm, contains('jsr\trbt_print_str'));
      // virtual-register + runtime-module conventions
      expect(r.asm, contains('rbt_hl'));
      expect(r.asm, contains('rbt_hook_frame:'));
      // word pushes/pops are inline — a jsr'd helper would leave data
      // above the return address on the hardware stack
      expect(r.asm, isNot(contains('jsr\trbt_ph')));
      expect(r.asm, isNot(contains('jsr\trbt_pd')));
      // no Z80/pasmo syntax leaks in
      expect(r.asm, isNot(contains('\torg\t')));
      expect(r.asm, isNot(contains('defb')));
    });

    test('c64 tilemap pulls tmdata + tilemap + charset modules', () {
      final r = compile({
        'm.rbw': 'PROGRAM "T"\nTARGET C64\nMAIN:\n'
            '  TILESET "ts"\n  TILEMAP "lv"\n'
            '  TILEMAP VIEW 0, 0, 10, 5\n  TILEMAP CAMERA 0, 0\n'
            '  TILEMAP DRAW\n  PRINT TILEAT(1, 1)+TILEFLAGS(1)\n  END\n'
      }, target: 64, assets: {
        'ts': Uint8List.fromList(
            [2, ...List.filled(16, 0), 56, 69, 0, 1]),
        'lv': Uint8List.fromList(
            [4, 3, ...List.filled(12, 1)]),
      });
      expect(r.ok, isTrue, reason: r.diag.items.join('\n'));
      for (final call in [
        'rbt_tm_settiles',
        'rbt_tm_setmap',
        'rbt_tm_view',
        'rbt_tm_camera',
        'rbt_tm_draw',
        'rbt_tileat',
        'rbt_tileflags',
      ]) {
        expect(r.asm, contains('jsr\t$call'), reason: call);
      }
      // the charset module is pulled in too: the tilemap engine reads
      // rbt_font to decide how much chargen ROM to populate first
      expect(r.asm, contains('rbt_font:'));
      // scroll + mutators exist in the runtime
      expect(r.asm, contains('rbt_tm_scroll:'));
      expect(r.asm, contains('rbt_tileatset:'));
    });

    test('c64 sprites pull the VIC-II mux module', () {
      final r = compile({
        'm.rbw': 'PROGRAM "T"\nTARGET C64\nMAIN:\n'
            '  TILESET "ts"\n  TILEMAP "lv"\n'
            '  SPRITE CREATE 0, "sp", 10, 10\n'
            '  SPRITES UPDATE\n'
            '  PRINT SPRITEX(0)+SPRITECOLLIDE(0,1)+COLLIDETILE(0)\n'
            '  END\n'
      }, target: 64, assets: {
        'sp': Uint8List.fromList(
            [16, 8, 1, 1, ...List.filled(63, 0)]),
        'ts': Uint8List.fromList([1, ...List.filled(8, 0), 56, 1]),
        'lv': Uint8List.fromList([4, 4, ...List.filled(16, 0)]),
      });
      expect(r.ok, isTrue, reason: r.diag.items.join('\n'));
      for (final call in [
        'rbt_sp_create',
        'rbt_sp_update',
        'rbt_spx',
        'rbt_spcoll',
      ]) {
        expect(r.asm, contains('jsr\t$call'), reason: call);
      }
      // the raster-IRQ mux lives in the sprite module
      expect(r.asm, contains('rbt_sp_irq:'));
      expect(r.asm, contains('rbt_slot:'));
      // spcoll (COLLIDETILE) needs the tilemap bridge too
      expect(r.asm, contains('rbt_colltile:'));
    });

    test('USEBANK / COPYBANK error on c64', () {
      final r = compile(
          {'m.rbw':
              'PROGRAM "T"\nTARGET C64\nMAIN:\n  USEBANK 0\n  END\n'},
          target: 64,
          banked: const {},
          bankedSize: const {});
      expect(r.diag.items.join('\n'), contains('banked target'));
    });

    test('c64 build produces game.s', () async {
      final d = Directory.systemTemp.createTempSync('rb_c64_test');
      Directory('${d.path}/src').createSync(recursive: true);
      File('${d.path}/project.rbw.json').writeAsStringSync(jsonEncode({
        'name': 'T',
        'target': 'c64',
        'sources': ['src/main.rbw']
      }));
      File('${d.path}/src/main.rbw').writeAsStringSync(
          'PROGRAM "t"\nMAIN:\n  PRINT "HI"\n  END\n');
      final r = await buildProject(d.path, assemble: false);
      expect(r.ok, isTrue, reason: r.log.join('\n'));
      expect(File('${d.path}/build/game.s').existsSync(), isTrue);
      expect(File('${d.path}/build/game.s').readAsStringSync(),
          contains('ca65'));
      d.deleteSync(recursive: true);
    });

    test('c64 sound pulls sid + sfx modules and wires the frame hook', () {
      final r = compile({
        'm.rbw': 'PROGRAM "T"\nTARGET C64\n'
            'MAIN:\n  MUSIC "tune"\n  SFX "zap"\n'
            '  PAUSE 2\n  MUSIC STOP\n  END\n'
      }, target: 64, assets: {
        'tune': Uint8List.fromList([8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 15, 0, 0, 0]),
        'zap': Uint8List.fromList([4, 8, 0, 32, 0, 0, 0]),
      });
      expect(r.ok, isTrue, reason: r.diag.items.join('\n'));
      for (final call in ['rbt_sid_start', 'rbt_sid_stop', 'rbt_sfx']) {
        expect(r.asm, contains('jsr\t$call'), reason: call);
      }
      expect(r.asm, contains('rbt_sid_tick:'));
      expect(r.asm, contains('jmp\trbt_sid_tick'));
      expect(r.asm, contains('rbt_sfx_drain:'));
    });

    test('c64 COPYBANK kernal-loads a disk file', () {
      final r = compile({
        'm.rbw': 'PROGRAM "T"\nTARGET C64\n'
            'MAIN:\n  COPYBANK "tiles", #6000\n  END\n'
      }, target: 64, banked: const {
        'tiles': (bank: 0, addr: 0xC000)
      }, bankedSize: const {
        'tiles': 100
      });
      expect(r.ok, isTrue, reason: r.diag.items.join('\n'));
      final asm = r.asm!;
      expect(asm, contains('jsr\trbt_diskload'));
      expect(asm, contains('rbt_diskload:'));
      // length-prefixed PETSCII name record for SETNAM
      expect(asm, contains('rbf_tiles:'));
      expect(asm, contains('\t.byte\t5,"TILES"'));
      // resident assets can't be COPYBANK'd
      final r2 = compile({
        'm.rbw': 'PROGRAM "T"\nTARGET C64\n'
            'MAIN:\n  COPYBANK "tiles", #6000\n  END\n'
      }, target: 64, assets: {
        'tiles': Uint8List(8)
      });
      expect(r2.diag.items.join('\n'), contains('resident, not banked'));
    });

    test('conditional jumps lower to branch+jmp trampolines', () {
      // 6502 conditional branches are ±127 bytes — IF/WHILE exit jumps
      // over large bodies must not be bare bXX (ca65 range error).
      final r = compile({
        'm.rbw': 'PROGRAM "T"\nTARGET C64\n'
            'MAIN:\n  DIM X\n  X=1\n'
            '  IF X=0 THEN\n    PRINT "A"\n  ENDIF\n'
            '  WHILE X<10\n    X=X+1\n  WEND\n  END\n'
      }, target: 64, banked: const {}, bankedSize: const {});
      expect(r.ok, isTrue, reason: r.diag.items.join('\n'));
      final asm = r.asm!;
      // X=0 false -> bne exit, lowered as `beq skip; jmp exit`.
      expect(RegExp(r'beq\s+rb_l\d+\s*\n\s*jmp\s+rb_l\d+').hasMatch(asm),
          isTrue, reason: 'IF exit should be a jmp trampoline');
      // no bare conditional branch may target a far rb_ label
      for (final m in RegExp(r'(beq|bne|bcc|bcs|bmi|bpl)\s+(rb_l\d+)')
          .allMatches(asm)) {
        final from = asm.indexOf(m.group(0)!);
        final target = asm.indexOf('${m.group(2)}:');
        expect((target - from).abs(), lessThan(120),
            reason: '${m.group(1)} ${m.group(2)} may exceed ±127');
      }
    });
  });
}
