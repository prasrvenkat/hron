package io.hron.ast;

/**
 * Represents a date specification (either named like "feb 14" or ISO like "2026-03-15").
 *
 * @param kind the type of date specification
 * @param month the month (for NAMED)
 * @param day the day (for NAMED)
 * @param date the ISO date string (for ISO)
 */
public record DateSpec(Kind kind, MonthName month, int day, String date) {

  /** The type of date specification. */
  public enum Kind {
    /** A named date (e.g., feb 14). */
    NAMED,
    /** An ISO date (e.g., 2026-03-15). */
    ISO
  }

  /**
   * Creates a named date specification.
   *
   * @param month the month
   * @param day the day
   * @return a new named date specification
   */
  public static DateSpec named(MonthName month, int day) {
    return new DateSpec(Kind.NAMED, month, day, null);
  }

  /**
   * Creates an ISO date specification.
   *
   * @param date the ISO date string (YYYY-MM-DD)
   * @return a new ISO date specification
   */
  public static DateSpec iso(String date) {
    return new DateSpec(Kind.ISO, null, 0, date);
  }
}
