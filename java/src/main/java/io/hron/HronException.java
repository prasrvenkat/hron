package io.hron;

import java.util.Optional;

/** Exception thrown for errors in hron parsing, evaluation, or cron conversion. */
public final class HronException extends Exception {
  /** The error kind. */
  private final ErrorKind kind;

  /** The source span where the error occurred. */
  private final Span span;

  /** The original input string. */
  private final String input;

  /** An optional suggestion for fixing the error. */
  private final String suggestion;

  private HronException(
      ErrorKind kind, String message, Span span, String input, String suggestion) {
    super(message);
    this.kind = kind;
    this.span = span;
    this.input = input;
    this.suggestion = suggestion;
  }

  /**
   * Creates a new lexer error.
   *
   * @param message the error message
   * @param span the location of the error in the input
   * @param input the original input string
   * @return a new HronException for a lexer error
   */
  public static HronException lex(String message, Span span, String input) {
    return new HronException(ErrorKind.LEX, message, span, input, null);
  }

  /**
   * Creates a new parser error.
   *
   * @param message the error message
   * @param span the location of the error in the input
   * @param input the original input string
   * @param suggestion an optional suggestion for fixing the error
   * @return a new HronException for a parser error
   */
  public static HronException parse(String message, Span span, String input, String suggestion) {
    return new HronException(ErrorKind.PARSE, message, span, input, suggestion);
  }

  /**
   * Creates a new evaluation error.
   *
   * @param message the error message
   * @return a new HronException for an evaluation error
   */
  public static HronException eval(String message) {
    return new HronException(ErrorKind.EVAL, message, null, null, null);
  }

  /**
   * Creates a new cron conversion error.
   *
   * @param message the error message
   * @return a new HronException for a cron conversion error
   */
  public static HronException cron(String message) {
    return new HronException(ErrorKind.CRON, message, null, null, null);
  }

  /**
   * Returns the kind of error.
   *
   * @return the error kind
   */
  public ErrorKind kind() {
    return kind;
  }

  /**
   * Returns the span where the error occurred, if available.
   *
   * @return the span, or empty if not available
   */
  public Optional<Span> span() {
    return Optional.ofNullable(span);
  }

  /**
   * Returns the original input string, if available.
   *
   * @return the input, or empty if not available
   */
  public Optional<String> input() {
    return Optional.ofNullable(input);
  }

  /**
   * Returns a suggestion for fixing the error, if available.
   *
   * @return the suggestion, or empty if not available
   */
  public Optional<String> suggestion() {
    return Optional.ofNullable(suggestion);
  }

  /**
   * Formats a rich error message with underline and optional suggestion.
   *
   * <p>For lex and parse errors with span and input, produces output like:
   *
   * <pre>
   * error: unexpected token
   *   every blorp at 09:00
   *         ^^^^^
   * </pre>
   *
   * @return a formatted error message
   */
  public String displayRich() {
    if ((kind == ErrorKind.LEX || kind == ErrorKind.PARSE) && span != null && input != null) {
      StringBuilder sb = new StringBuilder();
      sb.append("error: ").append(getMessage()).append("\n");
      sb.append("  ").append(input).append("\n");

      // Add padding and underline
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
