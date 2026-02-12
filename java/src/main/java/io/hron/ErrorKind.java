package io.hron;

/** The type of error that occurred during parsing, evaluation, or conversion. */
public enum ErrorKind {
  /** Lexer error - invalid tokens in input. */
  LEX("lex"),
  /** Parser error - invalid syntax. */
  PARSE("parse"),
  /** Evaluation error - cannot compute next occurrence. */
  EVAL("eval"),
  /** Cron conversion error - expression not convertible to cron. */
  CRON("cron");

  private final String value;

  ErrorKind(String value) {
    this.value = value;
  }

  /**
   * Returns the lowercase string representation.
   *
   * @return the kind as a lowercase string
   */
  public String value() {
    return value;
  }

  @Override
  public String toString() {
    return value;
  }
}
