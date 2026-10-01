/// The part of the input an error points at: `[start, end)` counted in
/// Unicode code points (`input.runes`), not UTF-16 code units.
class Span {
  final int start;

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

  /// The message, then for lex and parse errors the input and a line of
  /// carets under the span, and any suggestion as ` try: "..."`. Lines are
  /// joined by `\n`, with no trailing newline.
  String displayRich() {
    final span = this.span;
    final input = this.input;
    final located = kind == HronErrorKind.lex || kind == HronErrorKind.parse;
    if (!located || span == null || input == null) return 'error: $message';
    // A tab, CR or LF would move the input off the line the carets are aligned to.
    final shown = input.replaceAll(RegExp('[\t\r\n]'), ' ');
    final width = span.end - span.start;
    final carets = '^' * (width < 1 ? 1 : width);
    final hint = suggestion == null ? '' : ' try: "$suggestion"';
    return 'error: $message\n  $shown\n  ${' ' * span.start}$carets$hint';
  }

  @override
  String toString() => 'HronError: $message';
}
