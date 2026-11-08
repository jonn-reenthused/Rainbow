import 'dart:typed_data';

/// MSX1 packaging: cassette (.cas) and cartridge (.rom) images.

/// Cassette block lead-in: the BIOS tape header's decoded byte pattern
/// (0x13, not 0x26 — the fourth pair is CC 13).
const _casHeader = [0x1F, 0xA6, 0xDE, 0xBA, 0xCC, 0x13, 0x7D, 0x74];

/// Build an MSX binary cassette image loadable with `BLOAD"CAS:",R`:
///   [header] [0xD0 x10] [6-byte name]
///   [header] [start][end][exec] [data]
Uint8List buildMsxCas(
    {required String name, required int org, required List<int> code}) {
  final out = BytesBuilder(copy: false)
    ..add(_casHeader)
    ..add(List.filled(10, 0xD0));
  final fn = name.toUpperCase().padRight(6).substring(0, 6);
  out.add(fn.codeUnits);
  out.add(_casHeader);
  final end = org + code.length - 1;
  out.add([
    org & 0xFF, org >> 8,
    end & 0xFF, end >> 8,
    org & 0xFF, org >> 8,
  ]);
  out.add(code);
  return out.toBytes();
}

/// Offset of the ROM header's INIT routine within the cart page.
const _msxRomInitOff = 0x10;

/// Offset of the payload copy within the cart page (after the
/// preamble: 16-byte header + 15-byte routine, padded to 0x40).
const _msxRomPayOff = 0x40;

/// Build an MSX cartridge image. Bank 0 maps at #4000 and carries the
/// header + INIT routine, which copies the payload to RAM at [org] and
/// jumps in (variables stay writable). With [bankBlobs] the image grows
/// to one 16K page per bank — bank N's blob sits at file offset
/// N*0x4000 so it appears at #4000 when `rbt_bank` writes N to the
/// #6000 ASCII16 register. Returns null when [code] doesn't fit bank 0.
Uint8List? buildMsxRom(List<int> code,
    {required int org, Map<int, Uint8List> bankBlobs = const {}}) {
  if (code.length > 0x4000 - _msxRomPayOff) return null;
  var maxBank = 0;
  for (final b in bankBlobs.keys) {
    if (b > maxBank) maxBank = b;
  }
  final rom = Uint8List(0x4000 * (maxBank + 1));
  rom[0] = 0x41; // 'A'
  rom[1] = 0x42; // 'B'
  rom[2] = _msxRomInitOff & 0xFF;
  rom[3] = 0x40; // INIT = #4010
  // Preamble at #4010: di; ld hl,payload; ld de,org; ld bc,len; ldir; jp org
  var i = _msxRomInitOff;
  rom[i++] = 0xF3; // di
  rom[i++] = 0x21; // ld hl,NN
  rom[i++] = _msxRomPayOff & 0xFF;
  rom[i++] = 0x40;
  rom[i++] = 0x11; // ld de,NN
  rom[i++] = org & 0xFF;
  rom[i++] = org >> 8;
  rom[i++] = 0x01; // ld bc,NN
  rom[i++] = code.length & 0xFF;
  rom[i++] = code.length >> 8;
  rom[i++] = 0xED;
  rom[i++] = 0xB0; // ldir
  rom[i++] = 0xC3; // jp NN
  rom[i++] = org & 0xFF;
  rom[i++] = org >> 8;
  rom.setAll(_msxRomPayOff, code);
  for (final e in bankBlobs.entries) {
    if (e.value.length > 0x4000) return null;
    rom.setAll(e.key * 0x4000, e.value);
  }
  return rom;
}
