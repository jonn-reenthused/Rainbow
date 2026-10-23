import 'dart:typed_data';

import 'package:rainbow_compiler/src/cd64.dart';
import 'package:test/test.dart';

const _spt = [
  21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21,
  19, 19, 19, 19, 19, 19, 19, 18, 18, 18, 18, 18, 18, 17, 17, 17, 17,
  17
];

int _off(int t, int s) {
  var o = 0;
  for (var i = 1; i < t; i++) {
    o += _spt[i - 1] * 256;
  }
  return o + s * 256;
}

// Walks a file's sector chain from its directory start sector and
// returns the payload bytes reassembled from 254-byte sectors.
List<int> _readChain(Uint8List img, int t, int s) {
  final out = <int>[];
  var guard = 0;
  while (t != 0 && guard++ < 683) {
    expect(t, inInclusiveRange(1, 35));
    expect(s, lessThan(_spt[t - 1]));
    expect(t, isNot(18), reason: 'file chain must skip track 18');
    final o = _off(t, s);
    final nt = img[o], ns = img[o + 1];
    if (nt == 0) {
      out.addAll(img.sublist(o + 2, o + 1 + ns));
      return out;
    }
    out.addAll(img.sublist(o + 2, o + 256));
    t = nt;
    s = ns;
  }
  fail('chain did not terminate');
}

void main() {
  test('image geometry and BAM', () {
    final img = buildD64(
        diskName: 'TESTDISK',
        files: [(name: 'A', data: Uint8List.fromList([1, 2, 3]))]);
    expect(img.length, 683 * 256);
    final b = _off(18, 0);
    expect(img.sublist(b, b + 4), [18, 1, 0x41, 0]);
    expect(String.fromCharCodes(img.sublist(b + 0x90, b + 0x98)),
        'TESTDISK');
    expect(img.sublist(b + 0xA0, b + 0xA7),
        [0xA0, 0xA0, 0x31, 0x41, 0xA0, 0x32, 0x41]);
    // One 1-sector file at T1S0: track 1 has 20 free, track 18 has
    // 17 free (S0 BAM + S1 dir used), others untouched.
    expect(img[b + 4 + 0], 20);
    expect(img[b + 4 + 17 * 4], 17);
    expect(img[b + 4 + 1 * 4], 21);
    // T1 bitmap: sector 0 allocated.
    expect(img[b + 5 + 0] & 1, 0);
    expect(img[b + 5 + 0] & 2, 2);
    // T18 bitmap: sectors 0-1 allocated.
    expect(img[b + 5 + 17 * 4] & 3, 0);
  });

  test('directory entry points at a valid chain', () {
    final prg = Uint8List.fromList(
        List<int>.generate(600, (i) => i * 3 & 0xFF));
    final img = buildD64(
        diskName: 'D', files: [(name: 'HELLO', data: prg)]);
    final d = _off(18, 1);
    expect(img.sublist(d, d + 2), [0, 0xFF]);
    final e = d + 2;
    expect(img[e], 0x82);
    expect(img[e + 1], 1); // start track
    expect(img[e + 2], 0); // start sector
    expect(String.fromCharCodes(img.sublist(e + 3, e + 8)), 'HELLO');
    expect(img[e + 8], 0xA0); // name pad
    expect(img[e + 30] | img[e + 31] << 8, 3); // ceil(600/254)
    final data = _readChain(img, img[e + 1], img[e + 2]);
    expect(data, prg);
  });

  test('final-sector byte count is exact', () {
    // 254-byte payload = exactly one full sector + a 0-byte remainder?
    // No: 255 bytes => 2 sectors; last holds 1 payload byte -> S = 2.
    final img = buildD64(
        diskName: 'D',
        files: [
          (name: 'X', data: Uint8List.fromList(List.filled(255, 0xAB)))
        ]);
    final o = _off(1, 1); // second sector is T1S1
    expect(img[o], 0);
    expect(img[o + 1], 2);
    expect(img[o + 2], 0xAB);
    // Exactly-full last sector: 254 bytes -> S = 255.
    final img2 = buildD64(
        diskName: 'D',
        files: [
          (name: 'Y', data: Uint8List.fromList(List.filled(254, 0)))
        ]);
    final o2 = _off(1, 0);
    expect(img2[o2], 0);
    expect(img2[o2 + 1], 255);
  });

  test('multi-sector chain links forward', () {
    final data = Uint8List.fromList(List<int>.generate(700, (i) => i));
    final img = buildD64(
        diskName: 'D', files: [(name: 'B', data: data)]);
    final e = _off(18, 1) + 2;
    expect(img[e + 30], 3); // ceil(700/254)
    var t = img[e + 1], s = img[e + 2];
    for (var i = 0; i < 2; i++) {
      final o = _off(t, s);
      expect(img[o], isNot(0));
      t = img[o];
      s = img[o + 1];
    }
    expect(img[_off(t, s)], 0);
    expect(img[_off(t, s) + 1], 700 - 2 * 254 + 1);
  });

  test('rejects >8 files and empty file lists', () {
    expect(
        () => buildD64(diskName: 'D', files: []), throwsArgumentError);
    expect(
        () => buildD64(
            diskName: 'D',
            files: [
              for (var i = 0; i < 9; i++)
                (name: 'F$i', data: Uint8List(1))
            ]),
        throwsArgumentError);
  });
}
