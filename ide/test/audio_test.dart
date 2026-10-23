import 'package:flutter_test/flutter_test.dart';
import 'package:rainbow_ide/audio.dart';

void main() {
  group('preview synths', () {
    test('synthRnt renders samples for a song', () {
      final pcm = synthRnt({
        'speed': 4,
        'rows': [
          {'n1': 30, 'n2': 42},
          {'n1': 34, 'n2': 46, 'dr': 1},
        ],
      });
      expect(pcm.length, greaterThan(1000));
      expect(pcm.any((s) => s != 0), isTrue);
    });

    test('synthRsf renders a slide effect', () {
      final pcm = synthRsf({
        'steps': [
          {'per': 60, 'len': 40, 'slide': -1}
        ],
      });
      expect(pcm.length, greaterThan(100));
      expect(pcm.any((s) => s > 0), isTrue);
      expect(pcm.any((s) => s < 0), isTrue);
    });

    test('synthRay renders AY rows', () {
      final pcm = synthRay({
        'rows': [
          {'dur': 4, 'a': [428, 15], 'mixer': 62},
        ],
      });
      expect(pcm.length, greaterThan(1000));
      expect(pcm.any((s) => s != 0), isTrue);
    });

    test('wavFromPcm produces a valid RIFF header', () {
      final w = wavFromPcm(synthRsf({
        'steps': [
          {'per': 10, 'len': 4}
        ],
      }));
      expect(String.fromCharCodes(w.sublist(0, 4)), 'RIFF');
      expect(String.fromCharCodes(w.sublist(8, 12)), 'WAVE');
    });
  });
}
