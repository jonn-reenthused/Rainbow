import 'dart:io';
import 'package:rainbow_compiler/rainbow_compiler.dart';

final cases = <String,String>{
 'undef-var':       'PROGRAM "T"\nMAIN:\nx = y + 1\nEND\n',
 'bad-type-assign': 'PROGRAM "T"\nDIM s AS UINT\nMAIN:\ns = "hi"\nEND\n',
 'dim-zero':        'PROGRAM "T"\nDIM a(0) AS UINT\nMAIN:\nEND\n',
 'dim-expr':        'PROGRAM "T"\nDIM a(x) AS UINT\nMAIN:\nEND\n',
 'bad-index-arity': 'PROGRAM "T"\nDIM a(5) AS UINT\nMAIN:\nx = a(1)(2)\nEND\n',
 'index-scalar':    'PROGRAM "T"\nDIM x AS UINT\nMAIN:\ny = x(1)\nEND\n',
 'struct-field':   'PROGRAM "T"\nTYPE T\na AS UINT\nEND TYPE\nDIM s AS T\nMAIN:\ns.b = 1\nEND\n',
 'struct-rvalue':  'PROGRAM "T"\nTYPE T\na AS UINT\nEND TYPE\nDIM s AS T\nMAIN:\nx = s\nEND\n',
 'string-in-type': 'PROGRAM "T"\nTYPE T\na AS STRING\nEND TYPE\nMAIN:\nEND\n',
 'unknown-call':   'PROGRAM "T"\nMAIN:\nCALL foo\nEND\n',
 'goto-missing':   'PROGRAM "T"\nMAIN:\nGOTO nowhere\nEND\n',
 'missing-endif':  'PROGRAM "T"\nMAIN:\nIF 1 THEN\nx = 1\nEND\n',
 'dup-label':      'PROGRAM "T"\nMAIN:\nx = 1\nMAIN:\nEND\n',
 'bad-keyword':    'PROGRAM "T"\nMAIN:\nPRINTT 1\nEND\n',
 'if-missing-then':'PROGRAM "T"\nMAIN:\nIF x = 1\ny = 2\nENDIF\nEND\n',
 'for-missing-to': 'PROGRAM "T"\nMAIN:\nFOR i = 1\nNEXT i\nEND\n',
 'wrong-arg-count':'PROGRAM "T"\nMAIN:\nx = SPRITEX(1,2)\nEND\n',
 'string-expr':    'PROGRAM "T"\nMAIN:\nx = "a" + 1\nEND\n',
 'div-zero':       'PROGRAM "T"\nMAIN:\nx = 1 / 0\nEND\n',
 'undef-in-print': 'PROGRAM "T"\nMAIN:\nPRINT z\nEND\n',
};
void main() async {
  for (final e in cases.entries) {
    final r = compile({'main.rbw': e.value});
    final errs = r.diag.items.map((d)=>'${d.line}:${d.col} ${d.message}').toList();
    print('--- ${e.key}');
    if (errs.isEmpty) print('   (no diagnostics!)');
    for (final m in errs) print('   $m');
  }
}
