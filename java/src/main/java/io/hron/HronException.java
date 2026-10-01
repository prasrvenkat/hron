package io.hron;

import java.util.Optional;

/** Exception thrown for errors in hron parsing, evaluation, or cron conversion. */
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
   * Formats the error for display. Lex and parse errors show the input with the span underlined,
   * followed by the suggestion if there is one; other errors show the message alone.
   */
  public String displayRich() {
    if ((kind == ErrorKind.LEX || kind == ErrorKind.PARSE) && span != null && input != null) {
      StringBuilder sb = new StringBuilder();
      sb.append("error: ").append(getMessage()).append("\n");
      sb.append("  ").append(input).append("\n");

      sb.append(" ".repeat(span.start() + 2));
      sb.append("^".repeat(span.length()));

      if (suggestion != null && !suggestion.isEmpty()) {
        sb.append(" try: \"").append(suggestion).append("\"");
      }

      return sb.toString();
    }

    return "error: " + getMessage();
  }
}
