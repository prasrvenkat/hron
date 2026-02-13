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

  /// Evaluation error (e.g., invalid date).
  eval,

  /// Cron conversion error (expression not representable in cron).
  cron,
}

/// An error thrown when parsing, evaluating, or converting hron expressions.
///
/// Use [displayRich] for user-friendly error messages with source context.
class HronError implements Exception {
  /// The error category.
  final HronErrorKind kind;

  /// The error message.
  final String message;

  /// The location in the source input where the error occurred.
  final Span? span;

  /// The original source input.
  final String? input;

  /// A suggested correction, if available.
  final String? suggestion;

  const HronError(
    this.kind,
    this.message, {
    this.span,
    this.input,
    this.suggestion,
  });

  /// Creates a lexical error.
  factory HronError.lex(String message, Span span, String input) =>
      HronError(HronErrorKind.lex, message, span: span, input: input);

  /// Creates a parse error.
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

  /// Creates an evaluation error.
  factory HronError.eval(String message) =>
      HronError(HronErrorKind.eval, message);

  /// Creates a cron conversion error.
  factory HronError.cron(String message) =>
      HronError(HronErrorKind.cron, message);

  /// Returns a formatted error message with source context and underline.
  ///
  /// Example output:
  /// ```
  /// error: unexpected token
  ///   every dya at 9am
  ///         ^^^
  /// ```
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
