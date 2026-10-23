import 'dart:typed_data';

/// CPC+ / GX4000 cartridge image (.cpr).
///
/// The format is a RIFF container: `RIFF <u32le size> 'AMS!'` followed
/// by one `cbNN` chunk per 16K ROM block, where NN is the block number
/// as two uppercase hex digits (cb00-cb1f, max 32 blocks / 512K).
/// Block 0 is the boot page — it owns the Z80 reset vector at $0000
/// and the IM1 slot at $0038. Blocks are paged into the upper-ROM
/// window at $C000 by writing $80|page to the ROM-select port $DF00.
Uint8List buildCpr(List<Uint8List> pages) {
  if (pages.isEmpty || pages.length > 32) {
    throw ArgumentError('cartridge needs 1-32 16K pages');
  }
  final chunks = BytesBuilder();
  for (var i = 0; i < pages.length; i++) {
    final p = pages[i];
    if (p.length > 0x4000) {
      throw ArgumentError('cart page $i is ${p.length} bytes (max 16K)');
    }
    chunks
      ..add('cb'.codeUnits)
      ..add(i.toRadixString(16).padLeft(2, '0').toUpperCase().codeUnits)
      ..add(_u32(p.length))
      ..add(p);
  }
  final body = chunks.toBytes();
  return (BytesBuilder()
        ..add('RIFF'.codeUnits)
        ..add(_u32(body.length + 4)) // RIFF size includes the 'AMS!' tag
        ..add('AMS!'.codeUnits)
        ..add(body))
      .toBytes();
}

Uint8List _u32(int v) =>
    Uint8List(4)..buffer.asByteData().setUint32(0, v, Endian.little);
