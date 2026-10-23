import 'dart:typed_data';

/// Commodore .crt cartridge writer — a normal 16K cartridge (EXROM+GAME
/// asserted) mapping ROML+ROMH at $8000-$BFFF. Since the game binary is
/// a RAM image linked at [org], the cart is: CBM80 autostart signature +
/// vectors, a boot stub that copies the payload from cart ROM to [org]
/// in RAM, `cli`, `jmp org+13` (the generated `jmp rbt_start` that the
/// BASIC `SYS` also lands on).
///
/// Format (CCS64): 64-byte header — "C64 CARTRIDGE   ", header length
/// u32 BE ($40), version u16 BE ($0100), cart type u16 BE (0 normal),
/// EXROM/GAME bytes (0 = asserted), reserved, 32-byte name — then one
/// "CHIP" packet: u32 packet length, u16 chip type (0 = ROM), u16 bank,
/// u16 load address, u16 size, all big-endian.

/// Boot stub assembled by hand: at $8000 the cold/warm vectors point at
/// $8009, then "CBM80" ($C3 $C2 $CD $38 $30), then the copy loop.
/// Returns null when the code doesn't fit the 16K cart.
Uint8List? buildC64Cart(
    {required String name, required Uint8List code, int org = 0x0801}) {
  final entry = org + 13; // org: 13-byte BASIC stub, then jmp rbt_start
  final n = code.length;
  final stub = <int>[
    0x09, 0x80, 0x09, 0x80, // cold/warm vectors -> $8009
    0xC3, 0xC2, 0xCD, 0x38, 0x30, // "CBM80"
    0x78, // sei
    // src = $8000 + stubLen (patched below), dst = org, count = n
    0xA9, 0, 0x85, 0xFB, // lda #<src; sta $fb
    0xA9, 0, 0x85, 0xFC, // lda #>src; sta $fc
    0xA9, org & 0xFF, 0x85, 0xFD, // lda #<org; sta $fd
    0xA9, (org >> 8) & 0xFF, 0x85, 0xFE, // lda #>org; sta $fe
    0xA2, (n >> 8) & 0xFF, // ldx #pages
    0xF0, 0x10, // beq tail (no full pages)
    0xA0, 0x00, // ldy #0
    0xB1, 0xFB, 0x91, 0xFD, 0xC8, 0xD0, 0xF9, // cpage: copy a page
    0xE6, 0xFC, 0xE6, 0xFE, 0xCA, 0xD0, 0xF2, // next page
    0xA0, 0x00, // tail: ldy #0
    0xC0, n & 0xFF, // cpy #n&ff
    0xF0, 0x07, // beq go
    0xB1, 0xFB, 0x91, 0xFD, 0xC8, 0xD0, 0xF5, // copy remainder
    0x58, // cli
    0x4C, entry & 0xFF, (entry >> 8) & 0xFF, // jmp entry
  ];
  final src = 0x8000 + stub.length;
  if (n > 0x4000 - stub.length) return null; // doesn't fit 16K
  stub[11] = src & 0xFF; // patch src operands (offsets into stub list)
  stub[15] = (src >> 8) & 0xFF;

  final rom = Uint8List(0x4000);
  rom.setRange(0, stub.length, stub);
  rom.setRange(stub.length, stub.length + n, code);

  final out = BytesBuilder();
  out.add('C64 CARTRIDGE   '.codeUnits);
  out.add([0, 0, 0, 0x40]); // header length
  out.add([0x01, 0x00]); // version
  out.add([0x00, 0x00]); // type: normal
  out.add([0x00, 0x00]); // EXROM, GAME both asserted -> 16K
  out.add(Uint8List(6)); // reserved
  final nm = Uint8List(32);
  final u = name.toUpperCase();
  for (var i = 0; i < u.length && i < 32; i++) {
    nm[i] = u.codeUnitAt(i);
  }
  out.add(nm);
  out.add('CHIP'.codeUnits);
  out.add([0, 0, 0x40, 0x10]); // packet length
  out.add([0, 0]); // chip type: ROM
  out.add([0, 0]); // bank
  out.add([0x80, 0x00]); // load address $8000
  out.add([0x40, 0x00]); // size 16K
  out.add(rom);
  return out.toBytes();
}
