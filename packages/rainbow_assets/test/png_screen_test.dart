import 'package:image/image.dart' as img;
import 'package:rainbow_assets/rainbow_assets.dart';
import 'package:test/test.dart';

void main() {
  group('imageToScreen', () {
    test('solid Spectrum colour fills produce matching attrs', () {
      // 256x192 cyan image -> every block paper=cyan(5), ink=cyan (no second
      // colour), bitmap all zeros.
      final src = img.Image(width: 256, height: 192)
        ..clear(img.ColorRgba8(0, 215, 215, 255));
      final out = imageToScreenImage(src);
      expect(out.length, 6912);
      expect(out.sublist(0, 6144).every((b) => b == 0), isTrue);
      // paper=5 -> 5<<3 = 0x28; ink=5 -> attr 0x2d? ink=paper=5 -> 5|40=0x2D
      expect(out.sublist(6144).every((a) => a == (5 | (5 << 3))), isTrue);
    });

    test('two-colour block quantises to ink/paper bits', () {
      // mostly white with black in the right quarter of each block ->
      // paper=white, ink=black, right 2 bits of each row set.
      final src = img.Image(width: 256, height: 192)
        ..clear(img.ColorRgba8(255, 255, 255, 255));
      for (var y = 0; y < 192; y++) {
        for (var x = 0; x < 256; x++) {
          if (x % 8 >= 6) src.setPixelRgba(x, y, 0, 0, 0, 255);
        }
      }
      final out = imageToScreenImage(src);
      expect(out[6144] & 0x3F, 0x38); // ink 0, paper 7 (bright allowed)
      expect(out[0] & 0x03, 0x03); // right 2 px are ink
      expect(out[0] & 0xFC, 0x00); // left 6 px are paper
    });

    test('PngFitMode.letterbox fits a wide image with black bars', () {
      final src = img.Image(width: 512, height: 128)
        ..clear(img.ColorRgba8(215, 215, 215, 255)); // white-ish
      final out = imageToScreenImage(src);
      // top rows are the black letterbox bar -> attr paper black
      expect(out[6144] & 0x38, 0);
      // centre row is the image -> attr paper white (7<<3)
      expect(out[6144 + 12 * 32] & 0x38, 7 << 3);
    });
  });
}
