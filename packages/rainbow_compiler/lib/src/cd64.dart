import 'dart:typed_data';

/// Commodore .d64 disk image writer — the standard 35-track layout the
/// 1541 DOS "2A" format uses: 683 sectors of 256 bytes (174,848 bytes).
///
/// Sector counts per track band: T1-17: 21, T18-24: 19, T25-30: 18,
/// T31-35: 17. Track 18 is the DOS track: sector 0 = BAM + disk name,
/// sector 1+ = directory (8 x 32-byte entries per sector). File data is
/// stored as a forward-linked sector chain starting at T1 S0, skipping
/// track 18; each sector's first two bytes link to the next sector —
/// on the last sector T=0 and S = bytes used + 1 (counting the link
/// pair itself, so payload capacity is 254 bytes per sector).
///
/// The .prg payload keeps its 2-byte load address — that's what
/// LOAD"name",8,1 and the kernal autostart expect.

/// One file to place on the image. [name] is the directory name
/// (uppercased, $A0-padded to 16 chars); [data] is the raw file bytes.
typedef D64File = ({String name, Uint8List data});

const _sectorsPerTrack = [
  21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21, 21,
  19, 19, 19, 19, 19, 19, 19,
  18, 18, 18, 18, 18, 18,
  17, 17, 17, 17, 17
];

int _trackOffset(int track) {
  var off = 0;
  for (var t = 1; t < track; t++) {
    off += _sectorsPerTrack[t - 1] * 256;
  }
  return off;
}

/// Builds a .d64 image. [diskName] becomes the 16-char disk label;
/// files land in the directory in order.
Uint8List buildD64({required String diskName, required List<D64File> files}) {
  if (files.isEmpty) {
    throw ArgumentError('a .d64 needs at least one file');
  }
  if (files.length > 8) {
    throw ArgumentError('d64 writer supports up to 8 files (one dir sector)');
  }
  final img = Uint8List(174848);

  // Track/sector -> byte offset. Track 18 is reserved for DOS use.
  int off(int t, int s) => _trackOffset(t) + s * 256;

  // Allocate file data chains starting at T1 S0, skipping track 18.
  // Returns the sector list each file occupies.
  final used = <({int t, int s})>[];
  var nt = 1, ns = 0;
  ({int t, int s}) next() {
    while (true) {
      if (ns >= _sectorsPerTrack[nt - 1]) {
        ns = 0;
        nt++;
      }
      if (nt == 18) nt++;
      if (nt > 35) {
        throw ArgumentError('files do not fit on a .d64');
      }
      final r = (t: nt, s: ns);
      ns++;
      return r;
    }
  }

  final chains = <List<({int t, int s})>>[];
  for (final f in files) {
    final nSectors = (f.data.length + 253) ~/ 254;
    final chain = <({int t, int s})>[];
    for (var i = 0; i < nSectors; i++) {
      final s = next();
      chain.add(s);
      used.add(s);
    }
    chains.add(chain);
  }

  // Write the sector chains: [t,s] link then payload; last sector
  // links T=0, S = bytes used + 1.
  for (var fi = 0; fi < files.length; fi++) {
    final chain = chains[fi];
    final data = files[fi].data;
    for (var i = 0; i < chain.length; i++) {
      final o = off(chain[i].t, chain[i].s);
      final start = i * 254;
      final n = (data.length - start).clamp(0, 254);
      if (i + 1 < chain.length) {
        img[o] = chain[i + 1].t;
        img[o + 1] = chain[i + 1].s;
      } else {
        img[o] = 0;
        img[o + 1] = n + 1;
      }
      img.setRange(o + 2, o + 2 + n, data, start);
    }
  }

  // Directory sector T18 S1. Byte 0-1: next dir sector link (0/255 =
  // last); entries at 2 + 32*i.
  final d = off(18, 1);
  img[d] = 0;
  img[d + 1] = 0xFF;
  List<int> dirName(String s) {
    final b = List<int>.filled(16, 0xA0);
    final u = s.toUpperCase();
    for (var i = 0; i < u.length && i < 16; i++) {
      b[i] = u.codeUnitAt(i);
    }
    return b;
  }

  for (var i = 0; i < files.length; i++) {
    final e = d + 2 + i * 32;
    img[e] = 0x82; // PRG, closed
    img[e + 1] = chains[i].first.t;
    img[e + 2] = chains[i].first.s;
    img.setRange(e + 3, e + 19, dirName(files[i].name));
    img[e + 30] = chains[i].length & 0xFF;
    img[e + 31] = chains[i].length >> 8;
  }

  // BAM at T18 S0: dir link, DOS version 'A', per-track free counts +
  // sector bitmaps (bit set = free), disk name + DOS type.
  final b = off(18, 0);
  img[b] = 18;
  img[b + 1] = 1;
  img[b + 2] = 0x41; // 'A'
  final usedSet = {for (final s in used) (s.t, s.s)};
  usedSet.add((18, 0));
  usedSet.add((18, 1));
  for (var t = 1; t <= 35; t++) {
    var free = 0;
    var m0 = 0, m1 = 0, m2 = 0;
    for (var s = 0; s < _sectorsPerTrack[t - 1]; s++) {
      if (!usedSet.contains((t, s))) {
        free++;
        if (s < 8) {
          m0 |= 1 << s;
        } else if (s < 16) {
          m1 |= 1 << (s - 8);
        } else {
          m2 |= 1 << (s - 16);
        }
      }
    }
    final e = b + 4 + (t - 1) * 4;
    img[e] = free;
    img[e + 1] = m0;
    img[e + 2] = m1;
    img[e + 3] = m2;
  }
  img.setRange(b + 0x90, b + 0xA0, dirName(diskName));
  img[b + 0xA0] = 0xA0;
  img[b + 0xA1] = 0xA0;
  img[b + 0xA2] = 0x31; // disk id '1'
  img[b + 0xA3] = 0x41; // 'A'
  img[b + 0xA4] = 0xA0;
  img[b + 0xA5] = 0x32; // DOS type '2A'
  img[b + 0xA6] = 0x41;
  img.setRange(b + 0xA7, b + 0xAB, [0xA0, 0xA0, 0xA0, 0xA0]);
  return img;
}

/// Builds a .d71 image — the 1571's double-sided 70-track format
/// (349,696 bytes = two 35-track halves). Side 2 holds tracks 36-70 at
/// byte offset 174,848; its "DOS track" is track 53, whose sector 0
/// carries the side-2 BAM bitmaps while the side-1 BAM's $DD-$FF tail
/// carries side-2 free-sector counts. The directory lives on side 1
/// track 18 exactly as .d64 — a single dir sector still caps files
/// at 8. DOS version is 'C' and DOS type '2C'.
Uint8List buildD71({required String diskName, required List<D64File> files}) {
  if (files.isEmpty) {
    throw ArgumentError('a .d71 needs at least one file');
  }
  if (files.length > 8) {
    throw ArgumentError('d71 writer supports up to 8 files (one dir sector)');
  }
  final img = Uint8List(349696);

  // Side-2 DOS track = 53; track 53 S0 holds the side-2 BAM.
  // File chains may use it from sector 1 up.
  int off(int t, int s) => t <= 35
      ? _trackOffset(t) + s * 256
      : 174848 + _trackOffset(t - 35) + s * 256;

  final used = <({int t, int s})>[];
  var nt = 1, ns = 0;
  ({int t, int s}) next() {
    while (true) {
      if (ns >= _sectorsPerTrack[(nt - 1) % 35]) {
        ns = 0;
        nt++;
      }
      if (nt == 18) nt++;
      if (nt == 53 && ns == 0) ns++; // side-2 BAM sector
      if (nt > 70) {
        throw ArgumentError('files do not fit on a .d71');
      }
      final r = (t: nt, s: ns);
      ns++;
      return r;
    }
  }

  final chains = <List<({int t, int s})>>[];
  for (final f in files) {
    final nSectors = (f.data.length + 253) ~/ 254;
    final chain = <({int t, int s})>[];
    for (var i = 0; i < nSectors; i++) {
      final s = next();
      chain.add(s);
      used.add(s);
    }
    chains.add(chain);
  }

  for (var fi = 0; fi < files.length; fi++) {
    final chain = chains[fi];
    final data = files[fi].data;
    for (var i = 0; i < chain.length; i++) {
      final o = off(chain[i].t, chain[i].s);
      final start = i * 254;
      final n = (data.length - start).clamp(0, 254);
      if (i + 1 < chain.length) {
        img[o] = chain[i + 1].t;
        img[o + 1] = chain[i + 1].s;
      } else {
        img[o] = 0;
        img[o + 1] = n + 1;
      }
      img.setRange(o + 2, o + 2 + n, data, start);
    }
  }

  final d = off(18, 1);
  img[d] = 0;
  img[d + 1] = 0xFF;
  List<int> dirName(String s) {
    final b = List<int>.filled(16, 0xA0);
    final u = s.toUpperCase();
    for (var i = 0; i < u.length && i < 16; i++) {
      b[i] = u.codeUnitAt(i);
    }
    return b;
  }

  for (var i = 0; i < files.length; i++) {
    final e = d + 2 + i * 32;
    img[e] = 0x82; // PRG, closed
    img[e + 1] = chains[i].first.t;
    img[e + 2] = chains[i].first.s;
    img.setRange(e + 3, e + 19, dirName(files[i].name));
    img[e + 30] = chains[i].length & 0xFF;
    img[e + 31] = chains[i].length >> 8;
  }

  final usedSet = {for (final s in used) (s.t, s.s)};
  usedSet.add((18, 0));
  usedSet.add((18, 1));
  usedSet.add((53, 0));
  int freeIn(int track) {
    var free = 0;
    for (var s = 0; s < _sectorsPerTrack[(track - 1) % 35]; s++) {
      if (!usedSet.contains((track, s))) free++;
    }
    return free;
  }

  List<int> bitmapFor(int track) {
    var m0 = 0, m1 = 0, m2 = 0;
    for (var s = 0; s < _sectorsPerTrack[(track - 1) % 35]; s++) {
      if (!usedSet.contains((track, s))) {
        if (s < 8) {
          m0 |= 1 << s;
        } else if (s < 16) {
          m1 |= 1 << (s - 8);
        } else {
          m2 |= 1 << (s - 16);
        }
      }
    }
    return [m0, m1, m2];
  }

  // Side-1 BAM at T18 S0: side-1 entries + name; the $DD-$FF tail
  // carries side-2 free counts (tracks 36-70, one byte each).
  final b = off(18, 0);
  img[b] = 18;
  img[b + 1] = 1;
  img[b + 2] = 0x43; // DOS version 'C' (1571)
  for (var t = 1; t <= 35; t++) {
    final e = b + 4 + (t - 1) * 4;
    img[e] = freeIn(t);
    img.setRange(e + 1, e + 4, bitmapFor(t));
    img[b + 0xDC + t] = freeIn(35 + t);
  }
  img.setRange(b + 0x90, b + 0xA0, dirName(diskName));
  img[b + 0xA0] = 0xA0;
  img[b + 0xA1] = 0xA0;
  img[b + 0xA2] = 0x31; // disk id '1'
  img[b + 0xA3] = 0x41; // 'A'
  img[b + 0xA4] = 0xA0;
  img[b + 0xA5] = 0x32; // DOS type '2C'
  img[b + 0xA6] = 0x43;

  // Side-2 BAM at T53 S0: link to the directory, then 4-byte
  // free+bitmap entries for tracks 36-70.
  final b2 = off(53, 0);
  img[b2] = 18;
  img[b2 + 1] = 1;
  img[b2 + 2] = 0x43;
  for (var t = 36; t <= 70; t++) {
    final e = b2 + 4 + (t - 36) * 4;
    img[e] = freeIn(t);
    img.setRange(e + 1, e + 4, bitmapFor(t));
  }
  return img;
}
