package io.hron;

public enum ErrorKind {
  /** Lexer error - invalid tokens in input. */
  LEX("lex"),
  /** Parser error - invalid syntax. */
  PARSE("parse"),
  /**
   * A schedule built in code from parts that break a rule (spec/README.md, "Error Types"). Never
   * thrown here, as Java builds schedules only through {@code parse} and {@code fromCron}.
   */
  EVAL("eval"),
  /** A cron expression {@code fromCron} rejects, or a schedule {@code toCron} cannot express. */
  CRON("cron");

  private final String value;

  ErrorKind(String value) {
    this.value = value;
  }

  /** Returns the kind as a lowercase string. */
  public String value() {
    return value;
  }

  @Override
  public String toString() {
    return value;
  }
}
