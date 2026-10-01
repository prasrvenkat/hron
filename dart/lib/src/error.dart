/// A span of characters in source input, used for error reporting.
class Span {
  /// The start position (inclusive).
  final int start;

  /// The end position (exclusive).
  final int end;

  const Span(this.start, this.end);
}

/// The category of a [HronError].
enum HronErrorKind {
  /// Lexical error (invalid token).
  lex,

  /// Parse error (invalid syntax).
  parse,

  eval,

  /// A cron expression `fromCron` rejects, or a schedule `toCron` cannot
  /// express.
  cron,
}

/// An error thrown when parsing, evaluating, or converting hron expressions.
class HronError implements Exception {
  final HronErrorKind kind;

  final String message;

  /// Null unless this is a lex or parse error.
  final Span? span;

  /// Null unless this is a lex or parse error.
  final String? input;

  /// Null unless the parser has a fix to suggest.
  final String? suggestion;

  const HronError(
    this.kind,
    this.message, {
    this.span,
    this.input,
    this.suggestion,
  });

  factory HronError.lex(String message, Span span, String input) =>
      HronError(HronErrorKind.lex, message, span: span, input: input);

  factory HronError.parse(
    String message,
    Span span,
    String input, {
    String? suggestion,
  }) => HronError(
    HronErrorKind.parse,
    message,
    span: span,
    input: input,
    suggestion: suggestion,
  );

  factory HronError.eval(String message) =>
      HronError(HronErrorKind.eval, message);

  factory HronError.cron(String message) =>
      HronError(HronErrorKind.cron, message);

  /// Returns a formatted error message with source context and underline.
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
