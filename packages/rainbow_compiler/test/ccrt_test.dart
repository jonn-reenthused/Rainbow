import 'dart:typed_data';

import 'package:rainbow_compiler/src/ccrt.dart';
import 'package:test/test.dart';

void main() {
  test('crt header and chip packet', () {
    final crt = buildC64Cart(
        name: 'HELLO', code: Uint8List.fromList([1, 2, 3]))!;
    expect(String.fromCharCodes(crt.sublist(0, 16)), 'C64 CARTRIDGE   ');
    expect(crt.sublist(0x10, 0x14), [0, 0, 0, 0x40]);
    expect(crt.sublist(0x14, 0x16), [0x01, 0x00]);
    expect(crt.sublist(0x16, 0x18), [0x00, 0x00]); // normal cart
    expect(crt.sublist(0x18, 0x1A), [0x00, 0x00]); // EXROM+GAME -> 16K
    expect(String.fromCharCodes(crt.sublist(0x20, 0x25)), 'HELLO');
    // CHIP packet
    expect(String.fromCharCodes(crt.sublist(0x40, 0x44)), 'CHIP');
    expect(crt.sublist(0x44, 0x48), [0, 0, 0x40, 0x10]);
    expect(crt.sublist(0x48, 0x4A), [0, 0]); // ROM
    expect(crt.sublist(0x4C, 0x4E), [0x80, 0x00]); // $8000
    expect(crt.sublist(0x4E, 0x50), [0x40, 0x00]); // 16K
    expect(crt.length, 0x50 + 0x4000);
  });

  test('boot stub copies payload to org and jumps to entry', () {
    final code = Uint8List.fromList(List<int>.generate(300, (i) => i));
    final crt = buildC64Cart(name: 'T', code: code)!;
    final rom = crt.sublist(0x50);
    // CBM80 signature + vectors at $8000
    expect(rom.sublist(0, 4), [0x09, 0x80, 0x09, 0x80]);
    expect(rom.sublist(4, 9), [0xC3, 0xC2, 0xCD, 0x38, 0x30]);
    // stub at $8009: sei, then src/dst/count operands
    expect(rom[9], 0x78);
    expect(rom.sublist(10, 12), [0xA9, 0x3F]); // src lo = $803F
    expect(rom.sublist(14, 16), [0xA9, 0x80]); // src hi
    expect(rom.sublist(18, 20), [0xA9, 0x01]); // dst lo = $0801
    expect(rom.sublist(22, 24), [0xA9, 0x08]); // dst hi
    expect(rom.sublist(26, 28), [0xA2, 1]); // 300 = 1 full page + rem
    expect(rom.sublist(48, 50), [0xC0, 300 & 0xFF]);
    // cli + jmp $080E (org + 13)
    expect(rom.sublist(59, 63), [0x58, 0x4C, 0x0E, 0x08]);
    // payload lands right after the 63-byte stub
    expect(rom.sublist(63, 63 + 300), code);
  });

  test('rejects code that does not fit a 16K cart', () {
    expect(buildC64Cart(name: 'T', code: Uint8List(0x4000 - 62)),
        isNull);
    expect(
        buildC64Cart(name: 'T', code: Uint8List(0x4000 - 63)), isNotNull);
  });
}
