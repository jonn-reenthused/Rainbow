// C64 kernal-format cassette image writer (`C64-TAPE-RAW` v1).
//
// A `.tap` stores raw pulse half-periods: each byte N means N*8 CPU
// cycles between consecutive tape edges (PAL clock 985248 Hz). The
// kernal loader recognises three pulse lengths, encoded here with the
// de-facto standard values (verified against real kernal-SAVE dumps):
//
//   S = 0x30  (384 cy, ~390 us)
//   M = 0x42  (528 cy, ~536 us)
//   L = 0x56  (688 cy, ~698 us)
//
// Symbols are pairs of pulses:
//   bit 0            = S,M
//   bit 1            = M,S
//   byte marker      = L,M   (precedes every stored byte)
//   end-of-block     = L     (single long pulse after a block)
//
// Each byte is stored as: byte marker, 8 data bits LSB first, odd
// parity bit. A block is:
//   sync train   9 countdown bytes ($89..$81 first copy / $09..$01)
//   payload      bytes, then a 1-byte XOR checkbyte
//   trailer      L + 79 S  (also serves as the second copy's leader)
//
// A program file is: header block (leader + 2 copies), data leader,
// data block (2 copies). The 192-byte header carries type, load range
// and a 16-char PETSCII name.

import 'dart:typed_data';

const int _s = 0x30;
const int _m = 0x42;
const int _l = 0x56;

/// Builds a kernal-format `.tap` image containing [data] as a single
/// non-relocatable program named [name] loading at [org].
Uint8List buildC64Tap(Uint8List data,
    {required String name, required int org}) {
  final out = <int>[];

  void leader(int n) {
    for (var i = 0; i < n; i++) {
      out.add(_s);
    }
  }

  void bit(int b) {
    if (b != 0) {
      out.add(_m);
      out.add(_s);
    } else {
      out.add(_s);
      out.add(_m);
    }
  }

  void tapeByte(int v) {
    out
      ..add(_l)
      ..add(_m); // byte marker
    var parity = 1; // odd parity over data+parity bits
    for (var k = 0; k < 8; k++) {
      final b = (v >> k) & 1;
      bit(b);
      parity ^= b;
    }
    bit(parity);
  }

  void block(Iterable<int> payload, {required bool first}) {
    // sync train: countdown bytes, MSB set on the first copy
    for (var k = 0; k < 9; k++) {
      tapeByte((first ? 0x89 : 0x09) - k);
    }
    var chk = 0;
    for (final b in payload) {
      tapeByte(b & 0xFF);
      chk ^= b & 0xFF;
    }
    tapeByte(chk);
    out.add(_l); // inter-record trailer: L + 79 S
    leader(79);
  }

  // 192-byte header block: type $03 (non-relocatable program)
  final header = List<int>.filled(192, 0x20);
  final end = org + data.length;
  header
    ..[0] = 0x03
    ..[1] = org & 0xFF
    ..[2] = (org >> 8) & 0xFF
    ..[3] = end & 0xFF
    ..[4] = (end >> 8) & 0xFF;
  final upper = name.toUpperCase();
  for (var k = 0; k < 16 && k < upper.length; k++) {
    header[5 + k] = upper.codeUnitAt(k);
  }

  leader(0x6A00); // first-copy leader (~10 s on real hardware)
  block(header, first: true);
  block(header, first: false);

  leader(0x1A00); // data-block leader (~2.6 s)
  block(data, first: true);
  block(data, first: false);

  // TAP container header
  final tap = BytesBuilder()
    ..add(Uint8List.fromList('C64-TAPE-RAW'.codeUnits))
    ..add([0x01, 0x00, 0x00, 0x00]) // v1, C64, PAL
    ..add([
      out.length & 0xFF,
      (out.length >> 8) & 0xFF,
      (out.length >> 16) & 0xFF,
      (out.length >> 24) & 0xFF,
    ])
    ..add(out);
  return tap.toBytes();
}
