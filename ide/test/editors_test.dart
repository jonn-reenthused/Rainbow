import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rainbow_ide/app_state.dart';
import 'package:rainbow_ide/ui/font_editor.dart';
import 'package:rainbow_ide/ui/music_editor.dart';
import 'package:rainbow_ide/ui/screen_editor.dart';
import 'package:rainbow_ide/ui/sprite_editor.dart';
import 'package:rainbow_ide/ui/tilemap_editor.dart';
import 'package:rainbow_ide/ui/tileset_editor.dart';

void main() {
  final spriteJson = jsonEncode({
    'w': 16,
    'h': 16,
    'attr': 0x47,
    'frames': [
      List.filled(16, '................'),
      List.filled(16, '................'),
    ],
  });

  final tilesetJson = jsonEncode({
    'tiles': [List.filled(8, '........')],
    'attrs': [0x38],
    'flags': [0],
  });

  Widget host(Widget child) => MaterialApp(
    home: Scaffold(body: SizedBox(width: 900, height: 600, child: child)),
  );

  group('SpriteEditor', () {
    testWidgets('renders frames and emits edited JSON', (tester) async {
      String? out;
      await tester.pumpWidget(
        host(SpriteEditor(
            text: spriteJson,
            onChanged: (t) => out = t,
            projectDir: '/nonexistent',
            relPath: 'assets/sprites/test.rbs')),
      );
      expect(find.text('16×16  frame 1/2'), findsOneWidget);
      expect(find.text('frame 1'), findsOneWidget);

      // paint a pixel at canvas origin — the canvas is a CustomPaint
      // centered in the editor area; find its top-left and tap inside.
      final canvas = find.byWidgetPredicate(
        (w) => w is CustomPaint && w.size == const Size(320, 320),
      );
      expect(canvas, findsOneWidget);
      final tl = tester.getTopLeft(canvas);
      await tester.tapAt(tl + const Offset(10, 10));
      await tester.pump();
      expect(out, isNotNull);
      final m = jsonDecode(out!) as Map<String, dynamic>;
      expect((m['frames'][0][0] as String)[0], '#');
    });

    testWidgets('add/duplicate/delete frames', (tester) async {
      String? out;
      await tester.pumpWidget(
        host(SpriteEditor(
            text: spriteJson,
            onChanged: (t) => out = t,
            projectDir: '/nonexistent',
            relPath: 'assets/sprites/test.rbs')),
      );
      await tester.tap(find.text('add frame'));
      await tester.pump();
      expect(jsonDecode(out!)['frames'].length, 3);
      await tester.tap(find.text('duplicate'));
      await tester.pump();
      expect(jsonDecode(out!)['frames'].length, 4);
      await tester.tap(find.text('delete'));
      await tester.pump();
      expect(jsonDecode(out!)['frames'].length, 3);
    });
  });

  group('TilesetEditor', () {
    testWidgets('paints pixels and edits flags', (tester) async {
      String? out;
      await tester.pumpWidget(
        host(TilesetEditor(text: tilesetJson, onChanged: (t) => out = t)),
      );
      expect(find.text('1 tiles'), findsOneWidget);

      await tester.tap(find.text('add'));
      await tester.pump();
      expect(jsonDecode(out!)['tiles'].length, 2);

      // toggle solid flag — 'add' selects the new tile (index 1)
      await tester.tap(find.text('solid'));
      await tester.pump();
      expect(jsonDecode(out!)['flags'], [0, 1]);
    });
  });

  group('TilemapEditor', () {
    testWidgets('paints map cells and resizes', (tester) async {
      final tmp = Directory.systemTemp.createTempSync('rbmtest');
      File('${tmp.path}/assets/sprites').createSync(recursive: true);
      // no .rbt — picker just shows indices 0
      final mapJson = jsonEncode({'w': 4, 'h': 2, 'map': List.filled(8, 0)});
      String? out;
      await tester.pumpWidget(
        host(
          TilemapEditor(
            text: mapJson,
            projectDir: tmp.path,
            onChanged: (t) => out = t,
          ),
        ),
      );
      expect(find.text('4 × 2 tiles'), findsOneWidget);

      await tester.tap(find.text('w+8'));
      await tester.pump();
      final m = jsonDecode(out!) as Map<String, dynamic>;
      expect(m['w'], 12);
      expect((m['map'] as List).length, 24);
      tmp.deleteSync(recursive: true);
    });
  });

  group('FontEditor', () {
    testWidgets('paints a glyph pixel and emits JSON', (tester) async {
      final fontJson = jsonEncode({'chars': <String, dynamic>{}});
      String? out;
      await tester.pumpWidget(
        host(FontEditor(text: fontJson, onChanged: (t) => out = t)),
      );
      // default selection is 'A' (65)
      expect(find.text("'A'  (65)"), findsOneWidget);

      final canvas = find.byWidgetPredicate(
        (w) => w is CustomPaint && w.size == const Size(160, 160),
      );
      expect(canvas, findsOneWidget);
      final tl = tester.getTopLeft(canvas);
      await tester.tapAt(tl + const Offset(10, 10));
      await tester.pump();
      expect(out, isNotNull);
      final m = jsonDecode(out!) as Map<String, dynamic>;
      expect((m['chars']['65'][0] as String)[0], '#');
    });
  });

  group('ScreenEditor', () {
    testWidgets('paints a bitmap pixel and emits hex JSON', (tester) async {
      final scrJson = jsonEncode({'bitmap': '00' * 6144, 'attrs': '38' * 768});
      String? out;
      await tester.pumpWidget(
        host(ScreenEditor(text: scrJson, onChanged: (t) => out = t)),
      );
      expect(find.text('screen 256×192'), findsOneWidget);

      final canvas = find.byWidgetPredicate(
        (w) => w is CustomPaint && w.size == const Size(512, 384),
      );
      expect(canvas, findsOneWidget);
      final tl = tester.getTopLeft(canvas);
      await tester.tapAt(tl + const Offset(3, 3)); // pixel (1,1) ink
      await tester.pump();
      expect(out, isNotNull);
      final m = jsonDecode(out!) as Map<String, dynamic>;
      // pixel (1,1): byte offset (1%8)<<8 + 0 + 0 = 0x100, bit 0x40
      expect(m['bitmap'].substring(0x100 * 2, 0x100 * 2 + 2), '40');
    });
  });

  group('IdeState.createFile', () {
    Directory makeProject() {
      final tmp = Directory.systemTemp.createTempSync('rbwproj');
      File('${tmp.path}/project.rbw.json').writeAsStringSync(
        jsonEncode({
          'name': 't',
          'sources': ['src/main.rbw'],
        }),
      );
      Directory('${tmp.path}/src').createSync();
      File('${tmp.path}/src/main.rbw')
          .writeAsStringSync('PROGRAM "T"\nMAIN:\n  CLS\ndone:\n  GOTO done\n');
      return tmp;
    }

    test('asset file lands in tree; source file joins manifest', () {
      final tmp = makeProject();
      final s = IdeState();
      s.projectDir = tmp.path;

      // screen asset -> assets/screens/loading.rbc, no manifest change
      expect(
        s.createFile(
          'assets/screens/loading.rbc',
          jsonEncode({'bitmap': '00' * 6144, 'attrs': '38' * 768}),
        ),
        isNull,
      );
      expect(s.assetFiles, contains('assets/screens/loading.rbc'));

      // source file -> file written + appended to manifest sources
      expect(s.createFile('src/extra.rbw', 'PROGRAM "X"\n'), isNull);
      expect(s.sourceFiles, contains('src/extra.rbw'));
      final m = jsonDecode(
        File('${tmp.path}/project.rbw.json').readAsStringSync(),
      );
      expect(m['sources'], ['src/main.rbw', 'src/extra.rbw']);

      // duplicate path refused
      expect(s.createFile('src/extra.rbw', 'x'), isNotNull);
      tmp.deleteSync(recursive: true);
    });

    test('deleteFile removes file, tree entry and manifest source', () {
      final tmp = makeProject();
      final s = IdeState();
      s.projectDir = tmp.path;
      s.createFile('src/extra.rbw', 'PROGRAM "X"\n');
      s.createFile('assets/sprites/x.rbs', '{}');
      expect(s.docs.any((d) => d.relPath == 'src/extra.rbw'), isTrue);

      expect(s.deleteFile('src/extra.rbw'), isNull);
      expect(File('${tmp.path}/src/extra.rbw').existsSync(), isFalse);
      expect(s.sourceFiles, isNot(contains('src/extra.rbw')));
      expect(s.docs.any((d) => d.relPath == 'src/extra.rbw'), isFalse);
      final m = jsonDecode(
        File('${tmp.path}/project.rbw.json').readAsStringSync(),
      );
      expect(m['sources'], ['src/main.rbw']);

      expect(s.deleteFile('assets/sprites/x.rbs'), isNull);
      expect(s.assetFiles, isNot(contains('assets/sprites/x.rbs')));
      expect(s.deleteFile('assets/sprites/x.rbs'), isNotNull);
      tmp.deleteSync(recursive: true);
    });

    test('moveFile relocates an asset into and out of a bank dir', () {
      final tmp = makeProject();
      final s = IdeState();
      s.projectDir = tmp.path;
      s.createFile('assets/sprites/x.rbs', '{}');
      expect(s.assetFiles, contains('assets/sprites/x.rbs'));

      expect(
        s.moveFile('assets/sprites/x.rbs', 'assets/bank3/sprites/x.rbs'),
        isNull,
      );
      expect(
        File('${tmp.path}/assets/bank3/sprites/x.rbs').existsSync(),
        isTrue,
      );
      expect(File('${tmp.path}/assets/sprites/x.rbs').existsSync(), isFalse);
      expect(s.assetFiles, contains('assets/bank3/sprites/x.rbs'));

      // back to resident
      expect(
        s.moveFile('assets/bank3/sprites/x.rbs', 'assets/sprites/x.rbs'),
        isNull,
      );
      expect(File('${tmp.path}/assets/sprites/x.rbs').existsSync(), isTrue);

      // onto an existing path is refused
      s.createFile('assets/bank1/sprites/y.rbs', '{}');
      expect(
        s.moveFile('assets/sprites/x.rbs', 'assets/bank1/sprites/y.rbs'),
        isNotNull,
      );
      tmp.deleteSync(recursive: true);
    });
  });

  group('music note entry', () {
    test('ant note names parse to indices', () {
      expect(parseAntNote('---'), 0);
      expect(parseAntNote('off'), 0);
      expect(parseAntNote('0'), 0);
      expect(parseAntNote('C-0'), 2);
      expect(parseAntNote('C-4'), 50);
      expect(parseAntNote('c#4'), 51);
      expect(parseAntNote('B-7'), 97);
      expect(parseAntNote('C-8'), isNull); // out of range
      expect(parseAntNote('xyz'), isNull);
    });

    test('ay period entry accepts names and raw numbers', () {
      expect(ayPeriodForName('---'), 0);
      expect(ayPeriodForName('A-4'), isNotNull);
      // AY period for A-4 (440Hz): 1773400/(16*440) ~= 252
      expect(ayPeriodForName('A-4')!, inInclusiveRange(250, 254));
      expect(ayPeriodForName('C-3'), greaterThan(ayPeriodForName('C-4')!));
      expect(ayPeriodForName('xyz'), isNull);
    });
  });
}
