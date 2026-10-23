/// A compiler diagnostic (error or warning) with source location.
class Diagnostic {
  Diagnostic(this.file, this.line, this.col, this.message,
      {this.isWarning = false});

  final String file;
  final int line;
  final int col;
  final String message;
  final bool isWarning;

  @override
  String toString() =>
      '$file:$line:$col: ${isWarning ? 'warning' : 'error'}: $message';
}

class DiagnosticBag {
  final List<Diagnostic> _items = [];

  List<Diagnostic> get items => List.unmodifiable(_items);
  bool get hasErrors => _items.any((d) => !d.isWarning);

  void error(String file, int line, int col, String message) =>
      _items.add(Diagnostic(file, line, col, message));

  void warn(String file, int line, int col, String message) =>
      _items.add(Diagnostic(file, line, col, message, isWarning: true));
}
