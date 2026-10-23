import 'package:rainbow_assets/rainbow_assets.dart';
import 'package:test/test.dart';

void main() {
  group('TapWriter', () {
    test('writes a single code block with valid checksum', () {
      final tap = TapWriter();
      tap.addCode(name: 'game', org: 0x8000, data: [0x21, 0x00, 0x80, 0xC9]);
      final bytes = tap.bytes;

      // Two blocks: 19-byte header + 6-byte data.
      var off = 0;
      int readLen() => bytes[off] | (bytes[off + 1] << 8);

      expect(readLen(), 19); // flag + 17-byte header + checksum
      final headerFlag = bytes[off + 2];
      expect(headerFlag, 0x00);
      expect(bytes[off + 3], 3); // type CODE
      expect(String.fromCharCodes(bytes.sublist(off + 4, off + 14)),
          'GAME      ');
      expect(bytes[off + 14] | (bytes[off + 15] << 8), 4); // data len
      expect(bytes[off + 16] | (bytes[off + 17] << 8), 0x8000); // org
      var cks = 0;
      for (var i = off + 2; i < off + 2 + 18; i++) {
        cks ^= bytes[i];
      }
      expect(bytes[off + 20], cks);
      off += 2 + 19;

      expect(readLen(), 6);
      expect(bytes[off + 2], 0xFF);
      cks = 0;
      for (var i = off + 2; i < off + 2 + 5; i++) {
        cks ^= bytes[i];
      }
      expect(bytes[off + 7], cks);
      off += 2 + 6;
      expect(off, bytes.length);
    });
  });

  group('BasicLine.tokenize', () {
    test('tokenizes keywords to single bytes', () {
      final t = BasicLine.tokenize('PRINT');
      expect(t, [0xF5]);
    });

    test('numbers carry hidden 0x0E floating point block', () {
      final t = BasicLine.tokenize('USR 32768');
      expect(t[0], 0xC0); // USR
      expect(t[1], 0x20);
      expect(String.fromCharCodes(t.sublist(2, 7)), '32768');
      expect(t[7], 0x0E);
      expect(t.sublist(8), [0x00, 0x00, 0x00, 0x80, 0x00]);
    });

    test('full loader line structure', () {
      final t = BasicLine.tokenize(
          'CLEAR 32767: LOAD ""CODE: RANDOMIZE USR 32768');
      expect(t[0], 0xFD); // CLEAR
      expect(t.contains(0xEF), isTrue); // LOAD
      expect(t.contains(0xAF), isTrue); // CODE
      expect(t.contains(0xF9), isTrue); // RANDOMIZE
      expect(t.contains(0xC0), isTrue); // USR
    });

    test('letters inside quotes are not tokenized', () {
      final t = BasicLine.tokenize('PRINT "BORDER"');
      expect(t[0], 0xF5);
      // "BORDER" should be plain ASCII inside quotes, not token 0xE7.
      expect(t.contains(0xE7), isFalse);
    });
  });

  group('buildGameLoader', () {
    test('produces a complete program line', () {
      final prog = buildGameLoader(clearAddr: 32767, entry: 32768);
      // line: 10 <len> tokens 0x0E
      expect(prog[0], 0x00);
      expect(prog[1], 0x0A);
      final len = prog[2] | (prog[3] << 8);
      expect(prog.length, 4 + len + 1);
      expect(prog.last, 0x0E);
    });
  });
}
