package io.hron.ast;

/**
 * Represents an exception date.
 *
 * @param kind the type of exception specification
 * @param month the month (for NAMED)
 * @param day the day (for NAMED)
 * @param date the ISO date string (for ISO)
 */
public record ExceptionSpec(Kind kind, MonthName month, int day, String date) {

  /** The type of exception specification. */
  public enum Kind {
    /** A named exception (e.g., dec 25). */
    NAMED,
    /** An ISO exception (e.g., 2026-12-25). */
    ISO
  }

  /**
   * Creates a named exception specification.
   *
   * @param month the month
   * @param day the day
   * @return a new named exception specification
   */
  public static ExceptionSpec named(MonthName month, int day) {
    return new ExceptionSpec(Kind.NAMED, month, day, null);
  }

  /**
   * Creates an ISO exception specification.
   *
   * @param date the ISO date string (YYYY-MM-DD)
   * @return a new ISO exception specification
   */
  public static ExceptionSpec iso(String date) {
    return new ExceptionSpec(Kind.ISO, null, 0, date);
  }
}
