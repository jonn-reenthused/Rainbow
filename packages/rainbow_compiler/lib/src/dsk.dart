import 'dart:typed_data';

/// Standard (non-extended) CPC .dsk writer — Amstrad "data" format:
/// 40 tracks x 9 sectors x 512 bytes, single sided, sector IDs #C1-#C9.
/// (System format uses #41-#49 but reserves tracks 0-1 and puts the
/// directory on track 2; data format has the directory at track 0.)
///
/// AMSDOS allocates file space in 1KB blocks (two consecutive logical
/// sectors, numbered disc-wide). Blocks 0-1 hold the 2KB directory on
/// track 0; file data starts at block 2.
///
/// Every file is written as a full AMSDOS record: a 128-byte header
/// ([buildAmsdosHeader]) followed by the payload, so LOAD/RUN and the
/// firmware CAS IN calls all see a proper binary file.

/// One file to place on the image.
typedef DskFile = ({String name, List<int> bytes});

/// Splits "GAME.BIN" into the 8.3 directory fields (uppercase,
/// space-padded).
(String, String) _name83(String name) {
  final dot = name.lastIndexOf('.');
  var base = dot < 0 ? name : name.substring(0, dot);
  var ext = dot < 0 ? '' : name.substring(dot + 1);
  if (base.length > 8) base = base.substring(0, 8);
  if (ext.length > 3) ext = ext.substring(0, 3);
  return (base.toUpperCase().padRight(8), ext.toUpperCase().padRight(3));
}

/// Builds the 128-byte AMSDOS header record for a binary file.
/// [dataLen] is the payload length (the header itself is not counted).
Uint8List buildAmsdosHeader(String name,
    {required int loadAddr, required int execAddr, required int dataLen}) {
  final h = Uint8List(128);
  final (base, ext) = _name83(name);
  for (var i = 0; i < 8; i++) {
    h[1 + i] = base.codeUnitAt(i);
  }
  for (var i = 0; i < 3; i++) {
    h[9 + i] = ext.codeUnitAt(i);
  }
  h[18] = 2; // unprotected binary
  h[19] = dataLen & 0xFF; // data length
  h[20] = (dataLen >> 8) & 0xFF;
  h[21] = loadAddr & 0xFF; // load address
  h[22] = (loadAddr >> 8) & 0xFF;
  h[23] = 0xFF; // first block
  h[24] = dataLen & 0xFF; // logical length
  h[25] = (dataLen >> 8) & 0xFF;
  h[26] = execAddr & 0xFF; // entry address
  h[27] = (execAddr >> 8) & 0xFF;
  h[64] = dataLen & 0xFF; // real length (24-bit)
  h[65] = (dataLen >> 8) & 0xFF;
  h[66] = (dataLen >> 16) & 0xFF;
  var sum = 0;
  for (var i = 0; i < 67; i++) {
    sum += h[i];
  }
  h[67] = sum & 0xFF; // checksum = sum of bytes 0..66
  h[68] = (sum >> 8) & 0xFF;
  return h;
}

/// Packs [files] into a .dsk image and returns the image bytes.
///
/// [name] in each entry is the on-disc filename (8.3; truncated if
/// longer). Each entry's [bytes] should already include the AMSDOS
/// header — use [addBinary] for a convenience wrapper.
Uint8List buildDsk(List<DskFile> files) {
  const tracks = 40;
  const sectsPerTrack = 9;
  const sectSize = 512;
  // AMSDOS requests sequential sector IDs (&C1, &C2, ...) for logical
  // sectors; the IDs sit around the track in this interleaved order for
  // rotational latency. So physical slot s carries ID sectorOrder[s] and
  // must hold the data for logical sector (sectorOrder[s] - #C1).
  const sectorOrder = [
    0xC1, 0xC6, 0xC2, 0xC7, 0xC3, 0xC8, 0xC4, 0xC9, 0xC5
  ];

  final logical = Uint8List(tracks * sectsPerTrack * sectSize);
  logical.fillRange(0, logical.length, 0xE5); // unwritten sectors read E5s

  int logicalSector(int block, int half) => block * 2 + half;

  final dir = Uint8List(2048)..fillRange(0, 2048, 0xE5);
  var dirPos = 0;
  var nextBlock = 2; // blocks 0-1 = directory

  for (final f in files) {
    final data = f.bytes;
    // write the file's bytes into consecutive 1K blocks
    final startBlock = nextBlock;
    final nblocks = (data.length + 1023) ~/ 1024;
    for (var b = 0; b < nblocks; b++) {
      for (var half = 0; half < 2; half++) {
        final s = logicalSector(startBlock + b, half);
        final srcOff = b * 1024 + half * 512;
        if (srcOff < data.length) {
          final n =
              (data.length - srcOff) < 512 ? data.length - srcOff : 512;
          logical.setRange(s * 512, s * 512 + n, data, srcOff);
        }
      }
    }
    nextBlock += nblocks;
    if (nextBlock > 180) {
      throw StateError('dsk full: ${f.name} does not fit');
    }

    dirPos = _writeDirEntry(dir, dirPos, f.name, data.length,
        startBlock);
  }

  // directory = first 2K of logical sector space
  logical.setRange(0, dir.length, dir);

  return _packExtended(logical,
      tracks: tracks,
      sectsPerTrack: sectsPerTrack,
      sectSize: sectSize,
      sectorIds: sectorOrder,
      logicalIndex: (id) => id - 0xC1);
}

/// Writes CP/M directory extents for a file occupying 1K blocks from
/// [startBlock]; returns the updated [dirPos]. Layout is shared by
/// AMSDOS and +3DOS (32-byte CP/M entries: 8.3 name, per-byte 1K block
/// numbers, extents capped at 16K).
int _writeDirEntry(Uint8List dir, int dirPos, String name, int dataLen,
    int startBlock) {
  final (base, ext) = _name83(name);
  var offset = 0;
  var extent = 0;
  var blockIdx = startBlock;
  while (offset < dataLen || extent == 0) {
    if (dirPos + 32 > dir.length) {
      throw StateError('dsk directory full (>64 entries)');
    }
    final e = dirPos;
    dirPos += 32;
    dir.fillRange(e, e + 32, 0); // a used entry zeroes unused fields
    dir[e] = 0; // user
    for (var i = 0; i < 8; i++) {
      dir[e + 1 + i] = base.codeUnitAt(i);
    }
    for (var i = 0; i < 3; i++) {
      dir[e + 9 + i] = ext.codeUnitAt(i);
    }
    dir[e + 12] = extent & 0xFF; // extent low
    final chunk =
        (dataLen - offset) < 16384 ? dataLen - offset : 16384;
    dir[e + 13] = chunk % 128; // Bc: bytes used in last record
    dir[e + 15] = (chunk + 127) ~/ 128; // Rc: records in this extent
    final inThisExtent = (chunk + 1023) ~/ 1024;
    for (var i = 0; i < inThisExtent; i++) {
      dir[e + 16 + i] = blockIdx++;
    }
    offset += chunk;
    extent++;
  }
  return dirPos;
}

// ---------------------------------------------------------------------------
// Spectrum +3 (+3DOS / CP/M Plus "data" format)
// ---------------------------------------------------------------------------
//
// Same physical shape (40 tracks x 9 sectors x 512 bytes, one side) but
// a different filesystem: track 0 is the reserved system track (left as
// E5 filler — the default XDPB logs the disk on), the 2K directory sits
// in the first two 1K blocks of the data area on track 1, and sectors
// are numbered 1-9 sequentially (no skew). Files carry a 128-byte
// PLUS3DOS header ([buildPlus3Header]).

/// Builds the 128-byte PLUS3DOS header record prepended to every file.
/// [type] is the Spectrum file type (0 = BASIC, 3 = CODE); [param1] is
/// the BASIC auto-run line or CODE load address, [param2] the program
/// length for BASIC, 0x8000 for CODE (what a real +3 writes).
Uint8List buildPlus3Header(String name,
    {required int type,
    required int dataLen,
    required int param1,
    required int param2}) {
  final h = Uint8List(128);
  const sig = 'PLUS3DOS';
  for (var i = 0; i < 8; i++) {
    h[i] = sig.codeUnitAt(i);
  }
  h[8] = 0x1A; // soft-EOF
  h[9] = 1; // issue
  h[10] = 0; // version — must be 0, +3DOS rejects anything higher
  final total = dataLen + 128;
  for (var i = 0; i < 4; i++) {
    h[11 + i] = (total >> (8 * i)) & 0xFF;
  }
  h[15] = type;
  h[16] = dataLen & 0xFF;
  h[17] = (dataLen >> 8) & 0xFF;
  h[18] = param1 & 0xFF;
  h[19] = (param1 >> 8) & 0xFF;
  h[20] = param2 & 0xFF;
  h[21] = (param2 >> 8) & 0xFF;
  var sum = 0;
  for (var i = 0; i < 127; i++) {
    sum += h[i];
  }
  h[127] = sum & 0xFF;
  return h;
}

/// Packs [files] into a +3DOS .dsk image. Each entry's [bytes] should
/// already include the PLUS3DOS header.
Uint8List buildPlus3Dsk(List<DskFile> files) {
  const tracks = 40;
  const sectsPerTrack = 9;
  const sectSize = 512;

  final logical = Uint8List(tracks * sectsPerTrack * sectSize);
  logical.fillRange(0, logical.length, 0xE5);

  // Block numbers count 1K allocation units within the data area,
  // which starts at track 1 (track 0 is reserved). Directory = blocks
  // 0-1, file data from block 2.
  const dataSectors = (tracks - 1) * sectsPerTrack;
  int linearOf(int block, int half) => block * 2 + half;
  void put(int block, int half, List<int> src, int srcOff) {
    final s = linearOf(block, half);
    if (s >= dataSectors) {
      throw StateError('dsk full');
    }
    final dst = (sectsPerTrack + s) * sectSize; // track 1 onwards
    final n = (src.length - srcOff) < 512 ? src.length - srcOff : 512;
    if (n > 0) logical.setRange(dst, dst + n, src, srcOff);
  }

  final dir = Uint8List(2048)..fillRange(0, 2048, 0xE5);
  var dirPos = 0;
  var nextBlock = 2;
  for (final f in files) {
    final data = f.bytes;
    final startBlock = nextBlock;
    final nblocks = (data.length + 1023) ~/ 1024;
    for (var b = 0; b < nblocks; b++) {
      put(startBlock + b, 0, data, b * 1024);
      put(startBlock + b, 1, data, b * 1024 + 512);
    }
    nextBlock += nblocks;
    dirPos =
        _writeDirEntry(dir, dirPos, f.name, data.length, startBlock);
  }
  put(0, 0, dir, 0);
  put(0, 1, dir, 512);
  put(1, 0, dir, 1024);
  put(1, 1, dir, 1536);

  return _packExtended(logical,
      tracks: tracks,
      sectsPerTrack: sectsPerTrack,
      sectSize: sectSize,
      sectorIds: const [1, 2, 3, 4, 5, 6, 7, 8, 9],
      logicalIndex: (id) => id - 1);
}

/// Wraps flat logical sector data in an EXTENDED CPC DSK container:
/// disk-info block, per-track headers, then sectors in slot order.
/// [sectorIds] gives the physical sector ID per slot; [logicalIndex]
/// maps an ID back to its 0-based index within [logical].
Uint8List _packExtended(Uint8List logical,
    {required int tracks,
    required int sectsPerTrack,
    required int sectSize,
    required List<int> sectorIds,
    required int Function(int id) logicalIndex}) {
  final trackSize = 256 + sectsPerTrack * sectSize;
  final img = Uint8List(256 + tracks * trackSize);
  const sig = 'EXTENDED CPC DSK File\r\nDisk-Info\r\n';
  for (var i = 0; i < sig.length; i++) {
    img[i] = sig.codeUnitAt(i);
  }
  const creator = 'RAINBOW';
  for (var i = 0; i < creator.length; i++) {
    img[0x22 + i] = creator.codeUnitAt(i);
  }
  img[0x30] = tracks;
  img[0x31] = 1; // sides
  // 0x32-0x33 unused in extended format; per-track sizes in bytes/256:
  for (var t = 0; t < tracks; t++) {
    img[0x34 + t] = trackSize ~/ 256;
  }

  for (var t = 0; t < tracks; t++) {
    final th = 256 + t * trackSize; // track header offset
    const tsig = 'Track-Info\r\n';
    for (var i = 0; i < tsig.length; i++) {
      img[th + i] = tsig.codeUnitAt(i);
    }
    img[th + 0x10] = t; // track number
    img[th + 0x11] = 0; // side
    img[th + 0x14] = 2; // sector size code (512)
    img[th + 0x15] = sectsPerTrack;
    img[th + 0x16] = 0x4E; // GAP#3
    img[th + 0x17] = 0xE5; // filler
    for (var s = 0; s < sectsPerTrack; s++) {
      final si = th + 0x18 + s * 8;
      img[si] = t;
      img[si + 1] = 0;
      img[si + 2] = sectorIds[s];
      img[si + 3] = 2;
      img[si + 6] = 0x00; // ext-sector length lo (0x0200)
      img[si + 7] = 2; // ext-sector length hi, as WinAPE writes it
      // FDC status bytes 0; slot s holds logical sector
      // logicalIndex(sectorIds[s]).
      final src =
          (t * sectsPerTrack + logicalIndex(sectorIds[s])) * sectSize;
      img.setRange(
          th + 256 + s * sectSize, th + 256 + (s + 1) * sectSize,
          logical, src);
    }
  }
  return img;
}
