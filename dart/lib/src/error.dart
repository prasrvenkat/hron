class Span {
  final int start;
  final int end;

  const Span(this.start, this.end);
}

enum HronErrorKind { lex, parse, eval, cron }

class HronError implements Exception {
  final HronErrorKind kind;
  final String message;
  final Span? span;
  final String? input;
  final String? suggestion;

  const HronError(this.kind, this.message, {this.span, this.input, this.suggestion});

  factory HronError.lex(String message, Span span, String input) =>
      HronError(HronErrorKind.lex, message, span: span, input: input);

  factory HronError.parse(String message, Span span, String input,
          {String? suggestion}) =>
      HronError(HronErrorKind.parse, message,
          span: span, input: input, suggestion: suggestion);

  factory HronError.eval(String message) =>
      HronError(HronErrorKind.eval, message);

  factory HronError.cron(String message) =>
      HronError(HronErrorKind.cron, message);

  String displayRich() {
    if ((kind == HronErrorKind.lex || kind == HronErrorKind.parse) &&
        span != null &&
        input != null) {
      final buf = StringBuffer();
      buf.writeln('error: $message');
      buf.writeln('  $input');
      final padding = ' ' * (span!.start + 2);
      final len = span!.end - span!.start;
      final underline = '^' * (len < 1 ? 1 : len);
      buf.write(padding);
      buf.write(underline);
      if (suggestion != null) {
        buf.write(' try: "$suggestion"');
      }
      return buf.toString();
    }
    return 'error: $message';
  }

  @override
  String toString() => 'HronError: $message';
}
