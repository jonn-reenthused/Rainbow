import 'dart:io';

import 'package:rainbow_compiler/rainbow_compiler.dart';
import 'package:rainbow_compiler/src/ast.dart';
import 'package:rainbow_compiler/src/codegen.dart';
import 'package:rainbow_compiler/src/parser.dart';
import 'package:rainbow_compiler/src/sema.dart';
import 'package:test/test.dart';

/// Golden codegen tests: each `test/golden/<name>.rbw` fixture is
/// compiled and the *generated* asm section compared to
/// `test/golden/<name>.asm`. Only the CodeGen output is golden —
/// the runtime modules and prologue vary with runtime edits.
///
/// Regenerate fixtures after an intentional codegen change:
///   UPDATE_GOLDENS=1 dart test test/golden_test.dart
void main() {
  final dir = Directory('test/golden');
  final fixtures = dir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.rbw'))
      .map((f) => f.path)
      .toList()
    ..sort();

  final update = Platform.environment['UPDATE_GOLDENS'] == '1';

  group('golden codegen', () {
    for (final path in fixtures) {
      final name = path.split('/').last;
      test(name, () {
        final src = File(path).readAsStringSync();
        final diag = DiagnosticBag();
        final toks = Lexer(src, name, diag).tokenize();
        final units = [Parser(toks, name, diag).parseUnit()];
        expect(diag.hasErrors, isFalse,
            reason: 'parse failed for $name: ${diag.items}');
        final info = Sema(diag).analyze(units);
        expect(diag.hasErrors, isFalse,
            reason: 'sema failed for $name: ${diag.items}');
        final asm = CodeGen(info, diag, assets: const {}).generate(units);
        final asmFile = File(path.replaceAll('.rbw', '.asm'));
        if (update) {
          asmFile.writeAsStringSync(asm);
        } else {
          expect(asm.trim(), asmFile.readAsStringSync().trim(),
              reason:
                  'golden drift for $name — run UPDATE_GOLDENS=1 dart test '
                  'test/golden_test.dart if intentional');
        }
      });
    }
  });
}
