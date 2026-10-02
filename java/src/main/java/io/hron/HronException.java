package io.hron;

import java.util.Optional;

/** Exception thrown for errors in hron parsing or cron conversion. */
public final class HronException extends Exception {
  private final ErrorKind kind;

  private final Span span;

  private final String input;

  private final String suggestion;

  private HronException(
      ErrorKind kind, String message, Span span, String input, String suggestion) {
    super(message);
    this.kind = kind;
    this.span = span;
    this.input = input;
    this.suggestion = suggestion;
  }

  public static HronException lex(String message, Span span, String input) {
    return new HronException(ErrorKind.LEX, message, span, input, null);
  }

  /**
   * Creates a new parser error.
   *
   * @param suggestion a fix to show the user, or null
   */
  public static HronException parse(String message, Span span, String input, String suggestion) {
    return new HronException(ErrorKind.PARSE, message, span, input, suggestion);
  }

  public static HronException eval(String message) {
    return new HronException(ErrorKind.EVAL, message, null, null, null);
  }

  public static HronException cron(String message) {
    return new HronException(ErrorKind.CRON, message, null, null, null);
  }

  public ErrorKind kind() {
    return kind;
  }

  /** Empty unless this is a lex or parse error. */
  public Optional<Span> span() {
    return Optional.ofNullable(span);
  }

  /** Empty unless this is a lex or parse error. */
  public Optional<String> input() {
    return Optional.ofNullable(input);
  }

  /** Empty unless the parser has a fix to suggest. */
  public Optional<String> suggestion() {
    return Optional.ofNullable(suggestion);
  }

  /**
   * The message, then for lex and parse errors the input and a line of carets under the span, and
   * any suggestion as {@code try: "..."}. Lines are joined by {@code \n}, with no trailing newline.
   */
  public String displayRich() {
    if (span == null || input == null) {
      return "error: " + getMessage();
    }
    // A tab, CR or LF would move the input off the line the carets are aligned to.
    String shown = input.replace('\t', ' ').replace('\r', ' ').replace('\n', ' ');
    StringBuilder out = new StringBuilder();
    out.append("error: ").append(getMessage()).append('\n');
    out.append("  ").append(shown).append('\n');
    out.append("  ").append(" ".repeat(span.start())).append("^".repeat(span.length()));
    if (suggestion != null) {
      out.append(" try: \"").append(suggestion).append('"');
    }
    return out.toString();
  }
}
