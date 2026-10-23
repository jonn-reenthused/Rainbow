import 'dart:typed_data';

/// Writes ZX Spectrum .tap images.
///
/// A TAP file is a sequence of blocks, each prefixed with a 2-byte
/// little-endian length. Every block starts with a flag byte
/// (0x00 header, 0xFF data) and ends with an XOR checksum over
/// flag + payload.
class TapWriter {
  final BytesBuilder _out = BytesBuilder(copy: false);

  /// Full tap image bytes.
  Uint8List get bytes => _out.toBytes();

  /// Append a raw block (flag + payload + checksum).
  void addBlock(int flag, List<int> payload) {
    final block = Uint8List(1 + payload.length + 1);
    block[0] = flag & 0xFF;
    block.setRange(1, 1 + payload.length, payload);
    var cksum = flag & 0xFF;
    for (final b in payload) {
      cksum ^= b & 0xFF;
    }
    block[block.length - 1] = cksum;
    _writeChunk(block);
  }

  /// Append a header block (flag + 17-byte payload + checksum).
  ///
  /// [type] 0 = PROGRAM (BASIC), 1 = number array, 2 = char array,
  /// 3 = CODE. [param1] is the autostart line for PROGRAM or the
  /// start address for CODE; [param2] is the program length for
  /// PROGRAM or 0x8000 (unused) for CODE.
  void addHeader({
    required String name,
    required int type,
    required int dataLength,
    int param1 = 0,
    int param2 = 0x8000,
  }) {
    final payload = Uint8List(17);
    payload[0] = type & 0xFF;
    final nameBytes = name.toUpperCase().codeUnits;
    for (var i = 0; i < 10; i++) {
      payload[1 + i] = i < nameBytes.length ? nameBytes[i] & 0xFF : 0x20;
    }
    _u16(payload, 11, dataLength);
    _u16(payload, 13, param1);
    _u16(payload, 15, param2);
    addBlock(0x00, payload);
  }

  /// Append a data block (flag 0xFF).
  void addData(List<int> data) => addBlock(0xFF, data);

  /// Append a complete PROGRAM (BASIC) entry: header + data.
  ///
  /// [program] is the tokenized BASIC program (lines only, no
  /// variables area). [autoStartLine] makes the program run
  /// automatically when loaded.
  void addProgram({
    required String name,
    required List<int> program,
    int autoStartLine = 0,
  }) {
    addHeader(
      name: name,
      type: 0,
      dataLength: program.length,
      param1: autoStartLine,
      param2: program.length,
    );
    addData(program);
  }

  /// Append a complete CODE entry: header + data.
  void addCode({
    required String name,
    required int org,
    required List<int> data,
  }) {
    addHeader(
      name: name,
      type: 3,
      dataLength: data.length,
      param1: org,
      param2: 0x8000,
    );
    addData(data);
  }

  void _writeChunk(Uint8List chunk) {
    _out.addByte(chunk.length & 0xFF);
    _out.addByte((chunk.length >> 8) & 0xFF);
    _out.add(chunk);
  }

  static void _u16(Uint8List buf, int off, int v) {
    buf[off] = v & 0xFF;
    buf[off + 1] = (v >> 8) & 0xFF;
  }
}
