package io.hron.ast;

/**
 * Represents an until date.
 *
 * @param kind the type of until specification
 * @param date the ISO date string (for ISO)
 * @param month the month (for NAMED)
 * @param day the day (for NAMED)
 */
public record UntilSpec(Kind kind, String date, MonthName month, int day) {

  /** The type of until specification. */
  public enum Kind {
    /** An ISO until date (e.g., 2026-12-31). */
    ISO,
    /** A named until date (e.g., dec 31). */
    NAMED
  }

  /**
   * Creates an ISO until specification.
   *
   * @param date the ISO date string (YYYY-MM-DD)
   * @return a new ISO until specification
   */
  public static UntilSpec iso(String date) {
    return new UntilSpec(Kind.ISO, date, null, 0);
  }

  /**
   * Creates a named until specification.
   *
   * @param month the month
   * @param day the day
   * @return a new named until specification
   */
  public static UntilSpec named(MonthName month, int day) {
    return new UntilSpec(Kind.NAMED, null, month, day);
  }
}
