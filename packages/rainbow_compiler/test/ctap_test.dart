import 'dart:typed_data';

import 'package:rainbow_compiler/src/ctap.dart';
import 'package:test/test.dart';

// Symbol constants must match ctap.dart.
const _s = 0x30, _m = 0x42, _l = 0x56;

List<int> _payload(Uint8List tap) =>
    tap.sublist(20, 20 + (tap[16] | tap[17] << 8 | tap[18] << 16));

// Decodes one tape byte (L,M marker + 8 bits LSB first + odd parity)
// starting at p[i]. Returns (value, index past the byte).
(int, int) _byte(List<int> p, int i) {
  expect(p[i], _l, reason: 'byte marker at $i');
  expect(p[i + 1], _m);
  i += 2;
  var v = 0;
  var parity = 1;
  for (var k = 0; k < 8; k++) {
    final bit = (p[i] == _m && p[i + 1] == _s)
        ? 1
        : (p[i] == _s && p[i + 1] == _m ? 0 : -1);
    expect(bit, isNonNegative, reason: 'bit $k at $i');
    v |= bit << k;
    parity ^= bit;
    i += 2;
  }
  final pbit = (p[i] == _m && p[i + 1] == _s)
      ? 1
      : (p[i] == _s && p[i + 1] == _m ? 0 : -1);
  expect(pbit, parity, reason: 'parity at $i');
  return (v, i + 2);
}

int _skipLeader(List<int> p, int i) {
  while (p[i] == _s) {
    i++;
  }
  return i;
}

// Decodes the 9-byte sync train starting at p[i].
(List<int>, int) _sync(List<int> p, int i) {
  final out = <int>[];
  for (var k = 0; k < 9; k++) {
    final pk = _byte(p, i);
    out.add(pk.$1);
    i = pk.$2;
  }
  return (out, i);
}

// Decodes [n] payload bytes then the checkbyte; verifies XOR.
(List<int>, int) _payloadBlock(List<int> p, int i, int n) {
  final out = <int>[];
  var chk = 0;
  for (var k = 0; k < n; k++) {
    final pk = _byte(p, i);
    out.add(pk.$1);
    chk ^= pk.$1;
    i = pk.$2;
  }
  final pk = _byte(p, i);
  expect(pk.$1, chk, reason: 'checkbyte at $i');
  return (out, pk.$2);
}

void main() {
  test('tap container header', () {
    final tap =
        buildC64Tap(Uint8List.fromList([1, 2, 3]), name: 'X', org: 0x0801);
    expect(String.fromCharCodes(tap.sublist(0, 12)), 'C64-TAPE-RAW');
    expect(tap[12], 1);
    expect(tap.length, 20 + (tap[16] | tap[17] << 8 | tap[18] << 16));
  });

  test('header block decodes: sync, type, range, name, checksum', () {
    final code =
        Uint8List.fromList(List<int>.generate(20, (i) => i * 7 & 0xFF));
    final tap = buildC64Tap(code, name: 'HELLO', org: 0x0801);
    final p = _payload(tap);
    var i = _skipLeader(p, 0);
    final (sync, i1) = _sync(p, i);
    expect(sync, [for (var k = 0; k < 9; k++) 0x89 - k]);
    final (hdr, i2) = _payloadBlock(p, i1, 192);
    i = i2;
    expect(hdr[0], 0x03);
    expect(hdr.sublist(1, 5), [0x01, 0x08, 20 + 1, 0x08]);
    expect(String.fromCharCodes(hdr.sublist(5, 10)), 'HELLO');
    // trailer: L + ~79 S, then second-copy sync $09..$01
    expect(p[i], _l);
    i = _skipLeader(p, i + 1);
    final (sync2, _) = _sync(p, i);
    expect(sync2, [for (var k = 0; k < 9; k++) 0x09 - k]);
  });

  test('data block round-trips payload', () {
    final code = Uint8List.fromList([0xA9, 0x2A, 0x60, 0xFF, 0x00]);
    final tap = buildC64Tap(code, name: 'Z', org: 0x0801);
    final p = _payload(tap);
    var i = 0;
    // header copies
    for (var rep = 0; rep < 2; rep++) {
      i = _skipLeader(p, i);
      final (_, i1) = _sync(p, i);
      final (_, i2) = _payloadBlock(p, i1, 192);
      i = i2;
      expect(p[i], _l);
      i++;
    }
    // data block
    i = _skipLeader(p, i);
    final (_, i3) = _sync(p, i);
    final (data, _) = _payloadBlock(p, i3, code.length);
    expect(data, code);
  });
}
