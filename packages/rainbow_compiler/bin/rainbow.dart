import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:rainbow_assets/rainbow_assets.dart';
import 'package:rainbow_compiler/rainbow_compiler.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    _usage();
    exit(64);
  }
  switch (args[0]) {
    case 'build':
      await _build(args.sublist(1));
    case 'init':
      _init(args.sublist(1));
    case 'import-mod':
      _import(args.sublist(1), modToRay, 'mod');
    case 'import-mus':
      _import(args.sublist(1), musToRay, 'mus');
    default:
      _usage();
      exit(64);
  }
}

void _usage() {
  stderr.writeln(
      '''rainbow - ZX Spectrum game compiler (Rainbow BASIC -> Pasmo -> .tap)

usage:
  rainbow init <dir> [--target zx48|zx128]   scaffold a new project
  rainbow build <projectdir> [options]    compile project to .tap
  rainbow import-mod <in.mod> <out.ray>   convert a ProTracker module
  rainbow import-mus <in.mus> <out.ray>   convert a Sidplayer song

options:
  --target <key|zx48|zx128>   build only this target (multi-target
                    projects) or override a single-target project's target
  --asm-only        emit .asm only, don't run pasmo
  --out <dir>       build output directory (default <project>/build)
  --pasmo <path>    pasmo executable (default: pasmo)
''');
}

void _init(List<String> args) {
  final positional = args.where((a) => !a.startsWith('--')).toList();
  if (positional.isEmpty) {
    stderr.writeln('rainbow init <dir>');
    exit(64);
  }
  final target = _opt(args, '--target') ?? 'zx48';
  final tid = resolveTargetId(target);
  if (tid == null) {
    stderr.writeln('unknown target "$target" (want zx48 or zx128)');
    exit(64);
  }
  final dir = Directory(positional[0]);
  dir.createSync(recursive: true);
  Directory('${dir.path}/src').createSync(recursive: true);
  Directory('${dir.path}/assets').createSync(recursive: true);
  File('${dir.path}/project.rbw.json')
      .writeAsStringSync(const JsonEncoder.withIndent('  ').convert({
    'name': dir.uri.pathSegments.reversed
        .firstWhere((e) => e.isNotEmpty, orElse: () => 'game'),
    'target': kTargetNames[tid],
    'org': 0x8000,
    'sources': ['src/main.rbw'],
    'emulator': null,
  }));
  File('${dir.path}/src/main.rbw').writeAsStringSync('''PROGRAM "${'GAME'}"

MAIN:
  BORDER 1
  PAPER 1
  INK 7
  BRIGHT 1
  CLS
  PRINT AT 10,6;"HELLO SPECTRUM"
loop:
  HALT
  GOTO loop
''');
  print('created project in ${dir.path}');
}

void _import(
    List<String> args, ModImportResult Function(Uint8List) conv, String ext) {
  final positional = args.where((a) => !a.startsWith('--')).toList();
  if (positional.length < 2) {
    stderr.writeln('rainbow import-$ext <in.$ext> <out.ray>');
    exit(64);
  }
  try {
    final r = conv(File(positional[0]).readAsBytesSync());
    File(positional[1])
        .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(r.json));
    for (final line in r.report) {
      stdout.writeln('import-$ext: $line');
    }
  } catch (e) {
    stderr.writeln('import-$ext: $e');
    exit(65);
  }
}

String? _opt(List<String> args, String name) {
  final i = args.indexOf(name);
  if (i >= 0 && i + 1 < args.length) return args[i + 1];
  return null;
}

Future<void> _build(List<String> args) async {
  final positional = args.where((a) => !a.startsWith('--')).toList();
  if (positional.isEmpty) {
    stderr.writeln('rainbow build <projectdir>');
    exit(64);
  }
  final tsel = _opt(args, '--target');
  final r = await buildProject(
    positional[0],
    target: tsel == null ? null : resolveTargetId(tsel),
    targetName: tsel,
    assemble: !args.contains('--asm-only'),
    pasmo: _opt(args, '--pasmo') ?? 'pasmo',
    outDirName: _opt(args, '--out'),
  );
  for (final line in r.log) {
    (r.ok ? stdout : stderr).writeln(line);
  }
  if (!r.ok) exit(65);
}
